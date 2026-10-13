# Agent Standard 7.1: activity ledger — design

Status: approved on 2026-10-13. The design was approved in conversation
on 2026-10-12 (data model, failure policy, contract and guard). This spec
writes it down, with the changes since then marked **Changed** and the
three questions raised in review resolved at the end. Second of a series: owner notifications
(Standard 7.0, done), then this ledger, then the Apify scraping
capability, then goal-driven prospecting in sales-partner.

## Goal

An agent keeps a record of what it did, in a store the client owns and
can read: which activity ran, when, what it worked on, what came of it,
and what it cost. The record is append-only, and the guard enforces
that: the agent can add history but never rewrite or delete it. That is
what makes it an audit trail and not just a spreadsheet. The same store
holds state an agent reads back between runs, so a later run knows what
earlier runs already covered.

1. A standard `ledger` capability that any agent can include: one
   generic `Events` table, the same for every agent, plus tables the
   agent declares for its own state.
2. The first tool is Airtable: one base per agent per instance, in the
   client's own Airtable account.
3. Writes are retried; what still fails reaches the owner through
   `owner_notify` and can be backfilled later without duplicates.
4. Sales-partner records every run.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | One Airtable base per agent per instance, owned by the client | Agents can be at different versions with different schemas. A business with several agents has several bases; a cross-agent view is the owner's own build. |
| 2 | `Events` is one standard table, identical for every agent; each agent may declare its own tables in `capabilities/ledger/tables.md` | Every agent gets the audit trail for free and only its own state tables differ. Generic `Items In`/`Items Out` columns let charts and reports work for any agent. |
| 3 | Events are coarse: one per step, not one per item | About 20–40 rows per run instead of hundreds. Keeps Airtable's per-base record limit in reach (see Volume). |
| 4 | Schema changes are additive only and made only by `bootstrap.py`, never over MCP | An old row never loses a column. No scheduled run, however confused, can change its own audit table. |
| 5 | Append-only is enforced by existing guard features: `bound_keys_only` plus a `forbid: update` rule per `Events` field | No engine change. Airtable keys fields by ID, and the probe records each ID. |
| 6 | The guard refuses `typecast` and `interfaceContext` | **Changed.** With `typecast: true` Airtable creates missing select options on write, which is a schema change over MCP. Refusing it also means the agent can't invent new `Event` or `Outcome` values. |
| 7 | Failure: retry, queue in the run, then `owner_notify`; scheduled runs continue on a failed `Events` write and stop the activity on a failed state read | A run nobody can see breaks the visibility promise, but losing visibility is recoverable and spending blind is not. |
| 8 | `Run ID` + `Seq` is the idempotency key; `append_events` skips rows already present | Backfill and normal writes share one path; backfilling twice never duplicates a row. |
| 9 | `Recorded At` is an Airtable created-time field the agent can't write | **Changed (addition).** `At` is when the event happened, as the agent says; `Recorded At` is when Airtable received it. A backfilled or back-dated row is visible mechanically, not only through the `Backfilled` checkbox. |
| 10 | `Activity` and `Subject` are text, not single select | **Changed.** With `typecast` refused, a single-select `Activity` would need a schema upgrade whenever an agent adds an activity. `Trigger`, `Event` and `Outcome` stay single select: their values are fixed by this standard. |
| 11 | Writing a start and a finish event for every run is a contract rule, not an invariant | **Changed.** It was `run_bracketed (acceptable)`. No guard can check it, and an acceptable invariant needs every instance to accept it in `accept_instruction_only`, which sales-partner's setup no longer offers. |
| 12 | The `scope: baseId` guard key is dropped | **Changed.** It was needed only while Airtable could also be the CRM. That tool is gone (Standard 7.0). |
| 13 | Agent Standard 7.1: builder 7.1.0, sales-partner 7.1.0 | Additive: a new standard capability, reserved invariant ids, new checks. Development-phase rule: version numbers carry no compatibility meaning. |

Unchanged: the guard grammar and engine, `guard.sh`, `owner_notify`, the
CRM capability.

## Part A — builder 7.1.0

### A1. Where the ledger ships

The builder ships the standard capability at `_ledger/`:

