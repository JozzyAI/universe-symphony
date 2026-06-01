#!/usr/bin/env bash
# smoke_vibe_mock.sh — End-to-end smoke test for the Vibe ExternalExecutor with mock agent.
#
# Does NOT require:
#   - Linear API key
#   - Claude Code CLI
#   - Remote nodes or relay
#
# Requires:
#   - vibe CLI (install: cd vibe-interface-cli && npm install && npm run build && npm link)
#
# Usage:
#   bash elixir/scripts/smoke_vibe_mock.sh
#
# Override vibe location:
#   VIBE_CMD="node /path/to/dist/src/index.js" bash elixir/scripts/smoke_vibe_mock.sh

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────

# Default to the global `vibe` command from `npm link`.
# Override via VIBE_CMD env for dev (e.g. VIBE_CMD="node /path/to/dist/src/index.js").
VIBE_CMD="${VIBE_CMD:-vibe}"

if ! $VIBE_CMD --version &>/dev/null; then
  echo "ERROR: vibe CLI not found. Install it:"
  echo "  git clone https://github.com/JozzyAI/vibe_interface_cli"
  echo "  cd vibe_interface_cli && npm install && npm run build && npm link"
  exit 1
fi

echo "✓ vibe: $($VIBE_CMD --version)"

# ── Step 1: Verify vibe symphony start (mock) ───────────────────────────────

echo ""
echo "── Step 1: vibe symphony start --agent mock ──"

ISSUE_ID="smoke-mock-$$"
WORKSPACE_KEY="smoke-mock-$$"

START_OUT=$($VIBE_CMD symphony start \
  --agent mock \
  --issue-id "$ISSUE_ID" \
  --issue-title "Smoke test — mock agent" \
  --workspace-key "$WORKSPACE_KEY" \
  --json)

echo "start output: $START_OUT"

RUN_ID=$(echo "$START_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).run_id))")
STATUS=$(echo "$START_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).status))")

echo "run_id: $RUN_ID"
echo "status: $STATUS"

if [[ "$STATUS" != "running" ]]; then
  echo "ERROR: expected status=running, got $STATUS"
  exit 1
fi

echo "✓ start returned running run_id"

# ── Step 2: vibe symphony stream → completed ────────────────────────────────

echo ""
echo "── Step 2: vibe symphony stream $RUN_ID --jsonl ──"

LAST_STATUS=""
while IFS= read -r line; do
  TYPE=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write(e.type+'\n')}catch{} })" 2>/dev/null || true)
  echo "  event: $line"
  if [[ "$TYPE" == "status" ]]; then
    LAST_STATUS=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.status||'')+'\n')}catch{} })" 2>/dev/null || true)
  fi
done < <($VIBE_CMD symphony stream "$RUN_ID" --jsonl)

echo ""
echo "last status: $LAST_STATUS"

if [[ "$LAST_STATUS" != "completed" ]]; then
  echo "ERROR: expected last status=completed, got '$LAST_STATUS'"
  exit 1
fi

echo "✓ stream ended with status=completed"

# ── Step 3: vibe symphony status confirmation ───────────────────────────────

echo ""
echo "── Step 3: vibe symphony status $RUN_ID ──"

FINAL_OUT=$($VIBE_CMD symphony status "$RUN_ID" --json)
FINAL_STATUS=$(echo "$FINAL_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).status))")

echo "final status: $FINAL_STATUS"

if [[ "$FINAL_STATUS" != "completed" ]]; then
  echo "ERROR: expected final status=completed, got $FINAL_STATUS"
  exit 1
fi

echo "✓ status confirmed completed"

# ── Done ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  ✅  Vibe ExternalExecutor smoke PASSED"
echo "  run_id: $RUN_ID"
echo "  agent:  mock"
echo "════════════════════════════════════════"
