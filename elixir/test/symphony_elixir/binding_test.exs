defmodule SymphonyElixir.BindingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Redact

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a minimal settings struct for Binding.resolve tests without hitting
  # the real Config server.
  defp settings_with_binding(binding_spec) do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "vibe",
      binding: binding_yaml_block(binding_spec)
    )

    {:ok, %{config: config}} = Workflow.load()
    {:ok, settings} = SymphonyElixir.Config.Schema.parse(config)
    settings
  end

  defp settings_legacy(repo_url: url, external_agent: agent) do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "vibe",
      repo_url: url,
      external_agent: agent
    )

    {:ok, %{config: config}} = Workflow.load()
    {:ok, settings} = SymphonyElixir.Config.Schema.parse(config)
    settings
  end

  defp issue(labels: labels) do
    %SymphonyElixir.Linear.Issue{identifier: "TEST-1", labels: labels, project_labels: []}
  end

  defp issue(labels: labels, project_labels: plabels) do
    %SymphonyElixir.Linear.Issue{identifier: "TEST-1", labels: labels, project_labels: plabels}
  end

  defp issue(labels: labels, project_description: description) do
    %SymphonyElixir.Linear.Issue{
      identifier: "TEST-1",
      labels: labels,
      project_labels: [],
      project_description: description
    }
  end

  defp issue(labels: labels, project_labels: plabels, project_description: description) do
    %SymphonyElixir.Linear.Issue{
      identifier: "TEST-1",
      labels: labels,
      project_labels: plabels,
      project_description: description
    }
  end

  # Builds a Linear project description containing a fenced ```yaml code
  # block with a top-level `vibe:` key, mirroring how a user would paste
  # project-level binding config into a Linear project's description.
  defp project_description_with_vibe(vibe_fields) do
    """
    ## Project Overview

    This project ships fin_bot features.

    ```yaml
    #{vibe_yaml_block(vibe_fields)}
    ```

    More notes below the config block.
    """
  end

  defp vibe_yaml_block(fields) do
    ["vibe:"]
    |> maybe_append(fields, :repo, &"  repo: #{&1}")
    |> maybe_append(fields, :default_agent, &"  default_agent: #{&1}")
    |> maybe_append(fields, :default_node, &"  default_node: #{&1}")
    |> maybe_append(fields, :encrypt, &"  encrypt: #{&1}")
    |> maybe_append_list(fields, :allowed_agents, "  allowed_agents:")
    |> maybe_append_list(fields, :allowed_nodes, "  allowed_nodes:")
    |> Enum.join("\n")
  end

  defp maybe_append(lines, fields, key, render) do
    case Map.get(fields, key) do
      nil -> lines
      value -> lines ++ [render.(value)]
    end
  end

  defp maybe_append_list(lines, fields, key, header) do
    case Map.get(fields, key) do
      nil -> lines
      values -> lines ++ [header] ++ Enum.map(values, &"    - #{&1}")
    end
  end

  # Produces the "binding:" YAML block string for write_workflow_file!
  defp binding_yaml_block(spec) do
    nodes_yaml =
      spec
      |> Map.get(:nodes, %{})
      |> Enum.map_join("\n", fn {name, cfg} ->
        relay = Map.get(cfg, :relay, "wss://relay.example.com")
        token = Map.get(cfg, :token, "tok")
        node_id = Map.get(cfg, :node_id, "node_test_#{name}")
        agents = Map.get(cfg, :allowed_agents, ["mock", "claude-code"])

        agents_yaml = Enum.map_join(agents, "\n", &"        - #{&1}")

        """
            #{name}:
              relay: "#{relay}"
              token: "#{token}"
              node_id: "#{node_id}"
              allowed_agents:
        #{agents_yaml}
        """
        |> String.trim_trailing()
      end)

    agents_yaml =
      spec
      |> Map.get(:agents, %{"mock" => %{permission_mode: "default"}, "claude-code" => %{permission_mode: "unsafe-skip"}})
      |> Enum.map_join("\n", fn {name, cfg} ->
        pm = Map.get(cfg, :permission_mode, "default")
        "    #{name}:\n      permission_mode: \"#{pm}\""
      end)

    defaults = Map.get(spec, :defaults, %{})
    orgs = Map.get(spec, :allowed_github_orgs, ["JozzyAI"])
    allowed_repos = Map.get(spec, :allowed_repos, [])

    orgs_yaml = Enum.map_join(orgs, "\n", &"      - #{&1}")

    allowed_repos_yaml =
      case allowed_repos do
        [] ->
          ""

        repos ->
          "    allowed_repos:\n" <> Enum.map_join(repos, "\n", &"      - #{&1}") <> "\n"
      end

    defaults_repo = Map.get(defaults, :repo, "https://github.com/JozzyAI/fin_bot")
    defaults_node = Map.get(defaults, :node, "company-node")
    defaults_agent = Map.get(defaults, :agent, "claude-code")

    """
    binding:
      repo_policy:
        allowed_github_orgs:
    #{orgs_yaml}
    #{allowed_repos_yaml}  nodes:
    #{nodes_yaml}
      agents:
    #{agents_yaml}
      defaults:
        repo: "#{defaults_repo}"
        node: "#{defaults_node}"
        agent: "#{defaults_agent}"
        encrypt: true
    """
    |> String.trim()
  end

  defp default_nodes do
    %{
      "company-node" => %{
        relay: "wss://vibe-relay.example.com",
        token: "tok",
        allowed_agents: ["mock", "claude-code"]
      }
    }
  end

  # Fixture matching the documented label vocabulary: agent:codex/claude-code/mock,
  # repo:fin_bot/vibe_interface_cli/universe-symphony, node:joey-pc/company-node,
  # with defaults of agent=codex, repo=fin_bot, node=joey-pc.
  defp label_routing_nodes do
    %{
      "joey-pc" => %{
        relay: "wss://vibe-relay.example.com",
        token: "tok",
        node_id: "node_f7cedd3b6590aff9",
        allowed_agents: ["mock", "claude-code", "codex"]
      },
      "company-node" => %{
        relay: "wss://vibe-relay.example.com",
        token: "tok",
        allowed_agents: ["mock", "claude-code", "codex"]
      }
    }
  end

  defp label_routing_settings do
    settings_with_binding(%{
      nodes: label_routing_nodes(),
      agents: %{
        "mock" => %{permission_mode: "default"},
        "claude-code" => %{permission_mode: "unsafe-skip"},
        "codex" => %{permission_mode: "default"}
      },
      allowed_repos: ["fin_bot", "vibe_interface_cli", "universe-symphony"],
      defaults: %{
        repo: "https://github.com/JozzyAI/fin_bot",
        node: "joey-pc",
        agent: "codex"
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Label parsing tests
  # ---------------------------------------------------------------------------

  describe "parse_label/1" do
    test "parses colon-form repo full URL" do
      assert {:repo, "https://github.com/JozzyAI/fin_bot"} =
               Binding.parse_label("repo:https://github.com/JozzyAI/fin_bot")
    end

    test "parses colon-form repo org/name" do
      assert {:repo, "JozzyAI/fin_bot"} = Binding.parse_label("repo:JozzyAI/fin_bot")
    end

    test "parses colon-form repo bare name" do
      assert {:repo, "fin_bot"} = Binding.parse_label("repo:fin_bot")
    end

    test "parses slash-form repo bare name" do
      assert {:repo, "fin_bot"} = Binding.parse_label("repo/fin_bot")
    end

    test "parses slash-form repo org/name" do
      assert {:repo, "JozzyAI/fin_bot"} = Binding.parse_label("repo/JozzyAI/fin_bot")
    end

    test "parses colon-form node" do
      assert {:node, "company-node"} = Binding.parse_label("node:company-node")
    end

    test "parses slash-form node" do
      assert {:node, "company-node"} = Binding.parse_label("node/company-node")
    end

    test "parses colon-form agent" do
      assert {:agent, "claude-code"} = Binding.parse_label("agent:claude-code")
    end

    test "parses slash-form agent" do
      assert {:agent, "claude-code"} = Binding.parse_label("agent/claude-code")
    end

    test "returns :unknown for unrelated labels" do
      assert :unknown = Binding.parse_label("bug")
      assert :unknown = Binding.parse_label("priority:high")
      assert :unknown = Binding.parse_label("")
    end
  end

  # ---------------------------------------------------------------------------
  # Repo URL resolution tests
  # ---------------------------------------------------------------------------

  describe "resolve/2 — repo resolution" do
    test "full GitHub URL resolves when org is allowed" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["repo:https://github.com/JozzyAI/fin_bot"]), settings)
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
    end

    test "org/repo shorthand resolves to full GitHub URL" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["repo:JozzyAI/fin_bot"]), settings)
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
    end

    test "bare repo name resolves using the single allowed org" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["repo:fin_bot"]), settings)
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
    end

    test "slash-form repo/name also resolves" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["repo/fin_bot"]), settings)
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
    end

    test "non-JozzyAI GitHub URL is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})

      {:error, {:invalid_repo_label, msg}} =
        Binding.resolve(issue(labels: ["repo:https://github.com/evil-org/malware"]), settings)

      assert msg =~ "evil-org"
      assert msg =~ "allowed_github_orgs"
    end

    test "non-GitHub https URL is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})

      assert {:error, {:invalid_repo_label, _}} =
               Binding.resolve(issue(labels: ["repo:https://gitlab.com/JozzyAI/fin_bot"]), settings)
    end

    test "http:// URL is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})

      assert {:error, {:invalid_repo_label, msg}} =
               Binding.resolve(issue(labels: ["repo:http://github.com/JozzyAI/fin_bot"]), settings)

      assert msg =~ "http://"
    end

    test "file:// URL is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      assert {:error, {:invalid_repo_label, _}} = Binding.resolve(issue(labels: ["repo:file:///etc/passwd"]), settings)
    end

    test "ssh:// URL is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      assert {:error, {:invalid_repo_label, _}} = Binding.resolve(issue(labels: ["repo:ssh://git@github.com/JozzyAI/fin_bot"]), settings)
    end

    test "path traversal in repo label is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      assert {:error, {:invalid_repo_label, _}} = Binding.resolve(issue(labels: ["repo:../etc/passwd"]), settings)
    end

    test "repo with spaces is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      assert {:error, {:invalid_repo_label, _}} = Binding.resolve(issue(labels: ["repo:bad name"]), settings)
    end
  end

  # ---------------------------------------------------------------------------
  # Node and agent resolution tests
  # ---------------------------------------------------------------------------

  describe "resolve/2 — node resolution" do
    test "node:company-node resolves when in nodes map" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["node:company-node"]), settings)
      assert resolved.node == "company-node"
    end

    test "unknown node is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})

      assert {:error, {:unknown_node, "ghost-node", _known}} =
               Binding.resolve(issue(labels: ["node:ghost-node"]), settings)
    end

    test "relay and token are populated from node config" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: []), settings)
      assert resolved.relay == "wss://vibe-relay.example.com"
      assert resolved.token == "tok"
    end
  end

  describe "resolve/2 — node_id resolution (SYMPHONY_NODE_ID > binding.node_id > fail fast)" do
    setup do
      previous = System.get_env("SYMPHONY_NODE_ID")
      on_exit(fn -> restore_env("SYMPHONY_NODE_ID", previous) end)
      :ok
    end

    test "uses the node's configured node_id when no override is set" do
      System.delete_env("SYMPHONY_NODE_ID")

      nodes = %{
        "company-node" => %{
          relay: "wss://r.example.com",
          token: "t",
          node_id: "node_company_abc123",
          allowed_agents: ["mock", "claude-code"]
        }
      }

      settings = settings_with_binding(%{nodes: nodes})
      {:ok, resolved} = Binding.resolve(issue(labels: ["node:company-node"]), settings)

      assert resolved.node_id == "node_company_abc123"
    end

    test "SYMPHONY_NODE_ID overrides the configured node_id" do
      System.put_env("SYMPHONY_NODE_ID", "node_override_xyz789")

      nodes = %{
        "company-node" => %{
          relay: "wss://r.example.com",
          token: "t",
          node_id: "node_company_abc123",
          allowed_agents: ["mock", "claude-code"]
        }
      }

      settings = settings_with_binding(%{nodes: nodes})
      {:ok, resolved} = Binding.resolve(issue(labels: ["node:company-node"]), settings)

      assert resolved.node_id == "node_override_xyz789"
    end

    test "SYMPHONY_NODE_ID lets resolution succeed when the node has no configured node_id" do
      System.put_env("SYMPHONY_NODE_ID", "node_override_xyz789")

      nodes_yaml = """
          company-node:
            relay: "wss://r.example.com"
            token: "t"
            allowed_agents:
              - mock
              - claude-code
      """

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        binding: """
        binding:
          repo_policy:
            allowed_github_orgs:
              - JozzyAI
          nodes:
        #{nodes_yaml}
          agents:
            mock:
              permission_mode: "default"
            claude-code:
              permission_mode: "unsafe-skip"
          defaults:
            repo: "https://github.com/JozzyAI/fin_bot"
            node: "company-node"
            agent: "claude-code"
            encrypt: true
        """
      )

      {:ok, %{config: config}} = Workflow.load()
      {:ok, settings} = SymphonyElixir.Config.Schema.parse(config)

      {:ok, resolved} = Binding.resolve(issue(labels: ["node:company-node"]), settings)

      assert resolved.node_id == "node_override_xyz789"
    end

    test "fails fast when node has no configured node_id and no override is set" do
      System.delete_env("SYMPHONY_NODE_ID")

      nodes_yaml = """
          company-node:
            relay: "wss://r.example.com"
            token: "t"
            allowed_agents:
              - mock
              - claude-code
      """

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        binding: """
        binding:
          repo_policy:
            allowed_github_orgs:
              - JozzyAI
          nodes:
        #{nodes_yaml}
          agents:
            mock:
              permission_mode: "default"
            claude-code:
              permission_mode: "unsafe-skip"
          defaults:
            repo: "https://github.com/JozzyAI/fin_bot"
            node: "company-node"
            agent: "claude-code"
            encrypt: true
        """
      )

      {:ok, %{config: config}} = Workflow.load()
      {:ok, settings} = SymphonyElixir.Config.Schema.parse(config)

      assert {:error, {:missing_node_id, "company-node"}} =
               Binding.resolve(issue(labels: ["node:company-node"]), settings)
    end
  end

  describe "resolve/2 — agent resolution" do
    test "agent:claude-code resolves when allowlisted on node" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["agent:claude-code"]), settings)
      assert resolved.agent == "claude-code"
      assert resolved.permission_mode == "unsafe-skip"
    end

    test "agent:mock resolves and uses default permission_mode" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: ["agent:mock"]), settings)
      assert resolved.agent == "mock"
      assert resolved.permission_mode == "default"
    end

    test "unknown agent is rejected" do
      settings = settings_with_binding(%{nodes: default_nodes()})

      assert {:error, {:unknown_agent, "codex", _}} =
               Binding.resolve(issue(labels: ["agent:codex"]), settings)
    end

    test "agent not in node's allowed_agents is rejected" do
      nodes = %{
        "company-node" => %{
          relay: "wss://relay.example.com",
          token: "tok",
          allowed_agents: ["mock"]
        }
      }

      settings = settings_with_binding(%{nodes: nodes})

      assert {:error, {:agent_not_allowed_on_node, "claude-code", "company-node", ["mock"]}} =
               Binding.resolve(issue(labels: ["agent:claude-code"]), settings)
    end
  end

  # ---------------------------------------------------------------------------
  # Resolution priority tests
  # ---------------------------------------------------------------------------

  describe "resolve/2 — resolution priority" do
    test "issue label overrides project label" do
      nodes = %{
        "company-node" => %{relay: "wss://r.example.com", token: "t", allowed_agents: ["mock", "claude-code"]},
        "other-node" => %{relay: "wss://r2.example.com", token: "t2", allowed_agents: ["mock", "claude-code"]}
      }

      settings =
        settings_with_binding(%{
          nodes: nodes,
          defaults: %{
            repo: "https://github.com/JozzyAI/fin_bot",
            node: "other-node",
            agent: "claude-code"
          }
        })

      # Issue label says company-node, project label says other-node — issue wins
      {:ok, resolved} =
        Binding.resolve(
          issue(labels: ["node:company-node"], project_labels: ["node:other-node"]),
          settings
        )

      assert resolved.node == "company-node"
    end

    test "project label overrides WORKFLOW defaults" do
      nodes = %{
        "company-node" => %{relay: "wss://r.example.com", token: "t", allowed_agents: ["mock", "claude-code"]},
        "project-node" => %{relay: "wss://r2.example.com", token: "t2", allowed_agents: ["mock", "claude-code"]}
      }

      settings =
        settings_with_binding(%{
          nodes: nodes,
          defaults: %{
            repo: "https://github.com/JozzyAI/fin_bot",
            node: "company-node",
            agent: "claude-code"
          }
        })

      # No issue labels, project label says project-node — project wins over defaults
      {:ok, resolved} =
        Binding.resolve(
          issue(labels: [], project_labels: ["node:project-node"]),
          settings
        )

      assert resolved.node == "project-node"
    end

    test "WORKFLOW defaults are used when no labels override" do
      settings = settings_with_binding(%{nodes: default_nodes()})
      {:ok, resolved} = Binding.resolve(issue(labels: []), settings)
      assert resolved.node == "company-node"
      assert resolved.agent == "claude-code"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert resolved.encrypt == true
    end
  end

  # ---------------------------------------------------------------------------
  # Label routing tests (agent:*, repo:*, node:* -> agent_kind/repo_url/node_id)
  # ---------------------------------------------------------------------------

  describe "resolve/2 — label routing" do
    setup do
      previous = System.get_env("SYMPHONY_NODE_ID")
      System.delete_env("SYMPHONY_NODE_ID")
      on_exit(fn -> restore_env("SYMPHONY_NODE_ID", previous) end)
      :ok
    end

    test "no labels resolves to the configured defaults" do
      settings = label_routing_settings()
      {:ok, resolved} = Binding.resolve(issue(labels: []), settings)

      assert resolved.agent == "codex"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert resolved.node == "joey-pc"
      assert resolved.node_id == "node_f7cedd3b6590aff9"
    end

    test "agent:mock label overrides the default agent" do
      settings = label_routing_settings()
      {:ok, resolved} = Binding.resolve(issue(labels: ["agent:mock"]), settings)

      assert resolved.agent == "mock"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert resolved.node == "joey-pc"
    end

    test "repo:vibe_interface_cli label overrides the default repo" do
      settings = label_routing_settings()
      {:ok, resolved} = Binding.resolve(issue(labels: ["repo:vibe_interface_cli"]), settings)

      assert resolved.repo_url == "https://github.com/JozzyAI/vibe_interface_cli"
      assert resolved.agent == "codex"
      assert resolved.node == "joey-pc"
    end

    test "node:company-node label overrides the default node" do
      settings = label_routing_settings()
      {:ok, resolved} = Binding.resolve(issue(labels: ["node:company-node"]), settings)

      assert resolved.node == "company-node"
      assert resolved.agent == "codex"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
    end

    test "agent + repo + node labels together all resolve correctly" do
      settings = label_routing_settings()

      {:ok, resolved} =
        Binding.resolve(
          issue(labels: ["agent:claude-code", "repo:universe-symphony", "node:company-node"]),
          settings
        )

      assert resolved.agent == "claude-code"
      assert resolved.repo_url == "https://github.com/JozzyAI/universe-symphony"
      assert resolved.node == "company-node"
    end

    test "two agent:* labels fail fast with a conflict, dispatch is not attempted" do
      settings = label_routing_settings()

      assert {:error, {:conflicting_labels, :agent, ["codex", "mock"]}} =
               Binding.resolve(issue(labels: ["agent:codex", "agent:mock"]), settings)
    end

    test "two repo:* labels fail fast with a conflict, dispatch is not attempted" do
      settings = label_routing_settings()

      assert {:error, {:conflicting_labels, :repo, ["fin_bot", "vibe_interface_cli"]}} =
               Binding.resolve(
                 issue(labels: ["repo:fin_bot", "repo:vibe_interface_cli"]),
                 settings
               )
    end

    test "two node:* labels fail fast with a conflict, dispatch is not attempted" do
      settings = label_routing_settings()

      assert {:error, {:conflicting_labels, :node, ["joey-pc", "company-node"]}} =
               Binding.resolve(issue(labels: ["node:joey-pc", "node:company-node"]), settings)
    end

    test "unknown agent:* label fails fast and never dispatches" do
      settings = label_routing_settings()

      assert {:error, {:unknown_agent, "gpt5", known}} =
               Binding.resolve(issue(labels: ["agent:gpt5"]), settings)

      assert "codex" in known
      assert "mock" in known
      assert "claude-code" in known
    end

    test "repo:* label naming a repo outside allowed_repos fails fast" do
      settings = label_routing_settings()

      assert {:error, {:unknown_repo, "some-other-repo", "some-other-repo", allowed}} =
               Binding.resolve(issue(labels: ["repo:some-other-repo"]), settings)

      assert "fin_bot" in allowed
      assert "vibe_interface_cli" in allowed
      assert "universe-symphony" in allowed
    end

    test "unknown node:* label fails fast and never dispatches" do
      settings = label_routing_settings()

      assert {:error, {:unknown_node, "gpu-cluster", known}} =
               Binding.resolve(issue(labels: ["node:gpu-cluster"]), settings)

      assert "joey-pc" in known
      assert "company-node" in known
    end

    test "unknown agent:* label never silently falls back to the configured default agent" do
      settings = label_routing_settings()

      # defaults.agent is the valid "codex", but an explicit invalid agent
      # label must still fail -- never silently substitute the default.
      assert {:error, {:unknown_agent, "gpt5", _known}} =
               Binding.resolve(issue(labels: ["agent:gpt5"]), settings)
    end
  end

  # ---------------------------------------------------------------------------
  # Project description `vibe:` block tests
  # ---------------------------------------------------------------------------

  describe "resolve/2 — project vibe binding" do
    setup do
      previous = System.get_env("SYMPHONY_NODE_ID")
      System.delete_env("SYMPHONY_NODE_ID")
      on_exit(fn -> restore_env("SYMPHONY_NODE_ID", previous) end)
      :ok
    end

    test "no project vibe block leaves global defaults unchanged" do
      settings = label_routing_settings()

      description = "Just a plain project description, no config block here."
      {:ok, resolved} = Binding.resolve(issue(labels: [], project_description: description), settings)

      assert resolved.agent == "codex"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert resolved.node == "joey-pc"
      assert resolved.node_id == "node_f7cedd3b6590aff9"
    end

    test "project vibe repo is used when the issue has no repo label" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{repo: "vibe_interface_cli"})
      {:ok, resolved} = Binding.resolve(issue(labels: [], project_description: description), settings)

      assert resolved.repo_url == "https://github.com/JozzyAI/vibe_interface_cli"
      assert resolved.agent == "codex"
      assert resolved.node == "joey-pc"
    end

    test "project vibe default_agent is used when the issue has no agent label" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_agent: "mock"})
      {:ok, resolved} = Binding.resolve(issue(labels: [], project_description: description), settings)

      assert resolved.agent == "mock"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert resolved.node == "joey-pc"
    end

    test "project vibe default_node is used when the issue has no node label" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_node: "company-node"})
      {:ok, resolved} = Binding.resolve(issue(labels: [], project_description: description), settings)

      assert resolved.node == "company-node"
      assert resolved.agent == "codex"
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
    end

    test "issue repo label overrides the project vibe repo" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{repo: "vibe_interface_cli"})

      {:ok, resolved} =
        Binding.resolve(issue(labels: ["repo:universe-symphony"], project_description: description), settings)

      assert resolved.repo_url == "https://github.com/JozzyAI/universe-symphony"
    end

    test "issue agent label overrides the project vibe default_agent" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_agent: "mock"})

      {:ok, resolved} =
        Binding.resolve(issue(labels: ["agent:claude-code"], project_description: description), settings)

      assert resolved.agent == "claude-code"
    end

    test "issue node label overrides the project vibe default_node" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_node: "company-node"})

      {:ok, resolved} =
        Binding.resolve(issue(labels: ["node:joey-pc"], project_description: description), settings)

      assert resolved.node == "joey-pc"
    end

    test "invalid project vibe repo fails fast even when an issue repo label would otherwise win" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{repo: "some-other-repo"})

      assert {:error, {:invalid_project_repo, {:unknown_repo, "some-other-repo", "some-other-repo", allowed}}} =
               Binding.resolve(issue(labels: ["repo:fin_bot"], project_description: description), settings)

      assert "fin_bot" in allowed
    end

    test "invalid project vibe default_agent fails fast" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_agent: "gpt5"})

      assert {:error, {:invalid_project_default_agent, "gpt5", known}} =
               Binding.resolve(issue(labels: [], project_description: description), settings)

      assert "codex" in known
    end

    test "invalid project vibe default_node fails fast" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_node: "gpu-cluster"})

      assert {:error, {:invalid_project_default_node, "gpu-cluster", known}} =
               Binding.resolve(issue(labels: [], project_description: description), settings)

      assert "joey-pc" in known
      assert "company-node" in known
    end

    test "project vibe allowed_agents rejects a disallowed issue agent override" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{allowed_agents: ["codex", "mock"]})

      assert {:error, {:agent_not_allowed_by_project, "claude-code", ["codex", "mock"]}} =
               Binding.resolve(issue(labels: ["agent:claude-code"], project_description: description), settings)
    end

    test "project vibe allowed_nodes rejects a disallowed issue node override" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{allowed_nodes: ["joey-pc"]})

      assert {:error, {:node_not_allowed_by_project, "company-node", ["joey-pc"]}} =
               Binding.resolve(issue(labels: ["node:company-node"], project_description: description), settings)
    end

    test "issue label conflicts still fail fast even with a project vibe block present" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_agent: "mock"})

      assert {:error, {:conflicting_labels, :agent, ["codex", "mock"]}} =
               Binding.resolve(
                 issue(labels: ["agent:codex", "agent:mock"], project_description: description),
                 settings
               )
    end

    test "global allowed_repos is still enforced for issue repo labels with a project vibe block present" do
      settings = label_routing_settings()

      description = project_description_with_vibe(%{default_agent: "mock"})

      assert {:error, {:unknown_repo, "some-other-repo", "some-other-repo", allowed}} =
               Binding.resolve(issue(labels: ["repo:some-other-repo"], project_description: description), settings)

      assert "fin_bot" in allowed
    end

    test "binding resolution errors never include node relay tokens" do
      settings =
        settings_with_binding(%{
          nodes: %{
            "joey-pc" => %{
              relay: "wss://vibe-relay.example.com",
              token: "fake-relay-secret-99887",
              node_id: "node_f7cedd3b6590aff9",
              allowed_agents: ["mock", "claude-code", "codex"]
            }
          },
          agents: %{
            "mock" => %{permission_mode: "default"},
            "claude-code" => %{permission_mode: "unsafe-skip"},
            "codex" => %{permission_mode: "default"}
          },
          allowed_repos: ["fin_bot", "vibe_interface_cli", "universe-symphony"],
          defaults: %{repo: "https://github.com/JozzyAI/fin_bot", node: "joey-pc", agent: "codex"}
        })

      description = project_description_with_vibe(%{default_node: "gpu-cluster"})
      {:error, reason} = Binding.resolve(issue(labels: [], project_description: description), settings)

      message = Binding.describe_error(reason)

      refute message =~ "fake-relay-secret-99887"
      refute inspect(Redact.redact(reason)) =~ "fake-relay-secret-99887"
    end
  end

  describe "describe_error/1" do
    test "conflicting_labels message names both offending labels" do
      message = Binding.describe_error({:conflicting_labels, :agent, ["codex", "mock"]})

      assert message =~ "agent:codex"
      assert message =~ "agent:mock"
      assert message =~ "conflicting"
    end

    test "unknown_agent message names the offending label and known agents" do
      message = Binding.describe_error({:unknown_agent, "gpt5", ["codex", "mock", "claude-code"]})

      assert message =~ "agent:gpt5"
      assert message =~ "codex"
    end

    test "unknown_repo message names the offending label and allowed repos" do
      message =
        Binding.describe_error(
          {:unknown_repo, "some-other-repo", "some-other-repo",
           ["fin_bot", "vibe_interface_cli", "universe-symphony"]}
        )

      assert message =~ "some-other-repo"
      assert message =~ "fin_bot"
    end

    test "invalid_project_repo message names vibe.repo and the offending value" do
      message =
        Binding.describe_error(
          {:invalid_project_repo, {:unknown_repo, "some-other-repo", "some-other-repo", ["fin_bot"]}}
        )

      assert message =~ "vibe.repo"
      assert message =~ "some-other-repo"
    end

    test "invalid_project_default_agent message names vibe.default_agent and known agents" do
      message = Binding.describe_error({:invalid_project_default_agent, "gpt5", ["codex", "mock"]})

      assert message =~ "vibe.default_agent"
      assert message =~ "gpt5"
      assert message =~ "codex"
    end

    test "invalid_project_default_node message names vibe.default_node and known nodes" do
      message = Binding.describe_error({:invalid_project_default_node, "gpu-cluster", ["joey-pc"]})

      assert message =~ "vibe.default_node"
      assert message =~ "gpu-cluster"
    end

    test "agent_not_allowed_by_project message names the agent and the project allow-list" do
      message = Binding.describe_error({:agent_not_allowed_by_project, "claude-code", ["codex", "mock"]})

      assert message =~ "agent:claude-code"
      assert message =~ "allowed_agents"
    end

    test "node_not_allowed_by_project message names the node and the project allow-list" do
      message = Binding.describe_error({:node_not_allowed_by_project, "company-node", ["joey-pc"]})

      assert message =~ "node:company-node"
      assert message =~ "allowed_nodes"
    end

    test "invalid_project_vibe_config message mentions the vibe: block" do
      message = Binding.describe_error({:invalid_project_vibe_config, :project_vibe_not_a_map})

      assert message =~ "vibe:"
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy fallback tests
  # ---------------------------------------------------------------------------

  describe "resolve/2 — legacy fallback" do
    test "uses external: + repo: when no binding is configured" do
      settings = settings_legacy(repo_url: "https://github.com/JozzyAI/fin_bot", external_agent: "mock")
      {:ok, resolved} = Binding.resolve(issue(labels: []), settings)
      assert resolved.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert resolved.agent == "mock"
    end
  end

  # ---------------------------------------------------------------------------
  # Schema validation tests
  # ---------------------------------------------------------------------------

  describe "schema validation" do
    test "agent_kind vibe with binding and no repo.url is valid" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        binding:
          binding_yaml_block(%{
            nodes: default_nodes(),
            defaults: %{
              repo: "https://github.com/JozzyAI/fin_bot",
              node: "company-node",
              agent: "claude-code"
            }
          })
      )

      assert :ok = Config.validate!()
    end

    test "agent_kind vibe without binding or repo.url or after_create fails validation" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "vibe")
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "repo"
      assert message =~ "vibe"
    end
  end
end
