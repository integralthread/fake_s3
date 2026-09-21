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
    # One VM owns a data directory. Hold the lock through response creation
    # so readers cannot pair metadata with a concurrently replaced body. This
    # also includes COPY, multipart completion, deletes and bucket changes.
    :global.trans(
      {{__MODULE__, Path.expand(Config.data_dir())}, self()},
      fn ->
        try do
          FakeS3.Publication.recover!()
          super(conn, opts)
        rescue
          error in Plug.Conn.WrapperError ->
            case error.reason do
              reason
              when is_struct(reason, File.Error) or is_struct(reason, FakeS3.StorageError) ->
                s3_error(
                  error.conn,
                  {:storage_error, Exception.message(reason)},
                  conn.request_path
                )

              _ ->
                reraise error, __STACKTRACE__
            end

          error in [File.Error, FakeS3.StorageError] ->
            s3_error(conn, {:storage_error, Exception.message(error)}, conn.request_path)
        end
      end,
      [node()]
    )
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
    dispatch_bucket_put(conn, bucket)
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
      cond do
        Map.has_key?(conn.query_params, "delete") -> handle_delete_objects(conn, bucket)
        multipart_form?(conn) -> handle_post_object(conn, bucket)
        true -> s3_error(conn, :not_implemented, "/#{bucket}")
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
          handle_delete_object(conn, bucket, key)

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

  ## Bucket PUT dispatch

  # The bucket-level configuration subresources S3 defines for PUT. Anything
  # not listed falls through to CreateBucket, so an unrecognised query
  # parameter cannot break plain bucket creation.
  @bucket_put_subresources ~w(accelerate acl analytics cors encryption
                              intelligent-tiering inventory lifecycle logging
                              metrics notification object-lock ownershipControls
                              policy publicAccessBlock replication requestPayment
                              tagging versioning website)

  # A PUT on a bucket path is CreateBucket only when it carries no subresource.
  # Routing `?versioning`, `?acl` and friends into CreateBucket made every one
  # of them fail with 409 BucketAlreadyOwnedByYou against a bucket that already
  # existed, which is what most of the ceph/s3-tests setup does.
  defp dispatch_bucket_put(conn, bucket) do
    if Enum.any?(@bucket_put_subresources, &Map.has_key?(conn.query_params, &1)) do
      with :ok <- validate_bucket(bucket),
           true <- Storage.bucket_exists?(bucket) do
        if Map.has_key?(conn.query_params, "versioning") do
          handle_put_versioning(conn, bucket)
        else
          s3_error(conn, :not_implemented, "/#{bucket}")
        end
      else
        false -> s3_error(conn, :no_such_bucket, "/#{bucket}")
        {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
      end
    else
      handle_create_bucket(conn, bucket)
    end
  end

  defp handle_put_versioning(conn, bucket) do
    with {:ok, body, conn} <- read_control_body(conn),
         status when status in ["Enabled", "Suspended"] <- XML.token(body, "Status"),
         :ok <- Storage.put_versioning(bucket, status) do
      send_resp(conn, 200, "")
    else
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
      # A missing or unrecognised <Status> is what S3 calls IllegalVersioningConfiguration.
      _ -> s3_error(conn, :illegal_versioning_configuration, "/#{bucket}")
    end
  end

  defp handle_create_bucket(conn, bucket) do
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

  ## Bucket GET dispatch

  defp dispatch_bucket_get(conn, bucket) do
    params = conn.query_params

    cond do
      Map.has_key?(params, "location") ->
        xml_resp(conn, 200, S3XML.location_constraint(Config.region()))

      Map.has_key?(params, "versioning") ->
        xml_resp(conn, 200, S3XML.versioning_configuration(Storage.versioning(bucket)))

      Map.has_key?(params, "acl") ->
        xml_resp(conn, 200, S3XML.access_control_policy())

      Map.has_key?(params, "versions") ->
        handle_list_versions(conn, bucket)

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

  # The bucket-level subresources S3 defines for GET that FakeS3 does not
  # implement. Listed explicitly rather than treating every unrecognised query
  # parameter as a subresource: a success_action_redirect sends the browser
  # back to the bucket URL with ?bucket=&key=&etag= appended, and S3 answers
  # that with a plain listing rather than 501.
  @bucket_get_subresources ~w(accelerate analytics cors encryption
                              intelligent-tiering inventory lifecycle logging
                              metrics notification object-lock ownershipControls
                              policy policyStatus publicAccessBlock replication
                              requestPayment tagging website)

  defp subresource?(params) do
    Enum.any?(@bucket_get_subresources, &Map.has_key?(params, &1))
  end

  ## Object handlers

  defp handle_put_object(conn, bucket, key) do
    with :ok <- Storage.check_key_conflict(bucket, key),
         :ok <- check_write_conditions(conn, bucket, key) do
      do_put_object(conn, bucket, key)
    else
      {:error, reason} -> s3_error(conn, reason, conn.request_path)
    end
  end

  defp check_write_conditions(conn, bucket, key) do
    with {:ok, etag} <- current_etag(bucket, key) do
      match = get_req_header(conn, "if-match")
      none = get_req_header(conn, "if-none-match")

      cond do
        match != [] and not etag_matches?(match, etag) -> {:error, :precondition_failed}
        none != [] and etag_matches?(none, etag) -> {:error, :precondition_failed}
        true -> :ok
      end
    end
  end

  defp current_etag(bucket, key) do
    case Storage.read_object(bucket, key) do
      {:ok, %{meta: meta}} -> {:ok, meta["etag"]}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp etag_matches?(_headers, nil), do: false

  defp etag_matches?(headers, etag) do
    headers
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == "*" or &1 == etag))
  end

  defp do_put_object(conn, bucket, key) do
    content_type = content_type(conn, key)
    {headers, user_meta} = Metadata.extract_headers(conn.req_headers)
    version_id = new_version_id(bucket)

    result =
      Storage.publish_object(bucket, key, fn ->
        # Conditions were checked under the same request lock, before any
        # version or body mutation. Bedrock uses unversioned buckets.
        if version_id, do: Storage.archive_current(bucket, key)

        with {:ok, meta_path, %{size: size, etag: etag}} <-
               Storage.put_object(bucket, key, &Body.stream_to_file(conn, &1)),
             meta =
               bucket
               |> Metadata.build_object_meta(key, size, etag, content_type, headers, user_meta)
               |> put_version_fields(version_id),
             :ok <- Storage.write_json_atomic(meta_path, meta) do
          {:ok, etag}
        end
      end)

    case result do
      {:ok, etag} ->
        conn
        |> put_resp_header("etag", etag)
        |> maybe_version_header(version_id)
        |> send_resp(200, "")

      {:error, reason} ->
        s3_error(conn, reason, conn.request_path)
    end
  end

  # nil for a bucket that has never had versioning enabled; "null" while
  # suspended, which is the id S3 reuses for every write in that state.
  defp new_version_id(bucket) do
    case Storage.versioning(bucket) do
      "Enabled" -> Storage.new_version_id()
      "Suspended" -> "null"
      _ -> nil
    end
  end

  defp put_version_fields(meta, nil), do: meta

  defp put_version_fields(meta, version_id) do
    meta
    |> Map.put(:version_id, version_id)
    |> Map.put(:version_seq, System.os_time(:microsecond))
  end

  defp maybe_version_header(conn, nil), do: conn

  defp maybe_version_header(conn, version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)

  defp handle_get_object(conn, bucket, key) do
    case resolve_version(conn, bucket, key) do
      {:ok, %{content_path: path, meta: meta, stat: stat}} ->
        conn
        |> apply_object_headers(meta)
        |> apply_version_headers(meta)
        |> send_object(path, stat.size)

      {:delete_marker, meta} ->
        delete_marker_response(conn, bucket, key, meta)

      {:error, reason} ->
        s3_error(conn, reason, "/#{bucket}/#{key}")
    end
  end

  defp handle_head_object(conn, bucket, key) do
    case resolve_version(conn, bucket, key) do
      {:ok, %{content_path: path, meta: meta, stat: stat}} ->
        # Supply the actual entity length; Cowboy omits the body for HEAD.
        # The response bytes and metadata are captured under the same lock.
        conn
        |> apply_object_headers(meta)
        |> apply_version_headers(meta)
        |> send_stored_file(200, path, 0, stat.size)

      {:delete_marker, meta} ->
        delete_marker_response(conn, bucket, key, meta)

      {:error, reason} ->
        s3_error(conn, reason, "/#{bucket}/#{key}")
    end
  end

  defp handle_delete_object(conn, bucket, key) do
    case {conn.query_params["versionId"], Storage.versioning(bucket)} do
      # Deleting a named version really removes it, in any bucket state.
      {version_id, _} when is_binary(version_id) ->
        case Storage.delete_version(bucket, key, version_id) do
          {:ok, marker?} ->
            conn
            |> put_resp_header("x-amz-version-id", version_id)
            |> then(&if marker?, do: put_resp_header(&1, "x-amz-delete-marker", "true"), else: &1)
            |> send_resp(204, "")

          {:error, reason} ->
            s3_error(conn, reason, "/#{bucket}/#{key}")
        end

      # Versioning on: the object is not removed, it is shadowed by a marker.
      {nil, status} when status in ["Enabled", "Suspended"] ->
        marker_id = if status == "Enabled", do: Storage.new_version_id(), else: "null"

        case Storage.put_delete_marker(bucket, key, marker_id) do
          :ok ->
            conn
            |> put_resp_header("x-amz-delete-marker", "true")
            |> put_resp_header("x-amz-version-id", marker_id)
            |> send_resp(204, "")

          {:error, reason} ->
            s3_error(conn, reason, "/#{bucket}/#{key}")
        end

      {nil, _} ->
        case Storage.delete_object(bucket, key) do
          :ok -> send_resp(conn, 204, "")
          {:error, reason} -> s3_error(conn, reason, conn.request_path)
        end
    end
  end

  defp resolve_version(conn, bucket, key) do
    case conn.query_params["versionId"] do
      nil ->
        case Storage.read_object(bucket, key) do
          {:ok, found} ->
            {:ok, found}

          {:error, :not_found} ->
            # A current delete marker reads as absent, but S3 flags it so a
            # client can tell "deleted" from "never existed".
            case Storage.read_current_meta(bucket, key) do
              %{"delete_marker" => true} = meta -> {:delete_marker, meta}
              _ -> {:error, :no_such_key}
            end

          {:error, reason} ->
            {:error, reason}
        end

      version_id ->
        case Storage.read_version(bucket, key, version_id) do
          {:ok, %{delete_marker: true, meta: meta}} -> {:delete_marker, meta}
          {:ok, found} -> {:ok, found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Addressing a delete marker directly is a 405 in S3; reaching one implicitly
  # is a 404. Both carry x-amz-delete-marker so the client can distinguish it.
  defp delete_marker_response(conn, bucket, key, meta) do
    reason = if conn.query_params["versionId"], do: :method_not_allowed, else: :no_such_key

    conn
    |> put_resp_header("x-amz-delete-marker", "true")
    |> apply_version_headers(meta)
    |> s3_error(reason, "/#{bucket}/#{key}")
  end

  defp apply_version_headers(conn, meta) do
    case meta["version_id"] do
      nil -> conn
      version_id -> put_resp_header(conn, "x-amz-version-id", version_id)
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
        quiet? = XML.token(body, "Quiet") == "true"

        # Each <Object> is taken whole rather than gathering <Key> and
        # <VersionId> into separate lists, so a key stays paired with the
        # version it names. Dropping the pairing left every non-current
        # version behind, and a bucket that could never be emptied.
        {deleted, errors} =
          body
          |> XML.extract_all("Object")
          |> Enum.reduce({[], []}, fn object, {ok, failed} ->
            key = XML.text(object, "Key")
            version_id = XML.token(object, "VersionId")

            case Key.safe_key(key || "") do
              {:ok, safe_key} ->
                case delete_one(bucket, safe_key, version_id) do
                  result when result == :ok or elem(result, 0) == :ok ->
                    {[key | ok], failed}

                  {:error, reason} ->
                    {_status, code, message} = error_info(reason)
                    {ok, [{key, code, message} | failed]}
                end

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

  # Mirrors the single-object DELETE: a named version is really removed, an
  # unnamed one is shadowed by a delete marker while versioning is on.
  defp delete_one(bucket, key, nil) do
    case Storage.versioning(bucket) do
      status when status in ["Enabled", "Suspended"] ->
        marker_id = if status == "Enabled", do: Storage.new_version_id(), else: "null"
        Storage.put_delete_marker(bucket, key, marker_id)

      _ ->
        Storage.delete_object(bucket, key)
    end
  end

  defp delete_one(bucket, key, version_id) do
    Storage.delete_version(bucket, key, version_id)
  end

  ## POST object (browser form upload)

  @max_post_body 5 * 1024 * 1024 * 1024

  defp multipart_form?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.starts_with?(String.downcase(value), "multipart/form-data")
      _ -> false
    end
  end

  # Parsed here rather than in the plug pipeline: every other route streams its
  # body straight to disk, and installing a body parser globally would buffer
  # object uploads that are deliberately never held in memory.
  defp handle_post_object(conn, bucket) do
    parser = Plug.Parsers.init(parsers: [:multipart], length: @max_post_body, pass: ["*/*"])
    conn = Plug.Parsers.call(conn, parser)

    {upload, fields} = split_upload(conn.params)

    with {:ok, key} <- post_key(fields, upload),
         # Conditions are checked against the resolved key: "${filename}" is
         # substituted first, so ["starts-with", "$key", ...] sees the name the
         # object will actually get.
         :ok <- check_post_policy(Map.put(fields, "key", key), bucket, upload),
         {:ok, etag} <- store_post_object(bucket, key, upload, fields) do
      post_success(conn, bucket, key, etag, fields)
    else
      {:error, reason} -> s3_error(conn, reason, "/#{bucket}")
    end
  rescue
    # Plug raises on a body that is not parseable as multipart.
    Plug.Parsers.ParseError -> s3_error(conn, :malformed_post_request, "/#{bucket}")
  end

  # Clients that build the form with a filename on every part — which is what
  # requests' files= and many browser helpers do — make Plug parse ordinary
  # fields as uploads too. Only "file" is the object body; every other part is
  # read back as its text value.
  defp split_upload(params) do
    Enum.reduce(params, {nil, %{}}, fn {name, value}, {body, fields} ->
      case String.downcase(name) do
        "file" -> {post_body(value), fields}
        field -> {body, Map.put(fields, field, field_value(value))}
      end
    end)
  end

  defp post_body(%Plug.Upload{path: path, filename: filename}),
    do: %{path: path, data: nil, filename: filename || ""}

  defp post_body(value) when is_binary(value), do: %{path: nil, data: value, filename: ""}
  defp post_body(_), do: nil

  defp field_value(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, contents} -> contents
      _ -> ""
    end
  end

  defp field_value(value) when is_binary(value), do: value
  defp field_value(value), do: to_string(value)

  # "${filename}" is replaced with the name the browser sent, which is the only
  # way a plain form can name the object after the file the user picked.
  defp post_key(fields, upload) do
    case Map.get(fields, "key") do
      nil ->
        {:error, :missing_post_key}

      "" ->
        {:error, :missing_post_key}

      key ->
        filename = (upload && upload.filename) || ""
        {:ok, String.replace(key, "${filename}", filename)}
    end
  end

  defp upload_size(nil), do: 0
  defp upload_size(%{data: data}) when is_binary(data), do: byte_size(data)

  defp upload_size(%{path: path}) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp check_post_policy(fields, bucket, upload) do
    case Map.get(fields, "policy") do
      # No policy at all is an anonymous form post; there is nothing to enforce.
      nil ->
        :ok

      encoded ->
        with {:ok, policy} <- FakeS3.PostPolicy.decode(encoded) do
          FakeS3.PostPolicy.validate(policy, fields, bucket, upload_size(upload))
        end
    end
  end

  defp store_post_object(bucket, key, upload, fields) do
    content_type = Map.get(fields, "content-type") || "binary/octet-stream"
    user_meta = post_user_metadata(fields)
    version_id = new_version_id(bucket)

    if version_id, do: Storage.archive_current(bucket, key)

    writer = fn io ->
      case upload do
        nil -> Body.write_binary_to("", io)
        %{data: data} when is_binary(data) -> Body.write_binary_to(data, io)
        %{path: path} -> Body.stream_file_to(path, io)
      end
    end

    with {:ok, meta_path, %{size: size, etag: etag}} <- Storage.put_object(bucket, key, writer),
         meta =
           bucket
           |> Metadata.build_object_meta(key, size, etag, content_type, %{}, user_meta)
           |> put_version_fields(version_id),
         :ok <- Storage.write_json_atomic(meta_path, meta) do
      {:ok, etag}
    end
  end

  defp post_user_metadata(fields) do
    fields
    |> Enum.filter(fn {name, value} ->
      String.starts_with?(name, "x-amz-meta-") and is_binary(value)
    end)
    |> Map.new()
  end

  # success_action_redirect wins over success_action_status; an unrecognised
  # status falls back to 204 rather than being echoed back verbatim.
  defp post_success(conn, bucket, key, etag, fields) do
    location = "#{request_url_base(conn)}/#{bucket}/#{key}"

    case redirect_target(fields) do
      nil ->
        case Map.get(fields, "success_action_status") do
          "200" ->
            send_resp(conn, 200, "")

          "201" ->
            xml = S3XML.post_response(location, bucket, key, etag)
            xml_resp(conn, 201, xml)

          _ ->
            send_resp(conn, 204, "")
        end

      target ->
        # Ordered list, not a map: S3 appends bucket, key, etag in that order
        # and encode_query/1 would otherwise sort them alphabetically.
        query = URI.encode_query([{"bucket", bucket}, {"key", key}, {"etag", etag}])

        conn
        |> put_resp_header("location", "#{target}?#{query}")
        |> send_resp(303, "")
    end
  end

  defp redirect_target(fields) do
    case Map.get(fields, "success_action_redirect") || Map.get(fields, "redirect") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
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
            {parse_int(XML.token(part, "PartNumber")), XML.token(part, "ETag")}
          end)
          |> Enum.reject(fn {number, _} -> is_nil(number) end)

        case Storage.publish_object(bucket, key, fn ->
               Multipart.complete(bucket, upload_id, parts)
             end) do
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

  # Paginates by key rather than by key+version: every version of a key in the
  # page is returned together. S3 can split a key's versions across pages via
  # version-id-marker; nothing in practice depends on that, and doing it here
  # would mean a second cursor through the version list.
  defp handle_list_versions(conn, bucket) do
    case list_params(conn.query_params) do
      {:ok, params} ->
        entries =
          bucket
          |> Storage.list_versioned_keys()
          |> filter_and_group(params)

        {page, truncated?, next_key} = paginate(entries, params.max_keys)
        {versions, markers, prefixes} = split_version_entries(page, bucket)

        xml =
          S3XML.list_object_versions(
            bucket,
            params,
            versions,
            markers,
            prefixes,
            truncated?,
            next_key
          )

        xml_resp(conn, 200, xml)

      {:error, reason} ->
        s3_error(conn, reason, "/#{bucket}")
    end
  end

  defp split_version_entries(page, bucket) do
    {versions, markers, prefixes} =
      Enum.reduce(page, {[], [], []}, fn
        {:key, key, _}, acc ->
          Enum.reduce(Storage.list_versions(bucket, key), acc, fn meta,
                                                                  {versions, markers, prefixes} ->
            entry = version_entry(key, meta)

            if meta["delete_marker"] do
              {versions, [entry | markers], prefixes}
            else
              {[entry | versions], markers, prefixes}
            end
          end)

        {:prefix, name, _}, {versions, markers, prefixes} ->
          {versions, markers, [name | prefixes]}
      end)

    {Enum.reverse(versions), Enum.reverse(markers), Enum.reverse(prefixes)}
  end

  defp version_entry(key, meta) do
    %{
      key: key,
      version_id: meta["version_id"] || "null",
      is_latest: meta["is_latest"] == true,
      last_modified: meta["last_modified"],
      etag: meta["etag"],
      size: meta["size"] || 0
    }
  end

  defp list_params(params) do
    with {:ok, max_keys} <- parse_max_keys(Map.get(params, "max-keys")) do
      {:ok,
       %{
         prefix: Map.get(params, "prefix") || "",
         delimiter: empty_to_nil(Map.get(params, "delimiter")),
         token: empty_to_nil(Map.get(params, "continuation-token")),
         # ListObjectVersions spells the same cursor "key-marker".
         marker: empty_to_nil(Map.get(params, "marker") || Map.get(params, "key-marker")),
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

          {:error, reason} ->
            raise FakeS3.StorageError, reason: {:listing_object, key, reason}
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

  # Cowboy can defer opening sendfile paths until after this process returns.
  # Capture the bytes under the storage lock, so an overwrite cannot change
  # the body after its ETag/length were selected. This intentionally buffers
  # local-development objects in memory.
  defp send_stored_file(conn, status, path, offset, length) do
    body = File.read!(path)
    length = if length == :all, do: byte_size(body) - offset, else: length
    body = binary_part(body, offset, length)

    conn
    |> put_resp_header("content-length", Integer.to_string(length))
    |> send_resp(status, body)
  end

  defp send_object(conn, path, size) do
    case get_req_header(conn, "range") do
      [value | _] -> send_range(conn, value, path, size)
      _ -> send_stored_file(conn, 200, path, 0, size)
    end
  end

  defp send_range(conn, value, path, size) do
    case parse_range(value, size) do
      {:ok, {start, length, end_pos}} ->
        conn
        |> put_resp_header("content-range", "bytes #{start}-#{end_pos}/#{size}")
        |> send_stored_file(206, path, start, length)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> s3_error(:invalid_range, conn.request_path)

      # RFC 7233: an unparseable Range must be ignored, not rejected.
      :ignore ->
        send_stored_file(conn, 200, path, 0, size)
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

  defp error_info(:precondition_failed),
    do:
      {412, "PreconditionFailed", "At least one of the preconditions you specified did not hold."}

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

  defp error_info(:missing_post_key),
    do: {400, "InvalidArgument", "Bucket POST must contain a field named 'key'."}

  defp error_info(:malformed_post_request),
    do: {400, "MalformedPOSTRequest", "The body of your POST request is not well-formed."}

  defp error_info(:invalid_policy_document),
    do:
      {400, "InvalidPolicyDocument",
       "The content of the form does not meet the conditions specified in the policy document."}

  # A POST that breaks the policy's content-length-range is a 400, unlike the
  # 413 a PUT gets for exceeding FAKES3_MAX_BODY_BYTES.
  defp error_info(:post_entity_too_large),
    do: {400, "EntityTooLarge", "Your proposed upload exceeds the maximum allowed size."}

  defp error_info(:access_denied),
    do: {403, "AccessDenied", "Access Denied."}

  defp error_info(:no_such_version),
    do: {404, "NoSuchVersion", "The specified version does not exist."}

  defp error_info(:method_not_allowed),
    do: {405, "MethodNotAllowed", "The specified method is not allowed against this resource."}

  defp error_info(:illegal_versioning_configuration),
    do:
      {400, "IllegalVersioningConfigurationException",
       "The versioning configuration specified in the request is invalid."}

  defp error_info(_other),
    do: {500, "InternalError", "We encountered an internal error. Please try again."}

  defp request_id(conn), do: conn.assigns[:request_id] || "unknown"
end
