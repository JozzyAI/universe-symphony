# Symphony × Vibe — Approval Loop Demo

This document demonstrates the complete Symphony → Vibe approval round-trip:

```
Symphony UI (blocked state)
  ↑  vibe_approval_id + vibe_approval_message in blocked payload
  ↑
Symphony Orchestrator stores blocked entry
  ↑
ExternalExecutor receives approval_required from stream
  ↑
vibe symphony stream → approval_required JSONL event
  ↑
Vibe Node (mock or claude-code agent)
  ↑
vibe symphony start → run dispatched via relay (E2E encrypted)
  ↑
Symphony dispatches issue via WORKFLOW.md: agent_kind: vibe
```

After Symphony sees the block, an operator sends `POST /api/v1/:issue_identifier/approve`.
Symphony calls `vibe approval respond`, which sends an encrypted `approval_response` to the node.

---

## Architecture

Symphony remains the orchestrator and UI. Vibe is the worker node runtime.

```
Symphony (Elixir orchestrator)
  │
  │ 1. vibe symphony start → run_id
  │ 2. vibe symphony stream → JSONL events
  ↓
Vibe relay (plaintext WebSocket, localhost dev / GCP prod)
  │
  │ run_start payload: AES-256-GCM encrypted (HKDF: vibe-run-start-v1)
  │ approval_response: AES-256-GCM encrypted (HKDF: vibe-approval-response-v1)
  ↓
Vibe Node (local or remote)
  │
  │ spawns mock / claude-code / codex backend
  ↓
Agent (runs code, emits events)
  │
  │ approval_required → operator blocks run
  │ approval_response ← operator approves via Symphony API
  ↓
Run continues → completed
```

**Encryption:** The relay is a plaintext WebSocket transport (localhost dev or a GCP instance). The `run_start` and `approval_response` message bodies are E2E encrypted using X25519 ECDH + AES-256-GCM with per-surface HKDF-derived keys. The relay routes ciphertext; it never sees the prompt, agent decision, or approval payload.

---

## Prerequisites

```bash
# 1. Install Vibe CLI
cd /path/to/vibe-interface-cli
npm install && npm run build && npm link

vibe --version   # → 0.1.0

# 2. (Optional) Verify Symphony tests pass
cd symphony/elixir
mix test         # → 264 tests, 0 failures
```

No Linear API key needed. No Claude Code needed. The mock agent runs entirely locally.

---

## Smoke test (Vibe-only, no Symphony server needed)

Proves the relay + approval loop end-to-end without requiring a running Symphony instance:

```bash
bash elixir/scripts/smoke_vibe_approval.sh
```

Expected output:

```
✓ vibe: 0.1.0
── Step 1: start relay (port=7434, require-pairing=ON) ──
✓ relay started (pid=12345)
── Step 2: pair node identity with relay ──
✓ node identity registered
── Step 3: start node daemon (node_id=approval-node) ──
✓ node registered and online
── Step 4: vibe symphony start --agent mock --encrypt ──
   (run_start payload is E2E encrypted to node's public key)
run_id:  run_20260602_abc123
status:  running
node_id: approval-node
✓ run dispatched to node (encrypted)
── Step 5: stream events — waiting for approval_required ──
  approval_required event:
  {"type":"approval_required","approval_id":"appr_m5x4z","message":"Proceed with modifying tracked files?","run_id":"run_20260602_abc123","ts":"2026-06-02T12:34:56.789Z"}

✓ approval_required received
  approval_id: appr_m5x4z
  message:     Proceed with modifying tracked files?
── Step 6: vibe approval respond --decision approve ──
   (approval_response payload is E2E encrypted)
approval respond output: {"ok":true,"run_id":"run_20260602_abc123","approval_id":"appr_m5x4z","decision":"approve"}
✓ encrypted approval_response sent to relay → node
── Step 7: verify approval_response event in stream ──
  approval_response event:
  {"type":"approval_response","run_id":"run_20260602_abc123","approval_id":"appr_m5x4z","decision":"approve","ts":"2026-06-02T12:34:57.123Z"}

✓ approval_response received on stream
  decision:    approve
  approval_id: appr_m5x4z
════════════════════════════════════════════════════════════════
  ✅  Symphony Vibe approval smoke PASSED

  run_id:      run_20260602_abc123
  node:        approval-node
  approval_id: appr_m5x4z
  decision:    approve

  Encryption summary:
  ├─ run_start payload    → AES-256-GCM (HKDF: vibe-run-start-v1)
  └─ approval_response    → AES-256-GCM (HKDF: vibe-approval-response-v1)
  The relay forwarded ciphertext only — never saw plaintext.
════════════════════════════════════════════════════════════════
```

