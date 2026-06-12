defmodule SymphonyElixir.Binding do
  @moduledoc """
  Resolves repo/node/agent binding from Linear labels and WORKFLOW.md config.

  Labels are parsed from issue labels and project labels. Resolution priority:
    1. Issue labels
    2. Project labels
    3. binding.defaults (WORKFLOW.md)

  Label syntax (colon and slash forms are both supported):
    repo:https://github.com/JozzyAI/fin_bot
    repo:JozzyAI/fin_bot
    repo:fin_bot
    repo/fin_bot
    repo/JozzyAI/fin_bot
    node:company-node  /  node/company-node
    agent:claude-code  /  agent/claude-code
  """

  @type label_tag :: {:repo, String.t()} | {:node, String.t()} | {:agent, String.t()} | :unknown

  @type resolved :: %{
          repo_url: String.t() | nil,
          repo_branch_prefix: String.t() | nil,
          node: String.t() | nil,
          node_id: String.t() | nil,
          relay: String.t() | nil,
          token: String.t() | nil,
          encrypt: boolean(),
          agent: String.t() | nil,
          permission_mode: String.t()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parse a single label string.

  Returns `{:repo, value}`, `{:node, name}`, `{:agent, name}`, or `:unknown`.
  """
  @spec parse_label(String.t()) :: label_tag()
  def parse_label(label) when is_binary(label) do
    label = String.trim(label)

    cond do
      String.starts_with?(label, "repo:") ->
        {:repo, String.slice(label, 5..-1//1) |> String.trim()}

      String.starts_with?(label, "node:") ->
        {:node, String.slice(label, 5..-1//1) |> String.trim()}

      String.starts_with?(label, "agent:") ->
        {:agent, String.slice(label, 6..-1//1) |> String.trim()}

      Regex.match?(~r{^repo/(.+)$}, label) ->
        [_, value] = Regex.run(~r{^repo/(.+)$}, label)
        {:repo, value}

      Regex.match?(~r{^node/([^/]+)$}, label) ->
        [_, value] = Regex.run(~r{^node/([^/]+)$}, label)
        {:node, value}

      Regex.match?(~r{^agent/([^/]+)$}, label) ->
        [_, value] = Regex.run(~r{^agent/([^/]+)$}, label)
        {:agent, value}

      true ->
        :unknown
    end
  end

  @doc """
  Extract the repo/node/agent tags from a list of label strings.

  Returns the first value seen for each type, plus a `:conflicts` map
  listing every value seen for any type with more than one match (empty
  list when there's no conflict for that type).
  """
  @spec extract_labels([String.t()]) :: %{
          repo: String.t() | nil,
          node: String.t() | nil,
          agent: String.t() | nil,
          conflicts: %{repo: [String.t()], node: [String.t()], agent: [String.t()]}
        }
  def extract_labels(labels) when is_list(labels) do
    grouped =
      labels
      |> Enum.map(&parse_label/1)
      |> Enum.reduce(%{repo: [], node: [], agent: []}, fn
        {:repo, v}, acc -> %{acc | repo: acc.repo ++ [v]}
        {:node, v}, acc -> %{acc | node: acc.node ++ [v]}
        {:agent, v}, acc -> %{acc | agent: acc.agent ++ [v]}
        :unknown, acc -> acc
      end)

    %{
      repo: List.first(grouped.repo),
      node: List.first(grouped.node),
      agent: List.first(grouped.agent),
      conflicts: %{
        repo: if(length(grouped.repo) > 1, do: grouped.repo, else: []),
        node: if(length(grouped.node) > 1, do: grouped.node, else: []),
        agent: if(length(grouped.agent) > 1, do: grouped.agent, else: [])
      }
    }
  end

  @doc """
  Resolve the complete binding for an issue.

  When `binding` is configured in settings (has at least one node defined),
  uses label-based resolution with security validation.

  When no `binding` is configured, falls back to the legacy `external:` and
  `repo:` config fields (backward compatibility for older WORKFLOW.md files).

  Returns `{:ok, resolved_map}` or `{:error, reason}`.
  """
  @spec resolve(map(), struct()) :: {:ok, resolved()} | {:error, term()}
  def resolve(issue, settings) do
    if has_binding?(settings.binding) do
      do_resolve_binding(issue, settings.binding)
    else
      do_resolve_legacy(settings)
    end
  end

  @doc """
  Render an error returned by `resolve/2` as a short, human-readable
  sentence suitable for posting back to the Linear issue as a comment.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:conflicting_labels, type, values}) do
    labels = Enum.map_join(values, ", ", &"#{type}:#{&1}")
    "Found #{length(values)} conflicting `#{type}:*` labels (#{labels}) — only one `#{type}:*` label is allowed per issue."
  end

  def describe_error({:unknown_agent, name, known}) do
    "Unknown `agent:#{name}` label — configured agents are: #{Enum.join(known, ", ")}."
  end

  def describe_error({:unknown_node, name, known}) do
    "Unknown `node:#{name}` label — configured nodes are: #{Enum.join(known, ", ")}."
  end

  def describe_error({:unknown_repo, repo_name, raw, allowed}) do
    "Unknown repo #{inspect(repo_name)} in `repo:#{raw}` label — configured repos are: #{Enum.join(allowed, ", ")}."
  end

  def describe_error({:agent_not_allowed_on_node, name, node_name, allowed}) do
    "Agent `#{name}` is not allowed on node `#{node_name}` (allowed agents on that node: #{Enum.join(allowed, ", ")})."
  end

  def describe_error({:missing_binding, field, _detail}) do
    "No `#{field}:*` label found on this issue and no default `#{field}` is configured in WORKFLOW.md."
  end

  def describe_error({:invalid_repo_label, message}) do
    "Invalid `repo:*` label: #{message}."
  end

  def describe_error({:missing_node_id, node_name}) do
    "Node `#{node_name}` has no configured `node_id` and SYMPHONY_NODE_ID is not set."
  end

  def describe_error({:missing_repo_url, _binding}) do
    "Binding resolved without a repo_url — check `binding.defaults.repo` and `repo:*` labels in WORKFLOW.md."
  end

  def describe_error(reason) do
    "Binding resolution failed: #{inspect(reason)}."
  end

  # ---------------------------------------------------------------------------
  # Private: binding-based resolution
  # ---------------------------------------------------------------------------

  defp has_binding?(nil), do: false

  defp has_binding?(binding) do
    map_size(binding.nodes || %{}) > 0
  end

  defp do_resolve_binding(issue, binding) do
    issue_extracted = extract_labels(issue.labels || [])
    project_extracted = extract_labels(Map.get(issue, :project_labels) || [])
    defaults = binding.defaults || %{}

    raw_repo = issue_extracted.repo || project_extracted.repo || struct_get(defaults, :repo)
    raw_node = issue_extracted.node || project_extracted.node || struct_get(defaults, :node)
    raw_agent = issue_extracted.agent || project_extracted.agent || struct_get(defaults, :agent)

    {allowed_orgs, allowed_repos} =
      case binding.repo_policy do
        nil ->
          {[], []}

        policy ->
          {struct_get(policy, :allowed_github_orgs) || [], struct_get(policy, :allowed_repos) || []}
      end

    nodes = binding.nodes || %{}
    agents = binding.agents || %{}

    with :ok <- check_no_conflicts(issue_extracted.conflicts),
         :ok <- check_no_conflicts(project_extracted.conflicts),
         {:ok, repo_url} <- resolve_repo(raw_repo, allowed_orgs, allowed_repos),
         {:ok, node_name} <- resolve_node(raw_node, nodes),
         {:ok, agent_name} <- resolve_agent(raw_agent, node_name, nodes, agents),
         node_config = Map.get(nodes, node_name, %{}),
         {:ok, node_id} <- resolve_node_id(Map.get(node_config, "node_id"), node_name) do
      agent_config = Map.get(agents, agent_name, %{})

      {:ok,
       %{
         repo_url: repo_url,
         repo_branch_prefix: struct_get(defaults, :repo_branch_prefix),
         node: node_name,
         node_id: node_id,
         relay: Map.get(node_config, "relay"),
         token: Map.get(node_config, "token"),
         encrypt: struct_get(defaults, :encrypt) == true,
         agent: agent_name,
         permission_mode: Map.get(agent_config, "permission_mode", "default")
       }}
    end
  end

  # A list of two or more `agent:*`/`repo:*`/`node:*` labels of the same type
  # on one issue (or one project) is a misconfiguration — resolving "the
  # first one" would silently ignore the conflict, so fail fast instead.
  defp check_no_conflicts(%{repo: [], node: [], agent: []}), do: :ok
  defp check_no_conflicts(%{repo: repo}) when repo != [], do: {:error, {:conflicting_labels, :repo, repo}}
  defp check_no_conflicts(%{node: node}) when node != [], do: {:error, {:conflicting_labels, :node, node}}
  defp check_no_conflicts(%{agent: agent}) when agent != [], do: {:error, {:conflicting_labels, :agent, agent}}

  # ---------------------------------------------------------------------------
  # Private: legacy resolution (external: + repo: config)
  # ---------------------------------------------------------------------------

  defp do_resolve_legacy(settings) do
    with {:ok, node_id} <- resolve_node_id(settings.external.node, settings.external.node) do
      {:ok,
       %{
         repo_url: settings.repo.url,
         repo_branch_prefix: settings.repo.branch_prefix,
         node: settings.external.node,
         node_id: node_id,
         relay: settings.external.relay,
         token: settings.external.token,
         encrypt: settings.external.encrypt == true,
         agent: settings.external.agent,
         permission_mode: settings.external.permission_mode
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: node_id resolution (env override > configured value > fail fast)
  # ---------------------------------------------------------------------------

  # `SYMPHONY_NODE_ID` lets an operator point dispatch at a different relay
  # node identity (e.g. switching laptops/machines) without editing the
  # binding's `node_id` in WORKFLOW.md, which is host-specific and regenerated
  # per `~/.vibe/identity.json`.
  defp resolve_node_id(configured_node_id, context) do
    case node_id_override() do
      {:ok, override} ->
        {:ok, override}

      :not_set ->
        case configured_node_id do
          id when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, {:missing_node_id, context}}
        end
    end
  end

  defp node_id_override do
    case System.get_env("SYMPHONY_NODE_ID") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :not_set
    end
  end

  # ---------------------------------------------------------------------------
  # Private: repo resolution and validation
  # ---------------------------------------------------------------------------

  defp resolve_repo(nil, _allowed_orgs, _allowed_repos), do: {:ok, nil}
  defp resolve_repo("", _allowed_orgs, _allowed_repos), do: {:error, {:invalid_repo_label, "empty repo value"}}

  defp resolve_repo(raw, allowed_orgs, allowed_repos) do
    cond do
      String.contains?(raw, "..") ->
        {:error, {:invalid_repo_label, "path traversal not allowed in repo"}}

      String.contains?(raw, " ") ->
        {:error, {:invalid_repo_label, "spaces not allowed in repo label"}}

      String.starts_with?(raw, "file://") ->
        {:error, {:invalid_repo_label, "file:// URLs are not allowed"}}

      String.starts_with?(raw, "ssh://") ->
        {:error, {:invalid_repo_label, "ssh:// URLs are not allowed"}}

      String.starts_with?(raw, "git://") ->
        {:error, {:invalid_repo_label, "git:// URLs are not allowed"}}

      String.starts_with?(raw, "http://") ->
        {:error, {:invalid_repo_label, "http:// not allowed — use https://github.com/"}}

      String.starts_with?(raw, "https://github.com/") ->
        validate_github_url(raw, allowed_orgs, allowed_repos)

      String.starts_with?(raw, "https://") ->
        {:error, {:invalid_repo_label, "only github.com repos are allowed: #{inspect(raw)}"}}

      Regex.match?(~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, raw) ->
        # org/repo shorthand
        [org, repo_name] = String.split(raw, "/", parts: 2)

        with :ok <- validate_github_org(org, raw, allowed_orgs),
             :ok <- validate_allowed_repo(repo_name, raw, allowed_repos) do
          {:ok, "https://github.com/#{raw}"}
        end

      Regex.match?(~r{^[A-Za-z0-9_.-]+$}, raw) ->
        # bare repo name — expand using the single allowed org
        case allowed_orgs do
          [org] ->
            with :ok <- validate_allowed_repo(raw, raw, allowed_repos) do
              {:ok, "https://github.com/#{org}/#{raw}"}
            end

          [] ->
            {:error,
             {:invalid_repo_label,
              "no allowed_github_orgs configured to expand bare repo name #{inspect(raw)}"}}

          orgs ->
            {:error,
             {:invalid_repo_label,
              "ambiguous bare repo name #{inspect(raw)} — configure exactly one allowed_github_org (found: #{Enum.join(orgs, ", ")})"}}
        end

      true ->
        {:error, {:invalid_repo_label, "unrecognized repo format: #{inspect(raw)}"}}
    end
  end

  defp validate_github_url(url, allowed_orgs, allowed_repos) do
    case Regex.run(~r{^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)}, url) do
      [_, org, repo_name] ->
        with :ok <- validate_github_org(org, url, allowed_orgs),
             :ok <- validate_allowed_repo(repo_name, url, allowed_repos) do
          {:ok, url}
        end

      _ ->
        {:error, {:invalid_repo_label, "malformed GitHub URL: #{inspect(url)}"}}
    end
  end

  # Empty allowed_orgs list = no restriction
  defp validate_github_org(_org, _raw, []), do: :ok

  defp validate_github_org(org, raw, allowed_orgs) do
    if Enum.member?(allowed_orgs, org) do
      :ok
    else
      {:error,
       {:invalid_repo_label,
        "org #{inspect(org)} is not in allowed_github_orgs #{inspect(allowed_orgs)} (from #{inspect(raw)})"}}
    end
  end

  # Empty allowed_repos list = no restriction (any syntactically valid repo
  # name is accepted, as before this allowlist existed).
  defp validate_allowed_repo(_repo_name, _raw, []), do: :ok

  defp validate_allowed_repo(repo_name, raw, allowed_repos) do
    if Enum.member?(allowed_repos, repo_name) do
      :ok
    else
      {:error, {:unknown_repo, repo_name, raw, allowed_repos}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: node and agent resolution
  # ---------------------------------------------------------------------------

  defp resolve_node(nil, _nodes) do
    {:error, {:missing_binding, :node, "no node specified and no default configured"}}
  end

  defp resolve_node(name, nodes) do
    if Map.has_key?(nodes, name) do
      {:ok, name}
    else
      {:error, {:unknown_node, name, Map.keys(nodes)}}
    end
  end

  defp resolve_agent(nil, _node_name, _nodes, _agents) do
    {:error, {:missing_binding, :agent, "no agent specified and no default configured"}}
  end

  defp resolve_agent(name, node_name, nodes, agents) do
    with true <- Map.has_key?(agents, name) || {:error, {:unknown_agent, name, Map.keys(agents)}} do
      node_config = Map.get(nodes, node_name, %{})
      allowed = Map.get(node_config, "allowed_agents", [])

      if allowed == [] or Enum.member?(allowed, name) do
        {:ok, name}
      else
        {:error, {:agent_not_allowed_on_node, name, node_name, allowed}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: struct/map accessor (handles both structs and plain maps)
  # ---------------------------------------------------------------------------

  defp struct_get(value, key) when is_struct(value), do: Map.get(value, key)
  defp struct_get(value, key) when is_map(value), do: Map.get(value, to_string(key))
  defp struct_get(_value, _key), do: nil
end
