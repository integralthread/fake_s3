defmodule FakeS3.Time do
  @moduledoc false

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def now_iso, do: now() |> DateTime.to_iso8601()

  @doc """
  Renders a timestamp the way S3 renders it inside XML bodies: ISO 8601 with
  millisecond precision.
  """
  def to_xml(%DateTime{} = dt) do
    dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  def to_xml(iso) when is_binary(iso) do
    case parse(iso) do
      {:ok, dt} -> to_xml(dt)
      :error -> iso
    end
  end

  def to_xml(_), do: to_xml(now())

  @doc """
  Renders an RFC 7231 HTTP-date, as required for the `Last-Modified` header.

  Handing an ISO 8601 string to a client here is a protocol violation: HTTP
  date headers have a fixed grammar and clients parse them strictly.
  """
  def to_http_date(%DateTime{} = dt) do
    day_name = Enum.at(@days, Date.day_of_week(dt) - 1)
    month_name = Enum.at(@months, dt.month - 1)

    "#{day_name}, #{pad(dt.day)} #{month_name} #{dt.year} " <>
      "#{pad(dt.hour)}:#{pad(dt.minute)}:#{pad(dt.second)} GMT"
  end

  def to_http_date(iso) when is_binary(iso) do
    case parse(iso) do
      {:ok, dt} -> to_http_date(dt)
      :error -> to_http_date(now())
    end
  end

  def to_http_date(_), do: to_http_date(now())

  defp parse(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