```
_ledger/
  contract.md
  tables.md                 # template: ledger_schema: 1, no agent tables
  tools/airtable/
    identity.yaml
    usage.md
    guard.yaml
    bootstrap.py
  skills/ledger-backfill/SKILL.md
```

An agent that uses the ledger copies `_ledger/` into
`capabilities/ledger/` and `_ledger/skills/ledger-backfill/` into
`skills/ledger-backfill/`. Every copied file stays byte-identical to the
builder's except `capabilities/ledger/tables.md`, which the agent owns.
The validator checks this, the same way it checks `hooks/`, so the
`Events` table and its guard are the same in every agent.

### A2. The `Events` table

| Field | Airtable type | Written by | Example |
|---|---|---|---|
| `Run ID` | single line text (primary field) | agent | `prospect-20261019T1400Z` |
| `Key` | formula `{Run ID} & "#" & {Seq}` | Airtable | `prospect-20261019T1400Z#3` |
| `At` | date and time, UTC | agent | 2026-10-19 14:02 |
| `Recorded At` | created time | Airtable | 2026-10-19 14:02 |
| `Seq` | number (integer) | agent | 3 |
| `Activity` | single line text | agent | `prospect` |
| `Trigger` | single select: `scheduled`, `interactive` | agent | `scheduled` |
| `Event` | single select: `run_started`, `step`, `stop_condition`, `notify_sent`, `error`, `run_finished` | agent | `step` |
| `Subject` | single line text | agent | `Oakland\|hvac`, a CRM lead id |
| `Outcome` | single select: `ok`, `partial`, `failed`, `skipped`, `dry_run` | agent | `ok` |
| `Items In` | number | agent | 60 |
| `Items Out` | number | agent | 4 |
| `Cost USD` | currency | agent | 0.42 |
| `Duration s` | number | agent | 95 |
| `Detail` | long text | agent | `Oakland\|hvac: 60 raw, 41 kept, 4 passed` |
| `Agent Version` | single line text | agent | `7.1.0` |
| `Backfilled` | checkbox | agent | false |

Airtable cannot create formula fields as part of table creation (live check, 2026-10-13), so `bootstrap.py` creates each table with its plain fields and then adds computed fields.

`Run ID` is `<activity>-<UTC start, yyyymmddThhmmZ>`. `Seq` starts at 1
for `run_started` and increases by one per event in the run.

### A3. Agent tables: `tables.md`

The agent declares its own tables, and the schema version, in
`capabilities/ledger/tables.md`:

````markdown
# Ledger tables

ledger_schema: 2

## Cells

key: Cell

| Field | Type | Options |
|---|---|---|
| Cell | singleLineText | |
| Last Run | dateTime | |
| Runs | number | |
| Last Yield | number | |
````

- `ledger_schema` is an integer. It goes up by one whenever the agent
  adds a table or a field. A package that changes `tables.md` without
  raising it fails validation (checked against the base ref with
  `--require-bump`).
- `Type` is an Airtable field type name. `Options` lists select
  choices, comma-separated.
- `key` names the field `upsert_rows` matches on.
- The validator refuses an agent-table field whose name normalizes to
  an `Events` field name. The guard matches rules by field name, so a
  shared name would make an agent-table field append-only too, or hide
  one.
- Additive only: the validator, given the base ref, refuses a
  `tables.md` that removes or renames a table or field, or changes a
  type.

### A4. Contract `_ledger/contract.md`

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `ledger_status` | none | the bound `ledger_schema` and the package's | A mismatch, or no `bindings/ledger.md`: in a scheduled run the activity stops and calls `notify_owner(kind: error)`; in an interactive run it reports and offers to run setup. Called once at run start. |
| `append_events` | `events[]`, each with `run_id`, `seq`, `at`, `activity`, `trigger`, `event`, plus any optional fields | the number of rows written | Rejects an event missing `run_id`, `seq`, `event` or `at`. Skips any `run_id` + `seq` already present. Writes in `seq` order, up to 10 per call. |
| `find_events` | `run_id`, or `since` plus optional `activity` and `event` | events, oldest first | An empty list is a valid result. |
| `get_rows` | `table`, `filter` | rows of an agent table | Rejects a table that `tables.md` does not declare. |
| `upsert_rows` | `table`, `rows[]` | the rows written | Rejects an undeclared table or field, and any write to `Events`. Matches on the table's `key`. |

