defmodule SymphonyElixir.Linear.ProjectResourcesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.ProjectResources

  describe "github_repo_urls/1" do
    test "returns empty list when there are no resources" do
      assert ProjectResources.github_repo_urls([]) == []
    end

    test "extracts a single GitHub repo link" do
      urls = ["https://github.com/JozzyAI/fin_bot"]

      assert ProjectResources.github_repo_urls(urls) == ["https://github.com/JozzyAI/fin_bot"]
    end

    test "extracts multiple distinct GitHub repo links" do
      urls = [
        "https://github.com/JozzyAI/fin_bot",
        "https://github.com/JozzyAI/vibe_interface_cli"
      ]

      assert ProjectResources.github_repo_urls(urls) == [
               "https://github.com/JozzyAI/fin_bot",
               "https://github.com/JozzyAI/vibe_interface_cli"
             ]
    end

    test "ignores non-GitHub resources" do
      urls = [
        "https://www.figma.com/file/abc123/design",
        "https://docs.google.com/document/d/xyz"
      ]

      assert ProjectResources.github_repo_urls(urls) == []
    end

    test "ignores non-GitHub resources mixed with a GitHub repo link" do
      urls = [
        "https://www.notion.so/Project-Spec-abc123",
        "https://github.com/JozzyAI/fin_bot",
        "https://www.figma.com/file/abc123/design"
      ]

      assert ProjectResources.github_repo_urls(urls) == ["https://github.com/JozzyAI/fin_bot"]
    end

    test "drops malformed or unrecognized URLs without raising" do
      urls = [
        "not a url",
        "",
        "github.com/JozzyAI/fin_bot",
        "ftp://github.com/JozzyAI/fin_bot",
        "https://github.com/"
      ]

      assert ProjectResources.github_repo_urls(urls) == []
    end

    test "ignores non-string entries without raising" do
      urls = [nil, 123, %{url: "https://github.com/JozzyAI/fin_bot"}]

      assert ProjectResources.github_repo_urls(urls) == []
    end

    test "normalizes a link into a repo (e.g. a PR or file link) to the repo root" do
      urls = ["https://github.com/JozzyAI/fin_bot/pull/42"]

      assert ProjectResources.github_repo_urls(urls) == ["https://github.com/JozzyAI/fin_bot"]
    end

    test "strips a trailing .git suffix" do
      urls = ["https://github.com/JozzyAI/fin_bot.git"]

      assert ProjectResources.github_repo_urls(urls) == ["https://github.com/JozzyAI/fin_bot"]
    end

    test "strips a trailing slash" do
      urls = ["https://github.com/JozzyAI/fin_bot/"]

      assert ProjectResources.github_repo_urls(urls) == ["https://github.com/JozzyAI/fin_bot"]
    end

    test "de-duplicates repos reached via multiple links" do
      urls = [
        "https://github.com/JozzyAI/fin_bot/pull/42",
        "https://github.com/JozzyAI/fin_bot/issues/7",
        "https://github.com/JozzyAI/fin_bot"
      ]

      assert ProjectResources.github_repo_urls(urls) == ["https://github.com/JozzyAI/fin_bot"]
    end
  end

  describe "github_repo_url/1" do
    test "returns nil for a non-GitHub URL" do
      assert ProjectResources.github_repo_url("https://example.com/JozzyAI/fin_bot") == nil
    end

    test "returns nil for non-binary input" do
      assert ProjectResources.github_repo_url(nil) == nil
      assert ProjectResources.github_repo_url(123) == nil
    end

    test "returns the normalized repo URL for a GitHub link" do
      assert ProjectResources.github_repo_url("https://github.com/JozzyAI/fin_bot") ==
               "https://github.com/JozzyAI/fin_bot"
    end
  end
end
