defmodule SymphonyElixir.Planner.RunnerTest do
  @moduledoc """
  Tests for `SymphonyElixir.Planner.Runner`.

  Every test here swaps `:linear_client_module` for `FakePlannerLinearClient`
  and `:planner_executor_module` for `FakePlannerExecutor`, and uses
  `tracker.kind: "memory"` so parent comments/state transitions are asserted
  via `Tracker.Memory` messages. No test performs a real Linear API call, an
  external Codex run, or anything that would create/open a pull request.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Planner.Runner

  defmodule FakePlannerLinearClient do
    def create_issue(attrs) do
      send(self(), {:create_issue_called, attrs})

      case Application.get_env(:symphony_elixir, :fake_create_issue_result) do
        nil ->
          n = System.unique_integer([:positive, :monotonic])
          identifier = "JOZ-#{200 + n}"

          {:ok,
           %{
             id: "child-id-#{n}",
             identifier: identifier,
             title: attrs.title,
             url: "https://linear.app/issue/#{identifier}",
             state: "Backlog"
           }}

        result ->
          result
      end
    end

    def fetch_team_states(team_id) do
      send(self(), {:fetch_team_states_called, team_id})

      {:ok,
       [
         %{id: "state-backlog", name: "Backlog"},
         %{id: "state-todo", name: "Todo"},
         %{id: "state-human-review", name: "Human Review"}
       ]}
    end

    def resolve_team_state_id(team_id, state_name) do
      send(self(), {:resolve_team_state_id_called, team_id, state_name})

      case String.downcase(state_name) do
        "backlog" -> {:ok, "state-backlog"}
        "todo" -> {:ok, "state-todo"}
        "human review" -> {:ok, "state-human-review"}
        _ -> {:error, :state_not_found}
      end
    end

    def fetch_team_labels(team_id) do
      send(self(), {:fetch_team_labels_called, team_id})
      {:ok, [%{id: "label-bug", name: "Bug"}]}
    end

    def resolve_team_label_id(team_id, label_name) do
      send(self(), {:resolve_team_label_id_called, team_id, label_name})

      case String.downcase(label_name) do
        "bug" -> {:ok, "label-bug"}
        _ -> {:error, :label_not_found}
      end
    end

    def fetch_issue_comments(issue_id) do
      send(self(), {:fetch_issue_comments_called, issue_id})
      Application.get_env(:symphony_elixir, :fake_issue_comments, {:ok, []})
    end

    def fetch_issue_children(issue_id) do
      send(self(), {:fetch_issue_children_called, issue_id})
      Application.get_env(:symphony_elixir, :fake_issue_children, {:ok, []})
    end
  end

  defmodule FakePlannerExecutor do
    def run(issue, prompt, workspace, opts) do
      send(self(), {:executor_run_called, issue, prompt, workspace, opts})

      case Application.get_env(:symphony_elixir, :fake_executor_result) do
        {:ok, output} ->
          on_message = Keyword.fetch!(opts, :on_message)
          on_message.(%{event: :output, message: output})
          :ok

        {:error, _reason} = error ->
          error

        nil ->
          :ok
      end
    end
  end

  setup do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_executor = Application.get_env(:symphony_elixir, :planner_executor_module)

    Application.put_env(:symphony_elixir, :linear_client_module, FakePlannerLinearClient)
    Application.put_env(:symphony_elixir, :planner_executor_module, FakePlannerExecutor)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      planner_enabled: true,
      planner_trigger_label: "type:plan",
      planner_child_initial_state: "Backlog",
      planner_max_children: 10
    )

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:planner_executor_module, previous_executor)
      Application.delete_env(:symphony_elixir, :fake_executor_result)
      Application.delete_env(:symphony_elixir, :fake_issue_comments)
      Application.delete_env(:symphony_elixir, :fake_issue_children)
      Application.delete_env(:symphony_elixir, :fake_create_issue_result)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp parent_issue(overrides \\ []) do
    struct(
      %Issue{
        id: "parent-1",
        identifier: "JOZ-1",
        title: "Parent issue title",
        description: "Parent issue description.",
        state: "Todo",
        team_id: "team-1",
        project_id: "project-1",
        project_description: nil,
        project_labels: [],
        labels: ["type:plan"]
      },
      overrides
    )
  end

  defp planner_output(titles) do
    children =
      Enum.map(titles, fn title ->
        %{
          "title" => title,
          "description" => "Implement #{title}.",
          "acceptance_criteria" => ["Tests cover #{title}"],
          "labels" => [],
          "execution_mode" => "manual_review",
          "independent" => true
        }
      end)

    json = Jason.encode!(%{"children" => children})

    "Planning notes for this issue.\n\n```json\n#{json}\n```\n"
  end

  test "creates child issues in Backlog with parentId/projectId/teamId, posts a summary comment with the idempotency marker, and moves the parent to Human Review" do
    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["First child title", "Second child title"])})

    issue = parent_issue()

    assert {:ok, {:created_children, identifiers}} = Runner.run(issue, recipient: self())
    assert length(identifiers) == 2

    for _ <- identifiers do
      assert_receive {:create_issue_called, attrs}
      assert attrs.team_id == "team-1"
      assert attrs.parent_id == "parent-1"
      assert attrs.project_id == "project-1"
      assert attrs.state_id == "state-backlog"
      assert attrs.description =~ "## Acceptance criteria"
      assert attrs.description =~ "Open a PR, do not merge."
    end

    assert_receive {:memory_tracker_comment, "parent-1", comment}
    assert comment =~ "<!-- symphony-planner:v1 parent=parent-1 children=["

    for identifier <- identifiers do
      assert comment =~ identifier
    end

    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
    assert_receive {:planner_done, "parent-1"}
  end

  test "retry with an existing idempotency marker creates zero new children" do
    Application.put_env(
      :symphony_elixir,
      :fake_issue_comments,
      {:ok, [%{id: "c1", body: "<!-- symphony-planner:v1 parent=parent-1 children=[JOZ-101,JOZ-102] -->", created_at: nil}]}
    )

    issue = parent_issue(state: "Todo")

    assert {:ok, :already_done} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}
    refute_receive {:executor_run_called, _issue, _prompt, _workspace, _opts}

    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
    assert_receive {:planner_done, "parent-1"}
  end

  test "retry when the parent is already in Human Review does not post another comment or transition" do
    Application.put_env(
      :symphony_elixir,
      :fake_issue_comments,
      {:ok, [%{id: "c1", body: "<!-- symphony-planner:v1 parent=parent-1 children=[JOZ-101] -->", created_at: nil}]}
    )

    issue = parent_issue(state: "Human Review")

    assert {:ok, :already_done} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}
    refute_receive {:memory_tracker_comment, _issue_id, _body}
    refute_receive {:memory_tracker_state_update, _issue_id, _state_name}
    assert_receive {:planner_done, "parent-1"}
  end

  test "partial existing children from a previous run are not duplicated" do
    Application.put_env(:symphony_elixir, :fake_issue_comments, {:ok, []})

    Application.put_env(
      :symphony_elixir,
      :fake_issue_children,
      {:ok, [%{id: "child-1", identifier: "JOZ-101", title: "First child title", state: "Backlog"}]}
    )

    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["First child title", "Second child title"])})

    issue = parent_issue()

    assert {:ok, {:created_children, ["JOZ-101", new_identifier]}} = Runner.run(issue, recipient: self())
    assert new_identifier != "JOZ-101"

    assert_receive {:create_issue_called, attrs}
    assert attrs.title == "Second child title"
    refute_receive {:create_issue_called, %{title: "First child title"}}

    assert_receive {:memory_tracker_comment, "parent-1", comment}
    assert comment =~ "JOZ-101"
    assert comment =~ new_identifier
  end

  test "malformed planner output moves the parent to Human Review with an error comment and creates no children" do
    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, "I could not come up with a plan.\n"})

    issue = parent_issue()

    assert {:ok, {:failed, {:plan_extraction_failed, :no_json_block_found}}} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}

    assert_receive {:memory_tracker_comment, "parent-1", comment}
    assert comment =~ "could not finish planning"

    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
    assert_receive {:planner_done, "parent-1"}
  end

  test "an executor failure moves the parent to Human Review with an error comment and creates no children" do
    Application.put_env(:symphony_elixir, :fake_executor_result, {:error, {:stream_crashed, 1}})

    issue = parent_issue()

    assert {:ok, {:failed, {:executor_failed, {:stream_crashed, 1}}}} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}
    assert_receive {:memory_tracker_comment, "parent-1", _comment}
    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
  end

  test "more children than planner.max_children moves the parent to Human Review without creating any children" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      planner_enabled: true,
      planner_trigger_label: "type:plan",
      planner_child_initial_state: "Backlog",
      planner_max_children: 1
    )

    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["First child title", "Second child title"])})

    issue = parent_issue()

    assert {:ok, {:failed, {:too_many_children, 2, 1}}} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}
    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
  end

  test "an unresolvable child_initial_state moves the parent to Human Review with an error comment" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      planner_enabled: true,
      planner_trigger_label: "type:plan",
      planner_child_initial_state: "Nonexistent State",
      planner_max_children: 10
    )

    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["Only child title"])})

    issue = parent_issue()

    assert {:ok, {:failed, {:state_resolution_failed, "Nonexistent State", :state_not_found}}} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}
    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
  end

  test "child description includes a repo binding note when a repo is resolved" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      planner_enabled: true,
      planner_trigger_label: "type:plan",
      planner_child_initial_state: "Backlog",
      planner_max_children: 10,
      repo_url: "https://github.com/acme/widgets"
    )

    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["Only child title"])})

    issue = parent_issue()

    assert {:ok, {:created_children, [_identifier]}} = Runner.run(issue, recipient: self())

    assert_receive {:create_issue_called, attrs}
    assert attrs.description =~ "Repo binding: https://github.com/acme/widgets"
  end
end
