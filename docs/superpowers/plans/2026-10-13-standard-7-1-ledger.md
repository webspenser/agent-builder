# Agent Standard 7.1: Activity Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standard `ledger` capability (append-only `Events` table plus agent-declared tables in the client's own Airtable base), enforced by the existing guard engine, checked by the validator, tool checker and schedule gate, and adopted by sales-partner so every run records itself.

**Architecture:** The builder ships the capability at `_ledger/`; agents copy it byte-identical except `tables.md`. The `Events` schema and the `tables.md` parser live once, in `_template/hooks/tool_check.py`, and the validator, schedule gate and `bootstrap.py` all import them. Append-only needs no engine change: `bound_keys_only` plus one `forbid: update` rule per `Events` field, and `refuse_args: [typecast, interfaceContext]`.

**Tech Stack:** Python 3 standard library (no packages), bash tests in `tests/*.sh` using `tests/lib.sh`, the Airtable Web API (bootstrap only) and the claude.ai Airtable MCP connector (agent runtime).

**Spec:** `docs/superpowers/specs/2026-10-13-standard-7-1-ledger-design.md`

## Global Constraints

- Builder version 7.1.0; `CURRENT_STANDARD = "7.1"`; sales-partner version 7.1.0 with `standard: "7.1"`.
- Branch `feat/ledger` in both repos. agent-builder's already exists (from `feat/standard-7`); create sales-partner's from `feat/standard-7`.
- Every copied ledger file in an agent is byte-identical to `_ledger/`, except `capabilities/ledger/tables.md`.
- Schema changes only through `bootstrap.py` (Airtable Web API, `AIRTABLE_TOKEN`), never over MCP. Additive only: never delete, rename or retype.
- The guard refuses `typecast` and `interfaceContext` at any value, `false` included.
- `Events` field list, in order: `Key` (formula, primary), `At`, `Recorded At` (created time), `Run ID`, `Seq`, `Activity`, `Trigger`, `Event`, `Subject`, `Outcome`, `Items In`, `Items Out`, `Cost USD`, `Duration s`, `Detail`, `Agent Version`, `Backfilled`. `Key` and `Recorded At` are computed and never written.
- Select values: `Trigger` = `scheduled`, `interactive`; `Event` = `run_started`, `step`, `stop_condition`, `notify_sent`, `error`, `run_finished`; `Outcome` = `ok`, `partial`, `failed`, `skipped`, `dry_run`.
- `append_only_events` and `no_schema_change` are reserved invariant ids: never `(acceptable)`.
- sales-partner ships `ledger_schema: 1` (no agent tables). Production instances need Airtable Team; Free is for trials.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Nothing is pushed or merged; PRs only when the operator asks.

## Review Focus

1. **An upsert that creates an `Events` row.** `update_records_for_table` with `performUpsert` and records without `id` creates rows. It must still be blocked when it touches an `Events` field (Task 2 test "upsert into Events").
2. **`typecast: false`.** A falsy value must still be refused; only JSON `null` or `""` pass (Task 2 test "typecast false").
3. **An agent-table field spelled like an `Events` field** (`Run-ID`, `run id`, `RUN_ID`). It must be refused by the `tables.md` parser, because the guard matches rules by normalized name (Task 1 test "collision by spelling").
4. **A backticked or quoted `ledger_schema` in bindings** (`` ledger_schema: `1` ``). `read_bindings` strips one pair of quotes, and the gate must accept it as `1`; `ledger_schema: 01` must not equal `1` silently (Task 6 tests).
5. **Re-running `bootstrap.py` on a complete base.** It must plan zero writes (Task 3 test "complete base: no actions").

---

## Part A — agent-builder (`cd ~/Work/Webspenser/agent-builder`, branch `feat/ledger`)

### Task 1: `Events` schema, `tables.md` parser and ledger guard checks in `tool_check.py`

**Files:**
- Modify: `_template/hooks/tool_check.py`
- Test: `tests/test-tool-check.sh`

**Interfaces:**
- Produces (module `tool_check`, used by Tasks 3, 4, 5, 6):
  - `LEDGER_INVARIANTS = ("append_only_events", "no_schema_change")`
  - `LEDGER_EVENTS`: tuple of `(name, airtable_type, options_tuple)`; for `formula` the options tuple holds one item, the formula.
  - `LEDGER_COMPUTED = ("Key", "Recorded At")`
  - `LEDGER_TYPES`: tuple of the Airtable type names an agent table may use.
  - `norm_field(name) -> str` (lowercase; runs of spaces and hyphens become `_`).
  - `ledger_writable() -> list[str]` (the `Events` names minus `LEDGER_COMPUTED`).
  - `parse_tables(text) -> (schema: int | None, tables: dict, problems: list[str])`, where `tables` is `{table_name: {"key": str | None, "fields": {field_name: (type, options_tuple)}}}` in file order.
  - `check_ledger_guard(parsed, invariants, label) -> list[str]`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-tool-check.sh`, before its final `finish` line:

````bash
echo "-- ledger: tables.md"
pt() { # pt <file>: schema, table names, problems from parse_tables
  OUT=$(python3 -B -c 'import sys; sys.path.insert(0, "_template/hooks"); import tool_check as t
s, tb, p = t.parse_tables(open(sys.argv[1], encoding="utf-8").read())
print("schema", s); print("tables", ",".join(tb)); print("\n".join(p))' "$1" 2>&1); RC=$?; }
LT="$W/tables.md"
printf '%s\n' '# Ledger tables' '' 'ledger_schema: 2' '' '## Cells' '' 'key: Cell' '' '| Field | Type | Options |' '|---|---|---|' \
  '| Cell | singleLineText | |' '| Last Run | dateTime | |' '| Status | singleSelect | open, done |' > "$LT"
pt "$LT"; expect 0 "valid tables.md: schema" "schema 2"
expect 0 "valid tables.md: tables" "tables Cells"
printf '%s\n' 'ledger_schema: 1' > "$LT"; pt "$LT"; expect 0 "Events only" "schema 1"
printf '%s\n' '## Cells' 'key: Cell' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "missing schema" "missing ledger_schema: <n>"
printf '%s\n' 'ledger_schema: 0' > "$LT"; pt "$LT"; expect 0 "schema 0" "ledger_schema must be a positive integer"
printf '%s\n' 'ledger_schema: 1' '## Events' 'key: X' '| X | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "Events declared" "Events is the standard table"
printf '%s\n' 'ledger_schema: 1' '## Cells' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "no key" "table Cells has no key: line"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Nope' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "key not a field" "table Cells: key Nope is not one of its fields"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | rainbow | |' > "$LT"; pt "$LT"; expect 0 "bad type" "Cells.Cell: type rainbow is not one of"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Mode | singleSelect | |' > "$LT"; pt "$LT"; expect 0 "select without options" "Cells.Mode: a singleSelect field needs options"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Cell | number | |' > "$LT"; pt "$LT"; expect 0 "duplicate field" "Cells.Cell is declared twice"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Run-ID | singleLineText | |' > "$LT"; pt "$LT"
expect 0 "collision by spelling" "Cells.Run-ID has the same name as the Events field Run ID"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '## Cells' 'key: Cell' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "duplicate table" "table Cells is declared twice"

echo "-- ledger: guard checks"
L="$W/pkg/capabilities/ledger"; LT2="$L/tools/demo"; mkdir -p "$LT2"
printf '%s\n' '# Ledger' '' '## Operations' '' '| `append_events` | x |' '' '## Invariants' '' \
  '- `append_only_events` — x' '- `no_delete` — y' '- `no_schema_change` — z' > "$L/contract.md"
good_ledger() {
  printf '%s\n' 'capability: ledger' 'provider: demo' 'server_match: demo' > "$LT2/identity.yaml"
  printf '%s\n' '# Demo' '' '- `append_events` — demo:create' '' '## Probe' '' 'Call demo:tables.' > "$LT2/usage.md"
  { printf '%s\n' 'covers: [append_only_events, no_delete, no_schema_change]' 'allow: [create_records, update_records]' 'deny: ["*delete*"]' \
      'refuse_args: [typecast, interfaceContext]' 'writes:' '  - kind: create' '    tools: [create_records]' '    at: ["records[].fields"]' \
      '  - kind: update' '    tools: [update_records]' '    at: ["records[].fields"]' 'unknown_writes: block' 'bound_keys_only: true' 'rules:'
    for f in "At" "Run ID" "Seq" "Activity" "Trigger" "Event" "Subject" "Outcome" "Items In" "Items Out" "Cost USD" "Duration s" "Detail" "Agent Version" "Backfilled"; do
      printf '  - field: %s\n    forbid: update\n' "$f"; done; } > "$LT2/guard.yaml"
}
good_ledger; run "$LT2" "$L/contract.md"; expect 0 "complete ledger guard passes" "OK: "
good_ledger; sed -i.bak '/^bound_keys_only/d' "$LT2/guard.yaml"; run "$LT2" "$L/contract.md"
expect 1 "append_only_events needs bound_keys_only" "append_only_events needs bound_keys_only: true"
good_ledger; python3 - "$LT2/guard.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("  - field: Detail\n    forbid: update\n",""))
PY
run "$LT2" "$L/contract.md"; expect 1 "missing forbid rule" "append_only_events needs a forbid: update rule for Detail"
good_ledger; sed -i.bak 's/^refuse_args: .*/refuse_args: [interfaceContext]/' "$LT2/guard.yaml"; run "$LT2" "$L/contract.md"
expect 1 "no_schema_change needs typecast refused" "no_schema_change needs refuse_args to include typecast"
good_ledger; sed -i.bak 's/^covers: .*/covers: [no_delete]/' "$LT2/guard.yaml"; sed -i.bak '/^bound_keys_only/d' "$LT2/guard.yaml"; run "$LT2" "$L/contract.md"
expect 0 "uncovered ledger invariants are not checked here (the gate refuses them)"
````

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-tool-check.sh 2>&1 | grep -E "FAIL|passed"`
Expected: the new `-- ledger` cases FAIL (`parse_tables` missing, guard checks absent).

- [ ] **Step 3: Implement**

In `_template/hooks/tool_check.py`, after the line `LITERAL_BEARER = …`, add:

