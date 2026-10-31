# Optional Capabilities per Activity (Standard 7.4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an activity name capabilities it uses only when bound, so a scheduled run passes the gate without them and is fully guarded with them.

**Architecture:** A new flat `agent.yaml` key `optional_<activity>` lists optional capabilities. The validator checks it; `schedule_check.py`'s gate skips an unbound optional capability and treats a bound one exactly like a required one. `verify` needs no change (connectors already follow bindings). The guard needs no change. Standard moves to 7.4; builder releases 7.4.0.

**Tech Stack:** bash, python3 (stdlib), the repo's own test scripts (`tests/*.sh`, `tests/lib.sh`).

**Spec:** `/Users/hochoy/Work/Webspenser/sales-partner/docs/superpowers/specs/2026-10-31-exa-decision-maker-search-design.md`, section "Optional capabilities (agent-builder change)".

## Global Constraints

- Key form (spec, my call approved): `optional_<activity>: <cap>[, <cap>...]` next to `activity_<activity>`.
- An optional capability is never also listed in the same activity's `activity_<activity>`.
- Unbound optional: gate passes as if unlisted; `check` prints it as `optional, not bound`; no connector expected; `verify` still refuses a connector matching no bound `server_match`.
- Bound optional: identical rules to a required capability (all invariants covered, connector attached).
- Guard (`_template/hooks/guard.sh`) is not changed.
- Standard `"7.4"`; builder version `7.4.0` in the three builder manifests.
- Branch `feat/optional-capabilities` from `main`; PR into `main`; this PR merges before the sales-partner PR.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- `optional_x` with no `activity_x`: validator must fail, not silently ignore (Task 1 test `opt-orphan`).
- A capability in both `activity_x` and `optional_x`: validator fails (Task 1 test `opt-both`).
- An optional capability bound but its tool's guard leaves an invariant uncovered: the entry must FAIL, same message as required (Task 2 test "bound optional, uncovered invariant").
- A `then_` chain where the second activity has the optional capability: gate applies it (Task 2 test "optional via then_").
- An unbound optional capability whose connector is attached anyway: `verify` reports MISMATCH (Task 2 test "unbound optional, extra connector").

---

### Task 1: Validator accepts and checks `optional_<activity>`; Standard 7.4

**Files:**
- Modify: `bin/lib/check_manifests.py` (`CURRENT_STANDARD` at :24; `check_activities` at :329-362)
- Modify: `_template/agent.yaml` (`standard: "7.4"`), `tests/run-all.sh:27` (expects 7.4)
- Modify: every test fixture that writes `standard: "7.3"` (`tests/test-guard.sh:11`, `tests/test-schedule-check.sh:11,415,445`, `tests/test-validate-agent.sh:20,132,144,532-535`) to `"7.4"`; the old-standard cases become `7.3` must be `"7.4"`
- Test: `tests/test-validate-agent.sh` (new cases after :555)

**Interfaces:**
- Produces: `check_activities(root, meta, caps)` also validates `optional_*` keys. Exact failure strings below; Task 3 documents them.

- [ ] **Step 1: Write the failing tests** (after the `act-empty` case, same helpers `make_valid_agent`, `fails_with`, and the copied `skills/schedule`):

```bash
make_valid_agent "$FIX/opt"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: webspenser/agent-library' 'activity_prepare: crm' 'optional_prepare: scraping' >> "$FIX/opt/agent.yaml"
# make_valid_agent already writes a capabilities: line: edit that line to "crm, scraping" (sed), never append a second one, and add a scraping capability folder copied from crm
passes "$FIX/opt"
# opt-orphan: optional_prepare without activity_prepare
fails_with "$FIX/opt-orphan" "agent.yaml: optional_prepare has no activity_prepare"
# opt-both: optional_prepare: crm while activity_prepare: crm
fails_with "$FIX/opt-both" "agent.yaml: optional_prepare lists crm, which activity_prepare already requires"
# opt-unknown: optional_prepare: calendar
fails_with "$FIX/opt-unknown" "agent.yaml: optional_prepare uses calendar, which is not in capabilities"
# opt-none: optional_prepare: none
fails_with "$FIX/opt-none" "agent.yaml: optional_prepare may not list none"
# opt-empty: optional_prepare:
fails_with "$FIX/opt-empty" "agent.yaml: optional_prepare lists no capabilities"
# opt-dup: two optional_prepare lines
fails_with "$FIX/opt-dup" "agent.yaml: optional_prepare is declared more than once"
```

Use the file's existing fixture idiom for each (one `make_valid_agent` + `printf >> agent.yaml` + copy `skills/schedule`). If `passes` does not exist, use the file's existing success assertion.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-validate-agent.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: the seven new cases fail; nothing else does.

- [ ] **Step 3: Implement in `check_activities`**

Collect `optional_*` keys the same way as `activity_*` (including the raw-line duplicate scan, extended to `optional_` keys). For each `optional_<act>`: `<act>` must be an `activity_` key; names non-empty; `none` not allowed; each name in `caps`; no name in that activity's required list. Messages exactly as in Step 1.

- [ ] **Step 4: Bump the Standard**

`CURRENT_STANDARD = "7.4"`; `_template/agent.yaml` and `tests/run-all.sh:27` to 7.4; fixtures to `"7.4"`; the two old-standard cases assert `must be "7.4"` (and add a `7.3` one).

