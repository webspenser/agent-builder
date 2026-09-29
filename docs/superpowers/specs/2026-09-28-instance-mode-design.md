# Instance Mode — Design (sub-project 3)

**Date:** 2026-09-28
**Status:** Approved in conversation, pending spec review
**Implements:** sub-project 3 of [Agent Distribution Architecture](./2026-09-27-agent-distribution-architecture-design.md)
**Repos:** `webspenser/agent-builder` (Standard 1.1, template, validator, wizard) and `webspenser/sales-partner` (adopts 1.1, releases 1.0.0)

## Purpose

Make plugin installs useful: a user installs an agent from the catalog,
runs its `setup` skill in their own folder, and from then on opening a
host in that folder brings the agent to life with the user's data —
which lives only in that folder, never in the plugin.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Shared runtime | Each agent carries its own copy of the entry hook; the validator checks it is byte-identical to the builder's reference copy | Self-contained repos; works on every host and in source mode; no plugin dependencies |
| Entry mechanism (Claude) | `SessionStart` hook printing plain text to stdout | Confirmed in spike S1 and in the hook docs: plain stdout is added to the session's context; no JSON, no Python |
| Hook language | POSIX-leaning bash, no `jq`/`python` | Runs on a fresh macOS or Linux machine |
| Standard version | 1.1, additive: a 1.0 agent still validates as 1.0 | Minor bump per the versioning rule |
| Tool bindings | Not in 1.1 — `instance.yaml` has no `bindings` yet | Sub-project 4 (Standard 1.2) |
| sales-partner version | 1.0.0 once it adopts 1.1 | The spec for sub-project 2 tied 1.0.0 to working plugin installs |

## Agent Standard 1.1

### `instance.yaml` — the instance marker

```yaml
agent: sales-partner       # the agent.yaml name this instance belongs to
agent_version: 1.0.0       # agent version setup (or the last migration) ran with
standard: "1.1"
mode: plugin               # plugin | source
```

A folder is an instance of an agent if and only if it holds an
`instance.yaml` whose `agent` equals that agent's name. The instance is
the nearest such folder walking up from the working directory.

### Context resolution and the write rule

- In `AGENT.md`, skills, and sub-agent contracts, `context/<file>` means
  the **instance's** file. If the instance lacks it, the agent treats
  that input as not set up and runs the interview or setup step that
  produces it — it never acts on the package's blank default.
- `templates/`, `samples/`, `skills/`, `subagents/`, and `migrations/`
  mean the **package's** files.
- Everything the agent writes goes into the instance. Nothing is ever
  written into the package.
- In source mode the package folder *is* the instance, so both readings
  point at the same folder.

### Package files added in 1.1

| Path | Content |
|---|---|
| `hooks/hooks.json` | One `SessionStart` command hook: `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"` |
| `hooks/session-start.sh` | The reference script (below), byte-identical in every 1.1 agent |
| `skills/start/SKILL.md` | Manual entry: reads `${CLAUDE_PLUGIN_ROOT}/AGENT.md` (on other hosts, `AGENT.md` beside `skills/`), then follows it — the fallback when the hook didn't run |
| `skills/setup/SKILL.md` | Creates an instance (below) |
| `migrations/` | One `<from>-<to>.md` note per release that changes the shape of a context file; may be empty (`.gitkeep`) |
| `agent.yaml` `catalog` (optional) | `catalog: { name: webspenser, repo: webspenser/agent-library }` — lets `setup` write host settings that enable the plugin |

### `hooks/session-start.sh` — behavior

1. Read the agent's `name` and `version` from `${CLAUDE_PLUGIN_ROOT}/agent.yaml`.
2. Start at `${CLAUDE_PROJECT_DIR:-$PWD}`; walk up to `/` looking for
   `instance.yaml`. Stop at the first one found.
3. If none, or its `agent` isn't this agent's name: print nothing, exit 0.
4. Otherwise print, as plain text:
   - a header naming the agent, the instance folder, and the package
     folder (`${CLAUDE_PLUGIN_ROOT}`), with the 1.1 path rule in one
     sentence (context/ = instance; templates/, samples/, skills/,
     subagents/, migrations/ = package);
   - if the instance's `agent_version` differs from the package
     `version`, one line: the instance was set up with X, the agent is
     now Y — read `migrations/` in the package, show the user the
     proposed changes to the instance's files as a diff, and apply them
     only after they confirm, then update `agent_version`;
   - the full text of `${CLAUDE_PLUGIN_ROOT}/AGENT.md`.
5. Always exit 0; a missing `AGENT.md` prints one line saying so.

### `skills/setup/SKILL.md` — behavior

1. Choose the folder: the current folder if it is empty (ignoring dot
   files); otherwise propose `./<agent-name>/` and confirm. If an
   `instance.yaml` for this agent already exists, stop and offer to
   re-run only the interview.
2. Write `instance.yaml` (`agent`, `agent_version` = the package version,
   `standard: "1.1"`, `mode: plugin`).
3. Write pointer files `CLAUDE.md`, `GEMINI.md`, `AGENTS.md`: two lines
   each — "This folder is an instance of <agent>. Its instructions load
   from the <agent> plugin; if they didn't, run the `start` skill."
