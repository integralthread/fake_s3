defmodule FakeS3.PostPolicy do
  @moduledoc """
  The base64 policy document that accompanies a browser form upload
  (`POST /<bucket>` with `multipart/form-data`).

  The policy is supplied by the client and states what the form is allowed to
  contain, so evaluating it is request validation rather than authentication:
  it is checked in every auth mode. Verifying the *signature* over the policy
  does need the secret key, so that stays with `FakeS3.Auth` and the configured
  mode.
  """

  # Fields that carry the credential or the upload itself, and so never need a
  # matching condition. S3 also ignores anything prefixed "x-ignore-".
  @exempt ~w(file policy signature x-amz-signature awsaccesskeyid
             x-amz-credential x-amz-algorithm x-amz-date x-amz-security-token
             x-amz-server-side-encryption)

  @doc """
  Decodes a policy document.

  Both `expiration` and `conditions` are required and are matched
  case-sensitively, which is what S3 does — an `EXPIRATION` key is a malformed
  document, not a spelling S3 accepts.
  """
  def decode(encoded) do
    with {:ok, json} <- base64(encoded),
         {:ok, %{} = policy} <- Jason.decode(json),
         %{"expiration" => expiration, "conditions" => conditions}
         when is_binary(expiration) and is_list(conditions) <- policy,
         {:ok, expires_at} <- parse_expiration(expiration) do
      {:ok, %{expires_at: expires_at, conditions: conditions}}
    else
      _ -> {:error, :invalid_policy_document}
    end
  end

  defp base64(value) when is_binary(value), do: Base.decode64(value, ignore: :whitespace)
  defp base64(_), do: :error

  # Elixir's from_iso8601 accepts any separator character, so a Python
  # str(datetime) ("2026-08-21 12:00:00+00:00") would slip through as valid.
  # S3 wants a real ISO 8601 timestamp, so require the T and a zone.
  @iso8601 ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/

  defp parse_expiration(value) do
    with true <- Regex.match?(@iso8601, value),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  @doc """
  Checks a decoded policy against the submitted form.

  `fields` is a map of lowercased field name to value, `bucket` the bucket from
  the URL (S3 conditions on it even though it is not a form field), and `size`
  the uploaded byte count for `content-length-range`.
  """
  def validate(policy, fields, bucket, size, now \\ DateTime.utc_now()) do
    with :ok <- check_expiry(policy, now),
         {:ok, matched} <- check_conditions(policy.conditions, fields, bucket, size) do
      check_unmatched_fields(fields, matched)
    end
  end

  defp check_expiry(%{expires_at: expires_at}, now) do
    case DateTime.compare(expires_at, now) do
      :gt -> :ok
      _ -> {:error, :access_denied}
    end
  end

  # Returns the set of field names some condition spoke about, so the caller can
  # reject a form that smuggled in an extra field the policy never authorised.
  defp check_conditions(conditions, fields, bucket, size) do
    Enum.reduce_while(conditions, {:ok, MapSet.new()}, fn condition, {:ok, matched} ->
      case check_condition(condition, fields, bucket, size) do
        {:ok, names} -> {:cont, {:ok, MapSet.union(matched, MapSet.new(names))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # {"bucket": "name"} / {"acl": "private"}
  defp check_condition(%{} = condition, fields, bucket, size) do
    case Map.to_list(condition) do
      [{name, value}] -> match_exact(name, value, fields, bucket, size)
      _ -> {:error, :invalid_policy_document}
    end
  end

  # Operators and field names are both matched case-insensitively, which is
  # what S3 does: ["StArTs-WiTh", "$KeY", ...] is a valid condition.
  defp check_condition([operator | rest], fields, bucket, size) when is_binary(operator) do
    check_operator(String.downcase(operator), rest, fields, bucket, size)
  end

  defp check_condition(_unrecognised, _fields, _bucket, _size) do
    {:error, :invalid_policy_document}
  end

  defp check_operator("eq", ["$" <> name, value], fields, bucket, size) do
    match_exact(name, value, fields, bucket, size)
  end

  defp check_operator("starts-with", ["$" <> name, prefix], fields, _bucket, _size) do
    name = String.downcase(name)

    case submitted(fields, name) do
      # S3 allows an empty starts-with to stand in for "any value".
      nil ->
        if prefix == "", do: {:ok, [name]}, else: {:error, :access_denied}

      value ->
        if String.starts_with?(value, prefix),
          do: {:ok, [name]},
          else: {:error, :access_denied}
    end
  end

  defp check_operator("content-length-range", [min, max], _fields, _bucket, size)
       when is_integer(min) and is_integer(max) do
    if size >= min and size <= max, do: {:ok, []}, else: {:error, :post_entity_too_large}
  end

  # A malformed range (missing or non-numeric bound) makes the whole document
  # invalid rather than merely unsatisfied.
  defp check_operator(_operator, _args, _fields, _bucket, _size) do
    {:error, :invalid_policy_document}
  end

  defp match_exact(name, expected, fields, bucket, _size) do
    name = String.downcase(name)
    actual = if name == "bucket", do: bucket, else: submitted(fields, name)

    cond do
      actual == nil -> {:error, :access_denied}
      to_string(actual) == to_string(expected) -> {:ok, [name]}
      true -> {:error, :access_denied}
    end
  end

  defp submitted(fields, name), do: Map.get(fields, name)

  # Anything the form sent that no condition mentioned is rejected, which is how
  # a policy limits what a browser form can do.
  defp check_unmatched_fields(fields, matched) do
    unmatched =
      fields
      |> Map.keys()
      |> Enum.reject(fn name ->
        name in @exempt or
          String.starts_with?(name, "x-ignore-") or
          MapSet.member?(matched, name)
      end)

    if unmatched == [], do: :ok, else: {:error, :access_denied}
  end
end
