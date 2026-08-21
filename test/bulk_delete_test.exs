defmodule FakeS3.BulkDeleteTest do
  @moduledoc """
  DeleteObjects, which `aws s3 rm --recursive` and `aws s3 sync --delete`
  batch through. Previously unrouted, so it 404'd with a plain-text body.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  setup %{endpoint: endpoint} do
    bucket = create_bucket!(endpoint)
    req = s3_req(endpoint)

    for key <- ~w(one.txt two.txt nested/three.txt) do
      Req.put!(req, url: "s3://#{bucket}/#{key}", body: "x")
    end

    {:ok, bucket: bucket, req: req}
  end

  test "deletes several keys in one request", ctx do
    resp = delete_objects(ctx, ~w(one.txt nested/three.txt))

    assert resp.status == 200
    assert xml_values(resp.body, "Key") == ~w(one.txt nested/three.txt)

    assert %{status: 404} = Req.get!(ctx.req, url: "s3://#{ctx.bucket}/one.txt")
    assert %{status: 404} = Req.get!(ctx.req, url: "s3://#{ctx.bucket}/nested/three.txt")
    assert %{status: 200} = Req.get!(ctx.req, url: "s3://#{ctx.bucket}/two.txt")
  end

  test "is idempotent for keys that do not exist", ctx do
    resp = delete_objects(ctx, ~w(ghost.txt))

    assert resp.status == 200
    assert xml_values(resp.body, "Key") == ~w(ghost.txt)
  end

  test "honours Quiet mode", ctx do
    body = """
    <Delete><Quiet>true</Quiet>#{object_elements(~w(one.txt))}</Delete>
    """

    resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?delete", body: body)

    assert resp.status == 200
    assert xml_values(resp.body, "Key") == []
  end

  test "unescapes XML entities in keys", ctx do
    Req.put!(ctx.req, url: "s3://#{ctx.bucket}/a%26b.txt", body: "x")

    body = "<Delete><Object><Key>a&amp;b.txt</Key></Object></Delete>"
    resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?delete", body: body)

    assert resp.status == 200
    assert %{status: 404} = Req.get!(ctx.req, url: "s3://#{ctx.bucket}/a%26b.txt")
  end

  test "reports an error entry for a traversing key", ctx do
    body = "<Delete><Object><Key>../escape.txt</Key></Object></Delete>"
    resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?delete", body: body)

    assert resp.status == 200
    assert resp.body =~ "<Code>InvalidArgument</Code>"
  end

  test "404s for a missing bucket", %{endpoint: endpoint} do
    resp =
      Req.post!(raw_req(),
        url: "#{endpoint}/no-such-bucket-abc?delete",
        body: "<Delete>#{object_elements(~w(x.txt))}</Delete>"
      )

    assert resp.status == 404
    assert resp.body =~ "<Code>NoSuchBucket</Code>"
  end

  test "a POST without ?delete is reported as unimplemented", ctx do
    resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}", body: "")

    assert resp.status == 501
    assert resp.body =~ "<Code>NotImplemented</Code>"
  end

  defp delete_objects(ctx, keys) do
    body = "<Delete>#{object_elements(keys)}</Delete>"
    Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?delete", body: body)
  end

  defp object_elements(keys) do
    Enum.map_join(keys, &"<Object><Key>#{&1}</Key></Object>")
  end
end
