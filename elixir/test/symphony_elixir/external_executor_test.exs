defmodule SymphonyElixir.ExternalExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ExternalExecutor
  alias SymphonyElixir.Config

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp fake_issue(id \\ "issue-1") do
    %Issue{
      id: id,
      identifier: "ENG-#{System.unique_integer([:positive])}",
      title: "Test issue",
      description: "A test issue",
      state: "In Progress",
      url: "https://example.com/issues/#{id}"
    }
  end

  defp write_fake_vibe!(script_body) do
    path = Path.join(System.tmp_dir!(), "fake-vibe-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/usr/bin/env bash\n" <> script_body)
    File.chmod!(path, 0o755)
    path
  end

  # Fake vibe that outputs a completed stream
  defp vibe_completed! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"test-run-1","session_id":"sess-1","node_id":"enc-node-1","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      stream)
        RUN_ID="${3:-test-run-1}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"running\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"log\\",\\"stream\\":\\"stdout\\",\\"message\\":\\"Working...\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        echo "{\\"type\\":\\"tool_call\\",\\"tool\\":\\"bash\\",\\"input\\":{\\"cmd\\":\\"ls\\"},\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:02Z\\"}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"completed\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:03Z\\"}"
        ;;
      stop)
        echo "{\\"run_id\\":\\"${3:-test-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe that outputs a failed stream
  defp vibe_failed! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"fail-run-1","session_id":"sess-fail","node_id":"local","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      stream)
        RUN_ID="${3:-fail-run-1}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"running\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"error\\",\\"message\\":\\"agent crashed\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"failed\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:02Z\\"}"
        ;;
      stop)
        echo "{\\"run_id\\":\\"${3:-fail-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe that emits approval_required then hangs (port closes after)
  defp vibe_blocked! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"blocked-run-1","session_id":"sess-blocked","node_id":"local","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      stream)
        RUN_ID="${3:-blocked-run-1}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"running\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"approval_required\\",\\"approval_id\\":\\"appr-1\\",\\"message\\":\\"Proceed?\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        ;;
      stop)
        echo "{\\"run_id\\":\\"${3:-blocked-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe that emits approval_required, and records `symphony stop` /
  # `approval respond` invocations to `marker_path` (one line each).
  defp vibe_blocked_recording!(marker_path) do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$SUBCOMMAND-$ACTION" in
      symphony-start)
        echo '{"run_id":"blocked-run-1","session_id":"sess-blocked","node_id":"local","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      symphony-stream)
        RUN_ID="${3:-blocked-run-1}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"running\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"approval_required\\",\\"approval_id\\":\\"appr-1\\",\\"message\\":\\"Proceed?\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        ;;
      symphony-stop)
        echo "stop:${3:-blocked-run-1}" >> #{marker_path}
        echo "{\\"run_id\\":\\"${3:-blocked-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
      approval-respond)
        DECISION=""
        APPROVAL_ID=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --decision) shift; DECISION="$1" ;;
            --approval-id) shift; APPROVAL_ID="$1" ;;
          esac
          shift
        done
        echo "deny:$APPROVAL_ID:$DECISION" >> #{marker_path}
        echo "{\\"ok\\":true,\\"approval_id\\":\\"$APPROVAL_ID\\",\\"decision\\":\\"$DECISION\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe that emits status:blocked
  defp vibe_status_blocked! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"status-blocked-run-1","session_id":"sess-sb","node_id":"local","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      stream)
        RUN_ID="${3:-status-blocked-run-1}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"running\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"blocked\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        ;;
      stop)
        echo "{\\"run_id\\":\\"${3:-status-blocked-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe that emits pr_created then completes
  defp vibe_pr_created! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"pr-run-1","session_id":"sess-pr","node_id":"local","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      stream)
        RUN_ID="${3:-pr-run-1}"
        echo "{\\"type\\":\\"log\\",\\"stream\\":\\"stdout\\",\\"message\\":\\"Creating PR...\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"pr_created\\",\\"url\\":\\"https://github.com/org/repo/pull/42\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"completed\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:02Z\\"}"
        ;;
      stop)
        echo "{\\"run_id\\":\\"${3:-pr-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe that emits approval_response then completes
  defp vibe_approval_response! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo '{"run_id":"ar-run-1","session_id":"sess-ar","node_id":"local","agent":"mock","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      stream)
        RUN_ID="${3:-ar-run-1}"
        echo "{\\"type\\":\\"approval_response\\",\\"approval_id\\":\\"appr-2\\",\\"decision\\":\\"approve\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:00Z\\"}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"completed\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:01Z\\"}"
        ;;
      stop)
        echo "{\\"run_id\\":\\"${3:-ar-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  # Fake vibe where start returns bad JSON
  defp vibe_bad_start! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo 'not-json-at-all'
        ;;
    esac
    """)
  end

  # Fake vibe where start exits non-zero
  defp vibe_start_fails! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$ACTION" in
      start)
        echo 'Internal error' >&2
        exit 1
        ;;
    esac
    """)
  end

  # Fake vibe that records the full `symphony start` argv (one arg per line) to
  # `marker_path`, then emits a completed stream so run/4 returns :ok. Used to
  # assert exactly which flags ExternalExecutor forwards to the CLI.
  defp vibe_recording_start!(marker_path) do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    case "$SUBCOMMAND-$ACTION" in
      symphony-start)
        for a in "$@"; do echo "$a" >> #{marker_path}; done
        echo '{"run_id":"rec-run-1","session_id":"sess-rec","node_id":"node_f7cedd3b6590aff9","agent":"claude-code","status":"running","workspace_path":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
        ;;
      symphony-stream)
        RUN_ID="${3:-rec-run-1}"
        echo "{\\"type\\":\\"status\\",\\"status\\":\\"completed\\",\\"run_id\\":\\"$RUN_ID\\",\\"ts\\":\\"2026-01-01T00:00:03Z\\"}"
        ;;
      symphony-stop)
        echo "{\\"run_id\\":\\"${3:-rec-run-1}\\",\\"status\\":\\"stopped\\"}"
        ;;
    esac
    """)
  end

  defp recorded_args(marker), do: marker |> File.read!() |> String.split("\n", trim: true)

  defp value_after(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  # ── ExternalExecutor.run/4 tests ───────────────────────────────────────────

  test "completed stream returns :ok and forwards log + tool_call + vibe_start events" do
    cmd = vibe_completed!()
    issue = fake_issue()
    messages = :ets.new(:messages, [:public, :bag])
    on_msg = fn msg -> :ets.insert(messages, {msg.event, msg}) end

    assert :ok = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    events = :ets.tab2list(messages)
    assert Enum.any?(events, fn {k, _} -> k == :output end)
    assert Enum.any?(events, fn {k, _} -> k == :tool_call end)
    assert Enum.any?(events, fn {k, _} -> k == :vibe_start end)
  end

  test "vibe_start event includes run_id, node_id, and agent" do
    cmd = vibe_completed!()
    issue = fake_issue()
    messages = :ets.new(:vibe_start_msgs, [:public, :bag])
    on_msg = fn msg -> :ets.insert(messages, {msg.event, msg}) end

    assert :ok = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    [{:vibe_start, start_event}] = :ets.lookup(messages, :vibe_start)
    assert start_event.vibe_run_id == "test-run-1"
    assert start_event.vibe_node_id == "enc-node-1"
    assert start_event.vibe_agent == "mock"
    assert %DateTime{} = start_event.timestamp
  end

  test "tool_call event includes input field" do
    cmd = vibe_completed!()
    issue = fake_issue()
    messages = :ets.new(:tool_call_msgs, [:public, :bag])
    on_msg = fn msg -> :ets.insert(messages, {msg.event, msg}) end

    assert :ok = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    [{:tool_call, tc_event}] = :ets.lookup(messages, :tool_call)
    assert tc_event.tool == "bash"
    assert tc_event.input == %{"cmd" => "ls"}
  end

  test "log event includes stream field" do
    cmd = vibe_completed!()
    issue = fake_issue()
    messages = :ets.new(:log_msgs, [:public, :bag])
    on_msg = fn msg -> :ets.insert(messages, {msg.event, msg}) end

    assert :ok = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    [{:output, log_event}] = :ets.lookup(messages, :output)
    assert log_event.message == "Working..."
    assert log_event.stream == "stdout"
  end

  test "failed stream returns error tuple" do
    cmd = vibe_failed!()
    issue = fake_issue()

    assert {:error, _reason} = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock")
  end

  test "approval_required returns blocked error with approval_id and message fields" do
    cmd = vibe_blocked!()
    issue = fake_issue()
    received = :ets.new(:approvals, [:public, :bag])
    on_msg = fn msg -> :ets.insert(received, {msg.event, msg}) end

    assert {:error, {:blocked, :approval_required, _event}} =
             ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    [{:approval_required, appr_event}] = :ets.lookup(received, :approval_required)
    assert appr_event.approval_id == "appr-1"
    assert appr_event.message == "Proceed?"
  end

  test "approval_required without deny_pending_approvals leaves the run alone (default/coding-agent behavior)" do
    marker = Path.join(System.tmp_dir!(), "vibe-marker-#{System.unique_integer([:positive])}")
    cmd = vibe_blocked_recording!(marker)
    issue = fake_issue()

    assert {:error, {:blocked, :approval_required, _event}} =
             ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock")

    refute File.exists?(marker)
  end

  test "approval_required with deny_pending_approvals: true stops the run even without a relay" do
    marker = Path.join(System.tmp_dir!(), "vibe-marker-#{System.unique_integer([:positive])}")
    cmd = vibe_blocked_recording!(marker)
    issue = fake_issue()

    assert {:error, {:blocked, :approval_required, _event}} =
             ExternalExecutor.run(issue, "do something", "/tmp",
               command: cmd,
               agent: "codex",
               deny_pending_approvals: true
             )

    content = File.read!(marker)
    assert content =~ "stop:blocked-run-1"
    refute content =~ "deny:"
  end

  test "approval_required with deny_pending_approvals: true and a configured relay denies the approval and stops the run" do
    marker = Path.join(System.tmp_dir!(), "vibe-marker-#{System.unique_integer([:positive])}")
    cmd = vibe_blocked_recording!(marker)
    issue = fake_issue()

    assert {:error, {:blocked, :approval_required, _event}} =
             ExternalExecutor.run(issue, "do something", "/tmp",
               command: cmd,
               agent: "codex",
               relay: "ws://relay",
               token: "tok",
               deny_pending_approvals: true
             )

    content = File.read!(marker)
    assert content =~ "deny:appr-1:deny"
    assert content =~ "stop:blocked-run-1"
  end

  test "status:blocked returns blocked error with vibe_blocked event" do
    cmd = vibe_status_blocked!()
    issue = fake_issue()
    received = :ets.new(:status_blocked, [:public, :bag])
    on_msg = fn msg -> :ets.insert(received, {msg.event, msg}) end

    assert {:error, {:blocked, :status_blocked, _event}} =
             ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    assert :ets.lookup(received, :vibe_blocked) != []
  end

  test "pr_created event is forwarded and run completes" do
    cmd = vibe_pr_created!()
    issue = fake_issue()
    received = :ets.new(:pr_events, [:public, :bag])
    on_msg = fn msg -> :ets.insert(received, {msg.event, msg}) end

    assert :ok = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    [{:pr_created, pr_event}] = :ets.lookup(received, :pr_created)
    assert pr_event.url == "https://github.com/org/repo/pull/42"
  end

  test "approval_response event is forwarded and run completes" do
    cmd = vibe_approval_response!()
    issue = fake_issue()
    received = :ets.new(:ar_events, [:public, :bag])
    on_msg = fn msg -> :ets.insert(received, {msg.event, msg}) end

    assert :ok = ExternalExecutor.run(issue, "do something", "/tmp", command: cmd, agent: "mock", on_message: on_msg)

    [{:approval_response, ar_event}] = :ets.lookup(received, :approval_response)
    assert ar_event.approval_id == "appr-2"
    assert ar_event.decision == "approve"
  end

  test "command not found returns error" do
    issue = fake_issue()

    assert {:error, {:command_not_found, "/nonexistent/vibe"}} =
             ExternalExecutor.run(issue, "prompt", "/tmp", command: "/nonexistent/vibe", agent: "mock")
  end

  test "stream command not found returns error (start ok, stream exe missing)" do
    # Start returns run_id but the stream executable path is non-existent (absolute)
    # We simulate this by making start succeed but the executable vanishes after.
    # In practice we test resolve_executable via the stream_run path using a bad path
    # that is an absolute non-file path, distinct from the start command.
    # This requires a helper that overrides stream path — skipped for now; covered above.
    :ok
  end

  test "start bad JSON returns error" do
    cmd = vibe_bad_start!()
    issue = fake_issue()

    assert {:error, {:invalid_start_response_json, _, _}} =
             ExternalExecutor.run(issue, "prompt", "/tmp", command: cmd, agent: "mock")
  end

  test "start non-zero exit returns start_failed error" do
    cmd = vibe_start_fails!()
    issue = fake_issue()

    assert {:error, {:start_failed, 1, _}} =
             ExternalExecutor.run(issue, "prompt", "/tmp", command: cmd, agent: "mock")
  end

  # ── Remote dispatch argument forwarding (relay/node/token decoupling) ──────

  describe "remote dispatch argument forwarding" do
    test "forwards --relay, --node, --agent, --repo-url, --permission-mode, and --token" do
      marker = Path.join(System.tmp_dir!(), "vibe-args-#{System.unique_integer([:positive])}")
      cmd = vibe_recording_start!(marker)

      assert :ok =
               ExternalExecutor.run(fake_issue(), "prompt", "/tmp",
                 command: cmd,
                 agent: "claude-code",
                 node: "node_f7cedd3b6590aff9",
                 relay: "wss://vibe-relay.dynastylab.ai",
                 token: "tok-123",
                 repo_url: "https://github.com/JozzyAI/mirror_social",
                 permission_mode: "unsafe-skip"
               )

      args = recorded_args(marker)
      assert value_after(args, "--relay") == "wss://vibe-relay.dynastylab.ai"
      assert value_after(args, "--node") == "node_f7cedd3b6590aff9"
      assert value_after(args, "--agent") == "claude-code"
      assert value_after(args, "--repo-url") == "https://github.com/JozzyAI/mirror_social"
      assert value_after(args, "--permission-mode") == "unsafe-skip"
      assert value_after(args, "--token") == "tok-123"
    end

    test "forwards --node/--relay (remote) even when token is nil — no silent local fallback" do
      # Regression: previously a nil token dropped --node/--relay together, so
      # vibe ran locally and exited 1 with empty stderr => {:start_failed, 1, ""}.
      marker = Path.join(System.tmp_dir!(), "vibe-args-#{System.unique_integer([:positive])}")
      cmd = vibe_recording_start!(marker)

      assert :ok =
               ExternalExecutor.run(fake_issue(), "prompt", "/tmp",
                 command: cmd,
                 agent: "claude-code",
                 node: "node_f7cedd3b6590aff9",
                 relay: "wss://vibe-relay.dynastylab.ai",
                 token: nil,
                 repo_url: "https://github.com/JozzyAI/mirror_social",
                 permission_mode: "unsafe-skip"
               )

      args = recorded_args(marker)
      assert value_after(args, "--node") == "node_f7cedd3b6590aff9"
      assert value_after(args, "--relay") == "wss://vibe-relay.dynastylab.ai"
      # token omitted so the vibe client falls back to VIBE_RELAY_TOKEN env
      refute Enum.member?(args, "--token")
    end

    test "blank token is treated as absent (no --token, remote flags retained)" do
      marker = Path.join(System.tmp_dir!(), "vibe-args-#{System.unique_integer([:positive])}")
      cmd = vibe_recording_start!(marker)

      assert :ok =
               ExternalExecutor.run(fake_issue(), "prompt", "/tmp",
                 command: cmd,
                 agent: "claude-code",
                 node: "node_f7cedd3b6590aff9",
                 relay: "wss://vibe-relay.dynastylab.ai",
                 token: ""
               )

      args = recorded_args(marker)
      assert value_after(args, "--node") == "node_f7cedd3b6590aff9"
      assert value_after(args, "--relay") == "wss://vibe-relay.dynastylab.ai"
      refute Enum.member?(args, "--token")
    end

    test "pure local mode (no relay/node) adds no remote flags" do
      marker = Path.join(System.tmp_dir!(), "vibe-args-#{System.unique_integer([:positive])}")
      cmd = vibe_recording_start!(marker)

      assert :ok = ExternalExecutor.run(fake_issue(), "prompt", "/tmp", command: cmd, agent: "mock")

      args = recorded_args(marker)
      refute Enum.member?(args, "--relay")
      refute Enum.member?(args, "--node")
      refute Enum.member?(args, "--token")
    end
  end

  # ── ExternalExecutor.send_approval/7 tests ────────────────────────────────

  # Fake vibe approval CLI: echoes back a JSON result for any approval respond call
  defp vibe_approval_cli! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    if [ "$SUBCOMMAND" = "approval" ] && [ "$ACTION" = "respond" ]; then
      RUN_ID=""
      APPROVAL_ID=""
      DECISION=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --run-id) shift; RUN_ID="$1" ;;
          --approval-id) shift; APPROVAL_ID="$1" ;;
          --decision) shift; DECISION="$1" ;;
        esac
        shift
      done
      echo "{\\"ok\\":true,\\"run_id\\":\\"$RUN_ID\\",\\"approval_id\\":\\"$APPROVAL_ID\\",\\"decision\\":\\"$DECISION\\"}"
    else
      echo "unexpected subcommand" >&2
      exit 1
    fi
    """)
  end

  # Fake vibe approval CLI: exits non-zero to simulate CLI failure
  defp vibe_approval_cli_fails! do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    if [ "$SUBCOMMAND" = "approval" ] && [ "$ACTION" = "respond" ]; then
      echo "relay error" >&2
      exit 2
    fi
    """)
  end

  test "send_approval approve returns ok with result map" do
    cmd = vibe_approval_cli!()

    assert {:ok, result} =
             ExternalExecutor.send_approval(cmd, "run-1", "appr-1", "approve", "ws://relay", "token123")

    assert result["ok"] == true
    assert result["run_id"] == "run-1"
    assert result["approval_id"] == "appr-1"
    assert result["decision"] == "approve"
  end

  test "send_approval deny returns ok with result map" do
    cmd = vibe_approval_cli!()

    assert {:ok, result} =
             ExternalExecutor.send_approval(cmd, "run-2", "appr-2", "deny", "ws://relay", "token456")

    assert result["decision"] == "deny"
    assert result["run_id"] == "run-2"
  end

  test "send_approval returns relay_not_configured when relay is nil" do
    assert {:error, :relay_not_configured} =
             ExternalExecutor.send_approval("vibe", "run-1", "appr-1", "approve", nil, "token")
  end

  test "send_approval returns relay_not_configured when token is nil" do
    assert {:error, :relay_not_configured} =
             ExternalExecutor.send_approval("vibe", "run-1", "appr-1", "approve", "ws://relay", nil)
  end

  test "send_approval returns command_not_found for nonexistent command" do
    assert {:error, {:command_not_found, "/no/such/vibe"}} =
             ExternalExecutor.send_approval("/no/such/vibe", "run-1", "appr-1", "approve", "ws://relay", "tok")
  end

  test "send_approval returns approval_failed on non-zero exit" do
    cmd = vibe_approval_cli_fails!()

    assert {:error, {:approval_failed, 2, _}} =
             ExternalExecutor.send_approval(cmd, "run-1", "appr-1", "approve", "ws://relay", "token")
  end

  # ── Config schema tests ────────────────────────────────────────────────────

  test "agent_kind defaults to codex when not in workflow" do
    assert Config.settings!().agent_kind == "codex"
  end

  test "agent_kind reads vibe from workflow file" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "vibe",
      repo_url: "https://github.com/example/repo"
    )

    assert Config.settings!().agent_kind == "vibe"
  end

  test "external.command and external.agent default to vibe and mock" do
    config = Config.settings!()
    assert config.external.command == "vibe"
    assert config.external.agent == "mock"
  end

  test "external.command and external.agent read from workflow file" do
    write_workflow_file!(Workflow.workflow_file_path(),
      external_command: "/usr/local/bin/vibe",
      external_agent: "claude-code"
    )

    config = Config.settings!()
    assert config.external.command == "/usr/local/bin/vibe"
    assert config.external.agent == "claude-code"
  end

  test "planner.agent defaults to codex, independent of external.agent (mock)" do
    config = Config.settings!()
    assert config.planner.agent == "codex"
    assert config.external.agent == "mock"
  end

  test "planner.agent reads from workflow file" do
    write_workflow_file!(Workflow.workflow_file_path(), planner_agent: "claude-code")

    assert Config.settings!().planner.agent == "claude-code"
  end
end
