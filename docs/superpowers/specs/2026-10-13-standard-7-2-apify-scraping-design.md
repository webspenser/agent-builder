# Agent Standard 7.2: Apify scraping, pinned values — design

Status: approved in conversation on 2026-10-13 (sections 1–4). Third of
the series: owner notifications (7.0, done), the activity ledger (7.1,
done), this Apify capability, then goal-driven prospecting in
sales-partner, then upgrading the live Webspenser instance.

## Goal

Apify runs unattended, inside scheduled routines, behind a guard. Today
it never does: the schedule skill attaches only connectors whose tool has
a guard, Apify has none, so scheduled prospecting and research use web
search only even though `prospecting_sources` lists two Apify sources.

The operator's finish line for the whole series is a run that records
itself in the ledger and produces usable leads that meet the goal. This
spec's share of it: a scheduled prospect run scrapes real Google Maps
results through Apify, records each scrape in the ledger with its cost,
and writes scored leads to the CRM. The goal loop (cells, the Qualifier,
stop at N passing leads) is the next spec.

1. Two Apify actors, and only those two, can run: the Google Maps
   scraper and the contact-info scraper.
2. Each call's result limits are pinned to values the operator set at
   setup, and the agent cannot raise them by editing a file.
3. Dollars are bounded by the client's Apify account usage limit (hard)
   and the weekly cap, now measured from the ledger (instruction).

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Two specs in sequence: this one, then goal-driven prospecting | The operator chose to see real Apify leads first, then add the goal loop. |
| 2 | v1 actors: `compass/crawler-google-places` (Maps) and `vdrmota/contact-info-scraper` (emails, phones, social links); IDs confirmed by the live probe | Maps finds local businesses; contact details make a lead reachable. Full site text stays with web search. |
| 3 | Each client owns and pays for its own Apify account; Webspenser manages it | Same model as Resend: the client sees the spend and owns the data. |
| 4 | Two allowlists: the connector URL exposes only the two actors (`?tools=`), and the guard's `allow` names exactly their tools | The URL is set by a person and can be wrong; the guard holds even if the connector is added with the default URL, which also exposes `call-actor` (any actor). |
| 5 | Result limits are pinned with the existing `recipients` key, extended to numbers | No new grammar. A call asking for 5,000 places instead of 60 is blocked. |
| 6 | Pinned values must match the pushed copy, for every capability that pins values | Without it the agent could raise its own limits by editing `bindings/scraping.md`. Same trust model as the owner's address. |
| 7 | The hard dollar stop is the client's Apify account monthly usage limit | The guard cannot see cost. List lengths (search terms, URLs per call) cannot be pinned either. |
| 8 | The weekly cap `apify_spend_cap_usd_per_week` is checked against ledger `Cost USD` sums | The ledger now records each scrape's cost, so the cap becomes measurable instead of guessed. |
| 9 | `scraping` is required by the prospect and prepare activities | Apify is how this agent finds usable leads. Optional capabilities are out of scope. |
| 10 | `apify_site_scraper` is renamed `apify_contact_info` | It now returns contact details, not site text; the old name would mislead. |
| 11 | Agent Standard 7.2: builder 7.2.0, sales-partner 7.2.0 | Engine, `guard.sh` and a reserved invariant change. Development-phase versioning. |

## Part A — builder 7.2.0

### A1. Pinned values may be numbers

The `recipients` key keeps its name and grammar; STANDARD.md now
describes it as pinning any argument to bound values.

- A value at an `at` path may be a string, a number, or a list of
  strings and numbers. `null` counts as absent, as today. Booleans,
  objects and nested lists block (`<path>: a pinned value must be a
  string, a number, or a list of them`).
- A number matches a bound value when the bound value parses as a number
  and they are equal (`60`, `60.0` and binding `60` match). A string
  matches as today: trimmed, case-insensitive.
- The block messages become `<value> is not a pinned value (<bound>)`
  and, for a call that sets none of the paths, `<tool> names no pinned
  value at <paths>`.
  Every test and eval that expects `is not a pinned recipient` is
  updated (8 places in agent-builder, 6 in sales-partner).

### A2. Pinned bindings must match the pushed copy

`guard.sh` today checks `bindings/<cap>.md` against its git upstream
(`@{u}`) only inside the agent-policy exemption loop, for an
`owner_only_send` capability. In 7.2 that check moves into one shell
function, and the bind loop calls it before applying any bound tool's
policy that has a `recipients` entry. A missing, untracked, edited or
unpushed bindings file blocks every call to that tool with the existing
message (`bindings/<cap>.md must be committed and pushed before <cap>
can …`), reworded to name the capability generically. `owner_notify`
behaves exactly as before. The engine gains `--pins <tool guard.yaml>`,
printing each bound key the policy pins (one per line), so `guard.sh`
can ask without parsing YAML.

