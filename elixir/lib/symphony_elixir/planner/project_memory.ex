defmodule SymphonyElixir.Planner.ProjectMemory do
  @moduledoc """
  Manages the `<!-- symphony:project-memory:v1 -->` block in parent plan issue
  descriptions.

  Pure, I/O-free — takes the current description string and a normalized binding
  map (from `DescriptionNormalizer`) and returns an updated description string.

  Marker semantics:

    * The human-written text OUTSIDE the markers is preserved verbatim.
    * The managed block INSIDE the markers is replaced on every planner run.
    * No duplicate blocks are created — idempotent on re-runs.

  Separate marker for child inheritance (`symphony:inherited-project-memory:v1`)
  is written into each child issue description so the agent sees what repo/node/
  agent to target without having to re-read the parent.
  """

  @start_marker "<!-- symphony:project-memory:v1:start -->"
  @end_marker "<!-- symphony:project-memory:v1:end -->"

  @inherited_start "<!-- symphony:inherited-project-memory:v1:start -->"
  @inherited_end "<!-- symphony:inherited-project-memory:v1:end -->"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Inserts or replaces the managed project-memory block in `description`.

  The human-written text outside the markers is preserved verbatim. The managed
  block is rebuilt from `normalized_binding` and `title` on every call.
  """
  @spec write(String.t() | nil, map(), String.t() | nil) :: String.t()
  def write(description, normalized_binding, title) do
    description = description || ""
    {human_text, _old_block} = split(description)
    block = build_block(normalized_binding, title)
    human_part = String.trim(human_text)

    if human_part == "" do
      block
    else
      human_part <> "\n\n" <> block
    end
  end

  @doc """
  Splits `description` into `{human_text, memory_block | nil}`.

  `human_text` contains everything outside the managed markers (trimmed).
  `memory_block` is the trimmed content inside the markers, or `nil` if absent.
  """
  @spec split(String.t()) :: {String.t(), String.t() | nil}
  def split(description) when is_binary(description) do
    case String.split(description, @start_marker, parts: 2) do
      [before, rest] ->
        case String.split(rest, @end_marker, parts: 2) do
          [block, after_block] ->
            human_text = (String.trim(before) <> String.trim(after_block)) |> String.trim()
            {human_text, String.trim(block)}

          [_rest_only] ->
            # Unclosed marker — treat entire string as human text
            {description, nil}
        end

      [_no_marker] ->
        {description, nil}
    end
  end

  @doc """
  Builds the full managed block (including open/close markers) from a normalized
  binding map.
  """
  @spec build_block(map(), String.t() | nil) :: String.t()
  def build_block(normalized_binding, title) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    [
      @start_marker,
      "## Symphony Project Memory",
      product_summary_section(normalized_binding, title),
      tech_stack_section(normalized_binding),
      vibe_binding_section(normalized_binding),
      open_questions_section(normalized_binding),
      "",
      "*Last normalized by Symphony: #{now}, version: project-memory:v1*",
      @end_marker
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Builds the short `<!-- symphony:inherited-project-memory:v1 -->` block written
  into each child issue description. Returns `nil` when no binding fields are set.
  """
  @spec build_inherited_block(map(), String.t() | nil) :: String.t() | nil
  def build_inherited_block(normalized_binding, parent_identifier) do
    if has_any_binding?(normalized_binding) do
      [
        @inherited_start,
        "Parent: #{parent_identifier || "unknown"}",
        repo_line(normalized_binding),
        node_line(normalized_binding),
        agent_line(normalized_binding),
        "Human review required: #{normalized_binding.human_review_required}",
        if(is_nil(normalized_binding.auto_merge), do: nil, else: "Auto merge: #{normalized_binding.auto_merge}"),
        @inherited_end
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp has_any_binding?(%{node: node, agent: agent, repo_url: repo_url, repo_name: repo_name}) do
    node != nil or agent != nil or repo_url != nil or repo_name != nil
  end

  defp product_summary_section(_nb, nil), do: nil
  defp product_summary_section(_nb, ""), do: nil

  defp product_summary_section(nb, title) do
    tech =
      case nb.tech_stack do
        [] -> ""
        stack -> " — " <> Enum.join(stack, ", ")
      end

    "### Product Summary\n#{title}#{tech}."
  end

  defp tech_stack_section(%{tech_stack: []}), do: nil

  defp tech_stack_section(%{tech_stack: stack}) do
    items = Enum.map_join(stack, "\n", &"- #{&1}")
    "### Tech Stack\n#{items}"
  end

  defp vibe_binding_section(nb) do
    lines =
      [
        yaml_line("repo_mode", nb.repo_mode),
        yaml_line("repo_owner", nb.repo_owner),
        yaml_line("repo_name", nb.repo_name),
        yaml_line("repo_url", nb.repo_url),
        yaml_line("repo_status", nb.repo_status),
        yaml_line("node", nb.node),
        yaml_line("node_id", nb.node_id),
        yaml_line("agent", nb.agent),
        yaml_line("auto_merge", nb.auto_merge),
        yaml_line("human_review_required", nb.human_review_required),
        yaml_line("auto_promote_children", Map.get(nb, :auto_promote_children)),
        yaml_line("inherit_binding_to_children", nb.inherit_binding_to_children)
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [] do
      nil
    else
      "### Vibe Binding\n```yaml\n#{Enum.join(lines, "\n")}\n```"
    end
  end

  defp yaml_line(_key, nil), do: nil
  defp yaml_line(key, value) when is_atom(value), do: "#{key}: #{value}"
  defp yaml_line(key, value) when is_boolean(value), do: "#{key}: #{value}"
  defp yaml_line(key, value) when is_binary(value), do: "#{key}: #{value}"

  defp open_questions_section(%{open_questions: []}), do: nil

  defp open_questions_section(%{open_questions: questions}) do
    items = Enum.map_join(questions, "\n", &"- #{&1}")
    "### Open Questions\n#{items}"
  end

  defp repo_line(%{repo_url: url}) when is_binary(url), do: "Repo: #{url}"
  defp repo_line(%{repo_name: name}) when is_binary(name), do: "Repo: needs_confirmation (#{name})"
  defp repo_line(_), do: nil

  defp node_line(%{node: node, node_id: node_id}) when is_binary(node) do
    if is_binary(node_id), do: "Node: #{node} / #{node_id}", else: "Node: #{node}"
  end

  defp node_line(_), do: nil

  defp agent_line(%{agent: agent}) when is_binary(agent), do: "Agent: #{agent}"
  defp agent_line(_), do: nil
end
