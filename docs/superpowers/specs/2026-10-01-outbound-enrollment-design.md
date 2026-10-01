# Agent Standard 6.0 and sales-partner 6.0: outbound enrollment — design

Status: design agreed in conversation on 2026-10-01; awaiting the user's review of this written spec. This is the first sub-project of the "outbound partner" redesign. The second, enrichment (Google Places, Yelp Fusion, LinkedIn via Apify), gets its own spec.

## Goal

Make sales-partner an outbound partner. The agent researches, scores and personalizes. The owner approves the plan in the CRM. Then the approved email touch goes out through the client's cold-email platform (**InvokeIQ** first): the agent adds the lead to the campaign for its score band with the personalization filled in, and InvokeIQ sends the sequence. The agent never writes or sends the emails themselves. Replies and bounces come back into the CRM.

LinkedIn and call touches keep today's model: the agent drafts them, the owner does them.

## What the user said (the brief)

- Cold prospects are the main case. Marketing platforms (Loops, Kit, Mailchimp, MailerLite) forbid non-opted-in contacts, so the platform is a cold-email tool. The user tried Instantly for about a year and chose **InvokeIQ** instead; other platforms (Instantly included) can be added later as more tools under the same contract.
- Approval stays in the CRM. **One drag approves the plan**: the owner refines drafts, sets dates, voids what they don't want, then moves the lead to a new stage, **`Ready to Send`** ("grabs attention" better than "Approved"). No partial approvals. Dragging back to `Approach Drafted` before the enroll run picks it up cancels it.
- Several lanes: email goes out by enrollment; LinkedIn and calls wait for the owner on their own dates.
- Replies come back to the CRM through an **n8n** webhook relay.
- Countries: an allow-list, US by default.
- Sending setup (domains, DKIM, unsubscribe footer) is the client's job.

## InvokeIQ facts this design relies on

