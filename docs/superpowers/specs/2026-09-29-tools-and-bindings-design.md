# Tools and Bindings — Design (sub-project 4)

**Date:** 2026-09-29
**Status:** Approved in conversation (scope: CRM + email drafts), pending spec review
**Implements:** sub-project 4 ("Tools and credentials") of [Agent Distribution Architecture](./2026-09-27-agent-distribution-architecture-design.md)
**Repos:** `webspenser/agent-builder` (Standard 1.2, template, validator, wizard) and `webspenser/sales-partner` (adopts 1.2, releases 1.1.0)

## Purpose

Let a user bind an agent to the tools they already use — their CRM,
their mailbox — without editing agent logic, and make the agent's
safety rules hold by mechanism wherever a mechanism exists. Secrets
stay in the host (connectors, MCP config, environment); nothing secret
is ever written to the instance or the package.

## Prior art

The operator's own Attio setup (built 2026-09-24 in the retired
`live-agents/agent-library` clone, read but not modified) already works:

- `context/crm-attio-adapter.md` maps all eleven CRM operations to Attio
  tool calls over three lists (`sales_partner_pipeline`,
  `sales_partner_research`, `sales_partner_outreach`), each carrying a
  `lead` record-reference because list entries can't be filtered by
  parent.
- `scripts/attio_guard.py`, a `PreToolUse` hook wired by hand in
  `.claude/settings.local.json`, blocks agent writes of
  `status: approved|sent`, `status: draft` on an existing entry, and
  `do_not_contact: false`.
- `scripts/attio_bootstrap.py` creates the lists and attributes
  idempotently, using `ATTIO_API_KEY`.

This sub-project turns that into the standard's shape: shipped with the
package, generalized past one workspace, and wired automatically.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Capabilities `crm` (adapters: Attio, Airtable) and `email_drafts` (adapter: Gmail). Web research stays on host-native `WebSearch`/`WebFetch` with nothing to bind | Chosen 2026-09-29. HubSpot, Apify `scraper`, and `web_research` come later |
| Where enforcement is declared | In the adapter (`adapter.yaml`), not in `instance.yaml` | One source of truth; the instance only says which adapter is bound. Deviates from the umbrella's `enforcement:` map in `instance.yaml` |
| Binding format | Flat keys in `instance.yaml`: `bind_<capability>: <provider>` | The bash hooks and Python checker read top-level `key: value` lines only (same ruling as 1.1's catalog keys) |
| Guard wiring | A reference `hooks/guard.sh`, byte-identical in every 1.2 agent, registered as a `PreToolUse` hook in the package's `hooks.json` | Reaches every plugin user and every routine with no hand wiring; silent outside instances |
| Tool blocking | `block:` substrings in `adapter.yaml`, enforced by `guard.sh` itself in bash | "No send" and "no delete" hold without Python |
| Argument rules | Optional per-adapter `guard.py` (Python 3 stdlib), run by `guard.sh` | Rules like "never write `status: approved`" need JSON inspection |
| Fail mode | Closed: a bound adapter whose guard can't run blocks calls to its servers | A missing `python3` must not silently disable the approval invariant |
| Custom adapters | Allowed in the instance, but may not ship a `guard.py` (they may use `block:`) | The plugin's hook never executes code from an instance folder |
| Server matching | `server_match:` — a case-insensitive substring of the MCP server segment of the tool name | Covers `mcp__claude_ai_Attio__…`, `mcp__attio__…`, and plugin-provided forms alike; nothing to re-discover when a connector is renamed |
| Workspace facts | Written by setup's probe to the instance's `bindings/<capability>.md` | Object IDs and optional attributes differ per workspace; they never ship in the package |
| Versions | Standard 1.2 (additive); builder 1.2.0; sales-partner 1.1.0 | Minor bumps per the versioning rule |

## Agent Standard 1.2

### Package layout

```
capabilities/
  <capability>/
    contract.md
    adapters/
      <provider>/
        adapter.md
        adapter.yaml
        guard.py          # optional, executable
        bootstrap.py      # optional, executable
hooks/
  guard.sh                # reference copy, byte-identical
```

`agent.yaml` gains one optional key, a flat comma-separated list:

```yaml
capabilities: crm, email_drafts
```

### Contract (`contract.md`)

Neutral operations the agent thinks in. Skills and sub-agent contracts
call these operations, never a provider's tools by name. Two sections
are required:

- `## Operations` — a table whose first column is each operation name in
  backticks (`` `create_lead` ``), plus arguments, returns, and failure
  behavior.
- `## Invariants` — a list, one item per invariant, starting with its id
  in backticks: `` - `draft_only` — … ``. Ids are `snake_case`.

An invariant named `no_send` marks the capability as prospect-facing:
setup refuses to bind an adapter that enforces it only by `instruction`.

### Adapter

`adapter.md` maps every contract operation to a provider's tools (each
operation name appears in backticks), and has a `## Probe` section: the
read-only calls setup makes to confirm the binding and the facts it
writes to `bindings/<capability>.md`.

