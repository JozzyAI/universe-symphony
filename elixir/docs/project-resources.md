# Project Resources (discovery spike)

This documents the data Symphony reads from a Linear project's "Resources"
section (external links shown on the project overview page), and how this is
expected to fit into repo binding in the future.

## What's implemented today

- `SymphonyElixir.Linear.Client` queries `project.links.nodes { url label }`
  (the `ProjectLink` GraphQL type) alongside the existing
  `project.description` / `project.content` / `project.labels` fields.
- `SymphonyElixir.Linear.Issue.project_resources` is a flat list of the raw
  resource URLs for the issue's project, in the order Linear returns them.
  Links without a `url` are dropped; nothing else is filtered or interpreted.
- `SymphonyElixir.Linear.ProjectResources.github_repo_urls/1` picks out
  `https://github.com/<org>/<repo>` links from that list, normalizing away
  trailing paths (`/pull/42`, `/tree/main`), `.git` suffixes, and trailing
  slashes, and de-duplicating.

**This is additive only.** `project_resources` is not yet consulted by
`SymphonyElixir.Binding` — repo/agent/node resolution behaves exactly as
described in `label-routing.md` today.

## Intended future priority (not yet implemented)

Once a Project GitHub resource link is wired into `Binding.resolve`, the
intended repo resolution order — highest priority first — is:

1. **Issue `repo:*` label** — explicit per-issue override (unchanged).
2. **Project `repo:*` label** — explicit per-project override (unchanged).
3. **Linear Project GitHub resource link** — a `ProjectLink` whose URL
   resolves via `ProjectResources.github_repo_url/1` to a single
   `https://github.com/<org>/<repo>`.
4. **Natural-language repo mention in the project description** — a future
   Project Profile extraction step (not implemented by this spike).
5. **`binding.defaults.repo`** in `WORKFLOW.md` — global fallback, unchanged.

The existing `vibe:` YAML block in the project description
(`SymphonyElixir.Linear.ProjectVibeConfig`) continues to work as today; how
it interacts with a Project resource link is a design question for the
Project Profile work, not this spike.

If a project has **more than one** GitHub resource link (i.e.
`ProjectResources.github_repo_urls/1` returns more than one repo) and no
higher-priority signal (labels) disambiguates, resolution should fail fast —
comment on the issue and move it to `Human Review` — rather than guessing,
consistent with the existing fail-fast behavior in
`SymphonyElixir.Binding.describe_error/1`.
