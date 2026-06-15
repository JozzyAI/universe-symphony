defmodule SymphonyElixir.Planner.Runner do
  @moduledoc """
  Executes the Planner for a single parent Linear issue.

  Builds a planner prompt for the parent issue, runs it through the Codex
  planner via `SymphonyElixir.Codex.ExternalExecutor` (no repo/workspace),
  extracts the proposed child issue specs, creates them as child Linear
  issues, and moves the parent to Human Review.

  Node/relay/token routing is resolved via `SymphonyElixir.Binding.resolve/2`
  — the same shared resolution `AgentRunner` uses for coding dispatch — so
  the planner agent (`planner.agent`, e.g. `codex`) is dispatched to whatever
  node actually advertises it, rather than always falling back to the local
  node registry. Only `binding.node_id`/`relay`/`token`/`encrypt` are reused
  this way; `repo_url` from the binding is used solely as an informational
  note in generated child issue descriptions and is never passed to the
  executor.

  This module never writes code, opens pull requests, or merges anything —
  it only creates Linear issues and posts/transitions on the parent issue.
  Every step is best-effort and idempotent: a `<!-- symphony-planner:v1 -->`
  marker comment on the parent records completion so a retry never creates
  duplicate children.
  """

  require Logger

  alias SymphonyElixir.{Binding, Config, Redact, Tracker}
  alias SymphonyElixir.Codex.ExternalExecutor
  alias SymphonyElixir.Linear.{Adapter, Issue}
  alias SymphonyElixir.Planner.{PlanExtractor, Prompt}

  @marker_prefix "<!-- symphony-planner:v1"
  @human_review_state "Human Review"

  @type outcome ::
          :already_done
          | {:created_children, [String.t()]}
          | {:failed, term()}

  @doc """
  Runs the Planner for `issue` (the parent issue).

  Always returns `{:ok, outcome}` — failures are handled internally by
  posting a comment on the parent and moving it to Human Review, so the
  caller never needs to retry.

  ## Options

    * `:recipient` - if a pid, receives `{:planner_done, issue.id}` once this
      run finishes (success, handled failure, or crash). Used by the
      orchestrator to release its dispatch claim on the issue.
  """
  @spec run(Issue.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(issue, opts \\ [])

  def run(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    recipient = Keyword.get(opts, :recipient)

    try do
      do_run(issue)
    rescue
      error ->
        reason = {:planner_crashed, Exception.format(:error, error, __STACKTRACE__)}
        Logger.error("PlannerRunner crashed for #{issue_context(issue)}: #{inspect(Redact.redact(reason))}")
        fail_run(issue, reason)
    after
      notify_done(recipient, issue_id)
    end
  end

  def run(issue, _opts), do: {:error, {:invalid_issue, issue}}

  # ── Idempotency ──────────────────────────────────────────────────────────

  defp do_run(issue) do
    case idempotency_state(issue) do
      {:done, current_state} ->
        maybe_restore_human_review(issue, current_state)
        {:ok, :already_done}

      {:fresh, existing_children} ->
        execute_plan(issue, existing_children)
    end
  end

  defp idempotency_state(%Issue{id: issue_id, state: state} = issue) do
    case Adapter.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        if Enum.any?(comments, &marker_comment?(&1, issue_id)) do
          {:done, state}
        else
          {:fresh, fetch_existing_children(issue)}
        end

      {:error, reason} ->
        Logger.warning(
          "PlannerRunner: failed to fetch comments for #{issue_context(issue)}: #{inspect(Redact.redact(reason))}"
        )

        {:fresh, fetch_existing_children(issue)}
    end
  end

  defp fetch_existing_children(%Issue{id: issue_id} = issue) do
    case Adapter.fetch_issue_children(issue_id) do
      {:ok, children} ->
        children

      {:error, reason} ->
        Logger.warning(
          "PlannerRunner: failed to fetch existing children for #{issue_context(issue)}: #{inspect(Redact.redact(reason))}"
        )

        []
    end
  end

  defp marker_comment?(%{body: body}, issue_id) when is_binary(body) do
    String.contains?(body, "#{@marker_prefix} parent=#{issue_id}")
  end

  defp marker_comment?(_comment, _issue_id), do: false

  defp maybe_restore_human_review(issue, current_state) do
    if normalize_state(current_state) != normalize_state(@human_review_state) do
      case Tracker.update_issue_state(issue.id, @human_review_state) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "PlannerRunner: failed to move #{issue_context(issue)} to #{@human_review_state}: #{inspect(Redact.redact(reason))}"
          )
      end
    else
      :ok
    end
  end

  # ── Plan execution ───────────────────────────────────────────────────────

  defp execute_plan(issue, existing_children) do
    config = Config.settings!()
    planner_config = config.planner

    case Binding.resolve(issue, config) do
      {:ok, binding} ->
        repo_url = binding_repo_url(binding)
        prompt = build_prompt(issue, repo_url)

        case run_planner_executor(issue, prompt, config, binding) do
          {:ok, output} ->
            case PlanExtractor.extract_plan(output) do
              {:ok, %{children: children}} ->
                if length(children) > planner_config.max_children do
                  fail_run(issue, {:too_many_children, length(children), planner_config.max_children})
                else
                  create_children(issue, children, existing_children, repo_url, planner_config)
                end

              {:error, reason} ->
                fail_run(issue, {:plan_extraction_failed, reason})
            end

          {:error, reason} ->
            fail_run(issue, {:executor_failed, reason})
        end

      {:error, reason} ->
        fail_run(issue, {:binding_resolution_failed, reason})
    end
  end

  # `binding.repo_url` is used only to surface a "repo binding note" in child
  # descriptions — it is informational and never passed to the executor (the
  # planner never sets up a coding workspace).
  defp binding_repo_url(%{repo_url: repo_url}) when is_binary(repo_url) and repo_url != "", do: repo_url
  defp binding_repo_url(_binding), do: nil

  defp build_prompt(issue, repo_url) do
    Prompt.build(%{
      parent_identifier: issue.identifier,
      parent_title: issue.title,
      parent_description: issue.description,
      project_id: issue.project_id,
      project_description: issue.project_description,
      project_labels: issue.project_labels,
      repo_url: repo_url
    })
  end

  # Runs the planner turn with no repo_url and no coding workspace, forcing
  # the safe/default permission mode regardless of the configured agent
  # permission mode (this run never writes code).
  #
  # `node`/`relay`/`token`/`encrypt` are taken from the resolved `binding` —
  # the same node/relay routing AgentRunner uses for coding dispatch — so a
  # planner agent that's only advertised by a relay-paired remote node (e.g.
  # `codex`) is dispatched to that node instead of silently falling back to
  # the local node registry.
  #
  # `agent: config.planner.agent` (default "codex") is used instead of
  # `binding.agent`/`config.external.agent` (default "mock") — the mock
  # backend's canned simulation always emits an `approval_required` event
  # partway through, which would make every planner run fail.
  # `deny_pending_approvals: true` is a backstop: if the planner turn
  # nonetheless requests file-modification approval, ExternalExecutor denies
  # it and stops the run instead of leaving it pending.
  defp run_planner_executor(issue, prompt, config, binding) do
    {:ok, output_agent} = Agent.start_link(fn -> [] end)

    on_message = fn
      %{event: :output, message: message} when is_binary(message) ->
        Agent.update(output_agent, fn acc -> [message | acc] end)
        :ok

      _other ->
        :ok
    end

    result =
      executor_module().run(issue, prompt, nil,
        command: config.external.command,
        agent: config.planner.agent,
        node: binding.node_id,
        relay: binding.relay,
        token: binding.token,
        encrypt: binding.encrypt,
        repo_url: nil,
        permission_mode: "default",
        deny_pending_approvals: true,
        on_message: on_message
      )

    output = output_agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("")
    Agent.stop(output_agent)

    case result do
      :ok -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp executor_module do
    Application.get_env(:symphony_elixir, :planner_executor_module, ExternalExecutor)
  end

  # ── Child issue creation ─────────────────────────────────────────────────

  defp create_children(issue, children, existing_children, repo_url, planner_config) do
    case resolve_child_state_id(issue, planner_config.child_initial_state) do
      {:ok, state_id} ->
        do_create_children(issue, children, existing_children, repo_url, state_id)

      {:error, reason} ->
        fail_run(issue, {:state_resolution_failed, planner_config.child_initial_state, reason})
    end
  end

  defp resolve_child_state_id(%Issue{team_id: team_id}, state_name) when is_binary(team_id) do
    Adapter.resolve_team_state_id(team_id, state_name)
  end

  defp resolve_child_state_id(_issue, _state_name), do: {:error, :missing_team_id}

  # Reuses children from a previous partial run (matched by title) instead of
  # creating duplicates, and stops at the first creation failure so a retry
  # has a well-defined, non-duplicated starting point.
  defp do_create_children(issue, children, existing_children, repo_url, state_id) do
    existing_by_title = Map.new(existing_children, fn child -> {normalize_title(child.title), child} end)

    result =
      Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
        case Map.get(existing_by_title, normalize_title(child.title)) do
          %{} = existing ->
            {:cont, {:ok, [existing.identifier || existing.id | acc]}}

          nil ->
            case create_child_issue(issue, child, repo_url, state_id) do
              {:ok, identifier} -> {:cont, {:ok, [identifier | acc]}}
              {:error, reason} -> {:halt, {:error, reason, acc}}
            end
        end
      end)

    case result do
      {:ok, identifiers} ->
        finalize_success(issue, Enum.reverse(identifiers))

      {:error, reason, partial} ->
        fail_run(issue, {:child_creation_failed, reason, Enum.reverse(partial)})
    end
  end

  defp normalize_title(title) when is_binary(title), do: title |> String.trim() |> String.downcase()
  defp normalize_title(_title), do: ""

  defp create_child_issue(issue, child, repo_url, state_id) do
    attrs =
      %{
        team_id: issue.team_id,
        parent_id: issue.id,
        title: child.title,
        description: build_child_description(child, repo_url),
        state_id: state_id
      }
      |> maybe_put(:project_id, issue.project_id)
      |> maybe_put(:label_ids, resolve_label_ids(issue.team_id, child.labels))

    case Adapter.create_issue(attrs) do
      {:ok, %{identifier: identifier}} when is_binary(identifier) -> {:ok, identifier}
      {:ok, %{id: id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Best-effort: an unresolvable label name is skipped rather than failing
  # the whole planning run.
  defp resolve_label_ids(team_id, labels) when is_binary(team_id) and is_list(labels) do
    Enum.flat_map(labels, fn label_name ->
      case Adapter.resolve_team_label_id(team_id, label_name) do
        {:ok, id} -> [id]
        {:error, _reason} -> []
      end
    end)
  end

  defp resolve_label_ids(_team_id, _labels), do: []

  defp build_child_description(child, repo_url) do
    acceptance = Enum.map_join(child.acceptance_criteria, "\n", &"- #{&1}")

    [
      child.description,
      "## Acceptance criteria\n\n#{acceptance}",
      "Open a PR, do not merge.",
      repo_binding_note(repo_url)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp repo_binding_note(nil), do: nil
  defp repo_binding_note(""), do: nil
  defp repo_binding_note(repo_url), do: "Repo binding: #{repo_url}"

  # ── Outcome reporting ────────────────────────────────────────────────────

  defp finalize_success(issue, identifiers) do
    post_comment(issue, success_comment(issue.id, identifiers))
    move_to_human_review(issue)

    {:ok, {:created_children, identifiers}}
  end

  defp success_comment(issue_id, identifiers) do
    list = Enum.map_join(identifiers, "\n", &"- #{&1}")

    """
    Symphony Planner created #{length(identifiers)} child issue(s):

    #{list}

    #{marker_comment(issue_id, identifiers)}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp marker_comment(issue_id, identifiers) do
    "#{@marker_prefix} parent=#{issue_id} children=[#{Enum.join(identifiers, ",")}] -->"
  end

  defp fail_run(issue, reason) do
    Logger.warning("PlannerRunner failed for #{issue_context(issue)}: #{inspect(Redact.redact(reason))}")

    post_comment(issue, failure_comment(reason))
    move_to_human_review(issue)

    {:ok, {:failed, reason}}
  end

  defp failure_comment(reason) do
    "Symphony Planner could not finish planning this issue: #{describe_failure(reason)}\n\n" <>
      "Moved to Human Review — fix the issue and move it back to Todo to retry."
  end

  defp describe_failure({:binding_resolution_failed, reason}), do: Binding.describe_error(reason)

  defp describe_failure({:executor_failed, reason}), do: "the planner run failed (#{inspect(reason)})"

  defp describe_failure({:plan_extraction_failed, reason}),
    do: "the planner output could not be parsed (#{inspect(reason)})"

  defp describe_failure({:too_many_children, count, max}),
    do: "the planner proposed #{count} child issues, exceeding the configured limit of #{max}"

  defp describe_failure({:state_resolution_failed, state_name, reason}),
    do: "the configured child state #{inspect(state_name)} could not be resolved (#{inspect(reason)})"

  defp describe_failure({:child_creation_failed, reason, partial}),
    do: "creating a child issue failed (#{inspect(reason)}) after creating #{length(partial)} child issue(s)"

  defp describe_failure({:planner_crashed, _formatted}), do: "the planner run crashed unexpectedly"

  defp describe_failure(reason), do: inspect(reason)

  defp post_comment(issue, body) do
    case Tracker.create_comment(issue.id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("PlannerRunner: failed to comment on #{issue_context(issue)}: #{inspect(Redact.redact(reason))}")
    end
  end

  defp move_to_human_review(issue) do
    case Tracker.update_issue_state(issue.id, @human_review_state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "PlannerRunner: failed to move #{issue_context(issue)} to #{@human_review_state}: #{inspect(Redact.redact(reason))}"
        )
    end
  end

  defp notify_done(recipient, issue_id) when is_pid(recipient) do
    send(recipient, {:planner_done, issue_id})
    :ok
  end

  defp notify_done(_recipient, _issue_id), do: :ok

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
