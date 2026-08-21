defmodule FakeS3.TestServer do
  @moduledoc """
  Boots an isolated FakeS3 instance per test: its own port, its own data dir.

  `use FakeS3.TestServer` sets up the server in a `setup_all` block and tears
  it down (including the data dir) on exit, exposing `endpoint` and `data_dir`
  in the test context.
  """

  defmacro __using__(opts) do
    config = Keyword.get(opts, :config, quote(do: %{}))

    quote do
      use ExUnit.Case, async: true

      import FakeS3.TestServer

      setup_all do
        FakeS3.TestServer.setup_server(unquote(config))
      end
    end
  end

  @doc """
  Starts a server and registers its teardown with the calling test.

  Usable from either `setup` or `setup_all`.
  """
  def setup_server(config \\ %{}) do
    {:ok, server} = start(config)

    ExUnit.Callbacks.on_exit(fn -> stop(server) end)

    {:ok, endpoint: server.endpoint, data_dir: server.data_dir}
  end

  def start(config \\ %{}) do
    data_dir =
      System.tmp_dir!()
      |> Path.join("fake_s3_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    ref = :"fake_s3_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Plug.Cowboy.http(
        FakeS3.Router,
        [config: Map.put(config, :data_dir, data_dir)],
        ip: {127, 0, 0, 1},
        port: 0,
        ref: ref
      )

    port = :ranch.get_port(ref)

    {:ok, %{endpoint: "http://127.0.0.1:#{port}", ref: ref, data_dir: data_dir}}
  end

  def stop(%{ref: ref, data_dir: data_dir}) do
    Plug.Cowboy.shutdown(ref)
    File.rm_rf!(data_dir)
  end

  @doc """
  A Req client with req_s3 attached and SigV4 credentials.

  `raw: true` keeps Req from stripping `content-length` off the response once
  it has read the body, which would otherwise hide the header from assertions.
  """
  def s3_req(endpoint, opts \\ []) do
    Req.new(decode_body: false, raw: true)
    |> ReqS3.attach(
      aws_endpoint_url_s3: endpoint,
      aws_sigv4: [
        access_key_id: Keyword.get(opts, :access_key_id, "test"),
        secret_access_key: Keyword.get(opts, :secret_access_key, "test"),
        region: Keyword.get(opts, :region, "us-east-1")
      ]
    )
  end

  @doc "A plain Req client for hitting raw paths without signing."
  def raw_req, do: Req.new(decode_body: false, raw: true, retry: false)

  def unique_bucket, do: "test-bucket-#{System.unique_integer([:positive])}"

  def header_value(headers, key) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == key end)
    |> case do
      {_, [value | _]} -> value
      {_, value} when is_binary(value) -> value
      nil -> nil
    end
  end

  @doc "Creates a bucket and returns its name."
  def create_bucket!(endpoint) do
    bucket = unique_bucket()
    %{status: 200} = Req.put!(s3_req(endpoint), url: "s3://#{bucket}")
    bucket
  end

  @doc "Extracts the text of every `<tag>` in an XML body."
  def xml_values(body, tag) do
    ~r{<#{tag}>(.*?)</#{tag}>}s
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [value] -> value end)
  end
end
