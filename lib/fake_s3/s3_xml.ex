defmodule FakeS3.S3XML do
  @moduledoc false

  import XmlBuilder, only: [document: 2, document: 3, element: 2, generate: 1]

  def list_buckets(buckets, request_id) do
    document(
      :ListAllMyBucketsResult,
      %{xmlns: "http://s3.amazonaws.com/doc/2006-03-01/"},
      [
        element(:Owner, [element(:ID, "fake"), element(:DisplayName, "fake")]),
        element(:Buckets, Enum.map(buckets, &bucket_xml/1)),
        element(:RequestId, request_id)
      ]
    )
    |> generate()
  end

  def list_objects_v2(bucket, params, contents, common_prefixes, is_truncated, next_token) do
    elements = [
      element(:Name, bucket),
      element(:Prefix, params.prefix),
      element(:KeyCount, Integer.to_string(length(contents))),
      element(:MaxKeys, Integer.to_string(params.max_keys)),
      element(:Delimiter, params.delimiter || ""),
      element(:IsTruncated, if(is_truncated, do: "true", else: "false"))
    ]

    elements =
      if params.token do
        elements ++ [element(:ContinuationToken, params.token)]
      else
        elements
      end

    elements =
      if is_truncated and next_token do
        elements ++ [element(:NextContinuationToken, next_token)]
      else
        elements
      end

    elements =
      elements ++
        Enum.map(contents, &object_xml/1) ++
        Enum.map(common_prefixes, &common_prefix_xml/1)

    document(:ListBucketResult, %{xmlns: "http://s3.amazonaws.com/doc/2006-03-01/"}, elements)
    |> generate()
  end

  def error(code, message, resource, request_id) do
    document(:Error, [
      element(:Code, code),
      element(:Message, message),
      element(:Resource, resource),
      element(:RequestId, request_id)
    ])
    |> generate()
  end

  defp bucket_xml(bucket) do
    element(:Bucket, [
      element(:Name, bucket.name),
      element(:CreationDate, bucket.created_at)
    ])
  end

  defp object_xml(object) do
    element(:Contents, [
      element(:Key, object.key),
      element(:LastModified, object.last_modified),
      element(:ETag, object.etag),
      element(:Size, Integer.to_string(object.size)),
      element(:StorageClass, "STANDARD")
    ])
  end

  defp common_prefix_xml(prefix) do
    element(:CommonPrefixes, [element(:Prefix, prefix)])
  end
end
