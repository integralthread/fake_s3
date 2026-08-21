defmodule FakeS3.Body do
  @moduledoc false

  alias FakeS3.{ChunkedBody, Config}

  @read_opts [read_length: 1_048_576, timeout: 30_000]

  @doc """
  Streams the request body into `io`, decoding aws-chunked framing when
  present, and returns the decoded size along with MD5 in both hex-ETag and
  raw forms (multipart completion needs the raw digest).
  """
  def stream_to_file(conn, io) do
    decoder = if chunked?(conn), do: ChunkedBody.new(), else: nil

    case read_loop(conn, io, :crypto.hash_init(:md5), 0, Config.max_body_bytes(), decoder) do
      {:ok, ctx, size} ->
        md5 = :crypto.hash_final(ctx)
        hex = Base.encode16(md5, case: :lower)
        {:ok, %{size: size, etag: "\"" <> hex <> "\"", md5: md5}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  True when the client framed the body itself rather than sending it raw.
  """
  def chunked?(conn) do
    encoding =
      conn
      |> Plug.Conn.get_req_header("content-encoding")
      |> Enum.join(",")
      |> String.downcase()

    sha256 =
      conn
      |> Plug.Conn.get_req_header("x-amz-content-sha256")
      |> List.first()
      |> to_string()

    String.contains?(encoding, "aws-chunked") or String.starts_with?(sha256, "STREAMING-")
  end

  @doc """
  The size of the object as it will be stored, from request headers alone.

  For aws-chunked bodies `Content-Length` counts the framing too, so the
  decoded length header is the only meaningful figure.
  """
  def declared_length(conn) do
    header =
      if chunked?(conn), do: "x-amz-decoded-content-length", else: "content-length"

    with [value | _] <- Plug.Conn.get_req_header(conn, header),
         {length, _} <- Integer.parse(value) do
      length
    else
      _ -> nil
    end
  end

  defp read_loop(conn, io, ctx, size, max, decoder) do
    case Plug.Conn.read_body(conn, @read_opts) do
      {:ok, data, _conn} ->
        with {:ok, decoded, _decoder} <- decode(decoder, data),
             {:ok, ctx, size} <- consume(io, ctx, size, max, decoded) do
          {:ok, ctx, size}
        end

      {:more, data, conn} ->
        with {:ok, decoded, decoder} <- decode(decoder, data),
             {:ok, ctx, size} <- consume(io, ctx, size, max, decoded) do
          read_loop(conn, io, ctx, size, max, decoder)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(nil, data), do: {:ok, data, nil}
  defp decode(decoder, data), do: ChunkedBody.feed(decoder, data)

  defp consume(io, ctx, size, max, data) do
    new_size = size + byte_size(data)

    if max != nil and new_size > max do
      {:error, :entity_too_large}
    else
      case IO.binwrite(io, data) do
        :ok -> {:ok, :crypto.hash_update(ctx, data), new_size}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
