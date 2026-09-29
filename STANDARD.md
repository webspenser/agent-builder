# Agent Standard 2.0

An agent specification is a directory of provider-neutral markdown with a
single source of truth: one `AGENT.md`, one set of skills, one set of
sub-agent contracts. Provider differences — how Claude Code, Gemini CLI,
Codex, Cursor, or any other host discovers and wires up the agent — live
only in `adapters/`, which carry no behavior of their own. This document
is the standard `bin/validate-agent.sh` enforces; if this file and the
script ever disagree, the script is the ground truth and this file is a
bug.

## Development phase

The standard is 2.0. The validator checks only the current version: an
agent that declares another version fails with a message to update it.
Breaking changes are allowed, and every Webspenser agent is updated in
the same release as the builder. Compatibility rules will return when
agents have outside users. An agent declares the standard it follows in
`agent.yaml`.

## Directory layout

```
agent-builder/
  README.md                 # what this folder is, how to use a spec
  STANDARD.md               # the Agent Standard
  _template/                # empty skeleton, copy to start an agent
  <agent-name>/
    agent.yaml              # identity + standard version
    hooks/                  # hooks.json and three scripts, from _template
      session-start.sh      # entry hook
      guard.sh              # PreToolUse guard
      guard_policy.py       # guard policy engine
    migrations/             # <from>-<to>.md upgrade notes
    capabilities/           # optional, one folder per capability
      <capability>/
        contract.md         # operations + invariants
        adapters/
          <provider>/
            adapter.md      # operation -> tool map, ## Probe
            adapter.yaml    # capability, provider, server_match
            guard.yaml      # optional guard policy
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

Every agent has `agent.yaml` at its root:

```yaml
name: sales-partner            # kebab-case; the plugin / extension name
version: 1.3.0                 # MAJOR.MINOR.PATCH — the agent's own version
description: One sentence, what the agent does
standard: "2.0"                # the Agent Standard version followed
```

All four keys are required, one `key: value` per line; quotes and
trailing comments are allowed. The optional flat key
`capabilities: crm, email_drafts` lists comma-separated `snake_case`
names, one per folder in `capabilities/`. The folder name is not
checked — a clone may live under any name.

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

## Instances

A folder is an instance of an agent when it holds `instance.yaml`:

```yaml
agent: sales-partner       # the agent's name
agent_version: 1.0.0       # version setup (or the last migration) ran with
mode: plugin               # plugin | source
bind_crm: attio            # one line per bound capability
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

## Entry hook

Every agent ships `hooks/hooks.json` with at least one `SessionStart`
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

## Setup and start

Both skills are required. `skills/setup/SKILL.md` creates an instance;
`skills/start/SKILL.md` loads `AGENT.md` by hand when the hook did not
run. Setup's `<interview-skill>` and `<context-files>` placeholders must
be filled (the validator fails while either is left, except in the
template itself). Optional `agent.yaml` keys `catalog` (marketplace
name) and `catalog_repo` (`owner/repo`) let setup enable the plugin in
the instance's `.claude/settings.json`; they are two flat top-level
keys (not a nested map), set both or neither.

## Migrations

`migrations/` is required. It holds one `<from>-<to>.md` note per
release that changes the shape of a context file: what changed and how
to convert. It may be empty (keep a `.gitkeep` so git tracks it).

## Capabilities and adapters

A capability is an outside system the agent works through — a CRM, a
mailbox. The package describes it in two layers:

- `capabilities/<capability>/contract.md` — the neutral operations the
  agent thinks in (a `## Operations` table whose first column is each
  operation name in backticks) and the rules every adapter must uphold
  (a `## Invariants` list, each item starting with a `snake_case` id in
  backticks). Skills and sub-agent contracts call operations, never a
  provider's tools.
- `capabilities/<capability>/adapters/<provider>/` — one folder per
  system, called an adapter pack:
  - `adapter.md` maps every operation to that provider's tools and has a
    `## Probe` section (read-only calls setup makes when binding).
  - `adapter.yaml` holds exactly three flat keys, as plain values:

        capability: crm
        provider: attio
        server_match: attio          # substring of the MCP server name, any case

    Any other key is an error.
  - `guard.yaml` is the optional guard policy (next section).

An adapter's `guard.yaml` `covers` lists the invariants it enforces by
mechanism. The rest are held only by the agent's instructions. An
adapter without `guard.yaml` works, but every invariant is
instruction-only. An invariant named `no_send` must be covered.

## Guard policy

A guard policy is a small file, `guard.yaml`, beside an adapter. It says
which tools may be called, which values may be written, and which
contract invariants that covers. One reference engine,
`hooks/guard_policy.py`, enforces it before every call. Because the
policy is data, an instance's custom adapter can ship one too, so a tool
the user brings can qualify for unattended runs.