**Run bracketing (contract rule).** Every run writes `run_started` first
and `run_finished` last, or queues them under the failure policy (A7).
This is an instruction; no guard can check it.

**Invariants:**

- `append_only_events` — an `Events` row, once written, is never
  changed. Covered by the guard.
- `no_delete` — the agent never deletes a row in any ledger table.
  Covered.
- `no_schema_change` — the agent never creates, changes or deletes a
  table, field or select option. Covered: every schema tool is outside
  `allow`, and `typecast` is refused.

`append_only_events` and `no_schema_change` become reserved invariant
ids in STANDARD.md, like `no_external_send`: they can't be marked
`(acceptable)`.

### A5. Airtable tool

`identity.yaml`:

```yaml
capability: ledger
provider: airtable
server_match: airtable
```

`guard.yaml`:

```yaml
# Airtable ledger guard policy. Events rows are append-only; nothing is
# deleted; the schema never changes over MCP (bootstrap.py owns it).
# Airtable keys fields by ID, so every written key must be a field ID
# the probe recorded in bindings/ledger.md (bound_keys_only); the rules
# below match those IDs by field name.
covers: [append_only_events, no_delete, no_schema_change]
allow: [list_tables_for_base, get_table_schema, list_records_for_table,
        search_records, create_records_for_table, update_records_for_table]
deny: ["*delete*", "*create_base*", "*create_table*", "*update_table*",
       "*create_field*", "*update_field*", "*automation*", "*revert*",
       "*interface*", "*page*", "*comment*", "*form*"]
refuse_args: [typecast, interfaceContext]
writes:
  - kind: create
    tools: [create_records_for_table]
    at: ["records[].fields"]
  - kind: update
    tools: [update_records_for_table]
    at: ["records[].fields"]
unknown_writes: block
bound_keys_only: true
rules:
  - field: At
    forbid: update
  - field: Run ID
    forbid: update
  - field: Seq
    forbid: update
  - field: Activity
    forbid: update
  - field: Trigger
    forbid: update
  - field: Event
    forbid: update
  - field: Subject
    forbid: update
  - field: Outcome
    forbid: update
  - field: Items In
    forbid: update
  - field: Items Out
    forbid: update
  - field: Cost USD
    forbid: update
  - field: Duration s
    forbid: update
  - field: Detail
    forbid: update
  - field: Agent Version
    forbid: update
  - field: Backfilled
    forbid: update
```

Why each part holds:

- `update_records_for_table` with `performUpsert` is still an update, so
  it can't write an `Events` field, and can't create an `Events` row
  either. New events go through `create_records_for_table` only.
- `Key` and `Recorded At` are computed. Airtable rejects writes to them,
  and the probe does not record them as writable.
- A write to a different base uses field IDs the probe never recorded,
  so `bound_keys_only` blocks it.

`usage.md` maps each operation to these calls: `ledger_status` reads
`bindings/ledger.md`; `append_events` runs `list_records_for_table` on
`Events` filtered by `Run ID`, then `create_records_for_table` for the
missing `Seq` values; `find_events` and `get_rows` use
`list_records_for_table` with filters; `upsert_rows` uses
`update_records_for_table` with `performUpsert` on the table's `key`
field. It tells the agent never to pass `typecast`, even as `false`:
the guard refuses the argument whatever its value. Its `## Setup` lists
every table and field from A2 and `tables.md`, so a person can create
them by hand.

`bootstrap.py`, run by a person in their own terminal:

- Reads `AIRTABLE_TOKEN` (a personal access token; scopes to confirm in
  the plan against Airtable's docs, expected `schema.bases:read` and
  `schema.bases:write`).
- With `--workspace <id>` it creates the base; with `--base <id>` it
  adopts an existing empty base or one it created earlier.
- Creates `Events` and every table in `tables.md`, then adds any missing
  field. A missing select option, or a field whose type differs from the
  declared one, stops the script with an error naming the fix to make by
  hand. It never deletes, renames or retypes anything.
- Prints the `base_id` and the schema version it built. The probe, not
  the script, records them.

