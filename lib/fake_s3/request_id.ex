defmodule FakeS3.RequestId do
  @moduledoc false

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id =
      conn
      |> get_req_header("x-amz-request-id")
      |> List.first()
      |> case do
        nil -> generate_id()
        value -> value
      end

    # Puts the id on every log line emitted while handling this request, which
    # is what makes the id in the response and the id in the logs correlatable.
    Logger.metadata(request_id: request_id)

    conn
    |> put_resp_header("x-amz-request-id", request_id)
    |> put_resp_header("x-amz-id-2", generate_id())
    |> assign(:request_id, request_id)
  end

  defp generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
