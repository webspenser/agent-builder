# Agent Standard 2.0 — Guard Policies and a Clean Standard — Design

**Date:** 2026-09-29
**Status:** Direction approved in conversation; revised the same day to drop backward compatibility; pending spec review
**Follows:** [Tools and Bindings (Standard 1.2)](./2026-09-29-tools-and-bindings-design.md). Precedes sub-project 5 (scheduled runs).
**Repos:** `webspenser/agent-builder` (Standard 2.0, engine, validator, template; builder 2.0.0) and `webspenser/sales-partner` (adopts 2.0; releases 2.0.0)

## Purpose

1. Make an agent's safety rules easy to write and provably enforced, so
   any tool — shipped or brought by a user — can qualify for unattended
   runs: a declarative **guard policy** (`guard.yaml`) beside each
   adapter, enforced by one reference engine.
2. Collapse the standard into **one current version** with no
   compatibility layer. We are in a development phase with no outside
   users: the builder defines the standard, and sales-partner is changed
   to match it in the same release. Earlier mechanisms that the guard
   policy replaces are removed, not kept alongside.

## Development-phase policy

- The standard has one current version, **2.0**. The validator checks
  that version only; an agent declaring anything else fails with a
  message to update it.
- Breaking changes are allowed at any time. Every Webspenser agent is
  updated in the same release as the builder.
