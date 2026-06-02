# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## Symphony × Vibe integration (MVP 5)

This reference implementation ships with a fully-integrated external worker runtime called
**Vibe** ([`vibe-interface-cli`](https://github.com/JozzyAI/vibe_interface_cli)). Vibe handles
execution on local or remote nodes; Symphony stays as the orchestrator and UI.

### How it fits together

```
Symphony (Elixir orchestrator + UI)
  │  Reads WORKFLOW.md: agent_kind: vibe
  │  1. vibe symphony start  → run_id (E2E encrypted run_start)
  │  2. vibe symphony stream → JSONL events
  ↓
Vibe relay  (plaintext WebSocket, dev: localhost, prod: GCP)
  │  Routes ciphertext only — never sees payload plaintext
  ↓
Vibe Node  (worker host: local machine or remote VM)
  │  Decrypts run_start, spawns backend agent
  │  Streams events back via relay
  ↓
Agent backend (mock / claude-code)
  │  Runs code, emits log/approval_required/status events
  ↓
Symphony  (receives events, updates UI, blocks on approval_required)
  │  POST /api/v1/:issue/approve  →  vibe approval respond  →  encrypted approval_response
  ↓
Agent continues → completed
```

**Roles:**
- **Symphony** — orchestrator and UI; reads Linear, dispatches issues, surfaces state
- **Vibe** — external worker runtime; stable CLI contract for any orchestrator
- **Vibe Node** — execution host; runs on the machine where agents do work
- **Relay** — routing layer; forwards encrypted envelopes between controller and node
- **Agent backend** — executor (mock for local dev, claude-code for real work)
- **Codex/AppServer path** — unchanged default; Vibe is an opt-in `agent_kind: vibe` path

### Current capabilities

| Capability | Status |
|---|---|
| `agent_kind: vibe` ExternalExecutor path | ✅ |
| `mock` backend (no API key, no agent) | ✅ |
| `claude-code` backend (local Claude Code) | ✅ |
| Local Vibe Node (single machine) | ✅ |
| Relay node registration + heartbeat | ✅ |
| Remote node discovery (`vibe node list`) | ✅ |
| Remote run start / event stream / stop | ✅ |
| E2E encrypted `run_start` payload | ✅ AES-256-GCM / HKDF `vibe-run-start-v1` |
| E2E encrypted `run_event` stream | ✅ AES-256-GCM / HKDF `vibe-run-event-v1` |
| E2E encrypted `run_stop` request/ack | ✅ AES-256-GCM / HKDF `vibe-run-stop-v1` |
| E2E encrypted `approval_response` | ✅ AES-256-GCM / HKDF `vibe-approval-response-v1` |
| Symphony dashboard status mapping | ✅ vibe fields in running + blocked payloads |
| Symphony approval API (`POST /approve`) | ✅ validates id, routes to `vibe approval respond` |
| Smoke test suite (mock + relay + approval) | ✅ `elixir/scripts/smoke_vibe_*.sh` |

### Limitations and threat model

| Item | Current state |
|---|---|
| **Relay transport** | Plaintext WebSocket. Dev relay binds to `127.0.0.1`. Put relay behind TLS (`wss://`) for any non-localhost deployment. Payloads remain E2E encrypted regardless. |
| **Relay metadata** | The relay sees: `from`/`to` node IDs, `run_id`/`req_id`, message type, ciphertext size, timestamps, traffic timing. It does **not** see payload contents. |
| **Key storage** | Per-run AES keys stored in `~/.vibe/runs/<run_id>.json`. Identity (X25519) key in `~/.vibe/identity.json`. Protect with `chmod 700 ~/.vibe`. |
| **Forward secrecy** | Each run derives fresh ECDH keys. Keys are deleted after run stop, but if `~/.vibe/runs/` is compromised before deletion, past run payloads can be decrypted. |
| **Outer envelope signing** | Relay envelopes are not signed; a relay operator can observe routing metadata (see above). |
| **Cloud relay** | No hardened production relay deployment yet. The existing relay runs as a plain Node.js process. Add TLS termination, auth hardening, and rate limiting before public exposure. |
| **Mobile approval UI** | Not implemented. Approvals go through Symphony API or CLI only. |
| **Codex/OpenCode backends** | Not implemented in Vibe. The Codex/AppServer path in Symphony is unchanged and unaffected. |
| **Multi-tenant relay** | Not implemented. All nodes on a relay share one token namespace. |

### Quick demo (no Linear, no API key)

```bash
# 1. Install vibe CLI
cd /path/to/vibe-interface-cli
npm install && npm run build && npm link
vibe --version   # → 0.1.0

# 2. Terminal A — start relay with identity enforcement
vibe relay dev --port 7434 --token dev-approval --require-pairing

# 3. Terminal B — pair node identity with relay, then start daemon
vibe node pair   --relay ws://localhost:7434 --token dev-approval
vibe node daemon --local --relay ws://localhost:7434 --token dev-approval

# 4. Terminal B — run the full approval smoke test
cd /path/to/universe-symphony/elixir
bash scripts/smoke_vibe_approval.sh
```

Expected final output:

```
════════════════════════════════════════════════════════════════
  ✅  Symphony Vibe approval smoke PASSED

  run_id:      run_<timestamp>_<hex>
  node:        node_<identity_hex>
  approval_id: appr_<hex>
  decision:    approve

  Encryption summary:
  ├─ run_start payload    → AES-256-GCM (HKDF: vibe-run-start-v1)
  └─ approval_response    → AES-256-GCM (HKDF: vibe-approval-response-v1)
  The relay forwarded ciphertext only — never saw plaintext.
════════════════════════════════════════════════════════════════
```

For the full Symphony integration walkthrough (WORKFLOW.md config, blocked payload JSON, approve/deny curl examples, error codes), see [`docs/SYMPHONY_VIBE_APPROVAL_DEMO.md`](docs/SYMPHONY_VIBE_APPROVAL_DEMO.md).

### Tag this release

```bash
# vibe-interface-cli
cd /path/to/vibe-interface-cli && git tag vibe-symphony-mvp5 && git push origin vibe-symphony-mvp5

# universe-symphony
cd /path/to/universe-symphony && git tag vibe-external-executor-mvp5 && git push jozzy vibe-external-executor-mvp5
```

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
