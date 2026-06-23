defmodule SymphonyElixir.VibeStallStatusTest do
  @moduledoc """
  Tests for node-authoritative Vibe stall reconciliation (JOZ-37): when a `vibe
  symphony stream` process receives no events and the stall timeout fires,
  Symphony queries the authoritative node/relay run status via `vibe symphony
  status` before deciding the outcome, instead of false-parking the issue.

  - Node `completed` WITH a PR → reconcile as success (PR-ready comment), not a
    stall.
  - Node `completed` WITHOUT a PR → "stream events not received" comment, not the
    misleading "stalled without activity" wording.
  - Node `failed` → failure comment carrying the node-reported reason.
  - Node `running` → the run really did stall: existing "stalled" wording.
  - Status query inconclusive (query error / no run_id / unexpected status) →
    explicit "watchdog fired / could not be confirmed" diagnostic rather than a
    silent false-stall.
  - No secrets (relay token) ever appear in the posted comment.
  - The happy path (pr_created + completed events arrive via the stream) is
    unchanged. PlannerRunner dispatch is unaffected.
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

  # Polls (best-effort, up to timeout_ms) for `path` to exist and contain
  # `substring` -- used to deterministically observe a side effect
  # (`maybe_stop_vibe_run`) that happens after the comment message we
  # `assert_receive` on, with no other synchronization point available.
  defp wait_for_file_content(path, substring, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :poll end)
    |> Enum.reduce_while(nil, fn _, _ ->
      cond do
        File.exists?(path) and String.contains?(File.read!(path), substring) ->
          {:halt, :ok}

        System.monotonic_time(:millisecond) >= deadline ->
          {:halt, :timeout}

        true ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
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

  # Fake vibe: `symphony status` returns completed WITH a pr_url, simulating a
  # run that finished (and opened a PR) on the node while the stream went silent.
  defp vibe_status_completed_with_pr! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$SUBCOMMAND-$ACTION" in
      symphony-status)
        echo '{"run_id":"run_test_stall","status":"completed","pr_url":"https://github.com/org/repo/pull/7"}'
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

  # Fake vibe: `symphony status` returns failed with an error message.
  defp vibe_status_failed! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$SUBCOMMAND-$ACTION" in
      symphony-status)
        echo '{"run_id":"run_test_stall","status":"failed","error":"agent crashed: out of memory"}'
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

  describe "vibe stall + status: completed with a PR" do
    test "reconciles as success with a PR-ready comment, not a stall" do
      pid = start_orchestrator_with_stall(vibe_status_completed_with_pr!())
      issue_id = "issue-stall-completed-pr-#{System.unique_integer([:positive])}"
      worker_pid = inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "PR ready for review"
      assert comment =~ "https://github.com/org/repo/pull/7"
      refute comment =~ "stalled"
      refute comment =~ "stream events were not received"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    end
  end

  describe "vibe stall + status: failed" do
    test "reconciles as failure carrying the node-reported reason" do
      pid = start_orchestrator_with_stall(vibe_status_failed!())
      issue_id = "issue-stall-failed-#{System.unique_integer([:positive])}"
      worker_pid = inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "Vibe run failed before completion"
      assert comment =~ "agent crashed: out of memory"
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

  describe "vibe stall + status query inconclusive" do
    test "status query error → explicit diagnostic, moves to Human Review, does not crash" do
      pid = start_orchestrator_with_stall(vibe_status_failure!())
      issue_id = "issue-stall-failure-#{System.unique_integer([:positive])}"
      worker_pid = inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "watchdog fired"
      assert comment =~ "could not be confirmed"
      assert comment =~ "Human Review"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)

      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    end

    test "stall with no vibe_run_id reports inconclusive without querying status" do
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
      assert comment =~ "watchdog fired"
      assert comment =~ "no Vibe run_id was recorded"
      assert comment =~ "Human Review"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)
      refute Process.alive?(worker_pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
    end
  end

  describe "no secrets in reconciliation output" do
    test "configured relay token never appears in the posted comment (failure path)" do
      sentinel = "SENTINEL_RELAY_TOKEN_#{System.unique_integer([:positive])}"

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens",
        external_command: vibe_status_failed!(),
        external_relay: "ws://127.0.0.1:65535/relay",
        external_token: sentinel,
        codex_stall_timeout_ms: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :"SecretsOrchestrator#{System.unique_integer([:positive])}")
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      issue_id = "issue-stall-no-secrets-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      # The node-reported failure reason is surfaced, but the relay token (passed
      # only in argv) must never leak into the Linear comment.
      assert comment =~ "Vibe run failed before completion"
      refute comment =~ sentinel
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

  describe "vibe stall + status: relay/token resolved from the issue's node binding (JOZ-37 staleness regression)" do
    # Regression test for the confirmed JOZ-37 root cause: `query_vibe_run_status`
    # and `maybe_stop_vibe_run` used to read `config.external.relay`/`token`
    # directly. Those fields are normally unset in production (relay/token live
    # per-node under `binding.nodes.<name>` in WORKFLOW.md, resolved via
    # `Binding.resolve/2` -- the same source the original dispatch used). With
    # relay/token nil, ExternalExecutor silently dropped `--relay`/`--token` and
    # queried/stopped the run in LOCAL mode on the Symphony host, reading a
    # stale local run-record stub (created at dispatch, never updated by the
    # silent stream) instead of asking the real owning node -- producing a
    # false "node still reports running" stall minutes after the node had
    # actually completed. Fixed by resolving relay/token from the issue's node
    # binding (`resolve_vibe_relay_token/1`) before querying/stopping.

    # Fake vibe whose `symphony status` answer depends on whether `--relay` is
    # actually present in argv: WITHOUT it (the bug), returns "running" (the
    # stale local-mode answer); WITH it (the fix), returns "completed" (the
    # real node's authoritative answer).
    defp vibe_status_relay_aware! do
      write_fake_vibe!(~s"""
      SUBCOMMAND="$1"
      ACTION="$2"
      HAS_RELAY=""
      for arg in "$@"; do
        if [ "$arg" = "--relay" ]; then HAS_RELAY="1"; fi
      done
      case "$SUBCOMMAND-$ACTION" in
        symphony-status)
          if [ -n "$HAS_RELAY" ]; then
            echo '{"run_id":"run_test_stall","status":"completed"}'
          else
            echo '{"run_id":"run_test_stall","status":"running"}'
          fi
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

    # Fake vibe: `symphony status` always reports a genuine stall ("running"),
    # regardless of args. `symphony stop` records to `marker_path` whether it
    # was invoked with `--relay`, so the {:running, _} branch's
    # `maybe_stop_vibe_run` call can be verified independently of the status
    # query.
    defp vibe_status_running_records_stop_relay!(marker_path) do
      write_fake_vibe!(~s"""
      SUBCOMMAND="$1"
      ACTION="$2"
      case "$SUBCOMMAND-$ACTION" in
        symphony-status)
          echo '{"run_id":"run_test_stall","status":"running"}'
          ;;
        symphony-stop)
          for arg in "$@"; do
            if [ "$arg" = "--relay" ]; then echo "relay" >> #{marker_path}; fi
          done
          echo '{"status":"stopped"}'
          ;;
        *)
          exit 1
          ;;
      esac
      """)
    end

    # Mirrors production: `external:` only sets `command` (no relay/token), and
    # the issue's node binding (`binding.nodes.test-node`) carries the real
    # relay/token via `binding.defaults.node`/`binding.defaults.repo`/
    # `binding.defaults.agent` (no issue labels needed).
    defp start_orchestrator_with_stall_and_node_binding(fake_vibe_path) do
      binding_yaml = ~s"""
      binding:
        agents:
          mock:
            permission_mode: "default"
        defaults:
          repo: "https://github.com/JozzyAI/spendlens"
          node: "test-node"
          agent: "mock"
        nodes:
          test-node:
            node_id: "node_test123"
            relay: "ws://fake-relay-for-test.invalid"
            token: "node-binding-token-xyz"
      """

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        external_command: fake_vibe_path,
        binding: binding_yaml,
        codex_stall_timeout_ms: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :"BindingOrchestrator#{System.unique_integer([:positive])}")
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
      pid
    end

    test "node-binding relay (not config.external) is used: reconciles as completed, not a stale stall" do
      pid = start_orchestrator_with_stall_and_node_binding(vibe_status_relay_aware!())
      issue_id = "issue-stall-binding-relay-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      # {:completed, no pr_url} wording proves the query saw "completed", not
      # the {:running, _} "stalled ... still reports running" wording the bug
      # produced when relay/token were silently dropped.
      assert comment =~ "stream events were not received"
      refute comment =~ "stalled"
      refute comment =~ "still reports the run as running"

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    end

    test "genuine stall: stop_run is invoked with the node-binding relay, not silently local" do
      marker = Path.join(System.tmp_dir!(), "vibe-stop-relay-marker-#{System.unique_integer([:positive])}")
      pid = start_orchestrator_with_stall_and_node_binding(vibe_status_running_records_stop_relay!(marker))
      issue_id = "issue-stall-binding-stop-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "still reports the run as running"

      wait_for_file_content(marker, "relay", 1_000)
      assert File.exists?(marker)
      assert File.read!(marker) =~ "relay"
    end

    test "node binding token is never leaked into the posted comment" do
      pid = start_orchestrator_with_stall_and_node_binding(vibe_status_relay_aware!())
      issue_id = "issue-stall-binding-secrets-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      refute comment =~ "node-binding-token-xyz"
    end
  end

  describe "orphan stream cleanup diagnostics" do
    # `inject_stalled_running_entry/3` never sets `vibe_stream_os_pid` on the
    # running entry (mirroring the live JOZ-37 incident, where the stream PID
    # was apparently never captured either -- the orphaned Mac `vibe symphony
    # stream` process, PID 98413, was never reaped after reconciliation, and no
    # kill attempt was logged). `maybe_kill_vibe_stream/2`'s nil-pid clause used
    # to no-op silently; it now logs a warning so a future occurrence is
    # diagnosable instead of indistinguishable from "nothing to clean up".
    test "missing stream os_pid logs a diagnosable warning instead of silently no-op'ing" do
      pid = start_orchestrator_with_stall(vibe_status_completed!())
      issue_id = "issue-stall-orphan-diag-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :tick)
          assert_receive {:memory_tracker_comment, ^issue_id, _comment}, 2_000
        end)

      assert log =~ "no stream os_pid to clean up"
      assert log =~ "run_test_stall"
    end
  end
end
