# Scheduled Runs on Claude Routines — Design (Agent Standard 2.1)

**Date:** 2026-09-29
**Status:** Design approved in conversation; pending spec review
**Implements:** sub-project 5 ("Runtime") of [Agent Distribution Architecture](./2026-09-27-agent-distribution-architecture-design.md)
**Builds on:** [Agent Standard 2.0 — Guard Policies](./2026-09-29-guard-policy-design.md)
**Repos:** `webspenser/agent-builder` (Standard 2.1; builder 2.1.0) and `webspenser/sales-partner` (2.1.0)

## Purpose

Let an agent's activities run on a schedule with nobody at the keyboard
— for example sales-partner's Monday prospecting and digest — on Claude
cloud routines, and only when every rule those activities depend on is
enforced by the guard, never by the prompt alone.

## What the routine tests established (2026-09-29)

Run against a throwaway private instance repo and one routine, with the
Attio connector attached; nothing was written to Attio.

1. **Routines ignore marketplace plugins enabled in the repo.** The
   instance repo's `.claude/settings.json` (`extraKnownMarketplaces`,
   `enabledPlugins`) was cloned but no plugin loaded: no entry-hook
   context, no guard. An "approve" write reached Attio (it failed only
   because the entry ID was fictitious). The routine record's own
   `enabled_plugins` / `extra_marketplaces` fields could not be set
   through the API.
2. **Hooks declared in the repo's own `.claude/settings.json` run.** A
   `PreToolUse` hook in the repo blocked the connector calls.
3. **A cloud-environment setup script loads the plugin.** With the
   environment's setup script running
   `claude plugin marketplace add webspenser/agent-library` and
   `claude plugin install sales-partner@webspenser`, the session had the
   entry-hook context (`# Agent: sales-partner 2.0.0`, `Instance folder:
   /home/user/<repo>`), the approve write was blocked by the guard policy
   before reaching Attio, and reads worked. The script ran in about 3
   seconds and its result is cached.
4. **Connectors** are attached to the routine and appear as
   `mcp__<Name>__<tool>` (e.g. `mcp__Attio__…`); `server_match` matches
   them.
5. Routines clone the repo on every run, run with no permission
   prompts, and can push only to `claude/` branches.

Decision: instances stay thin plugin-mode repos; the **cloud
environment** carries the agents.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Runtime | Claude cloud routines, one per scheduled activity | Runs with the laptop closed; proven above |
| Agent in the cloud | The environment's setup script installs the catalog and each agent plugin | Proven; instances stay thin; one place per account |
| Environment | One per account, e.g. "webspenser-agents", used by every agent routine | The setup script is account-level; the guard is silent outside instances, so sharing is safe |
| Plugin updates | The setup script starts with one comment line per agent naming its version (`# sales-partner 2.1.0`); the schedule skill tells the user to update it when the agent version changes | Changing the script should invalidate the cached install (confirmed in acceptance) |
| Routine creation | Guided, then verified: the schedule skill prints exact form values; the user creates the routine in the web UI; the skill finds it through the routines API and checks it | Creation needs IDs only an existing routine reveals and relies on a research-preview API; verification needs only reads |
| Unattended gate | An entry may be scheduled only if every capability its activities use is bound and every contract invariant of each is in the bound adapter's `guard.yaml` `covers` | The agreed unattended-safe rule |
| Scheduled runs and the repo | Scheduled runs never edit or commit instance files | Routines can only push to `claude/` branches; the work lands in connected systems (CRM, drafts) |
| Versions | Standard 2.1 (additive to 2.0); builder 2.1.0; sales-partner 2.1.0 | Development phase: validator checks only 2.1 |

## Agent Standard 2.1

### Activities (package)

`agent.yaml` declares each schedulable activity and the capabilities it
uses, one flat key per activity:

```yaml
activity_prospect: crm
activity_prepare: crm
activity_approach: crm, email_drafts
activity_follow-up: crm, email_drafts
activity_digest: crm, email_drafts
```

- Activity names are kebab-case; values are a comma-separated list of
  capability names from `capabilities`, or `none`.
- Each activity is a Workflow step described in `AGENT.md`; its
  instructions say how to run it unattended.
- An agent with any `activity_*` key must ship `skills/schedule/SKILL.md`.

### `schedules.yaml` (instance)

Flat keys at the instance root:

```yaml
timezone: America/New_York
schedule_prospect: "Monday 07:00"
then_prospect: prepare
schedule_digest: "Monday 08:00"
routine_prospect: trig_01…
routine_digest: trig_01…
```

- `schedule_<activity>`: when it runs — a weekday (or `daily`) and a
  24-hour time, in `timezone` (an IANA name).
- `then_<activity>` (optional): activities to run after it in the same
  session, comma-separated.
- `routine_<activity>`: the routine's ID, written by the schedule skill
  after verification.
- Every activity named must be an `activity_*` in `agent.yaml`.
- The interview (or setup) writes `timezone` and the `schedule_*` /
  `then_*` lines; nothing else in the instance declares schedules.

### The scheduled prompt

Every routine's prompt is exactly:

> Scheduled run of `<activity>`[, then `<next>`, …] (unattended).
> Follow this agent's instructions for each activity, in order. Do not
> ask questions and do not edit or commit files in this repository. If
> something needs the operator, stop and say exactly what.

Agents must make every schedulable activity runnable to its stop
conditions under this prompt: no questions, no instance-file edits,
work recorded in connected systems only.

### The schedule skill (`skills/schedule/SKILL.md`)

