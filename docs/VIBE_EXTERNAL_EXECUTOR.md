# Symphony × Vibe — ExternalExecutor

This document is for Symphony operators who want to dispatch work through Vibe instead of (or
alongside) the default Codex AppServer path.

---

## The problem this solves

The default Symphony execution path looks like:

```
Symphony → AgentRunner → Codex AppServer (JSON-RPC) → coding agent
```

This works well when Codex is available, but it locks Symphony to one execution model and one
agent runtime on one machine.

Vibe introduces a different seam:

```
Symphony → AgentRunner → ExternalExecutor → vibe symphony start/stream → Vibe Node → agent
```

The Vibe Node can be the local machine or a remote machine connected through a relay. The agent
can be `mock` (for testing), `claude-code`, or future backends. Symphony does not need to know
which machine runs the work or which agent processes it — that is Vibe's responsibility.

---

## How to enable it

Add `agent_kind: vibe` to your `WORKFLOW.md`:

**Local node (no relay):**
```yaml
agent_kind: vibe
external:
  command: vibe         # or: node /path/to/dist/src/index.js
  agent: mock           # or: claude-code
```

**Remote node over relay:**
```yaml
agent_kind: vibe
external:
  command: vibe
  agent: claude-code
  node: my-node                      # node_id registered with the relay
  relay: ws://localhost:7434         # relay WebSocket URL
  token: dev-token                   # relay auth token
  permission_mode: unsafe-skip       # optional; enables --dangerously-skip-permissions
```

When `agent_kind: vibe` is set, Symphony's `AgentRunner` calls `ExternalExecutor` instead of
`AppServer`. The Codex JSON-RPC path is bypassed entirely and is not affected.

---

## What Symphony dispatches

When an issue is picked up, `ExternalExecutor.run/4` calls:

```bash
vibe symphony start \
  --agent <agent> \
  --issue-id <id> \
  --issue-title <title> \
  --workspace-key <key> \
  [--node <node_id>] \
  [--relay <url> --token <token>] \
  [--encrypt] \
  --json
```

The call returns a JSON run record:

```json
{
  "run_id": "run_20260602_abc123",
  "node_id": "my-node",
  "agent": "claude-code",
  "status": "running"
}
```

Symphony stores `run_id`, `node_id`, and `agent` in the running entry and exposes them in the
issue status payload.

---

## Event flow

`ExternalExecutor` then streams:

```bash
vibe symphony stream <run_id> [--relay ... --token ...] --jsonl
```

Events arrive as JSONL. Symphony handles each type:

| Event type | Symphony action |
|---|---|
| `status: running` | Stores `vibe_start` metadata (run_id, node_id, agent) |
| `log` | Records in session log (stdout/stderr, tool_call) |
| `approval_required` | Stores `vibe_approval_id` + `vibe_approval_message`; moves issue to blocked state |
| `approval_response` | Records that approval was relayed to node |
| `pr_created` | Records PR URL in session |
| `status: completed` | Marks run done, session complete |
| `status: failed` | Schedules retry according to WORKFLOW.md retry config |
| `status: blocked` | Moves issue to blocked state |

---

## Blocked state and the approval loop

When the agent emits `approval_required`, `ExternalExecutor` returns
`{:error, {:blocked, :approval_required, event}}`. The Orchestrator moves the issue to blocked and
stores the approval fields.

The issue status payload includes:

```json
{
  "status": "blocked",
  "blocked": {
    "vibe_run_id": "run_20260602_abc123",
    "vibe_node_id": "my-node",
    "vibe_agent": "claude-code",
    "vibe_approval_id": "appr_m5x4z",
    "vibe_approval_message": "Proceed with modifying tracked files?"
  }
}
```

An operator approves via the Symphony API:

```bash
curl -X POST http://localhost:4000/api/v1/ENG-123/approve \
  -H "Content-Type: application/json" \
  -d '{"approval_id":"appr_m5x4z","decision":"approve"}'
```

Symphony validates the `approval_id`, reads relay config from `WORKFLOW.md`, and calls:

```bash
vibe approval respond \
  --run-id run_20260602_abc123 \
  --approval-id appr_m5x4z \
  --decision approve \
  --relay ws://localhost:7434 \
  --token dev-token
```

