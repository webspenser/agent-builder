# Ledger contract

The agent's record of what it did, in a store the business owns: one
standard `Events` table, the same for every agent, plus tables the agent
declares in `tables.md` for state it reads back between runs. Skills and
sub-agent contracts call these operations, never a provider's tools.

## Operations

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `ledger_status` | none | the bound `ledger_schema` and the package's | A mismatch, or no `bindings/ledger.md`: in a scheduled run the activity stops and calls `notify_owner(kind: error)`; in an interactive run it reports and offers to run setup |
| `append_events` | `events[]`, each with `run_id`, `seq`, `at`, `activity`, `trigger`, `event`, plus any of `subject`, `outcome`, `items_in`, `items_out`, `cost_usd`, `duration_s`, `detail`, `agent_version`, `backfilled` | the number of rows written | Rejects an event missing `run_id`, `seq`, `at`, `activity`, `trigger` or `event`; skips any `run_id` + `seq` already present; writes in `seq` order |
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
is an instruction; no guard can check it. Write `stop_condition`,
`notify_sent` and `error` events when they happen.

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
| `ledger_status` mismatch or no bindings | Report; offer to run setup | Stop the activity; `notify_owner(kind: error)` |

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
