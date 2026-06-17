defmodule SymphonyElixir.VibeStreamCleanupTest do
  @moduledoc """
  Tests for the Vibe stream OS process cleanup added alongside the
  silent-stream stall fallback (PR #24 / fix/cleanup-vibe-stream-processes).

  When a `vibe symphony stream` process is orphaned because relay events were
  missed and the stall timeout fires, Symphony now:
    1. Captures the OS PID of the stream Port process in ExternalExecutor right
       after Port.open via Port.info(port, :os_pid).
    2. Sends a :vibe_stream_started codex worker update so the Orchestrator can
       store the PID in the running entry.
    3. On stall terminal handling, calls kill_stream_process/2 with the stored
       PID and run_id: sends SIGTERM after verifying /proc/<pid>/cmdline
       contains both "stream" and the run_id, then escalates to SIGKILL in a
       background process after 2 seconds if the process is still alive.
    4. Does not kill any process whose cmdline does not match the expected
       run_id (no broad pkill-style kill).
    5. Leaves the happy path (pr_created + completed stream events), the
       PlannerRunner, AppServer, and duplicate-dispatch guards unchanged.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ExternalExecutor
  alias SymphonyElixir.Orchestrator

  # ── OS-process helpers ─────────────────────────────────────────────────────

  # Spawns a long-lived shell script as a Port whose /proc/<pid>/cmdline
  # includes "stream" and run_id as separate null-terminated argv entries.
  # Blocks on stdin so default SIGTERM terminates it immediately.
  # Waits for fork→exec to complete before returning so callers see the
  # correct cmdline right away (needed on WSL2 where exec is slower).
  defp spawn_fake_stream_process(run_id) do
    script_path =
      Path.join(System.tmp_dir!(), "fake-stream-#{System.unique_integer([:positive])}.sh")

    File.write!(script_path, "#!/bin/sh\nread -r _\n")
    File.chmod!(script_path, 0o755)
    on_exit(fn -> File.rm(script_path) end)

    port =
      Port.open({:spawn_executable, script_path}, [
        :binary,
        :exit_status,
        args: ["stream", run_id, "--jsonl"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    wait_for_exec(os_pid, run_id)
    {port, os_pid}
  end

  # Polls /proc/<pid>/cmdline until fork→exec has completed and the expected
  # args appear. On WSL2 the fork helper is visible in cmdline before exec.
  defp wait_for_exec(os_pid, run_id, attempts \\ 50) do
    case File.read("/proc/#{os_pid}/cmdline") do
      {:ok, contents} ->
        args = String.split(contents, <<0>>, trim: true)

        if Enum.any?(args, &(&1 == "stream")) and Enum.any?(args, &(&1 == run_id)) do
          :ok
        else
          if attempts > 0 do
            :timer.sleep(20)
            wait_for_exec(os_pid, run_id, attempts - 1)
          else
            raise "Timed out waiting for exec: os_pid=#{os_pid} cmdline=#{inspect(args)}"
          end
        end

      {:error, _} ->
        if attempts > 0 do
          :timer.sleep(20)
          wait_for_exec(os_pid, run_id, attempts - 1)
        else
          raise "Timed out waiting for /proc/#{os_pid}/cmdline to appear"
        end
    end
  end

  defp close_port_safely(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp os_process_alive?(os_pid), do: File.exists?("/proc/#{os_pid}")

  # ── Fake vibe script helpers ───────────────────────────────────────────────

  defp write_fake_vibe!(script_body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fake-vibe-cleanup-#{System.unique_integer([:positive])}"
      )

    File.write!(path, "#!/usr/bin/env bash\n" <> script_body)
    File.chmod!(path, 0o755)
    path
  end

  defp vibe_status_completed! do
    write_fake_vibe!(~s"""
    case "$1-$2" in
      symphony-status)
        echo '{"run_id":"run_test","status":"completed"}'
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

  defp vibe_status_running! do
    write_fake_vibe!(~s"""
    case "$1-$2" in
      symphony-status)
        echo '{"run_id":"run_test","status":"running"}'
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

  defp vibe_pr_completed! do
    write_fake_vibe!(~s"""
    case "$2" in
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

  # ── Orchestrator setup helpers ─────────────────────────────────────────────

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

    orchestrator_name =
      Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp inject_stalled_entry(orchestrator_pid, issue_id, vibe_run_id, vibe_stream_os_pid) do
    worker_pid = spawn(fn -> receive do: (:done -> :ok) end)
    stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(orchestrator_pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "JOZ-test",
      vibe_run_id: vibe_run_id,
      vibe_stream_os_pid: vibe_stream_os_pid,
      issue: %Issue{id: issue_id, identifier: "JOZ-test", state: "In Progress"},
      last_codex_timestamp: stale_at,
      started_at: stale_at
    }

    :sys.replace_state(orchestrator_pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    worker_pid
  end

  # ── 1. ExternalExecutor emits :vibe_stream_started ────────────────────────

  describe "ExternalExecutor emits :vibe_stream_started with stream OS pid" do
    test "on_message receives :vibe_stream_started containing an integer stream_os_pid" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-cleanup-executor-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      parent = self()

      on_message = fn msg ->
        send(parent, {:collected, msg})
        :ok
      end

      issue = %Issue{
        id: "issue-stream-pid",
        identifier: "JOZ-SP",
        title: "stream pid test",
        state: "In Progress",
        url: "https://linear.app/test"
      }

      fake_vibe = vibe_pr_completed!()

      task =
        Task.async(fn ->
          ExternalExecutor.run(issue, "do the thing", workspace_root,
            command: fake_vibe,
            agent: "mock",
            on_message: on_message
          )
        end)

      messages =
        Enum.reduce_while(1..20, [], fn _, acc ->
          receive do
            {:collected, msg} ->
              updated = [msg | acc]
              if Enum.any?(updated, &(&1.event == :vibe_stream_started)) do
                {:halt, updated}
              else
                {:cont, updated}
              end
          after
            500 -> {:halt, acc}
          end
        end)

      Task.await(task, 5_000)

      stream_started = Enum.find(messages, &(&1.event == :vibe_stream_started))
      assert stream_started, "expected :vibe_stream_started event in on_message calls"
      assert is_integer(stream_started.stream_os_pid),
             "stream_os_pid must be an integer OS PID, got: #{inspect(stream_started.stream_os_pid)}"

      assert is_binary(stream_started.run_id), "run_id must be present"
    end
  end

  # ── 2. Orchestrator stores vibe_stream_os_pid ─────────────────────────────

  describe "Orchestrator stores vibe_stream_os_pid from :vibe_stream_started update" do
    test "codex_worker_update with :vibe_stream_started stores stream_os_pid in running entry" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name =
        Module.concat(__MODULE__, :"StoreOrchestrator#{System.unique_integer([:positive])}")

      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      issue_id = "issue-store-#{System.unique_integer([:positive])}"
      worker_pid = spawn(fn -> receive do: (:done -> :ok) end)
      initial_state = :sys.get_state(pid)

      # Minimal running entry — session_id required by integrate_codex_update;
      # all token/turn fields default to 0 via Map.get/3.
      running_entry = %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: "JOZ-test",
        session_id: nil,
        vibe_run_id: "run_store_test",
        issue: %Issue{id: issue_id, identifier: "JOZ-test", state: "In Progress"},
        started_at: DateTime.utc_now(),
        last_codex_timestamp: DateTime.utc_now(),
        last_codex_event: nil,
        last_codex_message: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        turn_count: 0
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      end)

      # Register the issue so the orchestrator poll cycle does not reconcile
      # it away (fetch_issue_states_by_ids returns [] otherwise → terminate).
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: issue_id, identifier: "JOZ-test", state: "In Progress"}
      ])

      send(pid, {
        :codex_worker_update,
        issue_id,
        %{
          event: :vibe_stream_started,
          run_id: "run_store_test",
          stream_os_pid: 42_424_242,
          timestamp: DateTime.utc_now()
        }
      })

      :timer.sleep(100)

      state = :sys.get_state(pid)
      entry = Map.get(state.running, issue_id)
      assert entry, "running entry should still exist after :vibe_stream_started update"
      assert Map.get(entry, :vibe_stream_os_pid) == 42_424_242
    end
  end

  # ── 3 & 4. Stall kills the matching stream process ────────────────────────

  describe "Vibe stall terminates the orphan stream OS process" do
    test "stall + completed status: kills stream process with matching cmdline" do
      run_id = "run_stall_done_#{System.unique_integer([:positive])}"
      {port, stream_os_pid} = spawn_fake_stream_process(run_id)
      on_exit(fn -> close_port_safely(port) end)

      assert os_process_alive?(stream_os_pid)

      pid = start_orchestrator_with_stall(vibe_status_completed!())
      issue_id = "issue-cleanup-done-#{System.unique_integer([:positive])}"
      inject_stalled_entry(pid, issue_id, run_id, stream_os_pid)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "Human Review"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      :timer.sleep(300)
      refute os_process_alive?(stream_os_pid),
             "stream OS process should be killed after stall cleanup"
    end

    test "stall + running/unknown status: also kills the stream process" do
      run_id = "run_stall_running_#{System.unique_integer([:positive])}"
      {port, stream_os_pid} = spawn_fake_stream_process(run_id)
      on_exit(fn -> close_port_safely(port) end)

      assert os_process_alive?(stream_os_pid)

      pid = start_orchestrator_with_stall(vibe_status_running!())
      issue_id = "issue-cleanup-running-#{System.unique_integer([:positive])}"
      inject_stalled_entry(pid, issue_id, run_id, stream_os_pid)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, comment}, 2_000
      assert comment =~ "stalled"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      :timer.sleep(300)
      refute os_process_alive?(stream_os_pid),
             "stream OS process should be killed after stall cleanup"
    end

    test "stall with no vibe_stream_os_pid does not crash and still moves to Human Review" do
      pid = start_orchestrator_with_stall(vibe_status_completed!())
      issue_id = "issue-no-stream-pid-#{System.unique_integer([:positive])}"

      worker_pid = spawn(fn -> receive do: (:done -> :ok) end)
      stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: "JOZ-test",
        vibe_run_id: "run_no_pid",
        issue: %Issue{id: issue_id, identifier: "JOZ-test", state: "In Progress"},
        last_codex_timestamp: stale_at,
        started_at: stale_at
        # vibe_stream_os_pid deliberately absent
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      end)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, ^issue_id, _comment}, 2_000
      assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}

      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
    end
  end

  # ── 5. Cleanup uses captured pid+run_id, not broad matching ───────────────

  describe "kill_stream_process uses the captured pid and run_id exactly" do
    test "does not kill a process with a different run_id even when both are alive" do
      run_id_a = "run_keep_#{System.unique_integer([:positive])}"
      run_id_b = "run_kill_#{System.unique_integer([:positive])}"

      {port_a, os_pid_a} = spawn_fake_stream_process(run_id_a)
      {port_b, os_pid_b} = spawn_fake_stream_process(run_id_b)

      on_exit(fn ->
        close_port_safely(port_a)
        close_port_safely(port_b)
      end)

      assert os_process_alive?(os_pid_a)
      assert os_process_alive?(os_pid_b)

      kill_log =
        capture_log(fn ->
          assert ExternalExecutor.kill_stream_process(os_pid_b, run_id_b) == :ok
        end)

      assert kill_log =~ "SIGTERM", "expected SIGTERM log — kill was skipped: #{inspect(kill_log)}"

      :timer.sleep(500)
      assert os_process_alive?(os_pid_a),
             "process for a different run_id must not be killed"
      refute os_process_alive?(os_pid_b), "target process should be killed"
    end
  end

  # ── 6. Verification failure: skipped safely, warning logged ───────────────

  describe "kill_stream_process handles PID verification failure safely" do
    test "logs a warning and returns :ok when cmdline does not match run_id" do
      {port, os_pid} = spawn_fake_stream_process("run_real_id_#{System.unique_integer([:positive])}")
      on_exit(fn -> close_port_safely(port) end)

      assert os_process_alive?(os_pid)

      log =
        capture_log(fn ->
          assert ExternalExecutor.kill_stream_process(os_pid, "run_wrong_id_99") == :ok
        end)

      assert log =~ "cmdline does not match", "expected warning about cmdline mismatch"

      :timer.sleep(100)
      assert os_process_alive?(os_pid),
             "process should still be alive when cmdline does not match"
    end

    test "returns :ok safely for a non-existent OS PID without crashing" do
      assert ExternalExecutor.kill_stream_process(99_999_999, "run_nonexistent") == :ok
    end

    test "returns :ok for non-integer os_pid or nil run_id without crashing" do
      assert ExternalExecutor.kill_stream_process(nil, "run_1") == :ok
      assert ExternalExecutor.kill_stream_process(1_234, nil) == :ok
      assert ExternalExecutor.kill_stream_process("not-an-int", "run_1") == :ok
    end
  end

  # ── 7. Happy path unaffected ──────────────────────────────────────────────

  describe "happy path: pr_created + completed events received normally" do
    test "finishes with PR comment; no stall comment; no manual kill needed" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-cleanup-happy-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "vibe",
        tracker_kind: "memory",
        repo_url: "https://github.com/JozzyAI/spendlens",
        external_command: vibe_pr_completed!(),
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 30_000
      )

      issue = %Issue{
        id: "issue-cleanup-happy",
        identifier: "JOZ-CH",
        title: "Happy cleanup test",
        state: "Todo",
        url: "https://linear.app/test/issue/JOZ-CH"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name =
        Module.concat(__MODULE__, :"HappyOrchestrator#{System.unique_integer([:positive])}")

      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      send(pid, :tick)

      assert_receive {:memory_tracker_comment, "issue-cleanup-happy", comment}, 5_000
      assert comment =~ "PR ready"
      assert comment =~ "https://github.com/org/repo/pull/99"
      refute comment =~ "stalled"
      refute comment =~ "stream events were not received"
    end
  end

  # ── 8. PlannerRunner unaffected ───────────────────────────────────────────

  describe "PlannerRunner dispatch is unaffected" do
    test "codex agent_kind orchestrator starts cleanly without vibe_stream_os_pid concerns" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        agent_kind: "codex"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name =
        Module.concat(__MODULE__, :"CodexOrchestrator#{System.unique_integer([:positive])}")

      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      send(pid, :tick)
      :timer.sleep(50)

      state = :sys.get_state(pid)
      assert is_map(state.running), "orchestrator state is intact"
      # No vibe stream pid at the orchestrator level — only in per-issue running entries
      refute Map.has_key?(state, :vibe_stream_os_pid)
    end
  end
end
