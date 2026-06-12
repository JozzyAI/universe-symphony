defmodule SymphonyElixir.Linear.ProjectDiscoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.ProjectDiscovery

  defmodule FakeTeamProjectsClient do
    def graphql(_query, _variables) do
      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  setup do
    previous_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeTeamProjectsClient)

    on_exit(fn ->
      case previous_client_module do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        module -> Application.put_env(:symphony_elixir, :linear_client_module, module)
      end

      Process.delete({FakeTeamProjectsClient, :graphql_result})
      Process.delete({FakeTeamProjectsClient, :graphql_results})
    end)

    :ok
  end

  defp set_graphql_result(result), do: Process.put({FakeTeamProjectsClient, :graphql_result}, result)

  defp team_projects_body(project_nodes) do
    %{
      "data" => %{
        "team" => %{
          "id" => "team-1",
          "name" => "Jozzy",
          "key" => "JOZ",
          "projects" => %{"nodes" => project_nodes}
        }
      }
    }
  end

  defp project_node(attrs) do
    Map.merge(
      %{
        "id" => "project-id",
        "name" => "Project",
        "slugId" => "project-slug",
        "state" => "started",
        "description" => nil,
        "content" => nil
      },
      attrs
    )
  end

  defp vibe_description(yaml_body) do
    """
    ## Project Overview

    ```yaml
    vibe:
    #{yaml_body}
    ```

    More notes below the config block.
    """
  end

  defp configure_auto_discovery(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_project_slug: nil,
          tracker_project_slugs: [],
          tracker_team_key: "JOZ",
          tracker_auto_discover_projects: true
        ],
        overrides
      )
    )
  end

  # ---------------------------------------------------------------------------
  # auto_discover_projects: true
  # ---------------------------------------------------------------------------

  describe "discover_projects/0 — auto_discover_projects" do
    test "discovers Symphony-enabled projects under the configured team" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-spendlens",
             "name" => "spendlens",
             "slugId" => "spendlens-abc123",
             "state" => "started",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/spendlens")
           })
         ])}
      )

      log =
        capture_log(fn ->
          assert {:ok, [project]} = ProjectDiscovery.discover_projects()
          assert project.id == "proj-spendlens"
          assert project.slug_id == "spendlens-abc123"
          assert project.name == "spendlens"
          assert project.repo == "https://github.com/JozzyAI/spendlens"
          assert project.vibe.repo == "https://github.com/JozzyAI/spendlens"
        end)

      assert log =~ "discovered project"
      assert log =~ "spendlens-abc123"
      assert log =~ "https://github.com/JozzyAI/spendlens"
    end

    test "ignores projects without a vibe: block" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{"description" => "Just a normal project description, no config block."})
         ])}
      )

      assert {:ok, []} = ProjectDiscovery.discover_projects()
    end

    test "ignores completed and canceled projects" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-done",
             "slugId" => "done-slug",
             "state" => "completed",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/done-project")
           }),
           project_node(%{
             "id" => "proj-cancel",
             "slugId" => "cancel-slug",
             "state" => "canceled",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/cancel-project")
           })
         ])}
      )

      assert {:ok, []} = ProjectDiscovery.discover_projects()
    end

    test "returns an error when team_key is not configured" do
      configure_auto_discovery(tracker_team_key: nil)

      assert {:error, :missing_linear_team_key} = ProjectDiscovery.discover_projects()
    end

    test "Client.resolve_project_slugs_for_test maps discovered projects to slugIds" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-spendlens",
             "name" => "spendlens",
             "slugId" => "spendlens-abc123",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/spendlens")
           }),
           project_node(%{"id" => "proj-other", "name" => "other", "description" => nil})
         ])}
      )

      config = SymphonyElixir.Config.settings!()

      assert {:ok, ["spendlens-abc123"]} = Client.resolve_project_slugs_for_test(config.tracker)
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed vibe: blocks
  # ---------------------------------------------------------------------------

  describe "discover_projects/0 — malformed project description" do
    test "logs a warning and skips a project with an invalid vibe: field, without crashing the poller" do
      configure_auto_discovery()

      set_graphql_result({:ok,
       team_projects_body([
         project_node(%{
           "id" => "proj-bad",
           "name" => "bad-config",
           "slugId" => "bad-config-slug",
           # allowed_agents must be a list, not a scalar.
           "description" => vibe_description("  allowed_agents: codex")
         }),
         project_node(%{
           "id" => "proj-good",
           "name" => "good-config",
           "slugId" => "good-config-slug",
           "description" => vibe_description("  repo: https://github.com/JozzyAI/good-config")
         })
       ])})

      log =
        capture_log(fn ->
          assert {:ok, [project]} = ProjectDiscovery.discover_projects()
          assert project.slug_id == "good-config-slug"
        end)

      assert log =~ "malformed vibe config"
      assert log =~ "bad-config"
    end

    test "a vibe: value that is not a mapping is logged and skipped" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-scalar",
             "name" => "scalar-vibe",
             "slugId" => "scalar-vibe-slug",
             "description" => """
             ```yaml
             vibe: not-a-map
             ```
             """
           })
         ])}
      )

      log =
        capture_log(fn ->
          assert {:ok, []} = ProjectDiscovery.discover_projects()
        end)

      assert log =~ "malformed vibe config"
      assert log =~ "scalar-vibe"
    end
  end

  # ---------------------------------------------------------------------------
  # repo_policy.allowed_repo_prefixes / allowed_repo_owners
  # ---------------------------------------------------------------------------

  describe "discover_projects/0 — repo allowlist (prefixes/owners)" do
    test "discovers a project whose vibe.repo matches an allowed_repo_prefix" do
      configure_auto_discovery(binding: %{repo_policy: %{allowed_repo_prefixes: ["https://github.com/JozzyAI/"]}})

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-spendlens",
             "name" => "spendlens",
             "slugId" => "spendlens-abc123",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/spendlens")
           })
         ])}
      )

      assert {:ok, [project]} = ProjectDiscovery.discover_projects()
      assert project.repo == "https://github.com/JozzyAI/spendlens"
    end

    test "discovers a project whose vibe.repo matches an allowed_repo_owner" do
      configure_auto_discovery(binding: %{repo_policy: %{allowed_repo_owners: ["JozzyAI"]}})

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-spendlens",
             "name" => "spendlens",
             "slugId" => "spendlens-abc123",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/spendlens")
           })
         ])}
      )

      assert {:ok, [project]} = ProjectDiscovery.discover_projects()
      assert project.repo == "https://github.com/JozzyAI/spendlens"
    end

    test "logs invalid_project_repo and skips a project whose vibe.repo is outside allowed_repo_prefixes" do
      configure_auto_discovery(binding: %{repo_policy: %{allowed_repo_prefixes: ["https://github.com/JozzyAI/"]}})

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-evil",
             "name" => "evil-project",
             "slugId" => "evil-slug",
             "description" => vibe_description("  repo: https://github.com/evil-org/malware")
           })
         ])}
      )

      log =
        capture_log(fn ->
          assert {:ok, []} = ProjectDiscovery.discover_projects()
        end)

      assert log =~ "invalid_project_repo"
      assert log =~ "evil-project"
    end

    test "logs invalid_project_repo and skips a project whose vibe.repo is outside allowed_repo_owners" do
      configure_auto_discovery(binding: %{repo_policy: %{allowed_repo_owners: ["JozzyAI"]}})

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-evil",
             "name" => "evil-project",
             "slugId" => "evil-slug",
             "description" => vibe_description("  repo: https://github.com/evil-org/malware")
           })
         ])}
      )

      log =
        capture_log(fn ->
          assert {:ok, []} = ProjectDiscovery.discover_projects()
        end)

      assert log =~ "invalid_project_repo"
      assert log =~ "evil-project"
    end
  end
end
