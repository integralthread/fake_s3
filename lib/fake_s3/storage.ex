defmodule FakeS3.Storage do
  @moduledoc false

  alias FakeS3.Config
  alias FakeS3.Key

  def bucket_dir(bucket) do
    Path.join([Config.data_dir(), "buckets", bucket])
  end

  def objects_dir(bucket) do
    Path.join([bucket_dir(bucket), "objects"])
  end

  def meta_dir(bucket) do
    Path.join([bucket_dir(bucket), "meta"])
  end

  # Scratch space for temp+rename. Deliberately a sibling of objects/ so that
  # a partial or orphaned write can never be mistaken for a stored object by
  # list_keys/2 or bucket_empty?/1.
  def tmp_dir(bucket) do
    Path.join([bucket_dir(bucket), "tmp"])
  end

  def uploads_dir(bucket) do
    Path.join([bucket_dir(bucket), "uploads"])
  end

  def bucket_meta_path(bucket) do
    Path.join([bucket_dir(bucket), "bucket.json"])
  end

  def object_path(bucket, key) do
    Path.join([objects_dir(bucket) | Key.key_path(key)])
  end

  def object_meta_path(bucket, key) do
    meta_file = key <> ".json"
    Path.join([meta_dir(bucket) | Key.key_path(meta_file)])
  end

  def ensure_bucket_dirs(bucket) do
    with :ok <- File.mkdir_p(objects_dir(bucket)),
         :ok <- File.mkdir_p(meta_dir(bucket)),
         :ok <- File.mkdir_p(tmp_dir(bucket)) do
      :ok
    end
  end

  def bucket_exists?(bucket) do
    File.dir?(bucket_dir(bucket))
  end

  def create_bucket(bucket, created_at) do
    with :ok <- ensure_bucket_dirs(bucket) do
      meta = %{name: bucket, created_at: created_at}
      write_json_atomic(bucket_meta_path(bucket), meta)
    end
  end

  def delete_bucket(bucket) do
    if bucket_empty?(bucket) do
      File.rm_rf(bucket_dir(bucket))
      :ok
    else
      {:error, :not_empty}
    end
  end

  def bucket_empty?(bucket) do
    dir = objects_dir(bucket)

    case File.dir?(dir) do
      false -> true
      true -> not any_file?(dir)
    end
  end

  def list_buckets do
    buckets_root = Path.join([Config.data_dir(), "buckets"])
    File.mkdir_p(buckets_root)

    case File.ls(buckets_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(buckets_root, &1)))
        |> Enum.map(&bucket_meta(&1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        []
    end
  end

  def bucket_meta(bucket) do
    path = bucket_meta_path(bucket)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, meta} ->
            %{name: meta["name"], created_at: meta["created_at"]}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Rejects keys that cannot be represented on a filesystem because another key
  already occupies part of their path.

  S3's keyspace is flat, so `a` and `a/b` may coexist there. Backed by
  directories they cannot, and silently accepting the second write would lose
  data. Callers surface this as an explicit error instead.
  """
  def check_key_conflict(bucket, key) do
    root = objects_dir(bucket)
    segments = Key.key_path(key)

    cond do
      ancestor_file?(root, segments) -> {:error, :key_conflict}
      File.dir?(Path.join([root | segments])) -> {:error, :key_conflict}
      true -> :ok
    end
  end

  defp ancestor_file?(root, segments) do
    segments
    |> Enum.drop(-1)
    |> Enum.reduce_while(root, fn segment, path ->
      next = Path.join(path, segment)
      if File.regular?(next), do: {:halt, :conflict}, else: {:cont, next}
    end)
    |> Kernel.==(:conflict)
  end

  @doc """
  Streams an object into place via temp+rename.

  `fun` receives an open IO device and returns `{:ok, payload}` or
  `{:error, reason}`; the payload is handed back to the caller so it can build
  metadata from whatever the writer computed (size, etag).
  """
  def put_object(bucket, key, fun) do
    content_path = object_path(bucket, key)
    meta_path = object_meta_path(bucket, key)

    with :ok <- check_key_conflict(bucket, key),
         :ok <- File.mkdir_p(tmp_dir(bucket)),
         :ok <- File.mkdir_p(Path.dirname(content_path)),
         :ok <- File.mkdir_p(Path.dirname(meta_path)),
         {:ok, payload, temp_path} <- write_temp(bucket, fun),
         :ok <- rename(temp_path, content_path) do
      {:ok, meta_path, payload}
    end
  end

  @doc """
  Writes to a temp file in the bucket's scratch dir and hands back the path.

  The caller owns the temp file from here: rename it into place or remove it.
  """
  def write_temp(bucket, fun) do
    File.mkdir_p(tmp_dir(bucket))
    temp_path = Path.join(tmp_dir(bucket), "tmp-" <> unique_suffix())

    case File.open(temp_path, [:write, :binary]) do
      {:ok, io} ->
        result =
          try do
            fun.(io)
          after
            File.close(io)
          end

        case result do
          {:ok, payload} ->
            {:ok, payload, temp_path}

          {:error, reason} ->
            File.rm(temp_path)
            {:error, reason}

          other ->
            File.rm(temp_path)
            {:error, other}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A failed rename previously went unnoticed, so the caller reported 200 OK
  # for an object that was never stored. Always surface it.
  defp rename(temp_path, target_path) do
    case File.rename(temp_path, target_path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temp_path)
        {:error, {:rename_failed, reason}}
    end
  end

  def write_json_atomic(path, data) do
    File.mkdir_p(Path.dirname(path))
    temp_path = path <> ".tmp-" <> unique_suffix()
    payload = Jason.encode!(data)

    with :ok <- File.write(temp_path, payload),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp_path)
        {:error, reason}
    end
  end

  def read_object(bucket, key) do
    content_path = object_path(bucket, key)
    meta_path = object_meta_path(bucket, key)

    with {:ok, %File.Stat{type: :regular} = stat} <- File.stat(content_path),
         {:ok, meta} <- read_json(meta_path) do
      {:ok, %{content_path: content_path, meta: meta, stat: stat}}
    else
      _ -> {:error, :not_found}
    end
  end

  def delete_object(bucket, key) do
    content_path = object_path(bucket, key)
    meta_path = object_meta_path(bucket, key)

    File.rm(content_path)
    File.rm(meta_path)

    # Leaving the directory behind would block a later PUT of the parent key.
    prune_empty_dirs(Path.dirname(content_path), objects_dir(bucket))
    prune_empty_dirs(Path.dirname(meta_path), meta_dir(bucket))

    :ok
  end

  defp prune_empty_dirs(dir, root) do
    if dir != root and String.starts_with?(dir, root <> "/") do
      case File.rmdir(dir) do
        :ok -> prune_empty_dirs(Path.dirname(dir), root)
        _ -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Copies an object, optionally replacing its metadata.

  `replacement` is `nil` to carry the source metadata over (the COPY
  directive), or a map of `:content_type`, `:headers` and `:user_metadata` to
  replace it (REPLACE).
  """
  def copy_object(src_bucket, src_key, dest_bucket, dest_key, replacement \\ nil) do
    same_object? = src_bucket == dest_bucket and src_key == dest_key

    case read_object(src_bucket, src_key) do
      {:ok, %{content_path: src_content_path, meta: src_meta}} ->
        cond do
          # Copying onto itself with File.copy/2 truncates the source before
          # reading it. S3 rejects this outright unless metadata is replaced.
          same_object? and is_nil(replacement) ->
            {:error, :copy_onto_self}

          same_object? ->
            write_copy_meta(dest_bucket, dest_key, src_meta, replacement)

          true ->
            copy_content(
              src_bucket,
              src_content_path,
              dest_bucket,
              dest_key,
              src_meta,
              replacement
            )
        end

      {:error, :not_found} ->
        {:error, :source_not_found}
    end
  end

  defp copy_content(src_bucket, src_content_path, dest_bucket, dest_key, src_meta, replacement) do
    dest_content_path = object_path(dest_bucket, dest_key)

    with :ok <- check_key_conflict(dest_bucket, dest_key),
         :ok <- File.mkdir_p(Path.dirname(dest_content_path)),
         {:ok, _, temp_path} <- write_temp(src_bucket, &stream_copy(src_content_path, &1)),
         :ok <- rename(temp_path, dest_content_path) do
      write_copy_meta(dest_bucket, dest_key, src_meta, replacement)
    end
  end

  defp stream_copy(src_path, io) do
    case File.open(src_path, [:read, :binary]) do
      {:ok, src_io} ->
        try do
          copy_loop(src_io, io)
        after
          File.close(src_io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_loop(src_io, dest_io) do
    case IO.binread(src_io, 1_048_576) do
      :eof ->
        {:ok, :copied}

      {:error, reason} ->
        {:error, reason}

      data ->
        case IO.binwrite(dest_io, data) do
          :ok -> copy_loop(src_io, dest_io)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp write_copy_meta(dest_bucket, dest_key, src_meta, replacement) do
    last_modified = DateTime.utc_now() |> DateTime.truncate(:second)

    new_meta =
      src_meta
      |> Map.put("key", dest_key)
      |> Map.put("bucket", dest_bucket)
      |> Map.put("last_modified", DateTime.to_iso8601(last_modified))
      |> apply_replacement(replacement)

    case write_json_atomic(object_meta_path(dest_bucket, dest_key), new_meta) do
      :ok -> {:ok, %{etag: src_meta["etag"], last_modified: last_modified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_replacement(meta, nil), do: meta

  defp apply_replacement(meta, replacement) do
    meta
    |> Map.put("content_type", replacement.content_type)
    |> Map.put("headers", replacement.headers)
    |> Map.put("user_metadata", replacement.user_metadata)
  end

  def list_keys(bucket) do
    dir = objects_dir(bucket)

    case File.dir?(dir) do
      false ->
        []

      true ->
        dir
        |> walk_files()
        |> Enum.map(fn path ->
          path
          |> Path.relative_to(dir)
          |> Path.split()
          |> Enum.join("/")
        end)
        |> Enum.sort()
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      error -> error
    end
  end

  def unique_suffix do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp walk_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> walk_files(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp any_file?(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.regular?(path) -> true
            File.dir?(path) -> any_file?(path)
            true -> false
          end
        end)

      _ ->
        false
    end
  end

  def debug_list_all_objects do
    Enum.flat_map(list_buckets(), fn bucket_meta ->
      bucket = bucket_meta.name

      bucket
      |> list_keys()
      |> Enum.map(fn key ->
        case read_object(bucket, key) do
          {:ok, %{meta: meta, stat: stat}} ->
            %{
              bucket: bucket,
              key: key,
              size: stat.size,
              etag: meta["etag"],
              content_type: meta["content_type"],
              last_modified: meta["last_modified"],
              user_metadata: meta["user_metadata"] || %{}
            }

          _ ->
            %{bucket: bucket, key: key, error: "metadata_missing"}
        end
      end)
    end)
  end
end