```python
LEDGER_INVARIANTS = ("append_only_events", "no_schema_change")
# The standard ledger Events table (STANDARD.md, "Ledger"): (name, Airtable type, options).
# A formula's options hold its expression. Key and Recorded At are computed by Airtable.
LEDGER_EVENTS = (
    ("Key", "formula", ('{Run ID} & "#" & {Seq}',)),
    ("At", "dateTime", ()),
    ("Recorded At", "createdTime", ()),
    ("Run ID", "singleLineText", ()),
    ("Seq", "number", ()),
    ("Activity", "singleLineText", ()),
    ("Trigger", "singleSelect", ("scheduled", "interactive")),
    ("Event", "singleSelect", ("run_started", "step", "stop_condition", "notify_sent", "error", "run_finished")),
    ("Subject", "singleLineText", ()),
    ("Outcome", "singleSelect", ("ok", "partial", "failed", "skipped", "dry_run")),
    ("Items In", "number", ()),
    ("Items Out", "number", ()),
    ("Cost USD", "currency", ()),
    ("Duration s", "number", ()),
    ("Detail", "multilineText", ()),
    ("Agent Version", "singleLineText", ()),
    ("Backfilled", "checkbox", ()),
)
LEDGER_COMPUTED = ("Key", "Recorded At")
LEDGER_TYPES = ("singleLineText", "multilineText", "number", "currency", "checkbox", "date",
                "dateTime", "singleSelect", "multipleSelects", "url", "email", "phoneNumber")
LEDGER_SELECTS = ("singleSelect", "multipleSelects")
TABLE_ROW = re.compile(r"^\|(.*)\|$")
SCHEMA_LINE = re.compile(r"^ledger_schema:\s*(\S+)$")
KEY_LINE = re.compile(r"^key:\s*(.+)$")
```

After `def acceptable(text): …` add:

```python
def norm_field(name):
    """A field name the way the guard engine matches rule fields: lowercase, spaces and hyphens to _."""
    return re.sub(r"[\s-]+", "_", str(name).strip().lower())


def ledger_writable():
    """The Events fields the agent writes; computed fields excluded."""
    return [name for name, _, _ in LEDGER_EVENTS if name not in LEDGER_COMPUTED]


def parse_tables(text):
    """(schema, tables, problems) from a ledger tables.md.

    schema is the ledger_schema integer or None; tables maps each declared
    table, in file order, to {"key": field or None, "fields": {field: (type, options)}};
    problems holds one message per error and is empty for a valid file."""
    problems, tables, schema, current = [], {}, None, None
    events = {norm_field(name): name for name, _, _ in LEDGER_EVENTS}
    for raw in text.splitlines():
        line = raw.strip()
        m = SCHEMA_LINE.match(line)
        if m:
            if schema is not None:
                problems.append("ledger_schema appears more than once")
            elif not re.fullmatch(r"[1-9][0-9]*", m.group(1)):
                problems.append(f"ledger_schema must be a positive integer, got {m.group(1)!r}")
            else:
                schema = int(m.group(1))
            continue
        if line.startswith("## "):
            name = line[3:].strip()
            if norm_field(name) == "events":
                problems.append("Events is the standard table; an agent may not declare it")
            if name in tables:
                problems.append(f"table {name} is declared twice")
            tables[name] = {"key": None, "fields": {}}
            current = name
            continue
        if current is None:
            continue
        m = KEY_LINE.match(line)
        if m:
            tables[current]["key"] = m.group(1).strip()
            continue
        m = TABLE_ROW.match(line)
        if not m:
            continue
        cells = [c.strip() for c in m.group(1).split("|")]
        if len(cells) < 2 or cells[0] in ("", "Field") or set(cells[0]) <= set("-: "):
            continue
        field, ftype = cells[0], cells[1]
        options = tuple(o.strip() for o in cells[2].split(",") if o.strip()) if len(cells) > 2 else ()
        where = f"{current}.{field}"
        if field in tables[current]["fields"]:
            problems.append(f"{where} is declared twice")
        if ftype not in LEDGER_TYPES:
            problems.append(f"{where}: type {ftype} is not one of {', '.join(LEDGER_TYPES)}")
        if ftype in LEDGER_SELECTS and not options:
            problems.append(f"{where}: a {ftype} field needs options")
        if norm_field(field) in events:
            problems.append(f"{where} has the same name as the Events field {events[norm_field(field)]}; "
                            "the guard matches rules by name, so rename it")
        tables[current]["fields"][field] = (ftype, options)
    if schema is None:
        problems.append("missing ledger_schema: <n>")
    for name, table in tables.items():
        if table["key"] is None:
            problems.append(f"table {name} has no key: line")
        elif table["key"] not in table["fields"]:
            problems.append(f"table {name}: key {table['key']} is not one of its fields")
        if not table["fields"]:
            problems.append(f"table {name} declares no fields")
    return schema, tables, problems


def check_ledger_guard(parsed, invariants, label):
    """append_only_events: bound_keys_only plus a forbid: update rule for every writable Events field.
    no_schema_change: refuse_args includes typecast. Only for invariants the guard covers."""
    fails = []
    if "append_only_events" in invariants:
        if parsed.get("bound_keys_only") != "true":
            fails.append(f"{label}/guard.yaml: append_only_events needs bound_keys_only: true")
        forbidden = {norm_field(r["field"]) for r in parsed.get("rules", []) if r.get("forbid") in ("update", "true")}
        for name in ledger_writable():
            if norm_field(name) not in forbidden:
                fails.append(f"{label}/guard.yaml: append_only_events needs a forbid: update rule for {name}")
    if "no_schema_change" in invariants:
        refused = {re.sub(r"[_-]", "", a).lower() for a in parsed.get("refuse_args", [])}
        if "typecast" not in refused:
            fails.append(f"{label}/guard.yaml: no_schema_change needs refuse_args to include typecast")
    return fails
```

In `check_tool`, directly after the two lines

```python
    if "owner_only_send" in invariants and parsed:
        fails.extend(check_owner_only(parsed, folder, label))
```

add:

```python
    ledger_covered = [inv for inv in LEDGER_INVARIANTS if inv in invariants and inv in (covers or [])]
    if ledger_covered and parsed:
        fails.extend(check_ledger_guard(parsed, ledger_covered, label))
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test-tool-check.sh 2>&1 | grep -E "FAIL|passed"`
Expected: `-- N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/tool_check.py tests/test-tool-check.sh
git commit -m "feat(tool_check): ledger Events schema, tables.md parser, ledger guard checks

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 2: The `_ledger/` capability: contract, tables, Airtable tool

**Files:**
- Create: `_ledger/contract.md`, `_ledger/tables.md`, `_ledger/tools/airtable/identity.yaml`, `_ledger/tools/airtable/guard.yaml`, `_ledger/tools/airtable/usage.md`
- Test: `tests/test-guard-policy.sh`, `tests/run-all.sh`

**Interfaces:**
- Consumes: `tool_check.check_tool`, `check_ledger_guard` (Task 1).
- Produces: `_ledger/` files that Tasks 3, 4, 6 and Part B copy or reference; operation names `ledger_status`, `append_events`, `find_events`, `get_rows`, `upsert_rows`; bindings keys `base_id`, `table_<name>`, `field_<name>`, `ledger_schema`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-guard-policy.sh`, before `finish`:

```bash
echo "-- ledger (airtable)"
cp _ledger/tools/airtable/guard.yaml "$W/guard.yaml"
parses 0 "ledger guard parses"
LB="$W/ledger.md"
printf '%s\n' 'base_id: appAAAAAAAAAAAAAA' 'field_at: fldAT000000000000' 'field_run_id: fldRUN00000000000' \
  'field_seq: fldSEQ00000000000' 'field_event: fldEVT00000000000' 'field_cell: fldCEL00000000000' > "$LB"
A=mcp__claude_ai_Airtable__; R='"baseId":"appAAAAAAAAAAAAAA","tableId":"tblE0000000000000"'
run 0 "append an event" ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"fldAT000000000000\":\"2026-10-19T14:02:00Z\",\"fldRUN00000000000\":\"prospect-20261019T1400Z\",\"fldSEQ00000000000\":1,\"fldEVT00000000000\":\"run_started\"}}]}" "" "$LB" airtable
run 2 "edit an event" ${A}update_records_for_table "{$R,\"records\":[{\"id\":\"recA0000000000000\",\"fields\":{\"fldEVT00000000000\":\"error\"}}]}" "Event may not be changed after create" "$LB" airtable
run 2 "upsert into Events" ${A}update_records_for_table "{$R,\"performUpsert\":{\"fieldIdsToMergeOn\":[\"fldRUN00000000000\"]},\"records\":[{\"fields\":{\"fldRUN00000000000\":\"x\"}}]}" "Run ID may not be changed after create" "$LB" airtable
run 0 "upsert an agent-table row" ${A}update_records_for_table "{$R,\"performUpsert\":{\"fieldIdsToMergeOn\":[\"fldCEL00000000000\"]},\"records\":[{\"fields\":{\"fldCEL00000000000\":\"Oakland|hvac\"}}]}" "" "$LB" airtable
run 2 "typecast false" ${A}create_records_for_table "{$R,\"typecast\":false,\"records\":[{\"fields\":{\"fldEVT00000000000\":\"step\"}}]}" "may not use typecast" "$LB" airtable
run 2 "interfaceContext" ${A}create_records_for_table "{$R,\"interfaceContext\":{\"interfaceId\":\"pbdAAAAAAAAAAAAAA\"},\"records\":[{\"fields\":{\"fldEVT00000000000\":\"step\"}}]}" "may not use interfaceContext" "$LB" airtable
run 2 "unrecorded field ID" ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"fldOTHER000000000\":\"x\"}}]}" "is not a recorded field ID" "$LB" airtable
run 2 "field by name, not ID" ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"Event\":\"step\"}}]}" "is not a recorded field ID" "$LB" airtable
for t in delete_records_for_table create_field update_field create_table update_table create_base create_automation revert_action create_record_comment submit_form publish_interface; do
  run 2 "denied or not allowed: $t" ${A}$t "{$R}" "" "$LB" airtable
done
run 0 "read records" ${A}list_records_for_table "{$R}" "" "$LB" airtable
run 0 "read schema" ${A}list_tables_for_base '{"baseId":"appAAAAAAAAAAAAAA"}' "" "$LB" airtable
```

In `tests/run-all.sh`, after the line that checks the skeleton guard parses, add:

```bash
# tool_check reads the capability name from capabilities/<cap>/tools/<tool>/, so check a copy laid out that way.
LTMP=$(mktemp -d); mkdir -p "$LTMP/capabilities/ledger"; cp -R _ledger/contract.md _ledger/tools "$LTMP/capabilities/ledger/"
if ! python3 -B _template/hooks/tool_check.py "$LTMP/capabilities/ledger/tools/airtable" "$LTMP/capabilities/ledger/contract.md" >/dev/null; then
  echo "FAIL: _ledger/tools/airtable fails tool_check"; python3 -B _template/hooks/tool_check.py "$LTMP/capabilities/ledger/tools/airtable" "$LTMP/capabilities/ledger/contract.md"; STATUS=1; fi
rm -rf "$LTMP"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-guard-policy.sh 2>&1 | grep -E "FAIL|passed" | head`
Expected: the `-- ledger` cases FAIL (no `_ledger/` yet).

