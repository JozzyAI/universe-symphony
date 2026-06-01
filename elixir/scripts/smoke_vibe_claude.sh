#!/usr/bin/env bash
# smoke_vibe_claude.sh — Smoke test for Vibe ExternalExecutor with claude-code backend.
#
# Skips cleanly if `claude` is not in PATH.
#
# Requires:
#   - claude CLI installed and authenticated
#   - vibe-interface-cli built (npm run build)
#
# Usage:
#   VIBE_CLI=/path/to/vibe-interface-cli/dist/src/index.js scripts/smoke_vibe_claude.sh

set -euo pipefail

# ── Claude check ────────────────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo "SKIP: claude CLI not found in PATH. Install Claude Code to run this smoke test."
  echo "  https://claude.ai/code"
  exit 0
fi

echo "✓ claude: $(claude --version 2>/dev/null | head -1)"

# ── Vibe CLI check ───────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(dirname "$SCRIPT_DIR")"

VIBE_CLI="${VIBE_CLI:-}"

if [[ -z "$VIBE_CLI" ]]; then
  CANDIDATE="$(dirname "$ELIXIR_DIR")/../vibe-interface-cli/dist/src/index.js"
  if [[ -f "$CANDIDATE" ]]; then
    VIBE_CLI="$(realpath "$CANDIDATE")"
  fi
fi

if [[ -z "$VIBE_CLI" ]] || ! [[ -f "$VIBE_CLI" ]]; then
  echo "ERROR: vibe CLI not found. Set VIBE_CLI=/path/to/dist/src/index.js"
  exit 1
fi

VIBE_CMD="node $VIBE_CLI"
echo "✓ vibe CLI: $VIBE_CLI"

# ── Write prompt file ────────────────────────────────────────────────────────

PROMPT_FILE="$(mktemp /tmp/vibe-smoke-claude-XXXX.md)"
cat > "$PROMPT_FILE" <<'EOF'
Say hello and confirm you are working correctly.
Output exactly one line: "Hello from Claude. Smoke test passed."
Do not write any files or run any commands.
EOF

echo "✓ prompt: $PROMPT_FILE"

# ── Step 1: start ────────────────────────────────────────────────────────────

echo ""
echo "── Step 1: vibe symphony start --agent claude-code ──"

ISSUE_ID="smoke-claude-$$"

START_OUT=$($VIBE_CMD symphony start \
  --agent claude-code \
  --issue-id "$ISSUE_ID" \
  --issue-title "Smoke test — claude-code" \
  --workspace-key "$ISSUE_ID" \
  --prompt-file "$PROMPT_FILE" \
  --permission-mode unsafe-skip \
  --json)

echo "start output: $START_OUT"

RUN_ID=$(echo "$START_OUT" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).run_id))")

echo "run_id: $RUN_ID"

# ── Step 2: stream ───────────────────────────────────────────────────────────

echo ""
echo "── Step 2: vibe symphony stream $RUN_ID --jsonl ──"
echo "   (this may take 15-60s for Claude to respond)"

LAST_STATUS=""
while IFS= read -r line; do
  TYPE=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write(e.type+'\n')}catch{} })" 2>/dev/null || true)
  if [[ "$TYPE" == "log" ]]; then
    MSG=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.message||'')+'\n')}catch{} })" 2>/dev/null || true)
    echo "  [log] $MSG"
  elif [[ "$TYPE" == "tool_call" ]]; then
    TOOL=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.tool||'')+'\n')}catch{} })" 2>/dev/null || true)
    echo "  [tool] $TOOL"
  elif [[ "$TYPE" == "status" ]]; then
    LAST_STATUS=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.status||'')+'\n')}catch{} })" 2>/dev/null || true)
    echo "  [status] $LAST_STATUS"
  elif [[ "$TYPE" == "error" ]]; then
    MSG=$(echo "$line" | node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{const e=JSON.parse(d); process.stdout.write((e.message||'')+'\n')}catch{} })" 2>/dev/null || true)
    echo "  [error] $MSG"
  fi
done < <($VIBE_CMD symphony stream "$RUN_ID" --jsonl)

rm -f "$PROMPT_FILE"

echo ""
echo "last status: $LAST_STATUS"

if [[ "$LAST_STATUS" == "completed" ]]; then
  echo ""
  echo "════════════════════════════════════════════"
  echo "  ✅  Vibe claude-code smoke PASSED"
  echo "  run_id: $RUN_ID"
  echo "  agent:  claude-code"
  echo "════════════════════════════════════════════"
elif [[ "$LAST_STATUS" == "failed" ]]; then
  echo ""
  echo "════════════════════════════════════════════"
  echo "  ⚠️  Vibe claude-code smoke: FAILED"
  echo "  run_id: $RUN_ID"
  echo "  Check ~/.vibe/events/$RUN_ID.jsonl for details."
  echo "════════════════════════════════════════════"
  exit 1
else
  echo "ERROR: unexpected last status '$LAST_STATUS'"
  exit 1
fi
