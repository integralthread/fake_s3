defmodule FakeS3.S3XML do
  @moduledoc false

  import XmlBuilder, only: [document: 2, document: 3, element: 2, generate: 1]

  alias FakeS3.Time

  @xmlns "http://s3.amazonaws.com/doc/2006-03-01/"

  def list_buckets(buckets, request_id) do
    document(
      :ListAllMyBucketsResult,
      %{xmlns: @xmlns},
      [
        element(:Owner, [element(:ID, "fake"), element(:DisplayName, "fake")]),
        element(:Buckets, Enum.map(buckets, &bucket_xml/1)),
        element(:RequestId, request_id)
      ]
    )
    |> generate()
  end

  def list_objects_v2(bucket, params, contents, common_prefixes, is_truncated, next_token) do
    enc = params.encoding_type
    key_count = length(contents) + length(common_prefixes)

    elements =
      [
        element(:Name, bucket),
        element(:Prefix, encode(params.prefix, enc)),
        element(:KeyCount, Integer.to_string(key_count)),
        element(:MaxKeys, Integer.to_string(params.max_keys)),
        element(:Delimiter, encode(params.delimiter || "", enc)),
        element(:IsTruncated, boolean(is_truncated))
      ]
      |> maybe_append(params.token, &element(:ContinuationToken, &1))
      |> maybe_append(is_truncated && next_token, &element(:NextContinuationToken, &1))
      |> maybe_append(params.start_after, &element(:StartAfter, encode(&1, enc)))
      |> maybe_append(enc, &element(:EncodingType, &1))

    elements =
      elements ++
        Enum.map(contents, &object_xml(&1, enc)) ++
        Enum.map(common_prefixes, &common_prefix_xml(&1, enc))

    document(:ListBucketResult, %{xmlns: @xmlns}, elements)
    |> generate()
  end

  def list_objects_v1(bucket, params, contents, common_prefixes, is_truncated, next_marker) do
    enc = params.encoding_type

    elements =
      [
        element(:Name, bucket),
        element(:Prefix, encode(params.prefix, enc)),
        element(:Marker, encode(params.marker || "", enc)),
        element(:MaxKeys, Integer.to_string(params.max_keys)),
        element(:Delimiter, encode(params.delimiter || "", enc)),
        element(:IsTruncated, boolean(is_truncated))
      ]
      |> maybe_append(is_truncated && next_marker, &element(:NextMarker, encode(&1, enc)))
      |> maybe_append(enc, &element(:EncodingType, &1))

    elements =
      elements ++
        Enum.map(contents, &object_xml(&1, enc)) ++
        Enum.map(common_prefixes, &common_prefix_xml(&1, enc))

    document(:ListBucketResult, %{xmlns: @xmlns}, elements)
    |> generate()
  end

  # FakeS3 does not store versions, so every key is reported as a single latest
  # version with the "null" version id S3 uses for unversioned buckets.
  def list_object_versions(
        bucket,
        params,
        versions,
        delete_markers,
        common_prefixes,
        is_truncated,
        next_marker
      ) do
    enc = params.encoding_type

    elements =
      [
        element(:Name, bucket),
        element(:Prefix, encode(params.prefix, enc)),
        element(:KeyMarker, encode(params.marker || "", enc)),
        element(:VersionIdMarker, ""),
        element(:MaxKeys, Integer.to_string(params.max_keys)),
        element(:Delimiter, encode(params.delimiter || "", enc)),
        element(:IsTruncated, boolean(is_truncated))
      ]
      |> maybe_append(is_truncated && next_marker, &element(:NextKeyMarker, encode(&1, enc)))
      |> maybe_append(is_truncated && next_marker, fn _ ->
        element(:NextVersionIdMarker, "null")
      end)
      |> maybe_append(enc, &element(:EncodingType, &1))

    elements =
      elements ++
        Enum.map(versions, &version_xml(&1, enc)) ++
        Enum.map(delete_markers, &delete_marker_xml(&1, enc)) ++
        Enum.map(common_prefixes, &common_prefix_xml(&1, enc))

    document(:ListVersionsResult, %{xmlns: @xmlns}, elements)
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

  def copy_object_result(etag, last_modified) do
    document(:CopyObjectResult, %{xmlns: @xmlns}, [
      element(:ETag, etag),
      element(:LastModified, Time.to_xml(last_modified))
    ])
    |> generate()
  end

  def delete_result(deleted, errors, quiet?) do
    deleted_elements =
      if quiet? do
        []
      else
        Enum.map(deleted, fn key -> element(:Deleted, [element(:Key, key)]) end)
      end

    error_elements =
      Enum.map(errors, fn {key, code, message} ->
        element(:Error, [
          element(:Key, key),
          element(:Code, code),
          element(:Message, message)
        ])
      end)

    document(:DeleteResult, %{xmlns: @xmlns}, deleted_elements ++ error_elements)
    |> generate()
  end

  def location_constraint(region) do
    # us-east-1 is represented by an empty constraint, matching real S3.
    value = if region == "us-east-1", do: "", else: region

    document(:LocationConstraint, %{xmlns: @xmlns}, value)
    |> generate()
  end

  # An unconfigured bucket reports an empty document rather than a status, which
  # is how clients tell "never enabled" from "enabled then suspended".
  def versioning_configuration(status \\ nil)

  def versioning_configuration(nil) do
    document(:VersioningConfiguration, %{xmlns: @xmlns}, [])
    |> generate()
  end

  def versioning_configuration(status) do
    document(:VersioningConfiguration, %{xmlns: @xmlns}, [element(:Status, status)])
    |> generate()
  end

  def access_control_policy do
    document(:AccessControlPolicy, %{xmlns: @xmlns}, [
      element(:Owner, [element(:ID, "fake"), element(:DisplayName, "fake")]),
      element(:AccessControlList, [
        element(:Grant, [
          element(:Grantee, [element(:ID, "fake"), element(:DisplayName, "fake")]),
          element(:Permission, "FULL_CONTROL")
        ])
      ])
    ])
    |> generate()
  end

  def initiate_multipart_upload_result(bucket, key, upload_id) do
    document(:InitiateMultipartUploadResult, %{xmlns: @xmlns}, [
      element(:Bucket, bucket),
      element(:Key, key),
      element(:UploadId, upload_id)
    ])
    |> generate()
  end

  def complete_multipart_upload_result(location, bucket, key, etag) do
    document(:CompleteMultipartUploadResult, %{xmlns: @xmlns}, [
      element(:Location, location),
      element(:Bucket, bucket),
      element(:Key, key),
      element(:ETag, etag)
    ])
    |> generate()
  end

  def list_parts_result(bucket, key, upload_id, parts) do
    elements =
      [
        element(:Bucket, bucket),
        element(:Key, key),
        element(:UploadId, upload_id),
        element(:PartNumberMarker, "0"),
        element(:MaxParts, "1000"),
        element(:IsTruncated, "false")
      ] ++
        Enum.map(parts, fn part ->
          element(:Part, [
            element(:PartNumber, Integer.to_string(part.part_number)),
            element(:LastModified, Time.to_xml(part.last_modified)),
            element(:ETag, part.etag),
            element(:Size, Integer.to_string(part.size))
          ])
        end)

    document(:ListPartsResult, %{xmlns: @xmlns}, elements)
    |> generate()
  end

  def list_multipart_uploads_result(bucket, uploads) do
    elements =
      [
        element(:Bucket, bucket),
        element(:KeyMarker, ""),
        element(:UploadIdMarker, ""),
        element(:MaxUploads, "1000"),
        element(:IsTruncated, "false")
      ] ++
        Enum.map(uploads, fn upload ->
          element(:Upload, [
            element(:Key, upload.key),
            element(:UploadId, upload.upload_id),
            element(:Initiated, Time.to_xml(upload.initiated))
          ])
        end)

    document(:ListMultipartUploadsResult, %{xmlns: @xmlns}, elements)
    |> generate()
  end

  defp bucket_xml(bucket) do
    element(:Bucket, [
      element(:Name, bucket.name),
      element(:CreationDate, Time.to_xml(bucket.created_at))
    ])
  end

  defp object_xml(object, enc) do
    element(:Contents, [
      element(:Key, encode(object.key, enc)),
      element(:LastModified, Time.to_xml(object.last_modified)),
      element(:ETag, object.etag),
      element(:Size, Integer.to_string(object.size)),
      element(:StorageClass, "STANDARD")
    ])
  end

  defp version_xml(object, enc) do
    element(:Version, [
      element(:Key, encode(object.key, enc)),
      element(:VersionId, object.version_id),
      element(:IsLatest, boolean(object.is_latest)),
      element(:LastModified, Time.to_xml(object.last_modified)),
      element(:ETag, object.etag),
      element(:Size, Integer.to_string(object.size)),
      element(:StorageClass, "STANDARD"),
      element(:Owner, [element(:ID, "fake"), element(:DisplayName, "fake")])
    ])
  end

  defp delete_marker_xml(marker, enc) do
    element(:DeleteMarker, [
      element(:Key, encode(marker.key, enc)),
      element(:VersionId, marker.version_id),
      element(:IsLatest, boolean(marker.is_latest)),
      element(:LastModified, Time.to_xml(marker.last_modified)),
      element(:Owner, [element(:ID, "fake"), element(:DisplayName, "fake")])
    ])
  end

  defp common_prefix_xml(prefix, enc) do
    element(:CommonPrefixes, [element(:Prefix, encode(prefix, enc))])
  end

  defp maybe_append(elements, value, _fun) when value in [nil, false], do: elements
  defp maybe_append(elements, value, fun), do: elements ++ [fun.(value)]

  defp boolean(true), do: "true"
  defp boolean(_), do: "false"

  # When a client asks for encoding-type=url it will percent-decode every key
  # it reads back. Returning raw keys corrupts any key containing a '+' or '%'.
  defp encode(value, "url") when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp encode(value, _), do: value
end
