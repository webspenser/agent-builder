# Agent Standard 7.0: owner notifications, recipient pinning — design

Status: approved in conversation on 2026-10-12. First of a series: owner
notifications (this spec), then the activity ledger, the Apify scraping
capability, and goal-driven prospecting in sales-partner, each with its
own spec.

## Goal

An agent may message its own business owner (status alerts, errors, run
summaries, the digest) and never anyone else. Today the standard has one
rule, `no_send`, enforced by tool-name globs, so an agent can't tell
"email the owner" from "email a prospect": both are the same send tool.
This spec draws the line on the recipient, enforced by the guard:

1. Split `no_send` into `no_external_send` (no message to anyone outside
   the business, ever) and `owner_only_send` (sending allowed only to
   recipients pinned at interactive setup).
2. New guard keys pin recipients and refuse arguments that override
   them.
3. The agent guard policy can exempt one capability's server from its
   send denies, only when that capability's tool covers
   `owner_only_send`.
4. Sales-partner drops every outbound path except owner notifications:
   no Gmail, no drafts in the owner's mailbox. Everything else it writes
   goes to the CRM. Owner notifications go through the client's own
   Resend account, from a no-reply address on the client's domain.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | `no_send` is renamed `no_external_send`; same strength, never `(acceptable)` | The meaning changes: the owner is no longer "anyone". The name says who is protected. |
| 2 | New invariant `owner_only_send`, coverable only by a tool guard with a `recipients` entry; never `(acceptable)` | A send capability with instruction-only recipients is the exact failure this prevents. |
| 3 | Recipients come only from `bindings/<capability>.md` lines written in interactive setup | The agent can't write bindings in a scheduled run, and nothing it reads (CRM data, scraped pages) can add a recipient. Prompt injection can't widen the list. |
| 4 | New guard key `refuse_args` | Gmail's `send_message` takes `draftId`, which sends an existing draft "as is" and ignores `to`/`cc`/`bcc`. A recipient check is only as strong as the arguments that can bypass it. |
| 5 | Agent guard policy key `exempt: [<capability>]` | The agent policy is deny-only and runs first, so it blocks an owner send before the tool policy sees it. The exemption names a capability, not a server: it applies only while that capability's bound tool covers `owner_only_send`. |
| 6 | One binding per capability stays the rule; multi-channel notify is out of scope | The gate already refuses a repeated `bind_` line. Slack or a second channel comes later as its own tool and design. |
| 7 | Sales-partner's first `owner_notify` tool is Resend's hosted MCP server (`https://mcp.resend.com/mcp`) | It is the only transactional email provider found with a hosted MCP server, which a routine can attach. Postmark and Mailgun servers run locally only; SES and Loops expose generic dispatchers the guard can't read. |
| 8 | Each client uses its own Resend account and domain | The client owns and pays for the account and sees its mail; Webspenser manages it. No shared sending dependency. |
| 9 | Sales-partner drops the Airtable CRM tool and the `email_drafts` capability | Airtable as CRM is a first-iteration leftover. The owner sends first touches from their own channel of choice; the agent only drafts into the CRM. |
| 10 | Agent Standard 7.0: builder 7.0.0, sales-partner 7.0.0, no git tags, CI keeps `validate@main` | Grammar and invariant change. Development-phase rule: version numbers carry no compatibility meaning, no migration notes. |

Unchanged: `covers`, `allow`, `deny`, `writes`, `unwrap`,
`unknown_writes`, `refuse_keys`, `bound_keys_only`, `rules`, the tool
layout, wrapped tools, activities and schedules (other than the gate
checks below).

## Part A — builder 7.0.0

### A1. Invariants

- `no_send` is renamed `no_external_send` everywhere: STANDARD.md,
  `_capability-template/contract.md`, `tool_check.py`,
  `schedule_check.py`, `check_manifests.py`, `validate-agent.sh`,
  `_template/skills/setup`, `_template/skills/add-tool`, tests. The old
  name is a validation error (`no_send was renamed no_external_send`),
  so nothing silently loses its protection.
