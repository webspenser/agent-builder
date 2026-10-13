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
