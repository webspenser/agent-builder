# Apify connector probe (Task 5)

Probed 2026-10-13 from a Claude Code session, with the claude.ai Apify
connector added by the operator at
`https://mcp.apify.com?tools=compass/crawler-google-places,vdrmota/contact-info-scraper`
on the operator's own Apify account (monthly usage limit set by the operator).

> **Superseded by the guard as shipped.** The "Refused" lists below describe
> the probe-time plan to block add-ons with `refuse_args`. The shipped guard
> instead uses `only_keys` allowlists (the accepted argument names at `$` and
> `url` only inside `startUrls[]`), so any argument not listed is blocked,
> including options the vendor adds later. Read the Refused lists as
> background on what the extra options cost, not as the enforced rule. See
> `capabilities/scraping/tools/apify/guard.yaml` in sales-partner.

## Server prefix

Tool names appear as `mcp__claude_ai_Apify__<tool>`. The server segment,
lowercased, is `claude_ai_apify`. The tool's `server_match` is `apify`: the
engine matches it as a substring of the server segment, so it also covers a
locally configured server named `apify`.

## Tools exposed by the restricted URL

| Tool | Kind | In the guard |
|---|---|---|
| `compass--crawler-google-places` | actor run (Maps) | allow, pinned |
| `vdrmota--contact-info-scraper` | actor run (contact details) | allow, pinned |
| `get-actor-run` | read (run status, storage IDs) | allow (probe read) |
| `get-dataset-items` | read (run results) | allow (probe read) |
| `get-key-value-store-record` | read | not allowed (not needed) |
| `abort-actor-run` | other write | not allowed |

`call-actor`, `search-actors`, `add-actor`, `fetch-actor-details` and the
docs, task, store and schedule tools are absent with the restricted URL. The
default URL adds a generic `call-actor` that can run any actor, so the guard
denies those names in case the connector is ever re-added with the default URL.

## Result handling

An actor tool waits at most `waitSecs` (0–45, default 30) and returns run
metadata, not items: `runId`, `status`, `stats.runTimeSecs`,
`stats.computeUnits`, `storages.datasets.default.id` and `itemCount`, plus a
`nextStep` naming `get-dataset-items`. If the run is not finished at the cap,
poll `get-actor-run` (`waitSecs` up to 45). Read results with
`get-dataset-items` and a `fields` projection, because the full Maps item has
about 64 fields, mostly irrelevant.

**Cost is not returned.** Neither the run result nor `get-actor-run` includes a
USD figure, only `computeUnits`. Both actors are pay-per-event, so the agent
records an estimate: `items × price per item`, marked `estimated` in `detail`.

## Maps — `compass--crawler-google-places`

Input schema: see the connector (recorded at probe time). Arguments that
matter:

- **Size (pin):** `maxCrawledPlacesPerSearch` (integer). **Left empty, it
  scrapes every place**, so it must always be passed with the pinned value.
- **Query (allowed):** `searchStringsArray` (array of strings; one term per
  call by instruction), `locationQuery` (free text), or the structured
  `city`, `state`, `county`, `postalCode`, `countryCode`; `language`;
  `waitSecs`.
- **Refused: paid add-ons or different inputs.** `refuse_args` blocks any
  value except null or "" (including `false`), so the agent omits these:
  `scrapeContacts`, `maximumLeadsEnrichmentRecords`,
  `leadsEnrichmentDepartments`, `verifyLeadsEnrichmentEmails`, `maxReviews`,
  `maxImages`, `maxQuestions`, `scrapePlaceDetailPage`,
  `enableCompetitorAnalysis`, `maxCompetitorsToAnalyze`, `includeWebResults`,
  `scrapeDirectories`, `scrapeOrderOnline`, `scrapeTableReservationProvider`,
  `scrapeSocialMediaProfiles`, `scrapeImageAuthors`,
  `scrapeReviewsPersonalData`, `reviewsFilterString`, `reviewsOrigin`,
  `reviewsSort`, `reviewsStartDate`, `categoryFilterWords`,
  `placeMinimumStars`, `searchMatching`, `skipClosedPlaces`, `website`,
  `allPlacesNoSearchAction`, `startUrls`, `placeIds`, `customGeolocation`.
  Several of these ($ filters such as `website: withWebsite` and
  `skipClosedPlaces`) may be worth paying for later. The prospecting spec can
  allow them deliberately.
- **Output fields used:** `title`, `categoryName`, `categories`, `address`,
  `street`, `city`, `state`, `postalCode`, `phone`, `website`, `totalScore`,
  `reviewsCount`, `placeId`, `url`, `permanentlyClosed`,
  `temporarilyClosed`, `claimThisBusiness`.

### Live call (operator approved)

`searchStringsArray: ["HVAC contractor"]`, `locationQuery: "Alameda, CA, USA"`,
`maxCrawledPlacesPerSearch: 5`, `language: en`, `waitSecs: 45`. Run
`C4yGVcAUW2PALabZq`: `SUCCEEDED` in 11.3 s, 0.0126 compute units, 5 items.
Nothing was written to the CRM.

