defmodule FakeS3.PostObjectTest do
  @moduledoc """
  Browser form uploads: `POST /<bucket>` with `multipart/form-data`, including
  the base64 policy document that constrains what the form may contain.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  setup %{endpoint: endpoint} do
    {:ok, bucket: create_bucket!(endpoint), req: s3_req(endpoint), endpoint: endpoint}
  end

  describe "uploading" do
    test "stores the object and answers 204 by default", ctx do
      resp = post(ctx, key: "foo.txt", file: {"bar", filename: "f.txt"})

      assert resp.status == 204
      assert get(ctx, "foo.txt").body == "bar"
    end

    test "${filename} is replaced with the uploaded file's name", ctx do
      resp = post(ctx, key: "${filename}", file: {"bar", filename: "foo.txt"})

      assert resp.status == 204
      assert get(ctx, "foo.txt").body == "bar"
    end

    test "a missing key field is a 400", ctx do
      resp = post(ctx, file: {"bar", filename: "f.txt"})

      assert resp.status == 400
      assert resp.body =~ "<Code>InvalidArgument</Code>"
    end

    test "Content-Type and x-amz-meta-* are stored", ctx do
      post(ctx,
        key: "foo.txt",
        "Content-Type": "text/plain",
        "x-amz-meta-colour": "blue",
        file: {"bar", filename: "f.txt"}
      )

      resp = get(ctx, "foo.txt")

      assert header_value(resp.headers, "content-type") == "text/plain"
      assert header_value(resp.headers, "x-amz-meta-colour") == "blue"
    end

    test "success_action_status=201 returns un-namespaced PostResponse XML", ctx do
      resp = post(ctx, key: "foo.txt", success_action_status: "201", file: {"bar", filename: "f"})

      assert resp.status == 201
      # No xmlns: a plain find("Key") has to work for browser-side code.
      refute resp.body =~ "xmlns"
      assert xml_values(resp.body, "Key") == ["foo.txt"]
    end

    test "an unrecognised success_action_status falls back to 204", ctx do
      resp = post(ctx, key: "foo.txt", success_action_status: "404", file: {"bar", filename: "f"})

      assert resp.status == 204
      assert resp.body == ""
    end

    test "success_action_redirect returns 303 with bucket, key and etag in order", ctx do
      resp =
        post(ctx,
          key: "foo.txt",
          success_action_redirect: "http://example.test/done",
          file: {"bar", filename: "f"}
        )

      assert resp.status == 303
      location = header_value(resp.headers, "location")

      # Order matters: S3 appends bucket, key, then etag.
      assert location =~
               ~r{^http://example\.test/done\?bucket=[^&]+&key=foo\.txt&etag=%22[a-f0-9]+%22$}
    end
  end

  describe "policy conditions" do
    test "a satisfied policy is accepted", ctx do
      policy = policy([%{"bucket" => ctx.bucket}, ["starts-with", "$key", "foo"]])

      resp = post(ctx, key: "foo.txt", policy: policy, file: {"bar", filename: "f"})

      assert resp.status == 204
    end

    test "a field the policy never mentions is refused", ctx do
      policy = policy([%{"bucket" => ctx.bucket}, ["starts-with", "$key", "foo"]])

      resp =
        post(ctx, key: "foo.txt", policy: policy, acl: "private", file: {"bar", filename: "f"})

      assert resp.status == 403
    end

    test "x-ignore-* fields need no condition", ctx do
      policy = policy([%{"bucket" => ctx.bucket}, ["starts-with", "$key", "foo"]])

      resp =
        post(ctx,
          key: "foo.txt",
          policy: policy,
          "x-ignore-note": "hi",
          file: {"bar", filename: "f"}
        )

      assert resp.status == 204
    end

    test "a condition the form does not satisfy is refused", ctx do
      policy = policy([%{"bucket" => ctx.bucket}, ["starts-with", "$key", "other"]])

      resp = post(ctx, key: "foo.txt", policy: policy, file: {"bar", filename: "f"})

      assert resp.status == 403
    end

    test "operators and field names are case-insensitive", ctx do
      policy = policy([%{"bUcKeT" => ctx.bucket}, ["StArTs-WiTh", "$KeY", "foo"]])

      resp = post(ctx, key: "foo.txt", policy: policy, file: {"bar", filename: "f"})

      assert resp.status == 204
    end

    test "${filename} is resolved before conditions are checked", ctx do
      policy = policy([%{"bucket" => ctx.bucket}, ["starts-with", "$key", "foo"]])

      # The submitted key is "${filename}", which does not start with "foo";
      # the resolved one does, and that is what S3 evaluates.
      resp = post(ctx, key: "${filename}", policy: policy, file: {"bar", filename: "foo.txt"})

      assert resp.status == 204
    end

    test "an expired policy is refused", ctx do
      policy = policy([%{"bucket" => ctx.bucket}], -600)

      resp = post(ctx, key: "foo.txt", policy: policy, file: {"bar", filename: "f"})

      assert resp.status == 403
    end

    test "content-length-range is enforced", ctx do
      policy =
        policy([
          %{"bucket" => ctx.bucket},
          ["starts-with", "$key", "foo"],
          ["content-length-range", 0, 2]
        ])

      resp = post(ctx, key: "foo.txt", policy: policy, file: {"too long", filename: "f"})

      assert resp.status == 400
      assert resp.body =~ "<Code>EntityTooLarge</Code>"
    end
  end

  describe "malformed policies" do
    test "a policy that is not base64 is rejected", ctx do
      resp = post(ctx, key: "foo.txt", policy: "!!!not base64!!!", file: {"bar", filename: "f"})

      assert resp.status == 400
      assert resp.body =~ "<Code>InvalidPolicyDocument</Code>"
    end

    test "the expiration and conditions keys are case-sensitive", ctx do
      encoded =
        Base.encode64(
          Jason.encode!(%{"EXPIRATION" => "2099-01-01T00:00:00Z", "conditions" => []})
        )

      resp = post(ctx, key: "foo.txt", policy: encoded, file: {"bar", filename: "f"})

      assert resp.status == 400
    end

    test "a missing conditions list is rejected", ctx do
      encoded = Base.encode64(Jason.encode!(%{"expiration" => "2099-01-01T00:00:00Z"}))

      resp = post(ctx, key: "foo.txt", policy: encoded, file: {"bar", filename: "f"})

      assert resp.status == 400
    end

    test "a non-ISO8601 expiration is rejected", ctx do
      # Elixir's from_iso8601 tolerates a space separator; S3 does not, and
      # Python's str(datetime) produces exactly that.
      encoded =
        Base.encode64(
          Jason.encode!(%{"expiration" => "2099-01-01 00:00:00+00:00", "conditions" => []})
        )

      resp = post(ctx, key: "foo.txt", policy: encoded, file: {"bar", filename: "f"})

      assert resp.status == 400
    end

    test "a malformed content-length-range is rejected", ctx do
      encoded =
        Base.encode64(
          Jason.encode!(%{
            "expiration" => "2099-01-01T00:00:00Z",
            "conditions" => [["content-length-range", 0]]
          })
        )

      resp = post(ctx, key: "foo.txt", policy: encoded, file: {"bar", filename: "f"})

      assert resp.status == 400
    end
  end

  describe "routing" do
    test "a POST that is not a form is still unimplemented", ctx do
      resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}", body: "")

      assert resp.status == 501
    end

    test "an unknown query parameter on a bucket GET is a listing, not a 501", ctx do
      # What success_action_redirect sends the browser back to.
      resp =
        Req.get!(ctx.req, url: "s3://#{ctx.bucket}", params: %{"bucket" => "x", "key" => "y"})

      assert resp.status == 200
      assert resp.body =~ "<ListBucketResult"
    end

    test "a genuine unimplemented subresource is still 501", ctx do
      resp = Req.get!(ctx.req, url: "s3://#{ctx.bucket}", params: %{"lifecycle" => ""})

      assert resp.status == 501
    end
  end

  ## Helpers

  defp post(ctx, fields) do
    Req.post!(raw_req(),
      url: "#{ctx.endpoint}/#{ctx.bucket}",
      form_multipart: fields,
      redirect: false
    )
  end

  defp get(ctx, key), do: Req.get!(ctx.req, url: "s3://#{ctx.bucket}/#{key}")

  defp policy(conditions, offset_seconds \\ 600) do
    expiration =
      DateTime.utc_now()
      |> DateTime.add(offset_seconds, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{"expiration" => expiration, "conditions" => conditions}
    |> Jason.encode!()
    |> Base.encode64()
  end
end
