defmodule FakeS3.SigV4Test do
  @moduledoc """
  Strict-mode signature verification.

  The canonical URI used to be re-encoded on top of the client's own encoding,
  so every key containing a space or a '%' failed to verify, and presigned
  URLs were not recognised at all.
  """

  use ExUnit.Case, async: true

  import FakeS3.TestServer

  @access_key "strict-access-key"
  @secret_key "strict-secret-key"

  setup do
    FakeS3.TestServer.setup_server(%{
      mode: "strict",
      access_key: @access_key,
      secret_key: @secret_key
    })
  end

  describe "header-signed requests" do
    setup %{endpoint: endpoint} do
      bucket = "strict-#{System.unique_integer([:positive])}"
      req = strict_req(endpoint)
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

      {:ok, bucket: bucket, req: req}
    end

    # Each of these round-trips only if the canonical URI matches what the
    # client signed, byte for byte.
    for {label, key} <- [
          {"plain", "plain.txt"},
          {"space", "a b.txt"},
          {"plus", "we+ird.txt"},
          {"tilde", "til~de.txt"},
          {"literal percent", "pct%20literal.txt"},
          {"unicode", "café.txt"},
          {"nested path", "n/e/s/t/ed.txt"},
          {"equals", "eq=uals.txt"},
          {"ampersand", "amp&ersand.txt"}
        ] do
      test "signs a key with a #{label}", %{req: req, bucket: bucket} do
        key = unquote(key)
        # Encode per segment so path separators stay separators.
        encoded =
          key
          |> String.split("/")
          |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

        url = "s3://#{bucket}/#{encoded}"

        assert %{status: 200} = Req.put!(req, url: url, body: "payload")
        assert %{status: 200, body: "payload"} = Req.get!(req, url: url)
      end
    end

    test "signs a request carrying query parameters", %{req: req, bucket: bucket} do
      resp =
        Req.get!(req,
          url: "s3://#{bucket}",
          params: %{"list-type" => "2", "prefix" => "a b/", "max-keys" => "10"}
        )

      assert resp.status == 200
    end

    test "rejects a wrong secret with SignatureDoesNotMatch", %{
      endpoint: endpoint,
      bucket: bucket
    } do
      req = strict_req(endpoint, secret_access_key: "not-the-secret")
      resp = Req.get!(req, url: "s3://#{bucket}")

      assert resp.status == 403
      assert resp.body =~ "<Code>SignatureDoesNotMatch</Code>"
    end

    test "rejects an unknown access key with InvalidAccessKeyId", %{
      endpoint: endpoint,
      bucket: bucket
    } do
      req = strict_req(endpoint, access_key_id: "someone-else")
      resp = Req.get!(req, url: "s3://#{bucket}")

      assert resp.status == 403
      assert resp.body =~ "<Code>InvalidAccessKeyId</Code>"
    end

    test "rejects an unsigned request with an XML error", %{endpoint: endpoint, bucket: bucket} do
      resp = Req.get!(raw_req(), url: "#{endpoint}/#{bucket}")

      assert resp.status == 403
      assert resp.body =~ "<Code>AccessDenied</Code>"
      assert resp.body =~ "<RequestId>"
    end
  end

  describe "presigned URLs" do
    setup %{endpoint: endpoint} do
      bucket = "presign-#{System.unique_integer([:positive])}"
      req = strict_req(endpoint)
      Req.put!(req, url: "s3://#{bucket}")
      Req.put!(req, url: "s3://#{bucket}/file.txt", body: "presigned payload")

      {:ok, bucket: bucket, req: req}
    end

    test "authorises a GET", %{endpoint: endpoint, bucket: bucket} do
      url = presign(endpoint, bucket, "file.txt")

      # Query-string auth was never parsed, so this was always 403.
      assert %{status: 200, body: "presigned payload"} = Req.get!(raw_req(), url: url)
    end

    test "authorises a PUT", %{endpoint: endpoint, bucket: bucket, req: req} do
      url = presign(endpoint, bucket, "uploaded.txt", method: :put)

      assert %{status: 200} = Req.put!(raw_req(), url: url, body: "via presign")

      assert %{status: 200, body: "via presign"} =
               Req.get!(req, url: "s3://#{bucket}/uploaded.txt")
    end

    test "rejects a tampered signature", %{endpoint: endpoint, bucket: bucket} do
      url = presign(endpoint, bucket, "file.txt") <> "TAMPER"

      resp = Req.get!(raw_req(), url: url)
      assert resp.status == 403
      assert resp.body =~ "<Code>SignatureDoesNotMatch</Code>"
    end

    test "rejects a URL signed in the past", %{endpoint: endpoint, bucket: bucket} do
      url =
        endpoint
        |> presign(bucket, "file.txt")
        |> backdate()

      resp = Req.get!(raw_req(), url: url)

      assert resp.status == 403
      # Specifically the expiry path, not a signature mismatch.
      assert resp.body =~ "signature has expired"
    end
  end

  defp strict_req(endpoint, opts \\ []) do
    s3_req(
      endpoint,
      Keyword.merge([access_key_id: @access_key, secret_access_key: @secret_key], opts)
    )
  end

  defp presign(endpoint, bucket, key, opts \\ []) do
    ReqS3.presign_url(
      [
        access_key_id: @access_key,
        secret_access_key: @secret_key,
        region: "us-east-1",
        endpoint_url: endpoint,
        bucket: bucket,
        key: key
      ] ++ opts
    )
  end

  # Rewrites X-Amz-Date to well before the signed validity window. The expiry
  # check runs ahead of signature verification, so this isolates it.
  defp backdate(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    past =
      DateTime.utc_now()
      |> DateTime.add(-2, :day)
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    uri
    |> Map.put(:query, URI.encode_query(Map.put(query, "X-Amz-Date", past)))
    |> URI.to_string()
  end
end