`adapter.yaml`, flat keys:

```yaml
capability: crm
provider: attio
server_match: attio
block: delete, merge            # optional; tool-name substrings
guard: guard.py                 # optional; package adapters only
enforce_draft_only: adapter
enforce_dnc_one_way: adapter
enforce_no_delete: adapter
```

One `enforce_<invariant>` line per contract invariant, no extras. The
level is one of:

- `adapter` — a mechanism in the package holds it: the provider has no
  tool that can violate it, `block:` removes the tools that could, or
  `guard` rejects the violating arguments.
- `host-deny` — setup writes host deny rules for the tools named in
  `deny:` (a further optional key, comma-separated tool-name suffixes).
- `instruction` — only the agent's instructions hold it.

### Bindings (instance)

`instance.yaml` gains one line per bound capability, and its `standard`
becomes `"1.2"`:

```yaml
agent: sales-partner
agent_version: 1.1.0
standard: "1.2"
mode: plugin
bind_crm: attio
bind_email_drafts: gmail
```

`bind_<capability>: custom` means the adapter lives in the instance at
`adapters/<capability>/adapter.md` and `adapter.yaml`. Facts the probe
discovers (object IDs, which optional attributes exist) are written to
`bindings/<capability>.md` in the instance, which the adapter reads.

A capability with no binding is not set up: the agent says so and
offers setup's tools step instead of calling anything.

### `hooks/guard.sh` — behavior

Registered in `hooks/hooks.json` alongside the 1.1 `SessionStart` hook:

```json
"PreToolUse": [
  { "matcher": "mcp__.*",
    "hooks": [ { "type": "command",
                 "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh\"" } ] }
]
```

1. Read the hook input from stdin. Take `tool_name`; split it as
   `mcp__<server>__<tool>`. Not an MCP name: exit 0.
2. Package root = `${CLAUDE_PLUGIN_ROOT}`, or the script's parent folder
   when unset (source mode). Read the agent's `name` from `agent.yaml`.
3. Walk up from `${CLAUDE_PROJECT_DIR:-$PWD}` to the nearest
   `instance.yaml` (same walk as the entry hook). None, or another
   agent's: exit 0. Unlike the entry hook, `mode: source` is **not**
   skipped.
4. For each `bind_<capability>: <provider>` line, load the adapter's
   `adapter.yaml` (package `capabilities/<capability>/adapters/<provider>/`,
   or instance `adapters/<capability>/` for `custom`). If the lowercased
   `<server>` contains the lowercased `server_match`:
   - if the lowercased `<tool>` contains any `block` substring: print
     `Blocked by <agent> guard: <tool> is blocked for <capability>
     (<provider> adapter)` to stderr, exit 2;
   - if the adapter is a package adapter with `guard:` set: run it with
     `python3`, the hook input on stdin. Exit 2 from it blocks, with its
     stderr passed through. `python3` missing, the guard file missing,
     or any other nonzero exit: block with a line naming the cause.
5. Otherwise exit 0. A bound provider whose adapter folder is missing
   prints one stderr line and matches no server; setup's probe catches
   this case first.

Values printed from `instance.yaml` are filtered the same way the entry
hook filters `agent_version`.

### `guard.py` — contract

Reads the hook input JSON from stdin. Exits 2 with one stderr line per
violated rule, or 0. Any internal error (bad JSON, an unexpected
argument shape on a write tool) is caught and turned into exit 2 with
the cause, so a bug fails closed.

### Setup — tools step

Added to `skills/setup/SKILL.md` after the interview, and offered on its
own when setup re-runs on an existing instance. For each capability in
`agent.yaml`:

1. List the shipped adapters. Ask which system the user uses. If none
   fits, offer a custom adapter: interview the user about their tool,
   write `adapters/<capability>/adapter.md` and `adapter.yaml` in the
   instance (no `guard`), and check its coverage the same way the
   validator does.
