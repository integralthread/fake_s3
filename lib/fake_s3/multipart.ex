defmodule FakeS3.Multipart do
  @moduledoc """
  Multipart upload support, backed by a staging directory per upload.

      DATA_DIR/buckets/<bucket>/uploads/<upload-id>/meta.json
                                                   /part-00001
                                                   /part-00001.json

  Staging lives beside `objects/` rather than inside it, so an in-flight
  upload is never visible to listings.

  Known divergence from S3: the 5 MB minimum size for non-final parts is not
  enforced, so test suites can exercise multipart with tiny payloads.
  """

  alias FakeS3.{Body, Storage, Time}

  def uploads_dir(bucket), do: Storage.uploads_dir(bucket)

  def upload_dir(bucket, upload_id), do: Path.join(uploads_dir(bucket), upload_id)

  def create(bucket, key, content_type, headers, user_meta) do
    upload_id = Storage.unique_suffix() <> Storage.unique_suffix()
    dir = upload_dir(bucket, upload_id)

    meta = %{
      key: key,
      bucket: bucket,
      upload_id: upload_id,
      content_type: content_type,
      headers: headers,
      user_metadata: user_meta,
      initiated: Time.now_iso()
    }

    with :ok <- File.mkdir_p(dir),
         :ok <- Storage.write_json_atomic(Path.join(dir, "meta.json"), meta) do
      {:ok, upload_id}
    end
  end

  def exists?(bucket, upload_id) do
    File.regular?(Path.join(upload_dir(bucket, upload_id), "meta.json"))
  end

  def meta(bucket, upload_id) do
    read_json(Path.join(upload_dir(bucket, upload_id), "meta.json"))
  end

  def put_part(bucket, upload_id, part_number, conn) do
    dir = upload_dir(bucket, upload_id)

    if exists?(bucket, upload_id) do
      part_path = Path.join(dir, part_name(part_number))

      with {:ok, payload, temp_path} <- Storage.write_temp(bucket, &Body.stream_to_file(conn, &1)),
           :ok <- rename(temp_path, part_path),
           :ok <-
             Storage.write_json_atomic(part_path <> ".json", %{
               part_number: part_number,
               etag: payload.etag,
               md5: Base.encode16(payload.md5, case: :lower),
               size: payload.size,
               last_modified: Time.now_iso()
             }) do
        {:ok, payload}
      end
    else
      {:error, :no_such_upload}
    end
  end

  def list_parts(bucket, upload_id) do
    dir = upload_dir(bucket, upload_id)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&(&1 == "meta.json"))
        |> Enum.map(&read_json(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn part ->
          %{
            part_number: part["part_number"],
            etag: part["etag"],
            md5: part["md5"],
            size: part["size"],
            last_modified: part["last_modified"]
          }
        end)
        |> Enum.sort_by(& &1.part_number)

      _ ->
        []
    end
  end

  def list_uploads(bucket) do
    case File.ls(uploads_dir(bucket)) do
      {:ok, entries} ->
        entries
        |> Enum.map(&meta(bucket, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&%{key: &1["key"], upload_id: &1["upload_id"], initiated: &1["initiated"]})
        |> Enum.sort_by(& &1.key)

      _ ->
        []
    end
  end

  def abort(bucket, upload_id) do
    if exists?(bucket, upload_id) do
      File.rm_rf(upload_dir(bucket, upload_id))
      :ok
    else
      {:error, :no_such_upload}
    end
  end

  @doc """
  Assembles the staged parts into the final object.

  `requested` is the `[{part_number, etag}]` list from the client's
  CompleteMultipartUpload body; it is validated against what was actually
  staged before anything is written.
  """
  def complete(bucket, upload_id, requested) do
    with {:ok, meta} <- fetch_meta(bucket, upload_id),
         :ok <- validate_order(requested),
         {:ok, parts} <- resolve_parts(bucket, upload_id, requested),
         :ok <- Storage.check_key_conflict(bucket, meta["key"]) do
      assemble(bucket, upload_id, meta, parts)
    end
  end

  defp fetch_meta(bucket, upload_id) do
    case meta(bucket, upload_id) do
      nil -> {:error, :no_such_upload}
      meta -> {:ok, meta}
    end
  end

  defp validate_order([]), do: {:error, :empty_parts}

  defp validate_order(requested) do
    numbers = Enum.map(requested, fn {number, _etag} -> number end)

    if numbers == Enum.sort(numbers) and numbers == Enum.uniq(numbers) do
      :ok
    else
      {:error, :invalid_part_order}
    end
  end

  defp resolve_parts(bucket, upload_id, requested) do
    staged = list_parts(bucket, upload_id) |> Map.new(&{&1.part_number, &1})

    Enum.reduce_while(requested, {:ok, []}, fn {number, etag}, {:ok, acc} ->
      case Map.fetch(staged, number) do
        {:ok, part} ->
          if etag == nil or normalize_etag(etag) == normalize_etag(part.etag) do
            {:cont, {:ok, [part | acc]}}
          else
            {:halt, {:error, {:invalid_part, number}}}
          end

        :error ->
          {:halt, {:error, {:invalid_part, number}}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp normalize_etag(etag), do: etag |> to_string() |> String.trim("\"")

  defp assemble(bucket, upload_id, meta, parts) do
    key = meta["key"]
    dir = upload_dir(bucket, upload_id)
    content_path = Storage.object_path(bucket, key)

    with :ok <- File.mkdir_p(Path.dirname(content_path)),
         {:ok, size, temp_path} <- concat_parts(bucket, dir, parts),
         :ok <- rename(temp_path, content_path) do
      etag = composite_etag(parts)

      object_meta = %{
        key: key,
        bucket: bucket,
        size: size,
        etag: etag,
        last_modified: Time.now_iso(),
        content_type: meta["content_type"],
        headers: meta["headers"] || %{},
        user_metadata: meta["user_metadata"] || %{}
      }

      case Storage.write_json_atomic(Storage.object_meta_path(bucket, key), object_meta) do
        :ok ->
          File.rm_rf(dir)
          {:ok, %{etag: etag, key: key, size: size}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp concat_parts(bucket, dir, parts) do
    result =
      Storage.write_temp(bucket, fn io ->
        Enum.reduce_while(parts, {:ok, 0}, fn part, {:ok, total} ->
          path = Path.join(dir, part_name(part.part_number))

          case copy_into(path, io) do
            {:ok, copied} -> {:cont, {:ok, total + copied}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end)

    # write_temp/2 unwraps the {:ok, payload} its callback returns, so `size`
    # arrives directly and any {:error, _} has already cleaned up the temp file.
    case result do
      {:ok, size, temp_path} -> {:ok, size, temp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_into(path, dest_io) do
    case File.open(path, [:read, :binary]) do
      {:ok, src_io} ->
        try do
          copy_loop(src_io, dest_io, 0)
        after
          File.close(src_io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_loop(src_io, dest_io, copied) do
    case IO.binread(src_io, 1_048_576) do
      :eof ->
        {:ok, copied}

      {:error, reason} ->
        {:error, reason}

      data ->
        case IO.binwrite(dest_io, data) do
          :ok -> copy_loop(src_io, dest_io, copied + byte_size(data))
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # S3's multipart ETag is the MD5 of the concatenated raw part digests,
  # suffixed with the part count.
  defp composite_etag(parts) do
    digest =
      parts
      |> Enum.map(fn part -> Base.decode16!(part.md5, case: :mixed) end)
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    "\"" <> digest <> "-" <> Integer.to_string(length(parts)) <> "\""
  end

  defp part_name(part_number) do
    "part-" <> (part_number |> Integer.to_string() |> String.pad_leading(5, "0"))
  end

  defp rename(temp_path, target) do
    case File.rename(temp_path, target) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temp_path)
        {:error, {:rename_failed, reason}}
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _ -> nil
    end
  end
end
