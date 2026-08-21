defmodule FakeS3.ChunkedBody do
  @moduledoc """
  Streaming decoder for `Content-Encoding: aws-chunked` request bodies.

  AWS SDKs frame the payload themselves whenever streaming signatures or
  trailing checksums are enabled:

      <hex-size>[;chunk-signature=<sig>]\\r\\n<data>\\r\\n
      ...
      0[;chunk-signature=<sig>]\\r\\n
      [x-amz-checksum-crc32:<value>\\r\\n]
      \\r\\n

  Storing that verbatim corrupts the object and the ETag, so it has to be
  stripped back out. The decoder is fed arbitrary slices of the raw body and
  emits only payload bytes, buffering whatever it cannot yet interpret.
  """

  defstruct state: :size, buffer: <<>>, done: false

  def new, do: %__MODULE__{}

  def feed(%__MODULE__{done: true} = decoder, _data), do: {:ok, <<>>, decoder}

  def feed(%__MODULE__{} = decoder, data) do
    decode(%{decoder | buffer: decoder.buffer <> data}, [])
  end

  defp decode(%__MODULE__{state: :size, buffer: buffer} = decoder, acc) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case parse_size(line) do
          {:ok, 0} -> decode(%{decoder | state: :trailer, buffer: rest}, acc)
          {:ok, size} -> decode(%{decoder | state: {:data, size}, buffer: rest}, acc)
          :error -> {:error, :invalid_chunk_encoding}
        end

      [_partial] ->
        emit(acc, decoder)
    end
  end

  defp decode(%__MODULE__{state: {:data, remaining}, buffer: buffer} = decoder, acc) do
    available = byte_size(buffer)

    cond do
      # The whole chunk plus its CRLF terminator has arrived.
      available >= remaining + 2 ->
        <<chunk::binary-size(remaining), separator::binary-size(2), rest::binary>> = buffer

        if separator == "\r\n" do
          decode(%{decoder | state: :size, buffer: rest}, [acc, chunk])
        else
          {:error, :invalid_chunk_encoding}
        end

      # Chunks can be larger than a single read, so emit what is certainly
      # payload rather than buffering the whole thing in memory.
      remaining > 0 and available > 0 ->
        take = min(available, remaining)
        <<chunk::binary-size(take), rest::binary>> = buffer
        emit([acc, chunk], %{decoder | state: {:data, remaining - take}, buffer: rest})

      true ->
        emit(acc, decoder)
    end
  end

  defp decode(%__MODULE__{state: :trailer} = decoder, acc) do
    # Everything after the zero-length chunk is trailer headers, which are
    # metadata rather than payload.
    emit(acc, %{decoder | buffer: <<>>, done: true})
  end

  defp emit(acc, decoder), do: {:ok, IO.iodata_to_binary(acc), decoder}

  defp parse_size(line) do
    hex =
      line
      |> :binary.split(";")
      |> hd()
      |> String.trim()

    case Integer.parse(hex, 16) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> :error
    end
  end
end
