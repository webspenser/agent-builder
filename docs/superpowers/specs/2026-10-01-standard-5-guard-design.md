# Agent Standard 5.0: agent guard policy, update-only forbid, Airtable known field IDs — design

Status: approved in conversation on 2026-09-30. This is the "standards topic" from the guard strictness review (`~/Work/Webspenser/briefs/2026-09-30-guard-strictness-review.md`).

## Goal

Close the review's gaps that are enforced by instruction alone today and that a guard engine feature can close:

1. Send and publish tools on connectors the instance never bound are unguarded in interactive runs. A hand-edited custom tool for a `no_send` capability with no `guard.yaml` is not blocked at call time.
2. An approved draft's body can be rewritten (`draft_body`, `Draft Body`, `hs_task_body` on update).
3. Airtable rules depend on two recorded field IDs. Every other `fld…` key passes unchecked, so a deleted and recreated `Status` field (new ID) is unguarded, and a missing ID blocks every write with a manual fix.
4. Small items: Gmail's `allow` list uses exact names; Attio allows three write tools no operation uses; a full-record update that echoes `do_not_contact: false` is blocked.

Out of scope (decided 2026-09-30): argument pinning (Gmail `to`, Airtable `baseId`, HubSpot `objectType`), HubSpot `only_fields`, compliance, the run-time re-gate. They stay in the roadmap.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | An optional, deny-only **agent guard policy** at the package root, `guard.yaml`, runs on every `mcp__` call inside an instance, whatever the server | Per-tool policies only fire when the call's server matches a bound tool, so an unbound Slack or social connector can't be stopped. The agent author owns the list; the operator can't weaken it. |
| 2 | The agent guard policy is required when any capability contract has a `no_send` invariant | It replaces the "custom `no_send` tool without `guard.yaml`" known gap: whatever tool is bound, the agent-wide send denies apply. |
| 3 | `forbid:` takes `true` (create and update) or `update` (update only) | Approved bodies must not be rewritten, while creating them stays allowed. |
| 4 | HubSpot `update_activity` no longer rewrites `hs_task_body`; the outcome goes to a new Note on the lead's company | Without this, `forbid: update` on `hs_task_body` would block voiding. |
| 5 | New guard policy key `bound_keys_only: true`: every key in a write map must be an ID recorded in a `field_<name>` binding | Turns Airtable from "check two known IDs" into an allowlist that fails closed on schema drift. Rejected alternative: matching by field name — the official Airtable connector refuses names (live test 2026-09-30: `Field ID must start with "fld" and be 17 characters long.`). |
| 6 | `binding_id:` is deleted from the grammar | With `bound_keys_only`, an unrecorded `Status` ID is an unknown key and blocks; `binding_id: required` adds nothing. |
| 7 | A `field_<name>` binding key may repeat; each line adds one ID | Airtable field names repeat across tables (`Lead`, `Email`, `Date`, …). The probe records every field of every table. |
| 8 | Start and setup run the Airtable probe on their own when `bindings/crm.md` has no `field_` lines | Removes the manual step the review flagged as too strict. |
| 9 | Agent Standard 5.0: builder 5.0.0, sales-partner 5.0.0, no git tags, CI keeps `validate@main` | Grammar change. Dev-phase rule: version numbers carry no compatibility meaning, no migration notes. |

Unchanged: `covers`, `allow`, `deny`, `writes`, `unwrap`, `unknown_writes`, `refuse_keys`, `rules` (other than `forbid` and `binding_id`), the tool layout, `tool_check.py`, activities and schedules.

## Part A — builder 5.0.0

### A1. Agent guard policy

**File.** `guard.yaml` at the agent package root. Optional, except as in A1 Validation.

```yaml
# guard.yaml — sales-partner agent guard policy
covers: [no_send]
deny: ["*send*", "*reply*", "*forward*", "*publish*", "*schedule_message*",
       "*cross_post*", "*posts_create*", "*bulk_upload_posts*", "*execute_write*"]
```