4. Write `.gitignore` (host caches, `.env*`, `**/credentials.json`,
   `**/*.key`).
5. If `agent.yaml` has `catalog`, write `.claude/settings.json` with
   `extraKnownMarketplaces` for that catalog and
   `enabledPlugins: { "<agent>@<catalog.name>": true }`, so cloud
   sessions and routines load the agent; merge into an existing file
   rather than overwriting it.
6. Copy each package `context/` file into the instance's `context/`, then
   run the agent's interview skill (named in the agent's `setup` skill)
   to fill them.
7. Offer `git init` and a first commit; suggest a private repo; remind
   that credentials go in the host, never in files.

### Validator (1.1 agents)

When `agent.yaml` declares `standard: "1.1"` (or later 1.x), additionally:

- `hooks/hooks.json` is valid JSON with a `SessionStart` command hook whose
  command is exactly `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"`.
- `hooks/session-start.sh` exists, is executable, and is byte-identical
  to the validator's reference copy (`_template/hooks/session-start.sh`
  in the builder).
- `skills/start/SKILL.md` and `skills/setup/SKILL.md` exist.
- `migrations/` exists.
- If `catalog` is present it has non-empty `name` and `repo` (`owner/repo`).
- If `instance.yaml` is present in the package, its `agent` equals the
  agent's name and its `mode` is `source`.

A 1.0 agent is checked exactly as today.

## Builder changes (version 1.1.0)

- `STANDARD.md`: title "Agent Standard 1.1"; new sections "Instances",
  "Entry hook", "Setup", "Migrations"; the version table notes 1.1.
- `_template/`: `standard: "1.1"`; adds `hooks/`, `skills/start/`,
  `skills/setup/` (with an `<interview skill>` placeholder the wizard
  fills), `migrations/.gitkeep`.
- Validator: the 1.1 checks above; tests for each (fixtures), plus hook
  behavior tests that run the script with a fake plugin root:
  no instance → silent; matching instance → prints header and AGENT.md;
  from a subfolder → finds the parent instance; another agent's
  instance → silent; version gap → prints the migration line; path with
  spaces works.
- `new-agent` wizard: generates the 1.1 files; asks which skill is the
  interview; for personal mode, runs `setup` in source mode (writes
  `instance.yaml` with `mode: source` at the agent folder) instead of
  filling context by hand.
- Builder manifests to `1.1.0`; README and `docs/writing-an-agent.md`
  explain instances in a short section.

## sales-partner changes (version 1.0.0)

- `agent.yaml`: `version: 1.0.0`, `standard: "1.1"`,
  `catalog: { name: webspenser, repo: webspenser/agent-library }`.
- Adds the hook, `start`, `setup` (interview = `interview-business`), and
  `migrations/0.9.x-1.0.0.md` (for source-mode users: add
  `instance.yaml` with `mode: source` at the repo root; nothing else
  changes).
- `AGENT.md` Inputs: one paragraph stating the 1.1 path rule.
  `interview-business` writes to the instance's `context/`.
- README: the catalog install becomes the primary route
  (`/plugin install sales-partner@webspenser`, then
  `/sales-partner:setup` in an empty folder); source mode stays
  documented.
- The catalog README's sales-partner status becomes "1.0 — install from
  the catalog, then run `/sales-partner:setup`" and the deferral note is
  removed.
- Content tests: extended for the new files.

## Verification

- Builder `tests/run-all.sh` ALL GREEN, including the hook behavior tests.
- sales-partner CI green on the 1.0.0 PR (release rule satisfied).
- Acceptance, from GitHub through the catalog: install
  `sales-partner@webspenser`; in an empty temp folder write an
  `instance.yaml` for sales-partner and confirm a headless session sees
  the agent (its `AGENT.md` text) and the instance path; in a second
  empty folder with no `instance.yaml`, confirm it does not; with
  `agent_version: 0.9.1` confirm the migration line appears; then
  uninstall.

## Deviations during implementation

- `agent.yaml` catalog fields are two flat keys, `catalog` and
  `catalog_repo`, not a `catalog: { name, repo }` map: the Python
  checker and the bash hook read top-level `key: value` lines only.
- The hook inlines `AGENT.md` only up to 9000 bytes; above that it
  prints a line telling the model to read the file (Claude Code cuts
  hook output at 10,000 characters). It always tells the model to read
  `AGENT.md` in full, and the validator WARNs above 9000 bytes.
- The hook is silent for a `mode: source` instance (source copies load
  `AGENT.md` through their own host files), and prints the migration
  notice only when the instance is older than the package.
- Operator-supplied examples live in the instance at
  `context/samples/`; the package's `samples/` holds only shipped
  examples.
- Setup copies only the context files the interview fills (listed per
  agent in `skills/setup/SKILL.md` via `<context-files>`); package-owned
  context files are read from the package.

## Out of scope

- Bindings, adapters, deny rules (sub-project 4); schedules on routines
  (sub-project 5); Gemini/Codex entry mechanics (still unverified).
