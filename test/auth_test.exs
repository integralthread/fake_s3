defmodule FakeS3.AuthTest do
  use ExUnit.Case, async: true

  describe "static auth mode" do
    setup do
      {:ok, endpoint: endpoint, ref: ref, tmp: tmp} =
        start_server(%{
          mode: "static",
          access_key: "test-access-key",
          secret_key: "test-secret-key"
        })

      on_exit(fn ->
        Plug.Cowboy.shutdown(ref)
        File.rm_rf!(tmp)
      end)

      {:ok, endpoint: endpoint}
    end

    test "accepts valid credentials", %{endpoint: endpoint} do
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "test-access-key",
            secret_access_key: "test-secret-key",
            region: "us-east-1"
          ]
        )

      bucket = "static-auth-bucket-#{System.unique_integer([:positive])}"
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")
      assert %{status: 200} = Req.head!(req, url: "s3://#{bucket}")

      # Cleanup
      Req.delete!(req, url: "s3://#{bucket}")
    end

    test "accepts request without auth in static mode (non-strict)", %{endpoint: endpoint} do
      # In static mode (non-strict), missing auth is allowed
      resp = Req.get!(Req.new(), url: "#{endpoint}/__health")
      assert resp.status == 200
    end

    test "rejects wrong access key", %{endpoint: endpoint} do
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "wrong-access-key",
            secret_access_key: "test-secret-key",
            region: "us-east-1"
          ]
        )

      bucket = "wrong-key-bucket-#{System.unique_integer([:positive])}"
      resp = Req.put!(req, url: "s3://#{bucket}")
      assert resp.status == 403
    end
  end

  describe "strict auth mode" do
    setup do
      {:ok, endpoint: endpoint, ref: ref, tmp: tmp} =
        start_server(%{
          mode: "strict",
          access_key: "strict-access-key",
          secret_key: "strict-secret-key"
        })

      on_exit(fn ->
        Plug.Cowboy.shutdown(ref)
        File.rm_rf!(tmp)
      end)

      {:ok, endpoint: endpoint}
    end

    test "accepts valid credentials in strict mode", %{endpoint: endpoint} do
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "strict-access-key",
            secret_access_key: "strict-secret-key",
            region: "us-east-1"
          ]
        )

      bucket = "strict-auth-bucket-#{System.unique_integer([:positive])}"
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}")

      # Cleanup
      Req.delete!(req, url: "s3://#{bucket}")
    end

    test "rejects missing auth in strict mode", %{endpoint: endpoint} do
      # Health endpoint should still work (before auth check happens on bucket routes)
      # But bucket operations without auth should fail
      bucket = "no-auth-bucket-#{System.unique_integer([:positive])}"

      # Raw request without S3 signing
      resp = Req.put!(Req.new(), url: "#{endpoint}/#{bucket}")
      assert resp.status == 403
    end

    test "rejects invalid signature in strict mode", %{endpoint: endpoint} do
      req =
        Req.new(decode_body: false)
        |> ReqS3.attach(
          aws_endpoint_url_s3: endpoint,
          aws_sigv4: [
            access_key_id: "strict-access-key",
            secret_access_key: "wrong-secret-key",
            region: "us-east-1"
          ]
        )

      bucket = "invalid-sig-bucket-#{System.unique_integer([:positive])}"
      resp = Req.put!(req, url: "s3://#{bucket}")
      assert resp.status == 403
    end
  end

  describe "missing credentials error" do
    setup do
      {:ok, endpoint: endpoint, ref: ref, tmp: tmp} =
        start_server(%{mode: "static"})

      on_exit(fn ->
        Plug.Cowboy.shutdown(ref)
        File.rm_rf!(tmp)
      end)

      {:ok, endpoint: endpoint}
    end

    test "returns 500 when credentials not configured", %{endpoint: endpoint} do
      bucket = "nocreds-bucket-#{System.unique_integer([:positive])}"
      resp = Req.put!(Req.new(), url: "#{endpoint}/#{bucket}")
      assert resp.status == 500
      assert resp.body =~ "missing credentials"
    end
  end

  defp start_server(config) do
    tmp =
      System.tmp_dir!()
      |> Path.join("fake_s3_auth_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    ref = :"fake_s3_auth_#{System.unique_integer([:positive])}"

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
