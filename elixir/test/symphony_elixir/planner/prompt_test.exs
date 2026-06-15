defmodule SymphonyElixir.Planner.PromptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Planner.Prompt

  describe "build/1" do
    test "renders parent issue identifier, title, and description" do
      prompt =
        Prompt.build(%{
          parent_identifier: "JOZ-21",
          parent_title: "Decompose onboarding flow",
          parent_description: "We need to split the onboarding flow into smaller pieces."
        })

      assert prompt =~ "Identifier: JOZ-21"
      assert prompt =~ "Title: Decompose onboarding flow"
      assert prompt =~ "We need to split the onboarding flow into smaller pieces."
    end

    test "renders 'No description provided.' when the parent description is blank" do
      prompt = Prompt.build(%{parent_identifier: "JOZ-21", parent_title: "Title only", parent_description: nil})

      assert prompt =~ "No description provided."

      prompt_blank =
        Prompt.build(%{parent_identifier: "JOZ-21", parent_title: "Title only", parent_description: "   "})

      assert prompt_blank =~ "No description provided."
    end

    test "renders project name, id, description, and labels when provided" do
      prompt =
        Prompt.build(%{
          parent_identifier: "JOZ-21",
          parent_title: "Parent",
          parent_description: "Parent description",
          project_name: "SpendLens",
          project_id: "proj-123",
          project_description: "Expense tracking product.",
          project_labels: ["backend", "frontend"]
        })

      assert prompt =~ "## Project context"
      assert prompt =~ "Project: SpendLens (proj-123)"
      assert prompt =~ "Expense tracking product."
      assert prompt =~ "Labels: backend, frontend"
    end

    test "omits the project section entirely when no project context is given" do
      prompt =
        Prompt.build(%{
          parent_identifier: "JOZ-21",
          parent_title: "Parent",
          parent_description: "Parent description"
        })

      refute prompt =~ "## Project context"
    end

    test "renders the repo URL when provided, and omits the repository section otherwise" do
      with_repo =
        Prompt.build(%{
          parent_identifier: "JOZ-21",
          parent_title: "Parent",
          parent_description: "Parent description",
          repo_url: "https://github.com/JozzyAI/universe-symphony"
        })

      assert with_repo =~ "## Repository"
      assert with_repo =~ "Repo URL: https://github.com/JozzyAI/universe-symphony"

      without_repo =
        Prompt.build(%{
          parent_identifier: "JOZ-21",
          parent_title: "Parent",
          parent_description: "Parent description"
        })

      refute without_repo =~ "## Repository"
    end

    test "renders an optional repo file tree under the repository section" do
      prompt =
        Prompt.build(%{
          parent_identifier: "JOZ-21",
          parent_title: "Parent",
          parent_description: "Parent description",
          repo_url: "https://github.com/JozzyAI/universe-symphony",
          repo_tree: "lib/\n  symphony_elixir/\ntest/"
        })

      assert prompt =~ "## Repository"
      assert prompt =~ "File tree:"
      assert prompt =~ "lib/\n  symphony_elixir/\ntest/"
    end

    test "includes the 'Open a PR, do not merge.' instruction" do
      prompt = Prompt.build(%{parent_identifier: "JOZ-21", parent_title: "Parent", parent_description: "Desc"})

      assert prompt =~ "Open a PR, do not merge."
    end

    test "instructs the planner to output only a final fenced JSON block with the expected shape" do
      prompt = Prompt.build(%{parent_identifier: "JOZ-21", parent_title: "Parent", parent_description: "Desc"})

      assert prompt =~ "5 to 10 child issues"
      assert prompt =~ "manual_review"
      assert prompt =~ "Do not output any prose"
      assert prompt =~ "```json"
      assert prompt =~ "\"children\""
      assert prompt =~ "\"acceptance_criteria\""
      assert prompt =~ "\"execution_mode\": \"manual_review\""
      assert prompt =~ "\"independent\": false"
    end

    test "does not claim work was done, create PRs, or leak secrets in the instructions" do
      prompt = Prompt.build(%{parent_identifier: "JOZ-21", parent_title: "Parent", parent_description: "Desc"})

      assert prompt =~ "Do not claim that any work has already been done."
      assert prompt =~ "Do not create pull requests"
      assert prompt =~ "Do not include API keys, tokens, passwords, or other secrets"
    end
  end
end
