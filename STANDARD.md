# Agent Standard

An agent specification is a directory of provider-neutral markdown with a
single source of truth: one `AGENT.md`, one set of skills, one set of
sub-agent contracts. Provider differences — how Claude Code, Gemini CLI,
Codex, Cursor, or any other host discovers and wires up the agent — live
only in `hosts/`, which carry no behavior of their own. This document
is the standard `bin/validate-agent.sh` enforces; if this file and the
script ever disagree, the script is the ground truth and this file is a
bug.

## Development phase

The standard is 7.2. It is in active development: agents track
agent-builder's main branch, and version tags come with the first
official release. An agent declares the standard it follows in
`agent.yaml`, and the validator requires `standard: "7.2"`.

## Directory layout

```
agent-builder/
  README.md                 # what this folder is, how to use a spec
  STANDARD.md               # the Agent Standard
  _template/                # empty skeleton, copy to start an agent
  _ledger/                  # the standard ledger capability, copied into agents that use it
  <agent-name>/
    agent.yaml              # identity + standard version
    hooks/                  # hooks.json and five scripts, from _template
      session-start.sh      # entry hook
      guard.sh              # PreToolUse guard
      guard_policy.py       # guard policy engine
      schedule_check.py     # schedule gate and routine verifier
      tool_check.py         # tool folder checker
    capabilities/           # optional, one folder per capability
      <capability>/
        contract.md         # operations + invariants
        tools/
          <tool>/
            identity.yaml   # capability, provider, server_match
            usage.md        # operation -> tool map, ## Probe
            guard.yaml      # optional guard policy
            bootstrap.py    # optional
    .claude-plugin/         # plugin.json, marketplace.json
    .codex-plugin/          # plugin.json
    gemini-extension.json
    AGENT.md                # single source of truth
    install.sh              # links hosts/ files into host-expected locations
    hosts/
      CLAUDE.md             # pointer file, no behavior
      GEMINI.md             # pointer file, no behavior
      AGENTS.md             # pointer file, no behavior (Codex, Cursor, Amp, Copilot)
    skills/
      <skill-name>/
        SKILL.md            # frontmatter + procedure
        references/         # optional deep-dive files, loaded on demand
      schedule/             # required when agent.yaml declares activities
      add-tool/             # required when the agent has capabilities
    subagents/
      <role-name>.md        # role contract
    templates/              # blank fill-in artifacts the agent PRODUCES
    samples/                # filled-in gold-standard examples
    context/                # inputs the agent CONSUMES
    evals/
      cases.md              # given-X-expect-Y checks
```

`hosts/`, `skills/`, `subagents/`, `templates/`, `samples/`,
`context/`, and `evals/` are all required directories inside every
`<agent-name>/`, even if some start empty — the validator fails an agent
missing any of them. `AGENT.md`, `install.sh`, and `evals/cases.md` are
required files; `install.sh` must additionally be executable
(`chmod +x`). `hosts/CLAUDE.md`, `hosts/GEMINI.md`, and
`hosts/AGENTS.md` are all required, not optional per-host extras.

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

## Host files

`hosts/CLAUDE.md`, `hosts/GEMINI.md`, and `hosts/AGENTS.md` are
pointer files only — 25 lines maximum, and each must reference
`AGENT.md` by name so the host lands on the real specification. Any rule
placed in a host file is a defect: it creates a second source of truth
for that provider, and the two will drift.

```markdown
<!-- hosts/GEMINI.md -->
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
standard: "7.2"                # the Agent Standard version followed
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
mode: plugin               # plugin | source
bind_crm: attio            # one line per bound capability
accept_instruction_only: enroll_ready_only   # optional; see The unattended gate
```

`accept_instruction_only` lists invariants the operator knowingly
accepts as held by instructions alone, comma-separated. Only setup
writes it, after explaining in plain words what is not enforced and
what could happen; only invariants the contract marks `(acceptable)`
may be listed (see Capabilities).

`context/<file>` in `AGENT.md`, skills, and contracts means the
instance's file; if it is missing, run the step that produces it —
never act on the package's blank default. Setup copies into the
instance only the context files the interview fills (listed in
`skills/setup/SKILL.md`); package-owned context files the user never
edits stay in the package, are read from there, and `AGENT.md` says
so. The user's own examples live in the instance's `context/samples/`;
the package's `samples/` holds only the examples the agent ships with.
`templates/`, `samples/`, `skills/`, and `subagents/`
mean the package's files. Package paths are read-only in plugin mode:
write only into the instance. In source mode the package folder is the
instance (`instance.yaml` with `mode: source` at its root). An agent
with activities also gets `schedules.yaml` at the instance root (see
Activities and schedules).

## Entry hook

Every agent ships `hooks/hooks.json` with at least one `SessionStart`
command hook, `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"`, and
`hooks/session-start.sh` byte-identical to `_template/hooks/session-start.sh`
and executable. It finds the nearest `instance.yaml` above the session
folder and stops there (it never looks further up); if that file names
this agent, it prints where the instance and package live, and a line telling
the model to read `AGENT.md` in full. It then inlines `AGENT.md` only
when it is at most 9000 bytes; above that it points at the file
(Claude Code truncates hook output past 10,000 characters). The
validator prints a `WARN:` for an `AGENT.md` over 9000 bytes. It prints nothing for a `mode: source`
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

## Capabilities

A capability is an outside system the agent works through — a CRM, a
mailbox. The package describes it in two layers:

- `capabilities/<capability>/contract.md` — the neutral operations the
  agent thinks in (a `## Operations` table whose first column is each
  operation name in backticks) and the rules every tool must uphold
  (a `## Invariants` list, each item starting with a `snake_case` id in
  backticks). Skills and sub-agent contracts call operations, never a
  provider's tools. An invariant no guard can check by design (for
  example one that depends on a record's state in another system) may
  be marked acceptable by writing ` (acceptable)` right after its id:
  ``- `enroll_ready_only` (acceptable) — …``. An instance may then
  accept it as instruction-only (`accept_instruction_only`).
  Two invariant ids are reserved for sending. `no_external_send`: the
  capability never sends a message to anyone. `owner_only_send`: it
  sends only to recipients pinned in `bindings/<capability>.md` at
  interactive setup (the business owner). Neither can be marked
  `(acceptable)`, and a contract may not list both. The id `no_send`
  was renamed `no_external_send` in 7.0 and is an error.
  Two more ids are reserved for the ledger: `append_only_events` and
  `no_schema_change` (see Ledger). A fifth, `pinned_inputs`, is reserved
  for limits on a call's size: every input that limits a call's size
  (a result count, a page size, a budget) comes only from values pinned
  in `bindings/<capability>.md` at interactive setup. None of the five
  can be marked `(acceptable)`.
- `capabilities/<capability>/tools/<tool>/` — one folder per system
  (see Tools).

## Tools

A tool connects one capability's contract to one system. Its folder,
`capabilities/<capability>/tools/<tool>/` (kebab-case name), holds four
files, each with one reader and one purpose:

