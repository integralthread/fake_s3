defmodule FakeS3.Metadata do
  @moduledoc false

  alias FakeS3.Storage
  alias FakeS3.Time

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
      last_modified: Time.now_iso(),
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
      |> Enum.map(&strip_transfer_encoding/1)
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    user =
      lowered
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-amz-meta-") end)
      |> Map.new()

    {standard, user}
  end

  # aws-chunked describes how the body was framed on the wire, not how the
  # stored object is encoded. Echoing it back on GET would tell the client to
  # un-frame a payload that was already decoded on the way in.
  defp strip_transfer_encoding({"content-encoding", value}) do
    cleaned =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.downcase(&1) == "aws-chunked"))
      |> Enum.join(", ")

    {"content-encoding", cleaned}
  end

  defp strip_transfer_encoding(header), do: header

  def write_object_meta(bucket, key, meta) do
    Storage.write_json_atomic(Storage.object_meta_path(bucket, key), meta)
  end
end