---

## Full Symphony integration (with Linear)

This section shows how Symphony surfaces the Vibe approval in its own UI.

### WORKFLOW.md

```yaml
agent_kind: vibe
external:
  command: vibe                            # or: node /path/to/dist/src/index.js
  agent: mock                              # or: claude-code
  node: my-node                            # node_id registered with the relay
  relay: ws://localhost:7434               # relay WebSocket URL
  token: dev-approval                      # relay auth token
```

### Setup (3 terminals)

```bash
# Terminal 1 — relay with identity enforcement
vibe relay dev --port 7434 --token dev-approval --require-pairing

# Terminal 2 — pair node, then start daemon
vibe node pair  --relay ws://localhost:7434 --token dev-approval
vibe node daemon --local \
  --relay ws://localhost:7434 \
  --token dev-approval \
  --node-id my-node

# Terminal 3 — Symphony
cd symphony/elixir && mix symphony.run
```

### What happens when the mock agent runs

The mock agent emits these events (streamed as JSONL to Symphony's ExternalExecutor):

```jsonl
{"type":"status","status":"running","run_id":"run_20260602_abc123","ts":"..."}
{"type":"log","stream":"stdout","message":"Cloning repository...","run_id":"...","ts":"..."}
{"type":"log","stream":"stdout","message":"Analyzing codebase...","run_id":"...","ts":"..."}
{"type":"log","stream":"stdout","message":"Executing task...","run_id":"...","ts":"..."}
{"type":"approval_required","approval_id":"appr_m5x4z","message":"Proceed with modifying tracked files?","run_id":"run_20260602_abc123","ts":"..."}
```

When `approval_required` arrives, ExternalExecutor:
1. Calls `on_message.(%{event: :approval_required, approval_id: "appr_m5x4z", message: "Proceed...", ...})`
2. Returns `{:error, {:blocked, :approval_required, event}}`

The Orchestrator stores `vibe_approval_id` and `vibe_approval_message` in the running entry, then moves the issue to the blocked state.

### Symphony blocked payload

```bash
curl -s http://localhost:4000/api/v1/ENG-123
```

```json
{
  "issue_identifier": "ENG-123",
  "issue_id": "issue-abc-def-123",
  "status": "blocked",
  "last_error": "vibe run is blocked — operator input may be required",
  "blocked": {
    "session_id": "sess-1",
    "state": "In Progress",
    "error": "vibe run is blocked — operator input may be required",
    "blocked_at": "2026-06-02T12:34:56Z",
    "last_event": "approval_required",
    "vibe_run_id": "run_20260602_abc123",
    "vibe_node_id": "my-node",
    "vibe_agent": "mock",
    "vibe_approval_id": "appr_m5x4z",
    "vibe_approval_message": "Proceed with modifying tracked files?",
    "last_event_at": "2026-06-02T12:34:56Z"
  },
  "workspace": {
    "path": "/home/user/.vibe/workspaces/ENG-123",
    "host": null
  },
  "attempts": { "restart_count": 0, "current_retry_attempt": 0 },
  "running": null,
  "retry": null,
  "recent_events": [],
  "tracked": {}
}
```

The `vibe_approval_id` and `vibe_approval_message` tell the operator exactly what the agent is waiting for.

### Operator approves via Symphony API

```bash
curl -s -X POST http://localhost:4000/api/v1/ENG-123/approve \
  -H "Content-Type: application/json" \
  -d '{"approval_id":"appr_m5x4z","decision":"approve"}'
```

```json
{
  "ok": true,
  "run_id": "run_20260602_abc123",
  "approval_id": "appr_m5x4z",
  "decision": "approve",
  "issue_identifier": "ENG-123"
}
```

Internally, Symphony:
1. Looks up `vibe_run_id` and `vibe_approval_id` from the blocked entry
2. Reads relay URL + token from `Config.settings!().external`
3. Calls `ExternalExecutor.send_approval("vibe", run_id, approval_id, "approve", relay, token)`
4. Which shells out to: `vibe approval respond --run-id ... --approval-id ... --decision approve --relay ... --token ...`

### Deny example

```bash
curl -s -X POST http://localhost:4000/api/v1/ENG-123/approve \
  -H "Content-Type: application/json" \
  -d '{"approval_id":"appr_m5x4z","decision":"deny","message":"Too risky — please scope to tests only"}'
```

```json
{
  "ok": true,
  "run_id": "run_20260602_abc123",
  "approval_id": "appr_m5x4z",
  "decision": "deny",
  "issue_identifier": "ENG-123"
}
```

### Encrypted approval_response event (on the Vibe node)

After the approval is sent, the node appends this to `~/.vibe/events/<run_id>.jsonl`:

```json
{
  "type": "approval_response",
  "run_id": "run_20260602_abc123",
  "session_id": "sess-1",
  "approval_id": "appr_m5x4z",
  "decision": "approve",
  "ts": "2026-06-02T12:34:57.123Z"
}
```

The event is then visible in `vibe symphony stream <run_id>`.

### Error cases from the approve endpoint

| Scenario | HTTP | `error.code` |
|---|---|---|
| `approval_id` not sent | 422 | `missing_approval_id` |
| `decision` is not `approve` or `deny` | 422 | `invalid_decision` |
| Issue not blocked (or not found) | 404 | `issue_not_found` |
| Issue is blocked but not a Vibe run | 422 | `missing_vibe_run_id` |
| Approval ID mismatch | 422 | `approval_id_mismatch` |
| Relay not configured in WORKFLOW.md | 503 | `relay_not_configured` |
| `vibe` command not in PATH | 503 | `command_not_found` |

---

## Encryption details

All four Vibe control surfaces use HKDF-SHA256 domain separation over a single X25519 ECDH key exchange:

| Surface | HKDF context | Direction |
|---|---|---|
| `run_start` | `vibe-run-start-v1` | Controller → Node |
| `run_event` | `vibe-run-event-v1` | Node → Controller (streamed events) |
| `run_stop` | `vibe-run-stop-v1` | Controller → Node |
| `approval_response` | `vibe-approval-response-v1` | Controller → Node |

Each message uses a 12-byte random nonce and AES-256-GCM with a 16-byte auth tag.  
The run-local AES keys are stored in `~/.vibe/runs/<run_id>.json` on the controller machine.  
Protect this directory with normal filesystem permissions (`chmod 700 ~/.vibe/runs`).

The relay transport is plaintext WebSocket. For production, put the relay behind TLS (e.g. `wss://relay.example.com`) or tunnel through SSH — the payload remains encrypted regardless.

---

## Limitations of the mock agent

The mock agent (`--agent mock`) emits `approval_required` but does **not** block waiting for the response — it auto-completes approximately 2 seconds later. This means:

- The smoke script successfully proves the approval message round-trip (relay → node → relay → controller)
- The full "agent pauses until approved, then continues" loop requires a real agent (`claude-code`) that actually pauses on `approval_required`
- The Symphony blocked/approve API is fully exercised regardless

To test blocking behavior manually:

```bash
# Watch the event log on the node while the run is in progress
tail -f ~/.vibe/events/<run_id>.jsonl
```

---

## Related scripts

| Script | Tests |
|---|---|
| `smoke_vibe_mock.sh` | Local mock: start → stream → completed (no relay) |
| `smoke_vibe_relay.sh` | Relay: mock agent through remote node |
| `smoke_vibe_approval.sh` | Relay + approval: full approval round-trip |
| `smoke_vibe_relay_claude.sh` | Relay: Claude Code agent (requires `claude` CLI) |

---

## Related docs

- [`vibe-external-executor.md`](vibe-external-executor.md) — how Symphony's ExternalExecutor dispatches to Vibe
- [`vibe-interface-cli/README.md`](../../vibe-interface-cli/README.md) — Vibe CLI reference
- [`vibe-interface-cli/docs/ENCRYPTED_RELAY_DEMO.md`](../../vibe-interface-cli/docs/ENCRYPTED_RELAY_DEMO.md) — Vibe E2E encryption demo
