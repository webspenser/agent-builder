# Agent Standard 6.0 and sales-partner 6.0: outbound enrollment — design

Status: approved in conversation on 2026-10-01. This is the first sub-project of the "outbound partner" redesign. The second, enrichment (Google Places, Yelp Fusion, LinkedIn via Apify), gets its own spec.

## Goal

Make sales-partner an outbound partner. The agent researches, scores and personalizes. The owner approves the plan in the CRM. Then approved email touches go out through the client's own cold-outreach platform (Instantly first): the agent adds the lead to the campaign for its score band with the personalization filled in, and Instantly sends the sequence. The agent never writes or sends the emails themselves. Replies and opt-outs come back into the CRM.

LinkedIn and call touches keep today's model: the agent drafts them, the owner does them.

## What the user said (the brief)

- Cold prospects are the main case. Marketing platforms (Loops, Kit, Mailchimp, MailerLite) forbid non-opted-in contacts, so the first platform is a cold-outreach tool: **Instantly**.
- Approval stays in the CRM. **One drag approves the plan**: the owner refines drafts, sets dates, voids what they don't want, then moves the lead to a new stage, **`Ready to Send`**. No partial approvals. Dragging back to `Approach Drafted` before the enroll run picks it up cancels it.
- Several lanes: email goes out by enrollment; LinkedIn and calls wait for the owner on their own dates.
- Replies and unsubscribes sync back to the CRM. Opt-outs set Do Not Contact and blocklist the address in Instantly.
- Countries: an allow-list, US by default.
- Sending setup (domains, DKIM, unsubscribe footer) is the client's job; the agent checks it read-only and warns.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Two layers: the **lead stage** is the plan's state; each **Activity** is one touch (channel, draft, date, status) | Approval is per plan, execution is per touch. Forcing touches into the stage was the confusion. |
| 2 | New stage **`Ready to Send`** between `Approach Drafted` and `Contacted` (13 stages). Only a human writes it: every CRM guard policy lists every other stage as writable and leaves `Ready to Send` out | "One drag approves the plan." The guard makes approval human-only by mechanism, with no engine change. |
| 3 | Activity statuses become **`draft` → `sent` / `voided`**. `approved` is removed. The agent may update an Activity to `sent` or `voided` | Approval moved to the lead stage. `sent` records a fact (the agent enrolled the email, or the owner did the LinkedIn touch); writing it sends nothing. |
| 4 | `draft_only` is restated: the agent creates Activities only at `draft`, updates them only to `sent`/`voided`, never rewrites a draft body (5.0 `forbid: update`), and never writes `Ready to Send` | Keeps "only a human approves" a mechanism. |
| 5 | New capability **`sequences`** with an **Instantly** tool (official MCP server `https://mcp.instantly.ai/mcp`, the client's API key) | One contract, one folder per platform; Smartlead, lemlist, HubSpot Sequences can follow. |
| 6 | The email draft's body **is** the personalization: labelled lines, one per Instantly custom variable (`subject: …`, `opener: …`) | The owner reviews and edits the exact values that will be sent, in the same place as today. `forbid: update` guarantees the agent can't change them after approval. |
| 7 | Enrollment is **done by the agent** in a scheduled `enroll` activity (option A) | Matches the brief: approve in the CRM, the next scheduled run picks it up. |
| 8 | "Enroll only leads at `Ready to Send`" is **instruction-only, accepted by the operator** (`accept_instruction_only`) | The guard cannot read the CRM at call time. The gap is named and accepted, not hidden. |
| 9 | **Argument pinning** in the guard engine: Instantly writes may only target campaign IDs recorded in bindings | Limits enrollment to the client's chosen campaigns; also defeats dispatcher-style arguments. Reused later for Gmail `to`, Airtable `baseId`, HubSpot `objectType`. |
| 10 | Score bands map to campaigns: `sequence_bands` in `operating-config.md` (for example `high: 80`, `mid: 65`), each band bound to one campaign ID | The brief's "different lists by score". |
| 11 | `allowed_countries` in `operating-config.md`, default `[US]`. EU/UK need an operator legitimate-interest note; Canada needs an operator-confirmed consent basis | Cold email law differs by country; the agent decides who may be enrolled. |
| 12 | Follow-up never drafts email follow-ups for a lead whose email touch was enrolled; the sequence does that | Avoids double emailing. |
| 13 | Agent Standard 6.0, builder 6.0.0, sales-partner 6.0.0; no backward compatibility | Dev-phase rule. |

## Part A — agent-builder 6.0.0

### A1. Argument pinning (`pins:`)

A new block list in a tool's `guard.yaml`:

```yaml
pins:
  - tools: [add_lead*, "*lead*campaign*"]
    arg: campaign_id          # a top-level argument, or a dotted / list path like `at`
    bound: campaign_          # allowed values: every bindings value whose key starts with campaign_
    required: true            # a matching call without the argument blocks
  - tools: [manage_crm_objects]
    arg: "createRequest.objects[].objectType"
    values: [companies, contacts, tasks, notes]
```

- An item holds `tools` (globs, matched as in `allow`), `arg` (a path as in `writes.at`, ending at a scalar or a list of scalars), exactly one of `bound` (a bindings key prefix) or `values` (a flow list), and optional `required: true`.
- Semantics: for a call whose tool matches, every value found at `arg` must equal (trimmed, case-insensitive) one allowed value. A path absent from the call passes unless `required: true`. No allowed values (a `bound` prefix with no bindings lines) blocks: `<arg> has no recorded values; re-run setup's tools step`. Otherwise: `<arg> may only be one of the recorded <prefix>* values` / `<arg> may only be one of <values>`.
- Bindings: a `bound` prefix matches keys like `campaign_high`, `campaign_mid`. Values follow the existing bare-ID rule.
- `pins` does not need `writes`.
- Parse errors: unknown item key, both or neither of `bound`/`values`, empty `tools`, invalid `arg` path, `required` other than `true`.

### A2. Operator-accepted instruction-only invariants

- A contract may mark an invariant acceptable: `- \`enroll_ready_only\` (acceptable) — …`. Invariants without the mark can never be accepted (`no_send`, `draft_only`, `dnc_one_way`, `no_delete` stay mandatory).
- `instance.yaml` may hold `accept_instruction_only: <invariant>[, <invariant>]`. Only setup writes it, after showing the operator the risk in plain words.
- The schedule gate treats an accepted, acceptable invariant as covered and prints `ACCEPTED (instruction-only): <capability>: <invariant>` on every check. Accepting an invariant that is not marked acceptable is a gate failure.
- `tool_check.py` and the validator parse the `(acceptable)` mark.

### A3. Docs and tests

STANDARD.md (Guard policy grammar/keys/semantics for `pins`; Capabilities for the `(acceptable)` mark; Instances for `accept_instruction_only`; The unattended gate), `docs/how-it-works.md`, `docs/writing-an-agent.md`, the `add-tool` skill (propose pins for arguments that pick a destination). Tests for every parse error and semantic above.

## Part B — sales-partner 6.0.0

### B1. CRM changes (all three tools)

- Stage enum: 13 stages, `Ready to Send` after `Approach Drafted`. Transitions: `Approach Drafted` → `Ready to Send` (owner only) → `Contacted` (the first touch actually went out on any channel: the agent after enrolling, or the owner/digest after a LinkedIn or call touch is marked `sent`). `Ready to Send` → `Approach Drafted` (owner, cancels).
- Activity status: `draft`, `sent`, `voided`. HubSpot: `NOT_STARTED`, `COMPLETED`, `DEFERRED` (the agent may update to `COMPLETED` or `DEFERRED`; `hs_task_completion_date` stays forbidden).
- Guard policies: the stage rule lists `New` on create and every stage except `Ready to Send` on update; the status rule allows `draft` on create and `sent`/`voided` on update. Bootstrap scripts and `## Setup` lists add the stage option.
- Views: the approval view becomes "leads at `Approach Drafted`" with their drafts; a "Ready to Send" view; the owner's to-do view lists `draft` LinkedIn and call Activities on `Ready to Send`/`Contacted` leads by date.
- `contract.md` Approval invariant rewritten for decisions 3–4.

### B2. `sequences` capability

`capabilities/sequences/contract.md`:

| Operation | Arguments | Returns |
|---|---|---|
| `get_campaigns` | — | campaigns (id, name, status, unsubscribe and stop-on-reply settings) |
| `enroll` | `email, first_name, last_name, company, campaign_band, variables` | enrollment id |
| `list_replies` | `since` | replies (email, campaign, date, snippet, is_unsubscribe) |
| `blocklist` | `email` | ok |

Invariants: `no_send` (no operation sends; enrollment hands the lead to a campaign the client set up) — covered by the agent guard policy and the tool's `allow`; `campaigns_bound_only` — enrollment targets only bound campaign IDs (pins); `no_campaign_control` — the agent never creates, launches, pauses or edits campaigns (allow list); `enroll_ready_only` **(acceptable)** — only leads at `Ready to Send`, not Do Not Contact, in an allowed country.

`capabilities/sequences/tools/instantly/`: `identity.yaml` (`server_match: instantly`), `usage.md` (operation mapping to the real MCP tool names, `## Probe`: list campaigns, record `campaign_<band>: <id>` and `workspace`, check unsubscribe/stop-on-reply and warn), `guard.yaml` (allow the read, lead-add and blocklist tools only; pins on the campaign argument; `covers: [no_send, campaigns_bound_only, no_campaign_control]`). The exact tool and argument names come from the connector's live tool list at build time.

### B3. Activities and sub-agents

- **Approacher:** for the email channel, writes the personalization draft (labelled lines, one per name in the `variables:` line the interview records in `bindings/sequences.md`), and for other enabled channels the usual drafts; stage → `Approach Drafted`. Sets each draft's date: email now; each other channel `touch_spacing_days` (new `operating-config.md` key, default 3) after the previous touch. The owner can change any date before dragging.
- **New `enroll` activity** (`activity_enroll: crm, sequences`, schedulable): for each lead at `Ready to Send` with a standing email `draft`: check not Do Not Contact, country in `allowed_countries`, an email address, no earlier `sent` email Activity; parse the variables; `enroll` into the band's campaign; `update_activity(sent)`; `update_stage(Contacted)`. Leads with no email draft but a `sent` LinkedIn/call Activity move to `Contacted`. Skipped leads are reported (digest).
- **New `sync-replies` activity** (`activity_sync-replies: crm, sequences`): `list_replies(since last run)`; for each: log an inbound Activity, `update_stage(Replied)` when at `Contacted`; on an unsubscribe or opt-out wording: `update_lead(Do Not Contact = true)` and `blocklist`. Also blocklists every lead whose Do Not Contact became true since the last run.
- **Follow-up:** skips email follow-ups for leads with an enrolled email touch.
- **Digest:** counts leads at `Ready to Send`, enrolled since the last digest, skipped (with reason), replies and opt-outs synced.
- **Interview / setup:** asks for score bands and the campaign per band, the template's custom variable names, allowed countries (and the EU/UK note or Canada basis when enabled); explains and records `accept_instruction_only: enroll_ready_only`; reminds about a separate sending domain.

### B4. Compliance

- `allowed_countries` (decision 11); leads without a known country are not enrolled.
- Opt-outs: Instantly unsubscribes and opt-out replies → Do Not Contact + blocklist; CRM Do Not Contact → blocklist.
- Setup's read-only check of each bound campaign: unsubscribe header/link and stop-on-reply on; warn otherwise.
- `how-it-works` gains a short "who is responsible for what" table: client (domain, DNS, footer address, sequence copy), agent (who is enrolled, opt-out sync, regions).

## Order

1. Builder PR (Part A). 2. Sales-partner PR (Part B), built after the user connects an Instantly workspace (the tool's names come from the live connector). 3. Acceptance on a real Instantly workspace: a test campaign, the user's own address as the lead, one full cycle (`Approach Drafted` → drag → enroll → reply → `Replied`; an unsubscribe → Do Not Contact + blocklist).

## Out of scope

Enrichment (its own spec), marketing platforms for warm leads, CRM-automation enrollment (option B), voice calling, Gemini/Codex guard hosts.
