defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      alias SymphonyElixir.Binding

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_project_slugs: [],
          tracker_team_key: nil,
          tracker_auto_discover_projects: false,
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_continuation_attempts: 1,
          max_concurrent_agents_by_state: %{},
          max_active_runs_per_project: nil,
          max_active_runs_per_repo: nil,
          agent_kind: "codex",
          repo_url: nil,
          repo_branch_prefix: nil,
          binding: nil,
          codex_command: "codex app-server",
          external_command: "vibe",
          external_agent: "mock",
          external_node: "node_test_legacy",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          planner_enabled: false,
          planner_trigger_label: "type:plan",
          planner_child_initial_state: "Backlog",
          planner_max_children: 10,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_project_slugs = Keyword.get(config, :tracker_project_slugs)
    tracker_team_key = Keyword.get(config, :tracker_team_key)
    tracker_auto_discover_projects = Keyword.get(config, :tracker_auto_discover_projects)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_continuation_attempts = Keyword.get(config, :max_continuation_attempts)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    max_active_runs_per_project = Keyword.get(config, :max_active_runs_per_project)
    max_active_runs_per_repo = Keyword.get(config, :max_active_runs_per_repo)
    agent_kind = Keyword.get(config, :agent_kind)
    repo_url = Keyword.get(config, :repo_url)
    repo_branch_prefix = Keyword.get(config, :repo_branch_prefix)
    binding = Keyword.get(config, :binding)
    external_command = Keyword.get(config, :external_command)
    external_agent = Keyword.get(config, :external_agent)
    external_node = Keyword.get(config, :external_node)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    planner_enabled = Keyword.get(config, :planner_enabled)
    planner_trigger_label = Keyword.get(config, :planner_trigger_label)
    planner_child_initial_state = Keyword.get(config, :planner_child_initial_state)
    planner_max_children = Keyword.get(config, :planner_max_children)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  project_slugs: #{yaml_value(tracker_project_slugs)}",
        "  team_key: #{yaml_value(tracker_team_key)}",
        "  auto_discover_projects: #{yaml_value(tracker_auto_discover_projects)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_continuation_attempts: #{yaml_value(max_continuation_attempts)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  max_active_runs_per_project: #{yaml_value(max_active_runs_per_project)}",
        "  max_active_runs_per_repo: #{yaml_value(max_active_runs_per_repo)}",
        "agent_kind: #{yaml_value(agent_kind)}",
        repo_yaml(repo_url, repo_branch_prefix),
        binding_yaml(binding),
        "external:",
        "  command: #{yaml_value(external_command)}",
        "  agent: #{yaml_value(external_agent)}",
        "  node: #{yaml_value(external_node)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        planner_yaml(planner_enabled, planner_trigger_label, planner_child_initial_state, planner_max_children),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp repo_yaml(nil, _branch_prefix), do: nil

  defp repo_yaml(url, branch_prefix) do
    [
      "repo:",
      "  url: #{yaml_value(url)}",
      branch_prefix && "  branch_prefix: #{yaml_value(branch_prefix)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp repo_policy_list_yaml(_key, []), do: []

  defp repo_policy_list_yaml(key, values) do
    ["    #{key}:"] ++ Enum.map(values, &"      - #{yaml_value(&1)}")
  end

  # binding is a raw YAML string block for test flexibility.
  # Pass pre-formatted YAML (without the top-level "binding:" key) as the value,
  # or pass a map: %{nodes: %{...}, agents: %{...}, defaults: %{...}, repo_policy: %{...}}.
  defp binding_yaml(nil), do: nil

  defp binding_yaml(raw) when is_binary(raw), do: raw

  defp binding_yaml(%{} = spec) do
    lines = ["binding:"]

    lines =
      if rp = Map.get(spec, :repo_policy) do
        orgs = Map.get(rp, :allowed_github_orgs, [])
        allowed_repos = Map.get(rp, :allowed_repos, [])
        allowed_repo_prefixes = Map.get(rp, :allowed_repo_prefixes, [])
        allowed_repo_owners = Map.get(rp, :allowed_repo_owners, [])

        lines ++
          [
            "  repo_policy:",
            "    allowed_github_orgs:"
          ] ++
          Enum.map(orgs, &"      - #{yaml_value(&1)}") ++
          repo_policy_list_yaml("allowed_repos", allowed_repos) ++
          repo_policy_list_yaml("allowed_repo_prefixes", allowed_repo_prefixes) ++
          repo_policy_list_yaml("allowed_repo_owners", allowed_repo_owners)
      else
        lines
      end

    lines =
      if nodes = Map.get(spec, :nodes) do
        node_lines =
          Enum.flat_map(nodes, fn {name, cfg} ->
            relay = Map.get(cfg, :relay)
            token = Map.get(cfg, :token)
            agents = Map.get(cfg, :allowed_agents, [])

            [
              "    #{name}:"
            ] ++
              ((relay && ["      relay: #{yaml_value(relay)}"]) || []) ++
              ((token && ["      token: #{yaml_value(token)}"]) || []) ++
              ((agents != [] &&
                  ["      allowed_agents:"] ++ Enum.map(agents, &"        - #{yaml_value(&1)}")) ||
                 [])
          end)

        lines ++ ["  nodes:"] ++ node_lines
      else
        lines
      end

    lines =
      if agents = Map.get(spec, :agents) do
        agent_lines =
          Enum.flat_map(agents, fn {name, cfg} ->
            pm = Map.get(cfg, :permission_mode, "default")
            ["    #{name}:", "      permission_mode: #{yaml_value(pm)}"]
          end)

        lines ++ ["  agents:"] ++ agent_lines
      else
        lines
      end

    lines =
      if defaults = Map.get(spec, :defaults) do
        d_lines =
          Enum.flat_map(
            [
              {:repo, Map.get(defaults, :repo)},
              {:repo_branch_prefix, Map.get(defaults, :repo_branch_prefix)},
              {:node, Map.get(defaults, :node)},
              {:agent, Map.get(defaults, :agent)},
              {:encrypt, Map.get(defaults, :encrypt)}
            ],
            fn
              {_k, nil} -> []
              {k, v} -> ["    #{k}: #{yaml_value(v)}"]
            end
          )

        lines ++ ["  defaults:"] ++ d_lines
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp planner_yaml(enabled, trigger_label, child_initial_state, max_children) do
    [
      "planner:",
      "  enabled: #{yaml_value(enabled)}",
      "  trigger_label: #{yaml_value(trigger_label)}",
      "  child_initial_state: #{yaml_value(child_initial_state)}",
      "  max_children: #{yaml_value(max_children)}"
    ]
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
