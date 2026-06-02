# Vibe External Executor

Symphony normally dispatches coding work to **Codex app-server** via JSON-RPC 2.0 over
stdio. As of MVP 2B, it also supports an **ExternalExecutor** path that delegates to
the [Vibe Interface CLI](https://github.com/JozzyAI/vibe_interface_cli) — a universal
worker-node runtime that can drive `mock`, `claude-code`, or future coding agents.

---

## Architecture

```
Default path (unchanged):
  AgentRunner → AppServer.start_session → Port (JSON-RPC) → codex app-server

Vibe path (agent_kind: vibe):
  AgentRunner → ExternalExecutor.run
    → System.cmd: vibe symphony start  → run_id
    → Port.open:  vibe symphony stream → JSONL events
    → maps events to on_message callback
    → :ok | {:error, reason}
```

**Key invariants:**
- `codex.command` and the Codex AppServer path are completely unchanged.
- `agent_kind` defaults to `"codex"`. No existing config is affected.
- Only `agent_kind: vibe` activates ExternalExecutor.

> **Future naming:** `agent_kind: vibe` is MVP-specific. A more upstream-friendly
> shape will be `agent_kind: external` (or `executor.kind: external`) with
> `external.provider: vibe`. The schema field is designed to extend cleanly.

---

## Prerequisites

```bash
# Install Vibe CLI (dev mode from source)
cd /path/to/vibe-interface-cli
npm install && npm run build

# Verify
node dist/src/index.js --version
# → 0.1.0
```

For `agent: claude-code`, Claude Code CLI must also be installed and authenticated:
```bash
claude --version
```

---

## WORKFLOW.md config — remote Vibe Node via relay

Dispatch runs to a remote Vibe Node through the plaintext dev relay.

> ⚠️ **Relay is plaintext localhost dev mode.** E2E encryption is planned for a future release.
> Ensure the relay is accessible from both the Symphony host and the worker node.

```yaml
agent_kind: vibe
external:
  command: node /path/to/vibe-interface-cli/dist/src/index.js
  agent: claude-code
  node: my-node              # node_id registered with the relay
  relay: ws://localhost:7433  # relay WebSocket URL
  token: dev                 # relay auth token
  permission_mode: unsafe-skip  # optional — enables --dangerously-skip-permissions
```

Setup (3 terminals):

```bash
# Terminal 1 — relay
vibe relay dev --port 7433 --token dev

# Terminal 2 — worker node
vibe node daemon --local \
  --relay ws://localhost:7433 \
  --token dev \
  --node-id my-node

# Terminal 3 — Symphony (uses WORKFLOW.md above)
cd symphony/elixir && mix symphony.run
```

Smoke test:
```bash
bash elixir/scripts/smoke_vibe_relay.sh
```

---

## WORKFLOW.md config — mock agent (safe, no API key)

```yaml
agent_kind: vibe
external:
  command: node /path/to/vibe-interface-cli/dist/src/index.js
  agent: mock
```

Full minimal example:

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: my-project
  active_states: ["In Progress"]
  terminal_states: ["Done", "Cancelled"]
agent_kind: vibe
external:
  command: node /path/to/vibe-interface-cli/dist/src/index.js
  agent: mock
---
You are a coding assistant. Complete the issue as described.
```

---

## WORKFLOW.md config — Claude Code agent

```yaml
agent_kind: vibe
external:
  command: node /path/to/vibe-interface-cli/dist/src/index.js
  agent: claude-code
```

> ⚠️ **Safety:** The `claude-code` backend passes `--dangerously-skip-permissions` only
> when `permission_mode: unsafe-skip` is also set in the vibe run. Default Vibe
> behavior runs Claude without dangerous permissions.

---

## Event mapping

Vibe JSONL events are mapped to the standard Symphony `on_message` callback:

| Vibe event type     | `on_message.event`    | AgentRunner result     |
|---------------------|-----------------------|------------------------|
| `status:running`    | (logged)              | continues streaming    |
| `log`               | `:output`             | forwarded to recipient |
| `tool_call`         | `:tool_call`          | forwarded to recipient |
| `approval_required` | `:approval_required`  | `{:error, {:blocked…}}`|
| `status:completed`  | —                     | `:ok`                  |
| `status:failed`     | —                     | `{:error, {:failed…}}` |
| `status:stopped`    | —                     | `{:error, {:stopped…}}`|
| `error`             | —                     | `{:error, {:run_error…}}`|

---

## Local smoke test

```bash
# From symphony/elixir:
scripts/smoke_vibe_mock.sh

# Optional (requires claude in PATH):
scripts/smoke_vibe_claude.sh
```

---

## State files

Vibe run state lives in `~/.vibe/` independently of Symphony's workspace:

```
~/.vibe/
├── runs/<run_id>.json       # RunRecord (status, metadata, …)
└── events/<run_id>.jsonl    # append-only JSONL event log
```
