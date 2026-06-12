defmodule SymphonyElixir.Binding do
  @moduledoc """
  Resolves repo/node/agent binding from Linear labels, the Linear project's
  `vibe:` description block, and WORKFLOW.md config.

  Labels are parsed from issue labels and project labels. Resolution priority
  for each of `repo`/`node`/`agent`, highest first:
    1. Issue labels — `agent:*`/`repo:*`/`node:*` set directly on the issue.
    2. Project labels — the *same label vocabulary* (`agent:*`/`repo:*`/
       `node:*`), but applied as labels on the Linear *project* that the
       issue belongs to. This is a distinct mechanism from #3 below — do
       not confuse "a label on the project" with "the project's
       *description* text".
    3. Linear project *description*'s `vibe:` block — project-level
       defaults (`repo`, `default_agent`, `default_node`, `encrypt`) and
       allow-lists (`allowed_agents`, `allowed_nodes`) parsed from a fenced
       ```yaml code block in the project's description/content. See
       `SymphonyElixir.Linear.ProjectVibeConfig` for the exact format.
    4. binding.defaults (WORKFLOW.md, global fallback)

  Label syntax (colon and slash forms are both supported):
    repo:https://github.com/JozzyAI/fin_bot
    repo:JozzyAI/fin_bot
    repo:fin_bot
    repo/fin_bot
    repo/JozzyAI/fin_bot
    node:company-node  /  node/company-node
    agent:claude-code  /  agent/claude-code

  If a project's `vibe:` block is present but invalid (e.g. an unknown
  repo, agent, or node, or a `default_agent`/`default_node` that falls
  outside that same block's own `allowed_agents`/`allowed_nodes`),
  resolution fails fast rather than silently falling back to WORKFLOW
  defaults.
  """

  alias SymphonyElixir.Linear.ProjectVibeConfig

  @type label_tag :: {:repo, String.t()} | {:node, String.t()} | {:agent, String.t()} | :unknown

  @type repo_scope :: %{
          allowed_orgs: [String.t()],
          allowed_repos: [String.t()],
          allowed_repo_prefixes: [String.t()],
          allowed_repo_owners: [String.t()]
        }

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
  Build the repo allow-list scope (`allowed_github_orgs`, `allowed_repos`,
  `allowed_repo_prefixes`, `allowed_repo_owners`) from `binding.repo_policy`.
  """
  @spec repo_scope(map() | nil) :: repo_scope()
  def repo_scope(nil), do: empty_repo_scope()

  def repo_scope(binding) do
    case binding.repo_policy do
      nil ->
        empty_repo_scope()

      policy ->
        %{
          allowed_orgs: struct_get(policy, :allowed_github_orgs) || [],
          allowed_repos: struct_get(policy, :allowed_repos) || [],
          allowed_repo_prefixes: struct_get(policy, :allowed_repo_prefixes) || [],
          allowed_repo_owners: struct_get(policy, :allowed_repo_owners) || []
        }
    end
  end

  defp empty_repo_scope,
    do: %{allowed_orgs: [], allowed_repos: [], allowed_repo_prefixes: [], allowed_repo_owners: []}

  @doc """
  Validate a repo reference (full GitHub URL, `org/repo`, or bare repo name)
  against `settings.binding`'s `repo_policy`, returning the resolved
  `https://github.com/...` URL (or `{:ok, nil}` for a `nil` repo).

  Used by `SymphonyElixir.Linear.ProjectDiscovery` to validate a discovered
  project's `vibe.repo` before treating that project as Symphony-enabled.
  """
  @spec validate_repo(String.t() | nil, struct()) :: {:ok, String.t() | nil} | {:error, term()}
  def validate_repo(repo, settings) do
    resolve_repo(repo, repo_scope(settings.binding))
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

  def describe_error({:invalid_project_vibe_config, reason}) do
    "This project's `vibe:` configuration block is invalid: #{describe_project_vibe_parse_error(reason)}."
  end

  def describe_error({:invalid_project_repo, reason}) do
    "This project's `vibe.repo` is invalid: #{describe_error(reason)}"
  end

  def describe_error({:invalid_project_default_agent, name, known}) do
    "This project's `vibe.default_agent: #{name}` is not a configured agent — configured agents are: #{Enum.join(known, ", ")}."
  end

  def describe_error({:invalid_project_default_node, name, known}) do
    "This project's `vibe.default_node: #{name}` is not a configured node — configured nodes are: #{Enum.join(known, ", ")}."
  end

  def describe_error({:invalid_project_default_node_id, name}) do
    "This project's `vibe.default_node: #{name}` has no configured `node_id` and SYMPHONY_NODE_ID is not set."
  end

  def describe_error({:agent_not_allowed_by_project, name, allowed}) do
    "Agent `agent:#{name}` is not in this project's `vibe.allowed_agents` (allowed: #{Enum.join(allowed, ", ")})."
  end

  def describe_error({:node_not_allowed_by_project, name, allowed}) do
    "Node `node:#{name}` is not in this project's `vibe.allowed_nodes` (allowed: #{Enum.join(allowed, ", ")})."
  end

  def describe_error({:project_vibe_inconsistent_default_agent, name, allowed}) do
    "This project's `vibe:` configuration is internally inconsistent: `default_agent: #{name}` is not in its own `allowed_agents` (#{Enum.join(allowed, ", ")})."
  end

  def describe_error({:project_vibe_inconsistent_default_node, name, allowed}) do
    "This project's `vibe:` configuration is internally inconsistent: `default_node: #{name}` is not in its own `allowed_nodes` (#{Enum.join(allowed, ", ")})."
  end

  def describe_error(reason) do
    "Binding resolution failed: #{inspect(reason)}."
  end

  defp describe_project_vibe_parse_error(:project_vibe_not_a_map) do
    "the `vibe:` value must be a mapping, not a scalar or list"
  end

  defp describe_project_vibe_parse_error({:project_vibe_invalid_field, key}) do
    "field `#{key}` has an invalid type"
  end

  defp describe_project_vibe_parse_error({:project_vibe_yaml_error, reason}) do
    "could not parse YAML (#{inspect(reason)})"
  end

  defp describe_project_vibe_parse_error(reason) do
    inspect(reason)
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
    repo_scope = repo_scope(binding)

    nodes = binding.nodes || %{}
    agents = binding.agents || %{}

    label_agent = issue_extracted.agent || project_extracted.agent
    label_node = issue_extracted.node || project_extracted.node

    with :ok <- check_no_conflicts(issue_extracted.conflicts),
         :ok <- check_no_conflicts(project_extracted.conflicts),
         {:ok, project_vibe} <- ProjectVibeConfig.parse(Map.get(issue, :project_description)),
         :ok <- validate_project_vibe(project_vibe, repo_scope, nodes, agents),
         :ok <- check_project_allowed(label_agent, project_vibe_field(project_vibe, :allowed_agents), :agent_not_allowed_by_project),
         :ok <- check_project_allowed(label_node, project_vibe_field(project_vibe, :allowed_nodes), :node_not_allowed_by_project),
         raw_repo = issue_extracted.repo || project_extracted.repo || project_vibe_field(project_vibe, :repo) || struct_get(defaults, :repo),
         raw_node = label_node || project_vibe_field(project_vibe, :default_node) || struct_get(defaults, :node),
         raw_agent = label_agent || project_vibe_field(project_vibe, :default_agent) || struct_get(defaults, :agent),
         {:ok, repo_url} <- resolve_repo(raw_repo, repo_scope),
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
         encrypt: resolve_encrypt(project_vibe, defaults),
         agent: agent_name,
         permission_mode: Map.get(agent_config, "permission_mode", "default")
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: project-level `vibe:` binding config (from project description)
  # ---------------------------------------------------------------------------

  defp project_vibe_field(nil, _key), do: nil
  defp project_vibe_field(project_vibe, key), do: Map.get(project_vibe, key)

  defp resolve_encrypt(project_vibe, defaults) do
    case project_vibe_field(project_vibe, :encrypt) do
      nil -> struct_get(defaults, :encrypt) == true
      value when is_boolean(value) -> value
    end
  end

  # A project's `vibe:` block is a contract: if it declares a `repo`,
  # `default_agent`, or `default_node`, that value must be valid on its
  # own (regardless of whether this particular issue ends up using it),
  # so misconfiguration is caught immediately instead of surfacing later
  # on a different issue.
  defp validate_project_vibe(nil, _repo_scope, _nodes, _agents), do: :ok

  defp validate_project_vibe(project_vibe, repo_scope, nodes, agents) do
    with :ok <- validate_project_repo(project_vibe.repo, repo_scope),
         :ok <- validate_project_agent(project_vibe.default_agent, agents),
         :ok <- validate_project_node(project_vibe.default_node, nodes),
         :ok <- validate_project_default_agent_allowed(project_vibe.default_agent, project_vibe.allowed_agents),
         :ok <- validate_project_default_node_allowed(project_vibe.default_node, project_vibe.allowed_nodes) do
      :ok
    end
  end

  defp validate_project_repo(nil, _repo_scope), do: :ok

  defp validate_project_repo(repo, repo_scope) do
    case resolve_repo(repo, repo_scope) do
      {:ok, _repo_url} -> :ok
      {:error, reason} -> {:error, {:invalid_project_repo, reason}}
    end
  end

  defp validate_project_agent(nil, _agents), do: :ok

  defp validate_project_agent(name, agents) do
    if Map.has_key?(agents, name) do
      :ok
    else
      {:error, {:invalid_project_default_agent, name, Map.keys(agents)}}
    end
  end

  defp validate_project_node(nil, _nodes), do: :ok

  defp validate_project_node(name, nodes) do
    if Map.has_key?(nodes, name) do
      node_config = Map.get(nodes, name, %{})

      case resolve_node_id(Map.get(node_config, "node_id"), name) do
        {:ok, _node_id} -> :ok
        {:error, _reason} -> {:error, {:invalid_project_default_node_id, name}}
      end
    else
      {:error, {:invalid_project_default_node, name, Map.keys(nodes)}}
    end
  end

  # A project's `vibe:` block is internally inconsistent if its own
  # `default_agent`/`default_node` falls outside its own
  # `allowed_agents`/`allowed_nodes` allow-list — no issue in this project
  # could ever resolve successfully, so fail fast here rather than letting
  # every issue dispatch fail individually with `*_not_allowed_by_project`.
  defp validate_project_default_agent_allowed(nil, _allowed_agents), do: :ok
  defp validate_project_default_agent_allowed(_name, nil), do: :ok
  defp validate_project_default_agent_allowed(_name, []), do: :ok

  defp validate_project_default_agent_allowed(name, allowed_agents) do
    if Enum.member?(allowed_agents, name) do
      :ok
    else
      {:error, {:project_vibe_inconsistent_default_agent, name, allowed_agents}}
    end
  end

  defp validate_project_default_node_allowed(nil, _allowed_nodes), do: :ok
  defp validate_project_default_node_allowed(_name, nil), do: :ok
  defp validate_project_default_node_allowed(_name, []), do: :ok

  defp validate_project_default_node_allowed(name, allowed_nodes) do
    if Enum.member?(allowed_nodes, name) do
      :ok
    else
      {:error, {:project_vibe_inconsistent_default_node, name, allowed_nodes}}
    end
  end

  # Restricts a label-driven agent/node override to the project's
  # `vibe.allowed_agents`/`vibe.allowed_nodes` list, when configured. A
  # nil label value (no override on this issue or its project labels)
  # or an absent/empty allow-list is always permitted — the constraint
  # only governs explicit label overrides, not the project's own
  # defaults or WORKFLOW.md's global defaults.
  defp check_project_allowed(nil, _allowed, _error_tag), do: :ok
  defp check_project_allowed(_label_value, nil, _error_tag), do: :ok
  defp check_project_allowed(_label_value, [], _error_tag), do: :ok

  defp check_project_allowed(label_value, allowed, error_tag) when is_list(allowed) do
    if Enum.member?(allowed, label_value) do
      :ok
    else
      {:error, {error_tag, label_value, allowed}}
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

  defp resolve_repo(nil, _repo_scope), do: {:ok, nil}
  defp resolve_repo("", _repo_scope), do: {:error, {:invalid_repo_label, "empty repo value"}}

  defp resolve_repo(raw, repo_scope) do
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
        validate_github_url(raw, repo_scope)

      String.starts_with?(raw, "https://") ->
        {:error, {:invalid_repo_label, "only github.com repos are allowed: #{inspect(raw)}"}}

      Regex.match?(~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, raw) ->
        # org/repo shorthand
        [org, repo_name] = String.split(raw, "/", parts: 2)
        url = "https://github.com/#{org}/#{repo_name}"

        with :ok <- validate_repo_access(org, repo_name, url, raw, repo_scope) do
          {:ok, url}
        end

      Regex.match?(~r{^[A-Za-z0-9_.-]+$}, raw) ->
        # bare repo name — expand using the single allowed org/owner
        with {:ok, org} <- single_org_for_expansion(raw, repo_scope) do
          url = "https://github.com/#{org}/#{raw}"

          with :ok <- validate_repo_access(org, raw, url, raw, repo_scope) do
            {:ok, url}
          end
        end

      true ->
        {:error, {:invalid_repo_label, "unrecognized repo format: #{inspect(raw)}"}}
    end
  end

  defp validate_github_url(url, repo_scope) do
    case Regex.run(~r{^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)}, url) do
      [_, org, repo_name] ->
        with :ok <- validate_repo_access(org, repo_name, url, url, repo_scope) do
          {:ok, url}
        end

      _ ->
        {:error, {:invalid_repo_label, "malformed GitHub URL: #{inspect(url)}"}}
    end
  end

  # An org/repo is allowed if it's covered by allowed_repo_prefixes (URL
  # prefix match) or allowed_repo_owners (any repo under that owner) —
  # either of these grants access without enumerating individual repo names.
  # Otherwise, fall back to the original combo: the org must be in
  # allowed_github_orgs (when configured) and the repo name must be in
  # allowed_repos (when configured).
  #
  # When NO repo_policy lists are configured at all, every github.com repo
  # is allowed (historical default). But once any list is configured, a repo
  # that matches none of them is rejected — otherwise a policy that only sets
  # allowed_repo_prefixes/allowed_repo_owners would silently allow everything
  # else via the "empty allowed_github_orgs/allowed_repos = unrestricted"
  # fallback.
  defp validate_repo_access(org, repo_name, url, raw, repo_scope) do
    cond do
      matches_any_prefix?(url, repo_scope.allowed_repo_prefixes) ->
        :ok

      org in repo_scope.allowed_repo_owners ->
        :ok

      repo_scope.allowed_orgs != [] or repo_scope.allowed_repos != [] ->
        with :ok <- validate_github_org(org, raw, repo_scope.allowed_orgs) do
          validate_allowed_repo(repo_name, raw, repo_scope.allowed_repos)
        end

      repo_scope.allowed_repo_prefixes == [] and repo_scope.allowed_repo_owners == [] ->
        :ok

      true ->
        {:error,
         {:invalid_repo_label,
          "repo #{inspect(url)} is not covered by allowed_repo_prefixes #{inspect(repo_scope.allowed_repo_prefixes)} or allowed_repo_owners #{inspect(repo_scope.allowed_repo_owners)} (from #{inspect(raw)})"}}
    end
  end

  defp matches_any_prefix?(_url, []), do: false
  defp matches_any_prefix?(url, prefixes), do: Enum.any?(prefixes, &String.starts_with?(url, &1))

  # Empty allowed_orgs list = no restriction
  defp validate_github_org(_org, _raw, []), do: :ok

  defp validate_github_org(org, raw, allowed_orgs) do
    if Enum.member?(allowed_orgs, org) do
      :ok
    else
      {:error, {:invalid_repo_label, "org #{inspect(org)} is not in allowed_github_orgs #{inspect(allowed_orgs)} (from #{inspect(raw)})"}}
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

  # Bare repo names (e.g. `repo:fin_bot`) need a single org/owner to expand
  # against — prefer allowed_github_orgs (the historical mechanism), falling
  # back to allowed_repo_owners when exactly one is configured.
  defp single_org_for_expansion(raw, repo_scope) do
    case repo_scope.allowed_orgs do
      [org] ->
        {:ok, org}

      [] ->
        case repo_scope.allowed_repo_owners do
          [org] ->
            {:ok, org}

          [] ->
            {:error, {:invalid_repo_label, "no allowed_github_orgs configured to expand bare repo name #{inspect(raw)}"}}

          owners ->
            {:error, {:invalid_repo_label, "ambiguous bare repo name #{inspect(raw)} — configure exactly one allowed_github_org or allowed_repo_owner (found owners: #{Enum.join(owners, ", ")})"}}
        end

      orgs ->
        {:error, {:invalid_repo_label, "ambiguous bare repo name #{inspect(raw)} — configure exactly one allowed_github_org (found: #{Enum.join(orgs, ", ")})"}}
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