- `identity.yaml` is read by the hooks. It holds three flat keys, as
  plain values, plus an optional fourth:

      capability: crm
      provider: attio
      server_match: attio          # part of the MCP server name, lowercase
      wrapper: n8n                 # optional: the system is reached through an n8n workflow

  `capability` is the capability's folder name. `provider` is the tool's
  folder name (`custom` in an instance's `custom-tools/`). `server_match`
  matches `[a-z0-9_-]+`; the guard compares it to the lowercased text
  after `mcp__` in a tool name. `wrapper`, when present, must be `n8n`
  (see Wrapped tools). Any other key is an error.
- `usage.md` is read by the model. It maps every operation of the
  contract, each named in backticks, to that system's exact tool calls,
  fields, filters and views. It has a `## Probe` section: the read-only
  calls setup (or the `add-tool` skill) makes when binding, and what
  they record in `bindings/<capability>.md`.
- `guard.yaml` is the optional guard policy (next section). Its
  `covers` lists the invariants it enforces by mechanism. The rest are
  held only by the agent's instructions. A tool without `guard.yaml`
  works, but every invariant is instruction-only. An invariant named
  `no_external_send` or `owner_only_send` must be covered.
- `bootstrap.py` is optional, for tools that need a setup script. When
  it exists, `usage.md` must have a `## Setup` section, so a person can
  always create the fields by hand. `## Setup` lists each field or object
  the tool needs (object, label, internal name, type, options), and, for a
  tool with `bootstrap.py`, the environment variable the script reads,
  the key scopes it needs and the command to run. A tool without
  `bootstrap.py` may have `## Setup` too.

An instance may bring one tool of its own per capability, in
`custom-tools/<capability>/`, with the same three files
(`identity.yaml` with `provider: custom`, `usage.md`, and optionally
`guard.yaml`).

### hooks/tool_check.py

`hooks/tool_check.py` checks one tool folder against its capability's
contract. It is byte-identical in every agent and executable, needs
only `python3`, and never prints a traceback. The validator, the
schedule checker and the `add-tool` skill all use it, so the package
and instance rules cannot drift.

    tool_check.py <tool-folder> <contract.md> [--custom]

`--custom` treats the folder as an instance's `custom-tools/<capability>/`.
It prints one `FAIL: <message>` line per problem, or one `OK:` line, and
exits 0 (OK), 1 (FAIL lines) or 2 (ERROR: unreadable input). Its checks:

- `identity.yaml` exists, has the three keys (and at most `wrapper:
  n8n` besides), `capability` and `provider` match the folder (or
  `custom`), and `server_match` is lowercase letters, digits, `_` or `-`;
- a `wrapper: n8n` tool passes the Wrapped tools checks below;
- `usage.md` exists, mentions every contract operation in backticks, and
  has a `## Probe` section;
- `guard.yaml`, when present, parses with the engine's parser and its
  `covers` names only contract invariants;
- when the contract has `no_external_send` or `owner_only_send`,
  `guard.yaml` exists and covers it; a contract with `no_send` fails
  (`no_send was renamed no_external_send`), and one with both send
  invariants fails;
- when the contract has `owner_only_send` or `pinned_inputs` and the
  policy covers it, `guard.yaml` also has an
  `allow` list and at least one `recipients` entry. Each `allow` entry
  is an exact tool name (no `*`, `?` or `[`), and is either pinned by a
  `recipients` entry (the engine's case-insensitive match over its
  `tools`) or named as a whole token in `usage.md` `## Probe` as a
  read: `<pattern> is allowed but no recipients entry pins it`;

### Wrapped tools (n8n)

A system with no MCP server is wrapped in an n8n workflow. The tool
folder then ships `workflow.n8n.json`, an n8n workflow export whose
**MCP Server Trigger** exposes exactly the tools `usage.md` maps, each a
thin call to the system, and `identity.yaml` says `wrapper: n8n`.
`server_match` is the name the user gives the connector for the
trigger's URL. The system's keys are n8n credentials: the package and
the instance hold none.

Rules, each checked by `tool_check.py`:

- `workflow.n8n.json` exists and is an n8n export (a `nodes` list and a
  `connections` object): `missing <tool>/workflow.n8n.json (identity.yaml
  says wrapper: n8n)`, `not valid JSON`, `needs a nodes list and a
  connections object`.
- Exactly one MCP Server Trigger node
  (`@n8n/n8n-nodes-langchain.mcpTrigger`): `needs exactly one MCP Server
  Trigger node`.
- The trigger requires authentication (`authentication` is `n8nOAuth2`,
  `bearerAuth` or `headerAuth`): `the MCP Server Trigger must require n8n
  OAuth2, Bearer or Header auth`. Use **n8n OAuth2**: claude.ai
  connectors (which scheduled runs use) log in to n8n through it, and no
  shared secret exists to store or rotate. Bearer or Header auth works
  for hosts that send a header (Claude Code), with a new credential made
  only for this trigger.
- The exposed tools are the nodes connected to the trigger by an
  `ai_tool` connection. At least one: `exposes no tools`. Each is named
  in snake_case, because the node name is the MCP tool name: `tool node
  '<name>' must be named in snake_case`.
- A tool never lets the caller set its URL, method or request body: no
  `$fromAI` (any case) in any parameter whose name ends in `url` or is
  `method`, `jsonBody` or `body`, at any depth, and no `{placeholder}` in
  a URL: `tool <name> lets the caller set its <parameter path>`. Named
  fields the caller fills (a body parameter's `value`) are fine.
- The tools and `usage.md` agree both ways: each tool appears in
  `usage.md` as `<server_match>:<tool>`, and each `<server_match>:<name>`
  in `usage.md` is a tool: `tool <name> is not mapped in usage.md as
  <server_match>:<name>`, ``usage.md: `<server_match>:<name>` is not a tool
  of the workflow's MCP Server Trigger``.
- No literal bearer token anywhere in the workflow: `holds a literal
  bearer token; keep secrets in n8n credentials`.
- Every node has a text name: `every node needs a text name`.

Use one workflow per system and a per-workflow MCP Server Trigger only.
n8n's instance-level MCP access exposes generic tools that run or build
any workflow (`execute_workflow`, `create_workflow_from_code`, `update_workflow`, `archive_workflow`, `publish_workflow`, `unpublish_workflow`, `test_workflow` and `restore_workflow_version`), which would bypass every tool policy, so an
agent with a wrapped tool must deny every one of them in its agent guard
policy; a broad pattern such as `"*_workflow*"` counts. The validator
checks the package's wrapped tools, and the schedule gate fails an entry
whose bound tool (an instance's custom tool included) is wrapped while
the agent guard policy misses one: `the <provider> tool is wrapped in
n8n, so the agent guard policy must deny <tool>`.

The host connects to the trigger's Production URL as an MCP connector.
Two n8n behaviours trip setup up: saving a change to the trigger does not
change the live workflow until it is **published** again, and n8n
silently attaches an existing credential of the right type to a new
trigger, so create a new one for it (or switch to n8n OAuth2).

### The add-tool skill

`skills/add-tool/SKILL.md` is generic and shipped in `_template`. Every
agent with capabilities carries it byte-identical. It has two targets:

- **instance**: a set-up instance of the agent gets a custom tool in
  `custom-tools/<capability>/`, which the skill checks, probes and binds
  (`bind_<capability>: custom`);
- **package**: the agent's own repository gets a new shipped tool in
  `capabilities/<capability>/tools/<tool>/`, checked and left for a pull
  request.

The steps: choose the capability; find the system's MCP tools and
propose a `server_match`; write `identity.yaml`, `usage.md` (from the
system's real tool list, read-only) and `guard.yaml`; run
`tool_check.py` until it prints `OK`; for an instance, run the probe,
write `bindings/<capability>.md`, bind, and report each invariant as
covered or instruction-only. A source-mode instance is its own package
copy, so there the skill takes the package target and does not bind:
setup's tools step continues with the new tool at its probe and binding
sub-steps. The tool name `custom` is reserved for an instance's own tool,
so the package target refuses it and `tool_check.py` fails a shipped tool
folder with that name. It never writes credentials: logins stay in
the host's connectors. It refuses to continue on a `no_external_send` or `owner_only_send`
contract until `guard.yaml` covers it. For `owner_only_send` the policy
also needs an `allow` list and a `recipients` entry pinning every send
tool.

## Guard policy

A guard policy is a small file, `guard.yaml`, beside a tool's other files. It says
which tools may be called, which values may be written, and which
contract invariants that covers. One reference engine,
`hooks/guard_policy.py`, enforces it before every call. Because the
policy is data, an instance's custom tool can ship one too, so a tool
the user brings can qualify for unattended runs.

```yaml
# capabilities/crm/tools/attio/guard.yaml
covers: [draft_only, dnc_one_way, no_delete]

allow: [whoami, list-*, get-*, search-*, semantic-search-*, run-basic-report,
        add-record-to-list, create-record, upsert-record, update-record,
        update-list-entry-by-id, update-list-entry-by-record-id,
        create-note, create-task, update-task]
deny: ["*delete*", "*merge*", create-list, update-list]

writes:
  - kind: create
    tools: [add-record-to-list, create-record]
    at: [entry_values, values]
  - kind: update
    tools: [update-list-entry-by-id, update-list-entry-by-record-id,
            update-record, upsert-record]
    at: [entry_values, values]
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

A tool whose contract has `owner_only_send` pins its send arguments
instead:

```yaml
# capabilities/owner_notify/tools/resend/guard.yaml
covers: [owner_only_send]
allow: [send-email]
recipients:
  - tools: [send-email]
    at: [to, cc, bcc]
    bound: recipient_email
refuse_args: [draftId, replyToMessageId]
```

A tool that scrapes caps how much one call may ask for, and refuses
nested arguments it cannot let through:

```yaml
# capabilities/scraping/tools/apify/guard.yaml
covers: [pinned_inputs]
allow: [crawl]
refuse_args: ["startUrls[].payload", "startUrls[].method", proxyConfig]
limits:
  - tools: [crawl]
    at: [startUrls]
    bound: max_sites
```

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
- The exceptions are `rules:`, `writes:`, `recipients:` and `limits:`, whose values
  are block lists: each item starts with `  - `, with further keys indented four
  spaces. A `rules` item holds `field:` plus any of `create:`,
  `update:`, `any:`, or `field:` plus `forbid: true` or `forbid: update`;
  `forbid` takes no other value and is never combined with `create`,
  `update` or `any`. A `writes` item holds `kind:`, `tools:`
  and `at:`, the last two as flow lists. A `recipients` or `limits` item
  holds `tools:` and `at:`, as flow lists, and `bound:`, a scalar. A flow list in an item may
  continue over following lines indented at least four spaces until its
  closing `]`.
- Tabs, anchors, multi-line strings, nested maps, nested lists,
  duplicate keys, and unknown keys are errors.

### Keys

| Key | Required | Meaning |
|---|---|---|
| `covers` | yes | Invariant ids this policy enforces (snake_case) |
| `allow` | no | Tool-name glob patterns that may be called; if present, everything else on the matched server is blocked |
| `deny` | no | Tool-name glob patterns that are always blocked |
| `writes` | if `rules`, `refuse_keys` or `bound_keys_only` | A list of `{kind, tools, at}` entries. `kind` is `create` or `update`; `tools` are tool-name globs, matched as in `allow`/`deny`; `at` lists where attribute maps sit in the tool input: a key (`values`), a dotted path (`a.b`), or a list path (`records[].fields`). A path containing `[]` must be quoted: `"records[].fields"` |
| `unwrap` | no | Keys whose value stands for a wrapped value (`{"option": "draft"}`); without them any object value on a write is an error |
| `unknown_writes` | no | `update` (default) or `block`: a call that holds an attribute map at a `writes` path that no `writes` entry for that tool lists |
| `refuse_keys` | no | Key shapes refused in attribute maps: `uuid` |
| `bound_keys_only` | no | `true`: every key in a write map must be an ID recorded in a `field_<name>` binding |
| `rules` | no | Field rules |
| `recipients` | no | A list of `{tools, at, bound}` entries. `tools`: tool-name globs; `at`: argument paths (the `writes` path grammar); `bound`: a `snake_case` binding key. Pins argument values (text or numbers) to values recorded in bindings: every value at those paths must equal a `<bound>: <value>` line |
| `limits` | no | A list of `{tools, at, bound}` entries, the same shape as `recipients`. Caps a size instead of pinning a value: each list at an `at` path may be no longer, and each number no larger, than the one number in the `<bound>` binding line. A path the call does not have is allowed |
| `refuse_args` | no | Argument names a call may not use (any value but `null` or `""` blocks). An entry is a plain top-level name, or a path in the `writes` path grammar (`proxyConfig.useApifyProxy`, `"startUrls[].payload"`; quote a path containing `[]`) that refuses a nested value |

### Semantics

1. **Tool name.** Candidate names are every suffix of the tool name
   after `mcp__` that follows a `__`. A `deny` pattern matching any
   candidate blocks. With `allow` present, some candidate must match an
   `allow` pattern; `allow` only counts suffixes whose server segment
   (the text between the previous `__` and that suffix's `__`) contains
   the tool's `server_match` (`guard.sh` passes it), so
   `mcp__attio__purge__get-x` cannot ride on `get-*`. Without a
   `server_match` (direct runs, `--check`), every suffix counts.
   Patterns are case-insensitive shell globs.
2. **Recipients, limits and refused arguments.** These run after `allow` and
   `deny`. Every problem they find is reported, and any one blocks the
   call before writes are read.

   *Refused arguments.* Each top-level argument name of the call is
   compared with the `refuse_args` names after lowercasing both and
   removing every `_` and `-`, so `refuse_args: [draftId]` refuses
   `draftId`, `draft_id` and `DRAFT-ID`. A call that holds one with any
   value other than JSON `null` or `""` (`0`, `false` and an empty list
   included) is blocked: `<tool> may not use <arg>`, with `<arg>` as the
   call sent it.

   A `refuse_args` entry that is a path (anything but a plain name) is
   walked through the call's input. Each segment is compared with the
   key the way a plain name is (lowercased, `_` and `-` removed), and
   every key that matches counts. A value found at the path that is not
   `null` and not `""` blocks: `<tool> may not use <path>`, with
   `<path>` as the policy wrote it. A `null` where an object or list is
   expected holds nothing. Any other wrong shape (a scalar where a list
   or object is expected, a list item that is not an object) counts as
   present and blocks: a mismatch never raises. With a path entry
   present, a call whose input is not an object blocks.

   *Recipients.* For each `recipients` entry whose `tools` match the
   call (suffix matching as in step 1; a matching call whose input is
   not an object blocks):

   1. Collect the values at every `at` path. `null` counts as absent. A
      string or a number is one value; a list of them is its items. An
      absent path is skipped. Any other shape (a boolean, an object, a
      nested list) blocks: `<path>: a pinned value must be a string, a
      number, or a list of them`.
   2. If no value was collected across all the paths, block: `<tool>
      names no pinned value at <paths>`.
   3. Read every `<bound>: <value>` line in `bindings/<capability>.md`.
      The key may repeat; each line adds one allowed value. With no such
      line, block: `no <bound> line in bindings; re-run setup's tools
      step`. If any of them is not a bare value (see Field identity),
      block: `<bound> must be a bare value`.
   4. Each collected value, trimmed and lowercased, must equal one bound
      value, trimmed and lowercased. A number also matches a numerically
      equal bound value: a value is numeric when it is a JSON number or
      a string matching `^[+-]?[0-9]+(\.[0-9]+)?$` (ASCII digits), and
      numbers compare exactly as decimals, with the bound values parsed
      the same way (`10`, `10.0` and `"10"` are equal; a non-finite
      number never matches). A display-name form (`Owner
      <owner@example.com>`) is not unwrapped and does not match: it
      fails closed. Otherwise block: `<value> is not a pinned value
      (<bound>)`.

   A `recipients` entry limits a call to values the operator confirmed
   at setup: a send's recipients, or the size of a scrape. `guard.sh`
   also requires the bindings file to match its pushed copy, for an
   exempt capability and for every bound tool whose policy has a
   `recipients` or `limits` entry, so an edit to the file does not take
   effect until it is pushed (see Guard hook).

   *Limits.* For each `limits` entry whose `tools` match the call (a
   matching call whose input is not an object blocks):

   1. Read every `<bound>: <value>` line in the bindings. With none,
      block: `no <bound> line in bindings; re-run setup's tools step`.
      The lines must agree on one number, parsed as in Recipients step 4;
      more than one distinct number, or a value that is not a number,
      blocks: `<bound> must be one number`.
   2. Collect the values at every `at` path, with segments compared as
      for nested `refuse_args`. `null` is skipped, and so is a path the
      call does not have: limits cap, they do not require. A wrong shape
      on the way (a scalar where an object or list is expected) blocks as
      `cannot check this call`.
   3. A list counts as its length. A number, or a string that is numeric
      as in Recipients step 4, counts as its value. Anything else (a
      boolean, an object, a non-numeric string) blocks: `<path>: a
      limited value must be a list or a number`.
   4. A count above the bound blocks: `<tool> exceeds <bound> at <path>
      (<count> > <bound value>)`.

3. **Writes.** The matching entries are the `writes` entries whose
   `tools` match the call's tool name, using the same suffix matching as
   `allow` and `deny`. For each matching entry, collect the value maps
   found at each of its `at` paths, and tag each map with that entry's
   `kind`. A listed path that is absent from the call is skipped.
   Walking a path, a missing key is skipped, but any other unexpected
   shape (a list inside a list, a list item that is not an object)
   blocks. An attribute key containing invisible (Unicode format)
   characters blocks.

   A tool matched by entries of both kinds is allowed. HubSpot's
   `manage_crm_objects` has a create entry at
   `createRequest.objects[].properties` and an update entry at
   `updateRequest.objects[].properties`, and each map gets the kind of
   the entry whose path found it.

   **Unknown writes.** A value map sits at a path listed in some entry,
   and either no entry matches the tool, or the tool matches entries but
   none of them lists that path (a matched tool writing at a path listed
   only by other entries). With `unknown_writes: block` the call is
   blocked (`<tool> writes values at <path>, which no writes entry for
   this tool lists`, when the tool matched some entry). With
   `unknown_writes: update` (the default) those maps are checked as
   `update`.

   **Stated limits.** When a tool matches an entry but uses a path that
   no `writes` entry lists anywhere, its values are not found and go
   unchecked; the `allow` and `deny` lists are the backstop. When one
   tool matches both a create entry and an update entry that share a
   path, each map at that path is checked with both kinds, so a rule
   whose `create` and `update` lists differ can never pass for a field
   there: such a field can't be written at all. The policy fails closed,
   but give each kind its own path.
4. **Values.** Lists flatten to their items; objects to the values
   under their `unwrap` keys (an object may hold only `unwrap` keys;
   any other key, or none, is an error); booleans to
   `true`/`false`; a JSON `null` compares as `null`. Leaves compare as
   trimmed lowercase strings.
5. **Rules.** A rule whose field appears in a map requires the
   flattened value to equal exactly one entry of the applicable list —
   `create` for creates, `update` for updates and unknown writes; `any`
   applies when the kind's own list is absent. No applicable list: not
   checked. A rule with `forbid: true` blocks any write of its field, on
   create or update, whatever the value (`<field> may not be written`).
   A rule with `forbid: update` blocks its field in a map checked as an
   update, unknown writes included (`<field> may not be changed after
   create`), and does not check creates. Other fields in the same map
   are still checked by their own rules.
6. **Refused keys.** `refuse_keys: [uuid]` blocks any UUID-shaped key
   in a map (it could hide a ruled field).
7. **Recorded keys.** With `bound_keys_only: true`, every key in every
   collected map (create, update or unknown) must equal, ignoring case,
   an ID recorded in some `field_<name>` binding; otherwise
   `<key> is not a recorded field ID; re-run the probe (setup's tools
   step)`. With no `field_` lines at all, a call holding a non-empty map
   is blocked with `the probe has not recorded any field IDs in
   bindings; re-run setup's tools step`.
8. **Field identity.** Each `field_<name>` line (the name normalized:
   lowercase, spaces and hyphens become underscores) in
   `bindings/<capability>.md` adds its ID as a key matching the rule for
   that name. The key may repeat; every line adds one ID.
9. **Errors.** An invalid policy, unreadable bindings, bad JSON, or any
   engine exception blocks, with the cause on stderr.
10. **Output.** Exit 2 with one line per problem, prefixed
   `Blocked by <label>: `; exit 0 otherwise. `--check` prints
   `FAIL: …` and exits 1 on an invalid policy. `guard.sh` passes the label
   `<agent> guard policy (<capability>/<provider>)`.

### Parse errors

Each is an invalid policy, and fails closed.

- `kind` is not `create` or `update`.
- `tools` or `at` is missing or empty.
- An `at` path is not a valid path.
- A `writes` entry has an unknown key.
- A `recipients` entry has an unknown key, or no `bound`, or a `bound`
  that is not `snake_case`; or `recipients:` has no items.
- A `limits` entry is invalid in the same ways as a `recipients` entry
  (unknown key, no `bound`, a `bound` that is not `snake_case`, a missing
  or empty `tools` or `at`, a bad `at` path); or `limits:` has no items.
- `refuse_args` is empty, or holds an entry that is neither a plain
  argument name (`^[A-Za-z_][A-Za-z0-9_]*$`) nor a path like `a.b` or
  `a[].b` (the `writes` path grammar).
- `rules`, `refuse_keys` or `bound_keys_only` is present without `writes`.
- `bound_keys_only` is not `true`.
- `forbid` is not `true` or `update`.

### Field identity

A rule names a field. It matches that key in the call, ignoring case
and separators (`Do Not Contact`, `do_not_contact`). Some providers key
fields by ID instead (Airtable writes `fld…`), so the probe records the
ID in `bindings/<capability>.md` as `field_<name>: <id>`, and the rule
matches that key too. A name used in two places (Airtable tables can
share a field name) gets one line per ID, and a rule for that name
matches all of them, which fails closed. With `bound_keys_only: true`
the recorded IDs are also the only keys a write may use, so a field
added or recreated in the provider is refused until the probe runs
again.

The exact form is a plain line, `field_<name>: <ID>`, with nothing else
on it: no bullet, and no trailing comment or note. The engine strips one
surrounding pair of backticks or matching quotes; the rest must match
`^[A-Za-z0-9_.-]+$`, or the call is blocked with `field_<name> must be a
bare ID`. A bulleted line is not read as a binding. Keys that do not
start with `field_` are not checked.

Recipient lines (`<bound>: <value>`) follow the same plain-line form. The
engine strips one surrounding pair of backticks or matching quotes from the
value, and then the value must match `^[^\s<>"',;]+$`.

### Agent guard policy

An agent may ship one more policy, `guard.yaml` at the package root. It
is deny-only and applies to every MCP call inside an instance of the
agent, whatever the server, bound or not:

```yaml
# guard.yaml — sales-partner agent guard policy
covers: [no_external_send]
deny: ["*send*", "*reply*", "*forward*", "*publish*", "*schedule_message*",
       "*cross_post*", "*posts_create*", "*bulk_upload_posts*", "*execute_write*"]
exempt: [owner_notify]
```

The grammar is the tool policy's. The keys are `covers` (optional,
`snake_case` ids), `deny` (required, a non-empty list of tool-name
globs) and `exempt` (optional, a non-empty list of `snake_case`
capability names); any other key is a parse error. The engine runs it as
`guard_policy.py --agent <guard.yaml> [label] [--exempt <server_match>]...`
with the hook input on stdin, and `--check --agent <guard.yaml>` only
parses it. `guard_policy.py --exempt-caps <guard.yaml>` prints each
`exempt` capability, and `guard_policy.py --covers <tool guard.yaml>`
prints each `covers` id of a tool policy; both print nothing and exit 1
on a file that does not parse. Candidate names are every suffix after
`mcp__` that follows a `__`, with no `server_match`, so every suffix
counts. A matching pattern blocks with `<tool> is denied (<pattern>)`;
errors block as in a tool policy.

When any capability's contract has a `no_external_send` invariant, the agent
must ship this file and its `covers` must include `no_external_send`. The
validator and the schedule gate both check it.

**Exempt.** `exempt` lets one capability that sends only to the owner get
past the deny list. Each name must be a listed capability whose contract
has `owner_only_send`; the validator rejects any other.

- *Hook.* For each capability in `exempt`, `guard.sh` reads its
  `bind_` line and finds the bound tool. For a call whose name contains
  the tool's `server_match`, it adds that `server_match` to the exempt
  list only when all of these hold: the
  binding is a tool shipped in the package (never `custom`); the tool's
  `identity.yaml` has a valid, non-empty `server_match`; its
  `guard.yaml` is a regular file (not a symlink) and its `covers`
  include `owner_only_send`. If any of these fails, the capability gets
  no exemption and the deny list applies in full. An unbound notify
  capability simply can't send. Then, for a call to that server,
  `bindings/<capability>.md` must also match its pushed copy, or the
  call is blocked (see Guard hook).
- *Engine.* The `--exempt <server_match>` options (one per exempt
  capability) skip `deny` for a call whose tool name holds the
  `server_match` in a server segment, the text between one `__` and the
  next (case-insensitive; the rule `allow` uses). A match anywhere else
  in the name does not count. Nothing else is skipped: the `bind_` loop
  still runs the tool's own policy, which must pass the call (`allow`,
  `recipients`, `limits`, `refuse_args`). A `server_match` that is not
  `[a-z0-9_-]+` blocks.

Globs match names, not behaviour: a connector whose send tool has an
unusual name (a generic `execute_write`) is caught only if the author
lists it. Check the list against the read tools of the connectors your
users have, so no read is denied. For scheduled runs the connector
restriction (`verify`) stays the strongest control.

## Bindings

`instance.yaml` binds each capability with one flat line,
`bind_<capability>: <provider>`. `custom` means the instance's own
tool in `custom-tools/<capability>/`; it may ship a `guard.yaml` like
any other. What the probe discovers — workspace IDs,
optional attributes, `field_<name>` IDs — goes in the instance's
`bindings/<capability>.md`. A capability with no binding is not set up:
the agent offers setup's tools step instead of calling anything.
Credentials stay in the host.

## Ledger

An agent may keep a ledger: a record of what it did, in a store the
business owns, plus state it reads back between runs. The builder
ships the standard capability at `_ledger/`. An agent that uses it
lists `ledger` in `capabilities`, copies `_ledger/contract.md` and
`_ledger/tools/` into `capabilities/ledger/`, and
`_ledger/skills/ledger-backfill/` into `skills/`. Those files stay
byte-identical to the builder's. The agent owns
`capabilities/ledger/tables.md`: its `ledger_schema` version and the
tables it declares besides `Events`.

- **`Events`** is the same in every agent: `Run ID` (primary),
  `Key` (formula), `At`, `Recorded At` (created time), `Seq`, `Activity`,
  `Trigger`, `Event`, `Subject`, `Outcome`, `Items In`, `Items Out`,
  `Cost USD`, `Duration s`, `Detail`, `Agent Version`, `Backfilled`.
  The list, with types, is `LEDGER_EVENTS` in `hooks/tool_check.py`.
- **`tables.md`**: `ledger_schema: <n>`, then per table a `## <Name>`
  heading, a `key: <Field>` line and a `| Field | Type | Options |`
  table. No table named `Events`; no field whose name, normalized,
  equals an `Events` field.
- **Schema changes** are additive only and made only by the tool's
  `bootstrap.py`, never over MCP. The script creates missing tables
  and fields; a missing select option or a field of the wrong type
  stops it with an error naming the manual fix, and it never deletes,
  renames or retypes anything. With `--require-bump`, the validator
  fails a `tables.md` change that does not raise `ledger_schema`, or
  that removes, renames or retypes a table, field or select option, or
  changes a table's key.
- **Invariants**: `append_only_events` (a tool covering it needs
  `bound_keys_only: true` and a `forbid: update` rule for every
  writable `Events` field), `no_delete`, and `no_schema_change` (a
  tool covering it must refuse `typecast`).
- **Bindings**: the probe writes `base_id`, `table_<name>`,
  `field_<name>` for every written field (every `Events` field except
  the computed `Key` and `Recorded At`, and the agent tables' fields),
  and `ledger_schema`.
- **Gate**: a scheduled activity using a capability with
  `append_only_events` needs `base_id`, `table_events`, a `field_<name>`
  line for every writable `Events` field, and `ledger_schema` equal to
  the package's.
- **Failure policy**: in `_ledger/contract.md`.

## Guard hook

`hooks/guard.sh` and `hooks/guard_policy.py`, each byte-identical to the
`_template/hooks/` copy and executable, run the guard. `guard.sh` is
registered in `hooks/hooks.json` as a `PreToolUse` command hook with
matcher `mcp__.*` and command `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"`.

`guard_policy.py` is the engine:
`python3 guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]`,
with the hook input on stdin. `--check <guard.yaml>` only parses the
policy. `--agent <guard.yaml> [label] [--exempt <server_match>]...` and
`--check --agent <guard.yaml>` do the same for the agent guard policy.
Two query modes serve `guard.sh`: `--exempt-caps <guard.yaml>` prints each
`exempt` capability of an agent policy, and `--covers <guard.yaml>`
prints each `covers` id of a tool policy, and `--pins <guard.yaml>` prints
each `bound` key of a tool policy's `recipients` entries and then its
`limits` entries, each key once (nothing when it pins none). It never prints a traceback.

Inside an instance of the agent (source mode included), for an MCP
call, `guard.sh` first runs the agent guard policy when `guard.yaml`
exists at the package root (a dangling symlink or a directory by that
name still reaches the engine, which blocks), with the label `<agent>
agent guard policy`. A missing engine, a missing `python3`, or any other
nonzero exit from the engine blocks. Then `guard.sh`
reads each `bind_<capability>: <provider>` line in `instance.yaml`. It
finds the tool (the package's `capabilities/<capability>/tools/<provider>/`,
or for `custom` the instance's `custom-tools/<capability>/`). When the
tool name after `mcp__` contains the tool's `server_match`
(case-insensitive substring), and the tool has a `guard.yaml`, it runs the engine with that policy, the
instance's `bindings/<capability>.md` (or `-`), and the `server_match`.
A `guard.yaml` that exists but cannot be read (a directory, a dangling
symlink) still reaches the engine, which blocks.

**Exemption.** Before it runs the agent guard policy, `guard.sh` reads the
policy's `exempt` capabilities (`--exempt-caps`). For each, it grants the
exemption only when the tool name after `mcp__` contains the bound tool's
`server_match` and the conditions under Agent guard policy hold: a tool
shipped in the package, never `custom`; a valid `server_match`; a regular
`guard.yaml`, not a symlink, whose `covers` (`--covers`) include
`owner_only_send`. An exempt capability's server then skips the deny list
(`--exempt <server_match>`), and its own tool policy still decides the call.
The call is also blocked unless `bindings/<capability>.md` is a regular
file, not a symlink, whose bytes equal the upstream (`@{u}`) copy at
`bindings/<capability>.md`, root-relative, so the instance must be the
repository root: `bindings/<capability>.md must be committed and pushed
before <capability> can run (it differs from the upstream copy, is
untracked, or the instance has no git upstream); re-run setup's tools
step, then commit and push`. The block is prefixed `Blocked by <agent>
agent guard policy:`.

**Pinned values.** The same pushed-copy check, with the same message,
also runs for every bound tool whose policy pins values (a `recipients`
or `limits` entry, listed by `--pins`), exempt or not, whatever the invariant. The
bind loop reads the tool's `guard.yaml` once into private scratch and
runs `--pins` on that copy; a `--pins` that fails blocks the call. When
the policy pins values, the engine then reads a private copy of the
verified upstream bindings blob, not the working-tree file, so the bytes
that were checked are the bytes that decide. A policy that pins nothing
needs no pushed bindings. On this path the block is prefixed `Blocked by
<agent> guard policy (<capability>/<provider>):`, not the agent-policy
prefix of the exempt path.

In both paths `git` runs with every transport refused, lazy fetch
off, replace objects off, system config ignored, fsmonitor off, stdin from
`/dev/null` and its output discarded, and the upstream blob's bytes are read
directly, so no diff driver or clean filter runs.

**Stated limit.** The pushed-copy check stops edits to the bindings file
and unpushed commits. An agent that rewrites its own instance repository's
`.git` can still defeat it: tracking refs, the branch's upstream or remote
config, `core.worktree`, a `.git` gitfile, or `objects/info/alternates`.
The guard defends against mistakes and injected single actions. For
scheduled runs the connector restriction (`verify`) stays the strongest
control.

Exit 2 blocks. It fails closed: a missing engine, a missing `python3`,
any other nonzero exit from the engine, or hook input naming two
different tools blocks the call. Outside an instance it allows
everything.

Every `bind_<capability>` line applies its own tool, so a repeated
key cannot hide one. The key may have spaces before the colon, and the
provider is lowercased and stripped of quotes and a trailing comment. A
`bind_` line that cannot be read (a bad capability or provider name)
blocks the call, since the binding state is unknown.

A bound tool with no `identity.yaml` blocks every MCP call, whatever
the tool name: the binding state is unknown, so the guard fails closed.
For a custom binding, the message says to run the `add-tool` skill. For a shipped tool, it says to fix
the binding (setup's tools step).

A bound tool whose `identity.yaml` has an empty `server_match` could
never match a call. With no `guard.yaml` it is instruction-only and the
guard goes on to the next binding. With a `guard.yaml` (or a dangling
symlink by that name) it blocks every MCP call, since its policy could
never apply; the message says to fix `identity.yaml` (`tool_check.py`
reports it).

A custom tool bound to a `no_external_send` capability is covered by the agent
guard policy's deny list, whatever its own files say; `add-tool`,
`tool_check.py` and the schedule gate still require its own
`guard.yaml`. A custom tool bound to an `owner_only_send` capability gets
no exemption, so the deny list applies to it in full.

Matching over-covers on purpose, so a name containing `__` cannot hide
a match: `server_match` is tested against everything after `mcp__` in
the tool name.

A guard policy is evaluated locally and quickly. The host's hook timeout
would let a call through, so the engine never waits on the network or a
prompt.

## Setup — tools step

Setup's tools step binds each capability:

- Pick a shipped tool, or run the `add-tool` skill to write a custom
  one (checked with `tool_check.py`). In plugin mode `add-tool` binds it
  itself, and setup moves to the next capability. In source mode it adds
  the tool to the package copy, and setup continues with that tool at the
  steps below.
- Find the matching connected server and run the tool's `usage.md`
  `## Probe`. If it fails because fields or objects are missing and the
  tool has a `## Setup` section, offer two choices:
  - **Create them yourself.** Show the `## Setup` list as plain steps in
    that system, then probe again.
  - **Use an API key.** Only when the tool has a `bootstrap.py`. Show the
    exact command and the environment variable and key scopes from
    `## Setup`. The user runs it in their own terminal, with the key set
    only in that terminal's environment by `read -rs <VAR> && export <VAR>`,
    which keeps it out of shell history.
  The key never enters the chat or any file. The probe must pass before
  the tool is bound. Setup's opening message tells the user up front to
  connect each system to their host and that fields may need creating,
  by hand or with an API key.
- Write `bindings/<capability>.md`, including any `field_<name>` IDs the
  probe records.
- Refuse to bind when the contract has `no_external_send` or
  `owner_only_send` and the tool's `covers` lacks it.
- For `owner_only_send`: ask for each pinned value the tool's `usage.md`
  `## Setup` lists, repeat each back, write `<bound>: <value>` lines to
  `bindings/<capability>.md` after the operator confirms, then commit and
  push the instance. Owner sends are refused until
  `bindings/<capability>.md` matches the pushed copy. Then offer one test
  notification to the pinned recipient, sent only after the operator
  confirms.
- Write `bind_<capability>: <provider>` to `instance.yaml`.
- In source mode, add the `PreToolUse` guard hook to
  `.claude/settings.json`.
- Report, per capability, each invariant as covered or instruction-only.
  A capability is unattended-safe when every invariant is covered.
  Scheduled runs may use only unattended-safe capabilities.

## Activities and schedules

An activity is a Workflow step that can run on a schedule with nobody at
the keyboard. `agent.yaml` declares each one with a flat key naming the
capabilities it uses:

```yaml
activity_prospect: crm
activity_digest: crm, email_drafts
activity_research: none
```

Activity names are kebab-case. A value is `none` or a comma-separated
list of names from `capabilities`. An agent with any `activity_*` key
must ship `skills/schedule/SKILL.md`, must set `catalog` and
`catalog_repo` (the cloud environment installs the agent from its
catalog), and must write each activity's instructions so it runs to its
stop conditions unattended. An activity whose capabilities are not all
covered by guard policies is refused by the gate. An empty
`activity_x:` fails validation; write `none`.

### schedules.yaml

The instance holds `schedules.yaml` at its root, as flat keys:

```yaml
timezone: America/New_York
environment: env_01...
schedule_prospect: "Monday 07:00"
then_prospect: prepare
schedule_digest: "Monday 08:00"
routine_digest: trig_01...
```

- `timezone`: an IANA name.
- `environment` (optional): the id of the cloud environment the
  agent's routines use, `env_` then letters and digits. The schedule
  skill writes it after the user confirms the id `verify` reports.
- `schedule_<activity>`: a weekday or `daily`, then a 24-hour time, in
  that timezone.
- `then_<activity>` (optional): activities to run after it in the same
  session, comma-separated.
- `routine_<activity>`: the routine's ID, written by the schedule skill
  after it verifies the routine.

Every activity named must be an `activity_*` in `agent.yaml`. The
interview writes `timezone`, `schedule_*`, and `then_*`; nothing else in
the instance declares schedules. A repeated `schedule_`, `then_`, or
`activity_` key is an error.

### Scheduled runs

A scheduled run is a Claude cloud routine. Each run clones the
instance's GitHub repository, so the instance folder must be the root of
that repository. The routine's prompt is exactly:

> Scheduled run of `<activity>`[, then `<next>`, ...] (unattended).
> Follow this agent's instructions for each activity, in order. Do not
> ask questions and do not edit or commit files in this repository. If
> something needs the operator, stop and say exactly what.

Under this prompt a run may not ask questions and may not edit or commit
instance files. It records its work in the connected systems only, and
stops and reports when an input is missing.

Routines do not load plugins from the repository, so the agent comes
from a cloud environment. The user keeps one environment per account
(suggested name `webspenser-agents`) whose setup script holds, for each
agent, a version comment and two install lines:

```bash
# sales-partner 5.0.0
claude plugin marketplace add webspenser/agent-library
claude plugin install sales-partner@webspenser
```

Changing the version comment when the agent is updated makes the
environment reinstall it. Every routine for the agent uses that
environment; any other environment does not load the agent or its
guard. The guard does nothing outside an instance, so sharing the
environment between agents is safe.

A source-mode instance already carries the agent and its guard as a
repository-level hook (setup's tools step), so its routine runs load
both from the cloned repository and the setup script needs no install
lines for it.

### The unattended gate

An entry may be scheduled only if it passes the gate. For the entry's
activity and its `then` activities, every capability used must be
bound, and every invariant of each capability's contract must be in the
bound tool's `guard.yaml` `covers`. These further rules apply to
the send and pinning invariants:

- A `no_external_send` invariant must also be in the agent guard policy's
  `covers`.
- An `owner_only_send` or `pinned_inputs` capability needs the bindings
  to hold at least one line for every `recipients` and `limits` `bound` key of the
  bound tool (`<capability>: bindings/<capability>.md has no <key> line
  (the <provider> tool pins values to it) ...`), each a bare value
  (`<capability>: bindings/<capability>.md <key> must be a bare value
  (the <provider> tool pins values to it) ...`).
- An `owner_only_send` capability also needs the agent guard policy to
  list it in `exempt` (`owner_only_send needs the agent guard policy to
  list <capability> in exempt`). A `pinned_inputs` capability needs no
  exemption.

The gate does not check that the bindings file is pushed; the guard
does that on every call that depends on it.

An invariant the contract marks
`(acceptable)` and `instance.yaml` lists in `accept_instruction_only`
counts as covered; the check prints it under the passing entry as
`ACCEPTED (instruction-only): <capability>: <invariant>`, every time.
The gate also fails an entry when:

- `agent.yaml` has no `catalog` or `catalog_repo`;
- a bound tool has no `server_match`, or one outside `[a-z0-9_-]+`;
- a capability has more than one `bind_` line, or a `bind_` line the
  guard cannot read;
- an `identity.yaml` it uses holds control characters;
- a bound tool fails `tool_check.py`;
- an `activity_`, `schedule_`, or `then_` key is repeated;
- `schedules.yaml` has an `environment` that is not `env_` then letters
  and digits;
- the time is not `<weekday|daily> HH:MM`;
- `accept_instruction_only` lists an invariant of one of the entry's
  capabilities that its contract does not mark `(acceptable)`.

A `routine_<activity>` line with no `schedule_<activity>` also fails
the check: that routine still runs without the gate, so the checker
names it for the user to disable or delete.

Some problems stop the whole check with an error (exit 2) instead of
failing one entry, for example: a timezone that is not an IANA name,
a missing or empty `schedules.yaml`, an `agent` in `instance.yaml` that
is not the `name` in `agent.yaml`, and control characters in
`agent.yaml` or `instance.yaml`.

### The schedule skill

`skills/schedule/SKILL.md` is generic and shipped in `_template`. It:

1. checks that `schedules.yaml` has entries;
2. checks that the instance folder is the root of a clean GitHub
   repository, on its default branch (routines clone that branch), in
   step with `origin`, with `instance.yaml`, `schedules.yaml`,
   `context/`, and `bindings/` committed;
3. runs the gate and refuses failing entries;
4. tells the user what to put in the environment's setup script;
5. prints the routine's name, repository, environment, connectors,
   schedule (with the UTC cron), and prompt for the user to create in
   the web UI;
6. verifies the routine the user created against the routines API and
   records `routine_<activity>`;
7. optionally does a smoke run and reads its log;
8. on later runs, re-checks everything and names routines the user must
   disable or delete.

It never creates or deletes routines. The gate runs only when the
schedule skill runs: after changing bindings, `schedules.yaml`, the
agent version, or the environment, re-run the skill.

### hooks/schedule_check.py

The skill's checker is `hooks/schedule_check.py`, byte-identical in
every agent and executable. It needs only `python3`.

- `schedule_check.py check <instance> [--repo owner/name] [--json]`
  applies the gate to every `schedule_` entry and prints `PASS` or
  `FAIL` for each, with the routine name, schedule, UTC cron, connectors
  (each as its provider and the `server_match` text a connector's name
  must contain), the prompt, and the environment setup script. It exits
  0 when every entry passes and no `routine_` line lacks its schedule.
- `schedule_check.py verify <instance> <activity> <routine.json>
  [--repo owner/name]` compares the routines API's JSON for a routine
  with what `check` expects (exactly one repository source, and it is
  this repository; enabled; exact prompt; a connector per bound
  capability and no connector that matches no bound `server_match`;
  next run time; the cloud environment) and prints one `MISMATCH` line
  per difference, or `OK`. Without `--repo` only the repository name is
  compared. The routine's `environment_id` must equal `environment` in
  `schedules.yaml`; when `schedules.yaml` has none, `verify` names the
  routine's environment and asks the user to confirm it and record it.

## Validation

```bash
bin/validate-agent.sh <agent-dir>
```

Exits `0` and prints `OK: <agent-dir> conforms` when the directory
matches every rule above; otherwise prints one `FAIL:` line per problem
and exits non-zero. Run it before committing any change to an agent
directory — a change that breaks heading order, frontmatter shape, or
host-file size is a change that breaks portability, and this script is the
only thing that catches it before a host does.

The validator checks:

- `agent.yaml` exists, and its `standard` is `"7.2"`.
- `hooks/hooks.json` has a `SessionStart` command hook running
  `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"` and a `PreToolUse`
  entry with matcher `mcp__.*` whose command is exactly
  `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"` (quoted).
- `hooks/session-start.sh`, `hooks/guard.sh`, `hooks/guard_policy.py`,
  `hooks/schedule_check.py`, and `hooks/tool_check.py` exist, are
  executable, and are byte-identical to the builder's `_template/hooks/`
  copies.
- Each name in `capabilities` is `snake_case`, and
  `capabilities/<name>/contract.md` exists with a `## Operations` table
  holding at least one backticked operation and a `## Invariants` list
  holding at least one backticked id; invariant ids are `snake_case`.
- Each capability has at least one tool folder, and each tool folder
  passes `tool_check.py` (the validator loads the template's copy): the
  identity, `usage.md` (including `## Setup` when `bootstrap.py` exists)
  and `guard.yaml` rules in Tools above, and
  `guard.yaml` covering `no_external_send` or `owner_only_send` when the
  contract has it. When a policy covers `owner_only_send` or
  `pinned_inputs`, the extra pin rules apply (an exact `allow` list,
  `recipients`). A contract's `pinned_inputs` need not be covered for
  the package to validate, but an uncovered one fails the unattended
  gate, which requires every contract invariant to be covered or
  accepted.
- A `guard.yaml` at the package root parses as an agent guard policy.
  When any contract has `no_external_send`, it must exist and its `covers` must
  include `no_external_send`. Each name in its `exempt` must be a listed
  capability whose contract has `owner_only_send`: `guard.yaml: exempt
  names <cap>, which is not in capabilities` and `guard.yaml: exempt
  names <cap>, whose contract has no owner_only_send`. When any tool says `wrapper: n8n`, its `deny`
  patterns must match each of `execute_workflow`, `create_workflow_from_code`, `update_workflow`, `archive_workflow`, `publish_workflow`, `unpublish_workflow`, `test_workflow` and `restore_workflow_version` (ignoring case; a broad pattern
  counts): `<tool folder> is wrapped in n8n, so guard.yaml at the root
  must deny <tool>`.
- No contract marks `no_external_send`, `owner_only_send`,
  `append_only_events`, `no_schema_change` or `pinned_inputs`
  `(acceptable)`:
  `<invariant> cannot be marked (acceptable)`.
- No contract lists `no_send`: `no_send was renamed no_external_send`.
  No contract lists both `no_external_send` and `owner_only_send`
  (reported by `tool_check.py` for each tool).
- An agent that lists `ledger` in `capabilities` has
  `capabilities/ledger/contract.md`, `tools/airtable/identity.yaml`,
  `usage.md`, `guard.yaml` and `bootstrap.py`, and
  `skills/ledger-backfill/SKILL.md`, each byte-identical to the
  builder's `_ledger/` copy.
- That agent's `capabilities/ledger/tables.md` is valid: a positive
  integer `ledger_schema`, no table named `Events`, no field named like
  an `Events` field, field types from the allowed list, select fields
  with options, and a `key:` naming a declared field in every table.
- With `--require-bump <ref>`, a `tables.md` that differs from the one
  at the ref must raise `ledger_schema` and change nothing but by
  addition.
- A tool covering `append_only_events` or `no_schema_change` has the
  `guard.yaml` rules listed under Ledger.
- `hosts/` exists with `CLAUDE.md`, `GEMINI.md` and `AGENTS.md`, each at
  most 25 lines and pointing at `AGENT.md`.
- An agent with capabilities ships `skills/add-tool/SKILL.md`,
  byte-identical to the builder's `_template/skills/add-tool/SKILL.md`.
- A `capabilities/` folder not listed in `capabilities` fails.
- Each `activity_<name>` key in `agent.yaml` has a kebab-case name and
  is declared once; its value is `none` or names only listed
  capabilities, and does not mix `none` with capabilities.
- An agent with any `activity_*` key ships `skills/schedule/SKILL.md`.

### CI

An agent's repository runs the validator on every pull request and push
with the Agent Builder's action. `main` tracks the current standard
while it is in development:

```yaml
- uses: actions/checkout@v4
- uses: webspenser/agent-builder/validate@main
```
