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
         :ok <- File.mkdir_p(meta_dir(bucket)) do
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

    with {:ok, entries} <- File.ls(buckets_root) do
      entries
      |> Enum.filter(&File.dir?(Path.join(buckets_root, &1)))
      |> Enum.map(&bucket_meta(&1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.name)
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

  def put_object(bucket, key, fun) do
    content_path = object_path(bucket, key)
    meta_path = object_meta_path(bucket, key)
    File.mkdir_p(Path.dirname(content_path))
    File.mkdir_p(Path.dirname(meta_path))

    temp_path = content_path <> ".tmp-" <> unique_suffix()

    case File.open(temp_path, [:write, :binary]) do
      {:ok, io} ->
        result = fun.(io)
        File.close(io)

        case result do
          {:ok, payload} ->
            File.rename(temp_path, content_path)
            {:ok, meta_path, payload}

          {:error, reason} ->
            File.rm(temp_path)
            {:error, reason}

          other ->
            File.rm(temp_path)
            {:error, other}
        end

      {:error, reason} ->
        File.rm(temp_path)
        {:error, reason}
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

    with true <- File.exists?(content_path),
         {:ok, meta} <- read_json(meta_path),
         {:ok, stat} <- File.stat(content_path) do
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
    :ok
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
          Path.relative_to(path, dir)
        end)
        |> Enum.map(&Path.split/1)
        |> Enum.map(&Enum.join(&1, "/"))
        |> Enum.sort()
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      error -> error
    end
  end

  defp unique_suffix do
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
end
