defmodule FakeS3.ConfigPlug do
  @moduledoc false

  def init(opts) do
    Keyword.get(opts, :config, %{})
  end

  def call(conn, config) do
    Process.put(:fake_s3_config, config)
    conn
  end
end
