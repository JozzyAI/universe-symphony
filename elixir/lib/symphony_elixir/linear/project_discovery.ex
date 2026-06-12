defmodule SymphonyElixir.Linear.ProjectDiscovery do
  @moduledoc """
  Discovers Linear projects under a configured team that have opted into
  Symphony via a `vibe:` configuration block in their description/content.

  This powers `tracker.auto_discover_projects: true` (see
  `SymphonyElixir.Config.Schema.Tracker`): instead of listing
  `tracker.project_slug`/`tracker.project_slugs` explicitly, Symphony queries
  every active project under `tracker.team_key` and treats the ones with a
  valid `vibe:` block (parsed by `SymphonyElixir.Linear.ProjectVibeConfig`) as
  Symphony-enabled.

  Validation failures for an individual project never abort discovery for the
  rest of the team:

    * No fenced `vibe:` block — the project is silently ignored.
    * A `vibe:` block that fails to parse (bad YAML, wrong field types) — a
      warning is logged and the project is skipped.
    * A `vibe.repo` that fails `binding.repo_policy` validation — a warning
      (tagged `invalid_project_repo`) is logged and the project is skipped.
  """

  require Logger

  alias SymphonyElixir.{Binding, Config}
  alias SymphonyElixir.Linear.{Client, ProjectVibeConfig}

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
          description
          content
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
          name: String.t(),
          repo: String.t() | nil,
          vibe: ProjectVibeConfig.t()
        }

  @spec discover_projects() :: {:ok, [discovered_project()]} | {:error, term()}
  def discover_projects do
    settings = Config.settings!()

    case settings.tracker.team_key do
      team_key when is_binary(team_key) and team_key != "" ->
        with {:ok, body} <- client_module().graphql(@query, %{teamKey: team_key}) do
          decode_team_projects(body, settings)
        end

      _ ->
        {:error, :missing_linear_team_key}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp decode_team_projects(%{"data" => %{"team" => %{"projects" => %{"nodes" => nodes}}}}, settings)
       when is_list(nodes) do
    projects =
      nodes
      |> Enum.filter(&active?/1)
      |> Enum.flat_map(&evaluate_project(&1, settings))

    {:ok, projects}
  end

  defp decode_team_projects(%{"data" => %{"team" => nil}}, _settings) do
    {:error, :linear_team_not_found}
  end

  defp decode_team_projects(%{"errors" => errors}, _settings) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_team_projects(_other, _settings), do: {:error, :linear_unknown_payload}

  defp active?(%{"state" => state}) when is_binary(state), do: state not in @inactive_states
  defp active?(_project), do: true

  defp evaluate_project(project, settings) do
    case ProjectVibeConfig.parse(project_description(project)) do
      {:ok, nil} ->
        []

      {:ok, vibe} ->
        evaluate_vibe(project, vibe, settings)

      {:error, reason} ->
        Logger.warning("Symphony: ignoring Linear project #{inspect(project["name"])} (#{project["slugId"]}) — malformed vibe config: #{inspect(reason)}")

        []
    end
  end

  defp evaluate_vibe(project, vibe, settings) do
    case Binding.validate_repo(vibe.repo, settings) do
      {:ok, repo_url} ->
        Logger.info("Symphony: discovered project #{inspect(project["name"])} slugId=#{project["slugId"]} repo=#{inspect(repo_url)}")

        [
          %{
            id: project["id"],
            slug_id: project["slugId"],
            name: project["name"],
            repo: repo_url,
            vibe: vibe
          }
        ]

      {:error, reason} ->
        Logger.warning("Symphony: invalid_project_repo for project #{inspect(project["name"])} (#{project["slugId"]}): #{inspect(reason)}")

        []
    end
  end

  defp project_description(%{"content" => content}) when is_binary(content) and content != "", do: content

  defp project_description(%{"description" => description}) when is_binary(description) and description != "",
    do: description

  defp project_description(_project), do: nil
end
