#!/usr/bin/env bash
# smoke_vibe_relay.sh — End-to-end smoke test: Symphony → relay → remote Vibe Node → mock agent.
#
# Demonstrates the full relay dispatch path:
#   1. Start the Vibe relay dev server
#   2. Register a remote Vibe Node daemon
#   3. Run a Symphony issue through the relay to the remote node
#   4. Stream events back through the relay
#
# Requires:
#   - vibe CLI (install: cd vibe-interface-cli && npm install && npm run build && npm link)
#
# Usage:
#   bash elixir/scripts/smoke_vibe_relay.sh
#
# Overrides:
#   VIBE_CMD="node /path/to/dist/src/index.js" bash ...
#   RELAY_PORT=7433  (default: 7433)
#   RELAY_TOKEN=dev  (default: dev)
#   NODE_ID=my-node  (default: smoke-node)

set -euo pipefail

VIBE_CMD="${VIBE_CMD:-vibe}"
RELAY_PORT="${RELAY_PORT:-7433}"
RELAY_TOKEN="${RELAY_TOKEN:-dev}"
NODE_ID="${NODE_ID:-smoke-node}"
RELAY_URL="ws://localhost:${RELAY_PORT}"

cleanup() {
  echo ""
  echo "── Cleanup ──────────────────────────────────────────────────────────────"
  if [[ -n "${RELAY_PID:-}" ]]; then
    echo "Stopping relay (pid=$RELAY_PID)"
    kill "$RELAY_PID" 2>/dev/null || true
  fi
  if [[ -n "${DAEMON_PID:-}" ]]; then
    echo "Stopping daemon (pid=$DAEMON_PID)"
    kill "$DAEMON_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! $VIBE_CMD --version &>/dev/null; then
  echo "ERROR: vibe CLI not found. Install it:"
  echo "  cd vibe-interface-cli && npm install && npm run build && npm link"
  exit 1
fi

echo "✓ vibe: $($VIBE_CMD --version)"

# ── Step 1: Start relay dev server ─────────────────────────────────────────

echo ""
echo "── Step 1: start relay on port $RELAY_PORT ──"

$VIBE_CMD relay dev --port "$RELAY_PORT" --token "$RELAY_TOKEN" &
RELAY_PID=$!
sleep 0.8

echo "✓ relay started (pid=$RELAY_PID)"

# ── Step 2: Register a node daemon ─────────────────────────────────────────

echo ""
echo "── Step 2: register node daemon (node_id=$NODE_ID) ──"

VIBE_NODE_HEARTBEAT_MS=500 \
  $VIBE_CMD node daemon --local \
    --relay "$RELAY_URL" \
    --token "$RELAY_TOKEN" \
    --node-id "$NODE_ID" &
DAEMON_PID=$!

# Wait for node to register
REGISTERED=false
for i in $(seq 1 15); do
  sleep 0.5
  NODES=$($VIBE_CMD node list --remote --relay "$RELAY_URL" --token "$RELAY_TOKEN" 2>/dev/null || echo "[]")
  if echo "$NODES" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ const ns=JSON.parse(d); process.exit(ns.some(n=>n.node_id==='$NODE_ID'&&n.status==='online')?0:1) })" 2>/dev/null; then
    REGISTERED=true
    break
  fi
done

if [[ "$REGISTERED" != "true" ]]; then
  echo "ERROR: node $NODE_ID did not register within 8s"
  exit 1
fi

echo "✓ node registered: $(
  $VIBE_CMD node list --remote --relay "$RELAY_URL" --token "$RELAY_TOKEN" 2>/dev/null \
    | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ const ns=JSON.parse(d); const n=ns.find(n=>n.node_id==='$NODE_ID'); console.log(JSON.stringify(n)) })"
)"

# ── Step 3: Symphony start via relay ───────────────────────────────────────

echo ""
echo "── Step 3: vibe symphony start --node $NODE_ID --relay $RELAY_URL ──"

ISSUE_ID="smoke-relay-$$"

START_OUT=$($VIBE_CMD symphony start \
  --agent mock \
  --node "$NODE_ID" \
  --relay "$RELAY_URL" \
  --token "$RELAY_TOKEN" \
  --issue-id "$ISSUE_ID" \
  --issue-title "Relay smoke test" \
  --workspace-key "$ISSUE_ID" \
  --json)

echo "start output: $START_OUT"

RUN_ID=$(echo "$START_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).run_id))")
STATUS=$(echo "$START_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).status))")
NODE_OUT=$(echo "$START_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).node_id))")

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

echo "✓ run dispatched to remote node"

# ── Step 4: Symphony stream via relay ──────────────────────────────────────

echo ""
echo "── Step 4: vibe symphony stream $RUN_ID --relay $RELAY_URL ──"

LAST_STATUS=""
while IFS= read -r line; do
  echo "  event: $line"
  TYPE=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.type||'')+'\n')}catch{} })" 2>/dev/null || true)
  if [[ "$TYPE" == "status" ]]; then
    LAST_STATUS=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.status||'')+'\n')}catch{} })" 2>/dev/null || true)
  fi
done < <($VIBE_CMD symphony stream "$RUN_ID" \
  --relay "$RELAY_URL" \
  --token "$RELAY_TOKEN" \
  --jsonl)

echo ""
echo "last status: $LAST_STATUS"

if [[ "$LAST_STATUS" != "completed" ]]; then
  echo "ERROR: expected last status=completed, got '$LAST_STATUS'"
  exit 1
fi

echo "✓ stream completed through relay"

# ── Done ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✅  Symphony relay smoke PASSED"
echo "  run_id:  $RUN_ID"
echo "  agent:   mock"
echo "  node:    $NODE_ID"
echo "  relay:   $RELAY_URL"
echo "════════════════════════════════════════════════════════"
