defmodule FakeS3.ChunkedBodyTest do
  @moduledoc """
  Unit tests for the aws-chunked decoder. Storing the framing verbatim used to
  corrupt both the object body and its ETag.
  """

  use ExUnit.Case, async: true

  alias FakeS3.ChunkedBody

  describe "decoding" do
    test "strips signed chunk framing" do
      raw = "b;chunk-signature=abc\r\nhello world\r\n0;chunk-signature=def\r\n\r\n"
      assert decode_all([raw]) == "hello world"
    end

    test "strips unsigned framing with a trailer" do
      raw = "b\r\nhello world\r\n0\r\nx-amz-checksum-crc32:AAAAAA==\r\n\r\n"
      assert decode_all([raw]) == "hello world"
    end

    test "joins multiple chunks" do
      raw = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n"
      assert decode_all([raw]) == "Hello World"
    end

    test "handles a body split at arbitrary boundaries" do
      raw = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n"

      # Every possible split point must produce the same result: chunk headers
      # and payloads can land across separate reads.
      for at <- 1..(byte_size(raw) - 1) do
        <<head::binary-size(at), tail::binary>> = raw
        assert decode_all([head, tail]) == "Hello World", "failed splitting at #{at}"
      end
    end

    test "handles byte-at-a-time delivery" do
      raw = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n"
      pieces = for <<byte <- raw>>, do: <<byte>>

      assert decode_all(pieces) == "Hello World"
    end

    test "emits payload before the chunk terminator arrives" do
      # A chunk larger than one read must not be buffered whole.
      {:ok, emitted, _decoder} =
        ChunkedBody.new() |> ChunkedBody.feed("a\r\n12345")

      assert emitted == "12345"
    end

    test "passes through an empty payload" do
      assert decode_all(["0\r\n\r\n"]) == ""
    end

    test "handles binary payloads containing CRLF" do
      payload = <<0, 13, 10, 255, 13, 10>>
      raw = "#{Integer.to_string(byte_size(payload), 16)}\r\n" <> payload <> "\r\n0\r\n\r\n"

      assert decode_all([raw]) == payload
    end

    test "ignores anything after the terminating chunk" do
      raw = "5\r\nHello\r\n0\r\n"
      {:ok, first, decoder} = ChunkedBody.feed(ChunkedBody.new(), raw)
      {:ok, second, _decoder} = ChunkedBody.feed(decoder, "x-amz-checksum-crc32:AA==\r\n\r\n")

      assert first <> second == "Hello"
    end

    test "rejects a non-hex chunk size" do
      assert {:error, :invalid_chunk_encoding} =
               ChunkedBody.feed(ChunkedBody.new(), "zz\r\ndata\r\n")
    end

    test "rejects a chunk not terminated by CRLF" do
      assert {:error, :invalid_chunk_encoding} =
               ChunkedBody.feed(ChunkedBody.new(), "5\r\nHelloXX7\r\n")
    end
  end

  defp decode_all(pieces) do
    {output, _decoder} =
      Enum.reduce(pieces, {"", ChunkedBody.new()}, fn piece, {acc, decoder} ->
        {:ok, decoded, decoder} = ChunkedBody.feed(decoder, piece)
        {acc <> decoded, decoder}
      end)

    output
  end
end
