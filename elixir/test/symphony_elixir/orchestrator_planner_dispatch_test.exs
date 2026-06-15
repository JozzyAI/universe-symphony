defmodule SymphonyElixir.OrchestratorPlannerDispatchTest do
  @moduledoc """
  Tests for the planner dispatch branch in `SymphonyElixir.Orchestrator`:
  routing a `type:plan` parent issue to `SymphonyElixir.Planner.Runner`
  instead of the normal repo-binding/AgentRunner dispatch path, gated behind
  `planner.enabled`.

  As in `SymphonyElixir.Planner.RunnerTest`, `:linear_client_module` and
  `:planner_executor_module` are swapped for fakes and `tracker.kind:
  "memory"` is used so no real Linear API call, external Codex run, or PR is
  ever made.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator

  # Runner.run/2 is dispatched into a separate `Task.Supervisor` task by the
  # orchestrator, so `self()` inside these callbacks would be the task's pid,
  # not the test process. Send to the shared `:memory_tracker_recipient`
  # (set to the test pid in `setup`) instead, matching `Tracker.Memory`.
  def test_recipient, do: Application.get_env(:symphony_elixir, :memory_tracker_recipient)

  defmodule FakePlannerLinearClient do
    def create_issue(attrs) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:create_issue_called, attrs})

      n = System.unique_integer([:positive, :monotonic])
      identifier = "JOZ-#{300 + n}"

      {:ok,
       %{
         id: "child-id-#{n}",
         identifier: identifier,
         title: attrs.title,
         url: "https://linear.app/issue/#{identifier}",
         state: "Backlog"
       }}
    end

    def fetch_team_states(team_id) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:fetch_team_states_called, team_id})

      {:ok, [%{id: "state-backlog", name: "Backlog"}, %{id: "state-human-review", name: "Human Review"}]}
    end

    def resolve_team_state_id(team_id, state_name) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:resolve_team_state_id_called, team_id, state_name})

      case String.downcase(state_name) do
        "backlog" -> {:ok, "state-backlog"}
        "human review" -> {:ok, "state-human-review"}
        _ -> {:error, :state_not_found}
      end
    end

    def fetch_team_labels(team_id) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:fetch_team_labels_called, team_id})
      {:ok, []}
    end

    def resolve_team_label_id(team_id, label_name) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:resolve_team_label_id_called, team_id, label_name})
      {:error, :label_not_found}
    end

    def fetch_issue_comments(issue_id) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:fetch_issue_comments_called, issue_id})
      {:ok, []}
    end

    def fetch_issue_children(issue_id) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:fetch_issue_children_called, issue_id})
      {:ok, []}
    end
  end

  defmodule FakePlannerExecutor do
    def run(issue, prompt, workspace, opts) do
      send(SymphonyElixir.OrchestratorPlannerDispatchTest.test_recipient(), {:executor_run_called, issue, prompt, workspace, opts})

      on_message = Keyword.fetch!(opts, :on_message)

      output = """
      Planning notes for this issue.

      ```json
      {"children": [{"title": "Child A", "description": "Do A.", "acceptance_criteria": ["A works"], "labels": [], "execution_mode": "manual_review", "independent": true}]}
      ```
      """

      on_message.(%{event: :output, message: output})
      :ok
    end
  end

  setup do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_executor = Application.get_env(:symphony_elixir, :planner_executor_module)

    Application.put_env(:symphony_elixir, :linear_client_module, FakePlannerLinearClient)
    Application.put_env(:symphony_elixir, :planner_executor_module, FakePlannerExecutor)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:planner_executor_module, previous_executor)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp plan_issue(overrides \\ []) do
    struct(
      %Issue{
        id: "issue-plan-1",
        identifier: "JOZ-50",
        title: "Decompose the widget overhaul",
        description: "Plan out the widget overhaul.",
        state: "Todo",
        team_id: "team-1",
        project_id: "project-1",
        labels: ["type:plan"]
      },
      overrides
    )
  end

  describe "planner_dispatch_for_test/2 (routing decision)" do
    test "planner disabled: type:plan Todo issue is not routed to PlannerRunner and follows old dispatch behavior" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", planner_enabled: false)

      issue = plan_issue()
      state = %Orchestrator.State{}

      refute Orchestrator.planner_dispatch_for_test(issue, state)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "planner enabled + type:plan + Todo: routed to PlannerRunner" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan"
      )

      issue = plan_issue()
      state = %Orchestrator.State{}

      assert Orchestrator.planner_dispatch_for_test(issue, state)
    end

    test "planner enabled but issue lacks the trigger label: not routed to PlannerRunner" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan"
      )

      issue = plan_issue(labels: [])
      state = %Orchestrator.State{}

      refute Orchestrator.planner_dispatch_for_test(issue, state)
    end

    test "planner enabled + type:plan but issue is not in Todo: not routed to PlannerRunner" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan"
      )

      issue = plan_issue(state: "In Progress")
      state = %Orchestrator.State{}

      refute Orchestrator.planner_dispatch_for_test(issue, state)
    end

    test "planner enabled + type:plan + Todo but already claimed: not re-routed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan"
      )

      issue = plan_issue()
      state = %Orchestrator.State{claimed: MapSet.new([issue.id])}

      refute Orchestrator.planner_dispatch_for_test(issue, state)
    end
  end

  describe "choose_issues_for_test/2 with planner enabled" do
    test "a type:plan Todo issue is dispatched to PlannerRunner, not AgentRunner, and the parent moves to Human Review" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan",
        planner_child_initial_state: "Backlog",
        planner_max_children: 10
      )

      issue = plan_issue()
      state = %Orchestrator.State{}

      updated_state = Orchestrator.choose_issues_for_test([issue], state)

      assert MapSet.member?(updated_state.claimed, issue.id)
      assert updated_state.running == %{}

      assert_receive {:create_issue_called, attrs}
      assert attrs.team_id == "team-1"
      assert attrs.parent_id == issue.id
      assert attrs.project_id == "project-1"
      assert attrs.state_id == "state-backlog"
      assert attrs.description =~ "Open a PR, do not merge."

      assert_receive {:memory_tracker_comment, issue_id, comment}
      assert issue_id == issue.id
      assert comment =~ "<!-- symphony-planner:v1 parent=#{issue.id} children=["

      assert_receive {:memory_tracker_state_update, issue_id, "Human Review"}
      assert issue_id == issue.id

      refute_received {:memory_tracker_state_update, _issue_id, "In Progress"}

      assert_receive {:planner_done, issue_id}
      assert issue_id == issue.id
    end
  end
end
