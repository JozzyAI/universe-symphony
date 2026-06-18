defmodule SymphonyElixir.Planner.AutoMergeTest do
  @moduledoc """
  Tests for `SymphonyElixir.Planner.AutoMerge`.

  Uses `tracker.kind: "memory"` so Tracker.fetch_issues_by_states and
  Tracker.create_comment/update_issue_state go to Tracker.Memory.

  `Adapter.fetch_issue_comments/1` is routed through `:linear_client_module`
  override. GitHub operations are routed through `:github_client_module`.

  Config is passed directly to `scan_and_merge/1` — no YAML roundtrip needed
  for the auto_merge settings, only the tracker kind needs the workflow file.
  """

  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema.{AutoMerge, Planner}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Planner.AutoMerge, as: AutoMergeMod

  @mirror_social_repo "https://github.com/JozzyAI/mirror_social"
  @pr_url "#{@mirror_social_repo}/pull/5"

  # ─── Fake clients ──────────────────────────────────────────────────────────

  defmodule FakeLinearClient do
    def fetch_issue_comments(issue_id) do
      data = Application.get_env(:symphony_elixir, :fake_linear_data, %{})
      {:ok, get_in(data, [:comments, issue_id]) || []}
    end

    def fetch_issue_children(issue_id) do
      data = Application.get_env(:symphony_elixir, :fake_linear_data, %{})
      {:ok, get_in(data, [:children, issue_id]) || []}
    end
    def graphql(_q, _v, _opts \\ []), do: {:error, :not_implemented}
    def create_issue(_attrs), do: {:error, :not_implemented}
    def fetch_team_states(_team_id), do: {:ok, []}
    def resolve_team_state_id(_team_id, _state), do: {:error, :not_implemented}
    def fetch_team_labels(_team_id), do: {:ok, []}
    def resolve_team_label_id(_team_id, _label), do: {:error, :not_implemented}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}
  end

  defmodule FakeGitHubClient do
    def get_pr(pr_url) do
      data = Application.get_env(:symphony_elixir, :fake_github_data, %{})
      case Map.get(data, pr_url) do
        nil -> {:error, {:gh_error, 1, "PR not found"}}
        result -> result
      end
    end

    def merge_pr(pr_url, _method, _delete_branch) do
      data = Application.get_env(:symphony_elixir, :fake_github_merge_result, %{})
      Map.get(data, pr_url, :ok)
    end
  end

  # ─── Setup ─────────────────────────────────────────────────────────────────

  setup do
    workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

    if workflow_path do
      write_workflow_file!(workflow_path, tracker_kind: "memory")
    end

    prev_linear = Application.get_env(:symphony_elixir, :linear_client_module)
    prev_github = Application.get_env(:symphony_elixir, :github_client_module)

    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      case prev_linear do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        v -> Application.put_env(:symphony_elixir, :linear_client_module, v)
      end

      case prev_github do
        nil -> Application.delete_env(:symphony_elixir, :github_client_module)
        v -> Application.put_env(:symphony_elixir, :github_client_module, v)
      end

      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :fake_linear_data)
      Application.delete_env(:symphony_elixir, :fake_github_data)
      Application.delete_env(:symphony_elixir, :fake_github_merge_result)
    end)

    :ok
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp enabled_config(overrides \\ []) do
    am =
      struct(
        AutoMerge,
        Keyword.merge(
          [
            enabled: true,
            merge_method: "squash",
            delete_branch: true,
            require_checks: true,
            allow_no_checks: false,
            allowed_repos: [@mirror_social_repo]
          ],
          overrides
        )
      )

    %{auto_merge: am, planner: %Planner{trigger_label: "type:plan"}}
  end

  defp disabled_config, do: %{auto_merge: %AutoMerge{enabled: false}, planner: %Planner{trigger_label: "type:plan"}}

  defp child_issue(id, overrides \\ []) do
    struct(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: "JOZ-31",
          title: "Implement feature",
          description: "Some task\n\nAuto merge: true",
          state: "Human Review",
          parent_id: "parent-uuid-123",
          labels: ["agent:claude-code", "repo:mirror_social"],
          project_description: nil
        ],
        overrides
      )
    )
  end

  defp pr_comment(url \\ @pr_url) do
    %{id: "comment-pr", body: "Symphony: PR ready for review — #{url}"}
  end

  defp set_issues(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
  end

  defp set_comments(issue_id, comments) do
    current = Application.get_env(:symphony_elixir, :fake_linear_data, %{})
    updated = Map.update(current, :comments, %{issue_id => comments}, &Map.put(&1, issue_id, comments))
    Application.put_env(:symphony_elixir, :fake_linear_data, updated)
  end

  defp set_pr(url, result) do
    current = Application.get_env(:symphony_elixir, :fake_github_data, %{})
    Application.put_env(:symphony_elixir, :fake_github_data, Map.put(current, url, result))
  end

  defp set_merge_result(url, result) do
    current = Application.get_env(:symphony_elixir, :fake_github_merge_result, %{})
    Application.put_env(:symphony_elixir, :fake_github_merge_result, Map.put(current, url, result))
  end

  defp open_mergeable_pr(checks_status \\ :passed) do
    {:ok, %{state: "OPEN", mergeable: "MERGEABLE", checks_status: checks_status, head_ref: "joz-31-feature", base_ref: "main"}}
  end

  # ─── 1. auto_merge disabled globally ──────────────────────────────────────

  describe "global enabled flag" do
    test "auto_merge disabled globally → no merge" do
      issue = child_issue("issue-am-1")
      set_issues([issue])
      set_comments("issue-am-1", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(disabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end
  end

  # ─── 2. Per-issue opt-in ──────────────────────────────────────────────────

  describe "per-issue opt-in" do
    test "issue without Auto merge: true in description → no merge" do
      issue = child_issue("issue-am-2", description: "Some task without opt-in")
      set_issues([issue])
      set_comments("issue-am-2", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end

    test "issue with Auto merge: false in description → no merge" do
      issue = child_issue("issue-am-2b", description: "Some task\n\nAuto merge: false")
      set_issues([issue])
      set_comments("issue-am-2b", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end
  end

  # ─── 3. Parent type:plan issue ────────────────────────────────────────────

  describe "parent plan issues" do
    test "parent type:plan issue → no merge" do
      parent = child_issue("issue-am-3",
        description: "Auto merge: true",
        parent_id: nil,
        labels: ["type:plan"]
      )
      set_issues([parent])
      set_comments("issue-am-3", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end

    test "issue without parent_id → no merge (not a child issue)" do
      issue = child_issue("issue-am-3b", parent_id: nil, labels: [])
      set_issues([issue])
      set_comments("issue-am-3b", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end
  end

  # ─── 4. Repo not allowlisted ──────────────────────────────────────────────

  describe "repo allowlist" do
    test "repo not allowlisted (allowed_repos empty) → no merge, posts skip comment" do
      issue = child_issue("issue-am-4")
      set_issues([issue])
      set_comments("issue-am-4", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config(allowed_repos: []))

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-am-4", comment}
      assert comment =~ "auto-merge skipped"
      assert comment =~ "allowed_repos"
    end

    # ─── 5. PR repo mismatch ─────────────────────────────────────────────────

    test "PR repo mismatch (allowed_repos has mirror_social, PR is for fin_bot) → no merge" do
      fin_bot_pr = "https://github.com/JozzyAI/fin_bot/pull/10"
      issue = child_issue("issue-am-5")
      set_issues([issue])
      set_comments("issue-am-5", [pr_comment(fin_bot_pr)])
      set_pr(fin_bot_pr, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-am-5", comment}
      assert comment =~ "auto-merge skipped"
    end
  end

  # ─── 6. Checks pending ────────────────────────────────────────────────────

  describe "check status" do
    test "checks pending → no merge, no skip comment" do
      issue = child_issue("issue-am-6")
      set_issues([issue])
      set_comments("issue-am-6", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr(:pending))

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end

    # ─── 7. Checks failed ─────────────────────────────────────────────────────

    test "checks failed → no merge, posts skip comment" do
      issue = child_issue("issue-am-7")
      set_issues([issue])
      set_comments("issue-am-7", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr(:failed))

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-am-7", comment}
      assert comment =~ "auto-merge skipped"
      assert comment =~ "checks failed"
    end

    # ─── 8. No checks + allow_no_checks false ─────────────────────────────────

    test "no checks + allow_no_checks false → no merge, posts skip comment" do
      issue = child_issue("issue-am-8")
      set_issues([issue])
      set_comments("issue-am-8", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr(:no_checks))

      :ok = AutoMergeMod.scan_and_merge(enabled_config(allow_no_checks: false, require_checks: true))

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-am-8", comment}
      assert comment =~ "auto-merge skipped"
      assert comment =~ "no status checks"
    end

    # ─── 9. No checks + allow_no_checks true ──────────────────────────────────

    test "no checks + allow_no_checks true → merge proceeds" do
      issue = child_issue("issue-am-9")
      set_issues([issue])
      set_comments("issue-am-9", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr(:no_checks))

      :ok = AutoMergeMod.scan_and_merge(enabled_config(allow_no_checks: true))

      assert_received {:memory_tracker_state_update, "issue-am-9", "Done"}
    end
  end

  # ─── 10. Mergeable PR + checks passed → merge ─────────────────────────────

  describe "successful merge" do
    test "mergeable PR with checks passed → merge executes" do
      issue = child_issue("issue-am-10")
      set_issues([issue])
      set_comments("issue-am-10", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      assert_received {:memory_tracker_state_update, "issue-am-10", "Done"}
    end

    # ─── 11. Successful merge moves issue to Done ──────────────────────────────

    test "successful merge posts idempotency marker comment and moves to Done" do
      issue = child_issue("issue-am-11")
      set_issues([issue])
      set_comments("issue-am-11", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      assert_received {:memory_tracker_comment, "issue-am-11", marker}
      assert marker =~ "symphony:auto-merge:v1"
      assert marker =~ "issue=issue-am-11"
      assert marker =~ "status=merged"

      assert_received {:memory_tracker_state_update, "issue-am-11", "Done"}
    end

    # ─── 12. Successful merge triggers ChildPromoter path ─────────────────────

    test "successful merge sets Done state so ChildPromoter can promote next sibling" do
      alias SymphonyElixir.Planner.ChildPromoter

      parent_id = "parent-am-12"
      issue = child_issue("issue-am-12", identifier: "JOZ-31")
      next_issue_id = "issue-am-12-next"

      set_issues([issue])
      set_comments("issue-am-12", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      # Run auto-merge (moves JOZ-31 to Done via memory tracker)
      :ok = AutoMergeMod.scan_and_merge(enabled_config())
      assert_received {:memory_tracker_state_update, "issue-am-12", "Done"}

      # Verify ChildPromoter sees the Done state (it reads from Adapter, not Tracker.Memory,
      # but verifying the Done update was issued confirms the ChildPromoter trigger path works)
      planner_marker = "<!-- symphony-planner:v1 parent=#{parent_id} children=[JOZ-31,JOZ-32] -->"

      Application.put_env(:symphony_elixir, :fake_linear_data, %{
        comments: %{parent_id => [%{id: "c1", body: planner_marker}]},
        children: %{
          parent_id => [
            %{id: "issue-am-12", identifier: "JOZ-31", title: "Feature", state: "Done"},
            %{id: next_issue_id, identifier: "JOZ-32", title: "Next", state: "Backlog"}
          ]
        }
      })

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: parent_id, identifier: "JOZ-30", state: "Human Review", labels: ["type:plan"]}
      ])

      assert :promoted = ChildPromoter.maybe_promote(parent_id)
      assert_received {:memory_tracker_state_update, ^next_issue_id, "Todo"}
    end
  end

  # ─── 13. Merge failure leaves issue in Human Review ───────────────────────

  describe "merge failure" do
    test "gh merge failure leaves issue in Human Review (no Done state update)" do
      issue = child_issue("issue-am-13")
      set_issues([issue])
      set_comments("issue-am-13", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())
      set_merge_result(@pr_url, {:error, {:gh_merge_failed, 1, "merge conflict"}})

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end
  end

  # ─── 14. Idempotency marker prevents duplicate merges ─────────────────────

  describe "idempotency" do
    test "existing auto-merge marker prevents re-merge" do
      issue = child_issue("issue-am-14")
      idempotency_marker = "<!-- symphony:auto-merge:v1 issue=issue-am-14 pr=#{@pr_url} status=merged -->"

      set_issues([issue])
      set_comments("issue-am-14", [pr_comment(), %{id: "c-marker", body: idempotency_marker}])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end

    test "two scan_and_merge calls on the same issue only merge once" do
      issue = child_issue("issue-am-14b")
      set_issues([issue])
      set_comments("issue-am-14b", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())
      assert_received {:memory_tracker_state_update, "issue-am-14b", "Done"}
      assert_received {:memory_tracker_comment, "issue-am-14b", marker}
      assert marker =~ "status=merged"

      # Second call: add the marker to comments so the idempotency check fires
      set_comments("issue-am-14b", [pr_comment(), %{id: "m", body: marker}])
      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end
  end

  # ─── 15. No secrets printed ───────────────────────────────────────────────

  describe "security" do
    test "no secrets or tokens are printed to logs during a successful merge" do
      issue = child_issue("issue-am-15")
      set_issues([issue])
      set_comments("issue-am-15", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      log =
        capture_log(fn ->
          :ok = AutoMergeMod.scan_and_merge(enabled_config())
        end)

      # Verify no secret patterns appear in log output
      refute log =~ "lin_api_"
      refute log =~ "ghp_"
      refute log =~ "$VIBE_RELAY_TOKEN"
      refute log =~ "Bearer "
    end
  end

  # ─── Project-level auto_merge defaults ────────────────────────────────────

  describe "project-level auto_merge resolution" do
    test "project auto_merge true + issue description has no Auto merge line → eligible" do
      # issue description does NOT have 'Auto merge:' → fall back to project_description
      issue = child_issue("issue-pm-1",
        description: "Implement feature X.\n\nSome details.",
        project_description: "For this project, auto-merge child PRs after checks pass."
      )
      set_issues([issue])
      set_comments("issue-pm-1", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      assert_received {:memory_tracker_state_update, "issue-pm-1", "Done"}
    end

    test "project auto_merge true + issue explicitly false → not eligible" do
      issue = child_issue("issue-pm-2",
        description: "Implement feature.\n\n<!-- symphony:inherited-project-memory:v1:start -->\nAuto merge: false\n<!-- symphony:inherited-project-memory:v1:end -->",
        project_description: "auto-merge child PRs after checks pass"
      )
      set_issues([issue])
      set_comments("issue-pm-2", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end

    test "project auto_merge false + issue explicitly true → eligible" do
      issue = child_issue("issue-pm-3",
        description: "Implement feature.\n\nAuto merge: true",
        project_description: "do not auto merge anything"
      )
      set_issues([issue])
      set_comments("issue-pm-3", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      assert_received {:memory_tracker_state_update, "issue-pm-3", "Done"}
    end

    test "global enabled false overrides project true" do
      issue = child_issue("issue-pm-4",
        description: "Some task.",
        project_description: "auto-merge child PRs after checks pass"
      )
      set_issues([issue])
      set_comments("issue-pm-4", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(disabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end

    test "repo not allowlisted overrides project true" do
      issue = child_issue("issue-pm-5",
        description: "Some task.",
        project_description: "auto-merge child PRs after checks pass"
      )
      set_issues([issue])
      set_comments("issue-pm-5", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config(allowed_repos: []))

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-pm-5", _skip_comment}
    end

    test "type:plan parent issue never auto-merges even if project says true" do
      plan_issue = child_issue("issue-pm-6",
        labels: ["type:plan"],
        parent_id: nil,
        project_description: "auto-merge child PRs after checks pass"
      )
      set_issues([plan_issue])
      set_comments("issue-pm-6", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
    end
  end

  # ─── Exact repo matching ──────────────────────────────────────────────────

  describe "exact repo matching" do
    test "PR URL for allowed repo merges successfully" do
      issue = child_issue("issue-exact-1")
      set_issues([issue])
      set_comments("issue-exact-1", [pr_comment()])
      set_pr(@pr_url, open_mergeable_pr())

      # @mirror_social_repo is exactly in allowed_repos
      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      assert_received {:memory_tracker_state_update, "issue-exact-1", "Done"}
    end

    test "PR URL with trailing path after repo (prefix) does not bypass exact match" do
      # allowed_repos has mirror_social; PR is for mirror_social_extra (a different repo)
      wrong_repo_pr = "https://github.com/JozzyAI/mirror_social_extra/pull/1"
      issue = child_issue("issue-exact-2")
      set_issues([issue])
      set_comments("issue-exact-2", [pr_comment(wrong_repo_pr)])
      set_pr(wrong_repo_pr, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-exact-2", _skip_comment}
    end

    test "fin_bot PR is rejected when only mirror_social is allowlisted" do
      fin_bot_pr = "https://github.com/JozzyAI/fin_bot/pull/99"
      issue = child_issue("issue-exact-3")
      set_issues([issue])
      set_comments("issue-exact-3", [pr_comment(fin_bot_pr)])
      set_pr(fin_bot_pr, open_mergeable_pr())

      :ok = AutoMergeMod.scan_and_merge(enabled_config())

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-exact-3", _skip_comment}
    end
  end

  # ─── Description Normalizer phrase tests (integration) ───────────────────

  describe "description normalizer phrase detection for auto_merge" do
    alias SymphonyElixir.Planner.DescriptionNormalizer

    defp norm(desc), do: DescriptionNormalizer.normalize(desc, "Test", %{planner: nil, binding: nil})

    test "phrase 'auto-merge child PRs after checks pass' normalizes to auto_merge true" do
      result = norm("For this project, auto-merge child PRs after checks pass.")
      assert result.auto_merge == true
    end

    test "phrase 'do not auto merge' normalizes to auto_merge false" do
      result = norm("Do not auto merge this project.")
      assert result.auto_merge == false
    end

    test "nil result when no auto_merge phrase present" do
      result = norm("This project builds a feature.")
      assert result.auto_merge == nil
    end

    test "child inherited memory includes Auto merge: true when parent normalizes to auto_merge true" do
      alias SymphonyElixir.Planner.ProjectMemory

      binding = %{
        repo_mode: nil, repo_name: nil, repo_owner: "JozzyAI",
        repo_url: "https://github.com/JozzyAI/mirror_social",
        repo_status: :resolved, node: "joey-pc", node_id: "node_abc",
        agent: "claude-code", auto_merge: true, human_review_required: true,
        tech_stack: [], open_questions: [], inherit_binding_to_children: true
      }

      block = ProjectMemory.build_inherited_block(binding, "JOZ-30")
      assert block =~ "Auto merge: true"
    end

    test "child inherited memory omits Auto merge line when parent auto_merge is nil" do
      alias SymphonyElixir.Planner.ProjectMemory

      binding = %{
        repo_mode: nil, repo_name: nil, repo_owner: "JozzyAI",
        repo_url: "https://github.com/JozzyAI/mirror_social",
        repo_status: :resolved, node: "joey-pc", node_id: "node_abc",
        agent: "claude-code", auto_merge: nil, human_review_required: true,
        tech_stack: [], open_questions: [], inherit_binding_to_children: true
      }

      block = ProjectMemory.build_inherited_block(binding, "JOZ-30")
      refute block =~ "Auto merge:"
    end
  end
end