- `owner_only_send` is new. A contract lists it when the capability
  sends to the owner. It can never be marked `(acceptable)`.
- A contract may not list both. A capability either never sends or
  sends only to the owner.

### A2. Guard key `recipients`

A list of `{tools, at, bound}` entries, the same flow-map shape as
`writes`.

```yaml
recipients:
  - tools: ["*send-email"]
    at: [to, cc, bcc]
    bound: recipient_email
```

- `tools`: tool-name globs, matched as in `allow`/`deny` (Semantics 1).
- `at`: paths in the tool input, with the `writes` path grammar.
- `bound`: a binding key name, `snake_case`.

**Semantics** (new step between Semantics 6 and 7). For each entry whose
`tools` match the call:

1. Collect the values at every `at` path. A string is one value; a list
   of strings is its items. An absent path is skipped. Any other shape
   (an object, a number, a nested list) blocks.
2. If no value was collected across all paths, block:
   `<tool> names no recipient at <paths>`.
3. Read every `<bound>: <value>` line in `bindings/<capability>.md` (the
   key may repeat; each line adds one allowed value). No such line
   blocks: `no <bound> line in bindings; re-run setup's tools step`.
4. Each collected value, trimmed and lowercased, must equal one bound
   value, trimmed and lowercased. A display-name form
   (`Owner <owner@example.com>`) is not unwrapped and does not match:
   it fails closed. Otherwise block:
   `<value> is not a pinned recipient (<bound>)`.

A binding line is a plain line, `<bound>: <value>`, with the same rules
as `field_<name>` lines (no bullet, no trailing note; one pair of
surrounding backticks or matching quotes is stripped). The value must
match `^[^\s<>"',;]+$`, or the call is blocked with
`<bound> must be a bare value`.

**Parse errors.** Missing or empty `tools`, `at` or `bound`; an invalid
path; `bound` not `snake_case`; an unknown key in an entry.

### A3. Guard key `refuse_args`

A flow list of top-level argument names: `refuse_args: [draftId,
replyToMessageId, replyThreadId]`. A call to a tool on the matched
server that holds any of them with a value other than JSON `null` or
an empty string is blocked: `<tool> may not use <arg>`. Names match
exactly (arguments are case-sensitive in every connector checked).

**Parse errors.** An empty list; an entry that is not a plain name
(`^[A-Za-z_][A-Za-z0-9_]*$`).

### A4. Agent guard policy `exempt`

```yaml
# guard.yaml — agent guard policy
covers: [no_external_send]
deny: ["*send*", "*reply*", "*forward*", "*publish*", ...]
exempt: [owner_notify]
```

- **Grammar.** `exempt` is optional: a flow list of capability names
  (`snake_case`). Allowed keys are now `covers`, `deny`, `exempt`.
- **Hook.** For each capability in `exempt`, `guard.sh` reads its
  `bind_` line, finds the bound tool, and adds the tool's `server_match`
  to the exempt list only when all of these hold: the tool has
  `identity.yaml` with a non-empty `server_match`, it has a readable
  `guard.yaml`, and that policy's `covers` includes `owner_only_send`.
  Otherwise the capability gets no exemption, and the deny list applies
  in full. It does not block on that by itself: an unbound notify
  capability simply can't send.
- **Engine.** `guard_policy.py --agent <guard.yaml> [label] [--exempt
  <server_match>]...`. When the text after `mcp__` contains an exempt
  `server_match` (case-insensitive substring, the same over-covering
  match as the `bind_` loop), `deny` is skipped for that call. Nothing
  else is skipped: the `bind_` loop still runs the tool's own policy,
  which must then pass the call (`allow`, `recipients`, `refuse_args`).
- **Validation.** Each name in `exempt` must be a listed capability
  whose contract has `owner_only_send`. `exempt` without such a
  capability is an error.

