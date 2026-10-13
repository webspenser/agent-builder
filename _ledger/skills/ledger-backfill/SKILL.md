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
