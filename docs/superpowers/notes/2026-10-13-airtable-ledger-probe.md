# Airtable ledger live check (Task 10)

Recorded 2026-10-13 for the Standard 7.1 ledger on `feat/ledger`. Bootstrap
ran from the operator's terminal; the probe and the guard check ran from a
Claude Code session.

## Bootstrap (operator's terminal, Airtable Web API)

- Run 1, `--workspace`: 422 `UNSUPPORTED_FIELD_TYPE_FOR_CREATE`, message
  "Creating formula fields as part of table creation is not supported.
  Create the table first, then add these fields separately." No base was
  created.
  - Fix abe308b: `Run ID` is now the primary field (first in `LEDGER_EVENTS`).
    Computed fields (formula, createdTime) are created after their table.
    `--workspace` creates the base with plain fields, then runs the same
    plan/apply as `--base`.
- Run 2, `--workspace`: base `appGaJaEuBnytNllF` created, `Events.Key`
  created, then `Recorded At` failed 422 `INVALID_FIELD_TYPE_OPTIONS_FOR_CREATE`:
  "options is not included in the ... (type=createdTime) schema".
  - Fix 62a7675: createdTime fields are sent with name and type only.
- Run 3, `--base appGaJaEuBnytNllF`: completed (operator reported success).

## Probe (claude.ai Airtable connector, read-only)

- `list_tables_for_base`: one table `Events` (`tbljzD6weHWFP9YMz`), primary
  field `Run ID`, 17 fields with the declared types (`Key` formula,
  `Recorded At` createdTime).
- `get_table_schema`: `Trigger`, `Event`, `Outcome` hold every declared
  option. `Key` formula is `{Run ID} & "#" & {Seq}` (stored by field ID),
  `isValid: true`, result singleLineText.
- IDs are 17 characters: base `app...`, table `tbl...`, field `fld...`,
  record `rec...`.

## Guard (real hooks/guard.sh, sales-partner feat/ledger, scratch instance with these bindings)

| Call | Result |
|---|---|
| create_records_for_table, run_started event | allowed |
| update_records_for_table touching Event | blocked: `Event may not be changed after create` |
| update_records_for_table performUpsert on Run ID | blocked: `Run ID may not be changed after create` |
| create with `typecast: false` | blocked: `may not use typecast` |
| write `Key` field ID (computed; no binding line) | blocked: `is not a recorded field ID` |
| delete_records_for_table | blocked: `denied (*delete*)` |
| create_field | blocked: `denied (*create_field*)` |
| list_records_for_table | allowed |

- `schedule_check.py check` on the scratch instance: `PASS  sales-partner: digest`.

## Live write (operator approved)

- One append through the connector: record `recL9kjobY81sJA2O`, Run ID
  `interactive-20261013T1500Z`, Seq 1, Event `run_started`.
- `Key` computed `interactive-20261013T1500Z#1`.
- `Recorded At` 2026-10-13T15:53:51Z vs `At` 2026-10-13T15:00:00Z. The gap
  shows a back-dated `At` mechanically, as spec decision 9 intends.
- `list_records_for_table` filtered on `Run ID = interactive-20261013T1500Z`
  returned Seq 1. The read `append_events` uses to skip existing rows works
  on a text field with a plain string operand.

## Still open

- Filtering `find_events` on select fields needs choice IDs from
  `get_table_schema`, and filtering on `At` needs a date-value object (see
  the deferred minor on usage.md). Neither was exercised live.
- The test base keeps the one live row. Delete it by hand in Airtable if
  wanted; the agent cannot.
