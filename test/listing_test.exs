defmodule FakeS3.ListingTest do
  @moduledoc """
  ListObjects v1/v2 argument handling, pagination and bucket subresources.
  """

  use FakeS3.TestServer, config: %{mode: "noauth"}

  describe "max-keys validation" do
    setup %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      for name <- ~w(a.txt b.txt c.txt),
          do: Req.put!(req, url: "s3://#{bucket}/#{name}", body: "x")

      {:ok, bucket: bucket, req: req}
    end

    test "max-keys=0 returns an empty page", %{req: req, bucket: bucket} do
      # Base.encode64(nil) used to raise here, giving a 500.
      resp = list(req, bucket, %{"list-type" => "2", "max-keys" => "0"})

      assert resp.status == 200
      assert resp.body =~ "<KeyCount>0</KeyCount>"
      assert resp.body =~ "<IsTruncated>false</IsTruncated>"
      assert xml_values(resp.body, "Key") == []
    end

    test "rejects a negative max-keys", %{req: req, bucket: bucket} do
      # Enum.take/2 with a negative count used to return keys from the tail.
      resp = list(req, bucket, %{"list-type" => "2", "max-keys" => "-1"})

      assert resp.status == 400
      assert resp.body =~ "<Code>InvalidArgument</Code>"
    end

    test "rejects a non-numeric max-keys", %{req: req, bucket: bucket} do
      resp = list(req, bucket, %{"list-type" => "2", "max-keys" => "abc"})
      assert resp.status == 400
    end

    test "caps max-keys at 1000", %{req: req, bucket: bucket} do
      resp = list(req, bucket, %{"list-type" => "2", "max-keys" => "99999"})

      assert resp.status == 200
      assert resp.body =~ "<MaxKeys>1000</MaxKeys>"
    end
  end

  describe "pagination" do
    test "walks every key without repeating", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      expected = for i <- 1..10, do: "key-#{String.pad_leading("#{i}", 2, "0")}.txt"
      for key <- expected, do: Req.put!(req, url: "s3://#{bucket}/#{key}", body: "x")

      assert drain_v2(req, bucket, %{}) == expected
    end

    test "terminates when truncating on a common prefix", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      # Each prefix holds several keys, so a page boundary lands inside a
      # CommonPrefixes group. Resuming from the prefix name itself would
      # replay the group forever, because "p1/" sorts before "p1/a".
      for prefix <- ~w(p1 p2 p3), name <- ~w(a b c) do
        Req.put!(req, url: "s3://#{bucket}/#{prefix}/#{name}", body: "x")
      end

      params = %{"delimiter" => "/", "max-keys" => "1"}
      assert drain_v2(req, bucket, params) == ~w(p1/ p2/ p3/)
    end

    test "counts common prefixes against max-keys", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      for prefix <- ~w(x1 x2 x3), do: Req.put!(req, url: "s3://#{bucket}/#{prefix}/a", body: "x")
      Req.put!(req, url: "s3://#{bucket}/loose.txt", body: "x")

      resp = list(req, bucket, %{"list-type" => "2", "delimiter" => "/", "max-keys" => "2"})

      assert resp.status == 200
      assert resp.body =~ "<KeyCount>2</KeyCount>"
      assert resp.body =~ "<IsTruncated>true</IsTruncated>"
    end

    test "start-after skips ahead", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)
      for name <- ~w(a b c d), do: Req.put!(req, url: "s3://#{bucket}/#{name}", body: "x")

      resp = list(req, bucket, %{"list-type" => "2", "start-after" => "b"})
      assert xml_values(resp.body, "Key") == ~w(c d)
    end
  end

  describe "ListObjects v1" do
    test "answers a bare GET on the bucket", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)
      Req.put!(req, url: "s3://#{bucket}/v1.txt", body: "x")

      # Used to be rejected with InvalidArgument, breaking boto3's
      # list_objects and every GetBucket* subresource call.
      resp = list(req, bucket, %{})

      assert resp.status == 200
      assert resp.body =~ "<ListBucketResult"
      assert resp.body =~ "<Marker>"
      assert xml_values(resp.body, "Key") == ["v1.txt"]
    end

    test "paginates with marker/NextMarker", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)
      for name <- ~w(m1 m2 m3), do: Req.put!(req, url: "s3://#{bucket}/#{name}", body: "x")

      first = list(req, bucket, %{"max-keys" => "2"})
      assert first.body =~ "<IsTruncated>true</IsTruncated>"
      assert xml_values(first.body, "Key") == ~w(m1 m2)

      [marker] = xml_values(first.body, "NextMarker")
      second = list(req, bucket, %{"max-keys" => "2", "marker" => marker})

      assert xml_values(second.body, "Key") == ~w(m3)
      assert second.body =~ "<IsTruncated>false</IsTruncated>"
    end
  end

  describe "encoding-type" do
    test "percent-encodes keys so clients can decode them back", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)

      # A literal '%20' in a key round-trips only if the response encodes it;
      # otherwise a client honouring encoding-type=url decodes it to a space.
      for key <- ["pct%20literal.txt", "plus+sign.txt", "a b.txt"] do
        Req.put!(req,
          url: "s3://#{bucket}/#{URI.encode(key, &URI.char_unreserved?/1)}",
          body: "x"
        )
      end

      resp = list(req, bucket, %{"list-type" => "2", "encoding-type" => "url"})

      assert resp.body =~ "<EncodingType>url</EncodingType>"

      decoded = resp.body |> xml_values("Key") |> Enum.map(&URI.decode/1) |> Enum.sort()
      assert decoded == ["a b.txt", "pct%20literal.txt", "plus+sign.txt"]
    end

    test "leaves keys raw when not requested", %{endpoint: endpoint} do
      bucket = create_bucket!(endpoint)
      req = s3_req(endpoint)
      Req.put!(req, url: "s3://#{bucket}/plain.txt", body: "x")

      resp = list(req, bucket, %{"list-type" => "2"})
      assert xml_values(resp.body, "Key") == ["plain.txt"]
      refute resp.body =~ "<EncodingType>"
    end
  end

  describe "bucket PUT dispatch" do
    setup %{endpoint: endpoint} do
      {:ok, bucket: create_bucket!(endpoint), req: s3_req(endpoint)}
    end

    test "?tagging is not treated as CreateBucket", %{req: req, bucket: bucket} do
      # Used to return 409 BucketAlreadyOwnedByYou, because every PUT on a
      # bucket path was routed to CreateBucket regardless of subresource.
      resp = put_subresource(req, bucket, "tagging")

      assert resp.status == 501
      assert resp.body =~ "<Code>NotImplemented</Code>"
    end

    test "?acl is not treated as CreateBucket", %{req: req, bucket: bucket} do
      resp = put_subresource(req, bucket, "acl")

      assert resp.status == 501
      assert resp.body =~ "<Code>NotImplemented</Code>"
    end

    # ?versioning is handled rather than 501'd; see FakeS3.VersioningTest.
    test "?versioning is dispatched to the versioning handler", %{req: req, bucket: bucket} do
      resp = put_subresource(req, bucket, "versioning")

      refute resp.status == 409
      assert resp.body =~ "IllegalVersioningConfiguration"
    end

    test "a subresource on a missing bucket 404s", %{req: req} do
      resp = put_subresource(req, "no-such-bucket-xyz", "versioning")

      assert resp.status == 404
      assert resp.body =~ "<Code>NoSuchBucket</Code>"
    end

    test "a bare PUT on an existing bucket still conflicts", %{req: req, bucket: bucket} do
      resp = Req.put!(req, url: "s3://#{bucket}")

      assert resp.status == 409
      assert resp.body =~ "<Code>BucketAlreadyOwnedByYou</Code>"
    end

    test "an unrecognised query parameter still creates the bucket", %{endpoint: endpoint} do
      # SDKs append things like ?x-id=CreateBucket; only known subresources
      # should divert away from bucket creation.
      resp =
        Req.put!(s3_req(endpoint),
          url: "s3://#{unique_bucket()}",
          params: %{"x-id" => "CreateBucket"}
        )

      assert resp.status == 200
    end
  end

  describe "bucket subresources" do
    setup %{endpoint: endpoint} do
      {:ok, bucket: create_bucket!(endpoint), req: s3_req(endpoint)}
    end

    test "?location returns a location constraint", %{req: req, bucket: bucket} do
      resp = list(req, bucket, %{"location" => ""})

      assert resp.status == 200
      assert resp.body =~ "<LocationConstraint"
    end

    test "?versioning returns an empty configuration", %{req: req, bucket: bucket} do
      resp = list(req, bucket, %{"versioning" => ""})

      assert resp.status == 200
      assert resp.body =~ "<VersioningConfiguration"
    end

    test "?acl returns an owner grant", %{req: req, bucket: bucket} do
      resp = list(req, bucket, %{"acl" => ""})

      assert resp.status == 200
      assert resp.body =~ "FULL_CONTROL"
    end

    test "an unimplemented subresource says so in XML", %{req: req, bucket: bucket} do
      resp = list(req, bucket, %{"lifecycle" => ""})

      assert resp.status == 501
      assert resp.body =~ "<Code>NotImplemented</Code>"
    end

    test "?versions lists every key at version null", %{req: req, bucket: bucket} do
      for name <- ~w(a.txt b.txt), do: Req.put!(req, url: "s3://#{bucket}/#{name}", body: "x")

      resp = list(req, bucket, %{"versions" => ""})

      assert resp.status == 200
      assert resp.body =~ "<ListVersionsResult"
      assert xml_values(resp.body, "Key") == ~w(a.txt b.txt)
      assert xml_values(resp.body, "VersionId") == ~w(null null)
      assert xml_values(resp.body, "IsLatest") == ~w(true true)
    end

    test "?versions paginates with key-marker", %{req: req, bucket: bucket} do
      for name <- ~w(a.txt b.txt c.txt),
          do: Req.put!(req, url: "s3://#{bucket}/#{name}", body: "x")

      first = list(req, bucket, %{"versions" => "", "max-keys" => "2"})

      assert first.status == 200
      assert first.body =~ "<IsTruncated>true</IsTruncated>"
      assert xml_values(first.body, "Key") == ~w(a.txt b.txt)

      [marker] = xml_values(first.body, "NextKeyMarker")
      second = list(req, bucket, %{"versions" => "", "key-marker" => marker})

      assert second.status == 200
      assert second.body =~ "<IsTruncated>false</IsTruncated>"
      assert xml_values(second.body, "Key") == ~w(c.txt)
    end

    test "listing a missing bucket 404s", %{endpoint: endpoint} do
      resp = list(s3_req(endpoint), "no-such-bucket-xyz", %{"list-type" => "2"})

      assert resp.status == 404
      assert resp.body =~ "<Code>NoSuchBucket</Code>"
    end
  end

  defp list(req, bucket, params) do
    Req.get!(req, url: "s3://#{bucket}", params: params)
  end

  defp put_subresource(req, bucket, name) do
    Req.put!(req, url: "s3://#{bucket}", params: %{name => ""}, body: "")
  end

  # Follows continuation tokens to exhaustion, failing loudly rather than
  # looping forever if pagination fails to advance.
  defp drain_v2(req, bucket, params, token \\ nil, seen \\ [], rounds \\ 0) do
    if rounds > 50, do: flunk("pagination did not terminate after #{rounds} pages")

    params =
      params
      |> Map.put("list-type", "2")
      |> then(fn p -> if token, do: Map.put(p, "continuation-token", token), else: p end)

    resp = list(req, bucket, params)
    assert resp.status == 200

    page = xml_values(resp.body, "Key") ++ xml_values(resp.body, "Prefix")
    page = Enum.reject(page, &(&1 == ""))
    seen = seen ++ page

    case xml_values(resp.body, "NextContinuationToken") do
      [next] -> drain_v2(req, bucket, params, next, seen, rounds + 1)
      [] -> seen
    end
  end
end
