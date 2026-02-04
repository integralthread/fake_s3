defmodule FakeS3.RequestId do
  @moduledoc false

  import Plug.Conn

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

    conn
    |> put_resp_header("x-amz-request-id", request_id)
    |> assign(:request_id, request_id)
  end

  defp generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
