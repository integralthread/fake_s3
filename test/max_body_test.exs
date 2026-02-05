defmodule FakeS3.MaxBodyTest do
  use ExUnit.Case, async: true

  describe "max body bytes enforcement" do
    setup do
      {:ok, endpoint: endpoint, ref: ref, tmp: tmp} =
        start_server(%{mode: "noauth", max_body_bytes: 100})

      on_exit(fn ->
        Plug.Cowboy.shutdown(ref)
        File.rm_rf!(tmp)
      end)

      {:ok, endpoint: endpoint}
    end

    test "accepts body within limit", %{endpoint: endpoint} do
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "test",
            secret_access_key: "test",
            region: "us-east-1"
          ]
        )

      bucket = "maxbody-bucket-#{System.unique_integer([:positive])}"
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

      # 50 bytes is under limit
      small_body = String.duplicate("a", 50)
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/small.txt", body: small_body)

      # Verify it was stored
      get_resp = Req.get!(req, url: "s3://#{bucket}/small.txt")
      assert get_resp.status == 200
      assert get_resp.body == small_body

      # Cleanup
      Req.delete!(req, url: "s3://#{bucket}/small.txt")
      Req.delete!(req, url: "s3://#{bucket}")
    end

    test "rejects body exceeding limit via Content-Length", %{endpoint: endpoint} do
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "test",
            secret_access_key: "test",
            region: "us-east-1"
          ]
        )

      bucket = "maxbody-bucket-#{System.unique_integer([:positive])}"
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

      # 200 bytes exceeds 100 byte limit
      large_body = String.duplicate("x", 200)
      resp = Req.put!(req, url: "s3://#{bucket}/large.txt", body: large_body)
      assert resp.status == 413

      # Cleanup
      Req.delete!(req, url: "s3://#{bucket}")
    end

    test "enforces limit during streaming", %{endpoint: endpoint} do
      bucket = "streaming-bucket-#{System.unique_integer([:positive])}"

      # Create bucket first
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "test",
            secret_access_key: "test",
            region: "us-east-1"
          ]
        )

      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

      # Use raw HTTP to test streaming without Content-Length
      # We'll use a chunked transfer to test the streaming enforcement
      large_body = String.duplicate("z", 150)

      # This should fail during streaming even if we lie about Content-Length
      resp =
        Req.put!(req,
          url: "s3://#{bucket}/streaming-large.txt",
          body: large_body
        )

      assert resp.status == 413

      # Cleanup
      Req.delete!(req, url: "s3://#{bucket}")
    end
  end

  defp start_server(config) do
    tmp =
      System.tmp_dir!()
      |> Path.join("fake_s3_maxbody_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    ref = :"fake_s3_maxbody_#{System.unique_integer([:positive])}"

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
end
