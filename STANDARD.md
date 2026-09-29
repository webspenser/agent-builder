# Agent Standard 1.2

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
grows with the builder's sub-projects — 1.0 packaging,
1.1 instance rules, 1.2 capability contracts and adapters (this version). An agent
declares the version it follows in `agent.yaml`; the validator
understands `1.x` and fails any other. A folder with no `agent.yaml` is
a pre-1.0 agent: it is checked by the pre-1.0 rules below only and passes with
a warning.

1.1 adds instances, the entry hook, setup, and migrations; a 1.0 agent
still validates as 1.0.

1.2 (this version) adds capabilities, adapters, bindings, and the guard
hook. It is additive: a 1.1 agent stays valid as 1.1.

## Directory layout

```
agent-builder/
  README.md                 # what this folder is, how to use a spec
  STANDARD.md               # the Agent Standard
  _template/                # empty skeleton, copy to start an agent
  <agent-name>/
    agent.yaml              # identity + standard version (1.1)
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
ignores keys it does not know. 1.2 adds the optional flat key
`capabilities: crm, email_drafts` — comma-separated `snake_case` names,
one per folder in `capabilities/`. The folder name is not checked — a clone
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
never act on the package's blank default. Setup copies into the
instance only the context files the interview fills (listed in
`skills/setup/SKILL.md`); package-owned context files the user never
edits stay in the package, are read from there, and `AGENT.md` says
so. The user's own examples live in the instance's `context/samples/`;
the package's `samples/` holds only the examples the agent ships with.
`templates/`, `samples/`, `skills/`, `subagents/`, and `migrations/`
mean the package's files. Package paths are read-only in plugin mode:
write only into the instance. In source mode the package folder is the
instance (`instance.yaml` with `mode: source` at its root).

## Entry hook (1.1)

Every 1.1 agent ships `hooks/hooks.json` with at least one `SessionStart`
command hook, `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"`, and
`hooks/session-start.sh` byte-identical to `_template/hooks/session-start.sh`
and executable. It finds the nearest `instance.yaml` above the session
folder and stops there (it never looks further up); if that file names
this agent, it prints where the instance and package live, a migration
notice when the instance's `agent_version` is older than the package's
`version` (dot-separated fields compared as numbers), and a line telling
the model to read `AGENT.md` in full. It then inlines `AGENT.md` only
when it is at most 9000 bytes; above that it points at the file
(Claude Code truncates hook output past 10,000 characters). The
validator prints a `WARN:` for an `AGENT.md` over 9000 bytes. A missing
or malformed `agent_version`, or an instance newer than the package,
suppresses the migration notice. It prints nothing for a `mode: source`
instance (source copies load `AGENT.md` through their own host files)
and nothing elsewhere.

## Setup and start (1.1)

Both skills are required. `skills/setup/SKILL.md` creates an instance;
`skills/start/SKILL.md` loads `AGENT.md` by hand when the hook did not
run. Setup's `<interview-skill>` and `<context-files>` placeholders must
be filled (the validator fails while either is left, except in the
template itself). Optional `agent.yaml` keys `catalog` (marketplace
name) and `catalog_repo` (`owner/repo`) let setup enable the plugin in
the instance's `.claude/settings.json`; they are two flat top-level
keys (not a nested map), set both or neither.

## Migrations (1.1)

`migrations/` is required. It holds one `<from>-<to>.md` note per
release that changes the shape of a context file: what changed and how
to convert. It may be empty (keep a `.gitkeep` so git tracks it).

## Capabilities and adapters (1.2)

A capability is an outside system the agent works through — a CRM, a
mailbox. The package describes it in two layers:

- `capabilities/<capability>/contract.md` — the neutral operations the
  agent thinks in (a `## Operations` table whose first column is each
  operation name in backticks) and the rules every adapter must uphold
  (a `## Invariants` list, each item starting with a `snake_case` id in
  backticks). Skills and sub-agent contracts call operations, never a
  provider's tools.