### A6. Bindings and the probe

The probe reads only (`list_tables_for_base`). It checks every table and
field of the package's `ledger_schema` exists with the declared type,
then writes `bindings/ledger.md`:

```
base_id: appXXXXXXXXXXXXXX
table_events: tblXXXXXXXXXXXXXX
table_cells: tblXXXXXXXXXXXXXX
field_at: fldXXXXXXXXXXXXXX
field_run_id: fldXXXXXXXXXXXXXX
...
ledger_schema: 1
```

Writable fields only; `Key` and `Recorded At` get no `field_` line. A
missing table or field fails the probe and shows the `## Setup` steps or
the `bootstrap.py` command, as for the CRM tools today.

### A7. Failure policy

**Retry.** Every ledger write gets up to 3 attempts with backoff (about
2 s, 5 s, 15 s), honoring `Retry-After` on HTTP 429. Events that still
fail stay queued in the run, in order; each later write retries the
queue first, and the run tries it once more before it ends.

**Then, by run type and by what failed:**

| What failed | Interactive run | Scheduled run |
|---|---|---|
| Writing `Events` | `notify_owner(kind: error)`, ask in chat: continue or stop | `notify_owner(kind: error)`, **continue**, queue kept |
| Reading agent tables | `notify_owner(kind: error)`, ask | `notify_owner(kind: error)`, **stop the activity** |
| Writing agent tables | `notify_owner(kind: error)`, ask | `notify_owner(kind: error)`, continue |
| `ledger_status` mismatch | Report, offer to run setup | Stop the activity, `notify_owner(kind: error)` |

**Capture after the fact.** Events still queued at the end of the run go
into the `notify_owner` call's `payload` as a fenced JSON block, and into
the run's final report. If `owner_notify` also fails, the final report
is the last copy; the routine keeps it.

### A8. `ledger-backfill` skill

Interactive only. Reads a queued-events block (from a notification email
or pasted), sets `Backfilled: true` on each event, and calls
`append_events`. Events keep their original `At`; `Recorded At` shows
when they arrived. Re-running it on the same block writes nothing.

### A9. Validator, tool checks and gate

- `validate-agent.sh`: the byte-identical check (A1); `tables.md` parses
  (A3); no agent-table field name collides with an `Events` field;
  with `--require-bump`, `ledger_schema` went up if `tables.md` changed,
  and nothing was removed, renamed or retyped.
- `tool_check.py`: a tool for a contract with `append_only_events` must
  have `bound_keys_only: true` and a `forbid: update` rule for every
  writable `Events` field. A tool for a contract with
  `no_schema_change` must refuse `typecast`.
- `schedule_check.py`: an activity that declares `ledger` passes only
  when `bindings/ledger.md` has `base_id`, a `field_` line for every
  writable `Events` field, and `ledger_schema` equal to the package's.

### A10. Docs and tests

STANDARD.md gets a "Ledger" section (A1–A8, in brief) and the reserved
invariant ids. Tests cover the guard (create on `Events` passes; any
`Events` field in an update, including an upsert, is blocked; delete
and schema tools blocked; `typecast` refused even as `false`; an
unrecorded field ID blocked), the validator fixtures, and the gate.

## Part B — sales-partner 7.1.0

### B1. Add the ledger

Copy `_ledger/` per A1. `tables.md` declares `ledger_schema: 1` and no
agent tables (see Open question 1). `agent.yaml` adds `ledger` to
`capabilities` and to every `activity_*` line.

### B2. What each activity records

All activities: `ledger_status` at start, then `run_started` and
`run_finished`, plus `stop_condition`, `notify_sent` and `error` when
they happen.

| Activity | `step` events | `Subject` | `Items In` → `Items Out` |
|---|---|---|---|
| prospect | one per source query | the query, e.g. `Oakland\|hvac` | results → new `Scored` leads |
| prepare | one per lead researched | the CRM lead id | findings → hooks written |
| approach | one per lead drafted | the CRM lead id | channels → drafts logged |
| digest | one for the send | `digest` | sections → 1 |

`run_finished` carries the run's totals and `Cost USD` (Apify spend when
known, otherwise empty).

