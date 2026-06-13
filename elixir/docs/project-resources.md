# Project Resources

This documents the data Symphony reads from a Linear project's "Resources"
section (external links shown on the project overview page), and how it's
used for repo binding.

## What's implemented

- `SymphonyElixir.Linear.Client` queries `project.externalLinks.nodes { url label }`
  (the `EntityExternalLink` GraphQL type, via `Project.externalLinks`)
  alongside the existing `project.description` / `project.content` /
  `project.labels` fields.
- `SymphonyElixir.Linear.Issue.project_resources` is a flat list of the raw
  resource URLs for the issue's project, in the order Linear returns them.
  Links without a `url` are dropped; nothing else is filtered or interpreted.
- `SymphonyElixir.Linear.ProjectResources.github_repo_urls/1` picks out
  `https://github.com/<org>/<repo>` links from that list, normalizing away
  trailing paths (`/pull/42`, `/tree/main`), `.git` suffixes, and trailing
  slashes, and de-duplicating.
- `SymphonyElixir.Binding.resolve/2` consults this as the **project Resources
  GitHub repo link** signal — see priority order below.

## Repo resolution priority

`SymphonyElixir.Binding.resolve/2` resolves an issue's repo, highest priority
first:

1. **Issue `repo:*` label** — explicit per-issue override.
2. **Project `repo:*` label** — explicit per-project override (same label
   vocabulary, applied to the Linear project).
3. **Project Resources GitHub repo link** — a single
   `https://github.com/<org>/<repo>` link in the Linear project's Resources
   (`project.externalLinks`), normalized via
   `ProjectResources.github_repo_urls/1`.
4. **`vibe:` block in the project description** — `vibe.repo`
   (`SymphonyElixir.Linear.ProjectVibeConfig`), a backward-compatible advanced
   fallback.
5. **`binding.defaults.repo`** in `WORKFLOW.md` — global fallback.

Like `vibe.repo`, the project Resources link is validated unconditionally
(even when a higher-priority label ends up winning for a given issue), so a
misconfigured Resources link is caught immediately rather than surfacing
later on a different issue in the same project:

- **More than one** GitHub repo link in Resources is ambiguous — resolution
  fails fast with `{:ambiguous_project_resource_repo, repos}` rather than
  guessing.
- A repo link that fails `binding.repo_policy` validation fails fast with
  `{:invalid_project_resource_repo, reason}`.

## No repo resolves at all

If *none* of the above resolve to a repo — no `repo:*` label (issue or
project), no project Resources GitHub link, no `vibe.repo`, and no
`binding.defaults.repo` — `Binding.resolve/2` fails fast with
`{:missing_binding, :repo, _}`. The orchestrator turns this into a comment on
the Linear issue asking for a repo binding (add a Resources link, a `repo:*`
label, or `binding.defaults.repo`) and moves the issue to `Human Review` — no
workspace or run is started, and Symphony never guesses a repo.

This is what lets `tracker.auto_discover_projects: true` watch *every* active
Linear Project in the configured team (see
`SymphonyElixir.Linear.ProjectDiscovery`) without requiring any project to be
pre-configured: a newly created project with no repo binding yet is
discovered and polled, but its issues simply fail fast until a repo is
configured.
