defmodule FakeS3.StorageIntegrityTest do
  @moduledoc """
  Guards the two ways this server used to lose data silently: a PUT whose
  rename failed but still reported 200, and a copy-onto-self that truncated
  its own source.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  describe "key/prefix collisions" do
    test "rejects a key that an existing key is a prefix of", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/coll/b", body: "x")

      # "coll" is a directory on disk. This used to answer 200 and store
      # nothing at all.
      resp = Req.put!(req, url: "s3://#{bucket}/coll", body: "y")
      assert resp.status == 400
      assert resp.body =~ "<Code>InvalidArgument</Code>"
    end

    test "rejects a key nested under an existing key", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/c", body: "x")

      # Used to raise :enotdir from mkdir_p and surface as a 500.
      resp = Req.put!(req, url: "s3://#{bucket}/c/d", body: "y")
      assert resp.status == 400
      assert resp.body =~ "<Code>InvalidArgument</Code>"
    end

    test "a rejected PUT leaves nothing behind", %{endpoint: endpoint, data_dir: data_dir} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      Req.put!(req, url: "s3://#{bucket}/coll/b", body: "x")
      Req.put!(req, url: "s3://#{bucket}/coll", body: "y")

      objects = Path.join([data_dir, "buckets", bucket, "objects"])
      assert temp_files(objects) == []

      # A stray temp file in objects/ used to make the bucket permanently
      # undeletable while listing as empty.
      Req.delete!(req, url: "s3://#{bucket}/coll/b")
      assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}")
    end

    test "deleting the last key under a prefix frees the prefix", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      Req.put!(req, url: "s3://#{bucket}/free/inner", body: "x")
      assert %{status: 204} = Req.delete!(req, url: "s3://#{bucket}/free/inner")

      # The now-empty directory is pruned, so the parent key becomes writable.
      assert %{status: 200} = Req.put!(req, url: "s3://#{bucket}/free", body: "y")
      assert %{status: 200, body: "y"} = Req.get!(req, url: "s3://#{bucket}/free")
    end
  end

  describe "copy onto self" do
    test "is rejected without a metadata directive", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      Req.put!(req, url: "s3://#{bucket}/same.txt", body: "hello world")

      resp =
        Req.put!(req,
          url: "s3://#{bucket}/same.txt",
          headers: [{"x-amz-copy-source", "/#{bucket}/same.txt"}]
        )

      assert resp.status == 400
      assert resp.body =~ "<Code>InvalidRequest</Code>"

      # Crucially, the object survived. File.copy/2 onto itself truncated it.
      assert %{status: 200, body: "hello world"} = Req.get!(req, url: "s3://#{bucket}/same.txt")
    end

    test "replaces metadata in place when REPLACE is given", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      Req.put!(req,
        url: "s3://#{bucket}/same2.txt",
        body: "hello world",
        headers: [{"x-amz-meta-stage", "before"}]
      )

      resp =
        Req.put!(req,
          url: "s3://#{bucket}/same2.txt",
          headers: [
            {"x-amz-copy-source", "/#{bucket}/same2.txt"},
            {"x-amz-metadata-directive", "REPLACE"},
            {"x-amz-meta-stage", "after"},
            {"content-type", "text/plain"}
          ]
        )

      assert resp.status == 200

      got = Req.get!(req, url: "s3://#{bucket}/same2.txt")
      assert got.status == 200
      assert got.body == "hello world"
      assert header_value(got.headers, "x-amz-meta-stage") == "after"
    end
  end

  describe "copy between keys" do
    test "copies content and metadata", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      Req.put!(req,
        url: "s3://#{bucket}/src.txt",
        body: "payload",
        headers: [{"x-amz-meta-origin", "src"}]
      )

      resp =
        Req.put!(req,
          url: "s3://#{bucket}/dest.txt",
          headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
        )

      assert resp.status == 200
      assert resp.body =~ "<CopyObjectResult"

      dest = Req.get!(req, url: "s3://#{bucket}/dest.txt")
      assert dest.body == "payload"
      assert header_value(dest.headers, "x-amz-meta-origin") == "src"

      # Source untouched.
      assert %{status: 200, body: "payload"} = Req.get!(req, url: "s3://#{bucket}/src.txt")
    end

    test "404s when the source is missing", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      resp =
        Req.put!(req,
          url: "s3://#{bucket}/dest2.txt",
          headers: [{"x-amz-copy-source", "/#{bucket}/nope.txt"}]
        )

      assert resp.status == 404
      assert resp.body =~ "<Code>NoSuchKey</Code>"
    end
  end

  defp temp_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> temp_files(path)
            String.contains?(entry, "tmp-") -> [path]
            true -> []
          end
        end)

      _ ->
        []
    end
  end
end
