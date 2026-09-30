# Agent Standard 4.0: `writes`, tool setup choices, and the HubSpot tool — design

Status: approved in conversation on 2026-09-30. This is sub-project 7, part 2.

## Goal

Ship a HubSpot CRM tool for sales-partner that is unattended-safe the same way the Attio and Airtable tools are. Two changes to the standard come first:

1. **One way to describe a write.** HubSpot creates and updates records through the same tool, `manage_crm_objects`. The difference is where the values sit: under `createRequest` or under `updateRequest`. Today's guard policy decides create versus update from the tool's name alone. The three keys `create_tools`, `update_tools` and `values_at` together describe one idea, "what a write looks like", and they cannot describe HubSpot. A single `writes:` list replaces all three.
2. **A clear choice when a tool needs fields.** When a tool's probe finds missing fields, setup offers two options:
   - create them yourself, from the tool's `## Setup` section;
   - run the tool's `bootstrap.py` with an API key, in your own terminal.

   The key never enters the chat or any file.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | The guard policy key `writes:` (a list of `{kind, tools, at}`) replaces `create_tools`, `update_tools` and `values_at` | It describes one concept once. It covers both name-based tools (Attio) and path-based ones (HubSpot). |
| 2 | Agent Standard 4.0: a breaking change to the guard policy format. Builder 4.0.0, sales-partner 4.0.0, a new action tag `v4`, and `v3` stays frozen | The format changes. With a new tag, nothing is force-moved. This follows the dev-phase policy: no backward compatibility. |
| 3 | No `ask`/approval-at-call-time mechanism | It would work only on Claude Code and add upkeep. The two setup choices work on every host. |
| 4 | A tool that needs fields documents them in a `## Setup` section of `usage.md`. `bootstrap.py` stays optional. When `bootstrap.py` exists, `## Setup` must too | A person can always set up by hand, and the script becomes a convenience. |
| 5 | Setup's tools step: when the probe finds missing fields, offer "create them yourself" or "run bootstrap.py in your own terminal". Never ask for the key in chat | The conversation is logged, and so is a `!` command's text. The key belongs only in the environment of the terminal that runs the script. |
| 6 | HubSpot lead = **Company** with a custom `sp_stage` dropdown. Activity (outreach draft) = **Task** using HubSpot's built-in `hs_task_status`. Research = **Note** on the company | This works on the free tier and keeps one record per business. The Deals pipeline stays free for real deals. **Amended 2026-09-30:** the free portal allows no custom properties on Tasks (Settings → Properties lists only Contact and Company), so the planned custom `sp_status` is dropped. Status maps to `hs_task_status`: draft = `NOT_STARTED`, approved = `IN_PROGRESS` or `WAITING`, sent = `COMPLETED`, voided = `DEFERRED`. The guard allows only `NOT_STARTED` on create and `DEFERRED` on update. The Tasks view filtered to Not started is the approval queue. |
| 7 | HubSpot `bootstrap.py` uses a private-app token in `HUBSPOT_TOKEN` | This matches Attio's `ATTIO_API_KEY` pattern. |
| 8 | The connector's `confirmationStatus`: in interactive runs, follow its confirmation step (show the change table on the first write, then offer to skip confirmations for the session). Scheduled runs pass `CONFIRMATION_WAIVED_FOR_SESSION` | Scheduled runs may not ask questions, and the guard enforces the invariants whatever this field says. |
| 9 | Setup (interview, connecting, field setup, binding) happens on the operator's work machine. Scheduled routines only run activities | The allow list bars routines from changing fields: HubSpot's schema tools are not on it. |

The following stay unchanged:
- `covers`, `allow`, `deny`, `unwrap`, `unknown_writes`, `refuse_keys` and `rules`;
- bindings;
- `tool_check.py`'s identity rules;
- activities and schedules;
- the custom-tool flow.

## Part A — Agent Standard 4.0 (builder 4.0.0)

### The `writes:` guard policy key

```yaml
writes:
  - kind: create            # create | update
    tools: [add-record-to-list, create-record]   # tool-name suffix globs, as in allow/deny
    at: [entry_values, values]                   # argument paths, as values_at took
  - kind: update
    tools: [update-record, update-list-entry-by-id, update-list-entry-by-record-id, upsert-record]
    at: [entry_values, values]
```

