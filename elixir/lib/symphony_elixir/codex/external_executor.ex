defmodule SymphonyElixir.Codex.ExternalExecutor do
  @moduledoc """
  Dispatches a run to an external CLI runtime (e.g. `vibe symphony`).

  Unlike AppServer, there is no JSON-RPC handshake. This executor:
    1. Calls `<command> symphony start` and captures the run_id.
    2. Emits a :vibe_start on_message event with run_id, node_id, and agent.
    3. Opens `<command> symphony stream <run_id> --jsonl` via a Port.
    4. Maps Vibe JSONL events to the standard on_message callback format.
    5. Returns :ok on completed, {:error, reason} on failed/stopped/blocked/crash.
    6. Calls `<command> symphony stop <run_id>` on abnormal exit to clean up.

  Codex (AppServer) remains the default path. This module is only invoked when
  the WORKFLOW.md sets `agent_kind: vibe`.

  ## Event mapping

  | Vibe event type   | on_message event atom | Notes                                       |
  |-------------------|-----------------------|---------------------------------------------|
  | status:running    | (ignored)             | Informational — run already started         |
  | log               | :output               | message, stream fields                      |
  | tool_call         | :tool_call            | tool and input fields                       |
  | approval_required | :approval_required    | approval_id, message — then returns blocked; if `deny_pending_approvals: true` was passed to `run/4`, also denies the approval (when relay/token configured) and stops the run |
  | approval_response | :approval_response    | approval_id, decision — non-blocking        |
  | pr_created        | :pr_created           | url — non-blocking                          |
  | status:blocked    | :vibe_blocked         | then returns {:error, {:blocked, ...}}      |
  | status:completed  | (no on_message)       | returns :ok                                 |
  | status:failed     | (no on_message)       | returns {:error, {:failed, event}}          |
  | status:stopped    | (no on_message)       | returns {:error, {:stopped, event}}         |
  | status:cancelled  | (no on_message)       | returns {:error, {:cancelled, event}}       |
  | error             | (no on_message)       | logs warning, returns {:error, {:run_error, event}} |
  """

  require Logger

  alias SymphonyElixir.Linear.Issue

  @port_line_bytes 65_536
  @plan_only_deny_message "Symphony Planner runs are plan-only and must not modify files; denying automatically."

  @spec run(Issue.t(), String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def run(issue, prompt, _workspace, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    command = Keyword.get(opts, :command, "vibe")
    agent = Keyword.get(opts, :agent, "mock")
    node = Keyword.get(opts, :node)
    relay = Keyword.get(opts, :relay)
    token = Keyword.get(opts, :token)
    encrypt = Keyword.get(opts, :encrypt)
    repo_url = Keyword.get(opts, :repo_url)
    permission_mode = Keyword.get(opts, :permission_mode)
    deny_pending_approvals = Keyword.get(opts, :deny_pending_approvals, false)

    prompt_file = write_temp_prompt!(prompt, issue)

    try do
      with {:ok, run_meta} <- start_run(command, agent, issue, prompt_file, node, relay, token, encrypt, repo_url, permission_mode) do
        # Announce Vibe run metadata so the orchestrator can display run_id/node/agent in the UI.
        on_message.(%{
          event: :vibe_start,
          vibe_run_id: run_meta.run_id,
          vibe_node_id: run_meta.node_id,
          vibe_agent: run_meta.agent,
          timestamp: DateTime.utc_now(),
        })

        ctx = %{command: command, relay: relay, token: token, deny_pending_approvals: deny_pending_approvals}
        stream_run(ctx, run_meta.run_id, on_message)
      end
    after
      File.rm(prompt_file)
    end
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  defp start_run(command, agent, issue, prompt_file, node, relay, token, encrypt, repo_url, permission_mode) do
    args =
      [
        "symphony", "start",
        "--agent", agent,
        "--issue-id", issue.id || "",
        "--issue-title", issue.title || "",
        "--workspace-key", issue.identifier || issue.id || "",
        "--prompt-file", prompt_file,
        "--json"
      ]
      |> append_relay_args(node, relay, token)
      |> append_encrypt(encrypt, relay)
      |> append_repo_url(repo_url)
      |> append_permission_mode(permission_mode)

    Logger.info("ExternalExecutor: #{command} symphony start issue_id=#{issue.id} node=#{inspect(node)} relay=#{inspect(relay)}")

    try do
      case System.cmd(command, args, stderr_to_stdout: false) do
        {output, 0} ->
          case Jason.decode(String.trim(output)) do
            {:ok, %{"run_id" => run_id} = record} when is_binary(run_id) ->
              Logger.info("ExternalExecutor: started run_id=#{run_id}")
              {:ok, %{
                run_id: run_id,
                node_id: Map.get(record, "node_id"),
                agent: Map.get(record, "agent", agent),
              }}

            {:ok, other} ->
              {:error, {:invalid_start_response, other}}

            {:error, reason} ->
              {:error, {:invalid_start_response_json, reason, output}}
          end

        {output, code} ->
          {:error, {:start_failed, code, output}}
      end
    rescue
      ErlangError -> {:error, {:command_not_found, command}}
    end
  end

  defp stream_run(ctx, run_id, on_message) do
    case resolve_executable(ctx.command) do
      nil ->
        {:error, {:command_not_found, ctx.command}}

      executable ->
        stream_args =
          ["symphony", "stream", run_id, "--jsonl"]
          |> append_relay_stream_args(ctx.relay, ctx.token)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              args: Enum.map(stream_args, &String.to_charlist/1),
              line: @port_line_bytes
            ]
          )

        stream_os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        Logger.info("ExternalExecutor: streaming run_id=#{run_id} relay=#{inspect(ctx.relay)} stream_os_pid=#{inspect(stream_os_pid)}")

        on_message.(%{
          event: :vibe_stream_started,
          run_id: run_id,
          stream_os_pid: stream_os_pid,
          timestamp: DateTime.utc_now()
        })

        await_stream(port, run_id, ctx, on_message)
    end
  end

  defp await_stream(port, run_id, ctx, on_message) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, event} -> handle_event(event, port, run_id, ctx, on_message)
          {:error, _} -> await_stream(port, run_id, ctx, on_message)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        await_stream(port, run_id, ctx, on_message)

      {^port, {:exit_status, 0}} ->
        {:error, :stream_ended_without_terminal}

      {^port, {:exit_status, code}} ->
        Logger.warning("ExternalExecutor: stream crashed code=#{code} run_id=#{run_id}")
        stop_run(ctx.command, run_id, ctx.relay, ctx.token)
        {:error, {:stream_crashed, code}}
    end
  end

  defp handle_event(%{"type" => "status", "status" => "completed"}, port, run_id, _ctx, _on_message) do
    Logger.info("ExternalExecutor: completed run_id=#{run_id}")
    close_port(port)
    :ok
  end

  defp handle_event(
         %{"type" => "status", "status" => terminal} = event,
         port,
         run_id,
         _ctx,
         _on_message
       )
       when terminal in ["failed", "stopped", "cancelled"] do
    Logger.warning("ExternalExecutor: terminal=#{terminal} run_id=#{run_id}")
    close_port(port)
    {:error, {String.to_atom(terminal), event}}
  end

  defp handle_event(%{"type" => "status", "status" => "blocked"} = event, port, run_id, _ctx, on_message) do
    Logger.info("ExternalExecutor: blocked run_id=#{run_id}")
    on_message.(%{event: :vibe_blocked, raw: event, timestamp: DateTime.utc_now()})
    close_port(port)
    {:error, {:blocked, :status_blocked, event}}
  end

  defp handle_event(%{"type" => "log", "message" => message} = event, port, run_id, ctx, on_message) do
    on_message.(%{
      event: :output,
      message: message,
      stream: Map.get(event, "stream", "stdout"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    await_stream(port, run_id, ctx, on_message)
  end

  defp handle_event(%{"type" => "tool_call", "tool" => tool} = event, port, run_id, ctx, on_message) do
    on_message.(%{
      event: :tool_call,
      tool: tool,
      input: Map.get(event, "input"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    await_stream(port, run_id, ctx, on_message)
  end

  defp handle_event(%{"type" => "approval_required"} = event, port, run_id, ctx, on_message) do
    approval_id = Map.get(event, "approval_id")
    Logger.info("ExternalExecutor: approval_required run_id=#{run_id} approval_id=#{approval_id}")
    on_message.(%{
      event: :approval_required,
      approval_id: approval_id,
      message: Map.get(event, "message"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    close_port(port)

    if ctx.deny_pending_approvals do
      deny_and_stop(ctx, run_id, approval_id)
    end

    {:error, {:blocked, :approval_required, event}}
  end

  defp handle_event(%{"type" => "approval_response"} = event, port, run_id, ctx, on_message) do
    on_message.(%{
      event: :approval_response,
      approval_id: Map.get(event, "approval_id"),
      decision: Map.get(event, "decision"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    await_stream(port, run_id, ctx, on_message)
  end

  defp handle_event(%{"type" => "pr_created", "url" => url} = event, port, run_id, ctx, on_message) do
    Logger.info("ExternalExecutor: pr_created run_id=#{run_id} url=#{url}")
    on_message.(%{event: :pr_created, url: url, raw: event, timestamp: DateTime.utc_now()})
    await_stream(port, run_id, ctx, on_message)
  end

  defp handle_event(%{"type" => "error", "message" => message} = event, port, run_id, ctx, _on_message) do
    Logger.warning("ExternalExecutor: error event run_id=#{run_id} message=#{message}")
    close_port(port)
    stop_run(ctx.command, run_id, ctx.relay, ctx.token)
    {:error, {:run_error, event}}
  end

  defp handle_event(_unknown, port, run_id, ctx, on_message) do
    await_stream(port, run_id, ctx, on_message)
  end

  # Plan-only safety net: if a planner-style run (which should never modify
  # files) is asked for file-modification approval, deny it (when a relay is
  # configured) and stop the run so it doesn't sit pending.
  defp deny_and_stop(ctx, run_id, approval_id) do
    if is_binary(approval_id) and is_binary(ctx.relay) and is_binary(ctx.token) do
      case send_approval(ctx.command, run_id, approval_id, "deny", ctx.relay, ctx.token, @plan_only_deny_message) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ExternalExecutor: failed to deny approval run_id=#{run_id} approval_id=#{approval_id}: #{inspect(reason)}"
          )
      end
    end

    stop_run(ctx.command, run_id, ctx.relay, ctx.token)
    :ok
  end

  @spec send_approval(String.t(), String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def send_approval(command, run_id, approval_id, decision, relay, token, message \\ nil)

  def send_approval(_command, _run_id, _approval_id, _decision, relay, token, _message)
      when not is_binary(relay) or not is_binary(token) do
    {:error, :relay_not_configured}
  end

  def send_approval(command, run_id, approval_id, decision, relay, token, message) do
    args =
      [
        "approval", "respond",
        "--run-id", run_id,
        "--approval-id", approval_id,
        "--decision", decision,
        "--relay", relay,
        "--token", token
      ]
      |> then(fn a -> if is_binary(message), do: a ++ ["--message", message], else: a end)

    Logger.info("ExternalExecutor: approval respond run_id=#{run_id} approval_id=#{approval_id} decision=#{decision}")

    try do
      case System.cmd(command, args, stderr_to_stdout: false) do
        {output, 0} ->
          case Jason.decode(String.trim(output)) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, {:invalid_approval_response_json, reason, output}}
          end

        {output, code} ->
          {:error, {:approval_failed, code, output}}
      end
    rescue
      ErlangError -> {:error, {:command_not_found, command}}
    end
  end

  @spec query_run_status(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, %{status: String.t(), pr_url: String.t() | nil, error: String.t() | nil}}
          | {:error, term()}
  def query_run_status(command, run_id, relay, token)
      when is_binary(command) and is_binary(run_id) do
    args =
      ["symphony", "status", run_id, "--json"]
      |> append_relay_stream_args(relay, token)

    try do
      case System.cmd(command, args, stderr_to_stdout: false) do
        {output, 0} ->
          case Jason.decode(String.trim(output)) do
            {:ok, %{"status" => status} = record} when is_binary(status) ->
              {:ok,
               %{
                 status: status,
                 pr_url: Map.get(record, "pr_url"),
                 error: Map.get(record, "error")
               }}

            {:ok, other} ->
              {:error, {:unexpected_status_response, other}}

            {:error, reason} ->
              {:error, {:invalid_status_json, reason}}
          end

        {_output, code} ->
          {:error, {:status_command_failed, code}}
      end
    rescue
      ErlangError -> {:error, {:command_not_found, command}}
    end
  end

  def query_run_status(_command, _run_id, _relay, _token), do: {:error, :invalid_args}

  def stop_run(command, run_id, relay, token) do
    args =
      ["symphony", "stop", run_id]
      |> append_relay_stream_args(relay, token)

    try do
      System.cmd(command, args, stderr_to_stdout: true)
    catch
      _, _ -> :ok
    end
  end

  # Terminates the local OS process that was opened for `vibe symphony stream
  # <run_id>`. Before sending any signal, verifies via /proc/<os_pid>/cmdline
  # that the process is actually the expected stream process for this run_id, to
  # avoid killing an unrelated process that happened to reuse the PID. On
  # mismatch or non-existent PID, logs a warning and returns :ok without
  # crashing. Sends SIGTERM first; if the process is still alive after 2
  # seconds, escalates to SIGKILL in a background process so the caller is not
  # blocked.
  @spec kill_stream_process(integer(), String.t()) :: :ok
  def kill_stream_process(os_pid, run_id) when is_integer(os_pid) and is_binary(run_id) do
    if verify_stream_process_cmdline(os_pid, run_id) do
      Logger.info("ExternalExecutor: SIGTERM stream os_pid=#{os_pid} run_id=#{run_id}")
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

      spawn(fn ->
        :timer.sleep(2_000)

        if os_process_alive?(os_pid) do
          Logger.warning("ExternalExecutor: SIGKILL stream os_pid=#{os_pid} run_id=#{run_id} (SIGTERM timed out)")
          System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
        end
      end)
    else
      Logger.warning("ExternalExecutor: stream os_pid=#{os_pid} cmdline does not match run_id=#{run_id}; skipping kill")
    end

    :ok
  end

  def kill_stream_process(_os_pid, _run_id), do: :ok

  # Remote dispatch is determined by node + relay, NOT by the auth token: the
  # vibe CLI also resolves the relay token from its own VIBE_RELAY_TOKEN env (see
  # resolveRelayToken / `--token` help text), and the worker daemon runs with no
  # `--token` at all. So a nil/blank token must never silently drop --node/--relay
  # and fall back to LOCAL mode — that produced `{:start_failed, 1, ""}` (vibe ran
  # locally, found no such node, exited 1 with JSON on stdout / empty stderr).
  # We forward --node/--relay whenever both are present, and append --token only
  # when we actually have one (otherwise the client uses its env token, or fails
  # loudly on the relay side instead of degrading to local).
  defp append_relay_args(args, node, relay, token)
       when is_binary(node) and node != "" and is_binary(relay) and relay != "" do
    (args ++ ["--node", node, "--relay", relay]) |> maybe_append_token(token)
  end

  defp append_relay_args(args, _node, _relay, _token), do: args

  defp append_relay_stream_args(args, relay, token) when is_binary(relay) and relay != "" do
    (args ++ ["--relay", relay]) |> maybe_append_token(token)
  end

  defp append_relay_stream_args(args, _relay, _token), do: args

  defp maybe_append_token(args, token) when is_binary(token) and token != "" do
    args ++ ["--token", token]
  end

  defp maybe_append_token(args, _token), do: args

  # Only add --encrypt when relay is configured and encrypt is explicitly true.
  # Encrypting local runs has no effect (no relay to be blind to the payload).
  defp append_encrypt(args, true, relay) when is_binary(relay), do: args ++ ["--encrypt"]
  defp append_encrypt(args, _encrypt, _relay), do: args

  defp append_repo_url(args, repo_url) when is_binary(repo_url) and repo_url != "" do
    args ++ ["--repo-url", repo_url]
  end

  defp append_repo_url(args, _repo_url), do: args

  defp append_permission_mode(args, mode) when is_binary(mode) and mode != "default" do
    args ++ ["--permission-mode", mode]
  end

  defp append_permission_mode(args, _mode), do: args

  defp close_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp resolve_executable(command) when is_binary(command) do
    if String.starts_with?(command, "/") do
      if File.regular?(command), do: command, else: nil
    else
      System.find_executable(command)
    end
  end

  defp write_temp_prompt!(prompt, issue) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-prompt-#{issue.id}-#{System.unique_integer([:positive])}.md"
      )

    File.write!(path, prompt)
    path
  end

  # Reads /proc/<os_pid>/cmdline (Linux-only) and verifies that the null-
  # separated argv entries include both the literal string "stream" and the
  # expected run_id. This prevents killing an unrelated process if the OS has
  # reused the PID since the stream was started.
  defp verify_stream_process_cmdline(os_pid, run_id) do
    case File.read("/proc/#{os_pid}/cmdline") do
      {:ok, contents} ->
        args = String.split(contents, <<0>>, trim: true)
        Enum.any?(args, &(&1 == "stream")) and Enum.any?(args, &(&1 == run_id))

      {:error, _} ->
        false
    end
  end

  defp os_process_alive?(os_pid) do
    File.exists?("/proc/#{os_pid}")
  end
end
