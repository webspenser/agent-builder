# Guard Policy — Design (Agent Standard 1.3)

**Date:** 2026-09-29
**Status:** Direction approved in conversation; pending spec review
**Follows:** [Tools and Bindings (Standard 1.2)](./2026-09-29-tools-and-bindings-design.md). Precedes sub-project 5 (scheduled runs).
**Repos:** `webspenser/agent-builder` (Standard 1.3, engine, validator, template) and `webspenser/sales-partner` (moves to guard policies, releases 1.2.0)

## Purpose

Make an agent's safety rules easy to author and provably enforced, so
that any tool — shipped or brought by a user — can qualify for
unattended runs.

In Standard 1.2 an adapter enforces its contract's invariants with a
`block:` list of tool-name substrings (in `adapter.yaml`) and, for
argument-level rules, an optional Python `guard.py`. That works, but:

- rules that need argument checks require writing code;
- custom adapters may not ship code, so a bring-your-own tool can never
  be unattended-safe;
- the validator cannot tell which mechanism covers which invariant, so
  `enforce_<id>: adapter` is a claim, not a checked fact;
- a deny list lets a tool the vendor adds later through by default.

Standard 1.3 adds a **guard policy**: a declarative `guard.yaml` beside
the adapter, enforced by a reference engine that ships in every agent.

## Vocabulary

| Term | Meaning |
|---|---|
| Capability | A kind of outside system the agent uses (`crm`, `email_drafts`) |
| Contract | The capability's operations and invariants — the agent's "action layer" |
| Adapter | Maps each contract operation onto one tool (MCP server, API, CLI, plugin) |
| Guard policy | `guard.yaml`: which tools may be called and which argument values may be written, and which invariants that covers |
| Adapter pack | An adapter plus its guard policy — what someone brings to support a new tool |
| Binding | The instance's choice of adapter per capability (`bind_crm: attio`) |
| Unattended-safe | Every contract invariant is enforced by mechanism (guard policy or host deny rules), none by instruction alone |

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| File | `guard.yaml` beside `adapter.yaml`, in package adapters and in instance `custom-adapters/<capability>/` | One file an author writes and a reviewer reads |
| Format | A strict YAML subset (below); anything outside it is a validation error and, at runtime, a block | Readable for authors; parseable by the Python standard library with no dependencies |
| Engine | Reference `hooks/guard_policy.py` (Python 3 stdlib), byte-identical in every 1.3 agent, run by `guard.sh` | Field rules need JSON inspection; one audited engine instead of per-adapter code |
| Default | When `allow` is present, a tool of the matched server that matches no `allow` pattern is blocked | New vendor tools are blocked until someone allows them |
| Precedence | `deny` beats `allow`; all field rules must pass; an adapter's `guard.py` (if any) and `block` (1.2) still run too | Every layer can only narrow |
| Custom adapters | May ship `guard.yaml` (it is data); still may not ship `guard.py` | Lets bring-your-own tools become unattended-safe without executing instance code |
| Coverage | `covers:` in `guard.yaml` lists the invariants the policy enforces; in a 1.3 agent every `enforce_<id>: adapter` invariant must appear there | Makes "adapter-enforced" a checked fact |
| Field identity | A rule names a field; it matches that key in the call, case-insensitive, and also the field ID the probe recorded in `bindings/<capability>.md` as `field_<name>: <id>` | Airtable writes key fields by ID (`fld…`), and IDs differ per base |
| Versioned references | The validator keeps each standard version's reference hooks; an agent's hooks must equal the reference for its own version or a later one | Moving to 1.3 must not break 1.2 agents |
| Python requirement | A bound adapter with a guard policy needs `python3`; without it, calls to that adapter's servers are blocked | Fail closed, as in 1.2 |
| Versions | Standard 1.3 (additive); builder 1.3.0; sales-partner 1.2.0 | Minor bumps |

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

- The top level is a map of `key: value` lines at column 0. Comments
  (`#` to end of line, outside quotes) and blank lines are ignored.
- A value is either a scalar (plain or single/double quoted) or a flow
  list `[a, b, "c*"]`. A flow list may continue over following lines
  that are indented, until its closing `]`.
- The one exception is `rules:`, whose value is a block list: each item
  starts with `  - ` and holds `field:` plus any of `create:`, `update:`,
  `any:` — each a flow list — on the item's own indented lines.
- Tabs, anchors, multi-line strings, nested maps, and any unknown key
  are errors.

### Keys