**Semantics for one tool call:**

1. The **matching entries** are those whose `tools` match the call's tool name. Matching uses the same suffix matching as `allow`/`deny`.
2. For each matching entry, collect the value maps found at each of its `at` paths, and tag each map with that entry's `kind`. A listed path that is absent from the call is skipped.
3. Check every collected map against `rules`, using the rule's `create:` or `update:` values for the map's kind, or `any:` as today.
4. **Unknown writes.** A value map sits at a path listed in some entry, and either no entry matches the tool, or the tool matches entries but none of them lists that path (a matched tool writing at a path listed only by other entries):
   - `unknown_writes: block` blocks the call ("<tool> writes values at <path>, which no writes entry for this tool lists" when the tool matched some entry);
   - `unknown_writes: update` (the default) checks those maps as `update`. This is unchanged from today.
5. A tool matched by entries of both kinds is allowed, e.g. HubSpot's `manage_crm_objects` with a create entry at `createRequest.objects[].properties` and an update entry at `updateRequest.objects[].properties`. Each map gets the kind of the entry whose path found it.

**Parse errors.** Each is a `PolicyError`, and the policy fails closed.
- `kind` is not `create` or `update`.
- `tools` or `at` is missing or empty.
- An `at` path is not a valid path.
- An entry has an unknown key.
- `rules` or `refuse_keys` is present without `writes`.
- Any of the old keys `create_tools`, `update_tools` or `values_at` is present. The message is `<key> is the Agent Standard 3 form; 4.0 uses writes: (see STANDARD.md "Guard policy")`.

The strict YAML subset parser must read a list of maps whose values are flow lists, as `rules` entries already are.

### Validator and tool checker

- `CURRENT_STANDARD = "4.0"`.
- `tool_check.py` gets one more rule: if the tool folder has `bootstrap.py`, `usage.md` must have a `## Setup` section. The failure message is `<label>/usage.md: needs a ## Setup section (bootstrap.py is optional; people must be able to create the fields by hand)`.
- Guard policies are still parsed through `guard_policy.parse`, so the old keys fail there, and the validator and `tool_check` report that.

### Setup skill, tools step

The probe sub-step changes. Run the tool's `## Probe` calls. If they report missing fields or objects, and the tool has a `## Setup` section, offer two choices:

1. **Create them yourself.** Show the `## Setup` list: each field with its object, type and options, as plain steps in that system's UI. When the user says it's done, probe again.
2. **Use an API key.** Only offered when the tool has a `bootstrap.py`. Show:
   - the exact command, `python3 <package>/capabilities/<cap>/tools/<tool>/bootstrap.py`;
   - the environment variable it reads and the key scopes it needs, from the `## Setup` section.

   Tell the user to run it in **their own terminal**, with the key set only in that terminal's environment. Never paste the key into this conversation or any file. When they say it's done, probe again.

The probe must pass before binding. Setup's opening message tells the user up front what they'll need:
- connect each system to their host;
- fields may need creating, by hand or with an API key.

### Docs

Update STANDARD ("Guard policy", "Tools", "Setup — tools step", Validation, "Changes from 3.0"), `docs/how-it-works.md` (vocabulary, guard diagram and the setup text), the wizard, `docs/writing-an-agent.md` and the README (`validate@v4`). The builder `_capability-template` guard policy moves to `writes`.

## Part B — sales-partner 4.0.0

### Existing tools

- Convert the `guard.yaml` for Attio, Airtable and Gmail to `writes:`, with the same behavior. Every existing guard-policy test in `tests/test-policies.sh` (or its equivalent) keeps passing.
- Attio's `usage.md` gains `## Setup`: the fields its `bootstrap.py` creates, as manual steps, plus the key and scopes the script needs. Its existing Probe text already points to the script, so it now offers both choices.
- Airtable's `usage.md` gains `## Setup`: the tables and fields to create by hand. Airtable has no `bootstrap.py`.
- Gmail needs no fields and no Setup section.

### The HubSpot tool: `capabilities/crm/tools/hubspot/`

