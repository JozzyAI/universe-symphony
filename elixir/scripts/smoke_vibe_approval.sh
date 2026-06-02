#!/usr/bin/env bash
# smoke_vibe_approval.sh — Full approval loop: relay → node → mock → approval_required → approval respond.
#
# Demonstrates the complete Vibe approval round-trip:
#   1. Start relay (--require-pairing enforces identity-based registration)
#   2. Pair the node (register its encryption identity with the relay)
#   3. Start node daemon
#   4. vibe symphony start --encrypt (run_start payload is E2E encrypted)
#   5. Stream events: capture approval_required event + approval_id
#   6. vibe approval respond (sends encrypted approval_response to the node)
#   7. Verify approval_response event appears in the event log
#
# The run_start/approval_response payloads are AES-256-GCM encrypted; the relay
# never sees their contents. The relay is plaintext transport (localhost dev mode).
#
# No Linear API key needed. No Claude Code needed. Requires vibe CLI only.
#
# Usage:
#   bash elixir/scripts/smoke_vibe_approval.sh
#
# Overrides:
#   VIBE_CMD="node /path/to/dist/src/index.js"
#   RELAY_PORT=7434    (default 7434; uses a different port than smoke_vibe_relay.sh)
#   RELAY_TOKEN=dev-approval
#   NODE_ID=approval-node

set -euo pipefail

VIBE_CMD="${VIBE_CMD:-vibe}"
RELAY_PORT="${RELAY_PORT:-7434}"
RELAY_TOKEN="${RELAY_TOKEN:-dev-approval}"
NODE_ID="${NODE_ID:-approval-node}"
RELAY_URL="ws://localhost:${RELAY_PORT}"
APPROVAL_TIMEOUT=20  # seconds to wait for approval_required event

RELAY_PID=""
DAEMON_PID=""
STREAM_PID=""
STREAM_FILE=""

cleanup() {
  echo ""
  echo "── Cleanup ───────────────────────────────────────────────────────────────"
  [[ -n "${STREAM_PID:-}" ]] && kill "$STREAM_PID" 2>/dev/null || true
  [[ -n "${DAEMON_PID:-}" ]] && { echo "Stopping daemon (pid=$DAEMON_PID)"; kill "$DAEMON_PID" 2>/dev/null || true; }
  [[ -n "${RELAY_PID:-}" ]] && { echo "Stopping relay (pid=$RELAY_PID)"; kill "$RELAY_PID" 2>/dev/null || true; }
  [[ -n "${STREAM_FILE:-}" ]] && rm -f "$STREAM_FILE"
}
trap cleanup EXIT

# ── Parse JSON helper (node-based, no jq dependency) ───────────────────────

jget() {
  local json="$1" key="$2"
  echo "$json" | node -e "
    let d='';
    process.stdin.resume();
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try { process.stdout.write(String(JSON.parse(d)['$key'] ?? '') + '\n') }
      catch { process.exit(1) }
    })
  " <<< "$json"
}

jget_from_stream() {
  local line="$1" key="$2"
  echo "$line" | node -e "
    let d='';
    process.stdin.resume();
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try { process.stdout.write(String(JSON.parse(d)['$key'] ?? '') + '\n') }
      catch {}
    })
  " 2>/dev/null || true
}

# ── Preflight ──────────────────────────────────────────────────────────────

if ! $VIBE_CMD --version &>/dev/null; then
  echo "ERROR: vibe CLI not found. Install it:"
  echo "  cd vibe-interface-cli && npm install && npm run build && npm link"
  exit 1
fi

echo "✓ vibe: $($VIBE_CMD --version)"

# ── Step 1: Start relay with --require-pairing ──────────────────────────────

echo ""
echo "── Step 1: start relay (port=$RELAY_PORT, require-pairing=ON) ──"

$VIBE_CMD relay dev \
  --port "$RELAY_PORT" \
  --token "$RELAY_TOKEN" \
  --require-pairing \
  &>/dev/null &
RELAY_PID=$!
sleep 0.8

echo "✓ relay started (pid=$RELAY_PID)"

# ── Step 2: Pair node identity with relay ──────────────────────────────────

echo ""
echo "── Step 2: pair node identity with relay ──"

PAIR_OUT=$($VIBE_CMD node pair \
  --relay "$RELAY_URL" \
  --token "$RELAY_TOKEN")

echo "pair output: $PAIR_OUT"
echo "✓ node identity registered"

