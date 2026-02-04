defmodule FakeS3.Metadata do
  @moduledoc false

  alias FakeS3.Storage

  @standard_headers [
    "cache-control",
    "content-encoding",
    "content-disposition",
    "content-language"
  ]

  def build_object_meta(bucket, key, size, etag, content_type, headers, user_meta) do
    %{
      key: key,
      bucket: bucket,
      size: size,
      etag: etag,
      last_modified: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      content_type: content_type,
      headers: headers,
      user_metadata: user_meta
    }
  end

  def extract_headers(req_headers) do
    lowered = Enum.map(req_headers, fn {k, v} -> {String.downcase(k), v} end)

    standard =
      lowered
      |> Enum.filter(fn {k, _} -> k in @standard_headers end)
      |> Map.new()

    user =
      lowered
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-amz-meta-") end)
      |> Map.new()

    {standard, user}
  end

  def write_object_meta(bucket, key, meta) do
    Storage.write_json_atomic(Storage.object_meta_path(bucket, key), meta)
  end
end