- REST API, no connector or MCP server: `https://api.invokeiq.com/api/v1`, header `Authorization: Bearer ivq_live_…`.
- `GET /me` (workspace, quota), `GET /campaigns` (active, paused, draft, completed), `GET /analytics?campaignId=`.
- `POST /contacts` `{campaignId, email, firstName, lastName, customFields}` enrolls a contact into a campaign. It is an idempotent upsert: calling it again for an enrolled contact updates its custom fields without disrupting its sequence.
- `POST /suppression` `{emails[], reason}` suppresses addresses workspace-wide.
- Webhooks (Settings → Webhooks, optional HMAC SHA-256 secret in `X-InvokeIQ-Signature: sha256=<hex>`): prospect replied (`contact.replied`, first reply only; payload `data.contact{email, firstName, lastName}`, `sentiment`, `sentimentScore`, `category`, `threadSummary`, `subject`, `snippet`, `receivedAt`), email opened, link clicked, email bounced. Only the reply payload is documented; the others are confirmed at acceptance.
- No unsubscribe event and no endpoint that lists replies or unsubscribes.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Two layers: the **lead stage** is the plan's state; each **Activity** is one touch (channel, draft, date, status) | Approval is per plan, execution is per touch. |
| 2 | New stage **`Ready to Send`** between `Approach Drafted` and `Contacted` (13 stages). Only a human writes it: every CRM guard policy lists every other stage as writable and leaves `Ready to Send` out | "One drag approves the plan", enforced by mechanism, with no engine change. |
| 3 | Activity statuses become **`draft` → `sent` / `voided`**. `approved` is removed. The agent may update an Activity to `sent` or `voided` | Approval moved to the lead stage. `sent` records a fact (the agent enrolled the email, or the owner did the LinkedIn touch); writing it sends nothing. |
| 4 | `draft_only` is restated: the agent creates outbound Activities only at `draft`, updates them only to `sent`/`voided`, never rewrites a draft body (5.0 `forbid: update`), and never writes `Ready to Send` | Keeps "only a human approves" a mechanism. |
| 5 | New capability **`sequences`** with an **InvokeIQ** tool | One contract, one folder per platform. |
| 6 | The agent reaches InvokeIQ through a **small MCP server bundled in sales-partner**, exposing only `get_workspace`, `get_campaigns`, `enroll_contact`, `suppress`. The key comes from `INVOKEIQ_API_KEY` in the environment; the agent never sees it | The guard only sees MCP calls; Bash/curl would bypass it, and a generic HTTP server is a dispatcher. Exposing only four operations makes the allow list structural. |
| 7 | The email draft's body **is** the personalization: labelled lines, one per InvokeIQ custom field (`icebreaker: …`, `company: …`) | The owner reviews and edits the exact values that will be sent. `forbid: update` guarantees the agent can't change them after approval. |
| 8 | Enrollment is **done by the agent** in a scheduled `enroll` activity | Approve in the CRM; the next scheduled run picks it up. |
| 9 | "Enroll only leads at `Ready to Send`" is **instruction-only, accepted by the operator** (`accept_instruction_only`) | The guard cannot read the CRM at call time. The gap is named and accepted. |
| 10 | **Argument pinning**: `enroll_contact` may only target campaign IDs recorded in bindings | Limits enrollment to the client's chosen campaigns. Reused later for Gmail `to`, Airtable `baseId`, HubSpot `objectType`. |
| 11 | `enroll` runs once per lead: never for a lead that already has a `sent` email Activity | `POST /contacts` silently updates an enrolled contact's fields mid-sequence. |
| 12 | Score bands map to campaigns: `sequence_bands` in `operating-config.md` (for example `high: 80`, `mid: 65`), each band bound to one campaign ID | The brief's "different lists by score". |
| 13 | Webhooks go to an **n8n relay that only records facts**: it verifies the signature and writes an inbound Activity on the lead. The agent's scheduled `sync-replies` makes every decision (stage, Do Not Contact, suppression) | One guarded, tested copy of the rules; the relay stays trivial per CRM. |
| 14 | v1 uses **replied** and **bounced**. **Opened** and **link clicked** are not recorded | Opens are inflated by mail privacy features and scanners; they would clutter the owner's Activities and the touch count. |
| 15 | Link-click unsubscribes are a **known limit**: InvokeIQ suppresses them, the CRM is not told. The digest says so | No unsubscribe event exists. Follow-up: ask InvokeIQ for one, or use the link-clicked URL if it carries it. |
| 16 | `allowed_countries` in `operating-config.md`, default `[US]`. EU/UK need an operator legitimate-interest note; Canada needs an operator-confirmed consent basis | Cold email law differs by country. |
| 17 | Agent Standard 6.0, builder 6.0.0, sales-partner 6.0.0; no backward compatibility | Dev-phase rule. |

## Part A — agent-builder 6.0.0

### A1. Argument pinning (`pins:`)

A new block list in a tool's `guard.yaml`:

```yaml
pins:
  - tools: [enroll_contact]
    arg: campaignId           # a top-level argument, or a dotted / list path like `at`
    bound: campaign_          # allowed values: every bindings value whose key starts with campaign_
    required: true            # a matching call without the argument blocks
  - tools: [manage_crm_objects]
    arg: "createRequest.objects[].objectType"
    values: [companies, contacts, tasks, notes]
```

- An item holds `tools` (globs, matched as in `allow`), `arg` (a path as in `writes.at`, ending at a scalar or a list of scalars), exactly one of `bound` (a bindings key prefix) or `values` (a flow list), and optional `required: true`.
- For a call whose tool matches, every value found at `arg` must equal (trimmed, case-insensitive) one allowed value. A path absent from the call passes unless `required: true`. A `bound` prefix with no bindings lines blocks: `<arg> has no recorded values; re-run setup's tools step`. Otherwise: `<arg> may only be one of the recorded <prefix>* values` / `<arg> may only be one of <values>`.
- A `bound` prefix matches keys like `campaign_high`, `campaign_mid`; values follow the existing bare-ID rule. `pins` does not need `writes`.
- Parse errors: unknown item key, both or neither of `bound`/`values`, empty `tools`, invalid `arg` path, `required` other than `true`.