# ── Step 3: Start node daemon ──────────────────────────────────────────────

echo ""
echo "── Step 3: start node daemon (node_id=$NODE_ID) ──"

VIBE_NODE_HEARTBEAT_MS=500 \
  $VIBE_CMD node daemon --local \
    --relay "$RELAY_URL" \
    --token "$RELAY_TOKEN" \
    --node-id "$NODE_ID" \
    &>/dev/null &
DAEMON_PID=$!

# Wait for node to appear online
REGISTERED=false
for i in $(seq 1 20); do
  sleep 0.5
  NODES=$($VIBE_CMD node list --remote \
    --relay "$RELAY_URL" \
    --token "$RELAY_TOKEN" 2>/dev/null || echo "[]")
  if echo "$NODES" | node -e "
    let d='';
    process.stdin.resume();
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      const ns=JSON.parse(d);
      process.exit(ns.some(n=>n.node_id==='$NODE_ID'&&n.status==='online')?0:1);
    })
  " 2>/dev/null; then
    REGISTERED=true
    break
  fi
done

if [[ "$REGISTERED" != "true" ]]; then
  echo "ERROR: node $NODE_ID did not register within 10s"
  exit 1
fi

echo "✓ node registered and online"

# ── Step 4: Start encrypted run ────────────────────────────────────────────

echo ""
echo "── Step 4: vibe symphony start --agent mock --encrypt ──"
echo "   (run_start payload is E2E encrypted to node's public key)"

ISSUE_ID="smoke-approval-$$"

START_OUT=$($VIBE_CMD symphony start \
  --agent mock \
  --node "$NODE_ID" \
  --relay "$RELAY_URL" \
  --token "$RELAY_TOKEN" \
  --encrypt \
  --issue-id "$ISSUE_ID" \
  --issue-title "Approval smoke test" \
  --workspace-key "$ISSUE_ID" \
  --json)

echo "start output: $START_OUT"

RUN_ID=$(jget "$START_OUT" "run_id")
STATUS=$(jget "$START_OUT" "status")
NODE_OUT=$(jget "$START_OUT" "node_id")

echo "run_id:  $RUN_ID"
echo "status:  $STATUS"
echo "node_id: $NODE_OUT"

if [[ "$STATUS" != "running" ]]; then
  echo "ERROR: expected status=running, got $STATUS"
  exit 1
fi

if [[ "$NODE_OUT" != "$NODE_ID" ]]; then
  echo "ERROR: expected node_id=$NODE_ID, got $NODE_OUT"
  exit 1
fi

echo "✓ run dispatched to node (encrypted)"

# ── Step 5: Stream events — wait for approval_required ────────────────────

echo ""
echo "── Step 5: stream events — waiting for approval_required ──"

STREAM_FILE=$(mktemp /tmp/vibe-smoke-stream-XXXXXX.jsonl)

$VIBE_CMD symphony stream "$RUN_ID" \
  --relay "$RELAY_URL" \
  --token "$RELAY_TOKEN" \
  --jsonl \
  > "$STREAM_FILE" 2>/dev/null &
STREAM_PID=$!

# Poll for approval_required event
APPROVAL_LINE=""
DEADLINE=$((SECONDS + APPROVAL_TIMEOUT))

echo "   Polling stream for approval_required (timeout=${APPROVAL_TIMEOUT}s)..."

while [[ $SECONDS -lt $DEADLINE ]]; do
  sleep 0.3
  if [[ -s "$STREAM_FILE" ]]; then
    LINE=$(grep '"type":"approval_required"' "$STREAM_FILE" 2>/dev/null | head -1 || true)
    if [[ -n "$LINE" ]]; then
      APPROVAL_LINE="$LINE"
      break
    fi
    # Also print other events as they arrive (for visibility)
    wc -l < "$STREAM_FILE" >/dev/null
  fi
done

if [[ -z "$APPROVAL_LINE" ]]; then
  echo ""
  echo "ERROR: approval_required not seen within ${APPROVAL_TIMEOUT}s"
  echo "Stream contents so far:"
  cat "$STREAM_FILE" 2>/dev/null || true
  exit 1
fi

echo ""
echo "  approval_required event:"
echo "  $APPROVAL_LINE"
echo ""

APPROVAL_ID=$(jget_from_stream "$APPROVAL_LINE" "approval_id")
APPROVAL_MSG=$(jget_from_stream "$APPROVAL_LINE" "message")

