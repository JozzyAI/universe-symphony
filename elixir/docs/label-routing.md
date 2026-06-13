# Label Routing

This describes how Symphony picks an agent, repo, and node for a Linear issue
when `agent_kind: vibe` (see `binding:` in `WORKFLOW.md`). The implementation
is `SymphonyElixir.Binding`.

## Dispatch model

- **`Todo` is the dispatch queue.** Any issue in `Todo` is eligible to be
  picked up — there is no separate "ready" label or gate. Moving an issue to
  `Todo` (or leaving it there) is how you ask Symphony to work on it.
- **Labels are optional.** An issue with no `agent:*`/`repo:*`/`node:*`
  labels uses `binding.defaults` from `WORKFLOW.md` for all three fields.
  Labels only need to be added when an issue should deviate from the
  defaults.

## Label vocabulary

| Label | Resolves to |
| --- | --- |
| `agent:codex` | `agents.codex` |
| `agent:claude-code` | `agents.claude-code` |
| `agent:mock` | `agents.mock` |
| `repo:fin_bot` | `https://github.com/JozzyAI/fin_bot` |
| `repo:vibe_interface_cli` | `https://github.com/JozzyAI/vibe_interface_cli` |
| `repo:universe-symphony` | `https://github.com/JozzyAI/universe-symphony` |
| `node:joey-pc` | `nodes.joey-pc` (`node_id: node_f7cedd3b6590aff9`) |
| `node:company-node` | `nodes.company-node` |

A full GitHub URL or `org/repo` shorthand also works for `repo:*` (e.g.
`repo:https://github.com/JozzyAI/fin_bot`, `repo:JozzyAI/fin_bot`), subject to
the same `repo_policy.allowed_github_orgs` / `repo_policy.allowed_repos`
checks as the bare-name form above.

Both `agent:`/`repo:`/`node:` (colon) and `agent/`/`repo/`/`node/` (slash)
syntaxes are accepted. Labels may be set on the issue itself or on its
project; issue labels take priority over project labels, which take priority
over the project's GitHub "Resources" repo link, which takes priority over
the project's `vibe:` block, which takes priority over `binding.defaults` —
see `docs/project-resources.md` for the full repo resolution order.

If no `repo:*` label, project Resources link, `vibe.repo`, or
`binding.defaults.repo` resolves to a repo at all, dispatch fails fast with a
comment asking for a repo binding and moves the issue to **Human Review** —
Symphony never guesses a repo. This is how
`tracker.auto_discover_projects: true` can watch every active Linear Project
in a team even before it has a repo configured.

## Current defaults

With no labels at all, an issue resolves to:

- `agent:codex`
- `repo:fin_bot` (`https://github.com/JozzyAI/fin_bot`)
- `node:joey-pc` (`node_id: node_f7cedd3b6590aff9`)

## Fail-fast on invalid labels

Symphony never silently falls back when a label is present but invalid:

- **More than one label of the same type** (e.g. two `agent:*` labels, or an
  `agent:*` label on both the issue and its project) is a conflict.
- **An `agent:*`, `repo:*`, or `node:*` label naming something not configured**
  (not in `binding.agents`, `repo_policy.allowed_repos`/
  `repo_policy.allowed_github_orgs`, or `binding.nodes`) is unrecognized.

In either case, dispatch is skipped: Symphony posts a comment on the Linear
issue explaining the problem (which labels conflicted, or which label was
unrecognized and what the valid values are) and moves the issue to **Human
Review**.

**To retry:** fix or remove the offending label(s) and move the issue back to
**Todo**. Symphony will pick it up again on the next poll.

## Merging and auto-merge

The `Merging` state exists in `tracker.active_states` for future use, but
Symphony does not currently act on it — it is a no-op today. **Symphony never
merges a PR.** Agents open or update PRs and Symphony moves the issue to
`Human Review`; a human reviews and merges.
