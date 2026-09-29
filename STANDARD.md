# Agent Standard 1.1

An agent specification is a directory of provider-neutral markdown with a
single source of truth: one `AGENT.md`, one set of skills, one set of
sub-agent contracts. Provider differences — how Claude Code, Gemini CLI,
Codex, Cursor, or any other host discovers and wires up the agent — live
only in `adapters/`, which carry no behavior of their own. This document
is the standard `bin/validate-agent.sh` enforces; if this file and the
script ever disagree, the script is the ground truth and this file is a
bug.

## Versioning

The standard uses semantic versioning: a minor release adds optional
rules, a major release changes what an agent must do to conform. It
grows with the builder's sub-projects — 1.0 packaging (this version),
1.1 instance rules, 1.2 capability contracts and adapters. An agent
declares the version it follows in `agent.yaml`; the validator
understands `1.x` and fails any other. A folder with no `agent.yaml` is
a pre-1.0 agent: it is checked by the pre-1.0 rules below only and passes with
a warning.

1.1 (this version) adds instances, the entry hook, setup, and migrations;
a 1.0 agent still validates as 1.0.

## Directory layout

```
agent-builder/
  README.md                 # what this folder is, how to use a spec
  STANDARD.md               # the Agent Standard
  _template/                # empty skeleton, copy to start an agent
  <agent-name>/
    agent.yaml              # identity + standard version (1.0)
    hooks/                  # hooks.json + session-start.sh (1.1)
    migrations/             # <from>-<to>.md upgrade notes (1.1)
    .claude-plugin/         # plugin.json, marketplace.json
    .codex-plugin/          # plugin.json
    gemini-extension.json
    AGENT.md                # single source of truth
    install.sh              # links adapters into host-expected locations
    adapters/
      CLAUDE.md             # pointer file, no behavior
      GEMINI.md             # pointer file, no behavior
      AGENTS.md             # pointer file, no behavior (Codex, Cursor, Amp, Copilot)
    skills/
      <skill-name>/
        SKILL.md            # frontmatter + procedure
        references/         # optional deep-dive files, loaded on demand
    subagents/
      <role-name>.md        # role contract
    templates/              # blank fill-in artifacts the agent PRODUCES
    samples/                # filled-in gold-standard examples
    context/                # inputs the agent CONSUMES
    evals/
      cases.md              # given-X-expect-Y checks
```

`adapters/`, `skills/`, `subagents/`, `templates/`, `samples/`,
`context/`, and `evals/` are all required directories inside every
`<agent-name>/`, even if some start empty — the validator fails an agent
missing any of them. `AGENT.md`, `install.sh`, and `evals/cases.md` are
required files; `install.sh` must additionally be executable
(`chmod +x`). `adapters/CLAUDE.md`, `adapters/GEMINI.md`, and
`adapters/AGENTS.md` are all required, not optional per-host extras.

## AGENT.md

Ten required headings, in this exact order. The validator collects every
`##`/`###` heading in the file, keeps only the ones that match this list,
and fails unless what's left is exactly these ten, once each, in this
order — other `##`/`###` headings may appear between or around them (for
subsections), but none of the ten may be missing, duplicated, or
reordered.

1. `Identity` — who the agent is, two or three sentences
2. `Mission` — the outcome it exists to produce
3. `Inputs` — what it needs before it can start
4. `Outputs` — what it produces, with exact artifact shapes
5. `Operating rules` — how it works, numbered
6. `Workflow` — ordered steps, each tagged with its required capability tier
7. `Sub-agents` — table: role, when to use, contract path
8. `Skills` — table: skill, trigger condition
9. `Guardrails / never do` — hard prohibitions
10. `Escalate to human when` — explicit stop-and-ask conditions

## Skills

Each skill lives at `skills/<skill-name>/SKILL.md` with YAML frontmatter
containing exactly two keys — nothing more, nothing less:

```
---
name: kebab-case-name
description: Use when <trigger condition> — <what it does>
---
```

