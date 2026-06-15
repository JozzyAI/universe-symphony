defmodule SymphonyElixir.Planner.PurityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Planner.{PlanExtractor, Prompt}

  @valid_output """
  ```json
  {"children": [{"title": "Add validation", "description": "Open a PR, do not merge.", "acceptance_criteria": ["Done"]}]}
  ```
  """

  test "building a prompt and extracting a plan perform no side effects" do
    refute_received _any

    prompt = Prompt.build(%{parent_identifier: "JOZ-1", parent_title: "Parent", parent_description: "Desc"})
    assert is_binary(prompt)

    assert {:ok, %{children: [_child]}} = PlanExtractor.extract_plan(@valid_output)

    refute_received _any
  end

  test "Prompt and PlanExtractor do not call Linear.Client, Linear.Adapter, or Orchestrator" do
    for module <- [Prompt, PlanExtractor] do
      deps = module_dependencies(module)

      refute SymphonyElixir.Linear.Client in deps, "#{inspect(module)} should not call Linear.Client"
      refute SymphonyElixir.Linear.Adapter in deps, "#{inspect(module)} should not call Linear.Adapter"
      refute SymphonyElixir.Orchestrator in deps, "#{inspect(module)} should not call Orchestrator"
      refute SymphonyElixir.Tracker in deps, "#{inspect(module)} should not call Tracker"
    end
  end

  defp module_dependencies(module) do
    {^module, beam, _filename} = :code.get_object_code(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports |> Enum.map(fn {mod, _fun, _arity} -> mod end) |> Enum.uniq()
  end
end
