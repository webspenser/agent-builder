# sales-partner 6.0.0 (Outbound Enrollment) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Part B of the outbound enrollment design: sales-partner 6.0.0 with the `Ready to Send` stage, a `sequences` capability wrapping InvokeIQ in n8n, scheduled `enroll` and `sync-replies` activities, and an n8n reply relay for Attio.

**The user's own stack (live tests run against these):** Attio CRM, InvokeIQ cold email, Loops warm email (Loops is out of scope here). HubSpot and Airtable stay supported because other businesses use them.

**Architecture:** The lead stage carries the plan (`Approach Drafted` → `Ready to Send`, human-only, → `Contacted`); Activities carry touches (`draft` → `sent`/`voided`). A new `sequences` capability has one tool, `invokeiq`, wrapped in an n8n MCP workflow (`wrapper: n8n`, n8n OAuth2). Two new skills run as scheduled activities: `enroll` (Ready-to-Send leads → InvokeIQ campaign by score band) and `sync-replies` (relay-written inbound Activities → stage, Do Not Contact, suppression). An n8n webhook relay records InvokeIQ replies and bounces as inbound Activities.

**Tech Stack:** Markdown agent package (skills, sub-agent contracts, tool `usage.md`), YAML guard policies, Python 3 stdlib bootstrap scripts, n8n workflows built through the connected n8n MCP and exported to JSON, plain-bash tests.

**Spec:** `docs/superpowers/specs/2026-10-01-outbound-enrollment-design.md` (Part B; decisions 1–16, 18; amendments of 2026-10-03: n8n OAuth2 on the trigger)

## Global Constraints

- Repo `~/Work/Webspenser/sales-partner`, new branch `feat/standard-6` from `main`. Hooks and `skills/add-tool/SKILL.md` are copied byte-identical from agent-builder's `feat/standard-6` branch (`_template/`).
- `agent.yaml`: `version: 6.0.0`, `standard: "6.0"`; host manifests and README match.
- `AGENT.md` stays under the 9000-byte inline limit (now 8473 bytes): trim to make room.
- No backward compatibility, no migration notes.
- No secrets in the repo. Workflow exports keep credential **names** only; strip credential `id`s, `webhookId`s and the instance's workflow `id` before committing.
- Merge order: agent-builder PR #19 first, then this PR right after (its CI uses `validate@main`, which only accepts `"6.0"` once #19 is merged). The user approves both merges.
- Edit files with scripted edits (`python3` read/replace/write) or `sed -i ''`; the Edit tool resets file modes (it stripped the executable bit twice during 6.0 builder work). Check `git diff --summary` for mode changes before each commit.

## Decisions this plan makes (flagged for the user at handoff)

