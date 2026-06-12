defmodule SymphonyElixir.RedactTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Redact

  describe "redact/1 — sensitive keys" do
    test "redacts run-record AES keys (stop/approval/event)" do
      run_record = %{
        "run_id" => "run_fake1234",
        "node_id" => "node_fakeabcd",
        "stop_aes_key" => "fake-stop-key-AAAA",
        "approval_aes_key" => "fake-approval-key-BBBB",
        "event_aes_key" => "fake-event-key-CCCC"
      }

      redacted = Redact.redact(run_record)

      assert redacted["stop_aes_key"] == "[REDACTED]"
      assert redacted["approval_aes_key"] == "[REDACTED]"
      assert redacted["event_aes_key"] == "[REDACTED]"
      assert redacted["run_id"] == "run_fake1234"
      assert redacted["node_id"] == "node_fakeabcd"
    end

    test "redacts VIBE_RELAY_TOKEN- and LINEAR_API_KEY-like names" do
      env = %{
        "VIBE_RELAY_TOKEN" => "fake-relay-token-1234",
        "LINEAR_API_KEY" => "fake-linear-key-5678",
        "GITHUB_TOKEN" => "fake-gh-token-9999"
      }

      redacted = Redact.redact(env)

      assert redacted["VIBE_RELAY_TOKEN"] == "[REDACTED]"
      assert redacted["LINEAR_API_KEY"] == "[REDACTED]"
      assert redacted["GITHUB_TOKEN"] == "[REDACTED]"
    end

    test "redacts atom keys on a resolved binding (token/relay)" do
      binding = %{
        repo_url: "https://github.com/JozzyAI/fin_bot",
        node_id: "node_fakeabcd",
        relay: "wss://fake-relay.example.com",
        token: "fake-relay-token-1234",
        encrypt: true,
        agent: "codex"
      }

      redacted = Redact.redact(binding)

      assert redacted.token == "[REDACTED]"
      assert redacted.relay == "wss://fake-relay.example.com"
      assert redacted.repo_url == "https://github.com/JozzyAI/fin_bot"
      assert redacted.node_id == "node_fakeabcd"
      assert redacted.agent == "codex"
    end
  end

  describe "redact/1 — nested maps/lists" do
    test "redacts secrets nested inside maps" do
      payload = %{
        "binding" => %{
          "token" => "fake-token-aaa",
          "relay" => "wss://fake-relay.example.com",
          "node_id" => "node_fakeabcd"
        }
      }

      redacted = Redact.redact(payload)

      assert redacted["binding"]["token"] == "[REDACTED]"
      assert redacted["binding"]["relay"] == "wss://fake-relay.example.com"
      assert redacted["binding"]["node_id"] == "node_fakeabcd"
    end

    test "redacts secrets in maps nested inside lists" do
      events = [
        %{"type" => "approval_required", "approval_aes_key" => "fake-aes-1"},
        %{"type" => "log", "message" => "hello", "event_aes_key" => "fake-aes-2"}
      ]

      [first, second] = Redact.redact(events)

      assert first["approval_aes_key"] == "[REDACTED]"
      assert second["event_aes_key"] == "[REDACTED]"
      assert first["type"] == "approval_required"
      assert second["message"] == "hello"
    end

    test "redacts sensitive entries in keyword lists" do
      dispatch_opts = [
        relay: "wss://fake-relay.example.com",
        token: "fake-token-aaa",
        repo_url: "https://github.com/JozzyAI/fin_bot"
      ]

      redacted = Redact.redact(dispatch_opts)

      assert redacted[:token] == "[REDACTED]"
      assert redacted[:relay] == "wss://fake-relay.example.com"
      assert redacted[:repo_url] == "https://github.com/JozzyAI/fin_bot"
    end

    test "redacts secrets nested inside error tuples" do
      reason =
        {:invalid_start_response,
         %{
           "run_id" => "run_fake1234",
           "stop_aes_key" => "fake-stop-key",
           "approval_aes_key" => "fake-approval-key",
           "event_aes_key" => "fake-event-key"
         }}

      {:invalid_start_response, redacted_record} = Redact.redact(reason)

      assert redacted_record["stop_aes_key"] == "[REDACTED]"
      assert redacted_record["approval_aes_key"] == "[REDACTED]"
      assert redacted_record["event_aes_key"] == "[REDACTED]"
      assert redacted_record["run_id"] == "run_fake1234"
    end
  end

  describe "redact/1 — public identifiers remain visible" do
    test "public PR URLs remain visible" do
      payload = %{
        "pr_url" => "https://github.com/JozzyAI/fin_bot/pull/8",
        "url" => "https://github.com/JozzyAI/fin_bot/pull/8"
      }

      redacted = Redact.redact(payload)

      assert redacted["pr_url"] == "https://github.com/JozzyAI/fin_bot/pull/8"
      assert redacted["url"] == "https://github.com/JozzyAI/fin_bot/pull/8"
    end

    test "Linear issue identifiers remain visible" do
      payload = %{"issue_id" => "issue_fake_001", "identifier" => "JOZ-19"}

      redacted = Redact.redact(payload)

      assert redacted["issue_id"] == "issue_fake_001"
      assert redacted["identifier"] == "JOZ-19"
    end

    test "public node IDs remain visible" do
      payload = %{"node_id" => "node_fakeabcd", "node" => "joey-pc"}

      redacted = Redact.redact(payload)

      assert redacted["node_id"] == "node_fakeabcd"
      assert redacted["node"] == "joey-pc"
    end
  end

  describe "redact/1 — non-map/list terms" do
    test "passes through scalars, atoms, and structs unchanged" do
      assert Redact.redact("plain string") == "plain string"
      assert Redact.redact(:some_atom) == :some_atom
      assert Redact.redact(42) == 42

      now = DateTime.utc_now()
      assert Redact.redact(now) == now
    end
  end
end
