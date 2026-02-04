defmodule FakeS3.Application do
  @moduledoc false

  use Application

  require Logger

  def start(_type, _args) do
    FakeS3.Config.configure_logger()

    children = [
      {Plug.Cowboy,
       scheme: :http,
       plug: FakeS3.Router,
       options: [ip: FakeS3.Config.host_ip(), port: FakeS3.Config.port()]}
    ]

    Logger.info("FakeS3 listening on #{FakeS3.Config.host()}:#{FakeS3.Config.port()}")

    Supervisor.start_link(children, strategy: :one_for_one, name: FakeS3.Supervisor)
  end
end
