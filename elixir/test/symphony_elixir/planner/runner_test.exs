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

  alias SymphonyElixir.Planner.{PlanExtractor, Runner}

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

        # Mirrors the real ExternalExecutor: one `:output` event per line,
        # with no trailing newline on each line's message.
        {:ok_lines, lines} ->
          on_message = Keyword.fetch!(opts, :on_message)
          Enum.each(lines, fn line -> on_message.(%{event: :output, message: line}) end)
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

  # Splits `planner_output/1`'s text into the line-by-line, no-trailing-newline
  # `:output` messages the real ExternalExecutor streams from Codex.
  defp planner_output_lines(titles) do
    titles
    |> planner_output()
    |> String.trim_trailing("\n")
    |> String.split("\n")
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

  test "executor output delivered as line-split :output events (no trailing newlines) is reassembled with newlines, preserving the fenced ```json block, and creates child issues in Backlog" do
    Application.put_env(
      :symphony_elixir,
      :fake_executor_result,
      {:ok_lines, planner_output_lines(["First child title", "Second child title"])}
    )

    issue = parent_issue()

    assert {:ok, {:created_children, identifiers}} = Runner.run(issue, recipient: self())
    assert length(identifiers) == 2

    for _ <- identifiers do
      assert_receive {:create_issue_called, attrs}
      assert attrs.state_id == "state-backlog"
      assert attrs.description =~ "## Acceptance criteria"
      assert attrs.description =~ "Open a PR, do not merge."
    end

    assert_receive {:memory_tracker_comment, "parent-1", comment}
    assert comment =~ "<!-- symphony-planner:v1 parent=parent-1 children=["

    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
    assert_receive {:planner_done, "parent-1"}
  end

  test "line-split executor output with no fenced json block still moves the parent to Human Review with an error comment and creates no children" do
    Application.put_env(
      :symphony_elixir,
      :fake_executor_result,
      {:ok_lines, ["I could not come up with a plan.", "Sorry about that."]}
    )

    issue = parent_issue()

    assert {:ok, {:failed, {:plan_extraction_failed, :no_json_block_found}}} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}

    assert_receive {:memory_tracker_comment, "parent-1", comment}
    assert comment =~ "could not finish planning"

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

  test "an approval_required executor failure moves the parent to Human Review with a non-idempotency failure comment and creates no children" do
    Application.put_env(
      :symphony_elixir,
      :fake_executor_result,
      {:error,
       {:blocked, :approval_required,
        %{"approval_id" => "appr-1", "message" => "Proceed with modifying tracked files?", "type" => "approval_required"}}}
    )

    issue = parent_issue()

    assert {:ok, {:failed, {:executor_failed, {:blocked, :approval_required, _event}}}} = Runner.run(issue, recipient: self())

    refute_receive {:create_issue_called, _attrs}

    assert_receive {:memory_tracker_comment, "parent-1", comment}
    assert comment =~ "could not finish planning"
    refute comment =~ "<!-- symphony-planner:v1"

    assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
    assert_receive {:planner_done, "parent-1"}
  end

  test "runs the plan-only Codex turn with the planner's agent (independent of external.agent=mock), no repo_url/workspace, default permission mode, and deny_pending_approvals enabled" do
    Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["Only child title"])})

    issue = parent_issue()

    assert {:ok, {:created_children, [_identifier]}} = Runner.run(issue, recipient: self())

    assert_receive {:executor_run_called, _issue, _prompt, workspace, opts}
    assert workspace == nil
    assert Keyword.get(opts, :agent) == "codex"
    assert Keyword.get(opts, :repo_url) == nil
    assert Keyword.get(opts, :permission_mode) == "default"
    assert Keyword.get(opts, :deny_pending_approvals) == true
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

  # ── Remote node/relay/token routing (binding-resolved, not local) ────────
  #
  # These mirror the live binding shape: `binding.defaults.node: "joey-pc"`,
  # `binding.nodes.joey-pc.node_id: "node_f7cedd3b6590aff9"` (plus
  # relay/token), and `binding.agents.codex.permission_mode: "unsafe-skip"`.
  # The planner must resolve `node_id`/`relay`/`token`/`encrypt` from this
  # binding (not fall back to the local node registry) while still hardcoding
  # `permission_mode: "default"` and `repo_url: nil` for its own executor
  # call, independent of `binding.agent`/`binding.permission_mode`.
  describe "remote node/relay/token routing" do
    setup do
      previous_node_id = System.get_env("SYMPHONY_NODE_ID")
      System.delete_env("SYMPHONY_NODE_ID")
      on_exit(fn -> restore_env("SYMPHONY_NODE_ID", previous_node_id) end)
      :ok
    end

    test "passes the resolved remote node id, relay, token, encrypt, repo_url nil, permission_mode default, deny_pending_approvals true, and a repo binding note" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan",
        planner_child_initial_state: "Backlog",
        planner_max_children: 10,
        planner_agent: "codex",
        binding: remote_binding_yaml()
      )

      Application.put_env(:symphony_elixir, :fake_executor_result, {:ok, planner_output(["Only child title"])})

      issue = parent_issue()

      assert {:ok, {:created_children, [_identifier]}} = Runner.run(issue, recipient: self())

      assert_receive {:executor_run_called, _issue, _prompt, workspace, opts}
      assert workspace == nil
      assert Keyword.get(opts, :agent) == "codex"
      assert Keyword.get(opts, :node) == "node_f7cedd3b6590aff9"
      assert Keyword.get(opts, :relay) == "wss://relay.example.com"
      assert Keyword.get(opts, :token) == "tok-secret-123"
      assert Keyword.get(opts, :encrypt) == true
      assert Keyword.get(opts, :repo_url) == nil
      assert Keyword.get(opts, :permission_mode) == "default"
      assert Keyword.get(opts, :deny_pending_approvals) == true

      assert_receive {:create_issue_called, attrs}
      assert attrs.description =~ "Repo binding: https://github.com/acme/widgets"
    end

    test "a binding with no configured node_id (and no SYMPHONY_NODE_ID) fails safely: parent moves to Human Review with no executor call and no children" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan",
        planner_child_initial_state: "Backlog",
        planner_max_children: 10,
        planner_agent: "codex",
        binding: remote_binding_yaml(node_id: nil)
      )

      issue = parent_issue()

      assert {:ok, {:failed, {:binding_resolution_failed, {:missing_node_id, "joey-pc"}}}} =
               Runner.run(issue, recipient: self())

      refute_receive {:executor_run_called, _issue, _prompt, _workspace, _opts}
      refute_receive {:create_issue_called, _attrs}

      assert_receive {:memory_tracker_comment, "parent-1", comment}
      assert comment =~ "could not finish planning"
      refute comment =~ "<!-- symphony-planner:v1"

      assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
      assert_receive {:planner_done, "parent-1"}
    end

    test "an agent_not_supported executor failure on the resolved remote node fails safely with no retry and no children" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        planner_enabled: true,
        planner_trigger_label: "type:plan",
        planner_child_initial_state: "Backlog",
        planner_max_children: 10,
        planner_agent: "codex",
        binding: remote_binding_yaml()
      )

      Application.put_env(
        :symphony_elixir,
        :fake_executor_result,
        {:error,
         {:start_failed, 1,
          ~s({"error":true,"code":"agent_not_supported","message":"Node node_f7cedd3b6590aff9 does not support agent codex"}\n)}}
      )

      issue = parent_issue()

      assert {:ok, {:failed, {:executor_failed, {:start_failed, 1, _output}}}} = Runner.run(issue, recipient: self())

      refute_receive {:create_issue_called, _attrs}

      assert_receive {:memory_tracker_comment, "parent-1", comment}
      assert comment =~ "could not finish planning"

      assert_receive {:memory_tracker_state_update, "parent-1", "Human Review"}
      assert_receive {:planner_done, "parent-1"}
    end
  end

  describe "join_output_lines/1" do
    test "rejoins line-split output with newlines so PlanExtractor can find the fenced json block" do
      lines = ["intro", "```json", ~s({"children": []}), "```"]

      output = Runner.join_output_lines(lines)

      assert output == "intro\n```json\n{\"children\": []}\n```"
      assert {:ok, %{"children" => []}} = PlanExtractor.extract_json_block(output)
    end
  end

  # Mirrors the live `binding:` shape used in WORKFLOW.md: `defaults.node`
  # points at a node entry that carries `node_id`/`relay`/`token` (the
  # relay-paired remote node), and `agents.codex.permission_mode` is
  # deliberately *not* "default" so tests can confirm the planner doesn't
  # pick it up.
  defp remote_binding_yaml(opts \\ []) do
    node_id_line =
      case Keyword.get(opts, :node_id, "node_f7cedd3b6590aff9") do
        nil -> []
        node_id -> ["      node_id: \"#{node_id}\""]
      end

    [
      "binding:",
      "  defaults:",
      "    repo: \"https://github.com/acme/widgets\"",
      "    node: \"joey-pc\"",
      "    agent: \"codex\"",
      "    encrypt: true",
      "  nodes:",
      "    joey-pc:"
    ]
    |> Kernel.++(node_id_line)
    |> Kernel.++([
      "      relay: \"wss://relay.example.com\"",
      "      token: \"tok-secret-123\"",
      "      allowed_agents:",
      "        - mock",
      "        - claude-code",
      "        - codex",
      "  agents:",
      "    codex:",
      "      permission_mode: \"unsafe-skip\""
    ])
    |> Enum.join("\n")
  end
end
