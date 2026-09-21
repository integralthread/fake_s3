defmodule FakeS3.Storage do
  @moduledoc false

  alias FakeS3.Config
  alias FakeS3.Key
  alias FakeS3.Time

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
    case File.stat(bucket_dir(bucket)) do
      {:ok, %File.Stat{type: :directory}} -> true
      {:error, :enoent} -> false
      other -> raise FakeS3.StorageError, reason: {:bucket_unreadable, bucket, other}
    end
  end

  def create_bucket(bucket, created_at) do
    with :ok <- ensure_bucket_dirs(bucket) do
      meta = %{name: bucket, created_at: created_at}
      write_json_atomic(bucket_meta_path(bucket), meta)
    end
  end

  def delete_bucket(bucket) do
    if bucket_empty?(bucket) do
      case File.rm_rf(bucket_dir(bucket)) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    else
      {:error, :not_empty}
    end
  end

  @doc """
  True when nothing at all remains, including old versions and delete markers.

  S3 refuses to delete a bucket that still holds non-current versions, and a
  delete marker is metadata with no content file, so checking objects/ alone
  would call a bucket empty while its version history was still on disk.
  """
  def bucket_empty?(bucket) do
    optional_versions_dir = versions_meta_dir(bucket)

    Enum.all?([objects_dir(bucket), meta_dir(bucket), optional_versions_dir], fn dir ->
      case File.stat(dir) do
        {:ok, %File.Stat{type: :directory}} -> walk_files(dir) == []
        {:error, :enoent} when dir == optional_versions_dir -> true
        other -> raise FakeS3.StorageError, reason: {:bucket_unreadable, dir, other}
      end
    end)
  end

  def list_buckets do
    buckets_root = Path.join([Config.data_dir(), "buckets"])
    File.mkdir_p!(buckets_root)

    buckets_root
    |> File.ls!()
    |> Enum.filter(fn entry -> File.lstat!(Path.join(buckets_root, entry)).type == :directory end)
    |> Enum.map(&bucket_meta/1)
    |> Enum.sort_by(& &1.name)
  end

  def bucket_meta(bucket) do
    case read_json(bucket_meta_path(bucket)) do
      {:ok, %{"name" => name, "created_at" => created_at} = meta} ->
        %{name: name, created_at: created_at, versioning: meta["versioning"]}

      other ->
        raise FakeS3.StorageError, reason: {:bucket_metadata_unreadable, bucket, other}
    end
  end

  @doc """
  The bucket's versioning state: `nil` (never configured), `"Enabled"` or
  `"Suspended"`.

  S3 has no way back to the unconfigured state once versioning has been
  enabled, which is why `nil` and `"Suspended"` are distinct: `nil` returns an
  empty `VersioningConfiguration`, `"Suspended"` returns an explicit status.
  """
  def versioning(bucket) do
    case bucket_meta(bucket) do
      %{versioning: status} -> status
      _ -> nil
    end
  end

  def versioning_enabled?(bucket), do: versioning(bucket) == "Enabled"

  @doc "True once versioning has ever been turned on, i.e. old versions may exist."
  def versioned?(bucket), do: versioning(bucket) in ["Enabled", "Suspended"]

  def put_versioning(bucket, status) when status in ["Enabled", "Suspended"] do
    path = bucket_meta_path(bucket)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, meta} -> write_json_atomic(path, Map.put(meta, "versioning", status))
          _ -> {:error, :bucket_meta_unreadable}
        end

      _ ->
        {:error, :bucket_meta_unreadable}
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
  Publish an object's body and metadata as one recoverable operation.

  The caller must hold the data-directory request lock. `fun` returns `:ok`,
  `{:ok, result}`, or `{:error, reason}`. Failed and interrupted operations
  restore the previous object before another request can observe it.
  """
  def publish_object(bucket, key, fun) do
    archive_paths =
      case read_current_meta(bucket, key) do
        %{"version_id" => version} when version != "null" ->
          [version_path(bucket, key, version), version_meta_path(bucket, key, version)]

        _ ->
          []
      end

    FakeS3.Publication.run(
      [object_path(bucket, key), object_meta_path(bucket, key)] ++ archive_paths,
      fun
    )
  end

  @doc "Stage and publish the body; call inside publish_object/3 with metadata publication."
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
            with {:ok, payload} <- fun.(io), :ok <- :file.sync(io) do
              {:ok, payload}
            end
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
    # Keep interrupted metadata staging outside all object/version listings.
    staging = Path.join(Config.data_dir(), ".staging")
    File.mkdir_p!(staging)
    temp_path = Path.join(staging, unique_suffix())
    payload = Jason.encode!(data)

    with :ok <- File.write(temp_path, payload, [:sync]),
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

    case {File.stat(content_path), read_json(meta_path)} do
      {{:ok, %File.Stat{type: :regular} = stat}, {:ok, meta}} when is_map(meta) ->
        if meta["size"] == stat.size and is_binary(meta["etag"]) do
          {:ok, %{content_path: content_path, meta: meta, stat: stat}}
        else
          {:error, :corrupt_object}
        end

      {{:error, :enoent}, {:error, :enoent}} ->
        {:error, :not_found}

      {{:error, :enoent}, {:ok, %{"delete_marker" => true}}} ->
        {:error, :not_found}

      {{:ok, %File.Stat{type: :directory}}, {:error, :enoent}} ->
        {:error, :not_found}

      {body, meta} ->
        {:error, {:object_unreadable, body, meta}}
    end
  end

  def delete_object(bucket, key) do
    publish_object(bucket, key, fn ->
      with :ok <- remove_if_present(object_path(bucket, key)),
           :ok <- remove_if_present(object_meta_path(bucket, key)) do
        prune_empty_dirs(Path.dirname(object_path(bucket, key)), objects_dir(bucket))
        prune_empty_dirs(Path.dirname(object_meta_path(bucket, key)), meta_dir(bucket))
        :ok
      end
    end)
  end

  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
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
    with :ok <- check_key_conflict(dest_bucket, dest_key) do
      publish_object(dest_bucket, dest_key, fn ->
        do_copy_object(src_bucket, src_key, dest_bucket, dest_key, replacement)
      end)
    end
  end

  defp do_copy_object(src_bucket, src_key, dest_bucket, dest_key, replacement) do
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

      {:error, reason} ->
        {:error, reason}
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

  ## Versioning
  #
  # The current version of a key stays exactly where an unversioned object
  # lives: content at objects/<key>, metadata at meta/<key>.json. Only
  # superseded versions move into the parallel versions/ trees. That keeps
  # every unversioned code path — reads, listings, bucket_empty? — untouched,
  # and means enabling versioning on a bucket does not rewrite what is already
  # stored.
  #
  # A delete marker is metadata with no content file, so an ordinary read
  # naturally reports not_found.

  def versions_dir(bucket), do: Path.join([bucket_dir(bucket), "versions"])
  def versions_meta_dir(bucket), do: Path.join([bucket_dir(bucket), "versions_meta"])

  # Versions of key "a/b" live under "versions/a/b.d/". The suffix stops the
  # directory holding versions of key "a" from colliding with the directory
  # that has to contain key "a/b".
  defp version_segments(key) do
    List.update_at(Key.key_path(key), -1, &(&1 <> ".d"))
  end

  def version_path(bucket, key, version_id) do
    Path.join([versions_dir(bucket) | version_segments(key)] ++ [version_id])
  end

  def version_meta_path(bucket, key, version_id) do
    Path.join([versions_meta_dir(bucket) | version_segments(key)] ++ [version_id <> ".json"])
  end

  @doc """
  A fresh version id.

  Lexicographically sortable so that ordering by id is ordering by creation
  time, which is what "latest version" and the ListObjectVersions ordering
  both rely on.
  """
  def new_version_id do
    stamp =
      System.os_time(:microsecond)
      |> Integer.to_string()
      |> String.pad_leading(20, "0")

    stamp <> "-" <> unique_suffix()
  end

  def read_current_meta(bucket, key) do
    case read_json(object_meta_path(bucket, key)) do
      {:ok, meta} when is_map(meta) -> meta
      {:error, :enoent} -> nil
      other -> raise FakeS3.StorageError, reason: {:metadata_unreadable, bucket, key, other}
    end
  end

  @doc """
  Moves the current version, if any, into the versions tree.

  In the Suspended state S3 reuses the id "null" for every new version, so an
  existing "null" version is discarded rather than archived — otherwise the
  tree would accumulate several versions all claiming the same id.
  """
  def archive_current(bucket, key) do
    case read_current_meta(bucket, key) do
      nil ->
        :ok

      meta ->
        version_id = meta["version_id"] || "null"
        content_path = object_path(bucket, key)

        if version_id == "null" do
          File.rm(content_path)
        else
          target = version_path(bucket, key, version_id)
          File.mkdir_p(Path.dirname(target))
          File.mkdir_p(Path.dirname(version_meta_path(bucket, key, version_id)))

          # A delete marker has metadata but no content to move.
          if File.regular?(content_path), do: File.rename(content_path, target)
          write_json_atomic(version_meta_path(bucket, key, version_id), meta)
        end

        File.rm(object_meta_path(bucket, key))
        :ok
    end
  end

  @doc "Every stored version of a key, current first, newest to oldest."
  def list_versions(bucket, key) do
    current =
      case read_current_meta(bucket, key) do
        nil -> []
        meta -> [Map.put(meta, "is_latest", true)]
      end

    archived =
      case File.ls(Path.join([versions_meta_dir(bucket) | version_segments(key)])) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&Path.join([versions_meta_dir(bucket) | version_segments(key)] ++ [&1]))
          |> Enum.flat_map(fn path ->
            case read_json(path) do
              {:ok, meta} -> [Map.put(meta, "is_latest", false)]
              _ -> []
            end
          end)

        _ ->
          []
      end

    current ++ Enum.sort_by(archived, &version_seq/1, :desc)
  end

  # Written at microsecond resolution precisely so that two versions created in
  # the same second still order deterministically.
  defp version_seq(meta), do: meta["version_seq"] || 0

  @doc "Reads one specific version: the current one if its id matches, else an archived one."
  def read_version(bucket, key, version_id) do
    current = read_current_meta(bucket, key)

    if current && (current["version_id"] || "null") == version_id do
      read_stored(object_path(bucket, key), current)
    else
      case read_json(version_meta_path(bucket, key, version_id)) do
        {:ok, meta} -> read_stored(version_path(bucket, key, version_id), meta)
        _ -> {:error, :no_such_version}
      end
    end
  end

  defp read_stored(content_path, meta) do
    if meta["delete_marker"] do
      {:ok, %{content_path: nil, meta: meta, stat: nil, delete_marker: true}}
    else
      case File.stat(content_path) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          {:ok, %{content_path: content_path, meta: meta, stat: stat, delete_marker: false}}

        _ ->
          {:error, :no_such_version}
      end
    end
  end

  @doc "Records a delete marker as the current version, archiving whatever it supersedes."
  def put_delete_marker(bucket, key, version_id) do
    archive_current(bucket, key)

    meta = %{
      "key" => key,
      "bucket" => bucket,
      "delete_marker" => true,
      "version_id" => version_id,
      "version_seq" => System.os_time(:microsecond),
      "last_modified" => Time.now_iso()
    }

    write_json_atomic(object_meta_path(bucket, key), meta)
  end

  @doc """
  Permanently removes one version.

  Deleting the current version promotes the newest surviving one back into
  place, so the key does not silently vanish while older versions remain.
  """
  def delete_version(bucket, key, version_id) do
    current = read_current_meta(bucket, key)

    if current && (current["version_id"] || "null") == version_id do
      File.rm(object_path(bucket, key))
      File.rm(object_meta_path(bucket, key))
      promote_latest(bucket, key)
      {:ok, current["delete_marker"] == true}
    else
      case read_json(version_meta_path(bucket, key, version_id)) do
        {:ok, meta} ->
          File.rm(version_path(bucket, key, version_id))
          File.rm(version_meta_path(bucket, key, version_id))
          prune_version_dirs(bucket, key)
          {:ok, meta["delete_marker"] == true}

        _ ->
          {:error, :no_such_version}
      end
    end
  end

  defp promote_latest(bucket, key) do
    case list_versions(bucket, key) do
      [] ->
        prune_object_dirs(bucket, key)
        :ok

      [newest | _] ->
        version_id = newest["version_id"] || "null"
        source = version_path(bucket, key, version_id)
        target = object_path(bucket, key)

        File.mkdir_p(Path.dirname(target))
        File.mkdir_p(Path.dirname(object_meta_path(bucket, key)))

        if File.regular?(source), do: File.rename(source, target)
        write_json_atomic(object_meta_path(bucket, key), newest)
        File.rm(version_meta_path(bucket, key, version_id))
        prune_version_dirs(bucket, key)
        :ok
    end
  end

  defp prune_object_dirs(bucket, key) do
    prune_empty_dirs(Path.dirname(object_path(bucket, key)), objects_dir(bucket))
    prune_empty_dirs(Path.dirname(object_meta_path(bucket, key)), meta_dir(bucket))
  end

  defp prune_version_dirs(bucket, key) do
    prune_empty_dirs(
      Path.join([versions_dir(bucket) | version_segments(key)]),
      versions_dir(bucket)
    )

    prune_empty_dirs(
      Path.join([versions_meta_dir(bucket) | version_segments(key)]),
      versions_meta_dir(bucket)
    )
  end

  @doc "Every key that has any version, current or archived."
  def list_versioned_keys(bucket) do
    from_current = list_keys(bucket) ++ list_meta_keys(bucket)
    from_archive = list_archived_keys(bucket)

    (from_current ++ from_archive) |> Enum.uniq() |> Enum.sort()
  end

  # Delete markers exist only as metadata, so they are invisible to list_keys/1.
  defp list_meta_keys(bucket) do
    dir = meta_dir(bucket)

    case File.dir?(dir) do
      false ->
        []

      true ->
        dir
        |> walk_files()
        |> Enum.map(&(&1 |> Path.relative_to(dir) |> Path.split() |> Enum.join("/")))
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.replace_suffix(&1, ".json", ""))
    end
  end

  defp list_archived_keys(bucket) do
    dir = versions_meta_dir(bucket)

    case File.dir?(dir) do
      false ->
        []

      true ->
        dir
        |> walk_files()
        |> Enum.map(&(&1 |> Path.relative_to(dir) |> Path.split()))
        |> Enum.flat_map(fn segments ->
          # ".../<key last segment>.d/<version_id>.json" back to the key.
          case Enum.split(segments, -2) do
            {prefix, [dir_segment, _file]} ->
              [Enum.join(prefix ++ [String.replace_suffix(dir_segment, ".d", "")], "/")]

            _ ->
              []
          end
        end)
    end
  end

  def list_keys(bucket) do
    dir = objects_dir(bucket)

    dir
    |> walk_files()
    |> Enum.map(fn path ->
      path |> Path.relative_to(dir) |> Path.split() |> Enum.join("/")
    end)
    |> Enum.sort()
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
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      case File.lstat!(path) do
        %File.Stat{type: :directory} -> walk_files(path)
        %File.Stat{type: :regular} -> [path]
        _ -> raise FakeS3.StorageError, reason: {:unexpected_file_type, path}
      end
    end)
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
