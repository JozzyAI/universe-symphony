defmodule SymphonyElixir.VibeStallStatusTest do
  @moduledoc """
  Tests for the Vibe silent-stream stall-path status fallback introduced to fix
  the JOZ-24 discrepancy: when a `vibe symphony stream` process receives no
  events and the stall timeout fires, Symphony now queries `vibe symphony
  status` before choosing the Human Review comment.

  - If the run completed, a "stream events not received" comment is posted
    instead of the misleading "stalled without activity" wording.
  - If the run is still running, unknown, or the status query fails, the
    existing "stalled without activity" comment is preserved.
  - The happy path (pr_created + completed events arrive via the stream) is
    unchanged.
  - PlannerRunner dispatch is unaffected.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator

  # ── Fake vibe scripts ──────────────────────────────────────────────────────

  defp write_fake_vibe!(script_body) do
    path = Path.join(System.tmp_dir!(), "fake-vibe-stall-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/usr/bin/env bash\n" <> script_body)
    File.chmod!(path, 0o755)
    path
  end

  # Fake vibe: `symphony status` returns completed; `symphony stop` returns ok.
  defp vibe_status_completed! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$SUBCOMMAND-$ACTION" in
      symphony-status)
        echo '{"run_id":"run_test_stall","status":"completed"}'
        ;;
      symphony-stop)
        echo '{"status":"stopped"}'
        ;;
      *)
        exit 1
        ;;
    esac
    """)
  end

  # Fake vibe: `symphony status` returns running.
  defp vibe_status_running! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$SUBCOMMAND-$ACTION" in
      symphony-status)
        echo '{"run_id":"run_test_stall","status":"running"}'
        ;;
      symphony-stop)
        echo '{"status":"stopped"}'
        ;;
      *)
        exit 1
        ;;
    esac
    """)
  end

  # Fake vibe: `symphony status` fails (non-zero exit) to simulate a query
  # error (e.g., relay unreachable, run not found, or CLI bug).
  defp vibe_status_failure! do
    write_fake_vibe!(~s"""
    exit 1
    """)
  end

  # Fake vibe: emits pr_created then completed, for happy-path coverage.
  defp vibe_pr_completed! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"run_happy","node_id":"local","agent":"mock"}'
        ;;
      stream)
        RUN_ID="${3:-run_happy}"
        echo "{\\"type\\":\\"pr_created\\",\\"url\\":\\"https://github.com/org/repo/pull/99\\",\\"run_id\\":\\"$RUN_ID\\"}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"completed\\",\\"run_id\\":\\"$RUN_ID\\"}"
        ;;
      status)
        echo '{"run_id":"run_happy","status":"completed"}'
        ;;
      stop)
        echo '{"status":"stopped"}'
        ;;
    esac
    """)
  end

  # ── Shared stall setup ─────────────────────────────────────────────────────

  defp start_orchestrator_with_stall(fake_vibe_path) do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "vibe",
      tracker_kind: "memory",
      repo_url: "https://github.com/JozzyAI/spendlens",
      external_command: fake_vibe_path,
      codex_stall_timeout_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp inject_stalled_running_entry(orchestrator_pid, issue_id, vibe_run_id) do
    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(orchestrator_pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "JOZ-test",
      vibe_run_id: vibe_run_id,
      issue: %Issue{id: issue_id, identifier: "JOZ-test", state: "In Progress"},
      last_codex_timestamp: stale_activity_at,
      started_at: stale_activity_at
    }

    :sys.replace_state(orchestrator_pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    worker_pid
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "vibe stall + status: completed" do
    test "posts 'stream events not received' comment, moves to Human Review, releases claim" do
      pid = start_orchestrator_with_stall(vibe_status_completed!())
      issue_id = "issue-stall-completed-#{System.unique_integer([:positive])}"
      worker_pid = inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "stream events were not received"
      assert comment =~ "pull request may already exist"
      assert comment =~ "Human Review"
      refute comment =~ "stalled for"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    end

    test "does not claim a PR URL exists" do
      pid = start_orchestrator_with_stall(vibe_status_completed!())
      issue_id = "issue-stall-no-pr-url-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      refute comment =~ "PR ready"
      refute comment =~ "for review —"
    end

    test "does not schedule a retry" do
      pid = start_orchestrator_with_stall(vibe_status_completed!())
      issue_id = "issue-stall-no-retry-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, _comment}, 2_000

      state = :sys.get_state(pid)
      refute Map.has_key?(state.retry_attempts, issue_id)
    end
  end

  describe "vibe stall + status: running" do
    test "keeps existing stall wording, moves to Human Review, releases claim" do
      pid = start_orchestrator_with_stall(vibe_status_running!())
      issue_id = "issue-stall-running-#{System.unique_integer([:positive])}"
      worker_pid = inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "stalled"
      assert comment =~ "Human Review"
      refute comment =~ "stream events were not received"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    end
  end

  describe "vibe stall + status query failure" do
    test "falls back to stall wording, moves to Human Review, does not crash" do
      pid = start_orchestrator_with_stall(vibe_status_failure!())
      issue_id = "issue-stall-failure-#{System.unique_integer([:positive])}"
      worker_pid = inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "stalled"
      assert comment =~ "Human Review"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    end

    test "stall with no vibe_run_id uses stall wording and does not query status" do
      pid = start_orchestrator_with_stall(vibe_status_failure!())
      issue_id = "issue-stall-no-run-id-#{System.unique_integer([:positive])}"

      # Inject a running entry without a vibe_run_id (e.g., start failed before run_id was set)
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
        identifier: "JOZ-test",
        issue: %Issue{id: issue_id, identifier: "JOZ-test", state: "In Progress"},
        last_codex_timestamp: stale_activity_at,
        started_at: stale_activity_at
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      end)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "stalled"
      assert comment =~ "Human Review"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)
      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
    end
  end

  describe "happy path: pr_created + completed events arrive normally" do
    test "finishes with PR comment, not a stall comment" do
      workspace_root = Path.join(System.tmp_dir!(), "symphony-vibe-stall-status-happy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      fake_vibe = vibe_pr_completed!()

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens",
        external_command: fake_vibe,
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 30_000
      )

      issue = %Issue{
        id: "issue-vibe-happy",
        identifier: "JOZ-H1",
        title: "Happy path test",
        state: "Todo",
        url: "https://linear.app/test/issue/JOZ-H1"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :"HappyOrchestrator#{System.unique_integer([:positive])}")
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, "issue-vibe-happy", comment}, 5_000
      assert comment =~ "PR ready"
      assert comment =~ "https://github.com/org/repo/pull/99"
      refute comment =~ "stalled"
      refute comment =~ "stream events were not received"

      assert_receive {:memory_tracker_state_update, "issue-vibe-happy", "Human Review"}
    end
  end
end
