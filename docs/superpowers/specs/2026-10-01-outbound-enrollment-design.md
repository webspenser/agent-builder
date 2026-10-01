# Agent Standard 6.0 and sales-partner 6.0: outbound enrollment — design

Status: design agreed in conversation on 2026-10-01; awaiting the user's review of this written spec. This is the first sub-project of the "outbound partner" redesign. The second, enrichment (Google Places, Yelp Fusion, LinkedIn via Apify), gets its own spec.

## Goal

Make sales-partner an outbound partner. The agent researches, scores and personalizes. The owner approves the plan in the CRM. Then the approved email touch goes out through the client's cold-email platform (**InvokeIQ** first): the agent adds the lead to the campaign for its score band with the personalization filled in, and InvokeIQ sends the sequence. The agent never writes or sends the emails themselves. Replies and bounces come back into the CRM.

LinkedIn and call touches keep today's model: the agent drafts them, the owner does them.

## What the user said (the brief)

- Cold prospects are the main case. Marketing platforms (Loops, Kit, Mailchimp, MailerLite) forbid non-opted-in contacts, so the platform is a cold-email tool. The user tried Instantly for about a year and chose **InvokeIQ** instead; other platforms (Instantly included) can be added later as more tools under the same contract.
- Approval stays in the CRM. **One drag approves the plan**: the owner refines drafts, sets dates, voids what they don't want, then moves the lead to a new stage, **`Ready to Send`** ("grabs attention" better than "Approved"). No partial approvals. Dragging back to `Approach Drafted` before the enroll run picks it up cancels it.
- Several lanes: email goes out by enrollment; LinkedIn and calls wait for the owner on their own dates.
- Services without an MCP server are wrapped in **n8n**: a workflow with an MCP Server Trigger exposes narrow tools, and the service's secrets live only in n8n. Replies come back through an n8n webhook relay too. This becomes a general Agent Builder pattern.
- Countries: an allow-list, US by default.
- Sending setup (domains, DKIM, unsubscribe footer) is the client's job.

## InvokeIQ facts this design relies on

- REST API, no connector or MCP server: `https://api.invokeiq.com/api/v1`, Bearer token auth.
- `GET /me` (workspace, quota), `GET /campaigns` (active, paused, draft, completed), `GET /analytics?campaignId=`.
- `POST /contacts` `{campaignId, email, firstName, lastName, customFields}` enrolls a contact into a campaign. It is an idempotent upsert: calling it again for an enrolled contact updates its custom fields without disrupting its sequence.
- `POST /suppression` `{emails[], reason}` suppresses addresses workspace-wide.
- Webhooks (Settings → Webhooks, optional HMAC SHA-256 signature in `X-InvokeIQ-Signature: sha256=<hex>`): prospect replied (`contact.replied`, first reply only; payload `data.contact{email, firstName, lastName}`, `sentiment`, `sentimentScore`, `category`, `threadSummary`, `subject`, `snippet`, `receivedAt`), email opened, link clicked, email bounced. Only the reply payload is documented; the others are confirmed at acceptance.
- No unsubscribe event and no endpoint that lists replies or unsubscribes.

## n8n facts this design relies on

