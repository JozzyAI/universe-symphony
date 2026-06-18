defmodule SymphonyElixir.Planner.DescriptionNormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Planner.DescriptionNormalizer

  # Minimal config shaped like Config.settings!() for the fields the normalizer reads.
  defp config(overrides \\ []) do
    nodes = Keyword.get(overrides, :nodes, %{
      "joey-pc" => %{"node_id" => "node_f7cedd3b6590aff9", "relay" => "wss://relay.example.com"}
    })
    allowed_repos = Keyword.get(overrides, :allowed_repos, ["fin_bot", "spendlens"])
    allowed_orgs = Keyword.get(overrides, :allowed_github_orgs, ["JozzyAI"])

    %{
      binding: %{
        nodes: nodes,
        repo_policy: %{
          allowed_repos: allowed_repos,
          allowed_github_orgs: allowed_orgs
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Node alias normalization
  # ---------------------------------------------------------------------------

  describe "node alias normalization" do
    test "joey_pc -> joey-pc" do
      result = DescriptionNormalizer.normalize("use joey_pc", "Test", config())
      assert result.node == "joey-pc"
    end

    test "joey pc -> joey-pc" do
      result = DescriptionNormalizer.normalize("use joey pc", "Test", config())
      assert result.node == "joey-pc"
    end

    test "joey-pc -> joey-pc" do
      result = DescriptionNormalizer.normalize("use joey-pc", "Test", config())
      assert result.node == "joey-pc"
    end

    test "no node phrase -> nil" do
      result = DescriptionNormalizer.normalize("no node mentioned", "Test", config())
      assert result.node == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Agent alias normalization
  # ---------------------------------------------------------------------------

  describe "agent alias normalization" do
    test "claude code -> claude-code" do
      result = DescriptionNormalizer.normalize("use claude code", "Test", config())
      assert result.agent == "claude-code"
    end

    test "claude-code -> claude-code" do
      result = DescriptionNormalizer.normalize("use claude-code", "Test", config())
      assert result.agent == "claude-code"
    end

    test "codex -> codex" do
      result = DescriptionNormalizer.normalize("use codex", "Test", config())
      assert result.agent == "codex"
    end

    test "no agent phrase -> nil" do
      result = DescriptionNormalizer.normalize("no agent mentioned", "Test", config())
      assert result.agent == nil
    end
  end

  # ---------------------------------------------------------------------------
  # node_id resolution from config
  # ---------------------------------------------------------------------------

  describe "node_id resolution" do
    test "resolves configured node_id for joey-pc" do
      result = DescriptionNormalizer.normalize("use joey-pc", "Test", config())
      assert result.node_id == "node_f7cedd3b6590aff9"
    end

    test "returns nil for unrecognized node name" do
      result = DescriptionNormalizer.normalize("some description", "Test", config())
      assert result.node_id == nil
    end

    test "returns nil when binding nodes is empty" do
      result = DescriptionNormalizer.normalize("use joey-pc", "Test", config(nodes: %{}))
      assert result.node_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Repo name inference
  # ---------------------------------------------------------------------------

  describe "repo name inference from title" do
    test "Mirror Social -> mirror_social" do
      result = DescriptionNormalizer.normalize("vibe: create a new repo", "Mirror Social", config())
      assert result.repo_name == "mirror_social"
    end

    test "My Cool App -> my_cool_app" do
      result = DescriptionNormalizer.normalize("vibe: create a new repo", "My Cool App", config())
      assert result.repo_name == "my_cool_app"
    end
  end

  describe "repo name inference from description text" do
    test "extracts app name from 'build a X app' pattern" do
      desc = "I want to build a Travel Frog app.\nvibe: create a new repo"
      result = DescriptionNormalizer.normalize(desc, "MVP", config())
      assert result.repo_name == "travel_frog"
    end

    test "description pattern takes priority over generic title" do
      desc = "I want to build a Mirror Social app.\nvibe: create a new repo"
      result = DescriptionNormalizer.normalize(desc, "MVP", config())
      assert result.repo_name == "mirror_social"
    end
  end

  describe "explicit create repo <name>" do
    test "uses explicit name when present" do
      result = DescriptionNormalizer.normalize(
        "vibe: create repo my_explicit_name",
        "Mirror Social",
        config()
      )
      assert result.repo_name == "my_explicit_name"
    end

    test "sets repo_mode to create_new for explicit create repo" do
      result = DescriptionNormalizer.normalize(
        "create repo mirror_social",
        "Test",
        config()
      )
      assert result.repo_mode == :create_new
      assert result.repo_name == "mirror_social"
    end
  end

  # ---------------------------------------------------------------------------
  # Repo status
  # ---------------------------------------------------------------------------

  describe "repo status" do
    test "needs_creation when inferred repo not in allowed_repos" do
      result = DescriptionNormalizer.normalize("vibe: create a new repo", "Mirror Social", config())
      assert result.repo_status == :needs_creation
    end

    test "resolved when repo name IS in allowed_repos" do
      result = DescriptionNormalizer.normalize(
        "vibe: create a new repo",
        "Mirror Social",
        config(allowed_repos: ["mirror_social", "fin_bot"])
      )
      assert result.repo_status == :resolved
    end

    test "needs_confirmation when create new repo but name cannot be inferred" do
      result = DescriptionNormalizer.normalize(
        "vibe: create a new repo",
        nil,
        config()
      )
      assert result.repo_status == :needs_confirmation
    end

    test "nil repo_status when no repo intent" do
      result = DescriptionNormalizer.normalize("plain description", "Test", config())
      assert result.repo_status == nil
    end
  end

  # ---------------------------------------------------------------------------
  # auto_merge flag
  # ---------------------------------------------------------------------------

  describe "auto_merge flag" do
    test "defaults to false" do
      result = DescriptionNormalizer.normalize("some description", "Test", config())
      assert result.auto_merge == false
    end

    test "do not auto merge -> false" do
      result = DescriptionNormalizer.normalize("Do not auto merge.", "Test", config())
      assert result.auto_merge == false
    end

    test "don't auto merge -> false" do
      result = DescriptionNormalizer.normalize("Don't auto merge.", "Test", config())
      assert result.auto_merge == false
    end

    test "no auto merge -> false" do
      result = DescriptionNormalizer.normalize("no auto merge", "Test", config())
      assert result.auto_merge == false
    end
  end

  # ---------------------------------------------------------------------------
  # human_review_required defaults
  # ---------------------------------------------------------------------------

  describe "human_review_required" do
    test "defaults to true" do
      result = DescriptionNormalizer.normalize("some description", "Test", config())
      assert result.human_review_required == true
    end
  end

  # ---------------------------------------------------------------------------
  # vibe: line priority
  # ---------------------------------------------------------------------------

  describe "vibe: line priority" do
    test "vibe line takes priority over body text for node" do
      desc = """
      I want to use codex in the main body.
      vibe: use claude code
      """
      result = DescriptionNormalizer.normalize(desc, "Test", config())
      assert result.agent == "claude-code"
    end

    test "parses full vibe directive line" do
      desc = "vibe: create a new repo use joey_pc use claude code"
      result = DescriptionNormalizer.normalize(desc, "Mirror Social", config())
      assert result.node == "joey-pc"
      assert result.agent == "claude-code"
      assert result.repo_mode == :create_new
    end
  end

  # ---------------------------------------------------------------------------
  # Full sample description (spec validation)
  # ---------------------------------------------------------------------------

  describe "full Mirror Social sample description" do
    @sample_description """
    I want to build a Mirror Social app, like travel frog + dating app.
    Users take tests, create a digital clone, clones socialize automatically, and users review daily summaries.
    vibe: create a new repo use joey_pc use claude code
    Use Next.js and Supabase.
    Do not auto merge.
    """

    test "parses repo_mode, repo_name, repo_url, repo_status" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert result.repo_mode == :create_new
      assert result.repo_owner == "JozzyAI"
      assert result.repo_name == "mirror_social"
      assert result.repo_url == "https://github.com/JozzyAI/mirror_social"
      assert result.repo_status == :needs_creation
    end

    test "parses node and node_id" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert result.node == "joey-pc"
      assert result.node_id == "node_f7cedd3b6590aff9"
    end

    test "parses agent" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert result.agent == "claude-code"
    end

    test "parses auto_merge false" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert result.auto_merge == false
    end

    test "parses human_review_required true" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert result.human_review_required == true
    end

    test "detects Next.js and Supabase in tech_stack" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert "Next.js" in result.tech_stack
      assert "Supabase" in result.tech_stack
    end

    test "sets inherit_binding_to_children to true" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      assert result.inherit_binding_to_children == true
    end

    test "repo not silently resolved to fin_bot (status is needs_creation)" do
      result = DescriptionNormalizer.normalize(@sample_description, "Mirror Social", config())
      refute result.repo_status == :resolved
      assert result.repo_name == "mirror_social"
    end
  end

  # ---------------------------------------------------------------------------
  # nil / empty input
  # ---------------------------------------------------------------------------

  describe "nil and empty inputs" do
    test "nil description returns empty binding" do
      result = DescriptionNormalizer.normalize(nil, "Test", config())
      assert result.node == nil
      assert result.agent == nil
      assert result.repo_mode == nil
    end

    test "empty description returns empty binding" do
      result = DescriptionNormalizer.normalize("", "Test", config())
      assert result.node == nil
      assert result.agent == nil
    end

    test "nil config binding is handled safely" do
      result = DescriptionNormalizer.normalize("use joey-pc", "Test", %{binding: nil})
      assert result.node == "joey-pc"
      assert result.node_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # child_labels/1
  # ---------------------------------------------------------------------------

  describe "child_labels/1" do
    test "includes agent: and node: labels when set" do
      binding = %{agent: "claude-code", node: "joey-pc", repo_name: nil, repo_status: nil}
      labels = DescriptionNormalizer.child_labels(binding)
      assert "agent:claude-code" in labels
      assert "node:joey-pc" in labels
    end

    test "includes repo: label when repo_status is needs_creation" do
      binding = %{agent: "claude-code", node: "joey-pc", repo_name: "mirror_social", repo_status: :needs_creation}
      labels = DescriptionNormalizer.child_labels(binding)
      assert "repo:mirror_social" in labels
    end

    test "includes repo: label when repo_status is resolved" do
      binding = %{agent: "claude-code", node: "joey-pc", repo_name: "fin_bot", repo_status: :resolved}
      labels = DescriptionNormalizer.child_labels(binding)
      assert "repo:fin_bot" in labels
    end

    test "does not include repo: label when repo_name is nil" do
      binding = %{agent: "claude-code", node: "joey-pc", repo_name: nil, repo_status: nil}
      labels = DescriptionNormalizer.child_labels(binding)
      refute Enum.any?(labels, &String.starts_with?(&1, "repo:"))
    end

    test "does not add type:plan to children" do
      binding = %{agent: "codex", node: "joey-pc", repo_name: "mirror_social", repo_status: :needs_creation}
      labels = DescriptionNormalizer.child_labels(binding)
      refute "type:plan" in labels
    end

    test "returns empty list when all binding fields are nil" do
      binding = %{agent: nil, node: nil, repo_name: nil, repo_status: nil}
      assert DescriptionNormalizer.child_labels(binding) == []
    end
  end
end
