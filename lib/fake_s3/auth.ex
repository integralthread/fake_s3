defmodule FakeS3.Auth do
  @moduledoc false

  import Plug.Conn
  require Logger

  alias FakeS3.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    mode = Config.mode()

    case mode do
      "noauth" ->
        conn

      "static" ->
        check_static(conn, strict: false)

      "strict" ->
        check_static(conn, strict: true)

      _ ->
        conn
    end
  end

  defp check_static(conn, opts) do
    access_key = Config.access_key()
    secret_key = Config.secret_key()

    if access_key == "" or secret_key == "" do
      conn
      |> send_resp(500, "Static auth enabled but missing credentials")
      |> halt()
    else
      case parse_authorization(conn) do
        {:ok, auth} ->
          if auth.access_key != access_key do
            reject(conn)
          else
            case verify_signature(conn, auth, secret_key) do
              :ok ->
                conn

              {:error, reason} ->
                if opts[:strict] do
                  Logger.debug("SigV4 strict reject: #{inspect(reason)}")
                  reject(conn)
                else
                  Logger.debug("SigV4 mismatch ignored: #{inspect(reason)}")
                  conn
                end
            end
          end

        _ ->
          if opts[:strict] do
            reject(conn)
          else
            conn
          end
      end
    end
  end

  defp reject(conn) do
    conn
    |> send_resp(403, "Forbidden")
    |> halt()
  end

  defp parse_authorization(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] ->
        case String.split(value, " ", parts: 2) do
          ["AWS4-HMAC-SHA256", rest] ->
            params = parse_kv(rest)

            with {:ok, credential} <- Map.fetch(params, "Credential"),
                 {:ok, signed_headers} <- Map.fetch(params, "SignedHeaders"),
                 {:ok, signature} <- Map.fetch(params, "Signature") do
              [access_key | scope_parts] = String.split(credential, "/")
              scope = Enum.join(scope_parts, "/")

              {:ok,
               %{
                 access_key: access_key,
                 scope: scope,
                 signed_headers: String.split(signed_headers, ";"),
                 signature: signature
               }}
            else
              _ -> {:error, :invalid_authorization}
            end

          _ ->
            {:error, :unsupported}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp parse_kv(rest) do
    rest
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {k, v}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp verify_signature(conn, auth, secret_key) do
    with {:ok, amz_date} <- fetch_amz_date(conn),
         {:ok, {date, region, service}} <- parse_scope(auth.scope),
         {:ok, payload_hash} <- payload_hash(conn) do
      canonical_request =
        canonical_request(conn, auth.signed_headers, payload_hash)

      string_to_sign =
        ["AWS4-HMAC-SHA256", amz_date, "#{date}/#{region}/#{service}/aws4_request", sha256_hex(canonical_request)]
        |> Enum.join("\n")

      signature =
        signing_key(secret_key, date, region, service)
        |> hmac_hex(string_to_sign)

      if signature == auth.signature do
        :ok
      else
        {:error, :signature_mismatch}
      end
    end
  end

  defp fetch_amz_date(conn) do
    case get_req_header(conn, "x-amz-date") do
      [value | _] -> {:ok, value}
      _ -> {:error, :missing_amz_date}
    end
  end

  defp parse_scope(scope) do
    case String.split(scope, "/") do
      [date, region, service, "aws4_request"] -> {:ok, {date, region, service}}
      _ -> {:error, :invalid_scope}
    end
  end

  defp payload_hash(conn) do
    case get_req_header(conn, "x-amz-content-sha256") do
      [value | _] -> {:ok, value}
      _ -> {:ok, "UNSIGNED-PAYLOAD"}
    end
  end

  defp canonical_request(conn, signed_headers, payload_hash) do
    method = conn.method
    uri = canonical_uri(conn.request_path)
    query = canonical_query(conn.query_string)
    headers = canonical_headers(conn, signed_headers)
    signed = Enum.join(signed_headers, ";")

    [method, uri, query, headers, signed, payload_hash]
    |> Enum.join("\n")
  end

  defp canonical_uri(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.map(&uri_encode/1)
    |> Enum.join("/")
    |> case do
      "" -> "/"
      value -> value
    end
  end

  defp canonical_query(query_string) do
    query_string
    |> Plug.Conn.Query.decode()
    |> Enum.flat_map(fn
      {k, v} when is_list(v) -> Enum.map(v, fn item -> {k, item} end)
      {k, v} -> [{k, v}]
    end)
    |> Enum.map(fn {k, v} -> {uri_encode(k), uri_encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp canonical_headers(conn, signed_headers) do
    headers =
      conn.req_headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end)
      |> Map.new()

    host_value =
      headers["host"] ||
        (case conn.port do
           80 -> conn.host
           443 -> conn.host
           _ -> "#{conn.host}:#{conn.port}"
         end)

    headers = Map.put(headers, "host", host_value)

    signed_headers
    |> Enum.map(fn header ->
      value = Map.get(headers, header, "")
      "#{header}:#{value}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp signing_key(secret_key, date, region, service) do
    ("AWS4" <> secret_key)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hmac_hex(key, data), do: Base.encode16(hmac(key, data), case: :lower)

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp uri_encode(nil), do: ""

  defp uri_encode(value) do
    URI.encode(value, fn char ->
      char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in ~c"-_.~"
    end)
  end
end