- **Per-workflow MCP Server Trigger:** exposes only the tools attached to that workflow; supports None, Bearer or Header auth.
- **Instance-level n8n MCP** (one connection per instance) exposes generic tools such as `execute_workflow` (runs any enabled workflow) and, from n8n 2.13, workflow create/update tools. Under the guard these are dispatchers.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Two layers: the **lead stage** is the plan's state; each **Activity** is one touch (channel, draft, date, status) | Approval is per plan, execution is per touch. |
| 2 | New stage **`Ready to Send`** between `Approach Drafted` and `Contacted` (13 stages). Only a human writes it: every CRM guard policy lists every other stage as writable and leaves `Ready to Send` out | "One drag approves the plan", enforced by mechanism, with no engine change. |
| 3 | Activity statuses become **`draft` → `sent` / `voided`**. `approved` is removed. The agent may update an Activity to `sent` or `voided` | Approval moved to the lead stage. `sent` records a fact (the agent enrolled the email, or the owner did the LinkedIn touch); writing it sends nothing. |
| 4 | `draft_only` is restated: the agent creates outbound Activities only at `draft`, updates them only to `sent`/`voided`, never rewrites a draft body (5.0 `forbid: update`), and never writes `Ready to Send` | Keeps "only a human approves" a mechanism. |
| 5 | New capability **`sequences`** with an **InvokeIQ** tool | One contract, one folder per platform. |
| 6 | The agent reaches InvokeIQ through an **n8n workflow with an MCP Server Trigger** ("Webspenser · InvokeIQ") exposing only `get_workspace`, `get_campaigns`, `enroll_contact`, `suppress`. The InvokeIQ API key is an n8n credential; sales-partner holds none | The guard only sees MCP calls; Bash/curl would bypass it. A per-workflow trigger exposes named tools only, so the allow list is structural. |
| 7 | The email draft's body **is** the personalization: labelled lines, one per InvokeIQ custom field (`icebreaker: …`, `company: …`) | The owner reviews and edits the exact values that will be sent. `forbid: update` guarantees the agent can't change them after approval. |
| 8 | Enrollment is **done by the agent** in a scheduled `enroll` activity | Approve in the CRM; the next scheduled run picks it up. |
| 9 | "Enroll only leads at `Ready to Send`" is **instruction-only, accepted by the operator** (`accept_instruction_only`) | The guard cannot read the CRM at call time. The gap is named and accepted. |
| 10 | `enroll_contact` takes a **band** (`high`, `mid`, …), not a campaign ID; the n8n workflow maps each band to its campaign | The agent cannot name any other campaign: structural, not a guard rule. Argument pinning is therefore not needed here and stays on the backlog (Gmail `to`, Airtable `baseId`, HubSpot `objectType`). |
| 11 | `enroll` runs once per lead: never for a lead that already has a `sent` email Activity | `POST /contacts` silently updates an enrolled contact's fields mid-sequence. |
| 12 | Score bands: `sequence_bands` in `operating-config.md` (for example `high: 80`, `mid: 65`); the band-to-campaign map lives in the n8n workflow | The brief's "different lists by score". |
| 13 | Webhooks go to an **n8n relay that only records facts**: it verifies the signature and writes an inbound Activity on the lead. The agent's scheduled `sync-replies` makes every decision (stage, Do Not Contact, suppression) | One guarded, tested copy of the rules; the relay stays trivial per CRM. |
| 14 | v1 uses **replied** and **bounced**. **Opened** and **link clicked** are not recorded | Opens are inflated by mail privacy features and scanners; they would clutter the owner's Activities and the touch count. |
| 15 | Link-click unsubscribes are a **known limit**: InvokeIQ suppresses them, the CRM is not told. The digest says so | No unsubscribe event exists. Follow-up: ask InvokeIQ for one, or use the link-clicked URL if it carries it. |
| 16 | `allowed_countries` in `operating-config.md`, default `[US]`. EU/UK need an operator legitimate-interest note; Canada needs an operator-confirmed consent basis | Cold email law differs by country. |
| 17 | Agent Standard 6.0, builder 6.0.0, sales-partner 6.0.0; no backward compatibility | Dev-phase rule. |
| 18 | **Wrapped tools** become an Agent Builder pattern: a tool for a service without MCP ships an n8n workflow template; agents' guard policies deny dispatcher tools (`*execute_workflow*`, n8n's workflow create/update/archive/publish tools) | The user will wrap most non-MCP services this way. A connector that can run or build arbitrary workflows would bypass every per-tool policy. |

## Part A — agent-builder 6.0.0

### A1. Operator-accepted instruction-only invariants

- A contract may mark an invariant acceptable: ``- `enroll_ready_only` (acceptable) — …``. Unmarked invariants can never be accepted (`no_send`, `draft_only`, `dnc_one_way`, `no_delete` stay mandatory).
- `instance.yaml` may hold `accept_instruction_only: <invariant>[, <invariant>]`. Only setup writes it, after showing the operator the risk in plain words.
- The schedule gate treats an accepted, acceptable invariant as covered and prints `ACCEPTED (instruction-only): <capability>: <invariant>` on every check. Accepting an unmarked invariant is a gate failure.
- `tool_check.py` and the validator parse the `(acceptable)` mark.

### A2. Wrapped tools (n8n)

