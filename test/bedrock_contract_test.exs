defmodule FakeS3.BedrockContractTest do
  use FakeS3.TestServer,
    config: %{mode: "strict", access_key: "test", secret_key: "test", region: "us-east-1"}

  alias Bedrock.ObjectStorage
  alias Bedrock.ObjectStorage.S3

  setup %{endpoint: endpoint} do
    config = [
      access_key_id: "test",
      secret_access_key: "test",
      region: "us-east-1",
      host: "127.0.0.1",
      port: URI.parse(endpoint).port,
      scheme: "http://",
      http_client: ExAws.Request.Req,
      retries: [max_attempts: 1]
    ]

    bucket = unique_bucket()
    assert {:ok, _} = ExAws.S3.put_bucket(bucket, "us-east-1") |> ExAws.request(config)
    backend = ObjectStorage.backend(S3, bucket: bucket, config: config)
    {:ok, backend: backend, config: config, bucket: bucket}
  end

  test "binary objects, ETags, HEAD, missing keys and idempotent delete", ctx do
    data = <<0, 255, 128, 0, 13, 10>>
    assert :ok = ObjectStorage.put(ctx.backend, "c/0/chunk", data)
    assert {:ok, ^data, token} = ObjectStorage.get_with_version(ctx.backend, "c/0/chunk")
    assert is_binary(token)

    assert {:ok, head} =
             ExAws.S3.head_object(ctx.bucket, "c/0/chunk") |> ExAws.request(ctx.config)

    assert header_value(head.headers, "etag") == token
    assert header_value(head.headers, "content-length") == "6"
    assert :ok = ObjectStorage.delete(ctx.backend, "c/0/chunk")
    assert :ok = ObjectStorage.delete(ctx.backend, "c/0/chunk")
    assert {:error, :not_found} = ObjectStorage.get(ctx.backend, "c/0/chunk")
  end

  test "create-only writes preserve the original", %{backend: backend} do
    assert :ok = ObjectStorage.put_if_not_exists(backend, "state", "original")
    assert {:error, :already_exists} = ObjectStorage.put_if_not_exists(backend, "state", "wrong")
    assert {:ok, "original"} = ObjectStorage.get(backend, "state")
  end

  test "exactly one concurrent create wins", %{backend: backend} do
    results = race(fn n -> ObjectStorage.put_if_not_exists(backend, "state", "writer-#{n}") end)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_exists})) == 7
  end

  test "CAS accepts current token, rejects stale and missing targets", %{backend: backend} do
    assert :ok = ObjectStorage.put(backend, "state", "one")
    assert {:ok, "one", token} = ObjectStorage.get_with_version(backend, "state")
    assert :ok = ObjectStorage.put_if_version_matches(backend, "state", token, "two")

    assert {:error, :version_mismatch} =
             ObjectStorage.put_if_version_matches(backend, "state", token, "wrong")

    assert {:ok, "two"} = ObjectStorage.get(backend, "state")

    assert {:error, :not_found} =
             ObjectStorage.put_if_version_matches(backend, "missing", token, "wrong")
  end

  test "exactly one concurrent CAS wins", %{backend: backend} do
    :ok = ObjectStorage.put(backend, "state", "original")
    {:ok, _, token} = ObjectStorage.get_with_version(backend, "state")

    results =
      race(fn n ->
        ObjectStorage.put_if_version_matches(backend, "state", token, "writer-#{n}")
      end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :version_mismatch})) == 7
  end

  test "server rejects stale and missing If-Match without the adapter HEAD check", ctx do
    :ok = ObjectStorage.put(ctx.backend, "state", "current")

    for key <- ["state", "missing"] do
      assert {:error, {:http_error, 412, _}} =
               ExAws.S3.put_object(ctx.bucket, key, "wrong", if_match: "\"stale\"")
               |> ExAws.request(ctx.config)
    end

    assert {:ok, "current"} = ObjectStorage.get(ctx.backend, "state")
    assert {:error, :not_found} = ObjectStorage.get(ctx.backend, "missing")
  end

  test "server atomically compares the same ETag for simultaneous direct PUTs", ctx do
    :ok = ObjectStorage.put(ctx.backend, "state", "original")
    {:ok, _, token} = ObjectStorage.get_with_version(ctx.backend, "state")

    results =
      race(fn n ->
        ExAws.S3.put_object(ctx.bucket, "state", "writer-#{n}", if_match: token)
        |> ExAws.request(ctx.config)
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:http_error, 412, _}}, &1)) == 7
  end

  @tag timeout: 120_000
  test "real adapter follows multiple pages in order and honors prefix and limit",
       %{backend: backend} = ctx do
    keys = for n <- 1..1003, do: "c/0/" <> String.pad_leading(Integer.to_string(n), 5, "0")
    for key <- keys, do: assert(:ok = ObjectStorage.put(backend, key, key))
    :ok = ObjectStorage.put(backend, "s/0/outside", "snapshot")
    assert Enum.to_list(ObjectStorage.list(backend, "c/0/")) == keys
    assert Enum.to_list(ObjectStorage.list(backend, "c/0/", limit: 1001)) == Enum.take(keys, 1001)
    assert Enum.to_list(ObjectStorage.list(backend, "c/0/", limit: 0)) == []

    # First page remains valid; a corrupt entry on the second page must fail
    # the enumeration instead of silently reporting a truncated history.
    File.write!(
      Path.join([ctx.data_dir, "buckets", ctx.bucket, "meta", List.last(keys) <> ".json"]),
      "bad"
    )

    assert_raise ObjectStorage.ListError, fn ->
      Enum.to_list(ObjectStorage.list(backend, "c/0/"))
    end
  end

  test "GET bytes always match their version token during competing writes", %{backend: backend} do
    :ok = ObjectStorage.put(backend, "state", "initial")

    results =
      race(fn n ->
        data = :binary.copy(<<n>>, 128_000)
        :ok = ObjectStorage.put(backend, "state", data)
        {:ok, body, token} = ObjectStorage.get_with_version(backend, "state")
        expected = "\"" <> Base.encode16(:crypto.hash(:md5, body), case: :lower) <> "\""
        token == expected
      end)

    assert Enum.all?(results)
  end

  test "corrupt metadata is a server error, never not_found or an empty listing", ctx do
    :ok = ObjectStorage.put(ctx.backend, "state", "one")
    path = Path.join([ctx.data_dir, "buckets", ctx.bucket, "meta", "state.json"])
    File.write!(path, "invalid json")
    assert {:error, {:http_error, 500, _}} = ObjectStorage.get(ctx.backend, "state")

    assert_raise ObjectStorage.ListError, fn ->
      Enum.to_list(ObjectStorage.list(ctx.backend, ""))
    end

    assert {:error, {:http_error, 500, _}} =
             ObjectStorage.put_if_not_exists(ctx.backend, "state", "wrong")
  end

  test "failed directory traversal is not an empty listing", ctx do
    path = Path.join([ctx.data_dir, "buckets", ctx.bucket, "objects"])
    File.rmdir!(path)
    File.write!(path, "not a directory")

    assert_raise ObjectStorage.ListError, fn ->
      Enum.to_list(ObjectStorage.list(ctx.backend, ""))
    end

    response = Req.get!(s3_req(ctx.endpoint), url: "s3://#{ctx.bucket}", retry: false)
    assert response.status == 500
    assert response.body =~ "<Code>InternalError</Code>"
  end

  test "delete reports storage failure and retains the body", ctx do
    :ok = ObjectStorage.put(ctx.backend, "state", "keep")
    meta = Path.join([ctx.data_dir, "buckets", ctx.bucket, "meta", "state.json"])
    File.rm!(meta)
    File.mkdir!(meta)
    assert {:error, {:http_error, 500, _}} = ObjectStorage.delete(ctx.backend, "state")

    assert File.read!(Path.join([ctx.data_dir, "buckets", ctx.bucket, "objects", "state"])) ==
             "keep"
  end

  test "continuation resumes after a deleted last key", ctx do
    for key <- ~w(c/a c/b c/c), do: ObjectStorage.put(ctx.backend, key, key)

    assert {:ok, first} =
             ExAws.S3.list_objects_v2(ctx.bucket, prefix: "c/", max_keys: 2)
             |> ExAws.request(ctx.config)

    token = first.body.next_continuation_token
    assert :ok = ObjectStorage.delete(ctx.backend, "c/b")

    assert {:ok, next} =
             ExAws.S3.list_objects_v2(ctx.bucket, prefix: "c/", continuation_token: token)
             |> ExAws.request(ctx.config)

    assert Enum.map(next.body.contents, & &1.key) == ["c/c"]
  end

  test "failed preconditions preserve version history", ctx do
    req = s3_req(ctx.endpoint)
    url = "s3://#{ctx.bucket}/state"
    xml = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"
    assert %{status: 200} = Req.put!(req, url: "s3://#{ctx.bucket}?versioning", body: xml)
    assert %{status: 200} = Req.put!(req, url: url, body: "original")

    assert %{status: 412} =
             Req.put!(req, url: url, body: "wrong", headers: [{"if-none-match", "*"}])

    assert %{status: 200, body: "original"} = Req.get!(req, url: url)
    versions = Req.get!(req, url: "s3://#{ctx.bucket}?versions").body
    assert length(xml_values(versions, "VersionId")) == 1
  end

  defp race(fun) do
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()

    tasks =
      for n <- 1..8 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(owner, {:ready, self()})

          receive do
            :go -> fun.(n)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    for task <- tasks, do: send(task.pid, :go)
    Task.await_many(tasks, 30_000)
  end
end
