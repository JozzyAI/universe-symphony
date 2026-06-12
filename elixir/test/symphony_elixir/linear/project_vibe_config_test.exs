defmodule SymphonyElixir.Linear.ProjectVibeConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.ProjectVibeConfig

  describe "parse/1 — no project vibe block" do
    test "nil description has no project vibe config" do
      assert {:ok, nil} = ProjectVibeConfig.parse(nil)
    end

    test "description without a vibe: block has no project vibe config" do
      description = """
      ## Project Overview

      This project ships fin_bot features. No special config here.
      """

      assert {:ok, nil} = ProjectVibeConfig.parse(description)
    end

    test "fenced code block without a vibe: key has no project vibe config" do
      description = """
      ## Notes

      ```yaml
      other_config:
        foo: bar
      ```
      """

      assert {:ok, nil} = ProjectVibeConfig.parse(description)
    end
  end

  describe "parse/1 — valid vibe: block" do
    test "parses a full vibe: block from a fenced yaml code block" do
      description = """
      ## Project Overview

      ```yaml
      vibe:
        repo: https://github.com/JozzyAI/fin_bot
        default_agent: codex
        default_node: joey-pc
        encrypt: true
        allowed_agents:
          - codex
          - claude-code
          - mock
        allowed_nodes:
          - joey-pc
      ```

      More notes.
      """

      assert {:ok, vibe} = ProjectVibeConfig.parse(description)

      assert vibe.repo == "https://github.com/JozzyAI/fin_bot"
      assert vibe.default_agent == "codex"
      assert vibe.default_node == "joey-pc"
      assert vibe.encrypt == true
      assert vibe.allowed_agents == ["codex", "claude-code", "mock"]
      assert vibe.allowed_nodes == ["joey-pc"]
    end

    test "parses a partial vibe: block, leaving unset fields nil" do
      description = """
      ```yaml
      vibe:
        repo: vibe_interface_cli
      ```
      """

      assert {:ok, vibe} = ProjectVibeConfig.parse(description)

      assert vibe.repo == "vibe_interface_cli"
      assert vibe.default_agent == nil
      assert vibe.default_node == nil
      assert vibe.encrypt == nil
      assert vibe.allowed_agents == nil
      assert vibe.allowed_nodes == nil
    end

    test "an empty vibe: block parses to all-nil fields" do
      description = """
      ```yaml
      vibe:
      ```
      """

      assert {:ok, vibe} = ProjectVibeConfig.parse(description)

      assert vibe.repo == nil
      assert vibe.default_agent == nil
      assert vibe.default_node == nil
    end

    test "a plain ``` fence with a vibe: key is also recognized" do
      description = """
      ```
      vibe:
        default_agent: mock
      ```
      """

      assert {:ok, vibe} = ProjectVibeConfig.parse(description)
      assert vibe.default_agent == "mock"
    end
  end

  describe "parse/1 — invalid vibe: block" do
    test "vibe: value that is not a mapping fails" do
      description = """
      ```yaml
      vibe: not-a-map
      ```
      """

      assert {:error, :project_vibe_not_a_map} = ProjectVibeConfig.parse(description)
    end

    test "malformed YAML inside the fenced block fails" do
      description = """
      ```yaml
      vibe:
        repo: [unterminated
      ```
      """

      assert {:error, {:project_vibe_yaml_error, _reason}} = ProjectVibeConfig.parse(description)
    end

    test "allowed_agents that is not a list of strings fails" do
      description = """
      ```yaml
      vibe:
        allowed_agents: codex
      ```
      """

      assert {:error, {:project_vibe_invalid_field, "allowed_agents"}} = ProjectVibeConfig.parse(description)
    end

    test "encrypt that is not a boolean fails" do
      description = """
      ```yaml
      vibe:
        encrypt: "yes"
      ```
      """

      assert {:error, {:project_vibe_invalid_field, "encrypt"}} = ProjectVibeConfig.parse(description)
    end
  end
end