- A tool folder for a service without an MCP server may ship `workflow.n8n.json`: an n8n workflow whose **MCP Server Trigger** exposes exactly the tools its `usage.md` maps, each a thin call to the service. No tool takes a URL, a method or a free-form request.
- `identity.yaml` gains `wrapper: n8n`. `server_match` is the name the user gives the connector (setup tells them which name to use, for example `invokeiq`).
- The service's secrets are n8n credentials. The agent package and the instance hold none.
- The trigger requires Bearer or Header auth. Setup records how the host connects (Claude Code: an `Authorization` header in the MCP config; claude.ai custom connector for cloud routines: confirmed at acceptance, with an unguessable trigger path as the fallback).
- `tool_check.py`: a `wrapper: n8n` tool must ship `workflow.n8n.json`, and the tool names of its MCP Server Trigger's attached tool nodes must equal the names mapped in `usage.md`.
- Guidance (STANDARD.md, writing-an-agent): one service per workflow; per-workflow trigger only, never instance-level MCP; the agent guard policy denies dispatcher tools (`*execute_workflow*`, `*create_workflow*`, `*update_workflow*`, `*archive_workflow*`, `*publish_workflow*`).

### A3. Docs and tests

STANDARD.md (the `(acceptable)` mark; `accept_instruction_only`; the unattended gate; wrapped tools), `docs/how-it-works.md`, `docs/writing-an-agent.md`, the `add-tool` skill (offer the n8n wrapper when a service has no MCP server). Tests for every parse rule and gate behaviour above, and `tool_check.py` cases for wrapped tools.

## Part B — sales-partner 6.0.0

### B1. CRM changes (all three tools)

- Stage enum: 13 stages, `Ready to Send` after `Approach Drafted`. Transitions: `Approach Drafted` → `Ready to Send` (owner only) → `Contacted` (the first touch actually went out: the agent after enrolling, or the agent on finding a LinkedIn or call Activity the owner marked `sent`). `Ready to Send` → `Approach Drafted` (owner; cancels).
- Activity status: `draft`, `sent`, `voided`. HubSpot: `NOT_STARTED`, `COMPLETED`, `DEFERRED` (the agent may update to `COMPLETED` or `DEFERRED`; `hs_task_completion_date` stays forbidden).
- Guard policies: the stage rule allows `New` on create and every stage except `Ready to Send` on update; the status rule allows `draft` on create and `sent`/`voided` on update. Bootstrap scripts and `## Setup` lists add the stage option.
- Views: the review view is "leads at `Approach Drafted`" with their drafts; a `Ready to Send` view; the owner's to-do view lists `draft` LinkedIn and call Activities on `Ready to Send`/`Contacted` leads by date.
- `contract.md` Approval invariant rewritten for decisions 3–4.

### B2. `sequences` capability and the InvokeIQ tool

`capabilities/sequences/contract.md`:

| Operation | Arguments | Returns |
|---|---|---|
| `get_workspace` | — | workspace id, quota used and limit |
| `get_campaigns` | — | the band campaigns (band, id, name, status) |
| `enroll_contact` | `band, email, first_name, last_name, variables` | the platform's contact id |
| `suppress` | `emails, reason` | ok |

Invariants: `no_send` (no operation sends; enrollment hands the lead to a campaign the client set up and launched); `campaigns_bound_only` (enrollment can only reach the band campaigns; structural, the agent passes a band); `no_campaign_control` (the agent never creates, launches, pauses or edits a campaign; structural, the workflow has no such tool); `enroll_ready_only` **(acceptable)** — only leads at `Ready to Send`, not Do Not Contact, in an allowed country, never enrolled before.

