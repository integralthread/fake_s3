defmodule FakeS3.Router do
  @moduledoc false

  use Plug.Router

  require Logger

  alias FakeS3.{Auth, Body, Config, Key, Metadata, Multipart, S3XML, Storage, Time, XML}

  @max_control_body 8 * 1024 * 1024

  plug(FakeS3.RequestId)
  plug(Plug.Logger)
  plug(Auth)
  plug(:fetch_query_params)
  plug(:match)
  plug(:dispatch)

  def init(opts), do: opts

  def call(conn, opts) do
    conn = FakeS3.ConfigPlug.call(conn, FakeS3.ConfigPlug.init(opts))
    super(conn, opts)
  end

  get "/__health" do
    send_resp(conn, 200, "ok")
  end

  get "/__debug/objects" do
    json = Jason.encode!(Storage.debug_list_all_objects(), pretty: true)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, json)
  end

  get "/" do
    xml = S3XML.list_buckets(Storage.list_buckets(), request_id(conn))
    xml_resp(conn, 200, xml)
  end

  put "/:bucket" do
    with :ok <- validate_bucket(bucket),
         false <- Storage.bucket_exists?(bucket),
         :ok <- Storage.create_bucket(bucket, Time.now_iso()) do
      conn
      |> put_resp_header("location", "/" <> bucket)
      |> send_resp(200, "")
    else
      true -> s3_error(conn, :bucket_already_exists, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  head "/:bucket" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket) do
      send_resp(conn, 200, "")
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  delete "/:bucket" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         :ok <- Storage.delete_bucket(bucket) do
      send_resp(conn, 204, "")
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, :not_empty} -> s3_error(conn, :bucket_not_empty, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  post "/:bucket" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket) do
      if Map.has_key?(conn.query_params, "delete") do
        handle_delete_objects(conn, bucket)
      else
        s3_error(conn, :not_implemented, "/#{bucket}")
      end
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  get "/:bucket" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket) do
      dispatch_bucket_get(conn, bucket)
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  put "/:bucket/*key" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      params = conn.query_params

      cond do
        params["uploadId"] && params["partNumber"] ->
          handle_upload_part(conn, bucket, key, params["uploadId"], params["partNumber"])

        true ->
          case get_copy_source(conn) do
            {:ok, {src_bucket, src_key}} ->
              handle_copy_object(conn, src_bucket, src_key, bucket, key)

            {:error, reason} ->
              s3_error(conn, reason, "/#{bucket}/#{key}")

            nil ->
              case check_declared_length(conn) do
                :ok -> handle_put_object(conn, bucket, key)
                {:error, reason} -> s3_error(conn, reason, "/#{bucket}/#{key}")
              end
          end
      end
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  post "/:bucket/*key" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      params = conn.query_params

      cond do
        Map.has_key?(params, "uploads") ->
          handle_create_multipart(conn, bucket, key)

        params["uploadId"] ->
          handle_complete_multipart(conn, bucket, key, params["uploadId"])

        true ->
          s3_error(conn, :not_implemented, "/#{bucket}/#{key}")
      end
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  get "/:bucket/*key" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      case conn.query_params["uploadId"] do
        nil -> handle_get_object(conn, bucket, key)
        upload_id -> handle_list_parts(conn, bucket, key, upload_id)
      end
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  head "/:bucket/*key" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      handle_head_object(conn, bucket, key)
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  delete "/:bucket/*key" do
    with :ok <- validate_bucket(bucket),
         true <- Storage.bucket_exists?(bucket),
         {:ok, key} <- normalize_key(key) do
      case conn.query_params["uploadId"] do
        nil ->
          Storage.delete_object(bucket, key)
          send_resp(conn, 204, "")

        upload_id ->
          case Multipart.abort(bucket, upload_id) do
            :ok -> send_resp(conn, 204, "")
            {:error, reason} -> s3_error(conn, reason, "/#{bucket}/#{key}")
          end
      end
    else
      false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  end

  match _ do
    s3_error(conn, :not_implemented, conn.request_path)
  end

  ## Bucket GET dispatch

  defp dispatch_bucket_get(conn, bucket) do
    params = conn.query_params

    cond do
      Map.has_key?(params, "location") ->
        xml_resp(conn, 200, S3XML.location_constraint(Config.region()))

      Map.has_key?(params, "versioning") ->
        xml_resp(conn, 200, S3XML.versioning_configuration())

      Map.has_key?(params, "acl") ->
        xml_resp(conn, 200, S3XML.access_control_policy())

      Map.has_key?(params, "uploads") ->
        xml_resp(
          conn,
          200,
          S3XML.list_multipart_uploads_result(bucket, Multipart.list_uploads(bucket))
        )

      params["list-type"] == "2" ->
        handle_list_objects(conn, bucket, :v2)

      Map.has_key?(params, "list-type") ->
        s3_error(conn, :invalid_argument, "/#{bucket}")

      # Anything else with a recognised subresource is an operation we do not
      # implement; bare GET is ListObjects v1.
      subresource?(params) ->
        s3_error(conn, :not_implemented, "/#{bucket}")

      true ->
        handle_list_objects(conn, bucket, :v1)
    end
  end

  @known_list_params ~w(prefix delimiter max-keys marker encoding-type continuation-token
                        start-after list-type fetch-owner)

  defp subresource?(params) do
    params
    |> Map.keys()
    |> Enum.any?(&(&1 not in @known_list_params))
  end

  ## Object handlers

  defp handle_put_object(conn, bucket, key) do
    content_type = content_type(conn, key)
    {headers, user_meta} = Metadata.extract_headers(conn.req_headers)

    case Storage.put_object(bucket, key, &Body.stream_to_file(conn, &1)) do
      {:ok, meta_path, %{size: size, etag: etag}} ->
        meta =
          Metadata.build_object_meta(bucket, key, size, etag, content_type, headers, user_meta)

        case Storage.write_json_atomic(meta_path, meta) do
          :ok ->
            conn
            |> put_resp_header("etag", etag)
            |> send_resp(200, "")

          {:error, reason} ->
            s3_error(conn, reason, "/#{bucket}/#{key}")
        end

      {:error, reason} ->
        s3_error(conn, reason, "/#{bucket}/#{key}")
    end
  end

  defp handle_get_object(conn, bucket, key) do
    case Storage.read_object(bucket, key) do
      {:ok, %{content_path: path, meta: meta, stat: stat}} ->
        conn
        |> apply_object_headers(meta)
        |> send_object(path, stat.size)

      {:error, :not_found} ->
        s3_error(conn, :no_such_key, "/#{bucket}/#{key}")
    end
  end

  defp handle_head_object(conn, bucket, key) do
    case Storage.read_object(bucket, key) do
      {:ok, %{content_path: path, meta: meta, stat: stat}} ->
        # send_resp/3 would let the adapter derive Content-Length from the
        # (empty) body and report 0. Going through send_file makes cowboy
        # derive it from the file while still omitting the body for HEAD.
        conn
        |> apply_object_headers(meta)
        |> send_file(200, path, 0, stat.size)

      {:error, :not_found} ->
        s3_error(conn, :no_such_key, "/#{bucket}/#{key}")
    end
  end

  defp handle_copy_object(conn, src_bucket, src_key, dest_bucket, dest_key) do
    replacement =
      case directive(conn) do
        "REPLACE" ->
          {headers, user_meta} = Metadata.extract_headers(conn.req_headers)

          %{
            content_type: content_type(conn, dest_key),
            headers: headers,
            user_metadata: user_meta
          }

        _ ->
          nil
      end

    case Storage.copy_object(src_bucket, src_key, dest_bucket, dest_key, replacement) do
      {:ok, %{etag: etag, last_modified: last_modified}} ->
        xml_resp(conn, 200, S3XML.copy_object_result(etag, last_modified))

      {:error, :source_not_found} ->
        s3_error(conn, :no_such_key, "/#{src_bucket}/#{src_key}")

      {:error, reason} ->
        s3_error(conn, reason, "/#{dest_bucket}/#{dest_key}")
    end
  end

  defp directive(conn) do
    conn
    |> get_req_header("x-amz-metadata-directive")
    |> List.first()
    |> to_string()
    |> String.upcase()
  end

  defp get_copy_source(conn) do
    source =
      case get_req_header(conn, "x-amz-copy-source") do
        [value | _] -> value
        _ -> conn.query_params["copy-source"]
      end

    if is_binary(source) do
      parse_copy_source(source)
    else
      nil
    end
  end

  defp parse_copy_source(source) do
    source =
      source
      |> String.split("?", parts: 2)
      |> hd()
      |> URI.decode()
      |> String.trim_leading("/")

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
  end

  ## Bulk delete

  defp handle_delete_objects(conn, bucket) do
    case read_control_body(conn) do
      {:ok, body, conn} ->
        keys = XML.texts(body, "Key")
        quiet? = XML.text(body, "Quiet") == "true"

        {deleted, errors} =
          Enum.reduce(keys, {[], []}, fn key, {ok, failed} ->
            case Key.safe_key(key) do
              {:ok, safe_key} ->
                Storage.delete_object(bucket, safe_key)
                {[key | ok], failed}

              {:error, _} ->
                {ok, [{key, "InvalidArgument", "The specified key is not valid."} | failed]}
            end
          end)

        xml = S3XML.delete_result(Enum.reverse(deleted), Enum.reverse(errors), quiet?)
        xml_resp(conn, 200, xml)

      {:error, reason, conn} ->
        s3_error(conn, reason, "/#{bucket}")
    end
  end

  ## Multipart

  defp handle_create_multipart(conn, bucket, key) do
    content_type = content_type(conn, key)
    {headers, user_meta} = Metadata.extract_headers(conn.req_headers)

    case Multipart.create(bucket, key, content_type, headers, user_meta) do
      {:ok, upload_id} ->
        xml_resp(conn, 200, S3XML.initiate_multipart_upload_result(bucket, key, upload_id))

      {:error, reason} ->
        s3_error(conn, reason, "/#{bucket}/#{key}")
    end
  end

  defp handle_upload_part(conn, bucket, key, upload_id, part_number) do
    with {:ok, number} <- parse_part_number(part_number),
         :ok <- check_declared_length(conn),
         {:ok, %{etag: etag}} <- Multipart.put_part(bucket, upload_id, number, conn) do
      conn
      |> put_resp_header("etag", etag)
      |> send_resp(200, "")
    else
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}/#{key}")
    end
  end

  defp handle_complete_multipart(conn, bucket, key, upload_id) do
    case read_control_body(conn) do
      {:ok, body, conn} ->
        parts =
          body
          |> XML.extract_all("Part")
          |> Enum.map(fn part ->
            {parse_int(XML.text(part, "PartNumber")), XML.text(part, "ETag")}
          end)
          |> Enum.reject(fn {number, _} -> is_nil(number) end)

        case Multipart.complete(bucket, upload_id, parts) do
          {:ok, %{etag: etag}} ->
            location = "#{request_url_base(conn)}/#{bucket}/#{key}"
            xml = S3XML.complete_multipart_upload_result(location, bucket, key, etag)
            xml_resp(conn, 200, xml)

          {:error, reason} ->
            s3_error(conn, reason, "/#{bucket}/#{key}")
        end

      {:error, reason, conn} ->
        s3_error(conn, reason, "/#{bucket}/#{key}")
    end
  end

  defp handle_list_parts(conn, bucket, key, upload_id) do
    if Multipart.exists?(bucket, upload_id) do
      parts = Multipart.list_parts(bucket, upload_id)
      xml_resp(conn, 200, S3XML.list_parts_result(bucket, key, upload_id, parts))
    else
      s3_error(conn, :no_such_upload, "/#{bucket}/#{key}")
    end
  end

  defp parse_part_number(value) do
    case parse_int(value) do
      number when is_integer(number) and number >= 1 and number <= 10_000 -> {:ok, number}
      _ -> {:error, :invalid_argument}
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp request_url_base(conn) do
    host =
      case get_req_header(conn, "host") do
        [value | _] -> value
        _ -> "#{conn.host}:#{conn.port}"
      end

    "#{conn.scheme}://#{host}"
  end

  ## Listing

  defp handle_list_objects(conn, bucket, version) do
    case list_params(conn.query_params) do
      {:ok, params} ->
        entries =
          bucket
          |> Storage.list_keys()
          |> filter_and_group(params)

        {page, truncated?, next_key} = paginate(entries, params.max_keys)
        {contents, prefixes} = split_entries(page, bucket)

        xml =
          case version do
            :v2 ->
              token = next_key && Base.encode64(next_key)
              S3XML.list_objects_v2(bucket, params, contents, prefixes, truncated?, token)

            :v1 ->
              S3XML.list_objects_v1(bucket, params, contents, prefixes, truncated?, next_key)
          end

        xml_resp(conn, 200, xml)

      {:error, reason} ->
        s3_error(conn, reason, "/#{bucket}")
    end
  end

  defp list_params(params) do
    with {:ok, max_keys} <- parse_max_keys(Map.get(params, "max-keys")) do
      {:ok,
       %{
         prefix: Map.get(params, "prefix") || "",
         delimiter: empty_to_nil(Map.get(params, "delimiter")),
         token: empty_to_nil(Map.get(params, "continuation-token")),
         marker: empty_to_nil(Map.get(params, "marker")),
         start_after: empty_to_nil(Map.get(params, "start-after")),
         encoding_type: encoding_type(Map.get(params, "encoding-type")),
         max_keys: max_keys
       }}
    end
  end

  defp parse_max_keys(nil), do: {:ok, 1000}

  defp parse_max_keys(value) do
    case Integer.parse(value) do
      # S3 caps at 1000 and rejects anything negative or non-numeric.
      {number, ""} when number >= 0 -> {:ok, min(number, 1000)}
      _ -> {:error, :invalid_argument}
    end
  end

  defp encoding_type("url"), do: "url"
  defp encoding_type(_), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp filter_and_group(keys, params) do
    keys
    |> Enum.filter(&String.starts_with?(&1, params.prefix))
    |> drop_consumed(params)
    |> group_by_delimiter(params)
  end

  defp drop_consumed(keys, params) do
    resume_after =
      cond do
        params.token -> decode_token(params.token)
        params.marker -> params.marker
        params.start_after -> params.start_after
        true -> nil
      end

    case resume_after do
      nil -> keys
      last -> Enum.drop_while(keys, &(&1 <= last))
    end
  end

  defp decode_token(token) do
    case Base.decode64(token) do
      {:ok, key} -> key
      :error -> nil
    end
  end

  # Entries are {type, display_name, last_underlying_key}. Tracking the
  # underlying key matters for pagination: a CommonPrefixes entry sorts before
  # every key beneath it, so resuming from the prefix name itself would replay
  # the whole group forever.
  defp group_by_delimiter(keys, %{delimiter: nil}) do
    Enum.map(keys, &{:key, &1, &1})
  end

  defp group_by_delimiter(keys, %{delimiter: delimiter, prefix: prefix}) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      rest = String.replace_prefix(key, prefix, "")

      case String.split(rest, delimiter, parts: 2) do
        [_] ->
          Map.put(acc, {:key, key}, key)

        [segment, _] ->
          Map.update(acc, {:prefix, prefix <> segment <> delimiter}, key, &max(&1, key))
      end
    end)
    |> Enum.map(fn {{type, name}, last_key} -> {type, name, last_key} end)
    |> Enum.sort_by(fn {_type, name, _last} -> name end)
  end

  defp paginate(_entries, 0), do: {[], false, nil}

  defp paginate(entries, max_keys) do
    if length(entries) > max_keys do
      page = Enum.take(entries, max_keys)
      {_type, _name, last_key} = List.last(page)
      {page, true, last_key}
    else
      {entries, false, nil}
    end
  end

  defp split_entries(page, bucket) do
    Enum.reduce(page, {[], []}, fn
      {:key, key, _}, {contents, prefixes} ->
        case Storage.read_object(bucket, key) do
          {:ok, %{meta: meta, stat: stat}} ->
            entry = %{
              key: key,
              last_modified: meta["last_modified"],
              etag: meta["etag"],
              size: stat.size
            }

            {[entry | contents], prefixes}

          _ ->
            {contents, prefixes}
        end

      {:prefix, name, _}, {contents, prefixes} ->
        {contents, [name | prefixes]}
    end)
    |> then(fn {contents, prefixes} -> {Enum.reverse(contents), Enum.reverse(prefixes)} end)
  end

  ## Responses

  defp content_type(conn, key) do
    case get_req_header(conn, "content-type") do
      [value | _] -> value
      _ -> MIME.from_path(key) || "application/octet-stream"
    end
  end

  defp apply_object_headers(conn, meta) do
    conn
    |> put_resp_header("content-type", meta["content_type"] || "application/octet-stream")
    |> put_resp_header("etag", meta["etag"])
    |> put_resp_header("last-modified", Time.to_http_date(meta["last_modified"]))
    |> put_resp_header("accept-ranges", "bytes")
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

  defp send_object(conn, path, size) do
    case get_req_header(conn, "range") do
      [value | _] -> send_range(conn, value, path, size)
      _ -> send_file(conn, 200, path, 0, size)
    end
  end

  defp send_range(conn, value, path, size) do
    case parse_range(value, size) do
      {:ok, {start, length, end_pos}} ->
        conn
        |> put_resp_header("content-range", "bytes #{start}-#{end_pos}/#{size}")
        |> send_file(206, path, start, length)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> s3_error(:invalid_range, conn.request_path)

      # RFC 7233: an unparseable Range must be ignored, not rejected.
      :ignore ->
        send_file(conn, 200, path, 0, size)
    end
  end

  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, ",") do
      [single] -> parse_single_range(String.trim(single), size)
      # Multipart ranges are legal to answer with the full entity.
      _ -> :ignore
    end
  end

  defp parse_range(_, _), do: :ignore

  defp parse_single_range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] -> suffix_range(suffix, size)
      [start, finish] -> offset_range(start, finish, size)
      _ -> :ignore
    end
  end

  defp suffix_range(suffix, size) do
    case Integer.parse(suffix) do
      {length, ""} when length > 0 ->
        if size == 0 do
          :unsatisfiable
        else
          length = min(length, size)
          {:ok, {size - length, length, size - 1}}
        end

      {0, ""} ->
        :unsatisfiable

      _ ->
        :ignore
    end
  end

  defp offset_range(start, finish, size) do
    with {start, ""} <- Integer.parse(start),
         {:ok, end_pos} <- range_end(finish, size) do
      cond do
        start >= size -> :unsatisfiable
        start > end_pos -> :unsatisfiable
        true -> {:ok, {start, min(end_pos, size - 1) - start + 1, min(end_pos, size - 1)}}
      end
    else
      _ -> :ignore
    end
  end

  defp range_end("", size), do: {:ok, size - 1}

  defp range_end(value, _size) do
    case Integer.parse(value) do
      {end_pos, ""} when end_pos >= 0 -> {:ok, end_pos}
      _ -> :error
    end
  end

  ## Helpers

  defp validate_bucket(bucket) do
    if Key.valid_bucket?(bucket), do: :ok, else: {:error, :invalid_bucket}
  end

  defp normalize_key(key_parts) do
    key_parts |> Enum.join("/") |> Key.safe_key()
  end

  # Reject oversized uploads from the declared length before streaming a body
  # we are only going to throw away.
  defp check_declared_length(conn) do
    case {Config.max_body_bytes(), Body.declared_length(conn)} do
      {nil, _} -> :ok
      {_max, nil} -> :ok
      {max, length} when length > max -> {:error, :entity_too_large}
      _ -> :ok
    end
  end

  defp read_control_body(conn, acc \\ "") do
    case read_body(conn, length: @max_control_body) do
      {:ok, data, conn} ->
        {:ok, acc <> data, conn}

      {:more, _data, conn} ->
        {:error, :entity_too_large, conn}

      {:error, _reason} ->
        {:error, :malformed_xml, conn}
    end
  end

  defp xml_resp(conn, status, xml) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, xml)
  end

  defp s3_error(conn, reason, resource) do
    {status, code, message} = error_info(reason)

    if status >= 500 do
      Logger.error("FakeS3 #{code}: #{inspect(reason)} on #{resource}")
    end

    xml = S3XML.error(code, message, resource, request_id(conn))
    xml_resp(conn, status, xml)
  end

  defp error_info(:no_such_bucket),
    do: {404, "NoSuchBucket", "The specified bucket does not exist."}

  defp error_info(:no_such_key),
    do: {404, "NoSuchKey", "The specified key does not exist."}

  defp error_info(:no_such_upload),
    do: {404, "NoSuchUpload", "The specified multipart upload does not exist."}

  defp error_info(:bucket_already_exists),
    do: {409, "BucketAlreadyOwnedByYou", "The requested bucket name is not available."}

  defp error_info(:bucket_not_empty),
    do: {409, "BucketNotEmpty", "The bucket you tried to delete is not empty."}

  defp error_info(:invalid_bucket),
    do: {400, "InvalidBucketName", "The specified bucket is not valid."}

  defp error_info(:invalid_key),
    do: {400, "InvalidArgument", "The specified key is not valid."}

  defp error_info(:invalid_copy_source),
    do: {400, "InvalidArgument", "The specified copy source is not valid."}

  defp error_info(:copy_onto_self),
    do:
      {400, "InvalidRequest",
       "This copy request is illegal because it is trying to copy an object to itself " <>
         "without changing the object's metadata."}

  defp error_info(:key_conflict),
    do:
      {400, "InvalidArgument",
       "The specified key collides with an existing key that is a prefix of it, or vice " <>
         "versa. FakeS3 stores objects as files, so these cannot coexist."}

  defp error_info(:entity_too_large),
    do: {413, "EntityTooLarge", "Your proposed upload exceeds the maximum allowed size."}

  defp error_info(:invalid_range),
    do: {416, "InvalidRange", "The requested range is not satisfiable."}

  defp error_info(:invalid_argument),
    do: {400, "InvalidArgument", "The request contained an invalid argument."}

  defp error_info(:invalid_part_order),
    do: {400, "InvalidPartOrder", "The list of parts was not in ascending order."}

  defp error_info(:empty_parts),
    do: {400, "MalformedXML", "The request did not list any parts."}

  defp error_info({:invalid_part, number}),
    do:
      {400, "InvalidPart",
       "One or more of the specified parts could not be found, or did not match. " <>
         "Part number: #{number}."}

  defp error_info(:malformed_xml),
    do: {400, "MalformedXML", "The XML provided was not well formed."}

  defp error_info(:not_implemented),
    do: {501, "NotImplemented", "This operation is not implemented by FakeS3."}

  defp error_info(_other),
    do: {500, "InternalError", "We encountered an internal error. Please try again."}

  defp request_id(conn), do: conn.assigns[:request_id] || "unknown"
end
