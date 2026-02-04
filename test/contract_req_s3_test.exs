defmodule FakeS3.ContractReqS3Test do
  use ExUnit.Case, async: false

  setup_all do
    tmp =
      System.tmp_dir!()
      |> Path.join("fake_s3_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    System.put_env("FAKES3_DATA_DIR", tmp)
    System.put_env("FAKES3_MODE", "noauth")

    ref = :"fake_s3_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Plug.Cowboy.http(
        FakeS3.Router,
        [],
        ip: {127, 0, 0, 1},
        port: 0,
        ref: ref
      )

    port = :ranch.get_port(ref)
    endpoint = "http://127.0.0.1:#{port}"

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
      {_, v} -> v
      nil -> nil
    end
  end
end