### A2. Operator-accepted instruction-only invariants

- A contract may mark an invariant acceptable: ``- `enroll_ready_only` (acceptable) — …``. Unmarked invariants can never be accepted (`no_send`, `draft_only`, `dnc_one_way`, `no_delete` stay mandatory).
- `instance.yaml` may hold `accept_instruction_only: <invariant>[, <invariant>]`. Only setup writes it, after showing the operator the risk in plain words.
- The schedule gate treats an accepted, acceptable invariant as covered and prints `ACCEPTED (instruction-only): <capability>: <invariant>` on every check. Accepting an unmarked invariant is a gate failure.
- `tool_check.py` and the validator parse the `(acceptable)` mark.

### A3. Bundled tool servers

- A tool folder may ship `server.py`: a stdio MCP server, Python standard library only, exposing only the operations its `usage.md` maps.
- `identity.yaml` gains `server: bundled` and `key_env: <VAR>`. The server reads the key from that variable, never prints or returns it, and fails each call with `<VAR> is not set` when it is missing.
- The agent registers each bundled server in `.mcp.json` (Claude Code) and `mcpServers` in `gemini-extension.json`, command `python3 ${CLAUDE_PLUGIN_ROOT}/capabilities/<cap>/tools/<tool>/server.py`, server name = the tool's `server_match`. The validator checks that every `server: bundled` tool is registered and every registration points at one.
- `tool_check.py`: a bundled server's tool names must equal the operation-tool names in `usage.md`.
- Setup: the key is set by the user in their own terminal (`read -rs INVOKEIQ_API_KEY && export INVOKEIQ_API_KEY`) or in the cloud environment's environment variables, never in chat or a file.

### A4. Docs and tests

STANDARD.md (pins; the `(acceptable)` mark; `accept_instruction_only`; the unattended gate; bundled servers), `docs/how-it-works.md`, `docs/writing-an-agent.md`, the `add-tool` skill (propose pins for arguments that pick a destination). Tests for every parse error and semantic above.

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
| `get_campaigns` | — | campaigns (id, name, status) |
| `enroll_contact` | `campaign_band, email, first_name, last_name, variables` | the platform's contact id |
| `suppress` | `emails, reason` | ok |

Invariants: `no_send` (no operation sends; enrollment hands the lead to a campaign the client set up and launched); `campaigns_bound_only` (enrollment targets only bound campaign IDs; pins); `no_campaign_control` (the agent never creates, launches, pauses or edits a campaign; structural, since the server has no such operation); `enroll_ready_only` **(acceptable)** — only leads at `Ready to Send`, not Do Not Contact, in an allowed country, never enrolled before.

