defmodule SymphonyElixir.Planner.DescriptionNormalizer do
  @moduledoc """
  Parses human-written plan issue descriptions to extract binding intent.

  Pure, I/O-free — accepts description text and WORKFLOW.md config, returns a
  normalized binding map that `ProjectMemory` and `Runner` use to write project
  memory and inherit routing labels to child issues.

  Supported phrases (case-insensitive):

    * Node aliases: `joey_pc`, `joey pc`, `joey-pc` → `joey-pc`
    * Agent aliases: `claude code`, `claude-code` → `claude-code`; `codex` → `codex`
    * Repo intent: `create a new repo`, `new repo`, `create repo <name>`
    * Repo name: inferred from explicit `create repo <name>`, then description
      "build a X app" pattern, then the issue title
    * Flags: `do not auto merge` / `don't auto merge` → `auto_merge: false`;
      `auto merge` → `auto_merge: true`; default is `false`
    * Tech stack: `Next.js`, `Supabase`, `React`, `PostgreSQL`, `Tailwind`, `TypeScript`

  A `vibe: …` line in the description is parsed first (higher priority) before
  searching the rest of the text.
  """

  @default_repo_owner "JozzyAI"

  @type repo_mode :: :create_new | :use_existing | nil
  @type repo_status :: :resolved | :needs_creation | :needs_confirmation | nil

  @type normalized_binding :: %{
          repo_mode: repo_mode(),
          repo_name: String.t() | nil,
          repo_owner: String.t(),
          repo_url: String.t() | nil,
          repo_status: repo_status(),
          node: String.t() | nil,
          node_id: String.t() | nil,
          agent: String.t() | nil,
          auto_merge: boolean(),
          human_review_required: boolean(),
          auto_promote_children: boolean(),
          tech_stack: [String.t()],
          open_questions: [String.t()],
          inherit_binding_to_children: boolean()
        }

  # ---------------------------------------------------------------------------
  # Pattern tables
  # ---------------------------------------------------------------------------

  @node_patterns [
    {~r/\bjoey[\s_\-]?pc\b/i, "joey-pc"}
  ]

  @agent_patterns [
    {~r/\bclaude[\s_\-]code\b/i, "claude-code"},
    {~r/\bcodex\b/i, "codex"}
  ]

  @create_repo_patterns [
    ~r/\bcreate\s+a\s+new\s+repo\b/i,
    ~r/\bmake\s+a\s+new\s+repo\b/i,
    ~r/\bnew\s+repo\b/i,
    ~r/\bcreate\s+new\s+repo\b/i,
    ~r/\bcreate\s+repo\b/i
  ]

  @explicit_repo_pattern ~r/\b(?:create|use)\s+repo\s+([A-Za-z0-9_\-]+)/i

  @app_name_pattern ~r/\bbuild\s+an?\s+([A-Za-z][A-Za-z0-9 ]+?)\s+(?:app|platform|service|project)\b/i

  @tech_patterns [
    {~r/\bnext\.?js\b/i, "Next.js"},
    {~r/\bsupabase\b/i, "Supabase"},
    {~r/\breact\b/i, "React"},
    {~r/\bpostgres(?:ql)?\b/i, "PostgreSQL"},
    {~r/\btailwind\b/i, "Tailwind CSS"},
    {~r/\btypescript\b/i, "TypeScript"}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parses `description` and returns a normalized binding map.

  `title` is used as a fallback when inferring a repo name from a "create a new
  repo" phrase with no explicit name. `config` must be a map (or struct) with a
  `:binding` field containing WORKFLOW.md binding configuration.
  """
  @spec normalize(String.t() | nil, String.t() | nil, map() | struct()) :: normalized_binding()
  def normalize(description, title, config) do
    text = description |> to_string() |> strip_project_memory()
    parsed = parse_text(text)

    node = normalize_node(parsed.node)
    node_id = resolve_node_id(node, config)
    agent = normalize_agent(parsed.agent)

    repo_owner = infer_repo_owner(config)
    allowed_repos = get_allowed_repos(config)

    {repo_mode, repo_name, repo_url, repo_status, extra_questions} =
      resolve_repo(parsed.repo_intent, parsed.explicit_repo_name, title, text, repo_owner, allowed_repos)

    %{
      repo_mode: repo_mode,
      repo_name: repo_name,
      repo_owner: repo_owner,
      repo_url: repo_url,
      repo_status: repo_status,
      node: node,
      node_id: node_id,
      agent: agent,
      auto_merge: parsed.auto_merge,
      human_review_required: true,
      auto_promote_children: get_auto_promote_children(config),
      tech_stack: parsed.tech_stack,
      open_questions: extra_questions,
      inherit_binding_to_children: true
    }
  end

  @doc """
  Returns label names to add to child issues based on `normalized_binding`.

  - `agent:<name>` — always added when agent is set
  - `node:<name>` — always added when node is set
  - `repo:<name>` — added when repo_name is set and repo_status is one of
    `:resolved`, `:needs_creation`, or `:needs_confirmation` (acts as an
    explicit routing signal even when the repo isn't yet in `allowed_repos`)
  """
  @spec child_labels(normalized_binding()) :: [String.t()]
  def child_labels(%{agent: agent, node: node, repo_name: repo_name, repo_status: repo_status}) do
    []
    |> maybe_label("agent", agent)
    |> maybe_label("node", node)
    |> maybe_repo_label(repo_name, repo_status)
  end

  # ---------------------------------------------------------------------------
  # Private: text parsing
  # ---------------------------------------------------------------------------

  defp parse_text(text) do
    # Vibe lines are parsed first (higher priority)
    vibe_text =
      text
      |> String.split("\n")
      |> Enum.filter(&String.match?(&1, ~r/^\s*vibe\s*:/i))
      |> Enum.join(" ")

    %{
      node: first_match(vibe_text, @node_patterns) || first_match(text, @node_patterns),
      agent: first_match(vibe_text, @agent_patterns) || first_match(text, @agent_patterns),
      repo_intent: detect_repo_intent(vibe_text, text),
      explicit_repo_name: detect_explicit_repo_name(vibe_text, text),
      auto_merge: detect_auto_merge(text),
      tech_stack: detect_tech_stack(text)
    }
  end

  defp first_match(text, patterns) do
    Enum.find_value(patterns, fn {regex, value} ->
      if Regex.match?(regex, text), do: value
    end)
  end

  defp detect_repo_intent(vibe_text, full_text) do
    if Enum.any?(@create_repo_patterns, &(Regex.match?(&1, vibe_text) or Regex.match?(&1, full_text))) do
      :create_new
    else
      nil
    end
  end

  defp detect_explicit_repo_name(vibe_text, full_text) do
    case Regex.run(@explicit_repo_pattern, vibe_text) || Regex.run(@explicit_repo_pattern, full_text) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp detect_auto_merge(text) do
    negative = ~r/\b(?:do\s+not|don'?t|no)\s+auto[\s_\-]?merge\b/i
    positive = ~r/\bauto[\s_\-]?merge\b/i

    cond do
      Regex.match?(negative, text) -> false
      Regex.match?(positive, text) -> true
      true -> false
    end
  end

  defp detect_tech_stack(text) do
    for {regex, name} <- @tech_patterns, Regex.match?(regex, text), do: name
  end

  # ---------------------------------------------------------------------------
  # Private: alias normalization and node_id resolution
  # ---------------------------------------------------------------------------

  defp normalize_node(nil), do: nil
  defp normalize_node(raw), do: String.replace(raw, "_", "-")

  defp normalize_agent(nil), do: nil
  defp normalize_agent(raw), do: raw

  defp resolve_node_id(nil, _config), do: nil

  defp resolve_node_id(node_name, config) do
    nodes = get_binding_nodes(config)

    case Map.get(nodes, node_name) do
      config_map when is_map(config_map) ->
        Map.get(config_map, "node_id") || System.get_env("SYMPHONY_NODE_ID")

      _ ->
        System.get_env("SYMPHONY_NODE_ID")
    end
  end

  defp get_binding_nodes(config) do
    binding = config && Map.get(config, :binding)
    nodes = binding && Map.get(binding, :nodes)
    if is_map(nodes), do: nodes, else: %{}
  end

  # ---------------------------------------------------------------------------
  # Private: repo resolution
  # ---------------------------------------------------------------------------

  defp infer_repo_owner(config) do
    binding = config && Map.get(config, :binding)
    repo_policy = binding && Map.get(binding, :repo_policy)
    orgs = repo_policy && Map.get(repo_policy, :allowed_github_orgs)

    case orgs do
      [org | _] -> org
      _ -> @default_repo_owner
    end
  end

  defp get_allowed_repos(config) do
    binding = config && Map.get(config, :binding)
    repo_policy = binding && Map.get(binding, :repo_policy)
    allowed = repo_policy && Map.get(repo_policy, :allowed_repos)
    if is_list(allowed), do: allowed, else: []
  end

  defp get_auto_promote_children(config) do
    planner = config && Map.get(config, :planner)
    value = planner && Map.get(planner, :auto_promote_children)
    value == true
  end

  defp resolve_repo(nil, nil, _title, _text, _owner, _allowed_repos) do
    {nil, nil, nil, nil, []}
  end

  defp resolve_repo(repo_intent, explicit_name, title, text, owner, allowed_repos) do
    repo_name = explicit_name || infer_repo_name(title, text)

    case {repo_intent, repo_name} do
      {:create_new, nil} ->
        {:create_new, nil, nil, :needs_confirmation,
         ["Specify a repo name (e.g. `create repo my_project`) in the description."]}

      {:create_new, name} ->
        url = "https://github.com/#{owner}/#{name}"

        if name in allowed_repos do
          {:create_new, name, url, :resolved, []}
        else
          {:create_new, name, url, :needs_creation,
           ["Confirm whether to create `#{owner}/#{name}` and add it to `binding.repo_policy.allowed_repos` in WORKFLOW.md."]}
        end

      {nil, _} ->
        {nil, nil, nil, nil, []}
    end
  end

  defp infer_repo_name(title, text) do
    infer_from_text(text) ||
      if is_binary(title) and title != "", do: normalize_to_snake(title)
  end

  defp infer_from_text(text) do
    case Regex.run(@app_name_pattern, text) do
      [_, name] -> normalize_to_snake(name)
      _ -> nil
    end
  end

  defp normalize_to_snake(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  # ---------------------------------------------------------------------------
  # Private: helpers
  # ---------------------------------------------------------------------------

  defp maybe_label(acc, _prefix, nil), do: acc
  defp maybe_label(acc, prefix, value), do: acc ++ ["#{prefix}:#{value}"]

  defp maybe_repo_label(acc, nil, _status), do: acc
  defp maybe_repo_label(acc, _name, nil), do: acc

  defp maybe_repo_label(acc, name, status)
       when status in [:resolved, :needs_creation, :needs_confirmation],
       do: acc ++ ["repo:#{name}"]

  defp maybe_repo_label(acc, _name, _status), do: acc

  defp strip_project_memory(description) do
    start_marker = "<!-- symphony:project-memory:v1:start -->"
    end_marker = "<!-- symphony:project-memory:v1:end -->"

    case String.split(description, start_marker, parts: 2) do
      [before, rest] ->
        case String.split(rest, end_marker, parts: 2) do
          [_block, after_block] -> String.trim(before) <> String.trim(after_block)
          [_rest_only] -> String.trim(before)
        end

      [text] ->
        text
    end
  end
end
