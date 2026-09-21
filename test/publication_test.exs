defmodule FakeS3.PublicationTest do
  use FakeS3.TestServer

  alias FakeS3.{Publication, Storage}

  setup %{data_dir: dir} do
    Process.put(:fake_s3_config, %{data_dir: dir})
    :ok
  end

  test "failed publication restores bytes and metadata", %{endpoint: endpoint} do
    bucket = create_bucket!(endpoint)
    req = s3_req(endpoint)
    url = "s3://#{bucket}/state"
    %{status: 200} = Req.put!(req, url: url, body: "original")
    original = Req.get!(req, url: url)

    assert {:error, :injected_metadata_failure} =
             Storage.publish_object(bucket, "state", fn ->
               File.write!(Storage.object_path(bucket, "state"), "replacement")
               {:error, :injected_metadata_failure}
             end)

    response = Req.get!(req, url: url)
    assert response.body == "original"
    assert header_value(response.headers, "etag") == header_value(original.headers, "etag")
  end

  test "a killed writer is recovered before the next read", %{endpoint: endpoint, data_dir: dir} do
    bucket = create_bucket!(endpoint)
    req = s3_req(endpoint)
    url = "s3://#{bucket}/state"
    %{status: 200} = Req.put!(req, url: url, body: "original")
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        Process.put(:fake_s3_config, %{data_dir: dir})

        :global.trans(
          {{FakeS3.Router, Path.expand(dir)}, self()},
          fn ->
            Storage.publish_object(bucket, "state", fn ->
              File.write!(Storage.object_path(bucket, "state"), "partial")
              send(owner, :body_written)

              receive do
                :never -> :ok
              end
            end)
          end,
          [node()]
        )
      end)

    ref = Process.monitor(pid)
    assert_receive :body_written, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert %{status: 200, body: "original"} = Req.get!(req, url: url)
    assert File.ls!(Path.join(dir, ".publications")) == []
  end

  test "failed new publication leaves no phantom object", %{endpoint: endpoint} do
    bucket = create_bucket!(endpoint)

    assert {:error, :failed} =
             Storage.publish_object(bucket, "new", fn ->
               File.write!(Storage.object_path(bucket, "new"), "partial")
               {:error, :failed}
             end)

    assert %{status: 404} = Req.get!(s3_req(endpoint), url: "s3://#{bucket}/new")
    assert Storage.list_keys(bucket) == []
    assert :ok = Publication.recover!()
  end

  test "committed data survives listener restart on the same data directory", %{data_dir: root} do
    dir = Path.join(root, "restart")
    ref = make_ref()

    child =
      Supervisor.child_spec(
        {Plug.Cowboy,
         scheme: :http,
         plug: {FakeS3.Router, [config: %{data_dir: dir}]},
         options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]},
        id: :restart_server
      )

    start_supervised!(child)
    endpoint = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    bucket = create_bucket!(endpoint)

    assert %{status: 200} =
             Req.put!(s3_req(endpoint), url: "s3://#{bucket}/state", body: "durable")

    assert :ok = stop_supervised(:restart_server)
    start_supervised!(child)
    endpoint = "http://127.0.0.1:#{:ranch.get_port(ref)}"

    assert %{status: 200, body: "durable"} =
             Req.get!(s3_req(endpoint), url: "s3://#{bucket}/state")
  end
end
