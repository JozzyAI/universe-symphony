---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "test1-99c9f7e93c92"
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Canceled
    - Duplicate
polling:
  interval_ms: 10000
workspace:
  root: ~/symphony-workspaces
agent:
  max_concurrent_agents: 4
  max_turns: 20
agent_kind: vibe
external:
  command: vibe
binding:
  repo_policy:
    allowed_github_orgs:
      - JozzyAI

  nodes:
    company-node:
      relay: wss://vibe-relay.dynastylab.ai
      token: $VIBE_RELAY_TOKEN
      # node_id is host-specific (regenerated per `~/.vibe/identity.json`,
      # i.e. per machine/WSL session). The value below matches the dev laptop
      # node. To dispatch from a different machine without editing this file,
      # export SYMPHONY_NODE_ID=<that machine's node_id> — Binding.resolve
      # honors it as: SYMPHONY_NODE_ID > binding.node_id > fail fast.
      node_id: node_46429f063508bae4
      allowed_agents:
        - mock
        - claude-code
        - codex

  agents:
    mock:
      permission_mode: default

    claude-code:
      permission_mode: unsafe-skip

    codex:
      permission_mode: unsafe-skip

  defaults:
    repo: https://github.com/JozzyAI/fin_bot
    repo_branch_prefix: linear
    node: company-node
    agent: claude-code
    encrypt: true
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Final message must report completed actions and any blockers only. Do not include "next steps for user".
3. Work only in the provided repository copy. Do not touch any other path.
4. Do not modify the Linear issue (state or comments). Symphony manages Linear status and
   comments based on your git/PR activity — this is not your responsibility.
5. If a Linear MCP server or tool happens to be available in your environment, you may use
   it for your own read-only reference, but it is never required, and you must not stop or
   report a blocker because Linear access is unavailable.

## Workflow

1. Determine current repo state (`branch`, `git status`, `HEAD`).
2. Check whether a PR already exists for a branch associated with this issue
   (e.g. `gh pr list --head <branch>`, where `<branch>` follows this repo's
   `{{ issue.identifier }}`-based naming convention).
   - If an open PR exists: treat this as a feedback/rework pass. Gather feedback from
     top-level PR comments (`gh pr view --comments`), inline review comments
     (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`), and review summaries
     (`gh pr view --json reviews`). Address every actionable comment with code/test/doc
     changes, or reply with an explicit, justified pushback on that thread.
   - If no PR exists (or the existing PR is `CLOSED`/`MERGED`): create a fresh branch from
     `origin/main` named for `{{ issue.identifier }}` and implement the ticket described
     above.
3. Merge the latest `origin/main` into your branch and resolve any conflicts before
   continuing.
4. Run the project's documented validation (tests/lint) for your changes. Re-run after any
   feedback-driven changes. Do not push unless validation passes.
5. Commit your changes with clear messages.
6. Push the branch. Open a new PR (referencing `{{ issue.identifier }}` and linking
   {{ issue.url }} in the description) or update the existing PR.
7. Do not merge any PR. Merge/Linear-status decisions are made outside this session.

## Blocked-access escape hatch

Use this only when completion is blocked by a missing required tool or missing auth/permission
**within this repo or GitHub workflow** (not Linear) that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default — try fallback auth/remote strategies first.
- If genuinely blocked, state in your final message exactly what is missing, why it blocks
  the work, and what a human needs to do to unblock it. Do not attempt any Linear action.
