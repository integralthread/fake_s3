defmodule FakeS3.VersioningTest do
  @moduledoc """
  Bucket versioning: configuration, versioned writes, ?versionId reads and
  deletes, delete markers, and ListObjectVersions.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  setup %{endpoint: endpoint} do
    {:ok, bucket: create_bucket!(endpoint), req: s3_req(endpoint), endpoint: endpoint}
  end

  describe "configuration" do
    test "an unconfigured bucket reports no status", ctx do
      resp = get_versioning(ctx)

      assert resp.status == 200
      assert resp.body =~ "<VersioningConfiguration"
      # Distinguishable from Suspended: never-enabled has no Status at all.
      refute resp.body =~ "<Status>"
    end

    test "Enabled and Suspended round trip", ctx do
      assert %{status: 200} = put_versioning(ctx, "Enabled")
      assert xml_values(get_versioning(ctx).body, "Status") == ["Enabled"]

      assert %{status: 200} = put_versioning(ctx, "Suspended")
      assert xml_values(get_versioning(ctx).body, "Status") == ["Suspended"]
    end

    test "an unrecognised status is rejected", ctx do
      resp = put_versioning(ctx, "Sometimes")

      assert resp.status == 400
      assert resp.body =~ "IllegalVersioningConfiguration"
    end

    test "versioning a missing bucket 404s", %{req: req} do
      resp =
        Req.put!(req,
          url: "s3://no-such-bucket-xyz",
          params: %{"versioning" => ""},
          body: "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"
        )

      assert resp.status == 404
      assert resp.body =~ "<Code>NoSuchBucket</Code>"
    end
  end

  describe "versioned writes" do
    setup ctx do
      put_versioning(ctx, "Enabled")
      :ok
    end

    test "each write returns a distinct version id and both remain readable", ctx do
      v1 = put_object!(ctx, "f.txt", "one")
      v2 = put_object!(ctx, "f.txt", "two")

      refute v1 == v2
      assert get_object(ctx, "f.txt").body == "two"
      assert get_object(ctx, "f.txt", v1).body == "one"
      assert get_object(ctx, "f.txt", v2).body == "two"
    end

    test "an unknown version id 404s", ctx do
      put_object!(ctx, "f.txt", "one")

      resp = get_object(ctx, "f.txt", "not-a-version")

      assert resp.status == 404
      assert resp.body =~ "<Code>NoSuchVersion</Code>"
    end

    test "HEAD reports the version it served", ctx do
      v1 = put_object!(ctx, "f.txt", "one")
      put_object!(ctx, "f.txt", "two")

      resp = Req.head!(ctx.req, url: "s3://#{ctx.bucket}/f.txt", params: %{"versionId" => v1})

      assert resp.status == 200
      assert header_value(resp.headers, "x-amz-version-id") == v1
    end

    test "an unversioned bucket gets no version id", ctx do
      # The setup above enabled versioning on ctx.bucket, so use a fresh one.
      plain = create_bucket!(ctx.endpoint)
      resp = Req.put!(ctx.req, url: "s3://#{plain}/f.txt", body: "x")

      assert resp.status == 200
      assert header_value(resp.headers, "x-amz-version-id") == nil
    end
  end

  describe "delete markers" do
    setup ctx do
      put_versioning(ctx, "Enabled")
      :ok
    end

    test "delete hides the object without destroying it", ctx do
      v1 = put_object!(ctx, "f.txt", "one")

      resp = Req.delete!(ctx.req, url: "s3://#{ctx.bucket}/f.txt")
      assert resp.status == 204
      assert header_value(resp.headers, "x-amz-delete-marker") == "true"

      # Hidden from a plain GET...
      hidden = get_object(ctx, "f.txt")
      assert hidden.status == 404
      assert header_value(hidden.headers, "x-amz-delete-marker") == "true"

      # ...but the version is still there.
      assert get_object(ctx, "f.txt", v1).body == "one"
    end

    test "addressing a delete marker directly is a 405", ctx do
      put_object!(ctx, "f.txt", "one")

      marker =
        header_value(
          Req.delete!(ctx.req, url: "s3://#{ctx.bucket}/f.txt").headers,
          "x-amz-version-id"
        )

      resp = get_object(ctx, "f.txt", marker)

      assert resp.status == 405
      assert resp.body =~ "<Code>MethodNotAllowed</Code>"
    end

    test "removing the marker brings the object back", ctx do
      put_object!(ctx, "f.txt", "one")

      marker =
        header_value(
          Req.delete!(ctx.req, url: "s3://#{ctx.bucket}/f.txt").headers,
          "x-amz-version-id"
        )

      assert %{status: 204} = delete_version(ctx, "f.txt", marker)
      assert get_object(ctx, "f.txt").body == "one"
    end
  end

  describe "deleting a specific version" do
    setup ctx do
      put_versioning(ctx, "Enabled")
      :ok
    end

    test "deleting the current version promotes the previous one", ctx do
      v1 = put_object!(ctx, "f.txt", "one")
      v2 = put_object!(ctx, "f.txt", "two")

      assert %{status: 204} = delete_version(ctx, "f.txt", v2)

      # Without promotion the key would vanish even though v1 still exists.
      assert get_object(ctx, "f.txt").body == "one"
      assert get_object(ctx, "f.txt", v1).body == "one"
    end

    test "deleting every version removes the key", ctx do
      v1 = put_object!(ctx, "f.txt", "one")
      v2 = put_object!(ctx, "f.txt", "two")

      delete_version(ctx, "f.txt", v1)
      delete_version(ctx, "f.txt", v2)

      assert get_object(ctx, "f.txt").status == 404
      assert list_versions(ctx) == []
    end

    test "deleting an unknown version 404s", ctx do
      put_object!(ctx, "f.txt", "one")

      assert %{status: 404} = delete_version(ctx, "f.txt", "not-a-version")
    end
  end

  describe "suspended" do
    test "writes reuse the null version id and replace each other", ctx do
      put_versioning(ctx, "Enabled")
      enabled_version = put_object!(ctx, "s.txt", "enabled")

      put_versioning(ctx, "Suspended")
      assert put_object!(ctx, "s.txt", "first") == "null"
      assert put_object!(ctx, "s.txt", "second") == "null"

      assert get_object(ctx, "s.txt").body == "second"
      # The version created while Enabled survives; the null one was replaced
      # rather than accumulating a second copy under the same id.
      assert get_object(ctx, "s.txt", enabled_version).body == "enabled"
      assert length(list_versions(ctx)) == 2
    end
  end

  describe "ListObjectVersions" do
    setup ctx do
      put_versioning(ctx, "Enabled")
      :ok
    end

    test "reports every version, newest first, flagging the latest", ctx do
      put_object!(ctx, "f.txt", "one")
      v2 = put_object!(ctx, "f.txt", "two")

      body = Req.get!(ctx.req, url: "s3://#{ctx.bucket}", params: %{"versions" => ""}).body

      assert [^v2 | _] = xml_values(body, "VersionId")
      assert xml_values(body, "IsLatest") == ~w(true false)
      assert xml_values(body, "Key") == ~w(f.txt f.txt)
    end

    test "delete markers appear as DeleteMarker, not Version", ctx do
      put_object!(ctx, "f.txt", "one")
      Req.delete!(ctx.req, url: "s3://#{ctx.bucket}/f.txt")

      body = Req.get!(ctx.req, url: "s3://#{ctx.bucket}", params: %{"versions" => ""}).body

      assert body =~ "<DeleteMarker>"
      # One real version plus one marker.
      assert length(xml_values(body, "VersionId")) == 2
    end

    test "bulk delete honours a per-object VersionId", ctx do
      # How ceph/s3-tests empties a versioned bucket. Ignoring VersionId here
      # left every non-current version on disk, so the bucket could never be
      # deleted and every later test failed in cleanup.
      v1 = put_object!(ctx, "f.txt", "one")
      v2 = put_object!(ctx, "f.txt", "two")

      body = """
      <Delete>
        <Object><Key>f.txt</Key><VersionId>#{v1}</VersionId></Object>
        <Object><Key>f.txt</Key><VersionId>#{v2}</VersionId></Object>
      </Delete>
      """

      resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?delete", body: body)

      assert resp.status == 200
      assert list_versions(ctx) == []
      assert %{status: 204} = Req.delete!(ctx.req, url: "s3://#{ctx.bucket}")
    end

    test "bulk delete without a VersionId inserts a marker", ctx do
      put_object!(ctx, "f.txt", "one")

      body = "<Delete><Object><Key>f.txt</Key></Object></Delete>"
      resp = Req.post!(raw_req(), url: "#{ctx.endpoint}/#{ctx.bucket}?delete", body: body)

      assert resp.status == 200
      assert get_object(ctx, "f.txt").status == 404
      # Shadowed, not destroyed: the original version is still listed.
      assert length(list_versions(ctx)) == 2
    end

    test "a bucket keeping only old versions is not empty", ctx do
      put_object!(ctx, "f.txt", "one")
      Req.delete!(ctx.req, url: "s3://#{ctx.bucket}/f.txt")

      # Nothing is visible to ListObjects, but the history must still block
      # DeleteBucket rather than being silently orphaned.
      assert xml_values(Req.get!(ctx.req, url: "s3://#{ctx.bucket}").body, "Key") == []
      assert %{status: 409} = Req.delete!(ctx.req, url: "s3://#{ctx.bucket}")
    end
  end

  ## Helpers

  defp put_versioning(ctx, status) do
    Req.put!(ctx.req,
      url: "s3://#{ctx.bucket}",
      params: %{"versioning" => ""},
      body: "<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>"
    )
  end

  defp get_versioning(ctx) do
    Req.get!(ctx.req, url: "s3://#{ctx.bucket}", params: %{"versioning" => ""})
  end

  defp put_object!(ctx, key, body) do
    resp = Req.put!(ctx.req, url: "s3://#{ctx.bucket}/#{key}", body: body)
    assert resp.status == 200
    header_value(resp.headers, "x-amz-version-id")
  end

  defp get_object(ctx, key, version_id \\ nil) do
    params = if version_id, do: %{"versionId" => version_id}, else: %{}
    Req.get!(ctx.req, url: "s3://#{ctx.bucket}/#{key}", params: params)
  end

  defp delete_version(ctx, key, version_id) do
    Req.delete!(ctx.req, url: "s3://#{ctx.bucket}/#{key}", params: %{"versionId" => version_id})
  end

  defp list_versions(ctx) do
    Req.get!(ctx.req, url: "s3://#{ctx.bucket}", params: %{"versions" => ""}).body
    |> xml_values("VersionId")
  end
end
