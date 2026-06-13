defmodule SymphonyElixir.Linear.ProjectDiscovery do
  @moduledoc """
  Discovers active Linear projects under a configured team.

  This powers `tracker.auto_discover_projects: true` (see
  `SymphonyElixir.Config.Schema.Tracker`): instead of listing
  `tracker.project_slug`/`tracker.project_slugs` explicitly, Symphony watches
  every active (non-completed, non-canceled) project under
  `tracker.team_key`.

  ## Discovery is scope-only

  Discovery does **not** require a `vibe:` configuration block, a GitHub
  `externalLinks` Resources link, or any labels — a newly created Linear
  Project under the configured team shows up to Symphony immediately, even
  before it has a repo binding configured.

  Repo/agent/node *binding* for each issue is resolved separately by
  `SymphonyElixir.Binding.resolve/2`, from (highest priority first): issue
  labels, project labels, the project's GitHub Resources link
  (`project.externalLinks`), the project's `vibe:` description block, and
  `binding.defaults`. An issue in a discovered project that has no resolvable
  repo fails dispatch fast with a Linear comment and is moved to Human
  Review — see `SymphonyElixir.Binding.describe_error/1`'s
  `{:missing_binding, :repo, _}` clause.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @query """
  query SymphonyTeamProjects($teamKey: String!) {
    team(id: $teamKey) {
      id
      name
      key
      projects {
        nodes {
          id
          name
          slugId
          state
        }
      }
    }
  }
  """

  # Project states that are no longer relevant for polling. Every other
  # known state (backlog, planned, started, paused, ...) is considered
  # "active" for discovery purposes.
  @inactive_states ["completed", "canceled"]

  @type discovered_project :: %{
          id: String.t(),
          slug_id: String.t(),
          name: String.t()
        }

  @spec discover_projects() :: {:ok, [discovered_project()]} | {:error, term()}
  def discover_projects do
    settings = Config.settings!()

    case settings.tracker.team_key do
      team_key when is_binary(team_key) and team_key != "" ->
        with {:ok, body} <- client_module().graphql(@query, %{teamKey: team_key}) do
          decode_team_projects(body)
        end

      _ ->
        {:error, :missing_linear_team_key}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp decode_team_projects(%{"data" => %{"team" => %{"projects" => %{"nodes" => nodes}}}}) when is_list(nodes) do
    projects =
      nodes
      |> Enum.filter(&active?/1)
      |> Enum.map(&to_discovered_project/1)

    for project <- projects do
      Logger.info("Symphony: discovered project #{inspect(project.name)} slugId=#{project.slug_id}")
    end

    {:ok, projects}
  end

  defp decode_team_projects(%{"data" => %{"team" => nil}}) do
    {:error, :linear_team_not_found}
  end

  defp decode_team_projects(%{"errors" => errors}) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_team_projects(_other), do: {:error, :linear_unknown_payload}

  defp active?(%{"state" => state}) when is_binary(state), do: state not in @inactive_states
  defp active?(_project), do: true

  defp to_discovered_project(project) do
    %{id: project["id"], slug_id: project["slugId"], name: project["name"]}
  end
end
