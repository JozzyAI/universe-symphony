defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec vibe_approve(Conn.t(), map()) :: Conn.t()
  def vibe_approve(conn, %{"issue_identifier" => issue_identifier} = params) do
    approval_id = Map.get(params, "approval_id")
    decision = Map.get(params, "decision")
    message = Map.get(params, "message")

    cond do
      is_nil(approval_id) or approval_id == "" ->
        error_response(conn, 422, "missing_approval_id", "approval_id is required")

      decision not in ["approve", "deny"] ->
        error_response(conn, 422, "invalid_decision", "decision must be approve or deny")

      true ->
        issue_id = resolve_issue_id(issue_identifier, orchestrator(), snapshot_timeout_ms())

        case issue_id do
          nil ->
            error_response(conn, 404, "issue_not_found", "Issue not found or not blocked")

          id ->
            case Orchestrator.vibe_approve(orchestrator(), id, approval_id, decision, message) do
              {:ok, result} ->
                json(conn, Map.put(result, :issue_identifier, issue_identifier))

              {:error, :not_blocked} ->
                error_response(conn, 422, "not_blocked", "Issue is not in blocked state")

              {:error, :missing_vibe_run_id} ->
                error_response(conn, 422, "missing_vibe_run_id", "Blocked entry has no vibe_run_id — was this a Vibe run?")

              {:error, :missing_vibe_approval_id} ->
                error_response(conn, 422, "missing_vibe_approval_id", "Blocked entry has no approval_id — was approval_required received?")

              {:error, {:approval_id_mismatch, _, _}} ->
                error_response(conn, 422, "approval_id_mismatch", "approval_id does not match the pending approval")

              {:error, :relay_not_configured} ->
                error_response(conn, 503, "relay_not_configured", "Relay URL and token must be configured for remote approvals")

              {:error, {:command_not_found, cmd}} ->
                error_response(conn, 503, "command_not_found", "Vibe command not found: #{cmd}")

              {:error, reason} ->
                error_response(conn, 500, "approval_failed", "Approval failed: #{inspect(reason)}")

              :unavailable ->
                error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
            end
        end
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp resolve_issue_id(issue_identifier, orchestrator, timeout_ms) do
    case Orchestrator.snapshot(orchestrator, timeout_ms) do
      %{blocked: blocked} ->
        case Enum.find(blocked, &(&1.identifier == issue_identifier)) do
          %{issue_id: id} -> id
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