- [ ] **Step 3: Write the files**

`_ledger/contract.md`:

```markdown
# Ledger contract

The agent's record of what it did, in a store the business owns: one
standard `Events` table, the same for every agent, plus tables the agent
declares in `tables.md` for state it reads back between runs. Skills and
sub-agent contracts call these operations, never a provider's tools.

## Operations

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `ledger_status` | none | the bound `ledger_schema` and the package's | A mismatch: the run stops and reports "run setup to upgrade the ledger" |
| `append_events` | `events[]`, each with `run_id`, `seq`, `at`, `activity`, `trigger`, `event`, plus any of `subject`, `outcome`, `items_in`, `items_out`, `cost_usd`, `duration_s`, `detail`, `agent_version`, `backfilled` | the number of rows written | Rejects an event missing `run_id`, `seq`, `event` or `at`; skips any `run_id` + `seq` already present; writes in `seq` order |
| `find_events` | `run_id`, or `since` plus optional `activity` and `event` | events, oldest first | An empty list is a valid result |
| `get_rows` | `table`, `filter` | rows of an agent table | Rejects a table `tables.md` does not declare |
| `upsert_rows` | `table`, `rows[]` | the rows written | Rejects an undeclared table or field, and any write to `Events`; matches on the table's `key` |

## Events

One row per step of a run, not one per item. `run_id` is
`<activity>-<UTC start, yyyymmddThhmmZ>`; `seq` starts at 1 for
`run_started` and goes up by one per event in the run. `event` is one of
`run_started`, `step`, `stop_condition`, `notify_sent`, `error`,
`run_finished`; `outcome` is one of `ok`, `partial`, `failed`, `skipped`,
`dry_run`; `trigger` is `scheduled` or `interactive`. `items_in` and
`items_out` count what a step took in and produced; `detail` is one
readable line; `agent_version` is `agent.yaml`'s `version`.

**Run bracketing.** Every run calls `ledger_status` first, writes
`run_started` next and `run_finished` last, with the run's totals. This
is an instruction; no guard can check it.

## Failure policy

Retry each write up to 3 times (about 2 s, 5 s, then 15 s; on HTTP 429
wait as `Retry-After` says). Events that still fail stay queued in the
run, in order; each later write retries the queue first, and the run
tries the queue once more before it ends. Then:

| What failed | Interactive run | Scheduled run |
|---|---|---|
| Writing `Events` | `notify_owner(kind: error)`; ask: continue or stop | `notify_owner(kind: error)`; continue, queue kept |
| Reading agent tables | `notify_owner(kind: error)`; ask | `notify_owner(kind: error)`; stop the activity |
| Writing agent tables | `notify_owner(kind: error)`; ask | `notify_owner(kind: error)`; continue |
| `ledger_status` mismatch | Report; offer to run setup | Stop the activity; `notify_owner(kind: error)` |

Events still queued when the run ends go into that `notify_owner` call's
`payload` as one fenced `json` block holding the list of events, and
into the run's final report. The `ledger-backfill` skill writes them
later. An agent without `owner_notify` reports them only in the run's
final report.

## Invariants

A tool's `guard.yaml` lists in `covers` the invariants it enforces by
mechanism.

- `append_only_events` — an `Events` row, once written, is never changed.
- `no_delete` — the agent never deletes a row in any ledger table.
- `no_schema_change` — the agent never creates, changes or deletes a
  table, field or select option.
```

`_ledger/tables.md`:

```markdown
# Ledger tables

The tables this agent keeps in its ledger base besides the standard
`Events` table, and the ledger's schema version. Raise `ledger_schema`
by one whenever you add a table or a field; never remove, rename or
retype one. Each table is a `## <Name>` heading, a `key: <Field>` line
naming the field `upsert_rows` matches on, and a `| Field | Type |
Options |` table. See STANDARD.md, "Ledger".

ledger_schema: 1
```

`_ledger/tools/airtable/identity.yaml`:

```yaml
capability: ledger
provider: airtable
server_match: airtable
```

`_ledger/tools/airtable/guard.yaml` (the rules block lists every writable `Events` field, in `LEDGER_EVENTS` order):

```yaml
# Airtable ledger guard policy. Events rows are append-only; nothing is
# deleted; the schema never changes over MCP (bootstrap.py owns it).
# Airtable keys fields by ID, so every written key must be a field ID
# the probe recorded in bindings/ledger.md (bound_keys_only); the rules
# below match those IDs by field name. typecast would create select
# options on write, a schema change, so it is refused at any value.
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

`_ledger/tools/airtable/usage.md`:

````markdown
# Ledger — Airtable tool

The ledger lives in one Airtable base per agent, in the business's own
Airtable account. `airtable:` below means the connected Airtable
server's tools, whatever their prefix. Table and field IDs come from
`bindings/ledger.md` (`base_id`, `table_<name>`, `field_<name>`, names
lowercase with spaces as `_`); every write keys fields by those IDs.

- `ledger_status` — read `ledger_schema` from `bindings/ledger.md` and
  from `capabilities/ledger/tables.md`. Equal: continue. Different:
  stop as the contract's failure policy says.
- `append_events` — `airtable:list_records_for_table` on `table_events`,
  `filters` `field_run_id` = the run's `run_id`, `fieldIds`
  [`field_seq`], to learn which `seq` values exist. Then
  `airtable:create_records_for_table` on `table_events` with the
  missing events in `seq` order, up to 50 per call. `fields` keys are
  `field_<name>` IDs; select values are plain strings (`"run_started"`).
  Never write `Key` or `Recorded At`: Airtable computes them.
- `find_events` — `airtable:list_records_for_table` on `table_events`
  with `filters` on `field_run_id`, or on `field_at` (`>=` the `since`
  date) plus `field_activity` and `field_event` when given; `sort` by
  `field_at`, then `field_seq`.
- `get_rows` — `airtable:list_records_for_table` on `table_<name>` with
  `filters`.
- `upsert_rows` — `airtable:update_records_for_table` on `table_<name>`
  with `performUpsert: {"fieldIdsToMergeOn": [<field ID of the table's
  key>]}` and records without `id`.

Never pass `typecast` (not even `false`) or `interfaceContext`: the guard
refuses both. Never call a delete or schema tool: the guard denies them.
A new select value, field or table needs a ledger upgrade (Setup), never
a write.

## Setup

1. The business owns the Airtable account. A production instance needs
   the Team plan or higher: Free holds 1,000 records per base, about ten
   weeks of runs. Free is fine for a trial.
2. Create the base, one of two ways:
   - **Script.** In your own terminal, set the token without echoing it:
     `read -rs AIRTABLE_TOKEN && export AIRTABLE_TOKEN`. Then run
     `python3 <package>/capabilities/ledger/tools/airtable/bootstrap.py --workspace <workspace id>`
     for a new base, or `--base <base id>` for an existing one (this is
     also how you upgrade). Add `--dry-run` to see the plan first. The
     token is a personal access token with scopes `schema.bases:read`
     and `schema.bases:write`, limited to that workspace. The script
     prints the base ID. It never deletes, renames or retypes anything,
     and it never prints the token.
   - **By hand.** Create a base with a table named `Events` holding the
     fields below (`Key` first, as the primary field), plus every table
     and field in `capabilities/ledger/tables.md`.
3. Add the Airtable connector in your host and sign in with the same
   account.

`Events`:

| Field | Type | Options |
|---|---|---|
| Key | formula (primary field) | `{Run ID} & "#" & {Seq}` |
| At | dateTime | UTC |
| Recorded At | createdTime | |
| Run ID | singleLineText | |
| Seq | number | integer |
| Activity | singleLineText | |
| Trigger | singleSelect | scheduled, interactive |
| Event | singleSelect | run_started, step, stop_condition, notify_sent, error, run_finished |
| Subject | singleLineText | |
| Outcome | singleSelect | ok, partial, failed, skipped, dry_run |
| Items In | number | integer |
| Items Out | number | integer |
| Cost USD | currency | $, 2 decimals |
| Duration s | number | integer |
| Detail | multilineText | |
| Agent Version | singleLineText | |
| Backfilled | checkbox | |

## Probe

1. Ask the operator for the base ID: `bootstrap.py` prints it, or it is
   the `app…` part of the base's URL.
2. `airtable:list_tables_for_base` with that base ID. Confirm `Events`
   and every table in `capabilities/ledger/tables.md` exist, each with
   every listed field at the listed type, and that each select field
   holds every listed option. If anything is missing, stop and show
   step 2 of Setup.
3. Write `bindings/ledger.md` in the instance, one plain line each, with
   nothing else on the line: `base_id: <app…>`; `table_<name>: <tbl…>`
   for `Events` and each agent table; `field_<name>: <fld…>` for every
   field the agent writes (every field except `Key` and `Recorded At`);
   and `ledger_schema: <n>` copied from `tables.md`.

The probe only reads.
````

- [ ] **Step 4: Run tests**

Run: `bash tests/test-guard-policy.sh 2>&1 | grep -E "FAIL|passed" && bash tests/run-all.sh 2>&1 | grep -E "^FAIL|GREEN|FAILURES"`
Expected: `0 failed`; the run-all `_ledger` tool_check line does not print FAIL. (`bootstrap.py` does not exist yet, which is fine: `## Setup` is allowed without it.)

- [ ] **Step 5: Commit**