```yaml
# capabilities/crm/adapters/attio/guard.yaml
covers: [draft_only, dnc_one_way, no_delete]

allow: [whoami, list-*, get-*, search-*, semantic-search-*, run-basic-report,
        add-record-to-list, create-record, upsert-record, update-record,
        update-list-entry-by-id, update-list-entry-by-record-id,
        create-note, create-task, update-task]
deny: ["*delete*", "*merge*", create-list, update-list]

create_tools: [add-record-to-list, create-record]
update_tools: [update-list-entry-by-id, update-list-entry-by-record-id,
               update-record, upsert-record]
values_at: [entry_values, values]
unwrap: [option, status, value, title]
unknown_writes: update
refuse_keys: [uuid]

rules:
  - field: status
    create: [draft]
    update: [voided]
  - field: do_not_contact
    update: [true]
```

With `allow` present, a tool of the matched server that matches no
`allow` pattern is blocked, so a new vendor tool stays blocked until
someone allows it. `deny` beats `allow`, and every field rule must pass:
rules only narrow.

### Grammar

The policy is a strict subset of YAML. Anything outside it is a
validation error and, at runtime, a block.

- The top level is a map of `key: value` lines at column 0; the key is
  followed by a space or the end of the line (`covers:[a]` is an error).
  Comments (`#` to end of line, outside quotes) and blank lines are
  ignored; a `#` starts a comment only at the start of the line's content
  or after whitespace (`[a]#x` is an error).
- A value is a scalar (plain, or single/double quoted) or a flow list
  `[a, b, "c*"]`. A flow list may continue over following indented
  lines until its closing `]`, and nothing may follow the `]`. A plain
  scalar may not start with `* & ! | > % @ :` `,` a backtick, `- ` or
  `? `, may not be `-` or `?` alone, may not end with `:`, and may not
  contain `[ ] { }`, `: ` or a quote character — quote it. A quoted
  scalar may not contain its own quote character, and a double-quoted
  one may not contain a backslash. A list item is one scalar
  (`["a" "b"]` is an error).
- The one exception is `rules:`, whose value is a block list: each item
  starts with `  - ` and holds `field:` plus any of `binding_id:`,
  `create:`, `update:`, `any:` — lists on one line — with further keys
  indented four spaces.
- Tabs, anchors, multi-line strings, nested maps, nested lists,
  duplicate keys, and unknown keys are errors.

### Keys

| Key | Required | Meaning |
|---|---|---|
| `covers` | yes | Invariant ids this policy enforces (snake_case) |
| `allow` | no | Tool-name glob patterns that may be called; if present, everything else on the matched server is blocked |
| `deny` | no | Tool-name glob patterns that are always blocked |
| `create_tools` | if `rules` | Tools whose writes create new data |
| `update_tools` | if `rules` | Tools whose writes change existing data |
| `values_at` | if `rules` or `refuse_keys` | Where attribute maps sit in the tool input: a key (`values`), a dotted path (`a.b`), or a list path (`records[].fields`) |
| `unwrap` | no | Keys whose value stands for a wrapped value (`{"option": "draft"}`); without them any object value on a write is an error |
| `unknown_writes` | no | `update` (default) or `block`: a tool in neither list whose input holds an attribute map |
| `refuse_keys` | no | Key shapes refused in attribute maps: `uuid` |
| `rules` | no | Field rules |

### Semantics