Shipped in the template; generic (reads everything it needs from
`agent.yaml`, `instance.yaml`, `schedules.yaml`, bindings, and the
adapters). Steps:

1. **Read** `schedules.yaml`. For each `schedule_<activity>` entry,
   collect the activity and its `then` activities, and the union of
   their capabilities from `agent.yaml`.
2. **Gate.** For each capability: it must be bound in `instance.yaml`,
   and every invariant of its contract must be in the bound adapter's
   `guard.yaml` `covers`. Otherwise refuse that entry and name each
   uncovered invariant and the fix (bind an adapter whose policy covers
   it). Entries that pass continue.
3. **Repo check.** The instance is a git repository with a GitHub
   remote, pushed and clean, with `instance.yaml`, `schedules.yaml`,
   `bindings/`, and `context/` committed. Otherwise say what to do.
4. **Environment.** Print the setup script for this agent:

   ```bash
   # <agent> <version>
   claude plugin marketplace add <catalog_repo>
   claude plugin install <agent>@<catalog>
   ```

   and tell the user to create (once) or update a cloud environment —
   name suggestion "webspenser-agents" — whose setup script contains
   these lines, merged with any other agents' lines, and to keep the
   version comment current on every agent update.
5. **Form values.** For each passing entry print: routine name
   `<agent>: <activity> (<repo name>)`; repository; environment; the
   connectors to attach (one per bound capability, named after its
   provider); the schedule (weekday and time in `timezone`, and the
   equivalent UTC cron); and the prompt above.
6. **Verify.** When the user says it is created, list routines through
   the routines API (`RemoteTrigger` `list`/`get` in Claude Code) and
   find it by name. Check: repository URL; enabled; prompt text exact;
   an attached connector for each bound capability; and that
   `next_run_at` falls on the intended weekday and local time. Report
   every mismatch. When all match, write `routine_<activity>` to
   `schedules.yaml` and remind the user to commit and push it.
   Without routines API access, print a manual checklist instead.
7. **Smoke run (optional).** Offer "Run now" through the API, warning
   that a real activity does real work (CRM records, drafts); then read
   the run log and report whether the entry-hook context loaded and
   whether the guard was active (the log shows the plugin's hooks), and
   the run's result.
8. **Changes.** Re-running the skill re-checks every entry; it never
   deletes routines (the API cannot); it tells the user which routines
   to disable or delete in the web UI when an entry was removed or
   fails the gate.

### Validator (2.1)

In addition to the 2.0 checks, and with `standard: "2.1"` required:

- `activity_*` keys: kebab-case names; values are `none` or a
  comma-separated list of names in `capabilities`.
- Any `activity_*` key requires `skills/schedule/SKILL.md`.

### Template and wizard

- `_template/`: `standard: "2.1"`; `skills/schedule/SKILL.md`.
- Wizard: asks which Workflow steps can run on a schedule and writes
  `activity_*` keys; tells the author each must run to completion under
  the scheduled prompt.
- `STANDARD.md`: new "Activities and schedules" section (activities,
  `schedules.yaml`, the scheduled prompt, the schedule skill, the
  cloud-environment setup script, the unattended gate) and the 2.1
  validation rules.

## sales-partner changes (2.1.0)

- `agent.yaml`: `standard: "2.1"`, `version: 2.1.0`, and the five
  `activity_*` keys above.
- `schedules.yaml` replaces the `timezone` and `schedules` keys in
  `context/operating-config.md`; `interview-business` writes it; setup's
  context-files list is unchanged except the interview now also writes
  `schedules.yaml` at the instance root.
- `AGENT.md` "Scheduled activities" and `operating-config.md` "Running
  on a schedule" point at `schedules.yaml` and the schedule skill; the
  cron / n8n / manual-routine instructions are removed.
- Each schedulable Workflow step states its unattended behavior: no
  questions; stop and report when a needed input is missing; write
  only to connected systems.
- `send-digest` reads its `digest` schedule from `schedules.yaml`.
- Content tests updated.

## Verification

- Builder and sales-partner suites ALL GREEN; the validator passes
  sales-partner 2.1.0 and `_template`.
- Acceptance on the throwaway repo, turned into a real 2.1 instance
  (Attio and Gmail bound, minimal context, a `schedule_digest` entry):
  run the schedule skill end to end —
  - the gate passes for `digest` (crm + email_drafts, all covered) and
    refuses an entry whose capability is bound to an uncovered adapter;
  - the user updates the environment setup script and creates the
    routine from the printed values; the skill verifies it;
  - a smoke run of `digest` loads the agent (entry-hook context), runs
    guarded, and ends with at most one Gmail draft to the operator and
    no other writes;
  - confirm how the routine's cron is interpreted (UTC or local) from
    `next_run_at`, and that editing the setup script's version comment
    re-runs the install.
  Then the user deletes the test routine and repo.

## Review Focus

1. **Gate correctness** — an entry using a capability bound to an
   adapter without full `covers` must be refused, including through
   `then` activities.
2. **Verification drift** — a routine missing a connector, pointing at
   another repo, or with an edited prompt must be reported, not
   accepted.
3. **Unattended behavior** — no scheduled activity path asks a question
   or edits instance files.
4. **Timezone** — the printed UTC cron and the verified `next_run_at`
   match the intended local time.
5. **Stale plugin** — the setup-script version comment is what forces a
   re-install; the skill must say so on every run.

## Out of scope

- A GitHub Actions runner; Desktop "Local" scheduled tasks; creating
  routines through the API; non-Claude hosts.
- Webhook or GitHub-event triggers.
- Run history or dashboards beyond the routine's own run log.