```bash
git add _ledger tests/test-guard-policy.sh tests/run-all.sh
git commit -m "feat: _ledger capability — contract, tables template, Airtable tool and guard

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 3: `bootstrap.py`

**Files:**
- Create: `_ledger/tools/airtable/bootstrap.py`
- Test: `tests/test-ledger-bootstrap.sh` (new), `tests/run-all.sh`

**Interfaces:**
- Consumes: `tool_check.LEDGER_EVENTS`, `parse_tables` (Task 1), loaded from `<package root>/hooks/tool_check.py`, or from `_template/hooks/tool_check.py` when run inside agent-builder.
- Produces (module functions, tested offline): `field_spec(name, ftype, options) -> dict`, `wanted(root) -> list[(table, [(field, type, options)])]`, `plan(existing, wanted) -> (actions, errors)`, `main(argv) -> int`. `existing` is `{table_name: {"id": tbl, "fields": {field_name: {"type": str, "choices": [str]}}}}`. Actions are `("create_table", table, [field_spec…])` and `("create_field", table, field_spec)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test-ledger-bootstrap.sh` (mode 755):

```bash
#!/usr/bin/env bash
# _ledger/tools/airtable/bootstrap.py, offline: the network call is faked.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
B=_ledger/tools/airtable/bootstrap.py
py() { OUT=$(python3 -B -c "import importlib.util, sys
spec = importlib.util.spec_from_file_location('b', '$B'); b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
$1" 2>&1); RC=$?; }
expect() { # expect <rc> <label> [text]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; } && ! printf '%s' "$OUT" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}

echo "-- field specs"
py "print(b.field_spec('Event', 'singleSelect', ('run_started', 'step')))";    expect 0 "select choices" "'choices': [{'name': 'run_started'}, {'name': 'step'}]"
py "print(b.field_spec('Key', 'formula', ('{Run ID} & \"#\" & {Seq}',)))";       expect 0 "formula" "'formula': '{Run ID} & \"#\" & {Seq}'"
py "print(b.field_spec('Seq', 'number', ()))";                                expect 0 "number precision 0" "'precision': 0"
py "print(b.field_spec('Cost USD', 'currency', ()))";                         expect 0 "currency" "'symbol': '\$'"
py "print(b.field_spec('At', 'dateTime', ()))";                               expect 0 "dateTime UTC" "'timeZone': 'utc'"

echo "-- plan"
py "w = b.wanted('.', events_only=True); a, e = b.plan({}, w); print(a[0][0], a[0][1], [f['name'] for f in a[0][2]][:2]); print(e)"
expect 0 "empty base: create Events, Key first" "create_table Events ['Key', 'At']"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS}}}
a, e = b.plan(ex, w); print(len(a), len(e))"
expect 0 "complete base: no actions" "0 0"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS if n != 'Detail'}}}
a, e = b.plan(ex, w); print(a)"
expect 0 "missing field: create it" "('create_field', 'Events', {'name': 'Detail', 'type': 'multilineText'})"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': 'number' if n == 'Subject' else t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS}}}
a, e = b.plan(ex, w); print(e)"
expect 0 "type mismatch is an error" "Events.Subject is number, the ledger needs singleLineText"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': [c for c in o if c != 'dry_run'] if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS}}}
a, e = b.plan(ex, w); print(e)"
expect 0 "missing select option is an error" "Events.Outcome lacks option dry_run"

echo "-- tables.md"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/capabilities/ledger"
printf '%s\n' 'ledger_schema: 2' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Runs | number | |' > "$T/capabilities/ledger/tables.md"
py "w = b.wanted('$T'); print([t for t, _ in w])";                             expect 0 "agent tables follow Events" "['Events', 'Cells']"
printf '%s\n' 'ledger_schema: 0' > "$T/capabilities/ledger/tables.md"
py "w = b.wanted('$T')";                                                       expect 1 "invalid tables.md stops" "ledger_schema must be a positive integer"

echo "-- main, faked network"
py "b.call = lambda *a, **k: (_ for _ in ()).throw(AssertionError('no call expected'))
import os; os.environ.pop('AIRTABLE_TOKEN', None); sys.exit(b.main(['--base', 'appAAAAAAAAAAAAAA']))"
expect 2 "no token: exit 2" "AIRTABLE_TOKEN is not set"
py "import os; os.environ['AIRTABLE_TOKEN'] = 'pat-canary-12345'
calls = []
def fake(method, path, body=None):
    calls.append((method, path)); return 200, {'tables': []}
b.call = fake; rc = b.main(['--base', 'appAAAAAAAAAAAAAA', '--dry-run']); print(calls); sys.exit(rc)"
expect 0 "dry run reads only" "[('GET', '/meta/bases/appAAAAAAAAAAAAAA/tables')]"
printf '%s' "$OUT" | grep -q 'pat-canary-12345' && _report no "printed the token" || _report ok "never prints the token"
py "import os; os.environ['AIRTABLE_TOKEN'] = 'x'
def fake(method, path, body=None):
    return (500, {'error': 'boom'}) if method == 'POST' else (200, {'tables': []})
b.call = fake; sys.exit(b.main(['--base', 'appAAAAAAAAAAAAAA']))"
expect 1 "a failed write stops with exit 1" "create table Events failed (500)"
py "sys.exit(b.main(['--base', 'not-a-base']))";                               expect 2 "bad base id" "not an Airtable base ID"
finish
```

In `tests/run-all.sh`, after the tool check line, add:

```bash
echo "== ledger bootstrap"; tests/test-ledger-bootstrap.sh || STATUS=1
```

- [ ] **Step 2: Run to verify they fail**

Run: `chmod +x tests/test-ledger-bootstrap.sh && bash tests/test-ledger-bootstrap.sh 2>&1 | tail -3`
Expected: FAIL lines (no `bootstrap.py`).

- [ ] **Step 3: Implement**

Create `_ledger/tools/airtable/bootstrap.py` (mode 755):

```python
#!/usr/bin/env python3
"""Create or upgrade the ledger base that usage.md describes.

Additive and idempotent: every table, field and select option is created
only if missing, so re-running after a partial failure is safe. Nothing
is ever deleted, renamed or retyped; a field of the wrong type stops the
script.

Reads AIRTABLE_TOKEN from the environment (set it in your shell with
`read -rs AIRTABLE_TOKEN && export AIRTABLE_TOKEN`; never write it to a
file). Token scopes: schema.bases:read, schema.bases:write.

    python3 capabilities/ledger/tools/airtable/bootstrap.py --workspace <wsp…> [--name <base name>]
    python3 capabilities/ledger/tools/airtable/bootstrap.py --base <app…> [--dry-run]
"""
import importlib.util
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
API = "https://api.airtable.com/v0"
HERE = pathlib.Path(__file__).resolve().parent
BASE_ID = re.compile(r"^app[A-Za-z0-9]{14}$")
WORKSPACE_ID = re.compile(r"^wsp[A-Za-z0-9]{14}$")
DATE_TIME = {"dateFormat": {"name": "iso"}, "timeFormat": {"name": "24hour"}, "timeZone": "utc"}


def _load_tool_check():
    """The agent's hooks/tool_check.py (package root is four levels up), or the builder's template copy."""
    for candidate in (HERE.parents[3] / "hooks" / "tool_check.py",
                      HERE.parents[2] / "_template" / "hooks" / "tool_check.py"):
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location("tool_check", candidate)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise SystemExit("ERROR: cannot find hooks/tool_check.py")


tool_check = _load_tool_check()


def field_spec(name, ftype, options):
    """The Airtable Web API field object for one declared field."""
    spec = {"name": name, "type": ftype}
    if ftype in ("singleSelect", "multipleSelects"):
        spec["options"] = {"choices": [{"name": o} for o in options]}
    elif ftype == "formula":
        spec["options"] = {"formula": options[0]}
    elif ftype == "number":
        spec["options"] = {"precision": 0}
    elif ftype == "currency":
        spec["options"] = {"precision": 2, "symbol": "$"}
    elif ftype == "checkbox":
        spec["options"] = {"icon": "check", "color": "greenBright"}
    elif ftype == "dateTime":
        spec["options"] = dict(DATE_TIME)
    elif ftype == "date":
        spec["options"] = {"dateFormat": {"name": "iso"}}
    elif ftype == "createdTime":
        spec["options"] = {"result": {"type": "dateTime", "options": dict(DATE_TIME)}}
    return spec


def wanted(root, events_only=False):
    """[(table, [(field, type, options)])]: Events first, then the agent's tables.md tables."""
    tables = [("Events", list(tool_check.LEDGER_EVENTS))]
    if events_only:
        return tables
    path = pathlib.Path(root) / "capabilities" / "ledger" / "tables.md"
    _, declared, problems = tool_check.parse_tables(path.read_text(encoding="utf-8"))
    if problems:
        raise SystemExit("ERROR: capabilities/ledger/tables.md: " + "; ".join(problems))
    for name, table in declared.items():
        tables.append((name, [(f, t, o) for f, (t, o) in table["fields"].items()]))
    return tables


def plan(existing, tables):
    """(actions, errors) that bring `existing` up to `tables`, additively."""
    actions, errors = [], []
    for table, fields in tables:
        have = existing.get(table)
        if have is None:
            actions.append(("create_table", table, [field_spec(*f) for f in fields]))
            continue
        for name, ftype, options in fields:
            got = have["fields"].get(name)
            if got is None:
                actions.append(("create_field", table, field_spec(name, ftype, options)))
            elif got["type"] != ftype:
                errors.append(f"{table}.{name} is {got['type']}, the ledger needs {ftype}; fix it by hand")
            elif ftype in ("singleSelect", "multipleSelects"):
                for option in options:
                    if option not in got.get("choices", []):
                        errors.append(f"{table}.{name} lacks option {option}; add it by hand")
    return actions, errors