2. Find tools in the current session whose server matches
   `server_match`. None: explain how to connect that system in the host
   (connector, MCP server), say the user enters any secret there
   themselves, and leave the capability unbound.
3. Run the adapter's `## Probe`. On failure, explain and leave it
   unbound. Write discovered facts to `bindings/<capability>.md`.
4. If the contract has `no_send` and the adapter enforces it by
   `instruction`: refuse to bind, and say why.
5. Write `bind_<capability>: <provider>` to `instance.yaml`. Merge into
   the instance's `.claude/settings.json` `permissions.deny`: one exact
   `mcp__<server>__<tool>` rule for every session tool of a matched
   server whose name contains a `block` substring or ends with a `deny`
   suffix. Never duplicate an existing rule; never remove one.
6. In source mode, also merge the `PreToolUse` guard hook into
   `.claude/settings.json`, pointing at `hooks/guard.sh` in the project
   folder.
7. Report, per capability, whether it is **unattended-safe**: every
   invariant at `adapter`, or at `host-deny` with its rules written.
   Sub-project 5 schedules only unattended-safe activities.

### Validator (1.2 agents)

When `agent.yaml` declares `standard: "1.2"` (or later 1.x), in addition
to the 1.1 checks:

- `hooks/hooks.json` has a `PreToolUse` entry with matcher `mcp__.*`
  whose command is exactly `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"`
  (quoted, as in 1.1).
- `hooks/guard.sh` exists, is executable, and is byte-identical to the
  builder's `_template/hooks/guard.sh`.
- For each name in `capabilities`: `capabilities/<name>/contract.md`
  exists, has `## Operations` with at least one backticked operation
  and `## Invariants` with at least one backticked `snake_case` id; and
  at least one adapter folder exists.
- For each adapter folder: `adapter.md` and `adapter.yaml` exist;
  `capability` and `provider` equal the folder names; `server_match` is
  non-empty; there is exactly one `enforce_<id>` per contract invariant,
  each `adapter`, `host-deny`, or `instruction`; a `host-deny` level
  requires a non-empty `deny`; `guard`, when set, names an executable
  file in that folder; `adapter.md` mentions every operation in
  backticks and has a `## Probe` section.
- `no_send` at `instruction` is a FAIL (a package may not ship an
  adapter setup would refuse).
- A `capabilities/` folder not listed in `capabilities` is a FAIL.

A 1.0 or 1.1 agent is checked exactly as today.

## Builder changes (version 1.2.0)

- `STANDARD.md`: "Agent Standard 1.2"; new sections "Capabilities and
  adapters", "Bindings", "Guard hook", "Setup — tools step"; the
  Validation section lists the 1.2 checks.
- `_template/`: `standard: "1.2"`; `hooks/guard.sh` (reference);
  `hooks/hooks.json` with both hooks; the setup skill's tools step; no
  capabilities by default.
- `_template/_capability/` — skeleton `contract.md`, `adapter.md`,
  `adapter.yaml` the wizard copies when an agent declares a capability
  (not part of the template agent itself, and exempt from validation as
  an agent).
- Validator: the 1.2 checks, fixtures for each, and `guard.sh` behavior
  tests with a fake plugin root: non-MCP tool → allowed; no instance →
  allowed; unbound server → allowed; matched server + blocked tool →
  exit 2; matched server + guard exit 2 → exit 2 with its message;
  guard missing or `python3` absent from `PATH` → exit 2; custom adapter
  with `guard:` → guard not run; path with spaces works; source mode
  (no `CLAUDE_PLUGIN_ROOT`) works.
- `new-agent` wizard: asks which external systems the agent uses; for
  each, scaffolds a capability from `_template/_capability/` and lists it
  in `capabilities`.
- `docs/writing-an-agent.md`: "Tools" section — contract, adapter,
  enforcement levels, guard, and the rule that skills name operations,
  not tools.
- Builder manifests to `1.2.0`.

## sales-partner changes (version 1.1.0)

- `agent.yaml`: `version: 1.1.0`, `standard: "1.2"`,
  `capabilities: crm, email_drafts`.
- `capabilities/crm/contract.md` — moved from `context/crm-contract.md`,
  with a new `## Invariants` section: `draft_only` (agents create
  activities only as drafts; only the operator approves or sends),
  `dnc_one_way` (Do Not Contact is never cleared), `no_delete` (the
  agent never deletes CRM data).
