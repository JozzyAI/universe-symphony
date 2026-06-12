defmodule SymphonyElixir.Linear.ProjectVibeConfig do
  @moduledoc """
  Parses the optional `vibe:` YAML configuration block from a Linear
  project's description/content.

  This lets a Linear Project set repo/agent/node defaults (and
  allow-lists) for every issue in that project, without requiring
  per-issue labels. Expected format (inside a fenced ```yaml code block
  in the project description):

      ```yaml
      vibe:
        repo: https://github.com/JozzyAI/fin_bot
        default_agent: codex
        default_node: joey-pc
        encrypt: true
        allowed_agents:
          - codex
          - claude-code
          - mock
        allowed_nodes:
          - joey-pc
      ```

  If no fenced code block contains a top-level `vibe:` key, the project
  has no project-level binding config (`{:ok, nil}`). If such a block
  exists but is malformed (bad YAML, `vibe:` isn't a mapping, or a known
  field has the wrong type), parsing fails with `{:error, reason}` so
  the caller can fail fast instead of silently ignoring it.
  """

  @type t :: %{
          repo: String.t() | nil,
          default_agent: String.t() | nil,
          default_node: String.t() | nil,
          encrypt: boolean() | nil,
          allowed_agents: [String.t()] | nil,
          allowed_nodes: [String.t()] | nil
        }

  @fenced_block ~r/```[a-zA-Z]*[ \t]*\n(.*?)```/s
  @vibe_key ~r/^vibe:/m

  @spec parse(String.t() | nil) :: {:ok, t() | nil} | {:error, term()}
  def parse(nil), do: {:ok, nil}

  def parse(description) when is_binary(description) do
    case find_vibe_block(description) do
      nil -> {:ok, nil}
      yaml -> decode_vibe_yaml(yaml)
    end
  end

  defp find_vibe_block(description) do
    @fenced_block
    |> Regex.scan(description, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.find(&Regex.match?(@vibe_key, &1))
  end

  defp decode_vibe_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"vibe" => vibe}} when is_map(vibe) -> normalize(vibe)
      {:ok, %{"vibe" => nil}} -> normalize(%{})
      {:ok, %{"vibe" => _other}} -> {:error, :project_vibe_not_a_map}
      {:ok, _decoded} -> {:ok, nil}
      {:error, reason} -> {:error, {:project_vibe_yaml_error, reason}}
    end
  end

  defp normalize(vibe) do
    with {:ok, repo} <- optional_string(vibe, "repo"),
         {:ok, default_agent} <- optional_string(vibe, "default_agent"),
         {:ok, default_node} <- optional_string(vibe, "default_node"),
         {:ok, encrypt} <- optional_boolean(vibe, "encrypt"),
         {:ok, allowed_agents} <- optional_string_list(vibe, "allowed_agents"),
         {:ok, allowed_nodes} <- optional_string_list(vibe, "allowed_nodes") do
      {:ok,
       %{
         repo: repo,
         default_agent: default_agent,
         default_node: default_node,
         encrypt: encrypt,
         allowed_agents: allowed_agents,
         allowed_nodes: allowed_nodes
       }}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:project_vibe_invalid_field, key}}
    end
  end

  defp optional_boolean(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:project_vibe_invalid_field, key}}
    end
  end

  defp optional_string_list(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:project_vibe_invalid_field, key}}
        end

      _other ->
        {:error, {:project_vibe_invalid_field, key}}
    end
  end
end