def call(method, path, body=None):
    """(status, parsed JSON) for one Web API request. Never prints the token."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + os.environ["AIRTABLE_TOKEN"], "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        try:
            return err.code, json.loads(err.read() or b"{}")
        except ValueError:
            return err.code, {}
    except urllib.error.URLError as err:
        return 0, {"error": str(err.reason)}


def existing_tables(base):
    status, body = call("GET", f"/meta/bases/{base}/tables")
    if status != 200:
        raise SystemExit(f"ERROR: reading base {base} failed ({status}): {body.get('error', body)}")
    out = {}
    for t in body.get("tables", []):
        fields = {}
        for f in t.get("fields", []):
            choices = [c.get("name") for c in (f.get("options") or {}).get("choices", [])]
            fields[f["name"]] = {"type": f["type"], "choices": choices}
        out[t["name"]] = {"id": t["id"], "fields": fields}
    return out


def apply(base, existing, actions):
    for kind, table, payload in actions:
        if kind == "create_table":
            status, body = call("POST", f"/meta/bases/{base}/tables", {"name": table, "fields": payload})
            if status != 200:
                print(f"ERROR: create table {table} failed ({status}): {body.get('error', body)}")
                return 1
            existing[table] = {"id": body.get("id"), "fields": {}}
            print(f"created table {table}")
        else:
            tid = existing[table]["id"]
            status, body = call("POST", f"/meta/bases/{base}/tables/{tid}/fields", payload)
            if status != 200:
                print(f"ERROR: create field {table}.{payload['name']} failed ({status}): {body.get('error', body)}")
                return 1
            print(f"created field {table}.{payload['name']}")
    return 0


def main(argv):
    args = list(argv)
    dry = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    opts = dict(zip(args[::2], args[1::2]))
    if len(args) % 2 or not ({"--base", "--workspace"} & opts.keys()) or {"--base", "--workspace"} <= opts.keys():
        print("usage: bootstrap.py --workspace <wsp…> [--name <base name>] | --base <app…> [--dry-run]")
        print("ERROR: pass exactly one of --workspace <wsp…> or --base <app…>")
        return 2
    if "--base" in opts and not BASE_ID.match(opts["--base"]):
        print(f"ERROR: {opts['--base']!r} is not an Airtable base ID (app + 14 characters)")
        return 2
    if "--workspace" in opts and not WORKSPACE_ID.match(opts["--workspace"]):
        print(f"ERROR: {opts['--workspace']!r} is not an Airtable workspace ID (wsp + 14 characters)")
        return 2
    if not os.environ.get("AIRTABLE_TOKEN"):
        print("ERROR: AIRTABLE_TOKEN is not set; run: read -rs AIRTABLE_TOKEN && export AIRTABLE_TOKEN")
        return 2
    root = HERE.parents[3]
    tables = wanted(root, events_only=not (root / "capabilities" / "ledger" / "tables.md").is_file())
    schema = 1
    if (root / "capabilities" / "ledger" / "tables.md").is_file():
        schema = tool_check.parse_tables((root / "capabilities" / "ledger" / "tables.md").read_text(encoding="utf-8"))[0]
    if "--workspace" in opts:
        if dry:
            print(f"would create a base with tables: {', '.join(t for t, _ in tables)}")
            return 0
        body = {"name": opts.get("--name", "Agent ledger"), "workspaceId": opts["--workspace"],
                "tables": [{"name": t, "fields": [field_spec(*f) for f in fs]} for t, fs in tables]}
        status, resp = call("POST", "/meta/bases", body)
        if status != 200:
            print(f"ERROR: create base failed ({status}): {resp.get('error', resp)}")
            return 1
        print(f"base_id: {resp.get('id')}")
        print(f"ledger_schema: {schema} built")
        return 0
    base = opts["--base"]
    existing = existing_tables(base)
    actions, errors = plan(existing, tables)
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        return 1
    if dry:
        for kind, table, payload in actions:
            print(f"would {kind.replace('_', ' ')} {table}" + ("" if kind == "create_table" else f".{payload['name']}"))
        print(f"{len(actions)} change(s) planned")
        return 0
    rc = apply(base, existing, actions)
    if rc == 0:
        print(f"base_id: {base}")
        print(f"ledger_schema: {schema} built")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Note for the test "dry run reads only": `--dry-run` with `--base` makes one `GET` and no `POST`.

- [ ] **Step 4: Run tests**

Run: `bash tests/test-ledger-bootstrap.sh 2>&1 | tail -3 && bash tests/run-all.sh 2>&1 | grep -E "^FAIL|GREEN|FAILURES"`
Expected: `0 failed`, `ALL GREEN`. (`_ledger/tools/airtable` now has `bootstrap.py` plus `## Setup`, which `tool_check` requires together.)

- [ ] **Step 5: Commit**

```bash
git add _ledger/tools/airtable/bootstrap.py tests/test-ledger-bootstrap.sh tests/run-all.sh
git commit -m "feat(ledger): bootstrap.py creates or upgrades the base, additively

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 4: `ledger-backfill` skill and validator checks

**Files:**
- Create: `_ledger/skills/ledger-backfill/SKILL.md`
- Modify: `bin/lib/check_manifests.py`
- Test: `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `tool_check.parse_tables` (via `load_tool_checker()`), `_ledger/` (Task 2).
- Produces: `check_ledger(root) -> list[str]`; reserved ids `append_only_events`, `no_schema_change` refused as `(acceptable)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-validate-agent.sh`, before `finish`:

```bash
echo "-- ledger"
add_ledger() { # add_ledger <dir>: the standard ledger capability, copied as an agent would
  local d="$1"
  mkdir -p "$d/capabilities/ledger" "$d/skills/ledger-backfill"
  cp -R _ledger/contract.md _ledger/tables.md _ledger/tools "$d/capabilities/ledger/"
  cp _ledger/skills/ledger-backfill/SKILL.md "$d/skills/ledger-backfill/SKILL.md"
  sed -i.bak 's/^capabilities: crm$/capabilities: crm, ledger/' "$d/agent.yaml"; rm -f "$d/agent.yaml.bak"
}
make_valid_agent "$FIX/led-good"; add_ledger "$FIX/led-good"
assert_pass bin/validate-agent.sh "$FIX/led-good"
make_valid_agent "$FIX/led-edit"; add_ledger "$FIX/led-edit"; echo '# local edit' >> "$FIX/led-edit/capabilities/ledger/tools/airtable/guard.yaml"
fails_with "$FIX/led-edit" "capabilities/ledger/tools/airtable/guard.yaml differs from the Agent Standard reference copy (_ledger/tools/airtable/guard.yaml in agent-builder)"
make_valid_agent "$FIX/led-noskill"; add_ledger "$FIX/led-noskill"; rm -r "$FIX/led-noskill/skills/ledger-backfill"
fails_with "$FIX/led-noskill" "missing skills/ledger-backfill/SKILL.md"
make_valid_agent "$FIX/led-collide"; add_ledger "$FIX/led-collide"
printf '%s\n' 'ledger_schema: 2' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Outcome | singleLineText | |' > "$FIX/led-collide/capabilities/ledger/tables.md"
fails_with "$FIX/led-collide" "capabilities/ledger/tables.md: Cells.Outcome has the same name as the Events field Outcome"
make_valid_agent "$FIX/led-tables-own"; add_ledger "$FIX/led-tables-own"
printf '%s\n' 'ledger_schema: 2' '## Cells' 'key: Cell' '| Cell | singleLineText | |' > "$FIX/led-tables-own/capabilities/ledger/tables.md"
assert_pass bin/validate-agent.sh "$FIX/led-tables-own"
make_valid_agent "$FIX/led-accept"
printf '%s\n' '- `append_only_events` (acceptable) — x' >> "$FIX/led-accept/capabilities/crm/contract.md"
fails_with "$FIX/led-accept" "capabilities/crm/contract.md: append_only_events cannot be marked (acceptable)"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-validate-agent.sh 2>&1 | grep -E "FAIL|passed" | tail -8`
Expected: the `led-*` cases FAIL (no skill file, no ledger checks).

- [ ] **Step 3: Implement**

Create `_ledger/skills/ledger-backfill/SKILL.md`:

```markdown
---
name: ledger-backfill
description: Use when a run's ledger events could not be written and the owner has the queued block (from an error notification or a run's final report) — writes them to the ledger once, marked as backfilled.
---

Interactive only; never part of a scheduled run.

1. Ask the operator to paste the queued-events block: the fenced `json`
   list from the `notify_owner` error message or the run's final report.
   Read only that block; ignore any other text around it.
2. Parse it. Every item needs `run_id`, `seq`, `event` and `at`. If any
   item lacks one, list the bad items and stop: write nothing.
3. Set `backfilled: true` on every item. Keep each `at` as given.
4. Call `ledger_status`. On a mismatch, stop and offer to run setup.
5. Call `append_events` with the items. It skips any `run_id` + `seq`
   already in the ledger, so running this twice on the same block
   writes nothing the second time.
6. Report how many rows were written and how many were already there.
```

In `bin/lib/check_manifests.py`:

1. After `REFERENCE_ADD_TOOL = …` add:

```python
LEDGER_REFERENCE = TEMPLATE_HOOKS.parents[1] / "_ledger"
LEDGER_FILES = ("contract.md", "tools/airtable/identity.yaml", "tools/airtable/usage.md",
                "tools/airtable/guard.yaml", "tools/airtable/bootstrap.py")
RESERVED_INVARIANTS = ("no_external_send", "owner_only_send", "append_only_events", "no_schema_change")
```

2. Replace `check_reference_file` with:

```python
def check_reference_file(root, rel, reference, shown=None):
    """`rel` exists and is byte-identical to the builder's reference copy."""
    path = root / rel
    if not path.is_file():
        return [f"missing {rel}"]
    try:
        same = reference.is_file() and path.read_bytes() == reference.read_bytes()
    except OSError:
        return [f"{rel} cannot be read"]
    where = shown or f"_template/{rel}"
    return [] if same else [f"{rel} differs from the Agent Standard reference copy ({where} in agent-builder)"]
```

3. In `check_capability`, replace `for inv in ("no_external_send", "owner_only_send"):` with `for inv in RESERVED_INVARIANTS:`.

4. Before `def check_tools`, add:

```python
def check_ledger(root):
    """The standard ledger: copied files byte-identical to _ledger/, the backfill skill, a valid tables.md."""
    fails = []
    for rel in LEDGER_FILES:
        fails.extend(check_reference_file(root, f"capabilities/ledger/{rel}", LEDGER_REFERENCE / rel,
                                          shown=f"_ledger/{rel}"))
    fails.extend(check_reference_file(root, "skills/ledger-backfill/SKILL.md",
                                      LEDGER_REFERENCE / "skills" / "ledger-backfill" / "SKILL.md",
                                      shown="_ledger/skills/ledger-backfill/SKILL.md"))
    tables = root / "capabilities" / "ledger" / "tables.md"
    if not tables.is_file():
        return fails + ["missing capabilities/ledger/tables.md"]
    checker = load_tool_checker()
    if checker is None:
        return fails + ["validator cannot load its tool checker (_template/hooks/tool_check.py)"]
    try:
        _, _, problems = checker.parse_tables(read_text(tables))
    except ReadError as err:
        return fails + [f"capabilities/ledger/tables.md: {err}"]
    return fails + [f"capabilities/ledger/tables.md: {p}" for p in problems]