The `approval_response` payload is E2E encrypted — the relay routes it without reading the
decision. The node decrypts, appends an `approval_response` event to the run log, and the agent
continues.

### Denial

```bash
curl -X POST http://localhost:4000/api/v1/ENG-123/approve \
  -H "Content-Type: application/json" \
  -d '{"approval_id":"appr_m5x4z","decision":"deny","message":"Too risky"}'
```

### Error codes

| `error.code` | Meaning |
|---|---|
| `missing_approval_id` | Request body missing `approval_id` |
| `invalid_decision` | `decision` is not `approve` or `deny` |
| `issue_not_found` | Issue not in blocked state (or not found) |
| `missing_vibe_run_id` | Issue is blocked but has no Vibe run_id |
| `missing_vibe_approval_id` | Issue is blocked but has no approval_id stored |
| `approval_id_mismatch` | Sent `approval_id` does not match what the node requested |
| `relay_not_configured` | `relay` or `token` missing from WORKFLOW.md `external` block |
| `command_not_found` | `vibe` command not in PATH |

---

## Encryption

When `relay` and `token` are configured, `ExternalExecutor` passes `--encrypt` to
`vibe symphony start`. All four control surfaces are E2E encrypted using X25519 ECDH +
AES-256-GCM with HKDF-SHA256 domain separation:

| Surface | HKDF context |
|---|---|
| `run_start` payload | `vibe-run-start-v1` |
| `run_event` stream | `vibe-run-event-v1` |
| `run_stop` request/ack | `vibe-run-stop-v1` |
| `approval_response` | `vibe-approval-response-v1` |

The relay sees routing metadata (`run_id`, `node_id`, timestamps, message sizes) but never
payload contents: prompt, agent output, stop reason, or approval decision.

Per-run AES keys are stored in `~/.vibe/runs/<run_id>.json` on the controller machine.
Protect that directory: `chmod 700 ~/.vibe/runs`.

---

## Running the demo

The smoke test proves the full approval loop without requiring Linear, Claude Code, or any API
key:

```bash
# 1. Install and link the Vibe CLI
cd /path/to/vibe-interface-cli
npm install && npm run build && npm link

# 2. Terminal A — relay with identity enforcement
vibe relay dev --port 7434 --token dev-approval --require-pairing

# 3. Terminal B — pair node and start daemon
vibe node pair   --relay ws://localhost:7434 --token dev-approval
vibe node daemon --local --relay ws://localhost:7434 --token dev-approval

# 4. Run the smoke script
cd universe-symphony/elixir
bash scripts/smoke_vibe_mock.sh       # local mock, no relay
bash scripts/smoke_vibe_approval.sh   # relay + approval round-trip
```

Expected result for `smoke_vibe_approval.sh`:

```
✅  Symphony Vibe approval smoke PASSED
  run_id:      run_<timestamp>_<hex>
  node:        node_<identity_hex>
  approval_id: appr_<hex>
  decision:    approve
  ├─ run_start payload    → AES-256-GCM (HKDF: vibe-run-start-v1)
  └─ approval_response    → AES-256-GCM (HKDF: vibe-approval-response-v1)
  The relay forwarded ciphertext only — never saw plaintext.
```

---

## Related docs

| Document | Content |
|---|---|
| [`SYMPHONY_VIBE_APPROVAL_DEMO.md`](SYMPHONY_VIBE_APPROVAL_DEMO.md) | Full walkthrough: WORKFLOW.md config, blocked payload JSON, curl examples, error table, encryption details |
| [`vibe-interface-cli/README.md`](../../vibe-interface-cli/README.md) | Vibe CLI reference: backends, relay, identity, state files, event types |
| [`vibe-interface-cli/docs/ENCRYPTED_RELAY_DEMO.md`](../../vibe-interface-cli/docs/ENCRYPTED_RELAY_DEMO.md) | E2E encryption walkthrough |

---

## What is not implemented yet

| Item | Status |
|---|---|
| Codex / OpenCode backends in Vibe | Not implemented — Codex AppServer path in Symphony is unchanged |
| Production cloud relay | Not implemented — dev relay only |
| Mobile approval UI | Not implemented — approvals go through API or CLI |
| Upstream Symphony PR | Not upstreamed — this lives in the `universe-symphony` fork |
