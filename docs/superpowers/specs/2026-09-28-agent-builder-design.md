# Agent Builder — Design (sub-project 1)

**Date:** 2026-09-28
**Status:** Approved in conversation, pending spec review
**Implements:** sub-project 1 of [Agent Distribution Architecture](./2026-09-27-agent-distribution-architecture-design.md)
**Repo:** `webspenser/agent-builder`

## Purpose

Make this repository an installable **builder**: a plugin anyone can add
to Claude Code (Gemini CLI and Codex manifests shipped, unverified) that
walks them from "I want an agent that…" to a working agent folder that
follows the Agent Standard, and that validates any agent — locally or in
CI.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Standard versioning | Grows per sub-project: **1.0** packaging (this spec), **1.1** instance rules (sub-project 3), **1.2** capability contracts and adapters (sub-project 4) | Each addition is additive; 1.0 ships with the builder instead of waiting on later work. Amends the umbrella spec, which bundled all three into 1.0 |
| Standard document | `CONVENTIONS.md` becomes `STANDARD.md`, headed "Agent Standard 1.0" | The name says what it is; the version is visible at the top |
| Names | Repo renamed `webspenser/agent-library` → `webspenser/agent-builder`; plugin `agent-builder` (skills appear as `/agent-builder:new-agent`). The name `webspenser/agent-library` is then reused for the public catalog (sub-project 6) | "Builder" is what this repo is; "library" fits the catalog of published agents. No users yet, so renaming costs nothing |
| Compatibility | None kept: files move freely, no shims | No existing users |
| Validator location | `bin/validate-agent.sh` (moved from `tests/`) | The plugin, the Action, and users all call it; it is a product, not a test |
| Parsing | `python3` standard library for JSON; `agent.yaml` read line by line | Present on macOS and GitHub runners; no dependency to install |
| Pre-1.0 agents | An agent with no `agent.yaml` is checked by the pre-1.0 rules only and passes with a warning | `sales-partner` stays valid here until sub-project 2 extracts it |
| Personal mode | Until 1.1, fills `context/` in place in the new agent's folder (source mode) | `instance.yaml` and `setup` belong to sub-project 3 |
| License | Apache-2.0 `LICENSE` at the repo root | Umbrella decision |

## Agent Standard 1.0

`STANDARD.md` keeps every rule in today's `CONVENTIONS.md` and adds:

### Versioning

Semantic versioning. A minor release adds optional rules; a major
release changes what an agent must do to conform. An agent declares the
version it follows in `agent.yaml`; the validator states which versions
it understands (`1.x`) and fails an agent declaring any other.

### Agent manifest — `agent.yaml` (required from 1.0)

```yaml
name: sales-partner            # kebab-case; the plugin / extension name
version: 1.3.0                 # semver of the agent itself
description: One sentence, what the agent does
standard: "1.0"                # Agent Standard version followed
```

Four keys, all required, one `key: value` per line (quotes optional).
1.1 and 1.2 add keys; 1.0 validators ignore keys they don't know.

### Host manifests (required from 1.0)

| File | Required content |
|---|---|
| `.claude-plugin/plugin.json` | `name`, `version`, `description` equal to `agent.yaml`; `agents` lists every file in `subagents/` as `"./subagents/<role>.md"` — files only, no directories, no missing or extra entries |
| `.claude-plugin/marketplace.json` | `name` equal to the agent name; `owner.name`; exactly one plugin entry with the agent's `name` and `"source": "./"` |
| `gemini-extension.json` | `name`, `version`, `description` equal to `agent.yaml`; `contextFileName: "AGENT.md"` |
| `.codex-plugin/plugin.json` | `name`, `version`, `description` equal to `agent.yaml`; `skills: "./skills/"` |

### Release rule

Any change to an agent's files ships with a `version` bump, applied to
`agent.yaml` and all four host manifests together. The validator
enforces this against a git ref when asked (`--require-bump <ref>`).

## Validator — `bin/validate-agent.sh`

```
bin/validate-agent.sh <agent-dir> [--require-bump <git-ref>]
```

- Runs every pre-1.0 check unchanged (directories, required files,
  `AGENT.md` headings, adapters, skill frontmatter, sub-agent headings).
- If `agent.yaml` is absent: prints
  `WARN: <dir> has no agent.yaml — checked as pre-1.0` and exits on the
  pre-1.0 result.
- If present, adds one `FAIL:` line per problem for:
  1. `agent.yaml` missing a key, `name` not kebab-case, `version` not
     `MAJOR.MINOR.PATCH`, `standard` not `1.x`. The folder name is not
     checked — a clone may live under any folder name.
  2. Any host manifest missing, not valid JSON, or disagreeing with
     `agent.yaml` on `name`, `version`, or `description`.
  3. Claude `agents` not matching `subagents/*.md` exactly, or holding a
     directory path.
  4. `marketplace.json` not a single entry with the agent's name and
     `"source": "./"`.
  5. `gemini-extension.json` `contextFileName` not `AGENT.md`;
     `.codex-plugin/plugin.json` `skills` not `./skills/`.
  6. With `--require-bump <ref>`: files under the agent changed since
     `<ref>` while `agent.yaml`'s `version` is unchanged since `<ref>`.
- Output contract unchanged: `OK: <dir> conforms` and exit 0, or one
  `FAIL:` line per problem, a count, and exit 1.

`tests/validate-agent.sh` is removed, not shimmed — there are no
existing users; every reference moves to `bin/validate-agent.sh`.

