# Standard 7.3 Fixed Values and URL Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The guard engine gains `fixed` (exact JSON values) and `urls` (strict URL rules) as Agent Standard 7.3 in builder 7.3.0. Sales Partner's open 8.1.0 PR (#24) adopts them to enforce reviews `personalData: false`, Facebook `onlyTotal: true`, the crawler's fixed settings, and constrained `startUrls`.

**Architecture:**
- Two new per-call checks in `_template/hooks/guard_policy.py`, parsed and validated like `limits`/`only_keys`, run inside `problems()`.
- URL checking uses the engine's own strict parser, not `urllib.parse`.
- The builder bumps the current standard and syncs template hooks. Sales Partner then declares 7.3, syncs hooks byte-identically, and adds the new entries to its Apify guard and instructions.

**Tech Stack:** Python 3 stdlib (the engine, no dependencies), the policy YAML subset the engine parses, bash tests (`tests/lib.sh`).

**Spec:** `docs/superpowers/specs/2026-10-18-standard-7-3-fixed-values-and-url-rules-design.md` (agent-builder).

## Global Constraints

- **Repos and branches.** Builder work is in `/Users/hochoy/Work/Webspenser/agent-builder`, branch `feat/standard-7-3`. Sales Partner work is in `/Users/hochoy/Work/Webspenser/sales-partner`, branch `feat/research-scrapers`.
- **Versions.** Builder version **7.3.0**, current standard **"7.3"**. Sales Partner stays **8.1.0**, with `standard: "7.3"`.
- **Stricter only.** The new keys only add checks. Every existing policy and test behaves as before. An unknown entry key, a malformed entry or an unparsable value fails closed.
- **`fixed` entry keys:** `tools, at, value, required`.
  - `value` tokens:
    - unquoted `true` / `false` → boolean;
    - unquoted `null` → null;
    - an unquoted strict decimal (the `_as_number` grammar) → number;
    - a quoted string → string;
    - any other unquoted token → parse error.
  - `required` defaults to `false`.
  - Matching is by exact type and value: `false` ≠ `0` ≠ `"false"`, `5` == `5.0` (Decimal), and strings are case-sensitive.
- **`fixed` messages:**
  - mismatch: `<tool> must send <path> = <value> (got <got>)`;
  - required and absent: `<tool> names no <path>`.
- **`urls` entry keys:** `tools, at, schemes, hosts, path, query, fragment, required`.
  - `schemes`: a non-empty list from `https`, `http`.
  - `hosts`: a non-empty exact list, or the word `public`.
  - `path`: `root` | `any` | a quoted `/prefix`, matched on segment boundaries.
  - `query` / `fragment`: `forbid` (default) | `allow`.
- **`urls` always-on refusals:**
  - the value is not a string (`<path> must be a URL string`);
  - control characters, whitespace or a backslash;
  - longer than 2048 characters;
  - not exactly `scheme://authority[path][?query][#fragment]`;
  - an uppercase scheme;
  - `@` in the authority;
  - a non-default port (`:443` for https and `:80` for http are allowed);
  - an IP literal: IPv4 dotted, decimal or hex, or a bracketed IPv6;
  - fewer than two labels;
  - a non-LDH label, a label outside 1–63 characters, a leading or trailing hyphen, or a trailing dot;
  - `%` in the host;
  - an `xn--` label, unless the host is in an exact list;
  - a host equal to `localhost`, or ending `.localhost`, `.local`, `.internal`, `.lan`, `.home.arpa` or `.test`;
  - `..` or `%2F` in the path, unless `path: any`;
  - a query or fragment (even a lone `?` or `#`) when forbidden.