1. **Tool name.** Candidate names are every suffix of the tool name
   after `mcp__` that follows a `__`. A `deny` pattern matching any
   candidate blocks. With `allow` present, some candidate must match an
   `allow` pattern; `allow` only counts suffixes whose server segment
   (the text between the previous `__` and that suffix's `__`) contains
   the adapter's `server_match` (`guard.sh` passes it), so
   `mcp__attio__purge__get-x` cannot ride on `get-*`. Without a
   `server_match` (direct runs, `--check`), every suffix counts.
   Patterns are case-insensitive shell globs.
2. **Writes.** A tool in `create_tools` or `update_tools`, or (per
   `unknown_writes`) any other tool whose input holds an attribute map
   at a `values_at` path, is a write; each map found is checked. Walking
   a path, a missing key is skipped, but any other unexpected shape (a
   list inside a list, a list item that is not an object) blocks. An
   attribute key containing invisible (Unicode format) characters blocks.
3. **Values.** Lists flatten to their items; objects to the values
   under their `unwrap` keys (an object may hold only `unwrap` keys;
   any other key, or none, is an error); booleans to
   `true`/`false`; a JSON `null` compares as `null`. Leaves compare as
   trimmed lowercase strings.
4. **Rules.** A rule whose field appears in a map requires the
   flattened value to equal exactly one entry of the applicable list —
   `create` for creates, `update` for updates and unknown writes; `any`
   applies when the kind's own list is absent. No applicable list: not
   checked.
5. **Refused keys.** `refuse_keys: [uuid]` blocks any UUID-shaped key
   in a map (it could hide a ruled field).
6. **Field identity.** `field_<name>` (the name normalized: lowercase,
   spaces and hyphens become underscores) in `bindings/<capability>.md` (a
   `key: value` line) adds that ID as a key matching the rule. With
   `binding_id: required`, a write while the ID is missing is blocked.
7. **Errors.** An invalid policy, unreadable bindings, bad JSON, or any
   engine exception blocks, with the cause on stderr.
8. **Output.** Exit 2 with one line per problem, prefixed
   `Blocked by <label>: `; exit 0 otherwise. `--check` prints
   `FAIL: …` and exits 1 on an invalid policy. `guard.sh` passes the label
   `<agent> guard policy (<capability>/<provider>)`.

### Field identity

A rule names a field. It matches that key in the call, ignoring case
and separators (`Do Not Contact`, `do_not_contact`). Some providers key
fields by ID instead (Airtable writes `fld…`), so the probe records the
ID in `bindings/<capability>.md` as `field_<name>: <id>`, and the rule
matches that key too. `binding_id: required` makes the ID mandatory: a
write while it is missing is blocked.

## Bindings

`instance.yaml` binds each capability with one flat line,
`bind_<capability>: <provider>`. `custom` means the instance's own
adapter pack in `custom-adapters/<capability>/`; it may ship a
`guard.yaml` like any other. What the probe discovers — workspace IDs,
optional attributes, `field_<name>` IDs — goes in the instance's
`bindings/<capability>.md`. A capability with no binding is not set up:
the agent offers setup's tools step instead of calling anything.
Credentials stay in the host.

## Guard hook

`hooks/guard.sh` and `hooks/guard_policy.py`, each byte-identical to the
`_template/hooks/` copy and executable, run the guard. `guard.sh` is
registered in `hooks/hooks.json` as a `PreToolUse` command hook with
matcher `mcp__.*` and command `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"`.

`guard_policy.py` is the engine:
`python3 guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]`,
with the hook input on stdin. `--check <guard.yaml>` only parses the
policy. It never prints a traceback.

Inside an instance of the agent (source mode included), `guard.sh`
reads each `bind_<capability>: <provider>` line in `instance.yaml`. It
finds the adapter (the package's, or for `custom` the instance's
`custom-adapters/<capability>/`). When the tool name after `mcp__`
contains the adapter's `server_match` (case-insensitive substring), and
the adapter has a `guard.yaml`, it runs the engine with that policy, the
instance's `bindings/<capability>.md` (or `-`), and the `server_match`.
A `guard.yaml` that exists but cannot be read (a directory, a dangling
symlink) still reaches the engine, which blocks.

Exit 2 blocks. It fails closed: a missing engine, a missing `python3`,
any other nonzero exit from the engine, or hook input naming two
different tools blocks the call. Outside an instance it allows
everything.

Every `bind_<capability>` line applies its own adapter, so a repeated
key cannot hide one. The key may have spaces before the colon, and the
provider is lowercased and stripped of quotes and a trailing comment. A
`bind_` line that cannot be read (a bad capability or provider name)
blocks the call, since the binding state is unknown.

Matching over-covers on purpose, so a name containing `__` cannot hide
a match: `server_match` is tested against everything after `mcp__` in
the tool name.

A guard policy is evaluated locally and quickly. The host's hook timeout
would let a call through, so the engine never waits on the network or a
prompt.

## Setup — tools step

Setup's tools step binds each capability:

- Pick an adapter, or write a custom one: `adapter.md`, `adapter.yaml`,
  and optionally `guard.yaml`, checked with
  `guard_policy.py --check`.
- Find the matching connected server and run the probe.
- Write `bindings/<capability>.md`, including any `field_<name>` IDs the
  probe records.
- Refuse to bind when the contract has `no_send` and the adapter's
  `covers` lacks it.
- Write `bind_<capability>: <provider>` to `instance.yaml`.
- In source mode, add the `PreToolUse` guard hook to
  `.claude/settings.json`.
- Report, per capability, each invariant as covered or instruction-only.
  A capability is unattended-safe when every invariant is covered.
  Scheduled runs may use only unattended-safe capabilities.

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

The validator checks:

- `agent.yaml` exists, and its `standard` is `"2.0"`.
- `hooks/hooks.json` has a `SessionStart` command hook running
  `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"` and a `PreToolUse`
  entry with matcher `mcp__.*` whose command is exactly
  `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"` (quoted).
- `hooks/session-start.sh`, `hooks/guard.sh`, and
  `hooks/guard_policy.py` exist, are executable, and are byte-identical
  to the builder's `_template/hooks/` copies.
- Each name in `capabilities` is `snake_case`, and
  `capabilities/<name>/contract.md` exists with a `## Operations` table
  holding at least one backticked operation and a `## Invariants` list
  holding at least one backticked id; invariant ids are `snake_case`.
- Each capability has at least one adapter folder.
- Each adapter folder name is kebab-case and has `adapter.md` and
  `adapter.yaml`; `adapter.yaml` has exactly `capability`, `provider`,
  and `server_match` as plain values (no lists); `capability` and
  `provider` equal the folder names.
- `guard.yaml`, when present, parses with the engine's parser (the
  validator imports the template's `guard_policy.py`), and every
  `covers` id is a contract invariant.
- If the contract has `no_send`, every adapter has a `guard.yaml` whose
  `covers` includes it.
- `adapter.md` mentions every operation in backticks and has a
  `## Probe` section.
- A `capabilities/` folder not listed in `capabilities` fails.