### A5. Tool checks (`tool_check.py`)

- A tool whose contract has `no_external_send` must ship `guard.yaml`
  covering it (today's `no_send` rule, renamed).
- A tool whose contract has `owner_only_send` must ship `guard.yaml`
  that covers it, has an `allow` list, and has at least one `recipients`
  entry. Every `allow` pattern must be matched by the `tools` of some
  `recipients` entry, or be a read (the author lists reads explicitly
  in `allow`; `tool_check.py` reports any `allow` pattern that no
  `recipients` entry covers as `<pattern> is allowed but no recipients
  entry pins it` unless the tool's `usage.md` `## Probe` names it as a
  read call).

### A6. Setup and the gate

- **Setup's tools step.** For a capability with `owner_only_send`, ask
  the operator for each pinned value the tool's `usage.md` `## Setup`
  lists (for example `recipient_email`), repeat each back, and write the
  lines to `bindings/<capability>.md` after the operator confirms. Then
  offer one test notification to the pinned recipient; the operator
  confirms before it is sent. Refuse to bind when the tool's `covers`
  lacks `owner_only_send`.
- **Gate (`schedule_check.py`).** An activity using an `owner_only_send`
  capability is unattended-safe only when the tool's guard covers it,
  the bindings hold at least one line for every `recipients` `bound`
  key, and the agent guard policy lists the capability in `exempt`. A
  `no_external_send` capability needs the agent policy to cover
  `no_external_send` (today's rule, renamed).

### A7. Docs and tests

- STANDARD.md: Capabilities (invariants), Guard policy (Keys, Semantics,
  Parse errors for `recipients` and `refuse_args`), Agent guard policy
  (`exempt`), Guard hook, Setup — tools step, The unattended gate,
  Validation. Standard `"7.0"`.
- `_capability-template/contract.md` names both invariants.
- `docs/how-it-works.md` gets one plain-words paragraph: the agent can
  message the owner and nobody else, and how that is enforced.
- Tests: `test-guard-policy.sh` (recipients match, mismatch, missing
  binding, display-name form, empty recipients, list and string shapes,
  refuse_args present/null/empty, parse errors), `test-guard.sh`
  (exemption granted, refused when the tool lacks `owner_only_send`,
  refused when unbound, tool policy still enforced after the
  exemption), `test-tool-check.sh`, `test-schedule-check.sh`,
  `test-validate-agent.sh` (old `no_send` name, `exempt` validation,
  both invariants in one contract).

## Part B — sales-partner 7.0.0

### B1. Remove the Airtable CRM tool

Delete `capabilities/crm/tools/airtable/`. Remove Airtable from the CRM
contract, README, `send-digest`, Attio's `usage.md`, tests and evals.
Historical specs and plans under `docs/superpowers/` stay as written.

### B2. Remove `email_drafts`

- Delete `capabilities/email_drafts/`.
- `agent.yaml`: `capabilities: crm, owner_notify`;
  `activity_digest: crm, owner_notify`.
- `operating-config.md`: remove `digest_channel` and `digest_delivery`.
  `sending_identity` stays: it is the "from" line written into drafted
  email Activities in the CRM.
- AGENT.md, README, interview, setup, tests and evals no longer mention
  Gmail drafts.

### B3. `owner_notify` capability

`capabilities/owner_notify/contract.md`:

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `notify_owner` | `kind` (`alert`, `error`, `summary`, `digest`), `subject`, `body`, `payload` (optional structured text) | the provider's message id | a send the provider rejects, or no bound recipient |

Invariants: `owner_only_send`.

Rules in the contract: the recipient is always the bound value, never an
argument; the subject starts with `[<agent name>] <kind>:`; the body is
plain text; `payload` is appended as a fenced block so a person or a
later skill can read it back.

### B4. Resend tool

`capabilities/owner_notify/tools/resend/`:

- `identity.yaml`: `capability: owner_notify`, `provider: resend`,
  `server_match: resend`.
- `usage.md`:
  - `## Setup`: a Resend account owned by the client (check the current
    plan allows a second team member for Webspenser, or use the plan
    that does); the client's sending domain verified in Resend (DNS
    records added); a no-reply sender on that domain; the hosted
    connector `https://mcp.resend.com/mcp` added in claude.ai. Pinned
    values: `recipient_email` (the owner's address, may repeat),
    `sender_email` (the verified no-reply address).
  - `## Probe`: read-only calls that confirm the sender's domain is
    verified, recording the domain in `bindings/owner_notify.md`.
  - The mapping of `notify_owner` to the exact send tool and arguments.
- `guard.yaml`, shaped as below; the tool names and argument paths are
  filled from the connector's live tool list in the first
  implementation step (B4 prerequisite), and every other Resend tool
  (broadcasts, audiences, contacts, domains writes, API keys) stays
  outside `allow`:

```yaml
covers: [owner_only_send]
allow: [<the single-email send tool>, <read tools named in ## Probe>]
deny: ["*broadcast*", "*audience*", "*contact*", "*delete*", "*api_key*"]
recipients:
  - tools: [<the single-email send tool>]
    at: [to, cc, bcc]
    bound: recipient_email
  - tools: [<the single-email send tool>]
    at: [from]
    bound: sender_email
refuse_args: [<every argument that can change recipients or send
              something other than the given body, found in the schema>]
```

**B4 prerequisite.** Before writing `guard.yaml`, connect the hosted
server in a test session and record its full tool list and the send
tool's input schema in the implementation plan. The guard is written
against that record, not against documentation. If the send tool can
schedule a send (a `scheduled_at` argument) or send a stored template
that carries its own recipients, those arguments go in `refuse_args`.

### B5. Agent guard policy

```yaml
covers: [no_external_send]
deny: [today's list]
exempt: [owner_notify]
```

### B6. Who calls `notify_owner`

- `send-digest`: composes the digest as today and delivers it with
  `notify_owner(kind: digest)`. No Gmail draft.
- AGENT.md "Escalate to human when": each case also calls
  `notify_owner(kind: alert)`.
- A scheduled run that stops on a missing input calls
  `notify_owner(kind: error)` with what is missing, before its final
  report.
- AGENT.md guardrail rewritten: the agent never sends a message to
  anyone but the owner, and to the owner only through `owner_notify`.

### B7. Release

`version: 7.0.0`, `standard: "7.0"`, manifests (`plugin.json`,
`marketplace.json`, `.codex-plugin`, `gemini-extension.json`) and the
README updated. Hooks re-copied byte-identical from the builder.

## Out of scope

- The activity ledger (Airtable), the Apify scraping capability,
  goal-driven prospecting: separate specs, in that order after this one.
- Slack or any second notify channel, and multi-channel bindings.
- Upgrading the live Webspenser instance: done after the prospecting
  spec ships, as its own step.

## Order

1. Builder A1–A7 on a branch; tests green.
2. Sales-partner B1 and B2 (removals), validator green against the new
   builder.
3. B4 prerequisite (probe the Resend connector), then B3–B6.
4. B7 release.

## Acceptance

- A Resend send to the pinned owner address from the pinned sender
  passes the guard; the same call to any other address, with a
  display-name form, with an extra `cc`, or with any `refuse_args`
  argument is blocked. Shown by `test-guard.sh` cases built from the
  recorded schema.
- With `owner_notify` unbound, or bound to a tool whose guard lacks
  `owner_only_send`, every `*send*` call is blocked by the agent policy.
- `schedule_check.py check` passes `digest` only when the Resend
  binding has `recipient_email` and `sender_email` lines and the agent
  policy exempts `owner_notify`.
- `bin/validate-agent.sh` passes sales-partner 7.0.0, and fails a
  fixture contract that still says `no_send`.
- Sales-partner has no Airtable CRM tool, no `email_drafts`, and no
  `digest_delivery` or `digest_channel` keys.