- [ ] **Step 5: Run the validator tests**

Run: `bash tests/test-validate-agent.sh 2>&1 | tail -1`
Expected: `-- N passed, 0 failed`

- [ ] **Step 6: Commit** `feat(validator): optional_<activity> capabilities; Standard 7.4`

---

### Task 2: Schedule gate skips unbound optional capabilities

**Files:**
- Modify: `_template/hooks/schedule_check.py` (activity parsing in `expected()` ~:338; capability loop :396-494; `_text()` ~:651)
- Test: `tests/test-schedule-check.sh`

**Interfaces:**
- Consumes: `optional_<act>` key format from Task 1.
- Produces: each entry dict gains `"optional": [cap, ...]` (all optional caps in the chain) and `"optional_unbound": [cap, ...]`; `_text()` prints `  optional, not bound: <cap>, <cap>` under a PASS or FAIL entry when non-empty. `--json` carries both keys.

- [ ] **Step 1: Write the failing tests** (new section `echo "-- optional capabilities"`; the test package's `agent.yaml` gains `optional_prospect: email_drafts`; instances made with the existing `instance` helper):

```bash
# unbound optional passes and is reported
OU="$W/optunbound"; instance "$OU" good - 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$OU";  expect 0 "unbound optional: passes" "PASS  demo-agent: prospect (optunbound)"
expect 0 "unbound optional: shown" "optional, not bound: email_drafts"
expect 0 "unbound optional: no connector listed" 'connectors: good (matches "goodcrm")'
# bound optional needs connector and coverage like required
OB="$W/optbound"; instance "$OB" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$OB";  expect 0 "bound optional: listed as a connector" 'mail (matches "mail")'
# bound optional, uncovered invariant fails like required (point bind_email_drafts at a tool whose guard.yaml does not cover no_external_send)
expect 1 "bound optional, uncovered invariant" "email_drafts: invariant no_external_send is not covered"
# optional via then_: schedule_research with then_research: prospect picks up prospect's optional cap
expect 0 "optional via then_" "optional, not bound: email_drafts"
# verify: unbound optional, connector attached anyway -> MISMATCH (reuse the file's routine-JSON helper)
expect 1 "unbound optional, extra connector" "matches no bound server_match"
# repeated optional key fails entries using it
expect 1 "repeated optional key" "agent.yaml declares optional_prospect more than once"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-schedule-check.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: the new cases fail; existing ones pass.

- [ ] **Step 3: Implement**

Parse `optional_*` alongside `activities` (with the same duplicate detection that produces `agent.yaml declares <key> more than once`). In the entry loop, build the chain's capabilities with an optional flag (required wins if a cap is required by any activity in the chain). In the per-cap loop, an optional cap with no binding is appended to `optional_unbound` and skipped (no problem, no connector); a bound one runs the existing body unchanged. Add the `_text()` line.

- [ ] **Step 4: Run the checker tests and the whole suite**

Run: `bash tests/test-schedule-check.sh 2>&1 | tail -1 && bash tests/run-all.sh 2>&1 | tail -1`
Expected: `0 failed` and `ALL GREEN`

- [ ] **Step 5: Commit** `feat(schedule): optional capabilities pass the gate unbound`

---

### Task 3: Document 7.4 and release builder 7.4.0

**Files:**
- Modify: `STANDARD.md` (:14,:17,:235,:1546 → 7.4; "Activities and schedules" after :1353; "The unattended gate" list; "Validation" list near :1606)
- Modify: `_template/skills/setup/SKILL.md` step 9 (tools) and sub-step 7
- Modify: `_template/skills/schedule/SKILL.md` step 3 (gate) one line
- Modify: `docs/how-it-works.md` (:7 versions, :210 "standard 7.4")
- Modify: `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json` → `7.4.0`; `tests/test-builder-manifests.sh:18` → `7.4.0`

- [ ] **Step 1: STANDARD.md**

Add under Activities: `optional_<activity>` (flat key, names from `capabilities`, never `none`, never a capability the activity requires, needs its `activity_<activity>`); the gate rules for unbound and bound optional capabilities (Global Constraints, verbatim meaning); skills using an optional capability check the binding first and skip the step when unbound. Add the six validator messages from Task 1 to the Validation list. Version strings to 7.4.

- [ ] **Step 2: Setup skill**

Step 9, sub-step 1: when the capability is listed only in `optional_*` keys, first ask whether the business uses such a system; on no, bind nothing for it and continue with the next capability. Sub-step 7: an optional capability left unbound is fine for scheduled runs. Apply the identical wording in sales-partner's copy later (sales-partner plan, Task 1).

- [ ] **Step 3: Schedule skill** — step 3: `optional, not bound` lines are informational, not problems.

- [ ] **Step 4: Release bump and full suite**

Run: `bash tests/run-all.sh 2>&1 | tail -1`
Expected: `ALL GREEN`

- [ ] **Step 5: Commit, push, PR**

Commit `docs: optional capabilities (Standard 7.4, builder 7.4.0)`. Push `feat/optional-capabilities` over HTTPS with `gh auth git-credential` (SSH to webspenser repos drops), open the PR, and stop for the user to merge.