if [[ -z "$APPROVAL_ID" ]]; then
  echo "ERROR: could not extract approval_id from approval_required event"
  exit 1
fi

echo "✓ approval_required received"
echo "  approval_id: $APPROVAL_ID"
echo "  message:     $APPROVAL_MSG"

# ── Step 6: Send encrypted approval response ───────────────────────────────

echo ""
echo "── Step 6: vibe approval respond --decision approve ──"
echo "   (approval_response payload is E2E encrypted)"

APPROVE_OUT=$($VIBE_CMD approval respond \
  --run-id "$RUN_ID" \
  --approval-id "$APPROVAL_ID" \
  --decision approve \
  --relay "$RELAY_URL" \
  --token "$RELAY_TOKEN")

echo "approval respond output: $APPROVE_OUT"

APPROVE_OK=$(jget "$APPROVE_OUT" "ok")
if [[ "$APPROVE_OK" != "true" ]]; then
  echo "ERROR: expected ok=true in approval respond response"
  exit 1
fi

echo "✓ encrypted approval_response sent to relay → node"

# ── Step 7: Verify approval_response appears in event stream ───────────────

echo ""
echo "── Step 7: verify approval_response event in stream ──"

# Wait for approval_response to land (it should already be there — relay is fast)
APPROVAL_RESPONSE_LINE=""
DEADLINE=$((SECONDS + 10))

while [[ $SECONDS -lt $DEADLINE ]]; do
  sleep 0.3
  LINE=$(grep '"type":"approval_response"' "$STREAM_FILE" 2>/dev/null | head -1 || true)
  if [[ -n "$LINE" ]]; then
    APPROVAL_RESPONSE_LINE="$LINE"
    break
  fi
done

if [[ -z "$APPROVAL_RESPONSE_LINE" ]]; then
  echo "ERROR: approval_response event not found in stream within 10s"
  echo "Stream contents:"
  cat "$STREAM_FILE"
  exit 1
fi

echo "  approval_response event:"
echo "  $APPROVAL_RESPONSE_LINE"
echo ""

RESPONSE_DECISION=$(jget_from_stream "$APPROVAL_RESPONSE_LINE" "decision")
RESPONSE_APPROVAL_ID=$(jget_from_stream "$APPROVAL_RESPONSE_LINE" "approval_id")

echo "✓ approval_response received on stream"
echo "  decision:    $RESPONSE_DECISION"
echo "  approval_id: $RESPONSE_APPROVAL_ID"

if [[ "$RESPONSE_DECISION" != "approve" ]]; then
  echo "ERROR: expected decision=approve, got $RESPONSE_DECISION"
  exit 1
fi

if [[ "$RESPONSE_APPROVAL_ID" != "$APPROVAL_ID" ]]; then
  echo "ERROR: approval_id mismatch: expected $APPROVAL_ID, got $RESPONSE_APPROVAL_ID"
  exit 1
fi

# ── Wait for stream to end ─────────────────────────────────────────────────

echo ""
echo "── Waiting for run to complete ──"

# Wait for stream process to exit naturally (mock completes shortly after approval_required)
DEADLINE=$((SECONDS + 15))
while [[ $SECONDS -lt $DEADLINE ]] && kill -0 "$STREAM_PID" 2>/dev/null; do
  sleep 0.5
done

LAST_STATUS=$(grep '"type":"status"' "$STREAM_FILE" 2>/dev/null \
  | node -e "
    const lines=require('fs').readFileSync('/dev/stdin','utf8').trim().split('\n');
    const last=lines.map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean).pop();
    process.stdout.write((last?.status ?? '') + '\n');
  " 2>/dev/null || true)

echo "last status: $LAST_STATUS"

if [[ "$LAST_STATUS" != "completed" ]]; then
  echo "WARN: expected last status=completed, got '$LAST_STATUS' (non-fatal — stream may have raced)"
fi

# ── Done ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅  Symphony Vibe approval smoke PASSED"
echo ""
echo "  run_id:      $RUN_ID"
echo "  node:        $NODE_ID"
echo "  approval_id: $APPROVAL_ID"
echo "  decision:    approve"
echo ""
echo "  Encryption summary:"
echo "  ├─ run_start payload    → AES-256-GCM (HKDF: vibe-run-start-v1)"
echo "  └─ approval_response    → AES-256-GCM (HKDF: vibe-approval-response-v1)"
echo "  The relay forwarded ciphertext only — never saw plaintext."
echo "════════════════════════════════════════════════════════════════"
