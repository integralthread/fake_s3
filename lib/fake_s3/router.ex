defmodule FakeS3.Router do
  @moduledoc false

  use Plug.Router

  require Logger

  alias FakeS3.{Auth, Config, Key, Metadata, S3XML, Storage}

  plug FakeS3.RequestId
  plug Plug.Logger
  plug Auth
  plug :match
  plug :dispatch

  def init(opts), do: opts

  def call(conn, opts) do
    conn = FakeS3.ConfigPlug.call(conn, FakeS3.ConfigPlug.init(opts))
    super(conn, opts)
  end

  get "/__health" do
    send_resp(conn, 200, "ok")
  end

  get "/__debug/objects" do
    objects = Storage.debug_list_all_objects()
    json = Jason.encode!(objects, pretty: true)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, json)
  end

  get "/" do
    buckets = Storage.list_buckets()
    xml = S3XML.list_buckets(buckets, request_id(conn))
    conn |> xml_resp(200, xml)
  end

  put "/:bucket" do
    with :ok <- validate_bucket(bucket),
         false <- Storage.bucket_exists?(bucket),
         :ok <- Storage.create_bucket(bucket, now_iso()) do
      send_resp(conn, 200, "")
    else
      true -> error_xml(conn, 409, "BucketAlreadyExists", "The requested bucket name is not available.", "/#{bucket}")
      {:error, :invalid_bucket} -> error_xml(conn, 400, "InvalidBucketName", "The specified bucket is not valid.", "/#{bucket}")
      {:error, _} -> send_resp(conn, 500, "")
    end
  end

  head "/:bucket" do
    if Storage.bucket_exists?(bucket) do
      send_resp(conn, 200, "")
    else
      error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")
    end
  end

  delete "/:bucket" do
    cond do
      not Storage.bucket_exists?(bucket) ->
        error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")

      true ->
        case Storage.delete_bucket(bucket) do
          :ok -> send_resp(conn, 204, "")
          {:error, :not_empty} -> error_xml(conn, 409, "BucketNotEmpty", "The bucket you tried to delete is not empty.", "/#{bucket}")
        end
    end
  end

  get "/:bucket" do
    conn = fetch_query_params(conn)

    case conn.query_params do
      %{"list-type" => "2"} ->
        handle_list_objects_v2(conn, bucket)

      _ ->
        error_xml(conn, 400, "InvalidArgument", "The request is missing the required list-type parameter.", "/#{bucket}")
    end
  end

  put "/:bucket/*key" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      case get_copy_source(conn) do
        {:ok, {src_bucket, src_key}} ->
          handle_copy_object(conn, src_bucket, src_key, bucket, key)

        {:error, :invalid_copy_source} ->
          error_xml(conn, 400, "InvalidArgument", "The specified copy source is not valid.", "/#{bucket}/#{key}")

        nil ->
          case enforce_body_limit(conn) do
            :ok -> handle_put_object(conn, bucket, key)
            {:error, :entity_too_large} -> send_resp(conn, 413, "Request entity too large")
          end
      end
    else
      {:error, :invalid_bucket} -> error_xml(conn, 400, "InvalidBucketName", "The specified bucket is not valid.", "/#{bucket}")
      false -> error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")
      {:error, :invalid_key} -> error_xml(conn, 400, "InvalidArgument", "The specified key is not valid.", "/#{bucket}")
      {:error, reason} -> send_resp(conn, 500, inspect(reason))
    end
  end

  get "/:bucket/*key" do
    with true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      handle_get_object(conn, bucket, key)
    else
      false -> error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")
      {:error, :invalid_key} -> error_xml(conn, 400, "InvalidArgument", "The specified key is not valid.", "/#{bucket}")
    end
  end

  head "/:bucket/*key" do
    with true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      handle_head_object(conn, bucket, key)
    else
      false -> error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")
      {:error, :invalid_key} -> error_xml(conn, 400, "InvalidArgument", "The specified key is not valid.", "/#{bucket}")
    end
  end

  delete "/:bucket/*key" do
    with true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      Storage.delete_object(bucket, key)
      send_resp(conn, 204, "")
    else
      false -> error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")
      {:error, :invalid_key} -> error_xml(conn, 400, "InvalidArgument", "The specified key is not valid.", "/#{bucket}")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp handle_put_object(conn, bucket, key) do
    content_type = content_type(conn, key)
    {headers, user_meta} = Metadata.extract_headers(conn.req_headers)

    case Storage.put_object(bucket, key, fn io ->
           stream_to_file(conn, io)
         end) do
      {:ok, meta_path, %{size: size, etag: etag}} ->
        meta = Metadata.build_object_meta(bucket, key, size, etag, content_type, headers, user_meta)
        :ok = Storage.write_json_atomic(meta_path, meta)

        conn
        |> put_resp_header("etag", etag)
        |> send_resp(200, "")

          {:error, :entity_too_large} ->
            send_resp(conn, 413, "Request entity too large")

          {:error, reason} ->
            send_resp(conn, 500, inspect(reason))
    end
  end

  defp handle_get_object(conn, bucket, key) do
    case Storage.read_object(bucket, key) do
      {:ok, %{content_path: path, meta: meta, stat: stat}} ->
        conn
        |> apply_object_headers(meta, stat.size)
        |> maybe_send_range(path, stat.size)

      {:error, :not_found} ->
        error_xml(conn, 404, "NoSuchKey", "The specified key does not exist.", "/#{bucket}/#{key}")
    end
  end

  defp handle_head_object(conn, bucket, key) do
    case Storage.read_object(bucket, key) do
      {:ok, %{meta: meta, stat: stat}} ->
        conn
        |> apply_object_headers(meta, stat.size)
        |> send_resp(200, "")

      {:error, :not_found} ->
        error_xml(conn, 404, "NoSuchKey", "The specified key does not exist.", "/#{bucket}/#{key}")
    end
  end

  defp handle_copy_object(conn, src_bucket, src_key, dest_bucket, dest_key) do
    case Storage.copy_object(src_bucket, src_key, dest_bucket, dest_key) do
      {:ok, %{etag: etag, last_modified: last_modified}} ->
        xml = S3XML.copy_object_result(etag, last_modified)
        xml_resp(conn, 200, xml)

      {:error, :source_not_found} ->
        error_xml(conn, 404, "NoSuchKey", "The specified key does not exist.", "/#{src_bucket}/#{src_key}")

      {:error, reason} ->
        send_resp(conn, 500, inspect(reason))
    end
  end

  defp get_copy_source(conn) do
    header =
      conn
      |> Plug.Conn.get_req_header("x-amz-copy-source")
      |> List.first()

    source =
      case header do
        nil ->
          conn = fetch_query_params(conn)
          conn.query_params["copy-source"]

        value ->
          value
      end

    if is_binary(source) do
      source = source |> URI.decode() |> String.trim_leading("/")

      case String.split(source, "/", parts: 2) do
        [bucket, key] when key != "" ->
          with :ok <- validate_bucket(bucket),
               {:ok, safe_key} <- Key.safe_key(key) do
            {:ok, {bucket, safe_key}}
          else
            _ -> {:error, :invalid_copy_source}
          end

        _ ->
          {:error, :invalid_copy_source}
      end
    else
      nil
    end
  end

  defp handle_list_objects_v2(conn, bucket) do
    if not Storage.bucket_exists?(bucket) do
      error_xml(conn, 404, "NoSuchBucket", "The specified bucket does not exist.", "/#{bucket}")
    else
      params = list_params(conn.query_params)
      keys = Storage.list_keys(bucket)
      {contents, common_prefixes, is_truncated, next_token} = list_objects(keys, bucket, params)
      xml = S3XML.list_objects_v2(bucket, params, contents, common_prefixes, is_truncated, next_token)
      xml_resp(conn, 200, xml)
    end
  end

  defp list_params(params) do
    %{
      prefix: Map.get(params, "prefix", ""),
      delimiter: Map.get(params, "delimiter"),
      token: Map.get(params, "continuation-token"),
      max_keys:
        params
        |> Map.get("max-keys", "1000")
        |> Integer.parse()
        |> case do
          {value, _} -> value
          :error -> 1000
        end
    }
  end

  defp list_objects(keys, bucket, params) do
    keys =
      keys
      |> Enum.filter(&String.starts_with?(&1, params.prefix))
      |> apply_token(params.token)

    {contents_keys, common_prefixes} =
      case params.delimiter do
        nil ->
          {keys, []}

        delimiter ->
          split_by_delimiter(keys, params.prefix, delimiter)
      end

    {page_keys, is_truncated, next_token} = paginate(contents_keys, params.max_keys)

    contents =
      Enum.map(page_keys, fn key ->
        case Storage.read_object(bucket, key) do
          {:ok, %{meta: meta, stat: stat}} ->
            %{
              key: key,
              last_modified: meta["last_modified"],
              etag: meta["etag"],
              size: stat.size
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {contents, common_prefixes, is_truncated, next_token}
  end

  defp apply_token(keys, nil), do: keys

  defp apply_token(keys, token) do
    case Base.decode64(token) do
      {:ok, last_key} ->
        keys |> Enum.drop_while(&(&1 <= last_key))

      _ ->
        keys
    end
  end

  defp split_by_delimiter(keys, prefix, delimiter) do
    Enum.reduce(keys, {[], MapSet.new()}, fn key, {contents, prefixes} ->
      rest = String.replace_prefix(key, prefix, "")

      case String.split(rest, delimiter, parts: 2) do
        [_] ->
          {[key | contents], prefixes}

        [segment, _] ->
          common_prefix = prefix <> segment <> delimiter
          {contents, MapSet.put(prefixes, common_prefix)}
      end
    end)
    |> then(fn {contents, prefixes} ->
      {Enum.sort(contents), prefixes |> MapSet.to_list() |> Enum.sort()}
    end)
  end

  defp paginate(keys, max_keys) do
    if length(keys) > max_keys do
      page = Enum.take(keys, max_keys)
      last_key = List.last(page)
      {page, true, Base.encode64(last_key)}
    else
      {keys, false, nil}
    end
  end

  defp content_type(conn, key) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [value | _] -> value
      _ -> MIME.from_path(key) || "application/octet-stream"
    end
  end

  defp stream_to_file(conn, io) do
    hash_ctx = :crypto.hash_init(:md5)
    max_bytes = Config.max_body_bytes()
    read_opts = [read_length: 1_048_576, timeout: 30_000]

    case read_body_chunks(conn, io, hash_ctx, 0, max_bytes, read_opts) do
      {:ok, ctx, size} ->
        md5 = :crypto.hash_final(ctx)
        etag = "\"" <> Base.encode16(md5, case: :lower) <> "\""
        {:ok, %{size: size, etag: etag}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body_chunks(conn, io, ctx, size, max_bytes, read_opts) do
    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, data, _conn} ->
        new_size = size + byte_size(data)

        if max_bytes != nil and new_size > max_bytes do
          {:error, :entity_too_large}
        else
          :ok = IO.binwrite(io, data)
          ctx = :crypto.hash_update(ctx, data)
          {:ok, ctx, new_size}
        end

      {:more, data, conn} ->
        new_size = size + byte_size(data)

        if max_bytes != nil and new_size > max_bytes do
          {:error, :entity_too_large}
        else
          :ok = IO.binwrite(io, data)
          ctx = :crypto.hash_update(ctx, data)
          read_body_chunks(conn, io, ctx, new_size, max_bytes, read_opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_object_headers(conn, meta, size) do
    conn
    |> put_resp_header("content-length", Integer.to_string(size))
    |> put_resp_header("content-type", meta["content_type"])
    |> put_resp_header("etag", meta["etag"])
    |> put_resp_header("last-modified", meta["last_modified"])
    |> put_meta_headers(meta)
  end

  defp put_meta_headers(conn, meta) do
    conn =
      Enum.reduce(meta["headers"] || %{}, conn, fn {k, v}, acc ->
        put_resp_header(acc, k, v)
      end)

    Enum.reduce(meta["user_metadata"] || %{}, conn, fn {k, v}, acc ->
      put_resp_header(acc, k, v)
    end)
  end

  defp maybe_send_range(conn, path, size) do
    case Plug.Conn.get_req_header(conn, "range") do
      [value | _] ->
        case parse_range(value, size) do
          {:ok, {start, length, end_pos}} ->
            conn
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-range", "bytes #{start}-#{end_pos}/#{size}")
            |> put_resp_header("content-length", Integer.to_string(length))
            |> send_file(206, path, start, length)

          :error ->
            send_file(conn, 200, path)
        end

      _ ->
        send_file(conn, 200, path)
    end
  end

  defp parse_range("bytes=" <> range, size) do
    case String.split(range, "-", parts: 2) do
      ["", end_s] ->
        with {suffix, ""} <- Integer.parse(end_s),
             true <- suffix > 0 do
          length = min(suffix, size)
          start = size - length
          end_pos = size - 1
          {:ok, {start, length, end_pos}}
        else
          _ -> :error
        end

      [start_s, end_s] ->
        with {start, ""} <- Integer.parse(start_s),
             end_pos <- if(end_s == "", do: size - 1, else: String.to_integer(end_s)),
             true <- start <= end_pos,
             true <- start < size,
             true <- end_pos < size do
          length = end_pos - start + 1
          {:ok, {start, length, end_pos}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_bucket(bucket) do
    if Key.valid_bucket?(bucket), do: :ok, else: {:error, :invalid_bucket}
  end

  defp normalize_key(key_parts) do
    key = Enum.join(key_parts, "/")
    Key.safe_key(key)
  end

  defp error_xml(conn, status, code, message, resource) do
    xml = S3XML.error(code, message, resource, request_id(conn))
    xml_resp(conn, status, xml)
  end

  defp xml_resp(conn, status, xml) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, xml)
  end

  defp request_id(conn), do: conn.assigns[:request_id] || "unknown"

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp enforce_body_limit(conn) do
    case Config.max_body_bytes() do
      nil ->
        :ok

      max ->
        case Plug.Conn.get_req_header(conn, "content-length") do
          [value | _] ->
            case Integer.parse(value) do
              {len, _} when len > max -> {:error, :entity_too_large}
              _ -> :ok
            end

          _ ->
            :ok
        end
    end
  end
end