### A3. Invariant `pinned_inputs`

A new reserved invariant id, never `(acceptable)`:

- `pinned_inputs` — every input that limits a call's size comes only from
  values pinned in `bindings/<capability>.md` at interactive setup.

`tool_check.py`: a tool whose guard covers `pinned_inputs` needs an
`allow` list of exact tool names (no wildcards) and at least one
`recipients` entry; every allowed name is either pinned by an entry or
named in `usage.md` `## Probe` as a read (the same rule `owner_only_send`
uses today, shared code).

`schedule_check.py`: for a bound capability with `pinned_inputs`, the
bindings file needs a line for every key the tool pins, each a bare
value (same check as `owner_only_send`, shared code).

### A4. Docs and tests

STANDARD.md: the Guard policy `recipients` row and Semantics describe
pinned values (A1); Guard hook describes the pushed-copy check (A2);
Capabilities lists `pinned_inputs` among reserved ids; Validation and
the gate list the new checks. `CURRENT_STANDARD = "7.2"`, template and
builder manifests at 7.2.0.

Tests: engine numeric pins (equal passes; `60.0` = `60`; `61`, `true`,
an object and a nested list block); `guard.sh` blocks a pinning tool
whose bindings differ from `@{u}` and passes when they match;
`owner_notify` cases unchanged; `tool_check` and gate cases for
`pinned_inputs`.

## Part B — sales-partner 7.2.0

### B1. Probe the Apify connector (operator present)

The operator connects the hosted server in claude.ai with
`https://mcp.apify.com?tools=compass/crawler-google-places,vdrmota/contact-info-scraper`
on their own Apify account. The probe records, in
`agent-builder/docs/superpowers/notes/2026-10-13-apify-connector-probe.md`:

- the server prefix (`server_match`) and every exposed tool name;
- each actor tool's full input schema, and which arguments bound the
  size of a call (for Maps: the per-search result limit, the list of
  search terms, the location; for contact-info: start URLs, pages per
  site, crawl depth);
- the output shape, whether results are truncated (and the read-only tool
  that fetches a finished run's full results, if any), and whether the
  run's cost is returned;
- that `call-actor`, `search-actors` and `add-actor` are absent with the
  restricted URL, and what the default URL adds.

Every name in B2 marked *(probe)* is filled from this note.

### B2. Capability `scraping` and its Apify tool

`capabilities/scraping/contract.md`:

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `find_businesses` | `query`, `location` | listings: name, address, phone, website, category, rating, review count, place id, URL; plus the run's cost when reported | Retried once; then a `failed` step and an `error` event |
| `find_contacts` | `urls[]` (at most the instruction cap per call) | per URL: emails, phones, social links; plus the run's cost when reported | Same |

Invariants: `no_external_send`, `allowlisted_actors` (only the two
allowlisted actors run), `pinned_inputs`. All covered by the guard.

`tools/apify/identity.yaml`: `server_match: apify` *(confirmed by
probe)*.

`tools/apify/guard.yaml`:

```yaml
covers: [no_external_send, allowlisted_actors, pinned_inputs]
allow: [<maps tool>, <contact-info tool>, <full-results read tool, if any>]   # (probe)
deny: ["*call-actor*", "*call_actor*", "*search-actors*", "*add-actor*",
       "*store*", "*task*", "*dataset*", "*webhook*", "*schedule*"]   # adjusted so no allowed name matches
recipients:
  - tools: [<maps tool>]
    at: [<per-search result limit argument>]          # (probe)
    bound: max_places_per_search
  - tools: [<contact-info tool>]
    at: [<pages-per-site argument>]                   # (probe)
    bound: max_pages_per_site
  - tools: [<contact-info tool>]
    at: [<crawl-depth argument>]                      # (probe)
    bound: max_crawl_depth
```

A call that leaves a pinned argument out is blocked (`names no pinned
value`, A1), so the actor's own default can never apply.

`tools/apify/usage.md` maps both operations to the probed tools, says
how many search terms and URLs one call may carry (Maps: one search term
per call; contact-info: at most 10 URLs per call), and has `## Setup`
and `## Probe`:

- Setup: (1) the client owns the Apify account and sets a monthly usage
  limit in Apify Console; (2) add the connector with the restricted URL
  above; (3) the operator confirms the pinned values, written to
  `bindings/scraping.md`, then commit and push:

  ```
  max_places_per_search: 60
  max_pages_per_site: 3
  max_crawl_depth: 1
  ```

- Probe (read-only): confirm the exposed tools are exactly the allowed
  ones.
- If the probe showed cost is not returned: each actor's per-result price
  is recorded in `usage.md`, and the agent records an estimate in
  `Cost USD` with `Detail` marked `estimated`.

### B3. Wiring

- `agent.yaml`: `capabilities: crm, owner_notify, ledger, scraping`;
  `scraping` added to `activity_prospect` and `activity_prepare`;
  `standard: "7.2"`; hooks synced from the builder.
- `operating-config.md`: `prospecting_sources` values are
  `apify_google_maps`, `apify_contact_info`, `web_search` (`apollo`
  stays a stub). An instance still listing `apify_site_scraper` gets a
  clear stop: `apify_site_scraper was renamed apify_contact_info`. The
  interview's sources question uses the new names.
- The rule "scheduled runs use web search only; Apify is never attached
  to a routine" is removed from the prospector, preparer and README.
- Prospector: one `find_businesses` call per query; dedupe against the
  CRM, score and create leads as today. Each call is a ledger `step`:
  `Subject` the query and location (e.g. `HVAC contractor|Oakland`),
  `Items In` results returned, `Items Out` new `Scored` leads,
  `Cost USD` the run's cost.
- Preparer: `find_contacts` on the website of each lead it researches;
  emails, phones and social links go to Contacts with their source URL.
  Each call is a `step` with its cost.
- Weekly cap: before each Apify call the prospector and preparer sum this
  cap week's `Cost USD` from the ledger (`find_events` for both
  activities). If the next call would pass
  `apify_spend_cap_usd_per_week`, they write a `stop_condition` event,
  call `notify_owner(kind: alert)`, and stop scraping for the run.
