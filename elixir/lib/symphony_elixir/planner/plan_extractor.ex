defmodule SymphonyElixir.Planner.PlanExtractor do
  @moduledoc """
  Pure utilities for extracting and validating the planner's final JSON
  block (a list of child issue specs) from raw Codex output.

  No part of this module performs any I/O: it only parses and validates the
  string it is given.
  """

  @max_children 20

  @type child_spec :: %{
          title: String.t(),
          description: String.t(),
          acceptance_criteria: [String.t()],
          labels: [String.t()],
          execution_mode: String.t(),
          independent: boolean()
        }

  @doc """
  Extracts and validates the planner's child issue specs from raw Codex
  output.

  Returns `{:ok, %{children: [child_spec()]}}` on success, or `{:error,
  reason}` if no valid planner JSON block was found or the children failed
  validation.
  """
  @spec extract_plan(String.t()) :: {:ok, %{children: [child_spec()]}} | {:error, term()}
  def extract_plan(output) when is_binary(output) do
    with {:ok, json} <- extract_json_block(output),
         {:ok, children} <- validate_children(Map.get(json, "children")) do
      {:ok, %{children: children}}
    end
  end

  @doc """
  Finds the final fenced code block in `output` that decodes to a JSON
  object containing a `"children"` key, and returns the decoded map.

  Possible errors:

    * `:no_json_block_found` - there are no fenced code blocks at all
    * `:invalid_json` - none of the fenced blocks contain valid JSON
    * `:missing_children` - at least one block was valid JSON, but none
      had a `"children"` key
  """
  @spec extract_json_block(String.t()) ::
          {:ok, map()} | {:error, :no_json_block_found | :invalid_json | :missing_children}
  def extract_json_block(output) when is_binary(output) do
    case fenced_blocks(output) do
      [] -> {:error, :no_json_block_found}
      blocks -> blocks |> Enum.reverse() |> find_planner_block(false)
    end
  end

  @doc """
  Validates and normalizes a list of raw child issue spec maps (as decoded
  from JSON, with string keys).

  Applies the following rules to each child:

    * `"title"` must be a non-empty string
    * `"description"` must be a non-empty string
    * `"acceptance_criteria"` must be a non-empty list of non-empty strings
    * `"labels"` defaults to `[]` and keeps only string entries
    * `"execution_mode"` defaults to `"manual_review"` when missing/blank
    * `"independent"` defaults to `false` when missing or not a boolean

  The overall list must contain between 1 and #{@max_children} children.
  """
  @spec validate_children(term()) :: {:ok, [child_spec()]} | {:error, term()}
  def validate_children(children) when is_list(children) do
    cond do
      children == [] ->
        {:error, :empty_children}

      length(children) > @max_children ->
        {:error, :too_many_children}

      true ->
        children
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {child, index}, {:ok, acc} ->
          case validate_child(child, index) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end
    end
  end

  def validate_children(_other), do: {:error, :children_not_list}

  # ---------------------------------------------------------------------------
  # Fenced block extraction
  # ---------------------------------------------------------------------------

  defp fenced_blocks(text) do
    ~r/```[^\n`]*\n(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> String.trim(block) end)
  end

  defp find_planner_block([], false), do: {:error, :invalid_json}
  defp find_planner_block([], true), do: {:error, :missing_children}

  defp find_planner_block([block | rest], any_valid_json?) do
    case Jason.decode(block) do
      {:ok, %{"children" => _} = json} -> {:ok, json}
      {:ok, _decoded} -> find_planner_block(rest, true)
      {:error, _reason} -> find_planner_block(rest, any_valid_json?)
    end
  end

  # ---------------------------------------------------------------------------
  # Child validation
  # ---------------------------------------------------------------------------

  defp validate_child(child, index) when is_map(child) do
    with {:ok, title} <- require_non_empty_string(child, "title", index),
         {:ok, description} <- require_non_empty_string(child, "description", index),
         {:ok, acceptance_criteria} <- require_non_empty_string_list(child, "acceptance_criteria", index) do
      {:ok,
       %{
         title: title,
         description: description,
         acceptance_criteria: acceptance_criteria,
         labels: string_list(Map.get(child, "labels")),
         execution_mode: non_empty_string_or_default(Map.get(child, "execution_mode"), "manual_review"),
         independent: boolean_or_default(Map.get(child, "independent"), false)
       }}
    end
  end

  defp validate_child(_other, index), do: {:error, {:invalid_child, index, :not_a_map}}

  defp require_non_empty_string(map, key, index) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:invalid_child, index, {:empty_field, key}}}
        else
          {:ok, value}
        end

      _missing ->
        {:error, {:invalid_child, index, {:missing_field, key}}}
    end
  end

  defp require_non_empty_string_list(map, key, index) do
    case Map.get(map, key) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &valid_non_empty_string?/1) do
          {:ok, list}
        else
          {:error, {:invalid_child, index, {:invalid_field, key}}}
        end

      [] ->
        {:error, {:invalid_child, index, {:empty_field, key}}}

      _missing ->
        {:error, {:invalid_child, index, {:missing_field, key}}}
    end
  end

  defp valid_non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  defp non_empty_string_or_default(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      _ -> value
    end
  end

  defp non_empty_string_or_default(_value, default), do: default

  defp boolean_or_default(value, _default) when is_boolean(value), do: value
  defp boolean_or_default(_value, default), do: default
end
