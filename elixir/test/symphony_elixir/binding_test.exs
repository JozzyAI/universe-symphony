defmodule SymphonyElixir.BindingTest do
  use SymphonyElixir.TestSupport

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

    orgs_yaml = Enum.map_join(orgs, "\n", &"      - #{&1}")

    defaults_repo = Map.get(defaults, :repo, "https://github.com/JozzyAI/fin_bot")
    defaults_node = Map.get(defaults, :node, "company-node")
    defaults_agent = Map.get(defaults, :agent, "claude-code")

    """
    binding:
      repo_policy:
        allowed_github_orgs:
    #{orgs_yaml}
      nodes:
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
