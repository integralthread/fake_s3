defmodule FakeS3.XML do
  @moduledoc """
  Minimal extraction for the handful of XML request bodies S3 clients send
  (DeleteObjects, CompleteMultipartUpload).

  Deliberately not a general parser. `:xmerl` interns every element name as an
  atom, so pointing it at request bodies from an untrusted client is an atom
  table exhaustion risk; these payloads are simple and fixed-shape enough that
  targeted extraction is both safer and sufficient.
  """

  @doc "Returns the inner content of every `<tag>...</tag>` occurrence."
  def extract_all(body, tag) when is_binary(body) do
    ~r{<(?:[\w.-]+:)?#{tag}(?:\s[^>]*)?>(.*?)</(?:[\w.-]+:)?#{tag}\s*>}s
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [inner] -> inner end)
  end

  def extract_all(_, _), do: []

  @doc "Returns the inner content of the first `<tag>...</tag>`, or nil."
  def extract_first(body, tag) when is_binary(body) do
    case extract_all(body, tag) do
      [first | _] -> first
      [] -> nil
    end
  end

  def extract_first(_, _), do: nil

  @doc "Returns the unescaped text of the first `<tag>...</tag>`, or nil."
  def text(body, tag) do
    case extract_first(body, tag) do
      nil -> nil
      value -> value |> String.trim() |> unescape()
    end
  end

  @doc "Returns the unescaped text of every `<tag>...</tag>`."
  def texts(body, tag) do
    body
    |> extract_all(tag)
    |> Enum.map(&(&1 |> String.trim() |> unescape()))
  end

  def unescape(value) do
    value
    |> String.replace(~r/&#x([0-9A-Fa-f]+);/, fn match ->
      match |> capture_hex() |> codepoint()
    end)
    |> String.replace(~r/&#(\d+);/, fn match ->
      match |> capture_decimal() |> codepoint()
    end)
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    # Ampersand last: unescaping it first would corrupt "&amp;lt;".
    |> String.replace("&amp;", "&")
  end

  defp capture_hex("&#x" <> rest), do: rest |> String.trim_trailing(";") |> String.to_integer(16)

  defp capture_decimal("&#" <> rest), do: rest |> String.trim_trailing(";") |> String.to_integer()

  defp codepoint(value) when value in 0..0x10FFFF, do: <<value::utf8>>
  defp codepoint(_), do: ""
end