`capabilities/sequences/tools/invokeiq/`:
- `identity.yaml`: `capability: sequences`, `provider: invokeiq`, `server_match: invokeiq`, `server: bundled`, `key_env: INVOKEIQ_API_KEY`.
- `server.py`: the four operations over the REST API. `enroll_contact` takes `campaignId` (the guard pins it); `customFields` come from `variables`.
- `usage.md`: operation mapping; `## Probe`: `get_workspace` (records `workspace`), `get_campaigns` (the owner picks one campaign per band; records `campaign_<band>: <id>`; warns if a chosen campaign is not active); `## Setup`: create the API key in InvokeIQ, set `INVOKEIQ_API_KEY`, and the webhook relay (B5).
- `guard.yaml`: `covers: [no_send, campaigns_bound_only, no_campaign_control]`, `allow` the four tools, `pins` on `enroll_contact`'s `campaignId` (`bound: campaign_`, `required: true`).
- `bindings/sequences.md` also holds `variables: <name>, <name>` (the campaign's custom fields), recorded by the interview.

### B3. Activities and sub-agents

- **Approacher:** for email, writes the personalization draft (labelled lines, one per `variables:` name) and for other enabled channels the usual drafts; stage → `Approach Drafted`. Each draft gets a date: email now; each other channel `touch_spacing_days` (new `operating-config.md` key, default 3) after the previous touch. The owner can change any date before dragging.
- **New `enroll` activity** (`activity_enroll: crm, sequences`, schedulable): for each lead at `Ready to Send` with a standing email `draft`: check not Do Not Contact, country in `allowed_countries`, an email address, no earlier `sent` email Activity; parse the variables; `enroll_contact` into the band's campaign; `update_activity(sent)`; `update_stage(Contacted)`. A lead with no email draft but a `sent` LinkedIn/call Activity moves to `Contacted`. Skipped leads are reported in the digest.
- **New `sync-replies` activity** (`activity_sync-replies: crm, sequences`): reads inbound Activities the relay created since the last interval (`query_activities`, idempotent actions, no processed flag). Reply: lead at `Contacted` → `Replied`; an opt-out category or wording → `update_lead(Do Not Contact = true)` and `suppress(reason: "opt-out reply")`. Bounce: the contact's email is marked bounced, the lead returns to `Approach Drafted` with reason "email bounced" so the owner can pick another contact or channel, and the bounce is not counted as a touch. It also suppresses every lead whose Do Not Contact became true since the last interval.
- **Follow-up:** skips email follow-ups for leads with an enrolled email touch.
- **Digest:** counts leads at `Ready to Send`, enrolled, skipped (with reason), replies, bounces, opt-outs; states that link-click unsubscribes are not visible to the CRM.
- **Interview / setup:** score bands and the campaign per band, the campaign's custom field names, allowed countries (with the EU/UK note or Canada basis when enabled); explains and records `accept_instruction_only: enroll_ready_only`; reminds about a separate sending domain.

### B4. Compliance

- `allowed_countries` (decision 16); a lead without a known country is not enrolled.
- Opt-out replies and CRM Do Not Contact → suppression. Link-click unsubscribes: known limit (decision 15).
- `how-it-works` gains a "who is responsible for what" table: client (domain, DNS, footer address, sequence copy, campaign launch), agent (who is enrolled, opt-out sync, regions).

### B5. The n8n relay

- One workflow per CRM (HubSpot, Airtable, Attio), shipped as an importable n8n JSON template in `capabilities/sequences/tools/invokeiq/relay/`.
- Webhook node → verify `X-InvokeIQ-Signature` (HMAC SHA-256 over the raw body with the shared secret; reject on mismatch) → keep only replied and bounced → find the lead by contact email → create one inbound Activity: channel `email`, direction `inbound`, status `sent`, summary `<category>: <threadSummary>`, body = sentiment, score, subject, snippet, received time (bounced: summary `bounced`).
- The relay never changes stage, Do Not Contact, or anything else. Setup's tools step explains the import (or Webspenser sets it up as part of the done-for-you service).

## Order

1. Builder PR (Part A).
2. Sales-partner PR (Part B), including `server.py` tested against recorded API fixtures (no network in tests).
3. Acceptance on the user's InvokeIQ workspace: a test campaign, the user's own address as the lead, one full cycle (`Approach Drafted` → drag → `enroll` → reply through the n8n relay → `sync-replies` → `Replied`); a bounce to a known-bad address; confirm the bounced/opened/clicked payloads and whether a link click carries the URL; confirm how the cloud environment holds `INVOKEIQ_API_KEY`.

## Out of scope

Enrichment (its own spec), other sending platforms (Instantly, Smartlead, …), marketing platforms for warm leads, LinkedIn automation, CRM-automation enrollment, voice calling, Gemini/Codex guard hosts.