- **`urls` message form:** `<tool> <path>: <reason>`.
- **Bindings and pins.** Neither key reads bindings: `--pins` and the schedule gate are unchanged, and `tool_check` doesn't count them as pins.
- **Sales Partner entries:**
  - **`fixed`:**
    - reviews `personalData: false`;
    - Facebook `onlyTotal: true`;
    - crawler `saveMarkdown: true`;
    - crawler `removeElementsCssSelector: 'script, style, noscript, svg'`;
    - all required.
  - **`urls`:**
    - Facebook `startUrls[].url`: `schemes: [https]`, `hosts: [facebook.com, www.facebook.com]`, `path: any`, required.
    - Crawler and contact scraper `startUrls[].url`: `schemes: [https]`, `hosts: public`, `path: root`, required.
- **Sales Partner normalization:**
  - `http://` is upgraded to `https://`. If https fails, the source is recorded as not run, never retried over http.
  - Site root means scheme plus host.
  - Shared-platform hosts skip the contact scraper and site reader, recorded as not run with reason "shared-platform website":
    - `facebook.com`, `instagram.com`, `linktr.ee`, `sites.google.com`, `business.site`, `yelp.com`;
    - `*.wixsite.com`, `*.square.site`, `*.godaddysites.com`, `*.weebly.com`.
  - Facebook URLs: `m.`/`web.facebook.com` become `www.facebook.com`, and the query and fragment are stripped. `/profile.php?id=` pages skip the Facebook count, recorded as not run with reason "profile id page".
- **Rules for every task:**
  - Every task leaves its repo's `bash tests/run-all.sh` green.
  - Don't edit sales-partner `hooks/` except by syncing from the builder.
  - Commits end with a `Co-Authored-By:` trailer naming the model that made them. Never push.
  - Keep `finish` last in test files that use it.
  - Keep test exec bits (`tests/lib.sh` is 100644 in sales-partner).

## Review Focus

1. **URL parser differentials.** For example `https://example.com\@evil.com`, `https:/example.com`, `https://example.com:443@evil.com`, `https://EXAMPLE.com` (host case is OK), `https://exa mple.com`, a tab or newline inside, `https://example.com.`, `https://xn--…`, a full-width dot `example。com`, and `//example.com`. Each must block, or be accepted only when it really has the same scheme, host and path a strict reader sees. Tested in Task 2.
2. **IP hosts in non-obvious forms:** `2130706433`, `0x7f.0.0.1`, `017700000001`, `127.1`, `[::ffff:127.0.0.1]`. All must block. Tested in Task 2.
3. **A `fixed` value written as a YAML-ish token the parser misreads:** `False`, `TRUE`, `yes`, `'false'`, `0`. Unquoted non-canonical tokens must fail parsing; a quoted `'false'` is the string. Tested in Task 1.
4. **Lists and nesting.** For `startUrls` with several items, every item must be checked, and an empty list or `[null]` must not bypass a required `urls` rule. Tested in Task 2.
5. **The adopting agent's real calls.** Sales Partner's normalized URLs must pass and raw listing URLs must block, so instructions and guard agree. Tested in Task 4.

---

### Task 1: `fixed` key (builder)

**Files:**
- Modify: `_template/hooks/guard_policy.py`:
  - add `"fixed"` to `KEYS`;
  - add `FIXED_KEYS = ("tools", "at", "value", "required")`;
  - parse typed `value` tokens;
  - validate in `_validate`;
  - check in `problems()`.
- Modify: `STANDARD.md` (Guard policy → Keys table, Semantics, Parse errors).
- Test: `tests/test-guard-policy.sh`.

**Interfaces:**
- Produces the policy key `fixed` and the messages in the Global Constraints.
- Produces `_fixed_problems(shown: str, entry: dict, args: dict) -> list[str]`.

