defmodule SymphonyElixir.Linear.PlannerCapabilitiesTest do
  @moduledoc """
  Linear client/adapter write and read capabilities needed by the future
  Planner (issue creation, label lookup, comment reads, child issue reads).

  Every test here either injects `request_fun` (so `Client.graphql/3` never
  calls `Req.post`) or swaps `:linear_client_module` for a fake module, so no
  test ever performs a real Linear API request.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter

  defmodule FakePlannerLinearClient do
    def create_issue(attrs) do
      send(self(), {:create_issue_called, attrs})
      {:ok, %{id: "new-issue", identifier: "JOZ-200", title: attrs.title, url: "https://linear.app/issue/JOZ-200", state: "Backlog"}}
    end

    def fetch_team_labels(team_id) do
      send(self(), {:fetch_team_labels_called, team_id})
      {:ok, [%{id: "label-1", name: "Planner"}]}
    end

    def resolve_team_label_id(team_id, label_name) do
      send(self(), {:resolve_team_label_id_called, team_id, label_name})
      {:ok, "label-1"}
    end

    def fetch_issue_comments(issue_id) do
      send(self(), {:fetch_issue_comments_called, issue_id})
      {:ok, [%{id: "comment-1", body: "<!-- symphony-planner:v1 -->", created_at: nil}]}
    end

    def fetch_issue_children(issue_id) do
      send(self(), {:fetch_issue_children_called, issue_id})
      {:ok, [%{id: "child-1", identifier: "JOZ-101", title: "Child", state: "Todo"}]}
    end
  end

  setup do
    previous_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      case previous_client_module do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        module -> Application.put_env(:symphony_elixir, :linear_client_module, module)
      end
    end)

    :ok
  end

  defp issue_create_success_body(attrs \\ %{}) do
    issue =
      Map.merge(
        %{
          "id" => "issue-1",
          "identifier" => "JOZ-100",
          "title" => "Child issue",
          "url" => "https://linear.app/issue/JOZ-100",
          "state" => %{"name" => "Backlog"}
        },
        attrs
      )

    %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}
  end

  defp fake_request_fun(body) do
    fn payload, _headers ->
      send(self(), {:graphql_payload, payload})
      {:ok, %{status: 200, body: body}}
    end
  end

  defp failing_request_fun do
    fn _payload, _headers -> raise "request_fun should not be called" end
  end

  defp team_labels_body(label_nodes) do
    %{"data" => %{"team" => %{"id" => "team-1", "labels" => %{"nodes" => label_nodes}}}}
  end

  # ---------------------------------------------------------------------------
  # Client.create_issue/2 — issueCreate mutation
  # ---------------------------------------------------------------------------

  describe "Client.create_issue/2" do
    test "sends teamId and title and normalizes the created issue" do
      request_fun = fake_request_fun(issue_create_success_body())

      assert {:ok, %{id: "issue-1", identifier: "JOZ-100", title: "Child issue", url: url, state: "Backlog"}} =
               Client.create_issue(%{team_id: "team-1", title: "Child issue"}, request_fun: request_fun)

      assert url == "https://linear.app/issue/JOZ-100"

      assert_receive {:graphql_payload, payload}
      assert payload["query"] =~ "issueCreate"
      assert payload["variables"]["input"] == %{"teamId" => "team-1", "title" => "Child issue"}
    end

    test "includes projectId/parentId/labelIds/stateId when provided" do
      request_fun = fake_request_fun(issue_create_success_body())

      attrs = %{
        team_id: "team-1",
        title: "Child issue",
        description: "Body",
        project_id: "project-1",
        parent_id: "parent-1",
        label_ids: ["label-1", "label-2"],
        state_id: "state-1"
      }

      assert {:ok, _issue} = Client.create_issue(attrs, request_fun: request_fun)

      assert_receive {:graphql_payload, payload}

      assert payload["variables"]["input"] == %{
               "teamId" => "team-1",
               "title" => "Child issue",
               "description" => "Body",
               "projectId" => "project-1",
               "parentId" => "parent-1",
               "labelIds" => ["label-1", "label-2"],
               "stateId" => "state-1"
             }
    end

    test "omits optional fields entirely when not provided" do
      request_fun = fake_request_fun(issue_create_success_body())

      assert {:ok, _issue} = Client.create_issue(%{team_id: "team-1", title: "Minimal"}, request_fun: request_fun)

      assert_receive {:graphql_payload, payload}
      refute Map.has_key?(payload["variables"]["input"], "description")
      refute Map.has_key?(payload["variables"]["input"], "projectId")
      refute Map.has_key?(payload["variables"]["input"], "parentId")
      refute Map.has_key?(payload["variables"]["input"], "labelIds")
      refute Map.has_key?(payload["variables"]["input"], "stateId")
    end

    test "returns an error without calling the request function when team_id is missing" do
      assert {:error, :missing_team_id} = Client.create_issue(%{title: "Missing team"}, request_fun: failing_request_fun())
    end

    test "returns an error without calling the request function when title is missing" do
      assert {:error, :missing_title} =
               Client.create_issue(%{team_id: "team-1"}, request_fun: failing_request_fun())
    end

    test "returns :issue_create_failed when the mutation reports success: false" do
      request_fun = fake_request_fun(%{"data" => %{"issueCreate" => %{"success" => false, "issue" => nil}}})

      assert {:error, :issue_create_failed} =
               Client.create_issue(%{team_id: "team-1", title: "Child issue"}, request_fun: request_fun)
    end

    test "returns linear_graphql_errors when the response contains errors" do
      request_fun = fake_request_fun(%{"errors" => [%{"message" => "boom"}]})

      assert {:error, {:linear_graphql_errors, [%{"message" => "boom"}]}} =
               Client.create_issue(%{team_id: "team-1", title: "Child issue"}, request_fun: request_fun)
    end
  end

  # ---------------------------------------------------------------------------
  # Client.fetch_team_labels/2 and Client.resolve_team_label_id/3
  # ---------------------------------------------------------------------------

  describe "Client.fetch_team_labels/2 and Client.resolve_team_label_id/3" do
    test "fetch_team_labels returns id/name pairs for the team" do
      request_fun =
        fake_request_fun(team_labels_body([%{"id" => "label-1", "name" => "Bug"}, %{"id" => "label-2", "name" => "Planner"}]))

      assert {:ok, labels} = Client.fetch_team_labels("team-1", request_fun: request_fun)
      assert labels == [%{id: "label-1", name: "Bug"}, %{id: "label-2", name: "Planner"}]

      assert_receive {:graphql_payload, payload}
      assert payload["query"] =~ "SymphonyTeamLabels"
      assert payload["variables"] == %{"teamId" => "team-1"}
    end

    test "resolve_team_label_id resolves a label name to its id, case-insensitively" do
      request_fun = fake_request_fun(team_labels_body([%{"id" => "label-1", "name" => "Planner"}]))

      assert {:ok, "label-1"} = Client.resolve_team_label_id("team-1", "planner", request_fun: request_fun)
    end

    test "resolve_team_label_id returns :label_not_found when no label matches" do
      request_fun = fake_request_fun(team_labels_body([%{"id" => "label-1", "name" => "Bug"}]))

      assert {:error, :label_not_found} = Client.resolve_team_label_id("team-1", "Planner", request_fun: request_fun)
    end

    test "fetch_team_labels returns an error when the team is not found" do
      request_fun = fake_request_fun(%{"data" => %{"team" => nil}})

      assert {:error, :linear_team_not_found} = Client.fetch_team_labels("team-1", request_fun: request_fun)
    end
  end

  # ---------------------------------------------------------------------------
  # Client.fetch_issue_comments/2
  # ---------------------------------------------------------------------------

  describe "Client.fetch_issue_comments/2" do
    test "returns comment ids/bodies/created_at" do
      body = %{
        "data" => %{
          "issue" => %{
            "id" => "issue-1",
            "comments" => %{
              "nodes" => [
                %{"id" => "comment-1", "body" => "<!-- symphony-planner:v1 batch=1 -->", "createdAt" => "2026-01-01T00:00:00.000Z"},
                %{"id" => "comment-2", "body" => "A human note", "createdAt" => "2026-01-02T00:00:00.000Z"}
              ]
            }
          }
        }
      }

      request_fun = fake_request_fun(body)

      assert {:ok, comments} = Client.fetch_issue_comments("issue-1", request_fun: request_fun)

      assert [
               %{id: "comment-1", body: "<!-- symphony-planner:v1 batch=1 -->", created_at: %DateTime{}},
               %{id: "comment-2", body: "A human note", created_at: %DateTime{}}
             ] = comments

      assert_receive {:graphql_payload, payload}
      assert payload["query"] =~ "SymphonyIssueComments"
      assert payload["variables"] == %{"issueId" => "issue-1"}
    end

    test "returns linear_issue_not_found when the issue does not exist" do
      request_fun = fake_request_fun(%{"data" => %{"issue" => nil}})

      assert {:error, :linear_issue_not_found} = Client.fetch_issue_comments("missing-issue", request_fun: request_fun)
    end
  end

  # ---------------------------------------------------------------------------
  # Client.fetch_issue_children/2
  # ---------------------------------------------------------------------------

  describe "Client.fetch_issue_children/2" do
    test "returns child issue identifiers/titles/states" do
      body = %{
        "data" => %{
          "issue" => %{
            "id" => "parent-1",
            "children" => %{
              "nodes" => [
                %{"id" => "child-1", "identifier" => "JOZ-101", "title" => "Child one", "state" => %{"name" => "Todo"}},
                %{"id" => "child-2", "identifier" => "JOZ-102", "title" => "Child two", "state" => %{"name" => "In Progress"}}
              ]
            }
          }
        }
      }

      request_fun = fake_request_fun(body)

      assert {:ok, children} = Client.fetch_issue_children("parent-1", request_fun: request_fun)

      assert children == [
               %{id: "child-1", identifier: "JOZ-101", title: "Child one", state: "Todo"},
               %{id: "child-2", identifier: "JOZ-102", title: "Child two", state: "In Progress"}
             ]

      assert_receive {:graphql_payload, payload}
      assert payload["query"] =~ "SymphonyIssueChildren"
      assert payload["variables"] == %{"issueId" => "parent-1"}
    end

    test "returns an empty list when the issue has no children" do
      body = %{"data" => %{"issue" => %{"id" => "parent-1", "children" => %{"nodes" => []}}}}
      request_fun = fake_request_fun(body)

      assert {:ok, []} = Client.fetch_issue_children("parent-1", request_fun: request_fun)
    end
  end

  # ---------------------------------------------------------------------------
  # Adapter delegation via the :linear_client_module override
  # ---------------------------------------------------------------------------

  describe "Adapter delegates planner write/read capabilities via :linear_client_module" do
    test "create_issue, label lookup, comments, and children all delegate to the configured client module" do
      Application.put_env(:symphony_elixir, :linear_client_module, FakePlannerLinearClient)

      assert {:ok, %{identifier: "JOZ-200", title: "New child"}} =
               Adapter.create_issue(%{team_id: "team-1", title: "New child"})

      assert_receive {:create_issue_called, %{team_id: "team-1", title: "New child"}}

      assert {:ok, [%{id: "label-1", name: "Planner"}]} = Adapter.fetch_team_labels("team-1")
      assert_receive {:fetch_team_labels_called, "team-1"}

      assert {:ok, "label-1"} = Adapter.resolve_team_label_id("team-1", "Planner")
      assert_receive {:resolve_team_label_id_called, "team-1", "Planner"}

      assert {:ok, [%{id: "comment-1", body: "<!-- symphony-planner:v1 -->"}]} = Adapter.fetch_issue_comments("issue-1")
      assert_receive {:fetch_issue_comments_called, "issue-1"}

      assert {:ok, [%{identifier: "JOZ-101"}]} = Adapter.fetch_issue_children("parent-1")
      assert_receive {:fetch_issue_children_called, "parent-1"}
    end
  end

  # ---------------------------------------------------------------------------
  # Issue struct — team_id/parent_id from the polling queries
  # ---------------------------------------------------------------------------

  describe "Issue normalization includes team_id and parent_id" do
    test "normalize_issue_for_test populates team_id and parent_id when present" do
      raw_issue = %{
        "id" => "issue-1",
        "identifier" => "JOZ-1",
        "title" => "Parent issue",
        "description" => nil,
        "priority" => nil,
        "state" => %{"name" => "In Progress"},
        "branchName" => nil,
        "url" => nil,
        "assignee" => nil,
        "team" => %{"id" => "team-1"},
        "parent" => %{"id" => "parent-1"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }

      issue = Client.normalize_issue_for_test(raw_issue)

      assert issue.team_id == "team-1"
      assert issue.parent_id == "parent-1"
    end

    test "normalize_issue_for_test leaves team_id and parent_id nil when absent" do
      raw_issue = %{
        "id" => "issue-1",
        "identifier" => "JOZ-1",
        "title" => "Root issue",
        "description" => nil,
        "priority" => nil,
        "state" => %{"name" => "In Progress"},
        "branchName" => nil,
        "url" => nil,
        "assignee" => nil,
        "team" => %{"id" => "team-1"},
        "parent" => nil,
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }

      issue = Client.normalize_issue_for_test(raw_issue)

      assert issue.team_id == "team-1"
      assert issue.parent_id == nil
    end
  end
end