1. `enroll` and `sync-replies` are **skills** (like `send-digest`), not sub-agent contracts: each is one bounded procedure with no judgement calls that need isolation, and skills need no manifest changes.
2. The reply relay ships for **Attio only** in 6.0.0 (the user's CRM, the one the acceptance runs on). `usage.md` documents exactly what any relay must write, so HubSpot and Airtable relays follow the same recipe later (or as done-for-you setup).
5. **Checkpoint before Task 6:** Tasks 6, 7 and 9 add to `AGENT.md`, which is near its inline limit. Execution stops after Task 5 for a discussion with the user about streamlining the agent as a whole: how it is positioned, how behaviours are defined, and how to keep the main context small (more in sub-agent contracts and skills, less in `AGENT.md`). Tasks 6 to 9 are revised from that discussion before they run.
3. A bounce is recorded only as the relay's inbound Activity (summary `bounced`); the Approacher never reuses an email address that has a `bounced` Activity. No new contact field.
4. Inbound Activities the agent logs itself (LinkedIn replies, call debriefs) keep today's `draft` status; only the relay writes inbound Activities at `sent` (it writes through n8n, outside the guard).

## Review Focus

1. **A lead at `Ready to Send` whose only email Activity was voided by the owner** — `enroll` must not enroll it, and must not move it to `Contacted` unless a LinkedIn/call touch was marked `sent`. Pinned in Task 6.
2. **The owner drags a lead back to `Approach Drafted` after `enroll` already ran** — nothing to undo automatically; the digest shows it as enrolled and the owner pauses it in InvokeIQ. Pinned in Task 6 (skill text) and Task 9 (how-it-works line).
3. **A personalization draft missing one of the `variables:` names, or carrying an extra label** — `enroll` refuses that lead and reports it rather than enrolling with a blank merge field. Pinned in Task 6.
4. **The same reply delivered twice by the webhook** (n8n retries) — `sync-replies` actions are idempotent: no double stage move, one suppression call is harmless. Pinned in Task 7.
5. **`allowed_countries` lists `CA` or an EU country without the operator's note/basis recorded** — `enroll` treats the country as not allowed and reports why. Pinned in Task 6.

---

### Task 1: Branch, 6.0 hooks, version

**Files:**
- Modify: `hooks/guard.sh`, `hooks/guard_policy.py`, `hooks/schedule_check.py`, `hooks/tool_check.py`, `skills/add-tool/SKILL.md` (copies), `agent.yaml`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`, `README.md`, `tests/test-content.sh`

- [ ] **Step 1: Branch and copy.**

```bash
cd ~/Work/Webspenser/sales-partner && git checkout main && git pull -q && git checkout -b feat/standard-6
B=~/Work/Webspenser/agent-builder; git -C $B checkout -q feat/standard-6
for f in guard.sh guard_policy.py schedule_check.py tool_check.py; do cp $B/_template/hooks/$f hooks/$f; done
cp $B/_template/skills/add-tool/SKILL.md skills/add-tool/SKILL.md
```

- [ ] **Step 2: Version.** `agent.yaml` `version: 6.0.0`, `standard: "6.0"`; `"version": "6.0.0"` in the three host manifests; README `Version 6.0.0.`; `tests/test-content.sh` line asserting `standard: "5.0"` → `"6.0"`.

- [ ] **Step 3: Verify and commit.**

Run: `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`; `~/Work/Webspenser/agent-builder/bin/validate-agent.sh . | tail -1` → `OK: . conforms`.

```bash
git add -A && git commit -m "chore: Standard 6.0 hooks; sales-partner 6.0.0"
```

### Task 2: Contract — `Ready to Send`, `sent`, restated `draft_only`

**Files:**
- Modify: `capabilities/crm/contract.md` (Operations notes for `log_activity`/`update_activity`, Approval invariant, Invariants, Stage enum, Stage transitions), `AGENT.md` ("twelve lead stages" → "thirteen"), `evals/cases.md`
- Test: `tests/test-content.sh`

**Interfaces:**
- Produces: stage list (13, in order) `New, Scored, Researched, Approach Drafted, Ready to Send, Contacted, Replied, Call Scheduled, Call Held, Following Up, Won, Lost, Disqualified`; Activity statuses `draft, sent, voided`; `update_activity` accepts `status: sent` or `voided`.

- [ ] **Step 1: Failing content tests.** Append before `finish` in `tests/test-content.sh`:

```bash
echo "-- 6.0.0: Ready to Send and sent"
K="$SP/capabilities/crm/contract.md"
assert_contains "$K" 'Approach Drafted
Ready to Send
Contacted'
assert_contains "$K" 'A lead occupies exactly one of these thirteen stages'
assert_contains "$K" '| `Ready to Send` |'
assert_contains "$K" 'only the operator writes `Ready to Send`'
assert_contains "$K" 'the only statuses it may later write are `sent` and `voided`'
assert_not_contains "$K" '`approved`'
assert_not_contains "$SP/AGENT.md" 'twelve lead stages'
assert_contains "$SP/AGENT.md" 'thirteen lead stages'
assert_not_contains "$SP/evals/cases.md" 'approved'
```

(`assert_contains` uses `grep -F`; for the multi-line stage-order check, if `grep -F` with embedded newlines matches any one line, replace that case with: `python3 -c "import sys; t=open('$K').read(); sys.exit(0 if 'Approach Drafted\nReady to Send\nContacted' in t else 1)" && _report ok "stage order" || _report no "stage order"`.)

Run: `bash tests/test-content.sh 2>&1 | grep -E "^  FAIL"` → the new cases fail.

- [ ] **Step 2: Rewrite the contract.**
  - Stage enum: thirteen stages, `Ready to Send` after `Approach Drafted`; "A lead occupies exactly one of these thirteen stages". Terminal stages unchanged.
  - Stage transitions table: `Approach Drafted` exits to `Ready to Send` ("the operator approves the whole plan by moving the lead; nothing is approved draft by draft"); new row `| \`Ready to Send\` | The operator moves the lead here once every standing draft and its date are right — only the operator writes \`Ready to Send\` | \`enroll\` enrolls the email touch and moves it to \`Contacted\`; a LinkedIn or call touch the operator marks \`sent\` also moves it to \`Contacted\`; the operator moving it back to \`Approach Drafted\` cancels |`; `Contacted` enters when "the first touch actually went out on any channel".
  - Approval invariant (rewrite the bullet list): the agent creates Activities only at `draft`; it may update an Activity only to `sent` or `voided`; it never rewrites a draft body after create; it never writes the stage `Ready to Send`. "Therefore no sequence of operations approves a plan: only the operator's move to `Ready to Send` does." Keep the Do Not Contact paragraph.
  - `log_activity` notes: accepts only `status: "draft"`. `update_activity`: accepts `sent` or `voided`; rejects `draft`; `outcome` optional.
  - Invariants: `draft_only` — "the agent creates Activities only at `status: draft`, the only statuses it may later write are `sent` and `voided`, and only the operator writes `Ready to Send` (see Approval invariant)".
  - Remove every `approved`. In `evals/cases.md`, replace approval-by-status cases with the stage-based equivalent (the operator moves the lead to `Ready to Send`).
  - `AGENT.md`: "The twelve lead stages" → "The thirteen lead stages".

- [ ] **Step 3: Verify and commit.** `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`.

```bash
git add -A && git commit -m "feat: plans are approved by moving the lead to Ready to Send; Activities go draft to sent or voided"
```

### Task 3: CRM tools — stage option, statuses, guard rules, views

**Files:**
- Modify: `capabilities/crm/tools/{attio,airtable,hubspot}/{usage.md,guard.yaml}`, `capabilities/crm/tools/attio/bootstrap.py`, `capabilities/crm/tools/hubspot/bootstrap.py`
- Test: `tests/test-policies.sh`, `tests/test-content.sh`

**Interfaces:**
- Consumes: Task 2's stage list and statuses.
- Produces: guard rules `stage`/`Stage`/`sp_stage` (create `[New]`, update every stage except `Ready to Send`) and status rules (create `[draft]`, update `[sent, voided]`; HubSpot `[COMPLETED, DEFERRED]`).

- [ ] **Step 1: Failing policy tests.** Add to each CRM section of `tests/test-policies.sh` (use each section's variables; Airtable needs a `field_stage` line in its bindings fixture):

```bash
# Attio
check 2 "agent can't approve a plan"  $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"stage\":\"Ready to Send\"}}" "stage may only be written as"
check 0 "agent moves to Contacted"    $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"stage\":\"Contacted\"}}"
check 0 "agent returns lead to Approach Drafted" $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"stage\":\"Approach Drafted\"}}"
check 2 "lead created past New"       $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"stage\":\"Scored\"}}" "stage may only be written as New on create"
check 0 "agent marks a touch sent"    $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"status\":\"sent\"}}"
check 2 "agent can't revive a draft"  $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"status\":\"draft\"}}"
# Airtable (add 'field_stage: fldSTAGEEEEEEEEEE' to the $W/b.md fixture)
check 2 "agent can't approve a plan"  $AR ${A}update_records_for_table "{$B,\"records\":[{\"id\":\"recRRRRRRRRRRRRRR\",\"fields\":{\"fldSTAGEEEEEEEEEE\":\"Ready to Send\"}}]}" "Stage may only be written as" "$W/b.md"
check 0 "agent marks a touch sent"    $AR ${A}update_records_for_table "{$B,\"records\":[{\"id\":\"recRRRRRRRRRRRRRR\",\"fields\":{\"fldSSSSSSSSSSSSSS\":\"sent\"}}]}" "" "$W/b.md"
# HubSpot
check 2 "agent can't approve a plan"  $HS ${H}manage_crm_objects '{"updateRequest":{"objects":[{"objectType":"companies","objectId":202,"properties":{"sp_stage":"Ready to Send"}}]}}' "sp_stage may only be written as"
check 0 "agent marks a task completed" $HS ${H}manage_crm_objects "{\"updateRequest\":{\"objects\":[$(printf "$TU" '"hs_task_status":"COMPLETED"')]}}"
```

Replace the existing expectations that `COMPLETED`/`sent` on update is blocked (HubSpot "update task COMPLETED", Attio/Airtable equivalents) with the new allowed behaviour.

Content tests (append to `tests/test-content.sh`):

```bash
for t in attio airtable hubspot; do assert_contains "$SP/capabilities/crm/tools/$t/usage.md" 'Ready to Send'; assert_not_contains "$SP/capabilities/crm/tools/$t/usage.md" 'approved'; done
grep -q '"Ready to Send"' "$SP/capabilities/crm/tools/attio/bootstrap.py" && _report ok "attio bootstrap has Ready to Send" || _report no "attio bootstrap lacks Ready to Send"
grep -q '"Ready to Send"' "$SP/capabilities/crm/tools/hubspot/bootstrap.py" && _report ok "hubspot bootstrap has Ready to Send" || _report no "hubspot bootstrap lacks Ready to Send"
```

Run both test files → new cases fail.

- [ ] **Step 2: Guard policies.** Append to each `rules:` (field name per CRM: Attio `stage`, Airtable `Stage`, HubSpot `sp_stage`):

```yaml
  - field: stage
    create: [New]
    update: [New, Scored, Researched, "Approach Drafted", Contacted, Replied, "Call Scheduled",
             "Call Held", "Following Up", Won, Lost, Disqualified]
```

Status rules: Attio `status` update `[sent, voided]`; Airtable `Status` update `[sent, voided]`; HubSpot `hs_task_status` update `[COMPLETED, DEFERRED]`.

- [ ] **Step 3: Bootstraps.** Insert `"Ready to Send"` after `"Approach Drafted"` in both `STAGES` lists; Attio status options `["draft", "sent", "voided"]`. The HubSpot bootstrap already patches missing enum options (`to_patch`), so an existing portal gains the option on the next run.

- [ ] **Step 4: usage.md, all three.** Stage tables say "the thirteen stages" and list `Ready to Send`; status `draft, sent, voided` (HubSpot: `NOT_STARTED` = draft, `COMPLETED` = sent, `DEFERRED` = voided; remove `IN_PROGRESS`/`WAITING` as statuses the agent reads — the operator may still use them, and the agent treats them like `NOT_STARTED`); `update_activity` maps `sent` too; Views: replace "Awaiting Approval" (Activities at draft) with **Review** (leads at `Approach Drafted`, with their draft Activities), add **Ready to Send** (leads at that stage) and **My touches** (draft LinkedIn and call Activities on `Ready to Send`/`Contacted` leads, sorted by date); `## Setup` stage option lists gain `Ready to Send`; guard policy prose matches Step 2.

- [ ] **Step 5: Verify and commit.** `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`.

```bash
git add -A && git commit -m "feat: CRM tools add Ready to Send (agent can't write it), drop approved, let the agent mark touches sent"
```

### Task 4: `sequences` capability, InvokeIQ tool, n8n workflow

**Files:**
- Create: `capabilities/sequences/contract.md`, `capabilities/sequences/tools/invokeiq/{identity.yaml,usage.md,guard.yaml,workflow.n8n.json}`
- Modify: `agent.yaml` (`capabilities: crm, email_drafts, sequences`), root `guard.yaml` (dispatcher denies), `tests/test-policies.sh`

**Interfaces:**
- Produces: contract operations `get_workspace`, `get_campaigns`, `enroll_contact(band, email, first_name, last_name, variables)`, `suppress(emails, reason)`; MCP tools `invokeiq:get_workspace`, `invokeiq:get_campaigns`, `invokeiq:enroll_contact`, `invokeiq:suppress`; invariants `no_send`, `campaigns_bound_only`, `no_campaign_control`, `enroll_ready_only (acceptable)`; bindings `bindings/sequences.md` keys `workspace`, `variables`.

- [ ] **Step 1: Failing tests.** Append to `tests/test-policies.sh` (agent policy section):

```bash
for t in execute_workflow test_workflow create_workflow_from_code update_workflow archive_workflow publish_workflow unpublish_workflow restore_workflow_version; do
  acheck 2 "n8n dispatcher denied: $t" "mcp__claude_ai_N8N_Webspenser_Newsletter__$t"
done
for t in get_workspace get_campaigns enroll_contact suppress; do acheck 0 "InvokeIQ tool passes the agent policy: $t" "mcp__invokeiq__$t"; done
IQ=capabilities/sequences/tools/invokeiq/guard.yaml
check 0 "enroll allowed"   $IQ mcp__invokeiq__enroll_contact '{"band":"high","email":"a@b.c"}'
check 2 "unknown tool"     $IQ mcp__invokeiq__create_campaign '{}' "is not in the allow list"
python3 -B hooks/tool_check.py capabilities/sequences/tools/invokeiq capabilities/sequences/contract.md >/dev/null && _report ok "invokeiq tool passes tool_check" || _report no "invokeiq tool fails tool_check"
```

Run → fails (files missing).

- [ ] **Step 2: Contract.** `capabilities/sequences/contract.md` with `## Operations` (the four, arguments and returns as in the spec's B2 table) and `## Invariants`:

```markdown
- `no_send` — no operation sends; enrollment hands the lead to a campaign the client set up and launched in the platform.
- `campaigns_bound_only` — enrollment reaches only the client's band campaigns: the agent passes a band, and the platform tool maps bands to campaigns.
- `no_campaign_control` — the agent never creates, launches, pauses or edits a campaign; the tool has no such operation.
- `enroll_ready_only` (acceptable) — only leads at `Ready to Send`, not Do Not Contact, in an allowed country, never enrolled before. No guard can check this: it depends on the lead's state in the CRM.
```

- [ ] **Step 3: Tool files.** `identity.yaml`:

```yaml
capability: sequences
provider: invokeiq
server_match: invokeiq
wrapper: n8n
```

`guard.yaml`:

```yaml
# InvokeIQ through the "Webspenser · InvokeIQ" n8n workflow: four tools, nothing else.
covers: [no_send, campaigns_bound_only, no_campaign_control]
allow: [get_workspace, get_campaigns, enroll_contact, suppress]
```

`usage.md`: map each operation to `invokeiq:<tool>` with its arguments; `## Probe` (`invokeiq:get_workspace` → record `workspace: <id>`; `invokeiq:get_campaigns` → show each band's campaign, warn if not active; `variables:` comes from the interview); `## Setup` — import `workflow.n8n.json` into n8n; create a **new** HTTP Bearer credential for InvokeIQ in n8n holding the client's `ivq_live_…` key (n8n silently reuses an existing credential of the same type otherwise); set the band map in the `enroll_contact` node; set the trigger's Authentication to **n8n OAuth2**; **Publish** (Save alone does not change the live workflow); add the trigger's Production URL as a connector named `invokeiq` (claude.ai: Settings → Connectors → Add custom connector, approve the n8n login); then the reply relay (Task 8).

- [ ] **Step 4: Build the workflow in n8n and export it.** Use the connected n8n MCP (read `get_workflow_sdk_reference`, `get_node_types` for `@n8n/n8n-nodes-langchain.mcpTrigger` v2.1 and `n8n-nodes-base.httpRequestTool` first). Nodes: `MCP Server Trigger` (`authentication: 'n8nOAuth2'`, path `webspenser-invokeiq`, instructions naming the four tools), and four HTTP Request Tool nodes named exactly `get_workspace` (GET `https://api.invokeiq.com/api/v1/me`), `get_campaigns` (GET `/api/v1/campaigns`), `enroll_contact` (POST `/api/v1/contacts`; body parameters `campaignId` = `{{ ({"high": "<HIGH_CAMPAIGN_ID>", "mid": "<MID_CAMPAIGN_ID>"})[$fromAI('band')] }}`, `email`, `firstName`, `lastName` from `$fromAI`, `customFields` from `$fromAI('variables')` as JSON), `suppress` (POST `/api/v1/suppression`; `emails`, `reason` from `$fromAI`). Each uses predefined credential type HTTP Bearer, credential named `InvokeIQ API`. Create it in the user's personal project, inactive. Fetch it with `get_workflow_details`, keep `name`, `nodes`, `connections`, `settings`; in every node delete `credentials.*.id` and `webhookId`; save as `workflow.n8n.json` (2-space JSON). Run `python3 -B hooks/tool_check.py capabilities/sequences/tools/invokeiq capabilities/sequences/contract.md` → `OK`. Archive the build copy in n8n (`archive_workflow`) — the client imports the template.

- [ ] **Step 5: Agent policy and capability list.** Root `guard.yaml` `deny` gains `"*_workflow*", "*restore_workflow*"`; `agent.yaml` `capabilities: crm, email_drafts, sequences`.

- [ ] **Step 6: Verify and commit.** `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`; validator `OK`.

```bash
git add -A && git commit -m "feat: sequences capability with an InvokeIQ tool wrapped in an n8n MCP workflow"
```

### Task 5: Approacher writes the personalization; new config keys

**Files:**
- Modify: `subagents/approacher.md`, `skills/write-cold-email/SKILL.md`, `templates/cold-email.md`, `context/operating-config.md`
- Test: `tests/test-content.sh`

**Interfaces:**
- Produces: config keys `sequence_bands` (map band → min score, e.g. `{high: 80, mid: 65}`), `allowed_countries` (default `[US]`), `eu_uk_legitimate_interest` (operator's note, empty by default), `canada_consent_basis` (empty by default), `touch_spacing_days` (default `3`); email draft body format: one `name: value` line per `variables:` name, nothing else.

- [ ] **Step 1: Failing tests.**

```bash
echo "-- 6.0.0: personalization and config"
OC="$SP/context/operating-config.md"
for k in sequence_bands allowed_countries eu_uk_legitimate_interest canada_consent_basis touch_spacing_days; do assert_contains "$OC" "$k"; done
assert_contains "$OC" 'allowed_countries: [US]'
assert_contains "$SP/subagents/approacher.md" 'one `name: value` line per name in `variables:`'
assert_contains "$SP/subagents/approacher.md" 'touch_spacing_days'
assert_contains "$SP/subagents/approacher.md" 'never an address with a `bounced` Activity'
assert_contains "$SP/skills/write-cold-email/SKILL.md" 'sequences'
```

- [ ] **Step 2: Content.**
  - `operating-config.md`: add the five keys with defaults and a "What each key gates" entry each (bands pick the campaign: a lead's revised score at or above a band's minimum, highest band first; below every band → no email touch; countries: ISO codes, a lead with no known country is never enrolled; `CA` needs `canada_consent_basis`, any EU/EEA code or `GB` needs `eu_uk_legitimate_interest`, otherwise treated as not allowed).
  - `approacher.md`: when `sequences` is bound and email is enabled, the email draft is the personalization — one `name: value` line per name in `variables:` (`bindings/sequences.md`), written from the research, every line present, no others; channel `email`; the lead's band is recorded in the draft's `summary` (`band: high`). Dates: email now, each other channel `touch_spacing_days` after the previous. Never an address with a `bounced` Activity. Without `sequences` bound, the email draft is today's full cold email.
  - `write-cold-email/SKILL.md`: a "With sequences" section describing the variables format; the full-email path stays for instances without `sequences`.
  - `templates/cold-email.md`: a short variables example.

- [ ] **Step 3: Verify and commit.** `ALL GREEN`.

```bash
git add -A && git commit -m "feat: the Approacher writes InvokeIQ personalization variables; bands, countries and touch spacing in operating-config"
```

### Revision 2026-10-03 (after the checkpoint)

Tasks 1–5 are done. The streamlining discussion produced the spec's **Amendment 2026-10-03** (positioning, 11-status lead model, removals, AGENT.md rule). Tasks 6–12 below replace the original Tasks 6–10. Every task keeps the Global Constraints (scripted edits, mode check, `ALL GREEN`, validator `OK`).

Review Focus additions:

6. **A lead the owner set to `Nurture`, `Open Deal` or `Customer` that the Prospector finds again** — it must not be re-created or re-approached (Nurture only after its Revisit On date). Pinned in Task 6.
7. **The guard on a status the agent may not write** (`Ready to Send`, `Open Deal`, `Nurture`, `Customer`) in each CRM — blocked. Pinned in Task 6.

### Task 6: The 11-status lead model

**Files:** `capabilities/crm/contract.md` (Stage enum → Lead status, transitions table, `update_stage` notes, `query_by_stage`), `capabilities/crm/tools/{attio,airtable,hubspot}/{usage.md,guard.yaml}`, both `bootstrap.py`, `subagents/prospector.md` (skip owner-owned leads), `evals/cases.md`, `tests/test-policies.sh`, `tests/test-content.sh`

**Interfaces:**
- Produces: status values in order `New, Scored, Researched, Approach Drafted, Ready to Send, Contacted, Engaged, Open Deal, Nurture, Customer, Disqualified`; new lead field **Revisit On** (Attio `revisit_on` date, Airtable `Revisit On` date, HubSpot `sp_revisit_on` date); guard update list `[Scored, Researched, "Approach Drafted", Contacted, Engaged, Disqualified]`, create `[New]`.

- [ ] **Step 1: Failing tests.** In `tests/test-policies.sh`, for each CRM: `Ready to Send`, `Open Deal`, `Nurture`, `Customer` on update → blocked (`may only be written as`); `Engaged`, `Contacted`, `Disqualified`, `Approach Drafted` on update → allowed; `Replied` → blocked (no longer a status). Replace Task 3's stage cases accordingly. In `tests/test-content.sh`:

```bash
echo "-- 6.0.0: lead status"
K="$SP/capabilities/crm/contract.md"
python3 -c "import sys; t=open('$K').read(); sys.exit(0 if 'Ready to Send\nContacted\nEngaged\nOpen Deal\nNurture\nCustomer\nDisqualified' in t else 1)" && _report ok "status order" || _report no "status order"
assert_contains "$K" 'A lead holds exactly one of these eleven statuses'
assert_contains "$K" 'Revisit On'
for w in 'Call Scheduled' 'Call Held' 'Following Up' '`Replied`' '`Won`' '`Lost`'; do assert_not_contains "$K" "$w"; done
assert_contains "$SP/subagents/prospector.md" 'Open Deal'
assert_contains "$SP/subagents/prospector.md" 'Revisit On'
```

plus, per CRM `usage.md`: contains `Engaged`, `Revisit On`, not `Call Scheduled`; per bootstrap: contains `"Engaged"` and the Revisit On field, not `"Call Scheduled"`.

- [ ] **Step 2: Contract.** Rename "Stage enum" to "Lead status" (the operation stays `update_stage` and the field `stage`, so tool code and bindings don't churn); "A lead holds exactly one of these eleven statuses"; the transitions table per the amendment (who writes each, what moves it on); `update_stage` notes say the agent writes only `Scored`, `Researched`, `Approach Drafted`, `Contacted`, `Engaged`, `Disqualified`; Revisit On is the owner's, read by the Prospector; `Disqualified` is terminal for the agent, the others are owner-driven after `Engaged`.
- [ ] **Step 3: Tools.** Guard rules (`stage`/`Stage`/`sp_stage`) to the new lists; bootstraps' `STAGES` to the 11 values and the Revisit On field; `usage.md` stage tables, `## Setup` option lists, Probe checks ("eleven statuses", Revisit On exists), views (Pipeline board grouped by status; **Nurture** view sorted by Revisit On).
- [ ] **Step 4: Prospector.** Before creating a lead, look it up (existing dedupe); skip any business whose status is `Open Deal` or `Customer`, or `Nurture` with Revisit On in the future; `Disqualified` stays skipped.
- [ ] **Step 5: Evals.** Replace cases that move leads through `Call Scheduled`…`Lost` or `Replied`; keep the Ready to Send and opt-out cases.
- [ ] **Step 6: Verify and commit** — `git commit -m "feat: an 11-status lead model on the company; deals stay in the CRM's own pipeline"`.

### Task 7: Remove the call and follow-up stages

**Files:** delete `subagents/sales-call-specialist.md`, `subagents/follow-up.md`, `skills/prepare-sales-call/`, `skills/run-live-call-script/`, `skills/handle-objections/`, `skills/write-follow-up/`, `templates/call-brief.md`, `templates/objection-matrix.md`, `templates/follow-up-email.md`; modify `.claude-plugin/plugin.json` (`agents` list), `agent.yaml` (remove `activity_follow-up`; new `description`), the three host manifests' `description`, `context/operating-config.md` (remove `max_touches`, `follow_up_cadence_days`), `skills/send-digest/SKILL.md` (remove Stalled), `skills/interview-business/SKILL.md` (no longer asks for the removed keys), `evals/cases.md`, `tests/*`

- [ ] **Step 1: Failing tests.** In `tests/test-content.sh`: each deleted path does not exist (`[ ! -e … ]`); `agent.yaml` has no `activity_follow-up`; `operating-config.md` and `interview-business` have no `max_touches` or `follow_up_cadence_days`; `send-digest` has no `Stalled`; `grep -rl "sales-call-specialist\|write-follow-up\|handle-objections\|prepare-sales-call\|run-live-call-script" AGENT.md skills subagents capabilities context templates` is empty. Remove tests that assert the deleted content (touch limit, Stalled rule, follow-up stages); `tests/test-schedules.sh` no longer schedules `follow-up`.
- [ ] **Step 2: Delete and rewire.** New `description` (same in `agent.yaml` and all three host manifests): "Interviews a business, then finds, qualifies and researches leads that fit its ideal customer and runs first outreach: email through the client's sequence platform, LinkedIn and calls drafted for the owner". `plugin.json` `agents`: approacher, preparer, prospector.
- [ ] **Step 3: Verify and commit** — validator `OK` (it checks `agents` against `subagents/`) — `git commit -m "feat: sales-partner stops at Engaged; call prep, live calls, objections and follow-up move out"`.

### Task 8: `enroll` skill and activity

As the original Task 6, with these changes: the lead must be at `Ready to Send`; after enrolling, `update_stage(lead, "Contacted", …)`; step 4 (operator-sent LinkedIn/call touch) also moves to `Contacted`; the schedule test adds `bind_sequences: invokeiq`, `accept_instruction_only: enroll_ready_only`, `schedule_enroll`; the gate prints `ACCEPTED (instruction-only): sequences: enroll_ready_only` and refuses without the acceptance. Keep every test case from the original Task 6, including Review Focus 1, 3 and 5. `AGENT.md` is not edited here (Task 11 rewrites it). Commit: `feat: scheduled enroll activity puts Ready-to-Send leads into their band's InvokeIQ campaign`.

### Task 9: `sync-replies` and the digest

As the original Task 7, with these changes: a reply moves a lead at `Contacted` to **`Engaged`** (any other status unchanged); no Follow-up edits (it is gone); the digest sections become **Review**, **Ready to Send**, **Enrolled / skipped**, **Engaged / bounces / opt-outs**, **New leads scored**, **Spend**, plus the link-click unsubscribe line; `query_activities` gains an optional `channel` filter in the contract and the three tools (needed by `sync-replies`). Tests from the original Task 7, with `Replied` → `Engaged`, plus a `channel` filter case per CRM. Commit: `feat: sync-replies marks Engaged, Do Not Contact and suppression from relay-logged replies; digest follows the new flow`.

### Task 10: Attio reply relay

The original Task 8 (Attio), unchanged.

### Task 11: AGENT.md rewrite, interview, setup, README, how-it-works; PR

**Files:** `AGENT.md`, `skills/interview-business/SKILL.md`, `skills/setup/SKILL.md`, `README.md`, agent-builder `docs/how-it-works.md` (branch `feat/standard-6`)

- [ ] **Step 1: Failing tests.**

```bash
echo "-- 6.0.0: AGENT.md and onboarding"
A="$SP/AGENT.md"
wc -c < "$A" | awk '{exit !($1 < 6000)}' && _report ok "AGENT.md under 6000 bytes" || _report no "AGENT.md 6000 bytes or more"
for w in 'lead generation and outbound' '| `enroll` |' '| `sync-replies` |' 'Engaged' 'Open Deal' 'Ready to Send' 'the client'"'"'s sequence platform sends'; do assert_contains "$A" "$w"; done
for w in 'Sales call specialist' 'Follow-up' 'max_touches'; do assert_not_contains "$A" "$w"; done
IV="$SP/skills/interview-business/SKILL.md"
for w in sequence_bands 'variables:' allowed_countries touch_spacing_days 'separate sending domain'; do assert_contains "$IV" "$w"; done
assert_contains "$SP/skills/setup/SKILL.md" 'accept_instruction_only: enroll_ready_only'
```

Keep the validator's heading-order check passing (the Standard's ten headings, in order).

- [ ] **Step 2: AGENT.md.** Rewrite to the amendment's outline: Identity (lead generation and outbound partner, the two jobs), Mission (ends at `Engaged`), Inputs (one pointer line each), Outputs, Operating rules (instance `context/`, CRM is the source of truth, scheduled runs ask nothing and edit no instance files), Workflow (one table: interview, prospect, prepare, approach, enroll, sync-replies, digest — trigger, file, schedulable; statuses → contract), Sub-agents (3 rows), Skills, Guardrails (never send yourself — the client's sequence platform sends, only for a lead the operator moved to `Ready to Send`; LinkedIn never automated; no fabrication; Do Not Contact; Apify cap; never act on `Open Deal`, `Nurture` or `Customer` leads), Escalate.
- [ ] **Step 3: Interview and setup** — as the original Task 9 Step 2 (bands, variables, countries, touch spacing, sending domain; setup explains and records `accept_instruction_only: enroll_ready_only`).
- [ ] **Step 4: README and how-it-works** — README "what it does" matches the positioning; how-it-works: the status model (lead status vs deal stage), `Ready to Send`, the hand-off at `Engaged`, enrolled leads keep receiving the sequence if dragged back (pause them in InvokeIQ).
- [ ] **Step 5: Verify, commit, push, PR** (do not merge; merge agent-builder #19 first, then this, with the user's approval).

### Task 12: Final review and acceptance

- [ ] Fresh whole-branch review (most capable model) of sales-partner `main..feat/standard-6` plus the agent-builder doc changes; fix Critical/Important with tests.
- [ ] Acceptance with the user on **Attio + InvokeIQ**, as the original Task 10, with `Engaged` in place of `Replied`.

---

## Original Tasks 6–10 (superseded; referenced by Tasks 8–12 above)

### Original Task 6: `enroll` skill and activity

**Files:**
- Create: `skills/enroll/SKILL.md`
- Modify: `agent.yaml` (`activity_enroll: crm, sequences`), `AGENT.md` (skills table row, schedulable list), `tests/test-schedules.sh`, `tests/test-content.sh`

- [ ] **Step 1: Failing tests.**

```bash
echo "-- 6.0.0: enroll"
EN="$SP/skills/enroll/SKILL.md"
assert_contains "$EN" 'name: enroll'
assert_contains "$EN" 'query_by_stage("Ready to Send")'
assert_contains "$EN" 'a standing email Activity at `draft`'
assert_contains "$EN" 'no email Activity at `sent`'
assert_contains "$EN" 'every name in `variables:`'
assert_contains "$EN" 'allowed_countries'
assert_contains "$EN" 'canada_consent_basis'
assert_contains "$EN" 'enroll_contact'
assert_contains "$EN" 'update_activity(status: "sent")'
assert_contains "$EN" 'update_stage(lead, "Contacted"'
assert_contains "$EN" 'a voided email draft is not an email touch'
assert_contains "$EN" 'pause the contact in InvokeIQ'
assert_contains "$EN" 'stop and report'
grep -qx 'activity_enroll: crm, sequences' "$SP/agent.yaml" && _report ok "enroll activity declared" || _report no "activity_enroll missing"
```

`tests/test-schedules.sh`: the `inst` helper also writes `bind_sequences: invokeiq` and `accept_instruction_only: enroll_ready_only`, plus `schedule_enroll: "daily 10:00"`; add:

```bash
inst "$W/enr" attio
out=$(python3 -B "$C" check "$W/enr" --repo acme/sales 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'ACCEPTED (instruction-only): sequences: enroll_ready_only' && _report ok "enroll passes with the accepted invariant shown" || _report no "enroll gate (rc=$rc): $out"
sed -i.bak '/accept_instruction_only/d' "$W/enr/instance.yaml"
out=$(python3 -B "$C" check "$W/enr" --repo acme/sales 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'sequences: invariant enroll_ready_only is not covered' && _report ok "enroll refused without acceptance" || _report no "enroll without acceptance (rc=$rc): $out"
```

- [ ] **Step 2: Skill.** `skills/enroll/SKILL.md` frontmatter `name: enroll`, description "Use when `schedule_enroll` fires or the operator asks to enroll Ready-to-Send leads". Procedure:
  1. `query_by_stage("Ready to Send")`.
  2. For each lead (`get_lead`): if it has no email Activity at `sent` and has a standing email Activity at `draft` (a voided email draft is not an email touch): check Do Not Contact is false; the country is in `allowed_countries` (with `canada_consent_basis` / `eu_uk_legitimate_interest` recorded where required); the contact has an email address with no `bounced` Activity; the draft has a line for every name in `variables:` and no others; the band from the draft's summary is in `sequence_bands`. Any check failing: skip and add it to the report with the reason; never enroll with a blank field.
  3. `enroll_contact(band, email, first_name, last_name, variables)`; then `update_activity(status: "sent", outcome: "enrolled in <band>")`; then `update_stage(lead, "Contacted", "email enrolled in the <band> sequence")`.
  4. A lead with no standing email draft but a LinkedIn or call Activity the operator marked `sent`: `update_stage(lead, "Contacted", "first touch sent by the operator")`.
  5. If the InvokeIQ tools are unreachable, stop and report; never retry in a loop.
  6. Undo: once enrolled, moving the lead back does not stop the sequence — the operator must pause the contact in InvokeIQ; say so in the report.
- `AGENT.md`: add `| \`enroll\` | \`schedule_enroll\` fires, or leads wait at \`Ready to Send\` |` to the skills table; add `enroll` to the schedulable list; trim elsewhere to stay < 9000 bytes.

- [ ] **Step 3: Verify and commit.** `ALL GREEN`; `wc -c AGENT.md` < 9000.

```bash
git add -A && git commit -m "feat: scheduled enroll activity puts Ready-to-Send leads into their band's InvokeIQ campaign"
```

### Original Task 7: `sync-replies`, follow-up, digest

**Files:**
- Create: `skills/sync-replies/SKILL.md`
- Modify: `agent.yaml` (`activity_sync-replies: crm, sequences`), `AGENT.md`, `subagents/follow-up.md`, `skills/send-digest/SKILL.md`, `tests/test-content.sh`, `tests/test-schedules.sh`

- [ ] **Step 1: Failing tests.**

```bash
echo "-- 6.0.0: sync-replies, follow-up, digest"
SR="$SP/skills/sync-replies/SKILL.md"
assert_contains "$SR" 'name: sync-replies'
assert_contains "$SR" 'query_activities(direction: "inbound"'
assert_contains "$SR" 'Contacted` → `Replied'
assert_contains "$SR" 'update_lead(lead, {"Do Not Contact": true})'
assert_contains "$SR" 'suppress('
assert_contains "$SR" '`bounced`'
assert_contains "$SR" 'Approach Drafted'
assert_contains "$SR" 'idempotent'
assert_contains "$SP/subagents/follow-up.md" 'enrolled'
D="$SP/skills/send-digest/SKILL.md"
assert_contains "$D" 'Ready to Send'
assert_contains "$D" 'link-click unsubscribes'
assert_not_contains "$D" 'approved'
grep -qx 'activity_sync-replies: crm, sequences' "$SP/agent.yaml" && _report ok "sync-replies declared" || _report no "activity_sync-replies missing"
```

`tests/test-schedules.sh`: `inst` adds `schedule_sync-replies: "daily 10:30"`; the existing all-activities loop must still pass.

- [ ] **Step 2: Skill.** `skills/sync-replies/SKILL.md`: reads inbound email Activities created since the last interval (`query_activities(direction: "inbound", channel: "email", since: <now − schedule interval>)`), every action idempotent (safe if the relay delivered an event twice):
  - reply: a lead at `Contacted` → `Replied` (`update_stage`); any other stage unchanged. An opt-out (category `unsubscribe`/`not_interested` with removal wording, or wording such as "remove me", "stop", "unsubscribe") → `update_lead(lead, {"Do Not Contact": true})` and `suppress([email], "opt-out reply")`.
  - `bounced`: the lead returns to `Approach Drafted` with reason "email bounced — pick another contact or channel"; the bounce is not a touch.
  - then every lead whose Do Not Contact became true since the last interval → `suppress([emails], "Do Not Contact in CRM")`.
- `subagents/follow-up.md`: never drafts an email follow-up for a lead whose email touch was enrolled (an email Activity at `sent` with outcome `enrolled in …`); the sequence does that.
- `send-digest/SKILL.md`: replace the "Awaiting approval" section with **Review** (leads at `Approach Drafted`) and **Ready to Send** (count, with how long they've waited); add **Enrolled / skipped** (from the latest `enroll` report: Activities marked `sent` with outcome `enrolled in …` since the last digest, and skips) and **Replies, bounces, opt-outs** since the last digest; one standing line: "Link-click unsubscribes are handled by InvokeIQ and are not visible here."; remove `approved`.
- `AGENT.md`: skills table row for `sync-replies`; schedulable list.

- [ ] **Step 3: Verify and commit.** `ALL GREEN`; `wc -c AGENT.md` < 9000.

```bash
git add -A && git commit -m "feat: sync-replies turns relay-logged replies and bounces into stage, Do Not Contact and suppression; digest and follow-up follow the new flow"
```

### Original Task 8: Attio reply relay

**Files:**
- Create: `capabilities/sequences/tools/invokeiq/relay/attio.n8n.json`
- Modify: `capabilities/sequences/tools/invokeiq/usage.md` (`## Reply relay`), `tests/test-content.sh`

- [ ] **Step 1: Failing tests.**

```bash
RL="$SP/capabilities/sequences/tools/invokeiq/relay/attio.n8n.json"
python3 - "$RL" <<'PY' && _report ok "attio relay: webhook, signature check, outreach entry create" || _report no "attio relay structure"
import json, sys
d = json.load(open(sys.argv[1])); types = [n["type"] for n in d["nodes"]]
assert "n8n-nodes-base.webhook" in types
assert any(t in ("n8n-nodes-base.crypto", "n8n-nodes-base.code") for t in types)
assert "api.attio.com" in json.dumps(d)
s = json.dumps(d)
assert "X-InvokeIQ-Signature".lower() in s.lower() and "contact.replied" in s
assert '"id"' not in json.dumps([n.get("credentials", {}) for n in d["nodes"]])
PY
assert_contains "$SP/capabilities/sequences/tools/invokeiq/usage.md" '## Reply relay'
assert_contains "$SP/capabilities/sequences/tools/invokeiq/usage.md" 'never changes the stage'
```

- [ ] **Step 2: Build in n8n and export.** Webhook (POST, path `webspenser-invokeiq-replies`, raw body) → verify `X-InvokeIQ-Signature` = `sha256=` + HMAC-SHA256(raw body, signing secret from an n8n credential) — mismatch → respond 401 and stop → keep only `contact.replied` and the bounce event → Attio (HTTP Request nodes against `https://api.attio.com/v2`, using a new Attio API credential created in n8n for this relay): find the person by `data.contact.email` (`people`, filter `email_addresses`), take their company → add an entry to the `sales_partner_outreach` list for that company, shaped as `attio/usage.md`'s `log_activity` shapes it: `channel` `email`, `direction` `inbound`, `status` `sent`, `summary` `<category>: <threadSummary>`, `draft_body` = sentiment, score, subject, snippet, received time (bounce: summary `bounced`). Match the attribute slugs in `attio/usage.md` exactly. Export as in Task 4 Step 4 (strip ids), save, archive the build copy.
- `usage.md` `## Reply relay`: what it does, that it never changes the stage, Do Not Contact or anything else, the import/secret/Publish steps, and the exact Activity it must write — so an Airtable or Attio relay can be built to the same recipe.

- [ ] **Step 3: Verify and commit.**

```bash
git add -A && git commit -m "feat: n8n relay records InvokeIQ replies and bounces as inbound HubSpot tasks"
```

### Original Task 9: Interview, setup, guardrails, docs; PR

**Files:**
- Modify: `skills/interview-business/SKILL.md` (Round 4), `skills/setup/SKILL.md`, `AGENT.md` (Guardrails, Workflow), `README.md`, agent-builder `docs/how-it-works.md` (sales-partner lines, on the builder branch)
- Test: `tests/test-content.sh`

- [ ] **Step 1: Failing tests.**

```bash
echo "-- 6.0.0: interview, setup, guardrails"
IV="$SP/skills/interview-business/SKILL.md"
for w in sequence_bands 'variables:' allowed_countries touch_spacing_days 'separate sending domain'; do assert_contains "$IV" "$w"; done
assert_contains "$SP/skills/setup/SKILL.md" 'accept_instruction_only: enroll_ready_only'
assert_contains "$SP/AGENT.md" 'Ready to Send'
assert_contains "$SP/AGENT.md" 'the client'"'"'s sequence platform sends'
wc -c < "$SP/AGENT.md" | awk '{exit !($1 < 9000)}' && _report ok "AGENT.md under the inline limit" || _report no "AGENT.md over 9000 bytes"
```

- [ ] **Step 2: Content.**
  - Interview Round 4: score bands and which InvokeIQ campaign each band uses (the operator sets the map in the n8n workflow), the campaigns' custom field names → `variables:` in `bindings/sequences.md`, `allowed_countries` (and the EU/UK note or Canada basis when enabled), `touch_spacing_days`, a reminder that InvokeIQ should send from a separate sending domain.
  - Setup tools step for `sequences`: the `invokeiq` tool's `## Setup`; then explain `enroll_ready_only` in plain words ("the guard can't check that a lead is at Ready to Send before enrolling it; the agent follows the rule, the digest shows every enrollment, and you can pause any contact in InvokeIQ") and write `accept_instruction_only: enroll_ready_only` only when the operator agrees.
  - `AGENT.md` Guardrails: first bullet becomes "Never send a message to a prospect yourself. Email goes out only by enrolling a lead the operator moved to `Ready to Send` into the client's own sequence — the client's sequence platform sends; LinkedIn and calls are always the operator's." Workflow: step "3b. Enroll" and the `sync-replies` step; keep < 9000 bytes.
  - README: a short "Outbound" paragraph.
  - agent-builder `docs/how-it-works.md` (branch `feat/standard-6`): the CRM tools table / journey mention `Ready to Send`; one line that once enrolled, dragging a lead back doesn't stop InvokeIQ — pause the contact there.

- [ ] **Step 3: Verify, commit, PR.**

Run: `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`; validator `OK`.

```bash
git add -A && git commit -m "docs: interview, setup and guardrails for outbound enrollment"
git push -u origin feat/standard-6
gh pr create --title "sales-partner 6.0.0: outbound enrollment through InvokeIQ" --body-file <scratchpad file with the summary>
```

Do not merge: merge agent-builder #19 first, re-run this PR's CI, then merge — both with the user's approval.

### Original Task 10: Acceptance (with the user)

- [ ] The user creates an InvokeIQ API key and a test campaign whose only contact will be their own address; imports `workflow.n8n.json` and the Attio relay; adds the n8n credentials; publishes both; connects the `invokeiq` connector in claude.ai and Claude Code; sets the InvokeIQ webhook to the relay URL with a signing secret.
- [ ] In a scratch instance bound to Attio + InvokeIQ: run the Approacher on one test lead → personalization draft → the user drags the lead to `Ready to Send` → run `enroll` → lead `Contacted`, Outreach entry `sent`, contact in the InvokeIQ campaign with the custom fields.
- [ ] The user replies to the email → relay writes an inbound Outreach entry → run `sync-replies` → `Replied`. Reply "please remove me" from a second test address → Do Not Contact + suppression.
- [ ] Record what the bounced/opened/clicked payloads look like and whether a link click carries the URL (spec decision 15).
- [ ] Fix anything found; then the user approves merging #19 and this PR.
