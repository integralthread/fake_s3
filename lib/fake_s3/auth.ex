defmodule FakeS3.Auth do
  @moduledoc false

  import Plug.Conn
  require Logger

  alias FakeS3.{Config, S3XML}

  @algorithm "AWS4-HMAC-SHA256"

  def init(opts), do: opts

  def call(conn, _opts) do
    case Config.mode() do
      "noauth" -> conn
      "static" -> check(conn, strict: false)
      "strict" -> check(conn, strict: true)
      _ -> conn
    end
  end

  defp check(conn, opts) do
    access_key = Config.access_key()
    secret_key = Config.secret_key()

    if access_key == "" or secret_key == "" do
      reject(
        conn,
        500,
        "InternalError",
        "Static auth is enabled but no credentials are configured."
      )
    else
      verify(conn, opts, access_key, secret_key)
    end
  end

  defp verify(conn, opts, access_key, secret_key) do
    case parse_credentials(conn) do
      {:ok, auth} ->
        cond do
          auth.access_key != access_key ->
            reject(conn, 403, "InvalidAccessKeyId", "The access key ID does not exist.")

          expired?(auth) ->
            reject(conn, 403, "AccessDenied", "The request signature has expired.")

          true ->
            check_signature(conn, opts, auth, secret_key)
        end

      {:error, reason} ->
        if opts[:strict] do
          reject(conn, 403, "AccessDenied", "Request is missing valid authentication: #{reason}.")
        else
          conn
        end
    end
  end

  defp check_signature(conn, opts, auth, secret_key) do
    case verify_signature(conn, auth, secret_key) do
      :ok ->
        conn

      {:error, reason} ->
        if opts[:strict] do
          Logger.debug("SigV4 strict reject: #{inspect(reason)}")

          reject(
            conn,
            403,
            "SignatureDoesNotMatch",
            "The request signature we calculated does not match the signature you provided."
          )
        else
          Logger.debug("SigV4 mismatch ignored: #{inspect(reason)}")
          conn
        end
    end
  end

  defp reject(conn, status, code, message) do
    request_id = conn.assigns[:request_id] || "unknown"

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, S3XML.error(code, message, conn.request_path, request_id))
    |> halt()
  end

  ## Credential parsing

  # SigV4 arrives either in the Authorization header or, for presigned URLs,
  # entirely in the query string.
  defp parse_credentials(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] -> parse_authorization(value)
      _ -> parse_presigned(conn)
    end
  end

  defp parse_authorization(value) do
    case String.split(value, " ", parts: 2) do
      [@algorithm, rest] ->
        params = parse_kv(rest)

        with {:ok, credential} <- Map.fetch(params, "Credential"),
             {:ok, signed_headers} <- Map.fetch(params, "SignedHeaders"),
             {:ok, signature} <- Map.fetch(params, "Signature"),
             {:ok, access_key, scope} <- split_credential(credential) do
          {:ok,
           %{
             access_key: access_key,
             scope: scope,
             signed_headers: String.split(signed_headers, ";"),
             signature: signature,
             presigned: false,
             date: nil,
             expires: nil
           }}
        else
          _ -> {:error, :invalid_authorization}
        end

      _ ->
        {:error, :unsupported_algorithm}
    end
  end

  defp parse_presigned(conn) do
    params = Plug.Conn.Query.decode(conn.query_string)

    with @algorithm <- params["X-Amz-Algorithm"],
         credential when is_binary(credential) <- params["X-Amz-Credential"],
         signed_headers when is_binary(signed_headers) <- params["X-Amz-SignedHeaders"],
         signature when is_binary(signature) <- params["X-Amz-Signature"],
         {:ok, access_key, scope} <- split_credential(credential) do
      {:ok,
       %{
         access_key: access_key,
         scope: scope,
         signed_headers: String.split(signed_headers, ";"),
         signature: signature,
         presigned: true,
         date: params["X-Amz-Date"],
         expires: params["X-Amz-Expires"]
       }}
    else
      _ -> {:error, :missing_signature}
    end
  end

  defp split_credential(credential) do
    case String.split(credential, "/") do
      [access_key | scope_parts] when scope_parts != [] ->
        {:ok, access_key, Enum.join(scope_parts, "/")}

      _ ->
        :error
    end
  end

  defp parse_kv(rest) do
    rest
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp expired?(%{presigned: true, date: date, expires: expires})
       when is_binary(date) and is_binary(expires) do
    with {:ok, signed_at} <- parse_amz_date(date),
         {seconds, ""} <- Integer.parse(expires) do
      DateTime.diff(DateTime.utc_now(), signed_at) > seconds
    else
      _ -> false
    end
  end

  defp expired?(_), do: false

  defp parse_amz_date(
         <<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">>
       ) do
    with {:ok, date} <- Date.new(int(y), int(m), int(d)),
         {:ok, time} <- Time.new(int(h), int(mi), int(s)) do
      DateTime.new(date, time, "Etc/UTC")
    end
  end

  defp parse_amz_date(_), do: :error

  defp int(value), do: String.to_integer(value)

  ## Signature verification

  defp verify_signature(conn, auth, secret_key) do
    with {:ok, amz_date} <- fetch_amz_date(conn, auth),
         {:ok, {date, region, service}} <- parse_scope(auth.scope) do
      key = signing_key(secret_key, date, region, service)
      scope = "#{date}/#{region}/#{service}/aws4_request"

      candidates = canonical_requests(conn, auth, payload_hash(conn, auth))

      if Enum.any?(candidates, &matches?(&1, key, amz_date, scope, auth.signature)) do
        :ok
      else
        Logger.debug(fn ->
          "canonical request candidates:\n" <> Enum.join(candidates, "\n---\n")
        end)

        {:error, :signature_mismatch}
      end
    end
  end

  defp matches?(canonical_request, key, amz_date, scope, signature) do
    string_to_sign =
      [@algorithm, amz_date, scope, sha256_hex(canonical_request)]
      |> Enum.join("\n")

    key
    |> hmac_hex(string_to_sign)
    |> Plug.Crypto.secure_compare(signature)
  end

  # Clients disagree on how to canonicalise a query string, and the wire form
  # is genuinely ambiguous: "a+b" is a space under form encoding but a literal
  # '+' under RFC 3986. The AWS CLI and boto3 normalise to %20 before signing;
  # Req signs the bytes exactly as sent. Both are in the wild, so verification
  # accepts either reading rather than locking out half of them.
  defp canonical_requests(conn, auth, payload_hash) do
    signed = Enum.join(auth.signed_headers, ";")
    headers = canonical_headers(conn, auth.signed_headers)

    conn.query_string
    |> canonical_query_variants(auth.presigned)
    |> Enum.map(fn query ->
      [conn.method, canonical_uri(conn), query, headers, signed, payload_hash]
      |> Enum.join("\n")
    end)
  end

  defp fetch_amz_date(_conn, %{presigned: true, date: date}) when is_binary(date), do: {:ok, date}

  defp fetch_amz_date(conn, _auth) do
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

  defp payload_hash(_conn, %{presigned: true}), do: "UNSIGNED-PAYLOAD"

  defp payload_hash(conn, _auth) do
    case get_req_header(conn, "x-amz-content-sha256") do
      [value | _] -> value
      _ -> "UNSIGNED-PAYLOAD"
    end
  end

  # S3 signs the path exactly as the client put it on the wire: already
  # percent-encoded, and explicitly not normalized. Re-encoding it here turned
  # every "%20" into "%2520" and broke every key containing a space.
  defp canonical_uri(conn) do
    case conn.request_path do
      "" -> "/"
      path -> path
    end
  end

  # Built from the raw query string rather than a decoded map: decoding through
  # Plug.Conn.Query mangles keys containing brackets and loses the distinction
  # between "?acl" and "?acl=".
  defp canonical_query_variants(query_string, presigned?) do
    pairs =
      query_string
      |> String.split("&", trim: true)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)
      # The signature itself is never part of what was signed.
      |> then(fn pairs ->
        if presigned? do
          Enum.reject(pairs, fn {k, _} -> uri_decode(k) == "X-Amz-Signature" end)
        else
          pairs
        end
      end)

    [normalized_query(pairs), raw_query(pairs)]
    |> Enum.uniq()
  end

  defp normalized_query(pairs) do
    pairs
    |> Enum.map(fn {k, v} -> {uri_encode(uri_decode(k)), uri_encode(uri_decode(v))} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp raw_query(pairs) do
    pairs
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp canonical_headers(conn, signed_headers) do
    headers =
      conn.req_headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end)
      |> Map.new()

    headers = Map.put_new_lazy(headers, "host", fn -> default_host(conn) end)

    signed_headers
    |> Enum.map_join("\n", fn header -> "#{header}:#{Map.get(headers, header, "")}" end)
    |> Kernel.<>("\n")
  end

  defp default_host(conn) do
    case conn.port do
      80 -> conn.host
      443 -> conn.host
      port -> "#{conn.host}:#{port}"
    end
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

  defp sha256_hex(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  # Query strings are form-encoded on the wire, so a bare '+' means a space.
  # SigV4 canonicalises it back to %20, and decoding it as a literal '+' would
  # re-encode to %2B and break every signature over a query value with a space.
  defp uri_decode(value) do
    URI.decode_www_form(value)
  rescue
    ArgumentError -> value
  end

  defp uri_encode(value) do
    URI.encode(value, fn char ->
      char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in ~c"-_.~"
    end)
  end
end