- Guard block on an Apify call: stop the activity and
  `notify_owner(kind: error)` naming the block; never retry it.
- Digest Spend section: the week's Apify cost comes from the ledger.
- README: Apify is required (client's own account, a monthly usage limit
  set in Apify Console, the restricted connector URL); upgrade note from
  7.1 (bind `scraping`, push `bindings/scraping.md`, re-run `schedule`).
- Tests: policy cases from the probed schemas (both actors with in-limit
  inputs pass; `call-actor`, an unlisted actor, an over-limit input and
  a missing pinned argument block); schedule fixtures bind `scraping`;
  content assertions for the rename, the removed web-search-only rule,
  the cap check and the ledger step lines.

### B4. Live acceptance (operator present)

1. Probe (B1).
2. Interactive, on a test instance pointed at the operator's Attio, with
   the operator's OK: the prospector runs one Maps query with
   `max_places_per_search: 20`. Pass: the ledger has `run_started`, a
   `step` with `Cost USD`, and `run_finished`; scored leads exist in
   Attio at `Scored`.
3. Scheduled: one real routine run of the prospect activity with Apify
   attached writes its own ledger events and leads. Pass: the same
   checks, with `Trigger` `scheduled`.

Results go in the probe notes file.

## Out of scope

- The goal loop, cells, the Qualifier, `Cells`/`Listings` ledger tables:
  the goal-driven prospecting spec.
- Capping list lengths in the guard, numeric ranges (`<=`) instead of
  exact pinned values, optional capabilities, the website-content
  crawler.
- A pushed-copy check for ledger bindings (the ledger pins nothing; still
  a stated limit of 7.1).

## Order

1. Builder A1–A4 on `feat/apify`; tests green.
2. B1 probe (operator).
3. sales-partner B2 (capability, tool, guard from the probe), then B3.
4. B4 live acceptance (operator).
5. Release: builder 7.2.0, sales-partner 7.2.0.

## Acceptance

- Engine: a pinned numeric argument equal to its binding passes; a
  different number, a boolean, an object, a nested list, or a missing
  argument blocks.
- `guard.sh`: a bound tool that pins values is blocked while its
  bindings file differs from `@{u}`, and allowed when it matches;
  `owner_notify` behavior is unchanged.
- The Apify guard allows exactly the probed actor tools with in-limit
  inputs; `call-actor`, any other actor, an over-limit or missing pinned
  input is blocked. Shown by tests built from the recorded schemas.
- `schedule_check.py` fails a prospect activity whose `scraping` binding
  lacks a pinned key, and passes with all three.
- `bin/validate-agent.sh` passes sales-partner 7.2.0 and fails a
  contract that marks `pinned_inputs` `(acceptable)`.
- B4 steps 2 and 3 pass, recorded in the notes.