```

5. In `check_tools`, after `fails.extend(check_activities(root, meta, caps))`, add:

```python
    if "ledger" in caps:
        fails.extend(check_ledger(root))
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test-validate-agent.sh 2>&1 | tail -2 && bash tests/run-all.sh 2>&1 | grep -E "^FAIL|GREEN|FAILURES"`
Expected: `0 failed`, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add _ledger/skills bin/lib/check_manifests.py tests/test-validate-agent.sh
git commit -m "feat(validator): ledger files match _ledger/, tables.md is valid, ledger ids are reserved

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 5: `--require-bump` keeps the ledger schema additive

**Files:**
- Modify: `bin/lib/check_manifests.py`, `bin/validate-agent.sh`
- Test: `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `tool_check.parse_tables`.
- Produces: CLI `check_manifests.py --ledger-diff <old tables.md | -> <new tables.md>` printing one `FAIL: …` line per problem, exit 0 (crash otherwise).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-validate-agent.sh`, before `finish`:

```bash
echo "-- ledger schema stays additive"
ledger_repo() { # ledger_repo <dir> <tables.md lines...>: a committed agent with a ledger, then new tables.md lines in the work tree
  local d="$1"; shift
  make_valid_agent "$d"; add_ledger "$d"
  printf '%s\n' 'ledger_schema: 2' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Runs | number | |' > "$d/capabilities/ledger/tables.md"
  git -C "$d" init -q && git -C "$d" add -A && git -C "$d" -c user.name=t -c user.email=t@t commit -qm base
  printf '%s\n' "$@" > "$d/capabilities/ledger/tables.md"
  sed -i.bak 's/^version: 0.1.0/version: 0.2.0/' "$d/agent.yaml"; rm -f "$d/agent.yaml.bak"; sync_agents "$d" demo-agent 0.2.0
  sed -i.bak 's/"version":"0.1.0"/"version":"0.2.0"/' "$d/gemini-extension.json" "$d/.codex-plugin/plugin.json"; rm -f "$d"/*.bak "$d"/.codex-plugin/*.bak
}
ledger_repo "$FIX/led-add" 'ledger_schema: 3' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Runs | number | |' '| Yield | number | |'
assert_pass bin/validate-agent.sh "$FIX/led-add" --require-bump HEAD
ledger_repo "$FIX/led-nobump" 'ledger_schema: 2' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Runs | number | |' '| Yield | number | |'
fails_with "$FIX/led-nobump" "capabilities/ledger/tables.md changed but ledger_schema is still 2" --require-bump HEAD
ledger_repo "$FIX/led-drop" 'ledger_schema: 3' '## Cells' 'key: Cell' '| Cell | singleLineText | |'
fails_with "$FIX/led-drop" "capabilities/ledger/tables.md: Cells.Runs was removed or renamed; ledger changes are additive only" --require-bump HEAD
ledger_repo "$FIX/led-retype" 'ledger_schema: 3' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Runs | singleLineText | |'
fails_with "$FIX/led-retype" "capabilities/ledger/tables.md: Cells.Runs changed type from number to singleLineText" --require-bump HEAD
ledger_repo "$FIX/led-droptable" 'ledger_schema: 3'
fails_with "$FIX/led-droptable" "capabilities/ledger/tables.md: table Cells was removed" --require-bump HEAD
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-validate-agent.sh 2>&1 | grep -E "led-(add|nobump|drop|retype|droptable)"`
Expected: the four `fails_with` cases FAIL; `led-add` passes already.

- [ ] **Step 3: Implement**

In `bin/lib/check_manifests.py`, before `def get(key, source):`, add:

```python
def ledger_diff(old_text, new_text):
    """FAIL messages for a tables.md change that is not additive, or not versioned."""
    if old_text == new_text:
        return []
    checker = load_tool_checker()
    if checker is None:
        return ["validator cannot load its tool checker (_template/hooks/tool_check.py)"]
    old_schema, old_tables, _ = checker.parse_tables(old_text)
    new_schema, new_tables, problems = checker.parse_tables(new_text)
    rel = "capabilities/ledger/tables.md"
    if problems:
        return []  # reported by check_ledger
    fails = []
    if old_schema is not None and (new_schema or 0) <= old_schema:
        fails.append(f"{rel} changed but ledger_schema is still {new_schema}")
    for name, table in old_tables.items():
        if name not in new_tables:
            fails.append(f"{rel}: table {name} was removed")
            continue
        for field, (ftype, options) in table["fields"].items():
            new = new_tables[name]["fields"].get(field)
            if new is None:
                fails.append(f"{rel}: {name}.{field} was removed or renamed; ledger changes are additive only")
            elif new[0] != ftype:
                fails.append(f"{rel}: {name}.{field} changed type from {ftype} to {new[0]}")
            else:
                for option in options:
                    if option not in new[1]:
                        fails.append(f"{rel}: {name}.{field} lost option {option}")
        if table["key"] != new_tables[name]["key"]:
            fails.append(f"{rel}: table {name} changed its key from {table['key']} to {new_tables[name]['key']}")
    return fails
```

In `main(argv)`, before the `--get` branch, add:

```python
    if len(argv) == 3 and argv[0] == "--ledger-diff":
        try:
            old = sys.stdin.read() if argv[1] == "-" else read_text(pathlib.Path(argv[1]))
            new = read_text(pathlib.Path(argv[2]))
        except ReadError as err:
            print(f"FAIL: capabilities/ledger/tables.md: {err}")
            return 0
        for message in ledger_diff(old, new):
            print(f"FAIL: {message}")
        return 0
```

In `bin/validate-agent.sh`, inside the `--require-bump` block, directly after the closing `fi` of the `if { [ -n "$changed" ] …` version check (still inside the `else` that has both versions), add:

```bash
        if [ -f "$DIR/capabilities/ledger/tables.md" ] && git -C "$DIR" cat-file -e "$BUMP_REF:./capabilities/ledger/tables.md" 2>/dev/null; then
          ldiff=$(git -C "$DIR" show "$BUMP_REF:./capabilities/ledger/tables.md" | "$PYTHON" "$CHECKER" --ledger-diff - "$DIR/capabilities/ledger/tables.md" 2>&1); lrc=$?
          while IFS= read -r line; do [ -n "$line" ] && fail "${line#FAIL: }"; done <<< "$ldiff"
          [ "$lrc" -eq 0 ] || fail "ledger diff checker crashed (exit $lrc)"
        fi
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test-validate-agent.sh 2>&1 | tail -2`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/check_manifests.py bin/validate-agent.sh tests/test-validate-agent.sh
git commit -m "feat(validator): --require-bump keeps the ledger schema additive and versioned

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 6: The schedule gate checks ledger bindings

**Files:**
- Modify: `_template/hooks/schedule_check.py`
- Test: `tests/test-schedule-check.sh`

**Interfaces:**
- Consumes: `tool_check.ledger_writable`, `norm_field`, `parse_tables`; `guard_policy.read_bindings`.
- Produces: `ledger_binding_problems(instance, cap) -> list[str]`, applied to every bound capability whose contract has `append_only_events`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-schedule-check.sh`, before `finish`:

```bash
echo "-- ledger bindings"
LP="$W/lpkg"; mkdir -p "$LP/hooks" "$LP/capabilities/ledger"
cp _template/hooks/schedule_check.py _template/hooks/guard_policy.py _template/hooks/tool_check.py "$LP/hooks/"
cp -R _ledger/contract.md _ledger/tables.md _ledger/tools "$LP/capabilities/ledger/"
printf '%s\n' 'name: led-agent' 'version: 1.0.0' 'description: Demo' 'standard: "7.0"' 'catalog: webspenser' \
  'catalog_repo: webspenser/agent-library' 'capabilities: ledger' 'activity_log: ledger' > "$LP/agent.yaml"
LSC="$LP/hooks/schedule_check.py"
lbind() { # lbind <instance> [schema] [drop-field]: bind ledger to airtable with every writable field
  local d="$1" schema="${2:-1}" drop="${3:-}"
  mkdir -p "$d/bindings"
  printf '%s\n' 'agent: led-agent' 'mode: plugin' 'bind_ledger: airtable' > "$d/instance.yaml"
  printf '%s\n' 'timezone: UTC' 'schedule_log: "daily 06:00"' > "$d/schedules.yaml"
  { echo 'base_id: appAAAAAAAAAAAAAA'; echo 'table_events: tblAAAAAAAAAAAAAA'
    for f in at run_id seq activity trigger event subject outcome items_in items_out cost_usd duration_s detail agent_version backfilled; do
      [ "$f" = "$drop" ] || echo "field_$f: fld$(printf '%-14s' "$f" | tr ' _' 'XX' | cut -c1-14)"; done
    echo "ledger_schema: $schema"; } > "$d/bindings/ledger.md"
}
lbind "$W/l-ok"; OUT=$(python3 -B "$LSC" check "$W/l-ok" --repo acme/led 2>&1); RC=$?; expect 0 "complete ledger bindings pass" "PASS  led-agent: log (led)"
lbind "$W/l-tick" '`1`'; OUT=$(python3 -B "$LSC" check "$W/l-tick" --repo acme/led 2>&1); RC=$?; expect 0 "backticked schema is read as 1"
lbind "$W/l-old" 0; OUT=$(python3 -B "$LSC" check "$W/l-old" --repo acme/led 2>&1); RC=$?
expect 1 "older ledger_schema fails" "bindings/ledger.md ledger_schema is 0, the package needs 1; run setup to upgrade the ledger"
lbind "$W/l-pad" 01; OUT=$(python3 -B "$LSC" check "$W/l-pad" --repo acme/led 2>&1); RC=$?; expect 1 "01 is not 1" "ledger_schema is 01, the package needs 1"
lbind "$W/l-field" 1 detail; OUT=$(python3 -B "$LSC" check "$W/l-field" --repo acme/led 2>&1); RC=$?
expect 1 "missing field line fails" "bindings/ledger.md has no field_detail line; re-run setup's tools step"
lbind "$W/l-base"; sed -i.bak '/^base_id/d' "$W/l-base/bindings/ledger.md"; OUT=$(python3 -B "$LSC" check "$W/l-base" --repo acme/led 2>&1); RC=$?
expect 1 "missing base_id fails" "bindings/ledger.md has no base_id line"
lbind "$W/l-none"; rm "$W/l-none/bindings/ledger.md"; OUT=$(python3 -B "$LSC" check "$W/l-none" --repo acme/led 2>&1); RC=$?
expect 1 "no bindings file fails" "bindings/ledger.md has no base_id line"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-schedule-check.sh 2>&1 | grep -E "FAIL|passed" | tail -8`
Expected: the failing-binding cases FAIL (the gate passes them today).

- [ ] **Step 3: Implement**

In `_template/hooks/schedule_check.py`, after `def recipient_keys(folder): …`, add:

```python
def ledger_binding_problems(instance, cap):
    """append_only_events: bindings/<cap>.md has base_id, a field_ line for every writable
    Events field, and ledger_schema equal to the package's capabilities/<cap>/tables.md."""
    fix = "re-run setup's tools step"
    bfile = pathlib.Path(instance) / "bindings" / f"{cap}.md"
    try:
        have = guard_policy.read_bindings(str(bfile)) if bfile.is_file() else {}
    except (OSError, UnicodeDecodeError, guard_policy.PolicyError) as err:
        return [f"{cap}: {err}"]
    problems = []
    if not have.get("base_id"):
        problems.append(f"{cap}: bindings/{cap}.md has no base_id line; {fix}")
    for name in tool_check.ledger_writable():
        key = "field_" + tool_check.norm_field(name)
        if not have.get(key):
            problems.append(f"{cap}: bindings/{cap}.md has no {key} line; {fix}")
    try:
        schema, _, bad = tool_check.parse_tables(_read(ROOT / "capabilities" / cap / "tables.md", guard=False))
    except CheckError as err:
        return problems + [f"{cap}: {err}"]
    if bad:
        return problems + [f"{cap}: capabilities/{cap}/tables.md is invalid: {bad[0]}"]
    bound = sorted(have.get("ledger_schema") or [])
    if bound != [str(schema)]:
        shown = ", ".join(bound) or "missing"
        problems.append(f"{cap}: bindings/{cap}.md ledger_schema is {shown}, the package needs {schema}; "
                        "run setup to upgrade the ledger")
    return problems
```

In the per-provider loop, directly after the `if "owner_only_send" in invs:` block that checks `recipient_keys`, add (same indentation as that `if`):

```python
                if "append_only_events" in invs:
                    entry["problems"].extend(ledger_binding_problems(instance, cap))
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test-schedule-check.sh 2>&1 | tail -2`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/schedule_check.py tests/test-schedule-check.sh
git commit -m "feat(gate): a scheduled ledger activity needs complete, current ledger bindings

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 7: Standard 7.1 — versions and docs

**Files:**
- Modify: `bin/lib/check_manifests.py` (`CURRENT_STANDARD`), `_template/agent.yaml`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`, `tests/run-all.sh`, `tests/test-builder-manifests.sh`, `tests/test-guard.sh`, `tests/test-schedule-check.sh`, `tests/test-validate-agent.sh`, `STANDARD.md`, `README.md`, `docs/how-it-works.md`

**Interfaces:**
- Produces: `CURRENT_STANDARD = "7.1"`; builder manifests at `7.1.0`.

- [ ] **Step 1: Bump**

```bash
sed -i.bak 's/CURRENT_STANDARD = "7.0"/CURRENT_STANDARD = "7.1"/' bin/lib/check_manifests.py
sed -i.bak 's/^standard: "7.0"/standard: "7.1"/' _template/agent.yaml
sed -i.bak 's/"version": "7.0.0"/"version": "7.1.0"/' .claude-plugin/plugin.json .codex-plugin/plugin.json gemini-extension.json
sed -i.bak -e 's/standard: "7.0"/standard: "7.1"/g' -e 's/_template is not 7.0/_template is not 7.1/' tests/run-all.sh tests/test-guard.sh tests/test-schedule-check.sh tests/test-validate-agent.sh
sed -i.bak 's/standard: "6.0"/standard: "7.0"/' tests/test-validate-agent.sh   # the "old standard" fixture now uses 7.0
sed -i.bak 's/c\["version"\] == "7.0.0"/c["version"] == "7.1.0"/' tests/test-builder-manifests.sh
find . -name '*.bak' -not -path './.git/*' -delete
grep -rn '"7\.0"\|7\.0\.0' --exclude-dir=.git --exclude-dir=docs . | grep -v 'renamed .* in 7.0'
```

Expected from the last command: only `STANDARD.md` lines, fixed in Step 2. If the "old standard" fixture message in `tests/test-validate-agent.sh` names `"7.0"` vs `"7.1"`, update its expected text to `standard '7.0' must be "7.1"`.

- [ ] **Step 2: STANDARD.md**

1. **Development phase**: `The standard is 7.1.` and `the validator requires \`standard: "7.1"\``.
2. **Agent manifest** example: `standard: "7.1"`.
3. **Directory layout**: add `_ledger/                  # the standard ledger capability, copied into agents that use it` under `_template/`.
4. **Capabilities**: after the reserved-send-ids paragraph, add: `Two more ids are reserved for the ledger: \`append_only_events\` and \`no_schema_change\` (see Ledger). None of the four can be marked \`(acceptable)\`.`
5. New section **Ledger**, after **Bindings**:

   ````markdown
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

   - **`Events`** is the same in every agent: `Key` (formula, primary),
     `At`, `Recorded At` (created time), `Run ID`, `Seq`, `Activity`,
     `Trigger`, `Event`, `Subject`, `Outcome`, `Items In`, `Items Out`,
     `Cost USD`, `Duration s`, `Detail`, `Agent Version`, `Backfilled`.
     The list, with types, is `LEDGER_EVENTS` in `hooks/tool_check.py`.
   - **`tables.md`**: `ledger_schema: <n>`, then per table a `## <Name>`
     heading, a `key: <Field>` line and a `| Field | Type | Options |`
     table. No table named `Events`; no field whose name, normalized,
     equals an `Events` field.
   - **Schema changes** are additive only and made only by the tool's
     `bootstrap.py`, never over MCP. With `--require-bump`, the validator
     fails a `tables.md` change that does not raise `ledger_schema`, or
     that removes, renames or retypes a table, field or select option.
   - **Invariants**: `append_only_events` (a tool covering it needs
     `bound_keys_only: true` and a `forbid: update` rule for every
     writable `Events` field), `no_delete`, and `no_schema_change` (a
     tool covering it must refuse `typecast`).
   - **Bindings**: the probe writes `base_id`, `table_<name>`,
     `field_<name>` for every written field, and `ledger_schema`.
   - **Gate**: a scheduled activity using a capability with
     `append_only_events` needs `base_id`, every `Events` field line, and
     `ledger_schema` equal to the package's.
   - **Failure policy**: in `_ledger/contract.md`.
   ````

6. **Validation** list: `standard` is `"7.1"`; add bullets for the byte-identical ledger files, `tables.md` validity, and the additive-schema rule under `--require-bump`.

Run: `grep -n '"7\.0"' STANDARD.md` — Expected: none.

- [ ] **Step 3: README and how-it-works**

`README.md`, in the table that lists `_template/`, add a row: `| \`_ledger/\` | The standard ledger capability: an append-only record of every run, in the business's own Airtable base |`.

`docs/how-it-works.md`, after the owner-notification paragraph, add:

```markdown
An agent can keep a ledger: every run writes what it did to an Airtable
base the business owns. The guard lets the agent add rows to that record
but never change or delete one, and never change the base's structure,
so the record can be trusted as an audit trail.
```

- [ ] **Step 4: Run everything**

Run: `bash tests/run-all.sh 2>&1 | tail -3`
Expected: `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: Agent Standard 7.1 — activity ledger (builder 7.1.0)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Part B — sales-partner (`cd ~/Work/Webspenser/sales-partner`)

Create the branch first: `git switch -c feat/ledger feat/standard-7`.

### Task 8: Sync to builder 7.1 and add the ledger capability

**Files:**
- Modify: `hooks/*` (sync), `agent.yaml`, `tests/test-schedules.sh`, `tests/test-policies.sh`, `tests/test-content.sh`
- Create: `capabilities/ledger/` (copy), `skills/ledger-backfill/SKILL.md` (copy)

**Interfaces:**
- Consumes: builder `_template/hooks/`, `_ledger/` (Part A).
- Produces: sales-partner with `capabilities: crm, owner_notify, ledger`, every activity declaring `ledger`, `standard: "7.1"`.

- [ ] **Step 1: Write failing content and gate assertions**

In `tests/test-content.sh`, before `finish`, add:

```bash
echo "-- 7.1: ledger"
assert_contains "$SP/agent.yaml" 'standard: "7.1"'
assert_contains "$SP/agent.yaml" 'capabilities: crm, owner_notify, ledger'
assert_contains "$SP/agent.yaml" 'activity_prospect: crm, owner_notify, ledger'
assert_contains "$SP/agent.yaml" 'activity_digest: crm, owner_notify, ledger'
assert_contains "$SP/capabilities/ledger/tables.md" 'ledger_schema: 1'
for f in contract.md tools/airtable/guard.yaml tools/airtable/usage.md tools/airtable/identity.yaml tools/airtable/bootstrap.py; do
  [ -f "./capabilities/ledger/$f" ] && _report ok "ledger $f present" || _report no "ledger $f missing"
done
[ -f ./skills/ledger-backfill/SKILL.md ] && _report ok "ledger-backfill skill present" || _report no "ledger-backfill skill missing"
# Byte-identity with the builder's _ledger/ is the validator's check (validate-agent.sh), which CI runs.
```

In `tests/test-schedules.sh`, add a `ledger()` helper next to `notify()` and call it from `inst()` and the `approach` fixture:

```bash
ledger() { # ledger <dir>: bind the ledger to Airtable with complete bindings
  mkdir -p "$1/bindings"
  printf '%s\n' 'bind_ledger: airtable' >> "$1/instance.yaml"
  { echo 'base_id: appAAAAAAAAAAAAAA'; echo 'table_events: tblAAAAAAAAAAAAAA'
    for f in at run_id seq activity trigger event subject outcome items_in items_out cost_usd duration_s detail agent_version backfilled; do
      echo "field_$f: fld$(printf '%-14s' "$f" | tr ' _' 'XX' | cut -c1-14)"; done
    echo 'ledger_schema: 1'; } > "$1/bindings/ledger.md"
}
```

Update the approach line to `grep -qx 'activity_approach: crm, owner_notify, ledger' agent.yaml`, and add one case: an instance with CRM and `owner_notify` bound but no ledger fails with `ledger is not bound`.

In `tests/test-policies.sh`, before the `echo "-- Attio"` line, add:

```bash
echo "-- ledger (airtable)"
LG=capabilities/ledger/tools/airtable/guard.yaml; A=mcp__claude_ai_Airtable__; SM=airtable
printf '%s\n' 'base_id: appAAAAAAAAAAAAAA' 'field_at: fldAT000000000000' 'field_run_id: fldRUN00000000000' \
  'field_seq: fldSEQ00000000000' 'field_event: fldEVT00000000000' > "$W/ledger.md"
R='"baseId":"appAAAAAAAAAAAAAA","tableId":"tblE0000000000000"'
check 0 "append an event"     $LG ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"fldRUN00000000000\":\"prospect-20261019T1400Z\",\"fldSEQ00000000000\":1,\"fldEVT00000000000\":\"run_started\"}}]}" "" "$W/ledger.md"
check 2 "edit an event"       $LG ${A}update_records_for_table "{$R,\"records\":[{\"id\":\"recA0000000000000\",\"fields\":{\"fldEVT00000000000\":\"error\"}}]}" "Event may not be changed after create" "$W/ledger.md"
check 2 "upsert into Events"  $LG ${A}update_records_for_table "{$R,\"performUpsert\":{\"fieldIdsToMergeOn\":[\"fldRUN00000000000\"]},\"records\":[{\"fields\":{\"fldRUN00000000000\":\"x\"}}]}" "Run ID may not be changed after create" "$W/ledger.md"
check 2 "typecast false"      $LG ${A}create_records_for_table "{$R,\"typecast\":false,\"records\":[{\"fields\":{\"fldEVT00000000000\":\"step\"}}]}" "may not use typecast" "$W/ledger.md"
check 2 "unrecorded field ID" $LG ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"fldOTHER000000000\":\"x\"}}]}" "is not a recorded field ID" "$W/ledger.md"
for t in delete_records_for_table create_field update_field create_table create_base create_automation revert_action; do
  check 2 "blocked: $t"       $LG ${A}$t "{$R}" "" "$W/ledger.md"
done
check 0 "read records"        $LG ${A}list_records_for_table "{$R}" "" "$W/ledger.md"
SM=
```

Run: `bash tests/run-all.sh 2>&1 | grep -E "FAIL|passed"` — Expected: failures.

- [ ] **Step 2: Sync and copy**

```bash
cp ../agent-builder/_template/hooks/tool_check.py ../agent-builder/_template/hooks/schedule_check.py hooks/
mkdir -p capabilities/ledger skills/ledger-backfill
cp -R ../agent-builder/_ledger/contract.md ../agent-builder/_ledger/tables.md ../agent-builder/_ledger/tools capabilities/ledger/
cp ../agent-builder/_ledger/skills/ledger-backfill/SKILL.md skills/ledger-backfill/SKILL.md
chmod 755 capabilities/ledger/tools/airtable/bootstrap.py
sed -i.bak -e 's/^standard: "7.0"/standard: "7.1"/' -e 's/^capabilities: crm, owner_notify$/capabilities: crm, owner_notify, ledger/' \
  -e 's/^\(activity_[a-z]*: crm, owner_notify\)$/\1, ledger/' agent.yaml && rm agent.yaml.bak
diff -r hooks ../agent-builder/_template/hooks | grep -v __pycache__
```

Expected from `diff`: no output.

- [ ] **Step 3: Run tests and the validator**

Run: `bash tests/run-all.sh 2>&1 | tail -3 && ../agent-builder/bin/validate-agent.sh .`
Expected: `ALL GREEN`, `OK: . conforms`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: ledger capability on Agent Standard 7.1; every activity declares it

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 9: Every run records itself

**Files:**
- Modify: `AGENT.md`, `subagents/prospector.md`, `subagents/preparer.md`, `subagents/approacher.md`, `skills/send-digest/SKILL.md`, `README.md`, `evals/cases.md`, `tests/test-content.sh`

**Interfaces:**
- Consumes: ledger operations `ledger_status`, `append_events`, `find_events` (Task 2).

- [ ] **Step 1: Write failing content assertions**

```bash
echo "-- 7.1: runs record themselves"
assert_contains "$SP/AGENT.md" '`bind_ledger`'
assert_contains "$SP/AGENT.md" 'Every run records itself in the ledger'
assert_contains "$SP/subagents/prospector.md" '## Ledger'
assert_contains "$SP/subagents/prospector.md" 'find_events(since: 30 days ago, activity: prospect, event: step)'
assert_contains "$SP/subagents/preparer.md" '## Ledger'
assert_contains "$SP/subagents/approacher.md" '## Ledger'
assert_contains "$SP/skills/send-digest/SKILL.md" '## Ledger'
assert_contains "$SP/README.md" 'You can see everything it did.'
assert_contains "$SP/README.md" 'Team plan'
assert_contains "$SP/evals/cases.md" 'A ledger outage never hides a run'
wc -c < "$SP/AGENT.md" | awk '{exit !($1 < 6000)}' && _report ok "AGENT.md under 6000 bytes" || _report no "AGENT.md 6000 bytes or more"
```

Run: `bash tests/test-content.sh 2>&1 | grep -E "FAIL|passed"` — Expected: failures.

- [ ] **Step 2: AGENT.md**

- Inputs, after the owner-notifications line: `- Ledger (\`bind_ledger\`): the business's Airtable base, through \`capabilities/ledger/contract.md\`.`
- Operating rules, add rule 5: `5. Every run records itself in the ledger: run bracketing and the failure policy in \`capabilities/ledger/contract.md\`. Each sub-agent's \`## Ledger\` section says what a \`step\` is.`

Check `wc -c AGENT.md` stays under 6000.

- [ ] **Step 3: Sub-agents and digest**

Add a `## Ledger` section before `## Handoff` in each sub-agent, and before `## Procedure` in `send-digest`:

`subagents/prospector.md`:

```markdown
## Ledger
One `step` per source query: `subject` is the query (for map sources,
`<city>|<industry>`), `items_in` the results returned, `items_out` the
new `Scored` leads it produced. Before choosing queries, call
`find_events(since: 30 days ago, activity: prospect, event: step)` and
skip any query whose `subject` matches a step with `items_out` 0, unless
every remaining query would be skipped. `run_finished` carries the run's
totals and the Apify spend in `cost_usd` when known.
```

`subagents/preparer.md`:

```markdown
## Ledger
One `step` per lead researched: `subject` is the CRM lead id,
`items_in` the findings logged, `items_out` the hooks written.
```

`subagents/approacher.md`:

```markdown
## Ledger
One `step` per lead drafted: `subject` is the CRM lead id, `items_in`
the reachable channels, `items_out` the drafts logged.
```

`skills/send-digest/SKILL.md`:

```markdown
## Ledger
One `step` for the send: `subject` `digest`, `items_in` the six
sections, `items_out` 1 when `notify_owner` succeeded. These ledger
writes are the digest's only writes besides delivery; it still never
writes to the CRM.
```

In `send-digest`, the sentence "Its only side effect anywhere is delivering the finished digest." becomes "Its only side effects are delivering the finished digest and recording the run in the ledger."

- [ ] **Step 4: README and evals**

`README.md`:
- **Why you can trust it**, new bullet after the first: `- **You can see everything it did.** Every run writes a record to an Airtable base you own. The agent can add to that record but never change or delete it.`
- **What you need**: `- **Airtable**, your own account, for the agent's record of every run. Production needs the Team plan; Free (1,000 records) is fine for a trial.`
- **Tools it needs**: `- Airtable for the ledger (\`capabilities/ledger/tools/airtable/\`); \`bootstrap.py\` creates the base, and the guard keeps the record append-only.` and change the guard sentence to `Each tool's guard policy makes Attio, HubSpot, Resend and Airtable unattended-safe.`

`evals/cases.md`, after Case 16:

```markdown
## Case 17: A ledger outage never hides a run

**Given** — a scheduled prospecting run; every Airtable write fails.

**Expect** — the run retries, keeps going, and finishes its CRM work. It
calls `notify_owner(kind: error)` with the unwritten events as a fenced
`json` block in `payload`, and lists them in its final report. Running
`ledger-backfill` on that block writes each event once, with
`Backfilled` checked; running it again writes nothing.

**Why it matters** — a run nobody can see breaks the audit promise;
recovery must not double-count.

**How to run** — bind the ledger to a base the connector can't reach;
run the prospect activity; then restore access and backfill twice.
```

- [ ] **Step 5: Run tests and the validator**

Run: `bash tests/run-all.sh 2>&1 | tail -3 && ../agent-builder/bin/validate-agent.sh .`
Expected: `ALL GREEN`, `OK: . conforms`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: every activity records its run in the ledger; prospector skips dry queries

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 10: Live check against a test base (operator present)

**Files:**
- Create: `../agent-builder/docs/superpowers/notes/2026-10-13-airtable-ledger-probe.md`
- Modify (only if the live API disagrees): `../agent-builder/_ledger/tools/airtable/bootstrap.py`, `usage.md`, then re-copy into sales-partner.

This task needs the operator: an Airtable workspace for testing, a personal access token in their own terminal, and the claude.ai Airtable connector.

- [ ] **Step 1: Bootstrap.** Ask the operator to run, in their own terminal: `read -rs AIRTABLE_TOKEN && export AIRTABLE_TOKEN && python3 capabilities/ledger/tools/airtable/bootstrap.py --workspace <wsp…> --name "Sales Partner ledger (test)"`. Record the output. If the API rejects the base (most likely spots: `Key` as a formula primary field created in the same request as the fields it references; the `createdTime` options shape), fix `field_spec` or the create order in the builder's `bootstrap.py`, add a test for the fix in `tests/test-ledger-bootstrap.sh`, and rerun. If a formula cannot be the primary field at creation, move `Run ID` first in `LEDGER_EVENTS` (it becomes the primary) and keep `Key` as a plain formula field; update the spec's A2 table and `usage.md` to match.
- [ ] **Step 2: Re-run is a no-op.** `bootstrap.py --base <app…> --dry-run` prints `0 change(s) planned`.
- [ ] **Step 3: Probe.** Through the Airtable connector, `list_tables_for_base` on the new base. Write a scratch instance's `bindings/ledger.md` per `usage.md` `## Probe`.
- [ ] **Step 4: Guard, live.** With the scratch instance (bindings committed to a local bare remote, as in the Resend check), run the real `guard.sh` on: a `create_records_for_table` append (expect allow), an update to an `Events` field (expect block), `typecast: false` (expect block). Then, with the operator's OK, make the one allowed append through the connector and confirm the row, its `Key` and its `Recorded At` in the base.
- [ ] **Step 5: Notes.** Write the notes file: the base ID shape, the real tool schemas used, any change made in Step 1, and the result of each check. Commit in agent-builder (`docs: Airtable ledger live check`); if `_ledger/` changed, re-copy into sales-partner and commit there too.

### Task 11: Release sales-partner 7.1.0

**Files:**
- Modify: `agent.yaml`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`, `README.md`, `tests/test-content.sh`

- [ ] **Step 1: Bump**

```bash
sed -i.bak 's/^version: 7.0.0/version: 7.1.0/' agent.yaml
sed -i.bak 's/"version": "7.0.0"/"version": "7.1.0"/' .claude-plugin/plugin.json .codex-plugin/plugin.json gemini-extension.json
sed -i.bak 's/^Version 7.0.0\./Version 7.1.0./' README.md
find . -name '*.bak' -not -path './.git/*' -delete
sed -i.bak "s/assert_contains \"\$SP\/agent.yaml\" 'version: 7.0.0'/assert_contains \"\$SP\/agent.yaml\" 'version: 7.1.0'/" tests/test-content.sh && rm tests/test-content.sh.bak
grep -rn '7\.0\.0' --exclude-dir=.git --exclude-dir=docs .
```

Expected from the last command: only the `echo "-- 7.0.0: …"` section labels in `tests/test-content.sh`.

- [ ] **Step 2: Full check**

Run: `bash tests/run-all.sh && ../agent-builder/bin/validate-agent.sh . --require-bump main && (cd ../agent-builder && bash tests/run-all.sh | tail -1)`
Expected: `ALL GREEN`, `OK: . conforms`, `ALL GREEN`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: sales-partner 7.1.0

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Done when

- `cd ~/Work/Webspenser/agent-builder && bash tests/run-all.sh` is green.
- `cd ~/Work/Webspenser/sales-partner && bash tests/run-all.sh && ../agent-builder/bin/validate-agent.sh . --require-bump main` is green.
- The spec's Acceptance list holds; Task 10's notes record the live checks.
- Neither branch is merged or pushed until the operator reviews; PRs only when asked.
