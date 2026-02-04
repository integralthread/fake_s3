defmodule FakeS3.Key do
  @moduledoc false

  @bucket_regex ~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/

  def valid_bucket?(bucket) when is_binary(bucket) do
    case Regex.match?(@bucket_regex, bucket) do
      false -> false
      true -> not String.contains?(bucket, "..")
    end
  end

  def safe_key(key) when is_binary(key) do
    segments = String.split(key, "/", trim: false)

    if Enum.any?(segments, &(&1 == "..")) do
      {:error, :invalid_key}
    else
      {:ok, key}
    end
  end

  def key_path(key) do
    String.split(key, "/", trim: false)
  end
end
