defmodule SymphonyElixir.DuplicateDispatchTest do
  @moduledoc """
  Regression tests for the JOZ-23 duplicate-dispatch bug: the same Linear
  issue must never have more than one agent run in flight at a time.

  Tests 1-3 cover the existing `claimed`/`running` guard in
  `should_dispatch_issue?/5` (agent-agnostic): an issue that is already
  claimed or running is never dispatched a second time, whether it
  reappears across consecutive polls or twice within the same poll.

  Tests 4-5 (plus the stall test) cover the new `agent_kind: "vibe"`
  terminal handling in `handle_agent_down/5` and `restart_stalled_issue/5`:
  any run that ends without a PR is sent to Human Review and its claim is
  released for good, instead of being retried via
  `schedule_issue_retry/4` -> `handle_active_retry/4` -> `dispatch_issue/4`,
  which bypasses the `claimed`/`running` checks and was the root cause of
  the duplicate dispatch.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator

  # Workspace root that is guaranteed to fail fast on creation (a path nested
  # inside a regular file). This lets a dispatched issue's async AgentRunner
  # task fail immediately during Workspace.create_for_issue, before any git
  # clone or codex/vibe subprocess would run, while still letting
  # dispatch_issue synchronously claim the issue and update
  # state.running/state.claimed.
  defp unusable_workspace_root!(name) do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    blocker = Path.join(test_root, "blocker")
    File.write!(blocker, "x")

    on_exit(fn -> File.rm_rf(test_root) end)

    Path.join(blocker, "workspaces")
  end

  describe "an issue that is already claimed/running is not dispatched again" do
    test "1. same issue returned across two consecutive polls while the first dispatch is still starting only spawns one agent" do
      workspace_root = unusable_workspace_root!("two-polls")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state_after_poll_1 = Orchestrator.choose_issues_for_test([issue], %Orchestrator.State{})

      assert %{pid: pid, ref: ref} = state_after_poll_1.running["issue-1"]
      assert MapSet.equal?(state_after_poll_1.claimed, MapSet.new(["issue-1"]))

      # Poll 2 sees the same issue again (e.g. the In Progress transition
      # hasn't been observed yet) while the first dispatch is still claimed
      # and running.
      state_after_poll_2 = Orchestrator.choose_issues_for_test([issue], state_after_poll_1)

      assert map_size(state_after_poll_2.running) == 1
      assert state_after_poll_2.running["issue-1"].pid == pid
      assert state_after_poll_2.running["issue-1"].ref == ref
      assert MapSet.equal?(state_after_poll_2.claimed, MapSet.new(["issue-1"]))
    end

    test "2. same issue appearing twice in one poll's candidate list only spawns one agent" do
      workspace_root = unusable_workspace_root!("dup-in-batch")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      result_state = Orchestrator.choose_issues_for_test([issue, issue], %Orchestrator.State{})

      assert map_size(result_state.running) == 1
      assert MapSet.equal?(result_state.claimed, MapSet.new(["issue-1"]))
    end

    test "3. issue is skipped while its issue_id is already claimed or running" do
      issue = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}

      claimed_state = %Orchestrator.State{claimed: MapSet.new([issue.id])}
      refute Orchestrator.should_dispatch_issue_for_test(issue, claimed_state)

      running_state = %Orchestrator.State{
        running: %{
          issue.id => %{issue: issue, pid: self(), ref: make_ref(), identifier: issue.identifier, worker_host: nil}
        }
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, running_state)
    end
  end

  describe "agent_kind: vibe terminal handling releases the claim instead of retrying" do
    test "4. claim is released after a successful vibe run produces a PR" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens"
      )
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-vibe-pr"
      pr_url = "https://github.com/JozzyAI/spendlens/pull/3"
      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :VibePrOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "JOZ-23",
        vibe_run_id: "run_abc123",
        vibe_pr_url: pr_url,
        issue: %Issue{id: issue_id, identifier: "JOZ-23", state: "In Progress"},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})

      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ pr_url

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    end

    test "5. claim is released and issue moves to Human Review when a vibe run exits without producing a run id" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens"
      )
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-vibe-start-failure"
      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :VibeStartFailureOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      # No :vibe_run_id and no :vibe_pr_url: the agent task exited before
      # ExternalExecutor ever obtained a run id (e.g. Workspace.create_for_issue
      # failed, or `vibe symphony start` itself failed to start).
      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "JOZ-23",
        issue: %Issue{id: issue_id, identifier: "JOZ-23", state: "In Progress"},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :boom})

      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Human Review"
      assert comment =~ "exited unexpectedly"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    end

    test "vibe issue that stalls moves to Human Review and releases its claim instead of retrying" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens",
        codex_stall_timeout_ms: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-vibe-stall"
      orchestrator_name = Module.concat(__MODULE__, :VibeStallOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      worker_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: "JOZ-23",
        vibe_run_id: "run_abc123",
        issue: %Issue{id: issue_id, identifier: "JOZ-23", state: "In Progress"},
        last_codex_timestamp: stale_activity_at,
        started_at: stale_activity_at
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      end)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 1_000
      assert comment =~ "Human Review"
      assert comment =~ "stalled"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    end
  end
end