- [ ] **Step 1: Write the failing cases in `tests/test-guard-policy.sh`,** following its existing fixture style, with a policy containing `fixed` entries for a tool `t`.
  - **Entry 1:** `{at: [personalData], value: false, required: true}`.
    - `false` passes.
    - `true`, `0`, `"false"` and `null` each block with `must send personalData = false`.
    - Omitted, it blocks with `names no personalData`.
  - **Entry 2:** `{at: [onlyTotal], value: true}`, not required. Omitted, it passes.
  - **Entry 3:** `{at: [n], value: 5}`. `5` and `5.0` pass; `"5"` blocks.
  - **Entry 4:** `{at: [sel], value: 'script, style'}`. The exact string passes; `'Script, style'` blocks.
  - **Entry 5:** `{at: ['a[].b'], value: false}`. `{"a":[{"b":false},{"b":true}]}` blocks.
  - **Parse errors**, each failing with a non-zero `--check`:
    - an unquoted `yes`, `False` or `TRUE` as a value;
    - an empty value;
    - a missing `at`;
    - an unknown entry key.

- [ ] **Step 2: Run** `bash tests/test-guard-policy.sh`. Expected: FAIL (unknown key `fixed`).

- [ ] **Step 3: Implement the parsing, validation and `_fixed_problems` in `guard_policy.py`.** Reuse the existing path walkers. Number equality uses `_as_number`, and type checks distinguish `bool` from numbers.

- [ ] **Step 4: Document the key in `STANDARD.md`:** a Keys table row, a Semantics subsection with the value grammar, and Parse errors.

- [ ] **Step 5: Run** `bash tests/run-all.sh`. Expected: ALL GREEN.

- [ ] **Step 6: Commit:** `feat(guard): fixed values — exact JSON values a tool must send`.

---

### Task 2: `urls` key with a strict URL parser (builder)

**Files:**
- Modify: `_template/hooks/guard_policy.py`:
  - add `"urls"` to `KEYS`;
  - add `URL_KEYS = ("tools", "at", "schemes", "hosts", "path", "query", "fragment", "required")`;
  - add `_parse_url(s: str) -> tuple[str, str, int|None, str, str|None, str|None] | str` (scheme, host, port, path, query, fragment, or a reason string on failure);
  - add `_url_problems(shown, entry, args) -> list[str]`;
  - validate in `_validate`.
- Modify: `STANDARD.md`: Keys, Semantics (the full refusal list), Parse errors, and a "Stated limits" line: with `hosts: public` and `path: root`, data can still ride in the hostname.
- Test: `tests/test-guard-policy.sh`.

**Interfaces:**
- Produces the policy key `urls` and the `<tool> <path>: <reason>` messages.

- [ ] **Step 1: Write the failing cases.**
  - **Policy:** tool `t` with:
    - **R1:** `{at: ['startUrls[].url'], schemes: [https], hosts: public, path: root, required: true}`;
    - **R2:** `{at: [page], schemes: [https], hosts: [facebook.com, www.facebook.com], path: any}`;
    - **R3:** `{at: [doc], schemes: [https, http], hosts: [docs.example.com], path: '/pages', query: allow}`.
  - **Allowed:**
    - R1 `https://example.com` and `https://example.com/`;
    - R1 `https://example.com:443/`;
    - R1 `https://Example.com` (the host lowercases);
    - R2 `https://www.facebook.com/somepage`;
    - R3 `http://docs.example.com/pages/x?a=1`.
  - **Blocked under R1, each its own case:**
    - a path `/contact`; a query `?a=1`; a lone `?`; a fragment `#x`; a lone `#`;
    - `http://example.com`; `HTTPS://example.com`;
    - `https://user@example.com`; `https://example.com:8443`;
    - `https://1.2.3.4`, `https://2130706433`, `https://0x7f.0.0.1`, `https://017700000001`, `https://127.1`, `https://[::1]`, `https://[::ffff:127.0.0.1]`;
    - `https://localhost`, `https://a.localhost`, `https://foo.local`, `https://x.internal`, `https://a.lan`, `https://a.home.arpa`, `https://a.test`;
    - `https://intranet` (one label); `https://example.com.` (trailing dot); `https://exa%6dple.com`;
    - `https://example.com\@evil.com`; `https:/example.com`; `//example.com`;
    - whitespace (`https://exa mple.com`); a tab; a `\n`;
    - a 2049-character URL;
    - `https://xn--e1afmkfd.com` (an `xn--` label under `public`);
    - `https://example。com` (a non-ASCII dot);
    - a non-string value (`{"url":5}`);
    - `startUrls` omitted, `[]` and `[null]` (required);
    - a list where the second item is bad (`[{"url":"https://a.com"},{"url":"https://a.com/x"}]`).
  - **Blocked under R2:** `https://evil.com/somepage`; `https://www.facebook.com/somepage?ref=x`; `https://m.facebook.com/somepage`.
  - **Blocked under R3:** `/pagesx`; `/pages/../admin`; `/pages%2Fx`.
  - **Parse errors:**
    - `schemes: []`; `schemes: [ftp]`;
    - `hosts: []`; `hosts: everyone`;
    - `path: rootish`; `path: pages` (no `/`);
    - `query: maybe`;
    - an unknown key.

