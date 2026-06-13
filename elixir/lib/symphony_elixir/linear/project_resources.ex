defmodule SymphonyElixir.Linear.ProjectResources do
  @moduledoc """
  Helpers for interpreting a Linear project's "Resources" (external links).

  `SymphonyElixir.Linear.Issue.project_resources` is a flat list of raw URL
  strings taken from the Linear project's "Resources" section (the
  `project.externalLinks` GraphQL field). This module picks out GitHub
  repository links from that list.

  This is an extraction helper used by `SymphonyElixir.Binding` when resolving
  an issue's repo binding — see `SymphonyElixir.Binding` for the full
  resolution order and `docs/project-resources.md` for details.
  """

  @github_repo ~r{^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)}

  @doc """
  Extract normalized `https://github.com/org/repo` URLs from a list of
  resource URLs.

  Non-GitHub URLs and malformed/unrecognized URLs are dropped silently.
  Trailing path segments (e.g. `/pull/123`), `.git` suffixes, and trailing
  slashes are stripped so links into a repo (not just to its root) still
  resolve to that repo. Duplicate repos are de-duplicated, preserving the
  order of first appearance.
  """
  @spec github_repo_urls([term()]) :: [String.t()]
  def github_repo_urls(urls) when is_list(urls) do
    urls
    |> Enum.map(&github_repo_url/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Normalize a single URL to `https://github.com/org/repo` if it points at a
  GitHub repository (or something inside one), or return `nil` otherwise.
  """
  @spec github_repo_url(term()) :: String.t() | nil
  def github_repo_url(url) when is_binary(url) do
    case Regex.run(@github_repo, url) do
      [_, org, repo] -> normalize_repo(org, repo)
      _ -> nil
    end
  end

  def github_repo_url(_), do: nil

  defp normalize_repo(org, repo) do
    case String.trim_trailing(repo, ".git") do
      "" -> nil
      repo_name -> "https://github.com/#{org}/#{repo_name}"
    end
  end
end