`capabilities/sequences/tools/invokeiq/`:
- `identity.yaml`: `capability: sequences`, `provider: invokeiq`, `server_match: invokeiq`, `wrapper: n8n`.
- `workflow.n8n.json`: MCP Server Trigger (Bearer auth) with four tool nodes calling `GET /me`, `GET /campaigns` (filtered to the band campaigns), `POST /contacts` (band → campaign ID from a map set in the workflow; `variables` → `customFields`) and `POST /suppression`. An unknown band errors.
- `usage.md`: operation mapping; `## Probe`: `get_workspace` (records `workspace`), `get_campaigns` (shows each band's campaign and warns if one is not active); `## Setup`: import the workflow, add the InvokeIQ credential in n8n, set the band map, activate, connect the trigger URL as a connector named `invokeiq`, and the reply relay (B6).
- `guard.yaml`: `covers: [no_send, campaigns_bound_only, no_campaign_control]`, `allow` the four tools.
- `bindings/sequences.md` holds `workspace` and `variables: <name>, <name>` (the campaigns' custom fields), recorded by the interview.

### B3. Activities and sub-agents

- **Approacher:** for email, writes the personalization draft (labelled lines, one per `variables:` name) and for other enabled channels the usual drafts; stage → `Approach Drafted`. Each draft gets a date: email now; each other channel `touch_spacing_days` (new `operating-config.md` key, default 3) after the previous touch. The owner can change any date before dragging.
- **New `enroll` activity** (`activity_enroll: crm, sequences`, schedulable): for each lead at `Ready to Send` with a standing email `draft`: check not Do Not Contact, country in `allowed_countries`, an email address, no earlier `sent` email Activity; parse the variables; `enroll_contact(band)`; `update_activity(sent)`; `update_stage(Contacted)`. A lead with no email draft but a `sent` LinkedIn/call Activity moves to `Contacted`. Skipped leads are reported in the digest. If the n8n tools are unreachable, stop and report it.
- **New `sync-replies` activity** (`activity_sync-replies: crm, sequences`): reads inbound Activities the relay created since the last interval (`query_activities`, idempotent actions, no processed flag). Reply: lead at `Contacted` → `Replied`; an opt-out category or wording → `update_lead(Do Not Contact = true)` and `suppress(reason: "opt-out reply")`. Bounce: the contact's email is marked bounced, the lead returns to `Approach Drafted` with reason "email bounced" so the owner can pick another contact or channel, and the bounce is not counted as a touch. It also suppresses every lead whose Do Not Contact became true since the last interval.
- **Follow-up:** skips email follow-ups for leads with an enrolled email touch.
- **Digest:** counts leads at `Ready to Send`, enrolled, skipped (with reason), replies, bounces, opt-outs; states that link-click unsubscribes are not visible to the CRM.
- **Interview / setup:** score bands and the campaign per band (set in the n8n workflow), the campaigns' custom field names, allowed countries (with the EU/UK note or Canada basis when enabled); explains and records `accept_instruction_only: enroll_ready_only`; reminds about a separate sending domain.

### B4. Agent guard policy

Add the dispatcher denies of decision 18 to sales-partner's root `guard.yaml`, with tests that the per-workflow tools (`get_workspace`, `get_campaigns`, `enroll_contact`, `suppress`) still pass.

### B5. Compliance

- `allowed_countries` (decision 16); a lead without a known country is not enrolled.
- Opt-out replies and CRM Do Not Contact → suppression. Link-click unsubscribes: known limit (decision 15).
- `how-it-works` gains a "who is responsible for what" table: client (domain, DNS, footer address, sequence copy, campaign launch, n8n instance), agent (who is enrolled, opt-out sync, regions).

### B6. The n8n relay

- One workflow per CRM (HubSpot, Airtable, Attio), shipped as an importable n8n JSON template in `capabilities/sequences/tools/invokeiq/relay/`, in the same n8n instance as the tools workflow.
- Webhook node → verify `X-InvokeIQ-Signature` (HMAC SHA-256 over the raw body with the shared signing secret; reject on mismatch) → keep only replied and bounced → find the lead by contact email → create one inbound Activity: channel `email`, direction `inbound`, status `sent`, summary `<category>: <threadSummary>`, body = sentiment, score, subject, snippet, received time (bounced: summary `bounced`).
- The relay never changes stage, Do Not Contact, or anything else. Setup's tools step explains the import (or Webspenser sets it up as part of the done-for-you service).

## Order

1. Builder PR (Part A).
2. Sales-partner PR (Part B). Agent-side tests use fixtures; the workflow templates are checked by `tool_check.py` and in acceptance.
3. Acceptance on the user's InvokeIQ workspace and n8n: a test campaign, the user's own address as the lead, one full cycle (`Approach Drafted` → drag → `enroll` → reply through the relay → `sync-replies` → `Replied`); a bounce to a known-bad address; confirm the bounced/opened/clicked payloads and whether a link click carries the URL; confirm a claude.ai custom connector (cloud routines) can reach the authenticated MCP trigger.

## Out of scope

Enrichment (its own spec), other sending platforms (Instantly, Smartlead, …), marketing platforms for warm leads, LinkedIn automation, CRM-automation enrollment, argument pinning, voice calling, Gemini/Codex guard hosts.