| Key | Required | Meaning |
|---|---|---|
| `covers` | yes | Invariant ids this policy enforces; each must be in the contract |
| `allow` | no | Tool-name glob patterns that may be called; if present, everything else on the matched server is blocked |
| `deny` | no | Tool-name glob patterns that are always blocked |
| `create_tools` | if `rules` | Tools whose writes create new data (rules' `create` lists apply) |
| `update_tools` | if `rules` | Tools whose writes change existing data (rules' `update` lists apply) |
| `values_at` | if `rules` | Where attribute maps sit in the tool input: a top-level key (`values`), or a list path (`records[].fields`) |
| `unwrap` | no | Keys whose value stands for a wrapped value (`{"option": "draft"}`); without it, any object value is an error on a write |
| `unknown_writes` | no | `update` (default) or `block`: a tool in neither list whose input has an attribute map at a `values_at` path |
| `refuse_keys` | no | Key shapes refused in attribute maps: `uuid` (Attio attribute IDs) |
| `rules` | no | Field rules (below) |

### Semantics

1. **Tool name.** The engine receives the full tool name
   `mcp__<rest>`. Candidate names are every suffix of `<rest>` that
   follows a `__` (so `mcp__x__DemoCRM__list-records` gives
   `DemoCRM__list-records` and `list-records`). A `deny` pattern
   matching any candidate blocks. With `allow` present, at least one
   candidate must match an `allow` pattern. Patterns are shell-style
   globs (`*`, `?`), case-insensitive.
2. **Writes.** A tool in `create_tools` or `update_tools`, or (per
   `unknown_writes`) any other tool whose input has an attribute map at
   a `values_at` path, is a write. Each attribute map found is checked.
3. **Values.** A value is flattened: a list to its items; an object to
   the values under its `unwrap` keys (an object with none of them is an
   error); a boolean to `true`/`false`. Each leaf is compared as a
   trimmed, lowercase string.
4. **Rules.** For each rule whose field is present in an attribute map
   (key match per Field identity), the flattened values must equal
   exactly one entry of the applicable list — `create` for a create
   tool, `update` for an update or unknown write — and `any` applies to
   both. A field with no applicable list for this kind of write is not
   checked.
5. **Refused keys.** With `refuse_keys: [uuid]`, any attribute-map key
   that looks like a UUID blocks the call (it could hide a ruled field).
6. **Errors.** An unreadable or invalid `guard.yaml`, an unreadable
   bindings file a rule depends on, or any engine exception blocks the
   call with the cause on stderr.
7. **Output.** Exit 2 with one stderr line per violation, prefixed
   `Blocked by <agent> guard policy (<capability>/<provider>):`; exit 0
   otherwise.

### Field identity and bindings

`bindings/<capability>.md` (written by setup's probe) may carry flat
`field_<name>: <id>` lines — for Airtable,
`field_status: fldAbc…` and `field_do_not_contact: fldXyz…`. A rule for
`status` then matches the key `status` (any case) and the key
`fldAbc…`. A rule may require that ID:

```yaml
  - field: status
    binding_id: required
    create: [draft]
    update: [voided]
```

With `binding_id: required`, a write to the policy's servers while the
bindings file lacks `field_status` is blocked ("probe has not recorded
the field ID") — the guard cannot recognize the field otherwise.

## Engine and hook

- `hooks/guard_policy.py` — reference engine. Invoked as
  `python3 guard_policy.py <guard.yaml> <bindings file or ->` with the
  hook input on stdin. It implements the grammar and semantics above and
  nothing else. Never tracebacks: every exception becomes exit 2.
- `hooks/guard.sh` — gains one step, after its existing `block` check
  for a matched adapter: if the adapter folder has `guard.yaml`, run the
  engine (package root's `hooks/guard_policy.py`) with it and the
  instance's `bindings/<capability>.md` (or `-` if absent). Exit 2
  blocks; `python3` or the engine missing blocks; any other nonzero
  exit blocks. Then the existing `guard.py` step runs for package
  adapters.
- Both scripts stay byte-identical across agents and are registered by
  the 1.2 `PreToolUse` hook (unchanged `hooks.json`).

## Validator (1.3 agents)

When `agent.yaml` declares `standard: "1.3"` or later, in addition to
the 1.2 checks:

- `hooks/guard_policy.py` exists, is executable, and equals the
  reference; `hooks/guard.sh` equals the 1.3 reference.
- Each adapter's `guard.yaml`, if present, parses under the subset;
  unknown keys, bad globs, `covers` ids not in the contract, and rules
  without an applicable `create`/`update`/`any` list are FAILs;
  `create_tools`, `update_tools`, `values_at` are required when `rules`
  is present; `unknown_writes` is `update` or `block`; `refuse_keys`
  items are known presets.
- **Coverage:** every invariant with `enforce_<id>: adapter` must be
  listed in that adapter's `guard.yaml` `covers`; an invariant listed in
  `covers` must be at `adapter` level.
- The validator's parser and the engine's parser are the same code: the
  validator imports the reference `guard_policy.py` from the builder.

Versioned references: the builder keeps `bin/lib/references/1.1/`,
`1.2/`, `1.3/` hook copies; `_template/hooks/` is always the latest. A
1.x agent's `session-start.sh`, `guard.sh`, and (1.3+) `guard_policy.py`
must equal the reference of its own standard version or any later one.

## Setup and unattended-safe (1.3)

- The tools step's probe may record `field_<name>` IDs; the adapter's
  `## Probe` says which.
- The unattended-safe report becomes mechanical: every invariant at
  `adapter` (and therefore in `covers`), or at `host-deny` with its rules
  written. Setup prints, per capability, the invariants and what covers
  each.
- Custom adapters: the tools step offers to write a `guard.yaml` with
  the user (allow list first, then any field rules), and validates it
  with the engine's parser before binding.

## Builder changes (1.3.0)

- `STANDARD.md` 1.3: "Guard policy" section (format, semantics, field
  identity, coverage), updated "Guard hook", "Setup — tools step",
  "Validation", versioned references.
- `_template/hooks/guard_policy.py`, updated `guard.sh`;
  `bin/lib/references/{1.1,1.2,1.3}/`.
- `_capability-template/adapters/example-provider/guard.yaml` —
  commented example (allow list, one rule) with `covers`.
- Validator: 1.3 checks; tests with fixtures for each FAIL and for
  versioned references (a 1.2 agent with the 1.2 `guard.sh` still
  passes).
- Engine tests: grammar (accepts the subset, rejects each excluded
  construct), name matching (deny beats allow, default-deny with
  `allow`, `__` candidates), writes (create/update/unknown), values
  (unwrap, lists, booleans, unknown object shape), rules, refuse_keys,
  field identity with and without `binding_id: required`, and
  fail-closed on every error path.
- Wizard: adapter packs — write `guard.yaml` with `covers`.
- Builder manifests to `1.3.0`.

## sales-partner changes (1.2.0)

- `standard: "1.3"`; `hooks/guard_policy.py` and the 1.3 `guard.sh`.
- **Attio:** `guard.yaml` as above replaces `guard.py` (which is
  removed); `adapter.yaml` drops `guard:` and `block:` (the policy's
  `deny` covers them). All existing Attio guard tests move to the
  engine and still pass.
- **Gmail:** `guard.yaml` with `covers: [no_send]`, an `allow` list of
  the draft and read tools (`create_draft`, `list_drafts`, `get_draft`,
  `search_threads`, `get_thread`, `get_message`, `list_labels`), and
  `deny: ["*send*", "*reply*", "*forward*"]`; `block:` removed from
  `adapter.yaml`.
- **Airtable:** `guard.yaml` covering `draft_only`, `dnc_one_way`, and
  `no_delete`:
  - `allow` the read tools and `create_records_for_table`,
    `update_records_for_table`; `deny: ["*delete*"]` (schema and
    automation tools are blocked by default-deny);
  - `create_tools: [create_records_for_table]`,
    `update_tools: [update_records_for_table]`,
    `values_at: ["records[].fields"]`;
  - rules: `Status` (`binding_id: required`) create `[draft]`, update
    `[voided]`; `Do Not Contact` (`binding_id: required`) update
    `[true]`;
  - its `## Probe` records `field_status` and `field_do_not_contact`
    from `list_tables_for_base`;
  - `adapter.yaml`: all three invariants at `adapter`. Airtable becomes
    unattended-safe.
- Migration note `1.1.0-1.2.0.md`: re-run setup's tools step so the
  probe records Airtable field IDs (Attio and Gmail need nothing).
- Content tests for the three policies; engine-level tests with
  real-shaped tool inputs for Attio, Airtable, and Gmail.

## Verification

- Builder and sales-partner test suites ALL GREEN; the validator passes
  sales-partner 1.2.0 and still passes a 1.2 fixture agent.
- Crafted end-to-end runs through `guard.sh` with the real package:
  - Attio: approve write blocked, void allowed, delete/merge blocked, an
    Attio tool not in `allow` blocked;
  - Gmail: send/reply/forward blocked, a new unlisted tool blocked,
    `create_draft` allowed;
  - Airtable: `Status: approved` by field ID blocked, `draft` on create
    allowed, clearing `Do Not Contact` blocked, a write with no recorded
    field IDs blocked, `delete_records_for_table` blocked, a schema tool
    blocked.
- Live acceptance, read-only, as in 1.2: install from the catalog; the
  Attio probe still passes; an instructed approve is blocked by the
  guard policy before reaching Attio.

## Review Focus

1. **Grammar edge cases** — the parser must reject, not guess, anything
   outside the subset; a policy that fails to parse blocks at runtime.
2. **Field keyed by ID** — an Airtable write keyed by `fld…` for Status
   must be recognized; a missing ID blocks when required.
3. **Default-deny surprises** — an `allow` list that forgets a read tool
   the adapter uses would block normal work; each shipped policy must be
   checked against every tool its `adapter.md` names.
4. **Versioned references** — a 1.2 agent must keep validating after the
   `v1` tag moves to 1.3.
5. **Layer interplay** — `block` (1.2), `guard.yaml`, and `guard.py` on
   the same adapter each only narrow; none can re-allow what another
   blocked.

## Out of scope

- Scheduling and routines (sub-project 5).
- Compliance rules (CAN-SPAM, GDPR, TCPA) — a later track; guard
  policies may later express some of them.
- HubSpot and other new adapters.
- Rate limits and spend caps in the guard.