## Template — `_template/`

Gains `agent.yaml` (`name: agent-template`, `version: 0.0.0`,
`description: Template — replace with one sentence`, `standard: "1.0"`)
and the four host manifests, filled to match it, with an empty
`agents: []`. The template itself passes the validator, as today.

## Builder plugin

The repo root is the plugin:

```
agent-builder/
  .claude-plugin/plugin.json        # name agent-builder, version 1.0.0
  .claude-plugin/marketplace.json   # one entry, source "./"
  gemini-extension.json             # contextFileName: STANDARD.md
  .codex-plugin/plugin.json         # skills: ./skills/
  STANDARD.md
  LICENSE                           # Apache-2.0
  bin/validate-agent.sh
  skills/new-agent/SKILL.md
  skills/validate-agent/SKILL.md
  _template/
  validate/action.yml               # GitHub Action
  docs/  tests/
```

`tests/test-builder-manifests.sh` checks the builder's four manifests
agree with each other on name, version, and description (the builder
has no `agent.yaml`; `.claude-plugin/plugin.json` is its source of
truth). Until sub-project 2, `sales-partner/` also sits in the repo and
is therefore present in the installed plugin; it is inert there — the
builder's manifests expose only the builder's own skills.

### Skill: `new-agent` (the wizard)

Trigger: the user wants to create a new agent. Runs as a conversation,
one question at a time, writing files as it goes so an interrupted run
resumes by reading what already exists.

1. **Purpose.** What job the agent does, for whom, and what success
   looks like. Refuse to continue on "it does everything" — ask for
   the one job.
2. **Name and place.** A kebab-case name; the folder to create it in
   (default `./<name>`). Stop if the folder exists and is not an
   earlier, interrupted run of this wizard.
3. **Mode.** *Personal* — one person uses it; context is filled in
   place after building. *Distributable* — others install it; context
   stays as blank defaults.
4. **Scaffold.** Copy `_template/` from the plugin root
   (`${CLAUDE_PLUGIN_ROOT}/_template` on Claude; the skill's own
   repository root elsewhere) to the folder; set `agent.yaml`
   (`version: 0.1.0`) and the four host manifests from the answers.
5. **Specification, section by section**, writing each before asking
   the next: Identity and Mission; Inputs and Outputs; the context
   files the agent consumes (each written as a blank with bracketed
   interview prompts, the way `sales-partner`'s `icp.md` is);
   Operating rules; Workflow, marking each step's capability tier;
   skills (name, trigger, procedure, one worked example, failure
   modes); sub-agent contracts only where a step benefits from
   isolation; Guardrails; Escalate-to-human conditions.
6. **Evals.** At least three negative cases in `evals/cases.md` —
   things the agent must refuse or never do — in the Given / Expect /
   Why it matters / How to run form.
7. **Manifests.** Refresh `agents` in `.claude-plugin/plugin.json` to
   list every file in `subagents/`.
8. **Validate.** Run `bin/validate-agent.sh` on the folder and fix every
   `FAIL:` until it prints `OK`.
9. **Finish.** Personal: offer to fill `context/` now by running the
   agent's own interview in the new folder. Distributable: offer
   `git init`, a first commit, and how to publish (a GitHub repo with
   "Template repository" enabled, then listing it in a catalog).

Never invents the user's domain facts; anything the user hasn't
supplied stays as a bracketed prompt.

### Skill: `validate-agent`

Trigger: the user asks whether an agent conforms, or wants it checked
before a commit or release. Runs `bin/validate-agent.sh` on the named
folder (default: the current folder), then explains each `FAIL:` in
plain language with the fix. Where no shell is available, performs the
same checks by reading the files and reports in the same format.

### GitHub Action — `validate/action.yml`

A composite action any agent repo can use:

```yaml
- uses: webspenser/agent-builder/validate@v1
  with:
    path: .                    # agent folder, default "."
    require-bump-against: ""   # e.g. origin/main on pull requests
```

It runs the validator from the action's own checkout of this repo, so
the agent repo needs nothing installed. A `v1` tag moves with 1.x
releases of the builder.

## Documentation

- `README.md` rewritten for the builder's users: what it is, install on
  Claude (`/plugin marketplace add webspenser/agent-builder`, then
  `/plugin install agent-builder@agent-builder`), Gemini and Codex
  marked unverified, `/agent-builder:new-agent`, validating in CI.
- `docs/writing-an-agent.md` — the practices the wizard follows, for
  people who build by hand.

## Testing

- `tests/test-validate-agent.sh` gains fixtures for every new check:
  a valid 1.0 agent passes; each manifest mismatch, a directory in
  `agents`, a missing or extra agent file, a bad marketplace entry, a
  wrong `standard`, and an unchanged version with `--require-bump`
  each fail; an agent without `agent.yaml` passes with the `WARN` line.
- `tests/test-builder-manifests.sh` as above.
- `tests/run-all.sh` runs both, the install tests, the sales-partner
  content tests, and the validator on `_template/` and every agent
  folder; still ends `ALL GREEN`.
- Manual acceptance: install the builder from a local path, run
  `/agent-builder:new-agent` in an empty folder for a small personal
  agent, and confirm the result validates.

## Out of scope

- `instance.yaml`, `setup`, the entry hook (Standard 1.1, sub-project 3).
- Capability contracts and adapters (Standard 1.2, sub-project 4).
- Extracting `sales-partner` (sub-project 2) and the catalog
  (sub-project 6).
- `upgrade-agent`; Windows support for the validator.
