defmodule FakeS3.ObjectResponseTest do
  @moduledoc """
  Covers the response headers and Range semantics that clients actually parse.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  @body "hello world"

  setup %{endpoint: endpoint} do
    bucket = create_bucket!(endpoint)
    req = s3_req(endpoint)
    Req.put!(req, url: "s3://#{bucket}/obj.txt", body: @body)

    {:ok, bucket: bucket, req: req}
  end

  describe "HEAD object" do
    test "reports the object size, not zero", %{req: req, bucket: bucket} do
      head = Req.request!(req, method: :head, url: "s3://#{bucket}/obj.txt")
      get = Req.get!(req, url: "s3://#{bucket}/obj.txt")

      expected = Integer.to_string(byte_size(@body))

      # send_resp/3 with an empty body made the adapter report 0 here, so
      # anything sizing an object via HEAD saw nothing.
      assert header_value(head.headers, "content-length") == expected
      assert header_value(get.headers, "content-length") == expected
      assert header_value(head.headers, "etag") == header_value(get.headers, "etag")
    end

    test "carries the same metadata as GET", %{req: req, bucket: bucket} do
      Req.put!(req,
        url: "s3://#{bucket}/meta.txt",
        body: @body,
        headers: [{"x-amz-meta-colour", "green"}, {"cache-control", "max-age=60"}]
      )

      head = Req.request!(req, method: :head, url: "s3://#{bucket}/meta.txt")

      assert header_value(head.headers, "x-amz-meta-colour") == "green"
      assert header_value(head.headers, "cache-control") == "max-age=60"
    end

    test "404s for a missing key", %{req: req, bucket: bucket} do
      assert %{status: 404} = Req.request!(req, method: :head, url: "s3://#{bucket}/nope.txt")
    end
  end

  describe "response headers" do
    test "Last-Modified is an RFC 7231 HTTP-date", %{req: req, bucket: bucket} do
      resp = Req.get!(req, url: "s3://#{bucket}/obj.txt")
      last_modified = header_value(resp.headers, "last-modified")

      # Used to emit ISO 8601, which is not valid in an HTTP date header.
      assert last_modified =~
               ~r/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} GMT$/

      assert {:ok, _} = parse_http_date(last_modified)
    end

    test "advertises range support", %{req: req, bucket: bucket} do
      resp = Req.get!(req, url: "s3://#{bucket}/obj.txt")
      assert header_value(resp.headers, "accept-ranges") == "bytes"
    end

    test "does not echo aws-chunked back as a content encoding", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)

      raw_req()
      |> Req.put!(
        url: "#{endpoint}/#{bucket}/chunked.txt",
        headers: [
          {"content-encoding", "aws-chunked"},
          {"x-amz-decoded-content-length", "11"}
        ],
        body: "b\r\nhello world\r\n0\r\n\r\n"
      )

      resp = Req.get!(raw_req(), url: "#{endpoint}/#{bucket}/chunked.txt")

      assert resp.body == @body
      assert header_value(resp.headers, "content-encoding") == nil
    end
  end

  describe "Range requests" do
    test "serves a byte range", %{req: req, bucket: bucket} do
      resp =
        Req.get!(req, url: "s3://#{bucket}/obj.txt", headers: [{"range", "bytes=0-4"}])

      assert resp.status == 206
      assert resp.body == "hello"
      assert header_value(resp.headers, "content-range") == "bytes 0-4/11"
    end

    test "clamps a range that runs past the end", %{req: req, bucket: bucket} do
      resp =
        Req.get!(req, url: "s3://#{bucket}/obj.txt", headers: [{"range", "bytes=6-9999"}])

      assert resp.status == 206
      assert resp.body == "world"
      assert header_value(resp.headers, "content-range") == "bytes 6-10/11"
    end

    test "serves a suffix range", %{req: req, bucket: bucket} do
      resp = Req.get!(req, url: "s3://#{bucket}/obj.txt", headers: [{"range", "bytes=-5"}])

      assert resp.status == 206
      assert resp.body == "world"
    end

    test "416s when the range starts past the end", %{req: req, bucket: bucket} do
      resp =
        Req.get!(req, url: "s3://#{bucket}/obj.txt", headers: [{"range", "bytes=9999-99999"}])

      # Used to answer 200 with the whole object.
      assert resp.status == 416
      assert resp.body =~ "<Code>InvalidRange</Code>"
      assert header_value(resp.headers, "content-range") == "bytes */11"
    end

    test "ignores a malformed range instead of crashing", %{req: req, bucket: bucket} do
      # String.to_integer/1 used to raise here and surface as a 500.
      resp = Req.get!(req, url: "s3://#{bucket}/obj.txt", headers: [{"range", "bytes=0-abc"}])

      assert resp.status == 200
      assert resp.body == @body
    end

    test "ignores a range with an unknown unit", %{req: req, bucket: bucket} do
      resp = Req.get!(req, url: "s3://#{bucket}/obj.txt", headers: [{"range", "lines=1-2"}])

      assert resp.status == 200
      assert resp.body == @body
    end

    test "416s on a zero-byte object", %{req: req, bucket: bucket} do
      Req.put!(req, url: "s3://#{bucket}/empty.txt", body: "")

      resp = Req.get!(req, url: "s3://#{bucket}/empty.txt", headers: [{"range", "bytes=0-0"}])
      assert resp.status == 416
    end
  end

  defp parse_http_date(value) do
    case Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/, value) do
      [_, d, mon, y, h, mi, s] ->
        months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
        month = Enum.find_index(months, &(&1 == mon)) + 1

        NaiveDateTime.new(
          String.to_integer(y),
          month,
          String.to_integer(d),
          String.to_integer(h),
          String.to_integer(mi),
          String.to_integer(s)
        )

      _ ->
        :error
    end
  end
end
