defmodule SymphonyElixir.Planner.PlanExtractorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Planner.PlanExtractor

  @valid_child %{
    "title" => "Add input validation",
    "description" => "Validate the form inputs. Open a PR, do not merge.",
    "acceptance_criteria" => ["Invalid inputs are rejected", "Tests cover the new validation"]
  }

  describe "extract_plan/1 - happy path" do
    test "parses a clean ```json block" do
      output = """
      Here is the plan.

      ```json
      #{Jason.encode!(%{"children" => [@valid_child]})}
      ```
      """

      assert {:ok, %{children: [child]}} = PlanExtractor.extract_plan(output)
      assert child.title == "Add input validation"
      assert child.description == "Validate the form inputs. Open a PR, do not merge."
      assert child.acceptance_criteria == ["Invalid inputs are rejected", "Tests cover the new validation"]
    end

    test "parses the final valid planner-shaped block when multiple fenced blocks exist" do
      example_block = Jason.encode!(%{"note" => "this is just an example, not the plan"})
      plan_block = Jason.encode!(%{"children" => [@valid_child]})

      output = """
      Some prose before.

      ```json
      #{example_block}
      ```

      More prose in between.

      ```json
      #{plan_block}
      ```

      Trailing prose after.
      """

      assert {:ok, %{children: [child]}} = PlanExtractor.extract_plan(output)
      assert child.title == "Add input validation"
    end

    test "parses a generic ``` fenced block without a 'json' tag" do
      output = """
      ```
      #{Jason.encode!(%{"children" => [@valid_child]})}
      ```
      """

      assert {:ok, %{children: [_child]}} = PlanExtractor.extract_plan(output)
    end

    test "normalizes default labels, execution_mode, and independent" do
      minimal_child = Map.drop(@valid_child, [])

      output = """
      ```json
      #{Jason.encode!(%{"children" => [minimal_child]})}
      ```
      """

      assert {:ok, %{children: [child]}} = PlanExtractor.extract_plan(output)
      assert child.labels == []
      assert child.execution_mode == "manual_review"
      assert child.independent == false
    end

    test "preserves provided labels, execution_mode, and independent" do
      child =
        Map.merge(@valid_child, %{
          "labels" => ["backend", "planner"],
          "execution_mode" => "auto",
          "independent" => true
        })

      output = """
      ```json
      #{Jason.encode!(%{"children" => [child]})}
      ```
      """

      assert {:ok, %{children: [normalized]}} = PlanExtractor.extract_plan(output)
      assert normalized.labels == ["backend", "planner"]
      assert normalized.execution_mode == "auto"
      assert normalized.independent == true
    end
  end

  describe "extract_plan/1 - errors" do
    test "rejects malformed JSON" do
      output = """
      ```json
      { "children": [ this is not valid json }
      ```
      """

      assert {:error, :invalid_json} = PlanExtractor.extract_plan(output)
    end

    test "rejects a block with no children key" do
      output = """
      ```json
      #{Jason.encode!(%{"note" => "no children here"})}
      ```
      """

      assert {:error, :missing_children} = PlanExtractor.extract_plan(output)
    end

    test "rejects when children is not a list" do
      output = """
      ```json
      #{Jason.encode!(%{"children" => "oops"})}
      ```
      """

      assert {:error, :children_not_list} = PlanExtractor.extract_plan(output)
    end

    test "rejects when there are no fenced blocks at all" do
      assert {:error, :no_json_block_found} = PlanExtractor.extract_plan("just some prose, no code blocks")
    end

    test "rejects an empty children list" do
      output = """
      ```json
      #{Jason.encode!(%{"children" => []})}
      ```
      """

      assert {:error, :empty_children} = PlanExtractor.extract_plan(output)
    end

    test "rejects more than 20 children" do
      children = for n <- 1..21, do: Map.put(@valid_child, "title", "Child #{n}")

      output = """
      ```json
      #{Jason.encode!(%{"children" => children})}
      ```
      """

      assert {:error, :too_many_children} = PlanExtractor.extract_plan(output)
    end
  end

  describe "extract_plan/1 - child field validation" do
    test "rejects an empty title" do
      child = Map.put(@valid_child, "title", "")

      output = """
      ```json
      #{Jason.encode!(%{"children" => [child]})}
      ```
      """

      assert {:error, {:invalid_child, 0, {:empty_field, "title"}}} = PlanExtractor.extract_plan(output)
    end

    test "rejects a missing description" do
      child = Map.delete(@valid_child, "description")

      output = """
      ```json
      #{Jason.encode!(%{"children" => [child]})}
      ```
      """

      assert {:error, {:invalid_child, 0, {:missing_field, "description"}}} = PlanExtractor.extract_plan(output)
    end

    test "rejects empty acceptance_criteria" do
      child = Map.put(@valid_child, "acceptance_criteria", [])

      output = """
      ```json
      #{Jason.encode!(%{"children" => [child]})}
      ```
      """

      assert {:error, {:invalid_child, 0, {:empty_field, "acceptance_criteria"}}} = PlanExtractor.extract_plan(output)
    end

    test "rejects acceptance_criteria containing a blank entry" do
      child = Map.put(@valid_child, "acceptance_criteria", ["Valid", "  "])

      output = """
      ```json
      #{Jason.encode!(%{"children" => [child]})}
      ```
      """

      assert {:error, {:invalid_child, 0, {:invalid_field, "acceptance_criteria"}}} = PlanExtractor.extract_plan(output)
    end

    test "reports the index of the first invalid child" do
      children = [@valid_child, Map.put(@valid_child, "title", "")]

      output = """
      ```json
      #{Jason.encode!(%{"children" => children})}
      ```
      """

      assert {:error, {:invalid_child, 1, {:empty_field, "title"}}} = PlanExtractor.extract_plan(output)
    end
  end

  describe "validate_children/1" do
    test "returns :children_not_list when given a non-list" do
      assert {:error, :children_not_list} = PlanExtractor.validate_children(%{})
      assert {:error, :children_not_list} = PlanExtractor.validate_children("oops")
    end

    test "returns :empty_children for an empty list" do
      assert {:error, :empty_children} = PlanExtractor.validate_children([])
    end
  end
end
