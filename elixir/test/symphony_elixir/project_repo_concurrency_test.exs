defmodule SymphonyElixir.ProjectRepoConcurrencyTest do
  use SymphonyElixir.TestSupport

  defp running_entry(issue) do
    %{issue: issue, pid: self(), ref: make_ref(), identifier: issue.identifier, worker_host: nil}
  end

  defp with_running(state, issue) do
    %{state | running: Map.put(state.running, issue.id, running_entry(issue)), claimed: MapSet.put(state.claimed, issue.id)}
  end

  # Workspace root that is guaranteed to fail fast on creation (a path nested
  # inside a regular file). This lets a dispatched issue's async AgentRunner
  # task fail immediately during Workspace.create_for_issue, before any git
  # clone or codex subprocess would run, while still letting dispatch_issue
  # synchronously claim the issue and update state.running/state.claimed.
  defp unusable_workspace_root!(name) do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    blocker = Path.join(test_root, "blocker")
    File.write!(blocker, "x")

    on_exit(fn -> File.rm_rf(test_root) end)

    Path.join(blocker, "workspaces")
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

  test "choose_issues dispatches only one of two same-project Todo issues in the same poll" do
    workspace_root = unusable_workspace_root!("project-poll")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_active_runs_per_project: 1
    )

    issue1 = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}
    issue2 = %Issue{id: "issue-2", identifier: "MT-2", title: "Second", state: "Todo", project_id: "proj-A"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue1, issue2])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    result_state = Orchestrator.choose_issues_for_test([issue1, issue2], %Orchestrator.State{})

    assert Map.keys(result_state.running) == ["issue-1"]
    assert MapSet.equal?(result_state.claimed, MapSet.new(["issue-1"]))
    refute Map.has_key?(result_state.running, "issue-2")
    refute MapSet.member?(result_state.claimed, "issue-2")
  end

  test "choose_issues dispatches only one of two same-repo Todo issues in the same poll" do
    workspace_root = unusable_workspace_root!("repo-poll")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_active_runs_per_repo: 1,
      repo_url: "https://github.com/JozzyAI/spendlens"
    )

    issue1 = %Issue{id: "issue-1", identifier: "MT-1", title: "First", state: "Todo", project_id: "proj-A"}
    issue2 = %Issue{id: "issue-2", identifier: "MT-2", title: "Second", state: "Todo", project_id: "proj-B"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue1, issue2])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    result_state = Orchestrator.choose_issues_for_test([issue1, issue2], %Orchestrator.State{})

    assert Map.keys(result_state.running) == ["issue-1"]
    assert MapSet.equal?(result_state.claimed, MapSet.new(["issue-1"]))
    refute Map.has_key?(result_state.running, "issue-2")
    refute MapSet.member?(result_state.claimed, "issue-2")
  end
end