This is built with `/sales-partner:add-tool` in package mode, against the claude.ai HubSpot connector. It is the skill's first real use.

**`identity.yaml`**: `capability: crm`, `provider: hubspot`, `server_match: hubspot`. Tool names look like `mcp__claude_ai_HubSpot__…` and `mcp__HubSpot__…`.

**Data model.** All custom properties carry the `sp_` prefix.

| Contract | HubSpot object | Properties |
|---|---|---|
| Lead | Company | Native: `name`, `domain`, `phone`, `address`, `city`, `state`, `zip`, `country`. Custom: `sp_stage` (the 12 stages, as a dropdown), `sp_stage_changed_at` (datetime), `sp_stage_reason`, `sp_score` (number), `sp_score_breakdown`, `sp_industry`, `sp_size`, `sp_location`, `sp_source`, `sp_source_url`, `sp_email` (the general inbox), `sp_next_action`, `sp_next_action_due` (date), `sp_do_not_contact` (checkbox) |
| Contact | Contact, associated with its company | Native: `firstname`, `lastname`, `jobtitle`, `email`, `phone`, `hs_linkedin_url` (or the portal's LinkedIn field, which the probe finds). Custom: `sp_role` (decision-maker / influencer / gatekeeper), `sp_verified` (checkbox), `sp_notes` |
| Research | Note, associated with its company | `hs_note_body` holds labelled lines: type, summary, source URL, date, hook. `hs_timestamp` = date |
| Activity | Task, associated with its company and contact | Built-in fields only (amended 2026-09-30: the free tier has no custom Task properties). `hs_task_subject`, `hs_timestamp`; `hs_task_status` holds the status (NOT_STARTED / IN_PROGRESS or WAITING / COMPLETED / DEFERRED for draft / approved / sent / voided); `hs_task_type` holds the channel (EMAIL / CALL / LINKED_IN_MESSAGE or LINKED_IN_CONNECT / TODO); `hs_task_body` starts with `Direction:` and `Summary:` lines (and `Outcome:` once voided), then a blank line, then `draft_body` |

**`usage.md`** maps all eleven contract operations onto `search_crm_objects`, `get_crm_objects` and `manage_crm_objects`, keeping the contract's semantics:
- `create_lead` dedupes by `domain`, then normalized phone, then name + address.
- `update_stage` writes `sp_stage` and `sp_stage_changed_at` in one update.
- `log_activity` is create-only, at `sp_status: draft`.
- `update_activity` writes only `voided`.
- `upsert_contact` matches on email, then name + title.

It also gives:
- the operator's views: the Tasks queue where `sp_status = draft`, and a Companies view by `sp_stage`;
- the `confirmationStatus` rule (decision 8);
- the connector's limit of 10 objects per request.

**`## Probe`** (read-only):
- `get_user_details`: record `hub_id:`. Companies, contacts, tasks and notes must be writable.
- `get_properties`:
  - on companies: `sp_stage` has the 12 options, and `sp_stage_changed_at` and `sp_do_not_contact` exist;
  - on contacts: `sp_role` has the three options;
  - on tasks: `sp_status` has the four options and `sp_direction` exists.
- Report any missing property by name.
- `bindings/crm.md` gets `hub_id:` and no field IDs, because HubSpot writes fields by name.

**`## Setup`** lists every custom property above, with its object, label, internal name, type and options, as steps in HubSpot (Settings → Properties). It also gives the bootstrap route:
- `HUBSPOT_TOKEN` from a private app;
- the scopes the script needs: company, contact and task schema read and write (the build confirms their exact names);
- the command.

**`guard.yaml`:**

```yaml
covers: [draft_only, dnc_one_way, no_delete]
allow: [get_user_details, get_organization_details, discover_hubspot_schema, search_crm_objects,
        get_crm_objects, get_properties, search_properties, search_owners, query_crm_data,
        tool_guidance, manage_crm_objects]
deny: ["*delete*", "*merge*"]
writes:
  - kind: create
    tools: [manage_crm_objects]
    at: ["createRequest.objects[].properties"]
  - kind: update
    tools: [manage_crm_objects]
    at: ["updateRequest.objects[].properties"]
unknown_writes: block
rules:
  - field: sp_status
    create: [draft]
    update: [voided]
  - field: sp_do_not_contact
    update: ["true"]
```

The build confirms the allow list against the connector's real read-tool names.

`no_delete` is covered because:
- deny blocks `*delete*` and `*merge*`;
- the allow list admits no other write tool;
- `manage_crm_objects` has no delete operation.

**`bootstrap.py`:**
- Reads `HUBSPOT_TOKEN` from the environment, and stops with instructions if it is unset.
- Creates each missing property (and property group `sales_partner`) through HubSpot's CRM properties API, and adds any missing option to `sp_stage`, `sp_status` and `sp_role`.
- Is idempotent and never deletes or renames anything.
- Uses the stdlib only (`urllib`), like Attio's.
- Stops with a plain message naming the property and HubSpot's error when the portal refuses a property. The likely causes are:
  - custom properties on tasks being unavailable on the free tier;
  - a limit on custom properties.

### Other sales-partner changes

- Setup's tools step is ported from the template.
- README: HubSpot appears among the supported CRMs, with the two setup choices.
- The interview and the other skills mention HubSpot only where they list CRMs.
- `agent.yaml` and the four manifests go to 4.0.0 and `standard: "4.0"`, and CI moves to `validate@v4`.
- `migrations/4.0.0.md`: an instance with a custom tool's `guard.yaml` that uses `create_tools`, `update_tools` or `values_at` rewrites them as `writes:`. Show the diff and confirm first. Nothing else changes for instances.

## Release order

1. Merge the builder PR.
2. The user creates tag `v4`. This is a new tag, not a force-push.
3. The sales-partner PR (CI on `@v4`) goes green, and the user merges it.
4. Catalog README: both agents at 4.0, and HubSpot named for sales-partner.

## Acceptance

1. **Fields.** On the user's HubSpot portal, create the fields by one of the two routes; the user picks which. The probe then passes. If the portal refuses custom task properties, stop and revisit decision 6; Ticket is the fallback.
2. **Interactive smoke test.** On a throwaway instance with HubSpot and Gmail bound, the agent (not a hand-written call):
   - creates one test company at `sp_stage: New`;
   - upserts one contact;
   - logs one draft task.

   Show the records' links.
3. **Guard.** Through the real `guard.sh`, these are blocked:
   - `manage_crm_objects` updating a task to `sp_status: approved`;
   - creating a task at `sent`;
   - setting `sp_do_not_contact` to `false`;
   - any `*delete*` tool;
   - `manage_custom_properties`, which is not on the allow list.

   A draft create and a `voided` update are allowed.
4. **Schedule gate.** `schedule_check check` PASSes for `digest` with HubSpot and Gmail bound.
5. **Old format.** A 3.0 `guard.yaml` fails the 4.0 validator, with the message naming `writes`.
6. **Cleanup.** Delete the test company, contact and task. The user does this in HubSpot, or approves it through the connector outside the agent's guard.

## Review focus

1. **Both kinds on one tool.** `manage_crm_objects` carrying both `createRequest` and `updateRequest` in one call: each map must be checked with its own kind. A create at `approved` hidden next to a harmless update must still block.
2. **Values at an unlisted path.** A write whose values sit at a path no entry lists, e.g. a future `upsertRequest`. `unknown_writes: block` must block it when it matches no entry. When the tool matches an entry but writes at a path that no entry lists anywhere, the values are unchecked. A path listed only by other entries is an unknown write (semantics step 4), so the guard never checks less than 3.0 did. That is a stated limit, and the allow list plus deny rules are the backstop.
3. **Case and type of values.** HubSpot sends booleans and enums as strings (`"true"`, `"draft"`). Rules compare case-insensitively. `true` versus `"true"` must behave the same.
4. **Old keys left in a custom tool's `guard.yaml` after the upgrade.** The guard must fail closed, blocking calls to that tool, with the migration message. The schedule gate must FAIL.
5. **The API key.** No skill text ever asks for the key in chat or writes it to a file. `bootstrap.py` never echoes it.

## Out of scope

- Deals as leads.
- Association labels.
- HubSpot marketing tools.
- A Claude-Code-only `ask` mechanism.
- Compliance work.
- The run-time re-gate for schedules.