- `capabilities/crm/adapters/airtable/` — `adapter.md` moved from
  `context/crm-airtable-adapter.md`; `adapter.yaml` with
  `server_match: airtable`, `block: delete`, `enforce_no_delete:
  adapter`, and `draft_only` / `dnc_one_way` at `instruction` (so an
  Airtable binding is not unattended-safe until it gets a guard).
- `capabilities/crm/adapters/attio/` — ported from the live adapter:
  - `adapter.md` with the Webspenser workspace name and hard-coded object
    IDs replaced by reads from `bindings/crm.md`; `lead_source: Outbound`
    applied only when the probe found that attribute and option;
    `## Probe`: `whoami`, `list-objects` (companies and people IDs),
    `list-list-attribute-definitions` on the three lists, and a check
    for the `sp_*` people attributes;
  - `guard.py` — the live rules, fail-closed, reading the argument shapes
    the Attio tools actually take;
  - `bootstrap.py` — the live script, reading `ATTIO_API_KEY` from the
    environment only (no `.env` file);
  - `adapter.yaml`: `server_match: attio`, `block: delete, merge`,
    `guard: guard.py`, all three invariants at `adapter`.
- `capabilities/email_drafts/contract.md` — operations `create_draft`
  (`to, subject, body` → `draft_id`) and `search_threads` (`query` →
  threads, read-only, for replies); invariant `no_send`.
- `capabilities/email_drafts/adapters/gmail/` — `server_match: gmail`,
  `block: send`, `enforce_no_send: adapter`; `## Probe` lists drafts.
- Every reference to `context/crm-contract.md`,
  `context/crm-airtable-adapter.md`, "the active adapter", and "Gmail —
  draft only" in `AGENT.md`, skills, and sub-agent contracts points at
  the capability, its contract, or the bound adapter instead.
- Setup: the tools step; setup's `<context-files>` no longer mentions
  CRM files.
- `hooks/guard.sh`, `hooks/hooks.json` with both hooks.
- `migrations/1.0.1-1.1.0.md`: no context file changes shape; run
  setup's tools step to bind `crm` and `email_drafts`, which also sets
  `standard: "1.2"` in `instance.yaml`. Source-mode users: the CRM files
  moved from `context/` to `capabilities/`.
- Content tests extended for the new paths, invariants, and the absence
  of the old ones.
- Catalog README status for sales-partner: "1.1 — install, run
  `/sales-partner:setup`, bind your CRM".

## Verification

- Builder `tests/run-all.sh` ALL GREEN, including the guard tests.
- sales-partner: its own tests for `guard.py` (each rule blocks; a
  legitimate create of a draft passes; malformed input blocks) and
  content tests; CI green on the release PR with the 1.2 validator.
- Acceptance, from GitHub through the catalog, against the operator's
  live Attio workspace, read-only:
  - in an empty folder with `instance.yaml` binding `crm: attio`, the
    Attio probe succeeds and writes `bindings/crm.md` with the
    workspace's object IDs;
  - a headless session told to set an Outreach entry's `status` to
    `approved` is blocked by the guard before the call reaches Attio
    (the entry id may be fictitious; the block happens first);
  - a call to any Attio tool from a folder with no instance is not
    blocked;
  - then uninstall.

## Review Focus

1. **Argument shapes** — the guard must read the argument names the
   Attio tools actually use (`entry_values`, `values`, and nested value
   forms). An unrecognized shape on a write tool blocks rather than
   passes.
2. **Guard unavailable** — no `python3`, an unreadable guard, or a
   crash blocks only calls to the bound adapter's servers; other MCP
   calls stay allowed and fast.
3. **Server name variants** — `mcp__claude_ai_Attio__…`,
   `mcp__attio__…`, and plugin-provided names all match `attio`.
4. **Settings merge** — re-running setup never duplicates deny rules,
   never removes the user's own, and keeps other keys in
   `.claude/settings.json`.
5. **Untrusted instance** — a folder whose `instance.yaml` points
   `bind_crm: custom` at an adapter with `guard:` must not execute it.

## Out of scope

- HubSpot and other CRM adapters; `scraper` (Apify) and `web_research`
  capabilities; an Airtable guard.
- Schedules and routines (sub-project 5), which consume the
  unattended-safe report.
- The digest's opt-in direct send (unchanged; an `email_send`
  capability is future work).
- Gemini and Codex hook equivalents.