- [ ] **Step 2: Run** `bash tests/test-guard-policy.sh`. Expected: FAIL.

- [ ] **Step 3: Implement `_parse_url`, `_url_problems` and the validation.** `_parse_url` is a strict left-to-right reader:
  - it splits the scheme at the first `://`;
  - the authority runs up to the first `/`, `?` or `#`;
  - it refuses `@`;
  - it splits the port at the last `:`, and only when what follows is digits, otherwise it refuses;
  - it checks the host against the label rules and the IP forms, using `ipaddress` after a pre-check that refuses all-numeric labels and `0x`;
  - the path runs up to `?` or `#`.

  It never calls `urllib.parse`.

- [ ] **Step 4: Document the key in `STANDARD.md`,** including the stated limit.

- [ ] **Step 5: Run** `bash tests/run-all.sh`. Expected: ALL GREEN.

- [ ] **Step 6: Commit:** `feat(guard): URL rules — schemes, hosts, path and strict parsing`.

---

### Task 3: Standard 7.3 release (builder)

**Files:**
- Modify: `bin/lib/check_manifests.py` (`CURRENT_STANDARD = "7.3"`), `_template/agent.yaml` (`standard: "7.3"`), `_template/hooks/tool_check.py` (accept the `fixed` and `urls` keys; they don't count as pins), `.claude-plugin/plugin.json` and `gemini-extension.json` (version `7.3.0`), the `.codex-plugin` manifest if it carries a version, `README.md` (any "7.2" standard mention that names the current standard), and STANDARD.md's header or version line.
- Test: `tests/test-tool-check.sh`, `tests/test-validate-agent.sh`, `tests/test-builder-manifests.sh` (update the version and standard pins).

**Interfaces:**
- Produces `CURRENT_STANDARD == "7.3"`, so every agent must declare `standard: "7.3"` and sync hooks.

- [ ] **Step 1: Write the failing tests.**
  - `tool_check` accepts a tool policy with `fixed` and `urls`, and still reports pins only from `recipients` and `limits`.
  - The validator requires `standard "7.3"`, and a `"7.2"` agent fails with `must be "7.3"`.
  - The builder manifests are `7.3.0`.
- [ ] **Step 2: Run** `bash tests/run-all.sh`. Expected: FAIL.
- [ ] **Step 3: Implement the version, standard and `tool_check` changes.**
- [ ] **Step 4: Run** `bash tests/run-all.sh`. Expected: ALL GREEN.
- [ ] **Step 5: Commit:** `chore: Agent Standard 7.3 (builder 7.3.0)`.

---

### Task 4: Sales Partner adopts 7.3 in its Apify guard

**Files (sales-partner, branch `feat/research-scrapers`):**
- Modify: `agent.yaml` (`standard: "7.3"`).
- Sync: `hooks/` byte-identical from agent-builder `_template/hooks` (use the repo's existing sync method; check how earlier syncs were done).
- Modify: `capabilities/scraping/tools/apify/guard.yaml` (the `fixed` and `urls` entries in the Global Constraints, and the header comment).
- Test: `tests/test-policies.sh`, `tests/test-content.sh`.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces a guard that accepts the normalized URLs Task 5 instructs and blocks everything else.

- [ ] **Step 1: Write the failing policy cases,** using the real `mcp__claude_ai_Apify_Actors__` prefix.
  - **Reviews:** `personalData: true` blocked; `personalData` omitted blocked; `personalData: false` allowed.
  - **Facebook:**
    - `onlyTotal` omitted blocked; `onlyTotal: false` blocked;
    - `https://www.facebook.com/bigbrothersplumbinginc` allowed;
    - the probe's keyword Ad Library URL (it has a query) blocked;
    - `https://m.facebook.com/x` blocked;
    - `https://evil.com/x` blocked.
  - **Crawler:**
    - `https://bigbrothersplumbinginc.com` allowed;
    - `https://bigbrothersplumbinginc.com/contact-us` blocked;
    - `http://…` blocked;
    - `https://1.2.3.4` blocked;
    - `saveMarkdown` omitted blocked;
    - a different `removeElementsCssSelector` blocked.
  - **Contact scraper:** a root URL allowed; a URL with a path or query blocked.
  - Content assertion: `agent.yaml` contains `standard: "7.3"`.
- [ ] **Step 2: Run** `bash tests/run-all.sh`. Expected: FAIL.
- [ ] **Step 3: Sync the hooks, set the standard, and add the guard entries.**
- [ ] **Step 4: Run** `bash tests/run-all.sh && ../agent-builder/bin/validate-agent.sh . --require-bump main`. Expected: ALL GREEN and OK. The validator reads the sibling builder checkout, which is on `feat/standard-7-3`.
- [ ] **Step 5: Commit:** `feat(guard): adopt Standard 7.3 — fixed values and URL rules on the Apify tools`.

---

### Task 5: Sales Partner instructions, evals and README

**Files (sales-partner):**
- Modify: `capabilities/scraping/tools/apify/usage.md`. The "instructions the guard can't pin" text becomes "the guard requires", plus the normalization rules (http upgrade, site root, the shared-platform list, Facebook normalization and the profile-id skip).
- Modify: `subagents/preparer.md`. The same normalization, the not-run reasons ("shared-platform website", "profile id page", https fetch failed), and contact URLs at the site root.
- Modify: `skills/research-company/SKILL.md` if it describes the inputs.
- Modify: `evals/cases.md`: four new cases, for a shared-platform website, an http upgrade, an `m.facebook.com` normalization and a `profile.php?id=` skip.
- Modify: `README.md`: the 8.1 stated limits shrink to the hostname channel; mention standard 7.3.
- Test: `tests/test-content.sh`.

- [ ] **Step 1: Write the failing assertions.**
  - `usage.md` and `preparer.md` contain:
    - the shared-platform host list;
    - `shared-platform website`;
    - `profile id page`;
    - the http-to-https rule.
  - `usage.md` no longer says the guard can't pin `personalData`.
  - The evals have the four new case headings.
  - The README names standard 7.3.
- [ ] **Step 2: Run** `bash tests/test-content.sh`. Expected: FAIL.
- [ ] **Step 3: Edit the files.** Check each eval's expected outcome against the shipped Preparer and `usage.md` text.
- [ ] **Step 4: Run** `bash tests/run-all.sh && ../agent-builder/bin/validate-agent.sh . --require-bump main`. Expected: ALL GREEN and OK.
- [ ] **Step 5: Commit:** `feat: URL normalization for the guarded scrapers; evals and README for Standard 7.3`.

## Done when

- Both repos' suites are green, and the sales-partner validator passes against the builder branch.
- Merge order (operator): sales-partner #23 → builder 7.3 PR → #24 (rebased onto `main`).
- PRs only when the operator asks.
