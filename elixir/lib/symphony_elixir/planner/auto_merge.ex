defmodule SymphonyElixir.Planner.AutoMerge do
  @moduledoc """
  Symphony auto-merge v1 for child issue PRs.

  Resolution order (all must pass):
  1. `auto_merge.enabled: true` in WORKFLOW.md
  2. PR repo exactly in `auto_merge.allowed_repos`
  3. Issue is a child (has parent_id, no type:plan label)
  4. Auto-merge consent:
     - issue description has `Auto merge: true` → eligible
     - issue description has `Auto merge: false` → never eligible
     - issue description has no `Auto merge:` line → fall back to
       project_description phrases (auto-merge, automatically merge, etc.)
  5. PR is open, mergeable (no conflicts), checks passed

  Idempotency: `<!-- symphony:auto-merge:v1 ... status=merged -->` marker
  prevents re-processing. Terminal failures post one comment and stop retrying;
  pending checks retry silently on the next poll.
  """

  require Logger

  alias SymphonyElixir.{Redact, Tracker}
  alias SymphonyElixir.Linear.Adapter

  @pr_url_regex ~r/Symphony: PR ready for review — (https:\/\/github\.com\/\S+)/
  @merge_marker_prefix "<!-- symphony:auto-merge:v1"
  @auto_merge_positive_regex ~r/\bauto[\s_\-]?merge\b|\bautomatically\s+merge\b|\bmerge\s+child\s+(?:prs?|pull\s+requests?)\s+after\s+checks?\s+pass\b/i
  @auto_merge_negative_regex ~r/\b(?:do\s+not|don'?t|no)\s+(?:auto[\s_\-]?merge|automatically\s+merge)\b|\bmanual\s+review\s+required\b|\bhuman\s+review\s+(?:only|required)\b/i

  @doc """
  Scans issues in Human Review state and auto-merges eligible PRs.

  Takes a config map or struct with `:auto_merge` and `:planner` keys.
  Returns `:ok` always; errors are logged per issue without aborting the scan.
  """
  @spec scan_and_merge(map()) :: :ok
  def scan_and_merge(%{auto_merge: %{enabled: false}}), do: :ok

  def scan_and_merge(%{auto_merge: auto_merge, planner: planner}) do
    trigger_label = planner.trigger_label

    case Tracker.fetch_issues_by_states(["Human Review"]) do
      {:ok, issues} ->
        Enum.each(issues, fn issue ->
          case maybe_merge_issue(issue, trigger_label, auto_merge) do
            :merged ->
              Logger.info("AutoMerge: merged PR for issue #{issue.identifier} (id=#{issue.id})")

            :skipped ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "AutoMerge: error for issue #{issue.identifier}: #{inspect(Redact.redact(reason))}"
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "AutoMerge: failed to fetch Human Review issues: #{inspect(Redact.redact(reason))}"
        )
    end

    :ok
  end

  # ─── Private ────────────────────────────────────────────────────────────────

  defp maybe_merge_issue(issue, trigger_label, auto_merge) do
    cond do
      trigger_label in (issue.labels || []) ->
        :skipped

      is_nil(issue.parent_id) ->
        :skipped

      not resolve_auto_merge(issue) ->
        :skipped

      true ->
        run_merge_checks(issue, auto_merge)
    end
  end

  defp run_merge_checks(issue, auto_merge) do
    case Adapter.fetch_issue_comments(issue.id) do
      {:ok, comments} ->
        if has_auto_merge_marker?(comments, issue.id) do
          :skipped
        else
          attempt_merge(issue, comments, auto_merge)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt_merge(issue, comments, auto_merge) do
    with {:ok, pr_url} <- extract_pr_url(comments),
         :ok <- check_repo_allowed(pr_url, auto_merge.allowed_repos),
         {:ok, pr_info} <- github_client().get_pr(pr_url),
         :ok <- check_pr_open(pr_info),
         :ok <- check_pr_mergeable(pr_info, issue),
         :ok <- check_checks(pr_info, auto_merge) do
      perform_merge(issue, pr_url, auto_merge)
    else
      {:skip, _reason} ->
        :skipped

      {:skip_terminal, reason} ->
        post_skip_comment(issue, reason)
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_auto_merge(issue) do
    case parse_issue_auto_merge(issue.description) do
      true -> true
      false -> false
      nil -> parse_project_auto_merge(issue.project_description)
    end
  end

  defp parse_issue_auto_merge(nil), do: nil

  defp parse_issue_auto_merge(description) do
    cond do
      Regex.match?(~r/Auto merge:\s*true/i, description) -> true
      Regex.match?(~r/Auto merge:\s*false/i, description) -> false
      true -> nil
    end
  end

  defp parse_project_auto_merge(nil), do: false

  defp parse_project_auto_merge(project_description) do
    cond do
      Regex.match?(@auto_merge_negative_regex, project_description) -> false
      Regex.match?(@auto_merge_positive_regex, project_description) -> true
      true -> false
    end
  end

  defp has_auto_merge_marker?(comments, issue_id) do
    Enum.any?(comments, fn comment ->
      body = Map.get(comment, :body, "")
      String.contains?(body, @merge_marker_prefix) and
        String.contains?(body, "issue=#{issue_id}")
    end)
  end

  defp extract_pr_url(comments) do
    combined = Enum.map_join(comments, "\n", &Map.get(&1, :body, ""))

    case Regex.run(@pr_url_regex, combined) do
      [_, url] -> {:ok, url}
      nil -> {:skip, "no PR URL found in comments"}
    end
  end

  defp check_repo_allowed(pr_url, allowed_repos) do
    case extract_repo_url(pr_url) do
      {:ok, repo_url} ->
        if repo_url in allowed_repos do
          :ok
        else
          {:skip_terminal, "PR repo not in auto_merge.allowed_repos: #{repo_url}"}
        end

      :error ->
        {:skip_terminal, "Cannot determine repo URL from PR URL: #{pr_url}"}
    end
  end

  defp extract_repo_url(pr_url) do
    case Regex.run(~r|^(https://github\.com/[^/]+/[^/]+)/pull/|, pr_url) do
      [_, repo_url] -> {:ok, repo_url}
      nil -> :error
    end
  end

  defp check_pr_open(%{state: "OPEN"}), do: :ok
  defp check_pr_open(%{state: state}), do: {:skip, "PR is not open (state=#{state})"}

  defp check_pr_mergeable(%{mergeable: "MERGEABLE"}, _issue), do: :ok

  defp check_pr_mergeable(%{mergeable: "CONFLICTING"}, issue),
    do: {:skip_terminal, "PR has merge conflicts for issue #{issue.identifier}"}

  defp check_pr_mergeable(%{mergeable: other}, _issue),
    do: {:skip, "PR mergeable=#{other}; will retry when resolved"}

  defp check_checks(%{checks_status: :passed}, _auto_merge), do: :ok

  defp check_checks(%{checks_status: :no_checks}, %{allow_no_checks: true}), do: :ok

  defp check_checks(%{checks_status: :no_checks}, _auto_merge),
    do: {:skip_terminal, "PR has no status checks and allow_no_checks is false"}

  defp check_checks(%{checks_status: :pending}, _auto_merge),
    do: {:skip, "PR checks are still pending; will retry"}

  defp check_checks(%{checks_status: :failed}, _auto_merge),
    do: {:skip_terminal, "PR checks failed"}

  defp perform_merge(issue, pr_url, auto_merge) do
    case github_client().merge_pr(pr_url, auto_merge.merge_method, auto_merge.delete_branch) do
      :ok ->
        marker = merge_marker(issue.id, pr_url)
        _ = Tracker.create_comment(issue.id, marker)
        move_to_done(issue)

      {:error, reason} ->
        Logger.warning(
          "AutoMerge: gh merge failed for issue #{issue.identifier} pr=#{pr_url}: #{inspect(Redact.redact(reason))}"
        )

        {:error, reason}
    end
  end

  defp move_to_done(issue) do
    case Tracker.update_issue_state(issue.id, "Done") do
      :ok ->
        :merged

      {:error, reason} ->
        Logger.warning(
          "AutoMerge: merged PR but failed to move issue #{issue.identifier} to Done: #{inspect(Redact.redact(reason))}"
        )

        :merged
    end
  end

  defp post_skip_comment(issue, reason) do
    body = "Symphony: auto-merge skipped — #{reason}"
    _ = Tracker.create_comment(issue.id, body)
    :ok
  end

  defp merge_marker(issue_id, pr_url) do
    "#{@merge_marker_prefix} issue=#{issue_id} pr=#{pr_url} status=merged -->"
  end

  defp github_client do
    Application.get_env(:symphony_elixir, :github_client_module, SymphonyElixir.GitHub.Client)
  end
end
