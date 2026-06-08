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
  Extract the first repo/node/agent tag from a list of label strings.
  """
  @spec extract_labels([String.t()]) :: %{
          repo: String.t() | nil,
          node: String.t() | nil,
          agent: String.t() | nil
        }
  def extract_labels(labels) when is_list(labels) do
    Enum.reduce(labels, %{repo: nil, node: nil, agent: nil}, fn label, acc ->
      case parse_label(label) do
        {:repo, v} when is_nil(acc.repo) -> %{acc | repo: v}
        {:node, v} when is_nil(acc.node) -> %{acc | node: v}
        {:agent, v} when is_nil(acc.agent) -> %{acc | agent: v}
        _ -> acc
      end
    end)
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

    allowed_orgs =
      case binding.repo_policy do
        nil -> []
        policy -> struct_get(policy, :allowed_github_orgs) || []
      end

    nodes = binding.nodes || %{}
    agents = binding.agents || %{}

    with {:ok, repo_url} <- resolve_repo(raw_repo, allowed_orgs),
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

  defp resolve_repo(nil, _allowed_orgs), do: {:ok, nil}
  defp resolve_repo("", _allowed_orgs), do: {:error, {:invalid_repo_label, "empty repo value"}}

  defp resolve_repo(raw, allowed_orgs) do
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
        validate_github_url(raw, allowed_orgs)

      String.starts_with?(raw, "https://") ->
        {:error, {:invalid_repo_label, "only github.com repos are allowed: #{inspect(raw)}"}}

      Regex.match?(~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, raw) ->
        # org/repo shorthand
        [org, _repo] = String.split(raw, "/", parts: 2)

        case validate_github_org(org, raw, allowed_orgs) do
          :ok -> {:ok, "https://github.com/#{raw}"}
          err -> err
        end

      Regex.match?(~r{^[A-Za-z0-9_.-]+$}, raw) ->
        # bare repo name — expand using the single allowed org
        case allowed_orgs do
          [org] ->
            {:ok, "https://github.com/#{org}/#{raw}"}

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

  defp validate_github_url(url, allowed_orgs) do
    case Regex.run(~r{^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)}, url) do
      [_, org, _repo] ->
        case validate_github_org(org, url, allowed_orgs) do
          :ok -> {:ok, url}
          err -> err
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