- No versioned reference copies, no per-version check paths, no
  migration notes for old agent versions. The migration mechanism
  itself (the entry hook's notice and `migrations/`) stays for when
  customers exist.
- Compatibility rules return, by a later spec, when agents have outside
  users.

## Removed

| Removed | Replaced by |
|---|---|
| Validator path for agents without `agent.yaml` ("pre-1.0", a WARN) | `agent.yaml` is required |
| Per-version checks (1.0 / 1.1 / 1.2 branches, "this validator understands 1.x") | One set of checks; `standard: "2.0"` required |
| `block:` in `adapter.yaml` (tool-name substrings) | `deny` in `guard.yaml` |
| `guard:` / per-adapter `guard.py` (code guards) | `rules` in `guard.yaml` |
| `enforce_<invariant>:` lines and the `adapter` / `host-deny` / `instruction` levels | `covers` in `guard.yaml`: listed = enforced by mechanism; not listed = instruction only |
| `deny:` tool suffixes and setup's `permissions.deny` writes | The guard enforces denials itself |
| `standard:` in `instance.yaml` | Nothing — `agent_version` is what migrations use |
| Section version tags in `STANDARD.md` ("(1.1)", "(1.2)") | One document for the current standard |
| sales-partner's old migration notes | Deleted; `migrations/` keeps a `.gitkeep` |

## Vocabulary

| Term | Meaning |
|---|---|
| Capability | A kind of outside system the agent uses (`crm`, `email_drafts`) |
| Contract | The capability's operations and invariants — the agent's "action layer" |
| Adapter | Maps each contract operation onto one tool (MCP server, API, CLI, plugin) |
| Guard policy | `guard.yaml`: which tools may be called, which values may be written, and which invariants that covers |
| Adapter pack | An adapter plus its guard policy — what someone brings to support a new tool |
| Binding | The instance's choice of adapter per capability (`bind_crm: attio`) |
| Unattended-safe | Every contract invariant is listed in the bound adapter's `guard.yaml` `covers` |

## Adapter files

```
capabilities/<capability>/adapters/<provider>/
  adapter.md      # maps every operation; ## Probe section
  adapter.yaml    # capability, provider, server_match — nothing else
  guard.yaml      # optional guard policy
```

`adapter.yaml`:

```yaml
capability: crm
provider: attio
server_match: attio
```

Any other key is a validation error. An adapter without `guard.yaml`
works, but every invariant is instruction-only, so it is not
unattended-safe, and it cannot be bound to a capability whose contract
has `no_send`.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| File | `guard.yaml` beside `adapter.yaml`, in package adapters and in instance `custom-adapters/<capability>/` | One file an author writes and a reviewer reads |
| Format | A strict YAML subset (below); anything outside it is a validation error and, at runtime, a block | Readable; parseable by the Python standard library |
| Engine | Reference `hooks/guard_policy.py` (Python 3 stdlib), byte-identical in every agent, run by `guard.sh` | One audited engine instead of per-adapter code |
| Default | With `allow` present, a tool of the matched server that matches no `allow` pattern is blocked | New vendor tools are blocked until someone allows them |
| Precedence | `deny` beats `allow`; every field rule must pass | Rules only narrow |
| Custom adapters | May ship `guard.yaml` (it is data) | Bring-your-own tools can become unattended-safe without executing instance code |
| Coverage | `covers` lists the invariants the policy enforces; each must be a contract invariant | "Enforced by mechanism" is a checked fact |
| `no_send` | A contract invariant named `no_send` must be in every adapter's `covers` (validator) and the bound adapter's (setup) | Prospect-facing sending stays impossible |
| Field identity | A rule names a field; it matches that key in the call (case- and separator-insensitive) and the ID the probe recorded in `bindings/<capability>.md` as `field_<name>: <id>` | Airtable writes key fields by ID (`fld…`) |
| Python requirement | A bound adapter with a guard policy needs `python3`; without it, calls to its servers are blocked | Fail closed |
| Versions | Standard 2.0; builder 2.0.0; sales-partner 2.0.0 | Breaking consolidation |

## The guard policy format

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

### Grammar (the subset)

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
| `values_at` | if `rules` or `refuse_keys` | Where attribute maps sit in the tool input: a key (`values`) or a list path (`records[].fields`) |
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
   `true`/`false`. Leaves compare as trimmed lowercase strings.
4. **Rules.** A rule whose field appears in a map requires the
   flattened value to equal exactly one entry of the applicable list —
   `create` for creates, `update` for updates and unknown writes; `any`
   applies when the kind's own list is absent. No applicable list: not
   checked.
5. **Refused keys.** `refuse_keys: [uuid]` blocks any UUID-shaped key
   in a map (it could hide a ruled field).
6. **Field identity.** `field_<name>` in `bindings/<capability>.md` (a
   `key: value` line) adds that ID as a key matching the rule. With
   `binding_id: required`, a write while the ID is missing is blocked.
7. **Errors.** An invalid policy, unreadable bindings, bad JSON, or any
   engine exception blocks, with the cause on stderr.
8. **Output.** Exit 2 with one line per problem, prefixed
   `Blocked by <label>: `; exit 0 otherwise. `guard.sh` passes the label
   `<agent> guard policy (<capability>/<provider>)`.

## Engine and hook

- `hooks/guard_policy.py` — the engine:
  `python3 guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]` with
  the hook input on stdin; `--check <guard.yaml>` parses only. Never
  tracebacks.
- `hooks/guard.sh` — for each `bind_<capability>: <provider>` line in
  the instance (package adapter, or `custom` → instance
  `custom-adapters/<capability>/`), when the tool name after `mcp__`
  contains the adapter's `server_match` (case-insensitive): if the
  adapter has `guard.yaml`, run the engine with it and the instance's
  `bindings/<capability>.md` (or `-`) and the `server_match`. A
  `guard.yaml` that exists but is unreadable (a directory, a dangling
  symlink) still reaches the engine, which blocks. Exit 2 blocks; engine or
  `python3` missing blocks; other nonzero blocks. It keeps today's
  instance walk, single-tool-name check, unreadable-binding block, and
  silence outside instances. It no longer reads `block` or runs
  `guard.py`.
- `hooks.json` is unchanged.

## Validator

One set of checks (today's 1.0–1.2 checks, minus the removed items):

- `agent.yaml` is required; `standard` must be `"2.0"`.
- `hooks/session-start.sh`, `hooks/guard.sh`, and
  `hooks/guard_policy.py` exist, are executable, and equal the builder's
  `_template/hooks/` copies.
- `adapter.yaml` has exactly `capability`, `provider`, `server_match`
  (plain values; no lists).
- `guard.yaml`, when present, parses with the engine's parser (the
  validator imports the template's `guard_policy.py`); every `covers` id
  is a contract invariant.
- If the contract has `no_send`, every adapter has a `guard.yaml` whose
  `covers` includes it.

## Setup — tools step

- Choose an adapter (or write a custom one — `adapter.md`,
  `adapter.yaml`, and optionally `guard.yaml`, checked with
  `guard_policy.py --check`).
- Find the matching server; run the probe; write `bindings/<capability>.md`
  (including any `field_<name>` IDs the probe records).
- Refuse to bind when the contract has `no_send` and the adapter's
  `covers` lacks it.
- Write `bind_<capability>: <provider>` to `instance.yaml`.
- Source mode: add the `PreToolUse` guard hook to `.claude/settings.json`.
- Report unattended-safe per capability: each invariant, covered or
  instruction-only.
- No `permissions.deny` writes; `instance.yaml` has no `standard` line.

## Builder changes (2.0.0)

- `STANDARD.md` rewritten as "Agent Standard 2.0": development-phase
  policy; one document with no version-tagged sections; adapter files,
  guard policy (format, semantics, field identity), guard hook,
  bindings, setup, validation.
- `_template/`: `standard: "2.0"`, `hooks/guard_policy.py`, the new
  `guard.sh`, setup text per above.
- `_capability-template/`: `adapter.yaml` with the three keys; a
  commented `guard.yaml`.
- Validator and tests consolidated to one fixture helper for a current
  agent; tests for removed behavior deleted.
- Wizard and docs: adapter packs = `adapter.md` + `adapter.yaml` +
  `guard.yaml`.

## sales-partner changes (2.0.0)

- `standard: "2.0"`; new `hooks/guard.sh` and `hooks/guard_policy.py`.
- **Attio:** `guard.yaml` as above; `guard.py` removed; `adapter.yaml`
  reduced to three keys.
- **Gmail:** `guard.yaml`: `covers: [no_send]`, `allow` the draft and
  read tools (`create_draft`, `list_drafts`, `get_draft`,
  `search_threads`, `get_thread`, `get_message`, `list_labels`),
  `deny: ["*send*", "*reply*", "*forward*"]`.
- **Airtable:** `guard.yaml` covering `draft_only`, `dnc_one_way`,
  `no_delete`: read tools plus `create_records_for_table` and
  `update_records_for_table` allowed, `deny: ["*delete*"]`,
  `values_at: ["records[].fields"]`, `unknown_writes: block`, rules for
  `Status` and `Do Not Contact` with `binding_id: required`; its probe
  records `field_status` and `field_do_not_contact`. Airtable becomes
  unattended-safe.
- Everything that mentions enforcement levels, `block`, `guard.py`, or
  deny rules is rewritten to the guard-policy terms.
- Old migration notes deleted.
- Tests: policy tests through the engine for all three adapters; content
  tests updated.

## Verification

- Builder and sales-partner suites ALL GREEN; the validator passes
  sales-partner 2.0.0 and `_template`.
- Crafted end-to-end runs through `guard.sh` with the real package:
  Attio approve blocked / void allowed / delete and merge blocked /
  unlisted tool blocked; Gmail send/reply/forward and unlisted tools
  blocked, `create_draft` allowed; Airtable `Status: approved` by field
  ID blocked, `draft` on create allowed, clearing `Do Not Contact`
  blocked, writes without recorded field IDs blocked, deletes and
  schema tools blocked.
- Live acceptance, read-only: install from the catalog; an instructed
  Attio approve is blocked by the guard policy; a plain-folder read
  succeeds.

## Review Focus

1. **Grammar edge cases** — the parser rejects, never guesses.
2. **Field keyed by ID** — Airtable `fld…` keys recognized; a missing
   required ID blocks.
3. **Default-deny surprises** — every tool an `adapter.md` names is in
   its `allow`.
4. **Nothing left behind** — no remaining reference to `block`,
   `guard.py`, `enforce_`, `host-deny`, or old standard versions in
   either repo outside `docs/` history.
5. **No path back to allow** — without the engine or `python3`, calls
   to a bound adapter with a policy are blocked.

## Out of scope

- Scheduling and routines (sub-project 5).
- Compliance rules (CAN-SPAM, GDPR, TCPA).
- HubSpot and other new adapters.
- Rate limits and spend caps in the guard.
