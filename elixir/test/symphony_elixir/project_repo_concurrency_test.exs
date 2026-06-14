defmodule SymphonyElixir.ProjectRepoConcurrencyTest do
  use SymphonyElixir.TestSupport

  defp running_entry(issue) do
    %{issue: issue, pid: self(), ref: make_ref(), identifier: issue.identifier, worker_host: nil}
  end

  defp with_running(state, issue) do
    %{state | running: Map.put(state.running, issue.id, running_entry(issue)), claimed: MapSet.put(state.claimed, issue.id)}
  end

  test "second Todo issue from the same Linear project is not dispatched when project limit is 1" do
    write_workflow_file!(Workflow.workflow_file_path(), max_active_runs_per_project: 1)

    issue1 = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}
    issue2 = %Issue{id: "issue-2", identifier: "MT-2", title: "Second", state: "Todo", project_id: "proj-A"}

    state = %Orchestrator.State{}

    assert Orchestrator.should_dispatch_issue_for_test(issue1, state)
    assert Orchestrator.should_dispatch_issue_for_test(issue2, state)

    running_state = with_running(state, issue1)

    refute Orchestrator.should_dispatch_issue_for_test(issue2, running_state)
  end

  test "second Todo issue for the same resolved repo is not dispatched when repo limit is 1" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_active_runs_per_repo: 1,
      repo_url: "https://github.com/JozzyAI/spendlens"
    )

    issue1 = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}
    issue2 = %Issue{id: "issue-2", identifier: "MT-2", title: "Second", state: "Todo", project_id: "proj-B"}

    state = %Orchestrator.State{}

    assert Orchestrator.should_dispatch_issue_for_test(issue1, state)
    assert Orchestrator.should_dispatch_issue_for_test(issue2, state)

    running_state = with_running(state, issue1)

    refute Orchestrator.should_dispatch_issue_for_test(issue2, running_state)
  end

  test "issues from different Linear projects can both be dispatch-eligible when project limit is 1" do
    write_workflow_file!(Workflow.workflow_file_path(), max_active_runs_per_project: 1)

    issue1 = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}
    issue2 = %Issue{id: "issue-2", identifier: "MT-2", title: "Second", state: "Todo", project_id: "proj-B"}

    state = %Orchestrator.State{}
    running_state = with_running(state, issue1)

    assert Orchestrator.should_dispatch_issue_for_test(issue2, running_state)
  end

  test "unset project/repo limits preserve prior dispatch behavior" do
    write_workflow_file!(Workflow.workflow_file_path())

    issue1 = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}
    issue2 = %Issue{id: "issue-2", identifier: "MT-2", title: "Second", state: "Todo", project_id: "proj-A"}

    state = %Orchestrator.State{}
    running_state = with_running(state, issue1)

    assert Orchestrator.should_dispatch_issue_for_test(issue2, running_state)
  end

  test "Todo issue is skipped (left in Todo) when another issue from the same project is already In Progress" do
    write_workflow_file!(Workflow.workflow_file_path(), max_active_runs_per_project: 1)

    in_progress_issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Active", state: "In Progress", project_id: "proj-A"}
    todo_issue = %Issue{id: "issue-2", identifier: "MT-2", title: "Pending", state: "Todo", project_id: "proj-A"}

    state = %Orchestrator.State{}

    refute Orchestrator.should_dispatch_issue_for_test(todo_issue, state, [in_progress_issue, todo_issue])
  end
end