**Grammar.** The same strict YAML subset as a tool policy. Allowed keys: `covers` (optional, snake_case ids) and `deny` (required, non-empty list of tool-name globs). Any other key is a parse error, including `allow`, `writes` and `rules`.

**Engine.** `guard_policy.py --agent <guard.yaml> [label]`, hook input on stdin. Candidate names are every suffix after `mcp__` that follows a `__` (Semantics 1), with no `server_match`: every suffix counts. A `deny` pattern matching any candidate blocks with `<tool> is denied (<pattern>)`. `--check --agent <guard.yaml>` parses only.

**Hook.** In `guard.sh`, once the call is known to be an `mcp__` call inside this agent's instance (after the instance and `agent:` checks, before the `bind_` loop): if `$root/guard.yaml` exists (or is a dangling symlink), run the engine with `--agent` and label `<agent> agent guard policy`. Exit 2 blocks; any other nonzero exit, a missing engine or a missing `python3` blocks (`pblock`-style message naming the agent policy). Then the `bind_` loop runs as today. Outside an instance nothing changes: everything is allowed.

**Validation.** `validate-agent.sh`:
- if `guard.yaml` exists at the root, it must pass `--check --agent`;
- if any `capabilities/*/contract.md` lists a `no_send` invariant, root `guard.yaml` must exist and its `covers` must include `no_send`;
- the instance gate (`schedule_check.py check`) treats a `no_send` capability as unattended-safe only when the agent policy covers `no_send` (in addition to today's per-tool checks).

**Stated limit.** Globs match names, not behaviour. A connector whose send tool has an unusual name (for example a generic `execute_write`) is caught only if the author lists it. The scheduled-run connector restriction (`verify`) stays the strongest control for scheduled runs.

**Known gap paragraph** in STANDARD.md (Guard hook) is replaced: a custom tool bound to a `no_send` capability is covered by the agent policy's deny list; its own `guard.yaml` is still required by `add-tool`, `tool_check.py` and the gate.

### A2. `forbid: update`

Grammar: `forbid:` takes `true` or `update`. Either form is never combined with `create`, `update` or `any`. Semantics 4 becomes:

- `forbid: true` blocks any write of the field, on create or update (`<field> may not be written`);
- `forbid: update` blocks a write of the field in a map tagged `update` (including unknown writes checked as update): `<field> may not be changed after create`. Create maps are not checked by the rule.

Other fields in the same map are still checked by their own rules.

### A3. `bound_keys_only` and field bindings

**Key.** `bound_keys_only: true` (the only allowed value). Requires `writes`. Parse error without `writes`.

**Bindings.** `bindings/<capability>.md` may hold several lines with the same `field_<name>` key; each adds one ID to that name. The engine reads bindings into `field_<name> → set of IDs`. Non-`field_` keys keep the last value, as today. Line format, the bare-ID check and the backtick/quote stripping are unchanged.

**Semantics** (new step between Refused keys and Field identity):

- With `bound_keys_only: true`, every key in every collected write map (create, update or unknown) must equal, ignoring case, an ID in some `field_<name>` set. Otherwise: `<key> is not a recorded field ID; re-run the probe (setup's tools step)`. Invisible-character keys still raise first.
- With no `field_` lines at all, every write with a non-empty map is blocked with `the probe has not recorded any field IDs in bindings; re-run setup's tools step`.

**Field identity** (Semantics 6) becomes: a rule for `<field>` matches the key `<field>` (normalized) and every ID recorded under `field_<normalized field>`. `binding_id:` is removed from Grammar, Keys and Semantics; it is now an unknown key and a parse error.

A rule whose field name repeats across tables matches every one of them (for example a `Status` field in two tables would both be ruled). This fails closed and is documented.

### A4. Docs and tests

- STANDARD.md: Guard policy (Grammar, Keys, Semantics, Parse errors, Field identity), a new "Agent guard policy" subsection, Guard hook, Validation, `standard: "5.0"` in the manifest example.
- `_template/`: no root `guard.yaml` (it is optional); `_capability-template` unchanged except a comment if it mentions `binding_id`.
- `docs/how-it-works.md`: the agent-wide deny list, update-only forbid, Airtable known-IDs rule. Same PR.
- `docs/writing-an-agent.md`: when to ship a root `guard.yaml`.
- Tests (`tests/`): engine `--agent` deny, parse errors (extra keys, empty deny); `guard.sh` runs the agent policy for an unbound server and a bound one, blocks on engine failure, ignores it outside an instance; `forbid: update` passes on create and blocks on update and on unknown writes; `bound_keys_only` passes recorded IDs, blocks an unrecorded `fld…` key, blocks with no `field_` lines, accepts repeated `field_` keys; `binding_id` is a parse error; validator requires the agent policy for a `no_send` contract.

## Part B — sales-partner 5.0.0

### B1. Agent guard policy

Root `guard.yaml` as in A1. Before committing, check the list against the connectors in use (Gmail, Slack, Attio, Airtable, HubSpot, Notion, Zernio, Beehiiv, Loops, Linear, ClickUp): no read tool may match. Known non-matches checked 2026-09-30: Attio `list-comment-replies` (`replies` ≠ `reply`), Beehiiv `list_publications`/`get_publication` (`publication` ≠ `publish`).

### B2. CRM guard policies

- Attio: drop `create-note`, `create-task`, `update-task` from `allow`; add `- field: draft_body` / `forbid: update`.
- Airtable: delete both `binding_id: required` lines; add `bound_keys_only: true`; add `- field: Draft Body` / `forbid: update`.
- HubSpot: add `- field: hs_task_body` / `forbid: update`.

### B3. HubSpot `update_activity`

Reject a `status` other than `voided`. Update the Task with `hs_task_status: DEFERRED` only. When an `outcome` is given, create a Note (`hs_note_body: <p>Outcome for task <activity_id>: <outcome></p>`, `hs_timestamp`) associated with the lead's Company. Reads that report a voided activity's outcome (`get_lead`) take it from the newest Note whose body starts `Outcome for task <activity_id>:`. The "only write this tool makes to an existing Task" sentence stays true.

### B4. Airtable probe

- Probe step 2 records `field_<normalized name>: <ID>` for **every field of the four tables**, one line each, from the single `list_tables_for_base` call. Repeated names get repeated lines.
- `## Guard policy` in usage.md: rewritten for known IDs only, update-only `Draft Body`, and the stale-ID behaviour (a recreated field is blocked until a re-probe).
- `skills/start` and `skills/setup`: when `bind_crm: airtable` and `bindings/crm.md` has no `field_` lines, run the probe before anything that writes, and say so in one line.

### B5. Gmail and small docs

- Gmail `allow`: `["*create_draft", "*list_drafts", "*get_draft", "*search_threads", "*get_thread", "*get_message", "*list_labels"]`; `deny` unchanged. Remove the "add its names to `allow`" advice from GM/usage.md.
- Each CRM usage.md: "write only the fields that change" on updates (the `do_not_contact: false` echo).

### B6. Release

`agent.yaml` `version: 5.0.0`, `standard: "5.0"`; the three host manifests; README version line. `tests/test-policies.sh` cases for B1–B5. No migration notes.

## Order

1. Builder PR (Part A). Merge.
2. Sales-partner PR (Part B), CI against `validate@main`. Merge.
3. Update memory (roadmap status) and how-it-works if anything moved during review.

## Acceptance

- Builder and sales-partner CI green.
- In a scratch instance: a Slack `slack_send_message` call (unbound server) is blocked by the agent policy; an Airtable write with an unrecorded `fld…` key is blocked; an Attio `draft_body` update is blocked; a HubSpot void writes `DEFERRED` plus a Note and passes. Guard tests drive these through `guard.sh` with fixture hook input; no live connector calls are needed.
