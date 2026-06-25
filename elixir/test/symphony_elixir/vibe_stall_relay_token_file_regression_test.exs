defmodule SymphonyElixir.VibeStallRelayTokenFileRegressionTest do
  @moduledoc """
  Combined regression test for PR #31 (orchestrator resolves vibe relay/token
  from the issue's node binding, not `config.external`) and PR #32
  (ExternalExecutor forwards the token via `--token-file`, never literal
  `--token <value>`).

  Each PR has its own dedicated coverage (`vibe_stall_status_test.exs` for
  #31's Binding-resolution path, `external_executor_test.exs` for #32's
  argv-hygiene path) but neither exercises both together: #31's tests only
  check for `--relay` presence in argv, and #32's tests call
  `ExternalExecutor.query_run_status/4` directly with an already-resolved
  token, bypassing `Orchestrator.resolve_vibe_relay_token/1`/`Binding.resolve`
  entirely. This test drives the real `:tick` -> stall-reconciliation path so
  a future regression in either fix (e.g. binding resolution starts feeding
  the token back to `config.external`'s old literal-`--token` call site)
  would be caught here even if it slipped past either PR's own tests.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator

  @node_token "node-binding-token-pr31pr32-regression"

  defp write_fake_vibe!(script_body) do
    path = Path.join(System.tmp_dir!(), "fake-vibe-pr3132-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/usr/bin/env bash\n" <> script_body)
    File.chmod!(path, 0o755)
    path
  end

  # `symphony status` records its full argv (and, if present, the
  # `--token-file` path + content at invocation time -- the only point the
  # file can be observed, since ExternalExecutor shreds+deletes it right
  # after the call returns) before answering "completed".
  defp vibe_status_completed_recording_argv!(marker_path) do
    write_fake_vibe!(~s"""
    SUBCOMMAND="$1"
    ACTION="$2"
    if [ "$SUBCOMMAND-$ACTION" = "symphony-status" ]; then
      {
        for a in "$@"; do echo "ARG $a"; done
        PREV=""
        for a in "$@"; do
          if [ "$PREV" = "--token-file" ]; then
            echo "TOKENFILE_PATH $a"
            echo "TOKENFILE_CONTENT $(cat "$a" 2>/dev/null)"
          fi
          PREV="$a"
        done
      } >> #{marker_path}
    fi
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

  defp parse_marker(marker_path) do
    lines = marker_path |> File.read!() |> String.split("\n", trim: true)
    args = lines |> Enum.filter(&String.starts_with?(&1, "ARG ")) |> Enum.map(&String.replace_prefix(&1, "ARG ", ""))
    token_file_path = lines |> Enum.find(&String.starts_with?(&1, "TOKENFILE_PATH ")) |> then(&(&1 && String.replace_prefix(&1, "TOKENFILE_PATH ", "")))
    token_file_content = lines |> Enum.find(&String.starts_with?(&1, "TOKENFILE_CONTENT ")) |> then(&(&1 && String.replace_prefix(&1, "TOKENFILE_CONTENT ", "")))
    %{args: args, token_file_path: token_file_path, token_file_content: token_file_content}
  end

  # Mirrors production: `external:` sets no relay/token (nil, as in the real
  # deployment); the issue's node binding carries the real relay/token.
  defp start_orchestrator_with_node_binding(fake_vibe_path) do
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
          token: "#{@node_token}"
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

    orchestrator_name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
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

  describe "PR #31 + PR #32 together: node-binding token reaches vibe via --token-file" do
    test "status query uses the binding-resolved token via --token-file (never literal --token), and completed is reconciled correctly" do
      marker = Path.join(System.tmp_dir!(), "vibe-pr3132-marker-#{System.unique_integer([:positive])}")
      pid = start_orchestrator_with_node_binding(vibe_status_completed_recording_argv!(marker))
      issue_id = "issue-pr3132-regression-#{System.unique_integer([:positive])}"
      inject_stalled_running_entry(pid, issue_id, "run_test_stall")

      send(pid, :tick)

      # Proves the *result* of the binding-resolved relay/token query was
      # parsed as completed (PR #31's fix + status decoding): the
      # "stream events were not received" wording only appears on the
      # {:completed, _} branch, never on the {:running, _}/{:unknown, _}
      # branches that the pre-#31 bug (silently local, stale stub) produced.
      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "stream events were not received"
      refute comment =~ "stalled"
      refute comment =~ @node_token

      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      parsed = parse_marker(marker)

      # PR #32: token-file, never literal --token; the real binding token
      # (not config.external, which is unset) was what got written to it.
      refute "--token" in parsed.args
      assert "--token-file" in parsed.args
      refute Enum.any?(parsed.args, &(&1 == @node_token))
      assert parsed.token_file_content == @node_token

      # The file is shredded+deleted right after the call returns -- by the
      # time this test observes it, nothing should remain on disk.
      assert parsed.token_file_path
      refute File.exists?(parsed.token_file_path)
    end
  end
end
