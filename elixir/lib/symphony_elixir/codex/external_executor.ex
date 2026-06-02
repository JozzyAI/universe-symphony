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
  | approval_required | :approval_required    | approval_id, message — then returns blocked |
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

  @spec run(Issue.t(), String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def run(issue, prompt, _workspace, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    command = Keyword.get(opts, :command, "vibe")
    agent = Keyword.get(opts, :agent, "mock")
    node = Keyword.get(opts, :node)
    relay = Keyword.get(opts, :relay)
    token = Keyword.get(opts, :token)
    permission_mode = Keyword.get(opts, :permission_mode)

    prompt_file = write_temp_prompt!(prompt, issue)

    try do
      with {:ok, run_meta} <- start_run(command, agent, issue, prompt_file, node, relay, token, permission_mode) do
        # Announce Vibe run metadata so the orchestrator can display run_id/node/agent in the UI.
        on_message.(%{
          event: :vibe_start,
          vibe_run_id: run_meta.run_id,
          vibe_node_id: run_meta.node_id,
          vibe_agent: run_meta.agent,
          timestamp: DateTime.utc_now(),
        })

        stream_run(command, run_meta.run_id, relay, token, on_message)
      end
    after
      File.rm(prompt_file)
    end
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  defp start_run(command, agent, issue, prompt_file, node, relay, token, permission_mode) do
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

  defp stream_run(command, run_id, relay, token, on_message) do
    case resolve_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      executable ->
        stream_args =
          ["symphony", "stream", run_id, "--jsonl"]
          |> append_relay_stream_args(relay, token)

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

        Logger.info("ExternalExecutor: streaming run_id=#{run_id} relay=#{inspect(relay)}")
        await_stream(port, run_id, command, relay, token, on_message)
    end
  end

  defp await_stream(port, run_id, command, relay, token, on_message) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, event} -> handle_event(event, port, run_id, command, relay, token, on_message)
          {:error, _} -> await_stream(port, run_id, command, relay, token, on_message)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        await_stream(port, run_id, command, relay, token, on_message)

      {^port, {:exit_status, 0}} ->
        {:error, :stream_ended_without_terminal}

      {^port, {:exit_status, code}} ->
        Logger.warning("ExternalExecutor: stream crashed code=#{code} run_id=#{run_id}")
        stop_run(command, run_id, relay, token)
        {:error, {:stream_crashed, code}}
    end
  end

  defp handle_event(%{"type" => "status", "status" => "completed"}, port, run_id, _command, _relay, _token, _on_message) do
    Logger.info("ExternalExecutor: completed run_id=#{run_id}")
    close_port(port)
    :ok
  end

  defp handle_event(
         %{"type" => "status", "status" => terminal} = event,
         port,
         run_id,
         _command,
         _relay,
         _token,
         _on_message
       )
       when terminal in ["failed", "stopped", "cancelled"] do
    Logger.warning("ExternalExecutor: terminal=#{terminal} run_id=#{run_id}")
    close_port(port)
    {:error, {String.to_atom(terminal), event}}
  end

  defp handle_event(%{"type" => "status", "status" => "blocked"} = event, port, run_id, _command, _relay, _token, on_message) do
    Logger.info("ExternalExecutor: blocked run_id=#{run_id}")
    on_message.(%{event: :vibe_blocked, raw: event, timestamp: DateTime.utc_now()})
    close_port(port)
    {:error, {:blocked, :status_blocked, event}}
  end

  defp handle_event(%{"type" => "log", "message" => message} = event, port, run_id, command, relay, token, on_message) do
    on_message.(%{
      event: :output,
      message: message,
      stream: Map.get(event, "stream", "stdout"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    await_stream(port, run_id, command, relay, token, on_message)
  end

  defp handle_event(%{"type" => "tool_call", "tool" => tool} = event, port, run_id, command, relay, token, on_message) do
    on_message.(%{
      event: :tool_call,
      tool: tool,
      input: Map.get(event, "input"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    await_stream(port, run_id, command, relay, token, on_message)
  end

  defp handle_event(%{"type" => "approval_required"} = event, port, run_id, _command, _relay, _token, on_message) do
    Logger.info("ExternalExecutor: approval_required run_id=#{run_id} approval_id=#{Map.get(event, "approval_id")}")
    on_message.(%{
      event: :approval_required,
      approval_id: Map.get(event, "approval_id"),
      message: Map.get(event, "message"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    close_port(port)
    {:error, {:blocked, :approval_required, event}}
  end

  defp handle_event(%{"type" => "approval_response"} = event, port, run_id, command, relay, token, on_message) do
    on_message.(%{
      event: :approval_response,
      approval_id: Map.get(event, "approval_id"),
      decision: Map.get(event, "decision"),
      raw: event,
      timestamp: DateTime.utc_now()
    })
    await_stream(port, run_id, command, relay, token, on_message)
  end

  defp handle_event(%{"type" => "pr_created", "url" => url} = event, port, run_id, command, relay, token, on_message) do
    Logger.info("ExternalExecutor: pr_created run_id=#{run_id} url=#{url}")
    on_message.(%{event: :pr_created, url: url, raw: event, timestamp: DateTime.utc_now()})
    await_stream(port, run_id, command, relay, token, on_message)
  end

  defp handle_event(%{"type" => "error", "message" => message} = event, port, run_id, command, relay, token, _on_message) do
    Logger.warning("ExternalExecutor: error event run_id=#{run_id} message=#{message}")
    close_port(port)
    stop_run(command, run_id, relay, token)
    {:error, {:run_error, event}}
  end

  defp handle_event(_unknown, port, run_id, command, relay, token, on_message) do
    await_stream(port, run_id, command, relay, token, on_message)
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

  defp stop_run(command, run_id, relay, token) do
    args =
      ["symphony", "stop", run_id]
      |> append_relay_stream_args(relay, token)

    try do
      System.cmd(command, args, stderr_to_stdout: true)
    catch
      _, _ -> :ok
    end
  end

  defp append_relay_args(args, node, relay, token)
       when is_binary(node) and is_binary(relay) and is_binary(token) do
    args ++ ["--node", node, "--relay", relay, "--token", token]
  end

  defp append_relay_args(args, _node, _relay, _token), do: args

  defp append_relay_stream_args(args, relay, token)
       when is_binary(relay) and is_binary(token) do
    args ++ ["--relay", relay, "--token", token]
  end

  defp append_relay_stream_args(args, _relay, _token), do: args

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
end
