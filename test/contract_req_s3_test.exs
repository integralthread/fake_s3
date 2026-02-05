defmodule FakeS3.ContractReqS3Test do
  use ExUnit.Case, async: true

  setup_all do
    {:ok, endpoint: endpoint, ref: ref, tmp: tmp} = start_server(%{mode: "noauth"})

    on_exit(fn ->
      Plug.Cowboy.shutdown(ref)
      File.rm_rf!(tmp)
    end)

    {:ok, endpoint: endpoint}
  end

  test "bucket lifecycle and object CRUD", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")
    assert %{status: 200} = Req.head!(req, url: "s3://#{bucket}")

    assert %{status: 200, headers: headers_put} =
             Req.put!(req, url: "s3://#{bucket}/hello.txt", body: "hello world")

    etag = header_value(headers_put, "etag")
    assert etag != nil

    assert %{status: 200, body: "hello world"} =
             Req.get!(req, url: "s3://#{bucket}/hello.txt")

    assert %{status: 200, headers: headers_head} =
             Req.request!(req, method: :head, url: "s3://#{bucket}/hello.txt")

    assert header_value(headers_head, "etag") == etag

    assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}/hello.txt")
    assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}/hello.txt")

    assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}")
    assert %{status: 404} = Req.head!(req, url: "s3://#{bucket}")
  end

  test "list objects v2 with prefix, delimiter, and continuation", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

    Req.put!(req, url: "s3://#{bucket}/logs/2026/01/a.txt", body: "a")
    Req.put!(req, url: "s3://#{bucket}/logs/2026/01/b.txt", body: "b")
    Req.put!(req, url: "s3://#{bucket}/logs/2026/02/c.txt", body: "c")
    Req.put!(req, url: "s3://#{bucket}/notes.txt", body: "n")

    resp_delim =
      Req.get!(req,
        url: "s3://#{bucket}",
        params: %{
          "list-type" => "2",
          "prefix" => "logs/",
          "delimiter" => "/"
        }
      )

    assert resp_delim.status == 200
    assert resp_delim.body =~ "<CommonPrefixes>"
    assert resp_delim.body =~ "<Prefix>logs/2026/</Prefix>"
    assert resp_delim.body =~ "<IsTruncated>false</IsTruncated>"
    assert resp_delim.body =~ "<KeyCount>1</KeyCount>"

    resp_page1 =
      Req.get!(req,
        url: "s3://#{bucket}",
        params: %{
          "list-type" => "2",
          "prefix" => "logs/",
          "max-keys" => "1"
        }
      )

    assert resp_page1.status == 200
    assert resp_page1.body =~ "<IsTruncated>true</IsTruncated>"

    next_token =
      Regex.run(~r/<NextContinuationToken>([^<]+)<\/NextContinuationToken>/, resp_page1.body)
      |> then(fn
        [_, token] -> token
        _ -> nil
      end)

    assert next_token != nil

    resp2 =
      Req.get!(req,
        url: "s3://#{bucket}",
        params: %{
          "list-type" => "2",
          "prefix" => "logs/",
          "continuation-token" => next_token
        }
      )

    assert resp2.status == 200
    assert resp2.body =~ "<IsTruncated>false</IsTruncated>"

    assert %{status: 409} = Req.delete!(req, url: "s3://#{bucket}")
    Req.delete!(req, url: "s3://#{bucket}/logs/2026/01/a.txt")
    Req.delete!(req, url: "s3://#{bucket}/logs/2026/01/b.txt")
    Req.delete!(req, url: "s3://#{bucket}/logs/2026/02/c.txt")
    Req.delete!(req, url: "s3://#{bucket}/notes.txt")
    assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}")
  end

  test "list buckets returns created bucket", %{endpoint: endpoint} do
    req = s3_req(endpoint)
    bucket = unique_bucket()

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

    resp = Req.get!(req, url: "s3://")
    assert resp.status == 200
    assert resp.body =~ "<Name>#{bucket}</Name>"

    assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}")
  end

  defp s3_req(endpoint) do
    Req.new(decode_body: false)
    |> ReqS3.attach(
      aws_endpoint_url_s3: endpoint,
      aws_sigv4: [
        access_key_id: "test",
        secret_access_key: "test",
        region: "us-east-1"
      ]
    )
  end

  defp unique_bucket do
    "test-bucket-#{System.unique_integer([:positive])}"
  end

  defp header_value(headers, key) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == key end)
    |> case do
      {_, [v | _]} -> v
      {_, v} when is_binary(v) -> v
      nil -> nil
    end
  end

  defp start_server(config) do
    tmp =
      System.tmp_dir!()
      |> Path.join("fake_s3_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    ref = :"fake_s3_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Plug.Cowboy.http(
        FakeS3.Router,
        [config: Map.put(config, :data_dir, tmp)],
        ip: {127, 0, 0, 1},
        port: 0,
        ref: ref
      )

    port = :ranch.get_port(ref)
    endpoint = "http://127.0.0.1:#{port}"

    {:ok, endpoint: endpoint, ref: ref, tmp: tmp}
  end

  test "range requests return partial content", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

    content = "Hello, this is a test file for range requests!"
    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/range.txt", body: content)

    # Request first 5 bytes
    resp = Req.get!(req, url: "s3://#{bucket}/range.txt", headers: [{"range", "bytes=0-4"}])
    assert resp.status == 206
    assert resp.body == "Hello"
    assert header_value(resp.headers, "content-range") == "bytes 0-4/#{byte_size(content)}"

    # Request middle bytes
    resp = Req.get!(req, url: "s3://#{bucket}/range.txt", headers: [{"range", "bytes=7-10"}])
    assert resp.status == 206
    assert resp.body == "this"

    # Request from offset to end ("requests!" is the last 9 chars, starting at index 37)
    resp = Req.get!(req, url: "s3://#{bucket}/range.txt", headers: [{"range", "bytes=37-"}])
    assert resp.status == 206
    assert resp.body == "requests!"

    # Cleanup
    Req.delete!(req, url: "s3://#{bucket}/range.txt")
    Req.delete!(req, url: "s3://#{bucket}")
  end

  test "range suffix request returns tail bytes", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")
    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/range.txt", body: "0123456789")

    resp =
      Req.get!(req,
        url: "s3://#{bucket}/range.txt",
        headers: [{"range", "bytes=-4"}]
      )

    assert resp.status == 206
    assert resp.body == "6789"

    Req.delete!(req, url: "s3://#{bucket}/range.txt")
    Req.delete!(req, url: "s3://#{bucket}")
  end

  test "metadata round-trip with x-amz-meta and standard headers", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

    # Put object with metadata
    put_headers = [
      {"x-amz-meta-custom-key", "custom-value"},
      {"x-amz-meta-another", "another-value"},
      {"cache-control", "max-age=3600"},
      {"content-disposition", "attachment; filename=\"test.txt\""},
      {"content-type", "text/plain; charset=utf-8"}
    ]

    assert %{status: 200} =
             Req.put!(req,
               url: "s3://#{bucket}/meta.txt",
               body: "metadata test",
               headers: put_headers
             )

    # Get object and verify headers
    resp = Req.get!(req, url: "s3://#{bucket}/meta.txt")
    assert resp.status == 200
    assert resp.body == "metadata test"

    assert header_value(resp.headers, "x-amz-meta-custom-key") == "custom-value"
    assert header_value(resp.headers, "x-amz-meta-another") == "another-value"
    assert header_value(resp.headers, "cache-control") == "max-age=3600"
    assert header_value(resp.headers, "content-disposition") == "attachment; filename=\"test.txt\""
    assert header_value(resp.headers, "content-type") == "text/plain; charset=utf-8"

    # Head object also returns metadata
    head_resp = Req.request!(req, method: :head, url: "s3://#{bucket}/meta.txt")
    assert head_resp.status == 200
    assert header_value(head_resp.headers, "x-amz-meta-custom-key") == "custom-value"
    assert header_value(head_resp.headers, "cache-control") == "max-age=3600"

    # Cleanup
    Req.delete!(req, url: "s3://#{bucket}/meta.txt")
    Req.delete!(req, url: "s3://#{bucket}")
  end

  test "copy object operation", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

    # Create source object with metadata
    assert %{status: 200, headers: put_headers} =
             Req.put!(req,
               url: "s3://#{bucket}/source.txt",
               body: "copy me!",
               headers: [{"x-amz-meta-original", "true"}]
             )

    src_etag = header_value(put_headers, "etag")

    # Copy to new key
    copy_resp =
      Req.put!(req,
        url: "s3://#{bucket}/dest.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/source.txt"}]
      )

    assert copy_resp.status == 200
    assert copy_resp.body =~ "<CopyObjectResult"
    # ETag quotes are XML-escaped as &quot;
    etag_unquoted = String.trim(src_etag, "\"")
    assert copy_resp.body =~ "<ETag>&quot;#{etag_unquoted}&quot;</ETag>"

    # Verify copied object
    get_resp = Req.get!(req, url: "s3://#{bucket}/dest.txt")
    assert get_resp.status == 200
    assert get_resp.body == "copy me!"
    assert header_value(get_resp.headers, "etag") == src_etag

    # Copy to different bucket
    bucket2 = unique_bucket()
    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket2}")

    copy_resp2 =
      Req.put!(req,
        url: "s3://#{bucket2}/cross-bucket.txt",
        headers: [{"x-amz-copy-source", "#{bucket}/source.txt"}]
      )

    assert copy_resp2.status == 200

    get_resp2 = Req.get!(req, url: "s3://#{bucket2}/cross-bucket.txt")
    assert get_resp2.status == 200
    assert get_resp2.body == "copy me!"

    # Copy non-existent source returns 404
    copy_resp3 =
      Req.put!(req,
        url: "s3://#{bucket}/missing-copy.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/nonexistent.txt"}]
      )

    assert copy_resp3.status == 404
    assert copy_resp3.body =~ "<Code>NoSuchKey</Code>"

    # Cleanup
    Req.delete!(req, url: "s3://#{bucket}/source.txt")
    Req.delete!(req, url: "s3://#{bucket}/dest.txt")
    Req.delete!(req, url: "s3://#{bucket}")
    Req.delete!(req, url: "s3://#{bucket2}/cross-bucket.txt")
    Req.delete!(req, url: "s3://#{bucket2}")
  end

  test "debug endpoint lists all objects", %{endpoint: endpoint} do
    bucket = unique_bucket()
    req = s3_req(endpoint)

    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")
    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/a.txt", body: "a")
    assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/b.txt", body: "bb")

    debug_resp = Req.get!(Req.new(decode_body: false), url: "#{endpoint}/__debug/objects")
    assert debug_resp.status == 200

    objects = Jason.decode!(debug_resp.body)

    bucket_objects = Enum.filter(objects, &(&1["bucket"] == bucket))
    assert length(bucket_objects) == 2

    keys = Enum.map(bucket_objects, & &1["key"]) |> Enum.sort()
    assert keys == ["a.txt", "b.txt"]

    # Cleanup
    Req.delete!(req, url: "s3://#{bucket}/a.txt")
    Req.delete!(req, url: "s3://#{bucket}/b.txt")
    Req.delete!(req, url: "s3://#{bucket}")
  end
end
