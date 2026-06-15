defmodule SymphonyElixir.Planner.Prompt do
  @moduledoc """
  Builds the Planner prompt used to decompose a parent Linear issue into a
  set of small, PR-sized child issue specs.

  This is separate from `SymphonyElixir.PromptBuilder`, which builds prompts
  for the coding agent that implements a single issue. `build/1` is a pure
  function: it takes a plain map of context and returns a prompt string, with
  no Linear, workflow, or orchestrator dependencies.
  """

  @json_shape """
  ```json
  {
    "children": [
      {
        "title": "...",
        "description": "...",
        "acceptance_criteria": ["...", "..."],
        "labels": ["..."],
        "execution_mode": "manual_review",
        "independent": false
      }
    ]
  }
  ```
  """

  @type input :: %{
          optional(:parent_identifier) => String.t() | nil,
          optional(:parent_title) => String.t() | nil,
          optional(:parent_description) => String.t() | nil,
          optional(:project_name) => String.t() | nil,
          optional(:project_id) => String.t() | nil,
          optional(:project_description) => String.t() | nil,
          optional(:project_labels) => [String.t()],
          optional(:repo_url) => String.t() | nil,
          optional(:repo_tree) => String.t() | nil
        }

  @spec build(input()) :: String.t()
  def build(input) when is_map(input) do
    [
      intro(),
      parent_issue_section(input),
      project_section(input),
      repo_section(input),
      instructions_section(),
      output_format_section()
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp intro do
    """
    You are the Planner.

    Read the parent issue and project context below, then break the parent \
    issue down into a set of small, independent, PR-sized child issues that \
    other coding agents can implement one at a time.
    """
    |> String.trim_trailing()
  end

  defp parent_issue_section(input) do
    identifier = display(Map.get(input, :parent_identifier))
    title = display(Map.get(input, :parent_title))
    description = blank_to_nil(Map.get(input, :parent_description)) || "No description provided."

    """
    ## Parent issue

    Identifier: #{identifier}
    Title: #{title}

    Description:
    #{description}
    """
    |> String.trim_trailing()
  end

  defp project_section(input) do
    name = blank_to_nil(Map.get(input, :project_name))
    id = blank_to_nil(Map.get(input, :project_id))
    description = blank_to_nil(Map.get(input, :project_description))
    labels = Map.get(input, :project_labels, []) || []

    if is_nil(name) and is_nil(id) and is_nil(description) and labels == [] do
      nil
    else
      body =
        [
          project_line(name, id),
          description && "Description:\n#{description}",
          labels != [] && "Labels: #{Enum.join(labels, ", ")}"
        ]
        |> Enum.reject(&(&1 in [nil, false]))
        |> Enum.join("\n\n")

      "## Project context\n\n#{body}"
    end
  end

  defp project_line(nil, nil), do: "Project: (none)"
  defp project_line(name, nil), do: "Project: #{display(name)}"
  defp project_line(nil, id), do: "Project: (unnamed) (#{id})"
  defp project_line(name, id), do: "Project: #{display(name)} (#{id})"

  defp repo_section(input) do
    repo_url = blank_to_nil(Map.get(input, :repo_url))
    repo_tree = blank_to_nil(Map.get(input, :repo_tree))

    if is_nil(repo_url) and is_nil(repo_tree) do
      nil
    else
      body =
        [
          repo_url && "Repo URL: #{repo_url}",
          repo_tree && "File tree:\n#{repo_tree}"
        ]
        |> Enum.reject(&(&1 in [nil, false]))
        |> Enum.join("\n\n")

      "## Repository\n\n#{body}"
    end
  end

  defp instructions_section do
    """
    ## Instructions

    - Decompose the parent issue into 5 to 10 child issues.
    - Each child issue must be small enough to implement and review in a single pull request (PR-sized).
    - Each child issue must include clear, testable acceptance criteria.
    - Each child issue's "description" must include the exact sentence: "Open a PR, do not merge."
    - Default "execution_mode" to "manual_review" unless there is a strong reason to choose a different value.
    - Do not include API keys, tokens, passwords, or other secrets anywhere in your output.
    - Do not claim that any work has already been done.
    - Do not create pull requests, and do not instruct anyone to merge a pull request.
    - Do not output any prose, explanation, or commentary outside the final fenced JSON block.
    """
    |> String.trim_trailing()
  end

  defp output_format_section do
    """
    ## Output format

    Respond with exactly one fenced JSON code block as the LAST thing in \
    your output, containing the child issue specs in this shape:

    #{@json_shape}
    Do not write anything after the closing fence of that JSON code block.
    """
    |> String.trim_trailing()
  end

  defp display(nil), do: "(none)"
  defp display(""), do: "(none)"
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