- **Finding:** every result was in Livermore. The free-text location
  "Alameda, CA, USA" resolved to Alameda **County**. The prospector should
  pass the structured `city` + `state` + `countryCode` fields, not
  `locationQuery`, when it means a city.
- **Results:** the top results by default ranking were large, well-reviewed
  operators (up to 4,999 reviews). That is an ICP and ranking question for the
  goal-driven prospecting spec, not a scraping issue.

## Contact info — `vdrmota--contact-info-scraper`

- **Size (pin):** `maxRequestsPerStartUrl` (pages per website), `maxDepth`
  (link depth; empty means unlimited), and `maxRequests` (pages for the whole
  call; default 9,999,999). All three are pinned. `maxRequests` is a third key
  the spec did not name.
- **Query (allowed):** `startUrls` (array of `{url}`, at most 10 per call by
  instruction), `mergeContacts`, `considerChildFrames`, `sameDomain`,
  `waitUntil`, `proxyConfig` (not required: the live schema
  requires only `startUrls`, and `proxyConfig` has a default,
  `{useApifyProxy: true}`; the shipped allowlist does not admit it, so the
  agent leaves it out), `waitSecs`. `sameDomain` cannot be pinned: pinned
  values are text or numbers, and true/false fail closed. The pinned
  `maxRequests` bounds an off-domain crawl.
- **Refused:** `maximumLeadsEnrichmentRecords`, `leadsEnrichmentDepartments`,
  `verifyLeadsEnrichmentEmails`, `scrapeSocialMediaProfiles`, `useBrowser`.
- Not run live in this probe.

## Pricing (Apify Store pages, 2026-10-13, "from" prices, lowest plan tier)

- Maps: from $1.50 per 1,000 scraped places. Paid add-ons cost extra (all
  refused). The FREE-plan price is higher than "from"; the operator reads the
  real per-run cost from Apify Console for run `C4yGVcAUW2PALabZq` to calibrate.
- Contact info: from $1.05 per 1,000 scraped pages; the Free plan's $5 credit
  is described as about 2,500 pages, so roughly $2 per 1,000.
- Estimates the agent uses until calibrated: **$0.004 per place** and
  **$0.002 per page**. These are deliberately above the "from" prices, so the
  weekly cap trips early rather than late.

## Values for Task 6

| Placeholder | Value |
|---|---|
| `<SERVER>` | `claude_ai_Apify` (server_match `apify`) |
| `<MAPS_TOOL>` | `compass--crawler-google-places` |
| `<CONTACTS_TOOL>` | `vdrmota--contact-info-scraper` |
| `<READ_TOOL>` | `get-actor-run`, `get-dataset-items` |
| `<MAPS_LIMIT_ARG>` | `maxCrawledPlacesPerSearch` → `max_places_per_search` |
| `<CONTACTS_PAGES_ARG>` | `maxRequestsPerStartUrl` → `max_pages_per_site` |
| `<CONTACTS_DEPTH_ARG>` | `maxDepth` → `max_crawl_depth` |
| (new) | `maxRequests` → `max_pages_per_call` (default 30 = 10 sites × 3 pages) |
| `<REFUSED_ARGS>` | the union of the two Refused lists above |
| cost field | none; estimate as above, `detail` marked `estimated` |

## Live acceptance (Task 8, interactive, 2026-10-15)

The instance `live-agents/webspenser-sales-partner` ran an interactive prospect
activity (run `prospect-20261015T1543Z`), with the plugin loaded from the 7.2
branch. The operator limited it to one query. The guard blocked nothing.

- **Apify:** run `3ynSGmg2fLzpWX0fY` (Maps, `plumber` in Alameda, CA, with the
  structured city fields): `SUCCEEDED` in 73.7 s, 0.082 compute units,
  14 items. Every result was in Alameda, which confirms the probe finding.
- **Ledger:** three rows with seq 1–3: `run_started` (7-day spend $0.00 of
  the $20 cap), one `step` with subject `plumber|Alameda, CA`, items 14 in and
  8 out, cost $0.056 estimated (14 × $0.004), and `run_finished`.
- **CRM:** 9 new leads at Scored (one 80, five 50, one 37.5, two 35) and
  1 Disqualified (Roto-Rooter, a national chain). Two existing leads were left
  untouched, and two duplicate listings were merged. The 80 is a plumber whose
  Maps listing has no website (buying trigger #3).
- **Gaps:**
  - The agent counted 8 new Scored leads in the ledger, but Attio has 9.
  - `agent_version` reads 7.1.0 until the release bumps it.
  - At prospecting, the trigger and decision-maker criteria score 0 unless the
    listing has no website. So 50 is the usual ceiling, and only no-website
    listings clear `research_threshold` 60. That is for the goal-driven
    prospecting spec.
