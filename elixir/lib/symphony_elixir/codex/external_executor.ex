defmodule SymphonyElixir.Codex.ExternalExecutor do
  @moduledoc """
  Dispatches a run to an external CLI runtime (e.g. `vibe symphony`).

  Unlike AppServer, there is no JSON-RPC handshake. This executor:
    1. Calls `<command> symphony start` and captures the run_id.
    2. Opens `<command> symphony stream <run_id> --jsonl` via a Port.
    3. Maps Vibe JSONL events to the standard on_message callback format.
    4. Returns :ok on completed, {:error, reason} on failed/stopped/blocked/crash.
    5. Calls `<command> symphony stop <run_id>` on abnormal exit to clean up.

  Codex (AppServer) remains the default path. This module is only invoked when
  the WORKFLOW.md sets `agent_kind: vibe`.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue

  @port_line_bytes 65_536

  @spec run(Issue.t(), String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def run(issue, prompt, _workspace, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    command = Keyword.get(opts, :command, "vibe")
    agent = Keyword.get(opts, :agent, "mock")

    prompt_file = write_temp_prompt!(prompt, issue)

    try do
      with {:ok, run_id} <- start_run(command, agent, issue, prompt_file) do
        stream_run(command, run_id, on_message)
      end
    after
      File.rm(prompt_file)
    end
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  defp start_run(command, agent, issue, prompt_file) do
    args = [
      "symphony",
      "start",
      "--agent",
      agent,
      "--issue-id",
      issue.id || "",
      "--issue-title",
      issue.title || "",
      "--workspace-key",
      issue.identifier || issue.id || "",
      "--prompt-file",
      prompt_file,
      "--json"
    ]

    Logger.info("ExternalExecutor: #{command} symphony start issue_id=#{issue.id}")

    try do
      case System.cmd(command, args, stderr_to_stdout: false) do
        {output, 0} ->
          case Jason.decode(String.trim(output)) do
            {:ok, %{"run_id" => run_id}} when is_binary(run_id) ->
              Logger.info("ExternalExecutor: started run_id=#{run_id}")
              {:ok, run_id}

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

  defp stream_run(command, run_id, on_message) do
    case resolve_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              args: Enum.map(["symphony", "stream", run_id, "--jsonl"], &String.to_charlist/1),
              line: @port_line_bytes
            ]
          )

        Logger.info("ExternalExecutor: streaming run_id=#{run_id}")
        await_stream(port, run_id, command, on_message)
    end
  end

  defp await_stream(port, run_id, command, on_message) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, event} -> handle_event(event, port, run_id, command, on_message)
          {:error, _} -> await_stream(port, run_id, command, on_message)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        await_stream(port, run_id, command, on_message)

      {^port, {:exit_status, 0}} ->
        {:error, :stream_ended_without_terminal}

      {^port, {:exit_status, code}} ->
        Logger.warning("ExternalExecutor: stream crashed code=#{code} run_id=#{run_id}")
        stop_run(command, run_id)
        {:error, {:stream_crashed, code}}
    end
  end

  defp handle_event(%{"type" => "status", "status" => "completed"}, port, run_id, _command, _on_message) do
    Logger.info("ExternalExecutor: completed run_id=#{run_id}")
    close_port(port)
    :ok
  end

  defp handle_event(
         %{"type" => "status", "status" => terminal} = event,
         port,
         run_id,
         _command,
         _on_message
       )
       when terminal in ["failed", "stopped", "cancelled"] do
    Logger.warning("ExternalExecutor: terminal=#{terminal} run_id=#{run_id}")
    close_port(port)
    {:error, {String.to_atom(terminal), event}}
  end

  defp handle_event(%{"type" => "log", "message" => message} = event, port, run_id, command, on_message) do
    on_message.(%{event: :output, message: message, raw: event, timestamp: DateTime.utc_now()})
    await_stream(port, run_id, command, on_message)
  end

  defp handle_event(%{"type" => "tool_call", "tool" => tool} = event, port, run_id, command, on_message) do
    on_message.(%{event: :tool_call, tool: tool, raw: event, timestamp: DateTime.utc_now()})
    await_stream(port, run_id, command, on_message)
  end

  defp handle_event(%{"type" => "approval_required"} = event, port, run_id, _command, on_message) do
    Logger.info("ExternalExecutor: approval_required run_id=#{run_id}")
    on_message.(%{event: :approval_required, raw: event, timestamp: DateTime.utc_now()})
    close_port(port)
    {:error, {:blocked, :approval_required, event}}
  end

  defp handle_event(%{"type" => "error", "message" => message} = event, port, run_id, command, _on_message) do
    Logger.warning("ExternalExecutor: error event run_id=#{run_id} message=#{message}")
    close_port(port)
    stop_run(command, run_id)
    {:error, {:run_error, event}}
  end

  defp handle_event(_unknown, port, run_id, command, on_message) do
    await_stream(port, run_id, command, on_message)
  end

  defp stop_run(command, run_id) do
    try do
      System.cmd(command, ["symphony", "stop", run_id], stderr_to_stdout: true)
    catch
      _, _ -> :ok
    end
  end

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
