# Extract Sales Partner — Design (sub-project 2)

**Date:** 2026-09-28
**Status:** Approved in conversation, pending spec review
**Implements:** sub-project 2 of [Agent Distribution Architecture](./2026-09-27-agent-distribution-architecture-design.md)
**Repos:** from `webspenser/agent-builder` to a new public `webspenser/sales-partner`

## Purpose

Give sales-partner its own repository, versioned and released
independently, as the first agent package on Agent Standard 1.0 — and
leave the builder repo holding no agents.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| History | `git subtree split --prefix=sales-partner` | Every commit that touched the agent comes along; log and blame work |
| Layout | The agent folder becomes the repo root (`AGENT.md` at top level) | One repo is one package on every host |
| Version | `0.9.0` | Usable in source mode now; `1.0.0` once instance mode (sub-project 3) makes plugin installs work end to end |
| Visibility | Public, Apache-2.0, "Template repository" enabled | Umbrella decisions; users copy it with "Use this template" |
| Release rule in CI | Pull requests must bump `version` against their base branch | Standard 1.0 release rule, enforced by the builder's Action |

## New repo — `webspenser/sales-partner`

```
sales-partner/                 # repo root
  AGENT.md  install.sh  adapters/  skills/  subagents/
  templates/  samples/  context/  evals/          # from subtree split
  agent.yaml                                      # new
  .claude-plugin/plugin.json, marketplace.json    # new
  gemini-extension.json  .codex-plugin/plugin.json  # new
  LICENSE  README.md                              # new
  tests/lib.sh                                    # copied from the builder
  tests/test-content.sh                           # moved, paths rewritten
  tests/run-all.sh                                # new: runs the content tests
  .github/workflows/validate.yml                  # new
  docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md
  docs/superpowers/specs/2026-09-24-sales-partner-generalize-prospecting-design.md
  docs/superpowers/plans/2026-09-24-sales-partner-generalize-prospecting.md
```

- `agent.yaml`: `name: sales-partner`, `version: 0.9.0`,
  `description: Interviews a business, then runs a five-stage lead
  pipeline — prospect, research, approach, sales call, follow-up — over
  a CRM`, `standard: "1.0"`.
- Host manifests repeat name, version, description. Claude `agents`
  lists the five contracts: `./subagents/approacher.md`,
  `./subagents/follow-up.md`, `./subagents/preparer.md`,
  `./subagents/prospector.md`, `./subagents/sales-call-specialist.md`.
  Marketplace `owner.name`: `Webspenser`.
- `tests/test-content.sh`: today's `tests/test-sales-partner-content.sh`
  with `SP=.` so its checks read the repo root.
- `.github/workflows/validate.yml`: on push to `main` and on pull
  requests — check out with full history, run
  `webspenser/agent-builder/validate@v1` on `.` (with
  `require-bump-against: origin/<base>` on pull requests only), then
  `tests/run-all.sh`.
- `README.md`: what the agent does; **use it today** in source mode
  ("Use this template" → your own private repo → open your host there →
  the agent interviews you and fills `context/`); plugin installs arrive
  with instance mode; how CRM and tools connect today (Airtable
  adapter); validating and releasing (bump `version` in `agent.yaml` and
  the four manifests).
- The moved specs and plans keep their content; links between them are
  fixed to their new relative paths. Links back to builder specs become
  absolute GitHub URLs.

## Builder repo afterward

- Remove `sales-partner/`, `tests/test-sales-partner-content.sh`, its
  line in `tests/run-all.sh`, and the three moved documents.
- `README.md`: drop the `sales-partner/` row; add an "Agents built with
  this" line linking `webspenser/sales-partner`.
- The builder specs that link to the moved documents point to their
  GitHub URLs in the new repo.
- `tests/run-all.sh` still ends `ALL GREEN`; the only agent it validates
  is `_template/`.

## Verification

- In the new repo: `bin/validate-agent.sh .` from a builder checkout
  prints `OK: . conforms` with no WARN; `tests/run-all.sh` ends
  `ALL GREEN`; `git log --oneline -- AGENT.md` shows the agent's history
  from the builder repo.
- The first CI run on `main` passes.
- A test pull request that changes a file without bumping `version`
  fails CI; bumping makes it pass. (Close it without merging.)
- In the builder repo: `tests/run-all.sh` ends `ALL GREEN`, and
  `grep -rn "sales-partner/" --exclude-dir=.git --exclude-dir=docs .`
  finds only README's link.

## Out of scope

- Instance mode (`instance.yaml`, `setup`, the entry hook) — sub-project 3.
- Capability contracts beyond the existing CRM contract, and new
  adapters (Attio, HubSpot) — sub-project 4.
- The catalog (`webspenser/agent-library`) — sub-project 6.
