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
        "state" => "started"
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
  # auto_discover_projects: false — explicit configured project only
  # ---------------------------------------------------------------------------

  describe "discover_projects/0 — auto_discover_projects: false" do
    test "Client.resolve_project_slugs_for_test uses only the explicitly configured project, never calling discovery" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "spendlens",
        tracker_project_slugs: [],
        tracker_team_key: "JOZ",
        tracker_auto_discover_projects: false
      )

      # No graphql result configured at all — if discovery were invoked, the
      # FakeTeamProjectsClient would return `nil` and resolution would crash.
      config = SymphonyElixir.Config.settings!()

      assert {:ok, ["spendlens"]} = Client.resolve_project_slugs_for_test(config.tracker)
    end
  end

  # ---------------------------------------------------------------------------
  # auto_discover_projects: true — scope-only discovery
  # ---------------------------------------------------------------------------

  describe "discover_projects/0 — auto_discover_projects: true (scope-only)" do
    test "discovers every active project under the configured team, regardless of vibe:/externalLinks/labels" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-plain",
             "name" => "plain-project",
             "slugId" => "plain-slug",
             "state" => "started"
           }),
           project_node(%{
             "id" => "proj-with-link",
             "name" => "linked-project",
             "slugId" => "linked-slug",
             "state" => "started",
             "externalLinks" => %{"nodes" => [%{"url" => "https://github.com/JozzyAI/spendlens", "label" => nil}]}
           }),
           project_node(%{
             "id" => "proj-with-vibe",
             "name" => "vibe-only-project",
             "slugId" => "vibe-only-slug",
             "state" => "backlog",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/fin_bot")
           })
         ])}
      )

      log =
        capture_log(fn ->
          assert {:ok, projects} = ProjectDiscovery.discover_projects()
          slug_ids = Enum.map(projects, & &1.slug_id)

          assert "plain-slug" in slug_ids
          assert "linked-slug" in slug_ids
          assert "vibe-only-slug" in slug_ids
          assert length(projects) == 3

          assert Enum.all?(projects, fn project -> Enum.sort(Map.keys(project)) == [:id, :name, :slug_id] end)
        end)

      assert log =~ "discovered project"
      assert log =~ "plain-slug"
      assert log =~ "linked-slug"
      assert log =~ "vibe-only-slug"
    end

    test "a project with no externalLinks at all is still discovered" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-no-links",
             "name" => "no-links-project",
             "slugId" => "no-links-slug",
             "state" => "started"
           })
         ])}
      )

      assert {:ok, [project]} = ProjectDiscovery.discover_projects()
      assert project.id == "proj-no-links"
      assert project.slug_id == "no-links-slug"
      assert project.name == "no-links-project"
    end

    test "a project with only a vibe: block and no GitHub externalLink is still discovered" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-vibe-only",
             "name" => "vibe-only-project",
             "slugId" => "vibe-only-slug",
             "state" => "started",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/spendlens")
           })
         ])}
      )

      assert {:ok, [project]} = ProjectDiscovery.discover_projects()
      assert project.slug_id == "vibe-only-slug"
    end

    test "ignores completed and canceled projects regardless of vibe/externalLinks" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{
             "id" => "proj-done",
             "slugId" => "done-slug",
             "state" => "completed",
             "externalLinks" => %{"nodes" => [%{"url" => "https://github.com/JozzyAI/done-project", "label" => nil}]}
           }),
           project_node(%{
             "id" => "proj-cancel",
             "slugId" => "cancel-slug",
             "state" => "canceled",
             "description" => vibe_description("  repo: https://github.com/JozzyAI/cancel-project")
           }),
           project_node(%{
             "id" => "proj-active",
             "slugId" => "active-slug",
             "state" => "started"
           })
         ])}
      )

      assert {:ok, [project]} = ProjectDiscovery.discover_projects()
      assert project.slug_id == "active-slug"
    end

    test "returns an error when team_key is not configured" do
      configure_auto_discovery(tracker_team_key: nil)

      assert {:error, :missing_linear_team_key} = ProjectDiscovery.discover_projects()
    end

    test "Client.resolve_project_slugs_for_test maps every discovered project to its slugId" do
      configure_auto_discovery()

      set_graphql_result(
        {:ok,
         team_projects_body([
           project_node(%{"id" => "proj-a", "name" => "a", "slugId" => "a-slug", "state" => "started"}),
           project_node(%{"id" => "proj-b", "name" => "b", "slugId" => "b-slug", "state" => "planned"})
         ])}
      )

      config = SymphonyElixir.Config.settings!()

      assert {:ok, slug_ids} = Client.resolve_project_slugs_for_test(config.tracker)
      assert "a-slug" in slug_ids
      assert "b-slug" in slug_ids
      assert length(slug_ids) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # GraphQL error handling
  # ---------------------------------------------------------------------------

  describe "discover_projects/0 — GraphQL error handling" do
    test "returns an error when the team is not found" do
      configure_auto_discovery()

      set_graphql_result({:ok, %{"data" => %{"team" => nil}}})

      assert {:error, :linear_team_not_found} = ProjectDiscovery.discover_projects()
    end

    test "returns an error when the GraphQL response contains errors" do
      configure_auto_discovery()

      set_graphql_result({:ok, %{"errors" => [%{"message" => "boom"}]}})

      assert {:error, {:linear_graphql_errors, [%{"message" => "boom"}]}} = ProjectDiscovery.discover_projects()
    end
  end
end