**Interim run memory.** Before choosing queries, the Prospector calls
`find_events(since: 30 days ago, activity: prospect, event: step)` and
skips any query whose `Subject` matches a step with `Items Out` 0, unless
every remaining query was skipped. Goal-driven prospecting replaces this
with `Cells`.

### B3. Setup, README, evals

- Setup's tools step binds `ledger` to Airtable: create the base with
  `bootstrap.py` or by hand, run the probe, commit and push
  `bindings/ledger.md`.
- README: what the ledger is, that the client owns the base, and that a
  production instance needs Airtable's Team plan (Free is for trials;
  see Volume).
- Evals: a scheduled run whose `Events` write fails still finishes, sends
  `notify_owner(kind: error)` with the queued events in `payload`, and a
  backfill of that payload writes each event once.

### B4. Release

Version 7.1.0 in `agent.yaml` and the four host manifests.

## Volume

Third-party pricing summaries (2026; to confirm on Airtable's own
pricing page) list 1,000 records per base on Free, 50,000 on Team and
125,000 on Business, and about 5 API requests per second per base.

Sales-partner's default schedule is about three runs a week (prospect
then prepare, approach, digest) at 20–40 events each: about 100 rows a
week, or about 5,000 a year. Free fills in about ten weeks; Team holds
about ten years. See Open question 2.

## Stated limits

- **The agent writes its own record.** The guard stops it changing or
  deleting history, not leaving something out. A run that crashes, or
  skips an event, leaves a gap. `run_started` without `run_finished`
  shows a crash, but nothing shows an event that was never written.
  Facts captured by a hook outside the agent (tool calls, timings,
  guard blocks) would close this; out of scope here.
- **Reads are not scoped to the ledger base.** Writes are, through
  `bound_keys_only`. The agent can read any base the owner's Airtable
  connector can see.
- **`At` and `Backfilled` are what the agent says.** `Recorded At` is
  the check on both.
- **The guard trusts `bindings/ledger.md`.** Field IDs and their names
  come from that file, which a session could edit; unlike
  `owner_only_send` bindings, ledger bindings are not checked against a
  pushed copy. A later standard may add that check.

## Out of scope

- Hook-captured events (see Stated limits).
- Retention and pruning. `no_delete` means only the owner, or a future
  interactive script, removes rows.
- A second ledger tool (PostHog or another analytics store) behind the
  same contract: revisit once Airtable has run in production.
- Airtable views and dashboards: the owner builds them; the README
  suggests a few.
- Agent tables for sales-partner's goal-driven prospecting: that spec.

## Order

1. Builder A1–A10 on `feat/ledger`; tests green.
2. Sales-partner B1–B4; validator green against the new builder.
3. A live bootstrap and probe against a test base in the Webspenser
   Airtable account before release, recording the real tool schemas the
   way the Resend probe did.

## Acceptance

- A `create_records_for_table` call on `Events` with recorded field IDs
  passes the guard. An `update_records_for_table` call touching any
  `Events` field, with or without `performUpsert`, is blocked. Any
  `*delete*` or schema tool is blocked. `typecast` is refused at any
  value. A field ID not in `bindings/ledger.md` is blocked.
- `bin/validate-agent.sh` fails a fixture whose `capabilities/ledger/`
  differs from `_ledger/` (other than `tables.md`), whose agent table
  reuses an `Events` field name, or whose `tables.md` removes a field.
- `schedule_check.py check` fails an activity declaring `ledger` when
  `bindings/ledger.md` is missing a field line or has an older
  `ledger_schema`.
- A sales-partner prospect run writes `run_started`, one `step` per
  query and `run_finished` with matching `Run ID` and consecutive `Seq`.
- Backfilling the same queued block twice writes each event once.

## Resolved in review

1. **Agent tables come with prospecting.** This spec ships
   `ledger_schema: 1` (`Events` only). The goal-driven prospecting spec
   adds `Cells` and `Listings` as `ledger_schema: 2`, which also tests
   the upgrade path on a real change.
2. **Airtable plan.** Team is required for a production instance; Free
   is for trials only, and the README says so. No pruning.
3. **Interim run memory: yes.** The Prospector reads its own recent
   `step` events (B2) until `Cells` exists.