The validator requires: an opening `---` on line 1, a closing `---`
later in the file, a `name` matching `^[a-z0-9]+(-[a-z0-9]+)*$`, a
`description` that begins with the literal words `Use when`, and no
other keys in the frontmatter block — any stray key (`version`, `tags`,
anything) fails validation.

The body is a numbered procedure, one worked example, and known failure
modes. Deep material goes in `references/` and is read on demand,
keeping the always-loaded surface small.

## Sub-agent contracts

Each contract lives at `subagents/<role-name>.md` with eight required
headings, in this exact order (same present-and-in-order rule as
`AGENT.md` above):

1. `Purpose`
2. `Trigger`
3. `Inputs` — exact
4. `Outputs` — exact shape
5. `Tools allowed`
6. `Stop conditions`
7. `Handoff` — which role or step consumes the output
8. `Inline fallback` — how to run this contract as a sequential phase
   when the host has no sub-agent dispatch

Above those headings, every contract opens with YAML frontmatter
carrying exactly two keys — the same two a skill carries, and required
for the same practical reason: a host that registers sub-agents by
directory (Claude Code reads them from `.claude/agents/`, which
`install.sh` links to `subagents/`) will not register a definition
without them. A contract with no frontmatter does not fail loudly — the
host simply never registers it, tier-1 dispatch silently degrades to
inline, and the tier-1 half of the portability claim goes untested.

```
---
name: kebab-case-name
description: One line saying when to dispatch this contract.
---
```

`name` is kebab-case and matches the filename (`subagents/follow-up.md`
→ `name: follow-up`). `description` is a single line naming the trigger
condition — a stage, a score threshold, a schedule — and, per the
no-naming rule below, never another contract's name. The frontmatter
sits above the eight headings and does not disturb their order.

Three rules apply on top of the heading shape. Unlike the heading
presence and order above, `bin/validate-agent.sh` does not check any
of these three, nor the frontmatter above — it only parses the eight
headings, never the frontmatter and never the content underneath them —
so these are conventions a human or reviewer enforces, not ones the
script catches:

- **No contract may name another contract.** Handoffs happen through
  state transitions only — a contract hands off by producing an output
  artifact, not by invoking a named peer. This is what lets the whole
  pipeline collapse into sequential inline phases on a host without
  dispatch.
- **Every `Stop conditions` entry is a countable resource** — a spend
  cap, a quota, an item count, a touch limit. Never "when done": a
  contract that stops on completion has no bound on a model that never
  believes it's done.
- **`Tools allowed` is the enforcement mechanism for autonomy.** A
  contract that must not send email, post publicly, or spend money does
  not list that tool — the omission is the guardrail, not a sentence
  telling it not to.

## templates/ vs samples/ vs context/

- **`templates/`** — blank artifacts the agent produces: the empty
  shape it fills in.
- **`samples/`** — filled, gold-standard examples the agent imitates
  for voice and structure.
- **`context/`** — material the agent consumes as input; never a
  deliverable.

They stay separate on purpose. Merging templates and samples causes
placeholder text to leak into output, because the model can no longer
tell "the blank to fill" from "an example already filled." Merging
context in with either causes reference material to get emitted as if
it were a deliverable.

## Adapters

`adapters/CLAUDE.md`, `adapters/GEMINI.md`, and `adapters/AGENTS.md` are
pointer files only — 25 lines maximum, and each must reference
`AGENT.md` by name so the host lands on the real specification. Any rule
placed in an adapter is a defect: it creates a second source of truth
for that provider, and the two will drift.

