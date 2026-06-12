defmodule SymphonyElixir.Redact do
  @moduledoc """
  Recursively redacts sensitive values from arbitrary terms before they are
  logged, inspected, or otherwise surfaced in diagnostics, run records, or
  tool output.

  Any map, struct, or keyword-list entry whose key contains (case
  insensitive) one of: `key`, `token`, `secret`, `password`, `credential`,
  `aes`, `approval`, `stop`, `event` — has its value replaced with
  `"[REDACTED]"`. Lists and tuples are walked recursively. Everything else
  (strings, numbers, atoms, structs) passes through unchanged.
  """

  @sensitive_substrings ~w(key token secret password credential aes approval stop event)

  @redacted "[REDACTED]"

  @spec redact(term()) :: term()
  def redact(value) when is_struct(value), do: value

  def redact(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      if sensitive_key?(k), do: {k, @redacted}, else: {k, redact(v)}
    end)
  end

  def redact(value) when is_list(value) do
    Enum.map(value, &redact_entry/1)
  end

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value), do: value

  defp redact_entry({k, v}) when is_atom(k) or is_binary(k) do
    if sensitive_key?(k), do: {k, @redacted}, else: {k, redact(v)}
  end

  defp redact_entry(value), do: redact(value)

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_substrings, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(_key), do: false
end
