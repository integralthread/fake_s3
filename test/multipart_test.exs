defmodule FakeS3.MultipartTest do
  @moduledoc """
  Multipart upload, which the AWS CLI reaches for on any file over 8 MB.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  @part_a String.duplicate("a", 1024)
  @part_b String.duplicate("b", 512)

  setup %{endpoint: endpoint} do
    {:ok, bucket: create_bucket!(endpoint), key: "multi/object.bin"}
  end

  test "assembles parts in order", ctx do
    upload_id = create_upload(ctx)

    etag_a = upload_part(ctx, upload_id, 1, @part_a)
    etag_b = upload_part(ctx, upload_id, 2, @part_b)

    resp = complete(ctx, upload_id, [{1, etag_a}, {2, etag_b}])
    assert resp.status == 200
    assert resp.body =~ "<CompleteMultipartUploadResult"

    got = Req.get!(raw_req(), url: object_url(ctx))
    assert got.body == @part_a <> @part_b
    assert header_value(got.headers, "content-length") == "#{byte_size(@part_a <> @part_b)}"
  end

  test "produces an S3-style composite ETag", ctx do
    upload_id = create_upload(ctx)
    etag_a = upload_part(ctx, upload_id, 1, @part_a)
    etag_b = upload_part(ctx, upload_id, 2, @part_b)

    complete(ctx, upload_id, [{1, etag_a}, {2, etag_b}])

    expected =
      [@part_a, @part_b]
      |> Enum.map(&:crypto.hash(:md5, &1))
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)
      |> then(&"\"#{&1}-2\"")

    got = Req.request!(raw_req(), method: :head, url: object_url(ctx))
    assert header_value(got.headers, "etag") == expected
  end

  test "carries the content type from creation", ctx do
    upload_id = create_upload(ctx, [{"content-type", "application/x-custom"}])
    etag = upload_part(ctx, upload_id, 1, @part_a)
    complete(ctx, upload_id, [{1, etag}])

    got = Req.request!(raw_req(), method: :head, url: object_url(ctx))
    assert header_value(got.headers, "content-type") == "application/x-custom"
  end

  test "lists staged parts", ctx do
    upload_id = create_upload(ctx)
    upload_part(ctx, upload_id, 1, @part_a)
    upload_part(ctx, upload_id, 2, @part_b)

    resp = Req.get!(raw_req(), url: object_url(ctx) <> "?uploadId=#{upload_id}")

    assert resp.status == 200
    assert xml_values(resp.body, "PartNumber") == ~w(1 2)
    assert xml_values(resp.body, "Size") == ["#{byte_size(@part_a)}", "#{byte_size(@part_b)}"]
  end

  test "lists uploads in progress", ctx do
    upload_id = create_upload(ctx)

    resp = Req.get!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?uploads")

    assert resp.status == 200
    assert xml_values(resp.body, "UploadId") == [upload_id]
  end

  test "abort discards the staging directory", ctx do
    upload_id = create_upload(ctx)
    upload_part(ctx, upload_id, 1, @part_a)

    assert %{status: 204} =
             Req.delete!(raw_req(), url: object_url(ctx) <> "?uploadId=#{upload_id}")

    staging = Path.join([ctx.data_dir, "buckets", ctx.bucket, "uploads"])
    assert File.ls(staging) in [{:ok, []}, {:error, :enoent}]

    assert %{status: 404} = Req.get!(raw_req(), url: object_url(ctx))
  end

  test "completing clears staging", ctx do
    upload_id = create_upload(ctx)
    etag = upload_part(ctx, upload_id, 1, @part_a)
    complete(ctx, upload_id, [{1, etag}])

    staging = Path.join([ctx.data_dir, "buckets", ctx.bucket, "uploads"])
    assert File.ls(staging) in [{:ok, []}, {:error, :enoent}]
  end

  test "rejects parts listed out of order", ctx do
    upload_id = create_upload(ctx)
    etag_a = upload_part(ctx, upload_id, 1, @part_a)
    etag_b = upload_part(ctx, upload_id, 2, @part_b)

    resp = complete(ctx, upload_id, [{2, etag_b}, {1, etag_a}])

    assert resp.status == 400
    assert resp.body =~ "<Code>InvalidPartOrder</Code>"
  end

  test "rejects a part whose ETag does not match", ctx do
    upload_id = create_upload(ctx)
    upload_part(ctx, upload_id, 1, @part_a)

    resp = complete(ctx, upload_id, [{1, "\"deadbeef\""}])

    assert resp.status == 400
    assert resp.body =~ "<Code>InvalidPart</Code>"
  end

  test "rejects a part that was never uploaded", ctx do
    upload_id = create_upload(ctx)
    etag = upload_part(ctx, upload_id, 1, @part_a)

    resp = complete(ctx, upload_id, [{1, etag}, {2, "\"whatever\""}])

    assert resp.status == 400
    assert resp.body =~ "<Code>InvalidPart</Code>"
  end

  test "404s for an unknown upload id", ctx do
    assert %{status: 404, body: body} =
             Req.put!(raw_req(),
               url: object_url(ctx) <> "?partNumber=1&uploadId=does-not-exist",
               body: @part_a
             )

    assert body =~ "<Code>NoSuchUpload</Code>"
  end

  test "rejects an invalid part number", ctx do
    upload_id = create_upload(ctx)

    assert %{status: 400} =
             Req.put!(raw_req(),
               url: object_url(ctx) <> "?partNumber=0&uploadId=#{upload_id}",
               body: @part_a
             )
  end

  defp create_upload(ctx, headers \\ []) do
    resp = Req.post!(raw_req(), url: object_url(ctx) <> "?uploads", headers: headers, body: "")

    assert resp.status == 200
    [upload_id] = xml_values(resp.body, "UploadId")
    upload_id
  end

  defp upload_part(ctx, upload_id, number, body) do
    resp =
      Req.put!(raw_req(),
        url: object_url(ctx) <> "?partNumber=#{number}&uploadId=#{upload_id}",
        body: body
      )

    assert resp.status == 200
    header_value(resp.headers, "etag")
  end

  defp complete(ctx, upload_id, parts) do
    body =
      parts
      |> Enum.map_join(fn {number, etag} ->
        "<Part><PartNumber>#{number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)
      |> then(&"<CompleteMultipartUpload>#{&1}</CompleteMultipartUpload>")

    Req.post!(raw_req(), url: object_url(ctx) <> "?uploadId=#{upload_id}", body: body)
  end

  defp object_url(ctx), do: "#{ctx.endpoint}/#{ctx.bucket}/#{ctx.key}"
end
