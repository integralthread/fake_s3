defmodule FakeS3.Config do
  @moduledoc false

  require Logger

  def host, do: override(:host) || env("FAKES3_HOST", "127.0.0.1")

  def host_ip do
    host()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  def port do
    case override(:port) do
      nil -> env("FAKES3_PORT", "4569") |> String.to_integer()
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
    end
  end

  def data_dir, do: override(:data_dir) || env("FAKES3_DATA_DIR", "./.fakes3")

  def mode, do: override(:mode) || env("FAKES3_MODE", "noauth") |> String.downcase()

  def access_key, do: override(:access_key) || env("FAKES3_ACCESS_KEY", "")
  def secret_key, do: override(:secret_key) || env("FAKES3_SECRET_KEY", "")
  def region, do: override(:region) || env("FAKES3_REGION", "us-east-1")

  def log_level, do: override(:log_level) || env("FAKES3_LOG_LEVEL", "info") |> String.downcase()

  def max_body_bytes do
    case override(:max_body_bytes) do
      nil ->
        case System.get_env("FAKES3_MAX_BODY_BYTES") do
          nil -> nil
          "" -> nil
          value -> String.to_integer(value)
        end

      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        String.to_integer(value)
    end
  end

  def configure_logger do
    level =
      case log_level() do
        "debug" -> :debug
        "info" -> :info
        "warn" -> :warn
        "error" -> :error
        _ -> :info
      end

    Logger.configure(level: level)
  end

  defp env(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp override(key) do
    case Process.get(:fake_s3_config) do
      nil -> nil
      map when is_map(map) -> Map.get(map, key)
      list when is_list(list) -> Keyword.get(list, key)
      _ -> nil
    end
  end
end
