defmodule SymphonyElixir.Planner.ProjectMemoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Planner.ProjectMemory

  @start_marker "<!-- symphony:project-memory:v1:start -->"
  @end_marker "<!-- symphony:project-memory:v1:end -->"
  @inherited_start "<!-- symphony:inherited-project-memory:v1:start -->"
  @inherited_end "<!-- symphony:inherited-project-memory:v1:end -->"

  defp full_binding do
    %{
      repo_mode: :create_new,
      repo_name: "mirror_social",
      repo_owner: "JozzyAI",
      repo_url: "https://github.com/JozzyAI/mirror_social",
      repo_status: :needs_creation,
      node: "joey-pc",
      node_id: "node_f7cedd3b6590aff9",
      agent: "claude-code",
      auto_merge: false,
      human_review_required: true,
      tech_stack: ["Next.js", "Supabase"],
      open_questions: ["Confirm whether to create `JozzyAI/mirror_social`."],
      inherit_binding_to_children: true
    }
  end

  defp empty_binding do
    %{
      repo_mode: nil,
      repo_name: nil,
      repo_owner: "JozzyAI",
      repo_url: nil,
      repo_status: nil,
      node: nil,
      node_id: nil,
      agent: nil,
      auto_merge: false,
      human_review_required: true,
      tech_stack: [],
      open_questions: [],
      inherit_binding_to_children: true
    }
  end

  # ---------------------------------------------------------------------------
  # split/1
  # ---------------------------------------------------------------------------

  describe "split/1" do
    test "returns {description, nil} when no marker is present" do
      {human, block} = ProjectMemory.split("Some description text.")
      assert human == "Some description text."
      assert block == nil
    end

    test "extracts human text (before marker) and block content" do
      desc = "Human text.\n\n#{@start_marker}\nblock content\n#{@end_marker}"
      {human, block} = ProjectMemory.split(desc)
      assert human == "Human text."
      assert block =~ "block content"
    end

    test "trims whitespace from human text" do
      desc = "  Human text.  \n\n#{@start_marker}\ncontent\n#{@end_marker}"
      {human, _} = ProjectMemory.split(desc)
      assert human == "Human text."
    end

    test "treats unclosed start marker as plain human text" do
      desc = "Human text. #{@start_marker} unclosed"
      {human, block} = ProjectMemory.split(desc)
      assert human == desc
      assert block == nil
    end

    test "preserves text after end marker" do
      desc = "Before.\n#{@start_marker}\nblock\n#{@end_marker}\nAfter."
      {human, _block} = ProjectMemory.split(desc)
      assert human =~ "Before."
      assert human =~ "After."
    end
  end

  # ---------------------------------------------------------------------------
  # write/3 — managed block insertion and idempotency
  # ---------------------------------------------------------------------------

  describe "write/3 insertion" do
    test "inserts project memory block into description" do
      result = ProjectMemory.write("My description.", full_binding(), "Mirror Social")
      assert String.contains?(result, "My description.")
      assert String.contains?(result, @start_marker)
      assert String.contains?(result, @end_marker)
      assert String.contains?(result, "## Symphony Project Memory")
    end

    test "works with nil description" do
      result = ProjectMemory.write(nil, full_binding(), "Mirror Social")
      assert String.contains?(result, @start_marker)
    end

    test "works with empty description" do
      result = ProjectMemory.write("", full_binding(), "Mirror Social")
      assert String.contains?(result, @start_marker)
    end
  end

  describe "write/3 idempotency" do
    test "replaces existing block on second call — no duplicate start marker" do
      first = ProjectMemory.write("My description.", full_binding(), "Mirror Social")
      second = ProjectMemory.write(first, full_binding(), "Mirror Social")

      assert length(String.split(second, @start_marker)) == 2
      assert length(String.split(second, @end_marker)) == 2
    end

    test "human text is preserved through re-writes" do
      first = ProjectMemory.write("My original description.", full_binding(), "Mirror Social")
      second = ProjectMemory.write(first, full_binding(), "Mirror Social")

      {human, _} = ProjectMemory.split(second)
      assert human == "My original description."
    end

    test "calling write three times still yields exactly one block" do
      desc = "Desc."
      result =
        desc
        |> ProjectMemory.write(full_binding(), "T")
        |> ProjectMemory.write(full_binding(), "T")
        |> ProjectMemory.write(full_binding(), "T")

      assert length(String.split(result, @start_marker)) == 2
    end
  end

  describe "write/3 preserves human text" do
    test "human description text appears before the managed block" do
      result = ProjectMemory.write("Human text here.", full_binding(), "Test")
      start_pos = :binary.match(result, "Human text here.") |> elem(0)
      marker_pos = :binary.match(result, @start_marker) |> elem(0)
      assert start_pos < marker_pos
    end

    test "human text is not modified" do
      human = "I want to build a Mirror Social app.\nvibe: create a new repo."
      result = ProjectMemory.write(human, full_binding(), "Test")
      {extracted, _} = ProjectMemory.split(result)
      assert extracted == human
    end
  end

  # ---------------------------------------------------------------------------
  # build_block/2 — content structure
  # ---------------------------------------------------------------------------

  describe "build_block/2" do
    test "starts with project-memory start marker" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert String.starts_with?(block, @start_marker)
    end

    test "ends with project-memory end marker" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert String.ends_with?(block, @end_marker)
    end

    test "contains repo binding yaml fields" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert block =~ "repo_mode: create_new"
      assert block =~ "repo_url: https://github.com/JozzyAI/mirror_social"
      assert block =~ "repo_status: needs_creation"
      assert block =~ "node: joey-pc"
      assert block =~ "node_id: node_f7cedd3b6590aff9"
      assert block =~ "agent: claude-code"
    end

    test "contains auto_merge false and human_review_required true" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert block =~ "auto_merge: false"
      assert block =~ "human_review_required: true"
    end

    test "contains tech stack entries" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert block =~ "Next.js"
      assert block =~ "Supabase"
    end

    test "contains open questions" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert block =~ "Confirm whether to create"
    end

    test "contains last-normalized timestamp" do
      block = ProjectMemory.build_block(full_binding(), "Mirror Social")
      assert block =~ "Last normalized by Symphony"
      assert block =~ "project-memory:v1"
    end

    test "omits tech stack section when tech_stack is empty" do
      binding = %{full_binding() | tech_stack: []}
      block = ProjectMemory.build_block(binding, "Test")
      refute block =~ "### Tech Stack"
    end

    test "omits open questions section when empty" do
      binding = %{full_binding() | open_questions: []}
      block = ProjectMemory.build_block(binding, "Test")
      refute block =~ "### Open Questions"
    end
  end

  # ---------------------------------------------------------------------------
  # build_inherited_block/2
  # ---------------------------------------------------------------------------

  describe "build_inherited_block/2" do
    test "includes parent identifier" do
      block = ProjectMemory.build_inherited_block(full_binding(), "JOZ-30")
      assert block =~ "Parent: JOZ-30"
    end

    test "includes repo url" do
      block = ProjectMemory.build_inherited_block(full_binding(), "JOZ-30")
      assert block =~ "https://github.com/JozzyAI/mirror_social"
    end

    test "includes node and node_id" do
      block = ProjectMemory.build_inherited_block(full_binding(), "JOZ-30")
      assert block =~ "joey-pc"
      assert block =~ "node_f7cedd3b6590aff9"
    end

    test "includes agent" do
      block = ProjectMemory.build_inherited_block(full_binding(), "JOZ-30")
      assert block =~ "claude-code"
    end

    test "includes human_review_required and auto_merge flags" do
      block = ProjectMemory.build_inherited_block(full_binding(), "JOZ-30")
      assert block =~ "Human review required: true"
      assert block =~ "Auto merge: false"
    end

    test "omits Auto merge line when auto_merge is nil (unset)" do
      binding = %{full_binding() | auto_merge: nil}
      block = ProjectMemory.build_inherited_block(binding, "JOZ-30")
      assert block =~ "Human review required: true"
      refute block =~ "Auto merge:"
    end

    test "includes Auto merge: true when auto_merge is true" do
      binding = %{full_binding() | auto_merge: true}
      block = ProjectMemory.build_inherited_block(binding, "JOZ-30")
      assert block =~ "Auto merge: true"
    end

    test "starts and ends with inherited markers" do
      block = ProjectMemory.build_inherited_block(full_binding(), "JOZ-30")
      assert String.starts_with?(block, @inherited_start)
      assert String.ends_with?(block, @inherited_end)
    end

    test "returns nil when no binding info is set" do
      assert ProjectMemory.build_inherited_block(empty_binding(), "JOZ-30") == nil
    end

    test "returns nil when parent_identifier is nil but binding is also empty" do
      assert ProjectMemory.build_inherited_block(empty_binding(), nil) == nil
    end

    test "shows needs_confirmation line when repo_url is nil but repo_name is set" do
      binding = %{full_binding() | repo_url: nil}
      block = ProjectMemory.build_inherited_block(binding, "JOZ-30")
      assert block =~ "needs_confirmation"
      assert block =~ "mirror_social"
    end
  end
end