```markdown
<!-- adapters/GEMINI.md -->
# <Agent Name>

Read `AGENT.md` in this directory. It is the full specification —
identity, rules, workflow, guardrails. Follow it exactly.

Skills: read `skills/<name>/SKILL.md` when its trigger matches.
Sub-agents: `subagents/*.md` are role contracts. This host has no
dispatch — run each contract inline as a sequential phase.
```

## Capability tiers

Agents declare the capability each workflow step needs, so weaker hosts
run a reduced agent rather than failing:

| Tier | Host capability | Behavior |
|---|---|---|
| 1 — Full | Sub-agent dispatch + skill autoloading | Sub-agents run dispatched and isolated |
| 2 — Reduced | No dispatch | Same role contracts run inline as sequential phases |
| 3 — Minimum | Single context | `AGENT.md` alone, skills pasted in as needed |

No step on any agent's critical path may require tier 1. Dispatch buys
parallelism and context isolation, never correctness — a workflow that
only works with dispatch is a workflow that only works on one host.

## Agent manifest

Every 1.0 agent has `agent.yaml` at its root:

```yaml
name: sales-partner            # kebab-case; the plugin / extension name
version: 1.3.0                 # MAJOR.MINOR.PATCH — the agent's own version
description: One sentence, what the agent does
standard: "1.0"                # the Agent Standard version followed
```

All four keys are required, one `key: value` per line; quotes and
trailing comments are allowed. Later versions add keys; a 1.0 validator
ignores keys it does not know. The folder name is not checked — a clone
may live under any name.

## Host manifests

Four static files let each host install the agent. None carries
behavior; each repeats the agent's identity.

| File | Required content |
|---|---|
| `.claude-plugin/plugin.json` | `name`, `version`, `description` equal to `agent.yaml`; `agents` lists every file in `subagents/` as `"./subagents/<role>.md"` — files only, no directories, none missing or extra |
| `.claude-plugin/marketplace.json` | `name` equal to the agent name; `owner.name`; exactly one plugin entry with the agent's name and `"source": "./"` |
| `gemini-extension.json` | `name`, `version`, `description` equal to `agent.yaml`; `"contextFileName": "AGENT.md"` |
| `.codex-plugin/plugin.json` | `name`, `version`, `description` equal to `agent.yaml`; `"skills": "./skills/"` |

Claude rejects a directory in `agents`, which is why each file is
listed. The one-entry marketplace lets the repo install on its own for
local testing.

## Release rule

Any change to an agent's files ships with a `version` bump, applied to
`agent.yaml` and all four host manifests together — hosts update a
GitHub-sourced plugin only when its version changes. The validator
enforces this against a git ref when asked:

    bin/validate-agent.sh <agent-dir> --require-bump origin/main

An agent that did not exist at the ref needs no bump.

## Instances (1.1)

A folder is an instance of an agent when it holds `instance.yaml`:

```yaml
agent: sales-partner       # the agent's name
agent_version: 1.0.0       # version setup (or the last migration) ran with
standard: "1.1"
mode: plugin               # plugin | source
```

`context/<file>` in `AGENT.md`, skills, and contracts means the
instance's file; if it is missing, run the step that produces it —
never act on the package's blank default. `templates/`, `samples/`,
`skills/`, `subagents/`, and `migrations/` mean the package's files.
Write only into the instance. In source mode the package folder is the
instance (`instance.yaml` with `mode: source` at its root).

## Entry hook (1.1)

Every 1.1 agent ships `hooks/hooks.json` with one `SessionStart`
command hook, `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"`, and
`hooks/session-start.sh` byte-identical to `_template/hooks/session-start.sh`.
It finds the nearest `instance.yaml` above the session folder; if it
names this agent, it prints where the instance and package live, a
migration notice when versions differ, and `AGENT.md`. Elsewhere it
prints nothing.

## Setup and start (1.1)

`skills/setup/SKILL.md` creates an instance; `skills/start/SKILL.md`
loads `AGENT.md` by hand when the hook did not run. Optional
`agent.yaml` keys `catalog` (marketplace name) and `catalog_repo`
(`owner/repo`) let setup enable the plugin in the instance's
`.claude/settings.json`; set both or neither.

## Migrations (1.1)

`migrations/` holds one `<from>-<to>.md` note per release that changes
the shape of a context file: what changed and how to convert. It may be
empty.

## Validation

```bash
bin/validate-agent.sh <agent-dir>
```

Exits `0` and prints `OK: <agent-dir> conforms` when the directory
matches every rule above; otherwise prints one `FAIL:` line per problem
and exits non-zero. Run it before committing any change to an agent
directory — a change that breaks heading order, frontmatter shape, or
adapter size is a change that breaks portability, and this script is the
only thing that catches it before a host does.