- `capabilities/<capability>/adapters/<provider>/` — one folder per
  system: `adapter.md` maps every operation to that provider's tools
  and has a `## Probe` section (read-only calls setup makes when
  binding); `adapter.yaml` holds flat keys:

      capability: crm
      provider: attio
      server_match: attio          # substring of the MCP server name, any case
      block: delete, merge         # optional: tool-name substrings refused
      guard: guard.py              # optional: argument checks (package adapters only)
      deny: delete-record          # optional: tool-name suffixes for host-deny
      enforce_draft_only: adapter  # one line per contract invariant

`server_match`, `block`, and `deny` must be plain comma-separated
values; a YAML list (`[a, b]` or indented `- a` items) fails
validation, because the guard reads them as flat text.

Enforcement levels: `adapter` (a mechanism in the package holds it —
no violating tool exists, `block` removes it, or `guard` rejects the
arguments), `host-deny` (setup writes host deny rules for the `deny`
tools), `instruction` (only the agent's instructions hold it). An
invariant named `no_send` can never be `instruction`.

## Bindings (1.2)

`instance.yaml` binds each capability with one flat line,
`bind_<capability>: <provider>`. `custom` means the instance's own
adapter in `custom-adapters/<capability>/` (it may use `block`, never
`guard`). What the probe discovers — workspace IDs, optional
attributes — goes in the instance's `bindings/<capability>.md`. A
capability with no binding is not set up: the agent offers setup's
tools step instead of calling anything. Credentials stay in the host.

## Guard hook (1.2)

`hooks/guard.sh`, byte-identical to `_template/hooks/guard.sh`, is
registered in `hooks/hooks.json` as a `PreToolUse` command hook with
matcher `mcp__.*` and command `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"`.
Inside an instance of the agent (source mode included) it refuses any
tool of a bound adapter's servers whose name contains a `block` entry,
then runs the adapter's `guard` with `python3`, the hook input on
stdin. Exit 2 blocks. It fails closed: a missing guard, a missing
`python3`, a guard crash, or hook input naming two different tools
blocks the call. Outside an instance it allows everything.

Matching over-covers on purpose, so a name containing `__` cannot hide
a match: `server_match` is tested (case-insensitive substring) against
everything after `mcp__` in the tool name, and `block` entries against
everything after the first `__`.

A guard reads the hook input JSON, exits 2 with one stderr line per
broken rule, or 0; any internal error must become exit 2. A guard must
be fast and never wait on the network or a prompt: the host's hook
timeout lets a call through, so a hanging guard fails open.

## Setup — tools step (1.2)

Setup's tools step binds each capability: pick an adapter (or write a
custom one), find the matching connected server, run the probe, write
`bind_<capability>` and `bindings/<capability>.md`, merge deny rules
into `.claude/settings.json`, and report which capabilities are
unattended-safe (every invariant at `adapter`, or `host-deny` with its
rules written). It refuses to bind a `no_send` capability enforced by
`instruction`. Scheduled runs may use only unattended-safe
capabilities.

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

For an agent declaring `standard: "1.2"` (or a later 1.x), the validator
also checks, in addition to the 1.1 rules:

- `hooks/hooks.json` has a `PreToolUse` entry with matcher `mcp__.*`
  whose command is exactly `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"`
  (quoted, as in 1.1).
- `hooks/guard.sh` exists, is executable, and is byte-identical to the
  builder's `_template/hooks/guard.sh`.
- Each name in `capabilities` is `snake_case`, and
  `capabilities/<name>/contract.md` exists with a `## Operations` table
  holding at least one backticked operation and a `## Invariants` list
  holding at least one backticked `snake_case` id.
- Each capability has at least one adapter folder.
- Each adapter folder has `adapter.md` and `adapter.yaml`; `capability`
  and `provider` equal the folder names; `server_match` is non-empty;
  `server_match`, `block`, and `deny` are plain comma-separated values,
  not YAML lists.
- Each adapter has exactly one `enforce_<id>` line per contract
  invariant, valued `adapter`, `host-deny`, or `instruction`; a
  `host-deny` level requires a non-empty `deny`; `guard`, when set,
  names an executable file in that folder.
- `adapter.md` mentions every operation in backticks and has a
  `## Probe` section.
- `no_send` at `instruction` fails: a package may not ship an adapter
  setup would refuse.
- A `capabilities/` folder not listed in `capabilities` fails.

A 1.0 or 1.1 agent is checked exactly as before.
