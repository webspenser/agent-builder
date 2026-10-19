# Agent Standard 7.3: fixed values and URL rules — design

Date: 2026-10-18. Builds on Standard 7.2 (pinned values, `only_keys`,
`limits`). Ships as **builder 7.3.0** with **Standard 7.3**. Sales Partner
adopts it in its open 8.1.0 PR (webspenser/sales-partner#24) before that
PR merges.

## Why

Two automated security reviews of Sales Partner 8.1 flagged the same two
gaps in the Apify guard:
- **The reviews actor's `personalData` can't be enforced.** It defaults to
  `true` (reviewer names, IDs, profile URLs). The guard engine can pin
  only text and numbers, and fails closed on true/false, so
  `personalData: false` rests on an instruction.
- **Outbound URL arguments are unconstrained.** The contact scraper, the
  Facebook ads count and the website reader take `startUrls[].url`, which
  can point anywhere, including a URL carrying data in its path or query
  string. A prompt-injected run could use Apify to fetch such a URL. 7.2
  accepted this as a stated limit.

The operator chose to close both properly, in a form that works for any
tool added later, not just these.

## Goals

1. **Fixed values.** A guard policy can require that an argument, at any
   path, equals an exact JSON value written in the policy: `true`,
   `false`, a number, a string or `null`. Optionally the argument must be
   present. This closes the `personalData` gap and covers the other
   true/false and comma-string settings 8.1 leaves to instructions:
   `onlyTotal: true`, `saveMarkdown: true` and
   `removeElementsCssSelector`.
2. **URL rules.** A guard policy can constrain any argument holding a URL:
   - schemes;
   - hosts: an exact list, or any public host;
   - path: root only, any, or a prefix;
   - query and fragment: allowed or forbidden.

   It always refuses user info, non-default ports, IP-address hosts,
   local, internal and single-label hosts, and anything that doesn't
   parse cleanly.
3. **Sales Partner 8.1 adopts both** in PR #24:
   - **reviews:** `personalData: false` is required;
   - **Facebook:** `onlyTotal: true` is required, and only `facebook.com`
     and `www.facebook.com` page URLs are accepted, with no query;
   - **website reader:** `saveMarkdown` and the remove-selector are fixed;
   - **website reader and contact scraper:** https site roots only, on
     public hosts.

## Non-goals

- Knowing which host belongs to which lead. A guard check sees only the
  one tool call in front of it, so it can't confirm that a URL is the
  lead's own website.
- Guarding the agent's built-in web fetch or web search. Those aren't
  MCP tools under a tool guard.
- Rewriting existing policies or changing how existing keys behave.

## Anti-goals

- Any existing policy or call that behaves differently under 7.3. The new
  keys only add checks.
- A new key that fails open. An unknown option, a malformed entry or a
  value the engine can't parse blocks the call.
- A URL check that a reasonable parser difference can bypass. Examples:
  - a backslash in the URL;
  - `https:/example.com`;
  - mixed-case schemes;
  - percent-encoded hosts;
  - a trailing dot;
  - IDN or punycode tricks;
  - whitespace or control characters.

  A URL the engine can't parse into exactly one unambiguous scheme, host,
  port, path, query and fragment is blocked.

## Engine changes (`_template/hooks/guard_policy.py`)

### New key `fixed`

A list of entries `{tools, at, value, required}`.
- `tools` and `at` use the same grammar and validation as `limits`.
- **`value`** is required, and is a scalar written in the policy:
  - unquoted `true` or `false` → a JSON boolean;
  - unquoted `null` → JSON null;
  - an unquoted strict decimal (the `_as_number` grammar) → a number;
  - a quoted string → that string.
  - An unquoted token that is none of these is a parse error, so string
    values must be quoted. This removes any doubt about type.
- **`required`** is optional, `true` or `false`, and defaults to `false`.

**Semantics.** For each entry whose `tools` match the call, for each path:
- **Value found:** each value at the path must equal `value` exactly, and
  in type: boolean `false` is not `0` and not `"false"`, and `5` equals
  `5.0` (number equality as Decimal). Text equality is exact and
  case-sensitive, because these are protocol values, not names.
  - A mismatch blocks with `<tool> must send <path> = <value> (got
    <got>)`.
- **Path absent:**
  - with `required: true`, the call blocks with `<tool> names no <path>`;
  - otherwise the path is allowed.
- **Shape mismatch:** if walking the path meets the wrong shape, the call
  blocks, as with the existing walkers.

**Why `fixed` values live in the policy.** They are safety settings of the
tool, not operator choices. They are not bindings, `--pins` doesn't list
them, and the pushed-copy check doesn't apply to them. They change only
with the agent's release, through review.

### New key `urls`

A list of entries `{tools, at, schemes, hosts, path, query, fragment, required}`.
- `tools`, `at` and `required` behave as in `limits`.
- **`schemes`** is required: a non-empty list from `https` and `http`.
- **`hosts`** is required. It is either:
  - a non-empty list of exact hostnames, matched case-insensitively after
    lowercasing ASCII; or
  - the single word `public`, which means any host that passes the
    always-on host checks.

  There are no wildcards.
- **`path`** is required, and is one of:
  - `root`: empty or `/` only;
  - `any`;
  - a quoted prefix starting with `/`, matched on segment boundaries:
    `/pages` matches `/pages` and `/pages/x`, not `/pagesx`.
- **`query`** and **`fragment`** are optional: `forbid` (the default) or
  `allow`.

**Semantics.** For each matched entry and path, every value found must be
a string. A non-string blocks with `<path> must be a URL string`. The
string is then checked, and any failure blocks with
`<tool> <path>: <reason>`. All of the following are checked:

1. **Clean characters.** The string has no ASCII control characters, no
   whitespace and no backslash, and it is at most 2048 characters.
2. **Exact shape.** It matches `scheme://authority[path][?query][#fragment]`
   exactly. The scheme is lowercase letters only and is in `schemes`; a
   mixed-case scheme is refused, not lowercased.
3. **Authority.**
   - It has no `@` (user info).
   - A port is refused unless it is the scheme's default, written
     explicitly or left out.
   - The host is not empty, is not an IP literal (IPv4 dotted, decimal or
     hex forms, or a bracketed IPv6), and has at least two labels.
   - The host's labels are ASCII LDH (letters, digits, hyphen), each 1 to
     63 characters, with no leading or trailing hyphen and no trailing
     dot.
   - The host contains no `%`.
   - A label starting `xn--` is allowed only when the host is in an exact
     `hosts` list.
4. **Not local.** The host is not `localhost`, and does not end in
   `.localhost`, `.local`, `.internal`, `.lan`, `.home.arpa` or `.test`.
5. **Host rule.** The host is in `hosts`, or `hosts` is `public` and the
   checks above passed.
6. **Path rule.** The path satisfies `path`. A path containing `..` or a
   percent-encoded `/` (`%2F`) is refused unless `path` is `any`.
7. **Query and fragment.** A query or fragment, including a lone `?` or
   `#`, is refused unless allowed.

**Implementation.** The engine uses its own strict parser, not
`urllib.parse`, so its view can't differ from a lenient parse. Tests
cover each refusal reason.

### Parsing and validation

- **Policy validation.** `_validate` rejects:
  - unknown entry keys;
  - an empty `at` or `tools`;
  - a bad `value` token;
  - an unknown `schemes` item;
  - an empty `hosts` list;
  - a `hosts` that is neither a list nor `public`;
  - a `path` that is neither `root` nor `any` nor a `/` prefix;
  - a `query` or `fragment` other than `forbid` or `allow`.
- **Fail closed.** All of these are parse errors, which block every call
  under the policy.
- **Order.** `fixed` and `urls` run with the other per-call checks, in
  `problems`. They add problems and never remove any.

### Documentation and gates

- **STANDARD.md, Guard policy:** the Keys table (two rows), Semantics (two
  subsections), Parse errors, and a "Stated limits" update. URL rules
  can't tie a host to a lead, so with `hosts: public` and `path: root`
  data can only ride in the hostname itself.
- **`tool_check.py`:** `fixed` and `urls` are accepted keys. They don't
  count as pinning, because they read no bindings.
- **`schedule_check.py`:** no change, since neither key reads bindings.
- **The current standard becomes "7.3".** `bin/lib/check_manifests.py`'s
  `CURRENT_STANDARD` and `_template/agent.yaml` change. Sales Partner is
  the only Agent Standard agent in the organization; `roi-calculator`
  has no `agent.yaml`.
- **Builder release:** version 7.3.0, with the template's hooks synced.

### Tests (agent-builder `tests/test-guard-policy.sh`)

- **`fixed`:**
  - `false` required: `false` passes; `true`, `0`, `"false"`, `null` and
    an omitted key block, the last because it is required.
  - `true` not required: an omitted key passes.
  - A number: `5` and `5.0` pass, `"5"` blocks.
  - A quoted string with commas and spaces matches exactly, and a case
    change blocks.
  - A nested path such as `a[].b` works.
  - Bad policy values fail parsing: an unquoted word, an empty value, an
    unknown key.
- **`urls`:**
  - Allowed: a valid root (`https://example.com`, `https://example.com/`)
    and an exact host with a page path (`https://www.facebook.com/somepage`).
  - Refused, each with its own case:
    - a path under `root`;
    - a query, a lone `?`, a fragment;
    - `http` when only `https` is allowed, and an uppercase `HTTPS://`;
    - user info, `:8443`, and `:443` (the default, which is allowed);
    - IPv4 (`1.2.3.4`, `2130706433`, `0x7f.1`) and `[::1]`;
    - `localhost`, `foo.local`, `x.internal`, a single-label host, a
      trailing dot, `%`-encoded hosts, a backslash, whitespace, control
      characters, a 2049-character URL;
    - a host outside an exact list, and `xn--` outside an exact list;
    - a prefix path without a segment boundary;
    - `..`;
    - a non-string value;
    - an omitted key with `required`.
  - Bad policy entries fail parsing.
- **Compatibility:** every existing policy fixture behaves as before.

## Sales Partner adoption (PR #24, 8.1.0)

- **`agent.yaml`:** `standard: "7.3"`. Hooks are synced byte-identical
  from builder 7.3.0, and the validator passes against builder `main`.
- **`capabilities/scraping/tools/apify/guard.yaml`:**
  - **`fixed`:**
    - reviews `personalData: false`, required;
    - Facebook `onlyTotal: true`, required;
    - crawler `saveMarkdown: true` and `removeElementsCssSelector:
      'script, style, noscript, svg'`, both required.
  - **`urls`:**
    - Facebook `startUrls[].url`: https, hosts `[facebook.com,
      www.facebook.com]`, path `any`, no query, no fragment, required.
    - Crawler `startUrls[].url` and contact scraper `startUrls[].url`:
      https, `public`, path `root`, no query, no fragment, required.
  - **Header:** the guard's header comment is updated.
- **`usage.md`:**
  - The "instructions the guard can't pin" notes become "the guard
    requires".
  - The contact scraper also starts at the site root, normalized from the
    Maps listing's website, as the site reader already does.
- **`subagents/preparer.md`:** contact URLs are normalized to the site
  root, matching the site reader.
- **Normalizing website URLs** (`usage.md` and `preparer.md`, for the
  contact scraper and the site reader). *(Designer's call.)*
  - **Scheme:** an `http://` listing website is upgraded to `https://`,
    with the same host. If the https fetch fails, the source is recorded
    as not run; it is never retried over http.
  - **Root:** the root is scheme plus host, with any path, query and
    fragment dropped.
  - **Shared platforms.** Some websites are a page on a platform's host.
    Cutting them to the root would send the scraper to the platform's
    home page, and its contacts would be written to the lead. So the
    contact scraper and the site reader are skipped for these hosts, and
    both are recorded as not run with the reason "shared-platform
    website":
    - `facebook.com`, `instagram.com`, `linktr.ee`, `sites.google.com`,
      `business.site`, `yelp.com`;
    - any `*.wixsite.com`, `*.square.site`, `*.godaddysites.com` or
      `*.weebly.com`.

    The list is maintained in `usage.md`.
  - **A Facebook-page website** still counts as the lead's own Facebook
    page for the ads count, after the Facebook normalization below.
- **Normalizing Facebook page URLs** (`usage.md` and `preparer.md`).
  *(Designer's call.)*
  - `m.facebook.com` and `web.facebook.com` are rewritten to
    `www.facebook.com`.
  - The query and fragment are stripped, which removes tracking such as
    `?ref=…`.
  - A page whose identity is in the query (`/profile.php?id=…`) can't be
    sent under the no-query rule. The Facebook count is skipped for it
    and recorded as not run with the reason "profile id page". The rule
    isn't widened, because that would reopen the query channel.
- **Tests:** policy cases for each new rule, with the real
  `mcp__claude_ai_Apify_Actors__` prefix. That includes `personalData:
  true` and an omitted `personalData` both blocked, a Facebook keyword
  Ad Library URL blocked (it has a query), and a crawler URL with a path
  or query blocked.
- **Evals:**
  - a lead whose Maps website is a shared-platform page: the contact
    scraper and site reader are skipped and listed as not run;
  - an `http` listing upgraded to `https`;
  - an `m.facebook.com` page normalized to `www.facebook.com`;
  - a `profile.php?id=` page skipped.
- **README:** the 8.1 note's stated limits are reduced to the hostname
  channel.
- **Release:** still 8.1.0, since PR #24 is unmerged.

## Order of work and merge

1. **Builder 7.3**, on agent-builder branch `feat/standard-7-3`.
2. **Sales Partner adoption**, on `feat/research-scrapers`.
3. **Merge order.** Sales Partner CI validates against builder `main` and
   requires `standard` to equal the current standard exactly, with hooks
   byte-identical to the builder's. So 7.2 agents fail CI once 7.3 is on
   `main`. *(Designer's call.)*
   1. **sales-partner #23 (8.0, standard 7.2)** into `main`, while builder
      `main` is still 7.2.
   2. **The builder 7.3 PR.** Sales Partner `main` stays on 7.2 until #24
      lands, and CI runs only on PRs and pushes, so nothing goes red.
   3. **#24, rebased onto `main` and retargeted.** It already declares 7.3
      with synced hooks, so its CI passes against the new builder `main`.
      Then it merges.

## Left to the builder

- The parser's internal structure, and the exact wording of the
  messages, beyond the forms above.
- Whether the IPv4 check uses `ipaddress` after a strict pre-parse. It
  must also refuse the decimal and hex forms.
- How STANDARD.md's sections are laid out.
