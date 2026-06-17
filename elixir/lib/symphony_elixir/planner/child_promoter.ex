defmodule SymphonyElixir.Planner.ChildPromoter do
  @moduledoc """
  Detects when a planner-created child issue moves to Done and promotes the
  next Backlog sibling to Todo, driving sequential child execution.

  The canonical child ordering is read from the parent's `symphony-planner:v1`
  marker comment, which lists children in the order PlannerRunner created
  them. Promotion is idempotent: a `symphony-autopromote:v1` marker comment
  is posted on the parent after each successful promotion so a second call
  (e.g. from a duplicate BEAM) detects the marker and skips.

  ## Strict Done-only rule

  Only the literal "Done" state (case-insensitive) counts as a completed
  predecessor for promotion purposes. Canceled, Duplicate, Human Review,
  Rework, Merging, and every other state do NOT trigger promotion. This
  prevents a skipped or cancelled sibling from cascade-promoting the rest of
  the sequence.

  ## First-child kickoff

  The first child in the sequence (index 0) is never auto-promoted. It
  requires a manual or out-of-band kickoff. Auto-promotion only fires once at
  least one predecessor is Done.

  ## Singleton note

  This module is code-level idempotent but not distributed-lock safe. Two
  concurrent Symphony processes may each attempt the same promotion. The
  autopromote marker check and the child-state check (Backlog → Todo) reduce
  but do not fully close the race window.

  TODO: full singleton enforcement (e.g. a distributed lock or single-writer
  BEAM coordination) should be addressed in a separate Symphony hardening PR.
  """

  require Logger

  alias SymphonyElixir.{Redact, Tracker}
  alias SymphonyElixir.Linear.Adapter

  @planner_marker_regex ~r/<!--\s*symphony-planner:v1\s+parent=\S+\s+children=\[([^\]]*)\]\s*-->/
  @autopromote_marker_prefix "<!-- symphony-autopromote:v1"

  @type promote_result :: :promoted | :skipped | :all_done | {:error, term()}

  @doc """
  Scans Linear for planner-managed parent issues (state Human Review or Done
  with `trigger_label`) that have a planner marker comment, and returns their
  IDs. Called once on startup to rehydrate the orchestrator's in-memory
  `tracked_parent_ids` after a BEAM restart.
  """
  @spec rehydrate_parent_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def rehydrate_parent_ids(trigger_label) when is_binary(trigger_label) do
    with {:ok, issues} <- Tracker.fetch_issues_by_states(["Human Review", "Done"]) do
      candidates = Enum.filter(issues, &(trigger_label in (&1.labels || [])))

      parent_ids =
        Enum.flat_map(candidates, fn issue ->
          case has_planner_marker?(issue.id) do
            {:ok, true} -> [issue.id]
            _ -> []
          end
        end)

      {:ok, parent_ids}
    end
  end

  @doc """
  Attempts to promote the next Backlog child of `parent_id` to Todo.

  Returns:
  - `:promoted`   — one child was moved from Backlog to Todo
  - `:skipped`    — no promotable target (no Done predecessor, next not
                    Backlog, idempotency marker already present, etc.)
  - `:all_done`   — all children in the sequence are Done; the caller may
                    remove this parent from tracking
  - `{:error, t}` — a Linear API call failed; log and retry next tick
  """
  @spec maybe_promote(String.t()) :: promote_result()
  def maybe_promote(parent_id) when is_binary(parent_id) do
    case do_maybe_promote(parent_id) do
      result when result in [:promoted, :skipped, :all_done] ->
        result

      {:error, reason} ->
        Logger.warning(
          "ChildPromoter: error for parent_id=#{parent_id}: #{inspect(Redact.redact(reason))}"
        )

        {:error, reason}
    end
  end

  @doc false
  @spec parse_child_identifiers([map()]) :: {:ok, [String.t()]} | {:skip, String.t()}
  def parse_child_identifiers(comments) when is_list(comments) do
    combined_body = Enum.map_join(comments, "\n", &Map.get(&1, :body, ""))

    case Regex.run(@planner_marker_regex, combined_body, capture: :all_but_first) do
      [identifiers_str] ->
        identifiers =
          identifiers_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, identifiers}

      nil ->
        {:skip, "no planner marker found"}
    end
  end

  @doc false
  @spec done_prefix_length([map()]) :: non_neg_integer()
  def done_prefix_length(ordered_children) when is_list(ordered_children) do
    Enum.reduce_while(ordered_children, 0, fn child, count ->
      state = String.downcase(to_string(Map.get(child, :state, "")))

      if state == "done" do
        {:cont, count + 1}
      else
        {:halt, count}
      end
    end)
  end

  @doc false
  @spec find_promotion_target([map()]) ::
          {:ok, map()} | {:skip, String.t()} | {:all_done, String.t()}
  def find_promotion_target(ordered_children) when is_list(ordered_children) do
    n = length(ordered_children)
    prefix_len = done_prefix_length(ordered_children)

    cond do
      n == 0 ->
        {:skip, "no children in sequence"}

      prefix_len == 0 ->
        {:skip, "no done predecessor; first child kickoff remains manual"}

      prefix_len == n ->
        {:all_done, "all #{n} children are Done"}

      true ->
        target = Enum.at(ordered_children, prefix_len)
        state = String.downcase(to_string(Map.get(target, :state, "")))

        if state == "backlog" do
          {:ok, target}
        else
          {:skip, "next child #{Map.get(target, :identifier)} is #{Map.get(target, :state)}; not Backlog"}
        end
    end
  end

  @doc false
  @spec already_promoted?([map()], String.t()) :: boolean()
  def already_promoted?(comments, identifier) when is_list(comments) and is_binary(identifier) do
    Enum.any?(comments, fn comment ->
      body = Map.get(comment, :body, "")
      String.contains?(body, @autopromote_marker_prefix) and
        String.contains?(body, "promoted=#{identifier}")
    end)
  end

  # ─── Private ─────────────────────────────────────────────────────────────

  defp do_maybe_promote(parent_id) do
    with {:ok, comments} <- Adapter.fetch_issue_comments(parent_id),
         {:ok, identifiers} <- parse_child_identifiers(comments),
         {:ok, children} <- Adapter.fetch_issue_children(parent_id) do
      ordered_children = build_ordered_children(identifiers, children)

      case find_promotion_target(ordered_children) do
        {:all_done, _} ->
          :all_done

        {:skip, reason} ->
          Logger.debug("ChildPromoter: skipping parent_id=#{parent_id}: #{reason}")
          :skipped

        {:ok, target} ->
          if already_promoted?(comments, target.identifier) do
            Logger.info(
              "ChildPromoter: #{target.identifier} already promoted for parent_id=#{parent_id}; skipping"
            )

            :skipped
          else
            perform_promotion(parent_id, target)
          end
      end
    else
      {:skip, reason} ->
        Logger.debug("ChildPromoter: skipping parent_id=#{parent_id}: #{reason}")
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_ordered_children(identifiers, children) do
    by_identifier = Map.new(children, &{&1.identifier, &1})

    Enum.flat_map(identifiers, fn id ->
      case Map.get(by_identifier, id) do
        nil -> []
        child -> [child]
      end
    end)
  end

  defp perform_promotion(parent_id, target) do
    Logger.info(
      "ChildPromoter: promoting #{target.identifier} (id=#{target.id}) Backlog→Todo for parent_id=#{parent_id}"
    )

    with :ok <- Tracker.update_issue_state(target.id, "Todo") do
      marker = autopromote_marker(parent_id, target.identifier)

      case Tracker.create_comment(parent_id, marker) do
        :ok ->
          Logger.info(
            "ChildPromoter: promoted #{target.identifier} and posted idempotency marker on parent_id=#{parent_id}"
          )

          :promoted

        {:error, reason} ->
          Logger.warning(
            "ChildPromoter: promoted #{target.identifier} but failed to post marker on parent_id=#{parent_id}: #{inspect(Redact.redact(reason))}"
          )

          :promoted
      end
    end
  end

  defp autopromote_marker(parent_id, identifier) do
    "#{@autopromote_marker_prefix} parent=#{parent_id} promoted=#{identifier} -->"
  end

  defp has_planner_marker?(parent_id) do
    case Adapter.fetch_issue_comments(parent_id) do
      {:ok, comments} ->
        combined_body = Enum.map_join(comments, "\n", &Map.get(&1, :body, ""))
        {:ok, Regex.match?(@planner_marker_regex, combined_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
