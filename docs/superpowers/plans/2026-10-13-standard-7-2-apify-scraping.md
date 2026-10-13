# Agent Standard 7.2: Apify Scraping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apify runs unattended behind a guard that allows exactly two actors and pins their result limits to pushed bindings, and sales-partner's prospector and preparer use it, recording each scrape and its cost in the ledger.

**Architecture:** Builder 7.2 extends the existing `recipients` pinning to numbers, runs the pushed-copy check for every tool that pins values, and adds the reserved invariant `pinned_inputs`. sales-partner adds a `scraping` capability whose Apify tool and guard are written from a live probe of the hosted Apify MCP server, then wires `find_businesses` into the prospector and `find_contacts` into the preparer.

**Tech Stack:** Python 3 standard library, bash tests (`tests/lib.sh`), git (pushed-copy check), the hosted Apify MCP server (`https://mcp.apify.com`) through a claude.ai connector.

**Spec:** `docs/superpowers/specs/2026-10-13-standard-7-2-apify-scraping-design.md`

## Global Constraints

- Builder 7.2.0, `CURRENT_STANDARD = "7.2"`; sales-partner 7.2.0 with `standard: "7.2"`.
- Branch `feat/apify` in both repos (agent-builder's exists from `main`; create sales-partner's from `main`).
- v1 actors: `compass/crawler-google-places` and `vdrmota/contact-info-scraper`, exact tool names from the probe.
- Connector URL: `https://mcp.apify.com?tools=compass/crawler-google-places,vdrmota/contact-info-scraper`.
- Pinned bindings in `bindings/scraping.md`: `max_places_per_search: 60`, `max_pages_per_site: 3`, `max_crawl_depth: 1`.
- Block messages: `<value> is not a pinned value (<bound>)`; `<tool> names no pinned value at <paths>`.
- Pushed-copy message: `bindings/<cap>.md must be committed and pushed before <cap> can run (it differs from the upstream copy, is untracked, or the instance has no git upstream); re-run setup's tools step, then commit and push`.
- `pinned_inputs` is a reserved invariant: never `(acceptable)`.
- `prospecting_sources` values: `apify_google_maps`, `apify_contact_info`, `web_search` (`apollo` stub). `apify_site_scraper` is renamed.
- Per-call list caps (instructions): Maps one search term per call; contact-info at most 10 URLs per call.
- Each client owns its Apify account and sets a monthly usage limit in Apify Console.
- Commit messages end with a `Co-Authored-By:` trailer naming the model that made the commit. Nothing is pushed or merged unless the operator asks.

## Review Focus

1. **A boolean where a number is pinned** (`"maxCrawledPlacesPerSearch": true`): Python treats `True` as `1`, so a naive numeric compare against binding `1` would pass. It must block (Task 1 test "boolean blocks").
2. **A numeric string vs a number** (`"60"` vs `60`): both should match binding `60`; `"60 "` with a space also matches (strings are trimmed) (Task 1 tests).
3. **A pinning tool in an instance with no git upstream** (fresh local setup before the first push): every call blocks with the pushed-copy message, not a traceback (Task 2 test "no upstream").
4. **The Apify connector added with the default URL**: `call-actor`, `search-actors`, `add-actor` and `fetch-actor-details` must block even though they exist (Task 7 tests).
5. **A call that omits a pinned argument** (relying on the actor's default of thousands of results): must block with `names no pinned value` (Task 7 tests).

---

## Part A — agent-builder (`cd ~/Work/Webspenser/agent-builder`, branch `feat/apify`)

### Task 1: Engine — pinned values may be numbers; `--pins`

**Files:**
- Modify: `_template/hooks/guard_policy.py` (`_addresses_at`, `_recipient_problems`, `main`, module docstring)
- Test: `tests/test-guard-policy.sh`, and every test or eval in this repo that expects `is not a pinned recipient` or `names no recipient` (find with `grep -rn "pinned recipient\|names no recipient" tests _template docs/how-it-works.md STANDARD.md`; STANDARD.md wording is Task 4)

**Interfaces:**
- Produces: `guard_policy.py --pins <tool guard.yaml>` prints each distinct `bound` key of the policy's `recipients` entries, one per line, exit 0 (nothing printed when there are none); exit 1 with `FAIL: …` on an unreadable or invalid policy.
- Produces: messages `<value> is not a pinned value (<bound>)`, `<tool> names no pinned value at <paths>`, `<path>: a pinned value must be a string, a number, or a list of them`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-guard-policy.sh`, before `finish`:

```bash
echo "-- pinned values (numbers)"
policy 'covers: [pinned_inputs]' 'allow: [run-maps]' 'recipients:' '  - tools: [run-maps]' '    at: [maxPlaces]' '    bound: max_places'
PB="$W/pins.md"; printf '%s\n' 'max_places: 60' > "$PB"
run 0 "number equal to binding"   mcp__apify__run-maps '{"maxPlaces":60}'    "" "$PB"
run 0 "float equal to binding"    mcp__apify__run-maps '{"maxPlaces":60.0}'  "" "$PB"
run 0 "numeric string"            mcp__apify__run-maps '{"maxPlaces":"60"}'  "" "$PB"
run 0 "numeric string, spaces"    mcp__apify__run-maps '{"maxPlaces":" 60 "}' "" "$PB"
run 2 "larger number blocks"      mcp__apify__run-maps '{"maxPlaces":5000}'  "5000 is not a pinned value (max_places)" "$PB"
run 2 "boolean blocks"            mcp__apify__run-maps '{"maxPlaces":true}'  "a pinned value must be a string, a number, or a list of them" "$PB"
printf '%s\n' 'max_places: 1' > "$W/pins1.md"
run 2 "true never equals 1"       mcp__apify__run-maps '{"maxPlaces":true}'  "a pinned value must be a string, a number, or a list of them" "$W/pins1.md"
run 2 "object blocks"             mcp__apify__run-maps '{"maxPlaces":{"n":60}}' "a pinned value must be a string, a number, or a list of them" "$PB"
run 2 "nested list blocks"        mcp__apify__run-maps '{"maxPlaces":[[60]]}' "a pinned value must be a string, a number, or a list of them" "$PB"
run 0 "list of equal numbers"     mcp__apify__run-maps '{"maxPlaces":[60, 60.0]}' "" "$PB"
run 2 "missing argument blocks"   mcp__apify__run-maps '{}'                  "run-maps names no pinned value at maxPlaces" "$PB"
printf '%s\n' 'max_places: sixty' > "$W/pinsx.md"
run 2 "non-numeric binding never equals a number" mcp__apify__run-maps '{"maxPlaces":60}' "60 is not a pinned value (max_places)" "$W/pinsx.md"
echo "-- --pins"
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); [ "$OUT" = "max_places" ] && _report ok "--pins prints the bound key" || _report no "--pins: $OUT"
policy 'covers: [x]' 'deny: ["*a*"]'
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); rc=$?; [ "$rc" -eq 0 ] && [ -z "$OUT" ] && _report ok "--pins prints nothing without recipients" || _report no "--pins empty (rc=$rc): $OUT"
printf 'covers: [x\n' > "$W/guard.yaml"
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); rc=$?; [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q '^FAIL:' && _report ok "--pins on a bad policy fails" || _report no "--pins bad (rc=$rc): $OUT"
```

Then change every existing expectation of `is not a pinned recipient` to `is not a pinned value`, and of `names no recipient` to `names no pinned value`, in `tests/test-guard-policy.sh` and `tests/test-guard.sh`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-guard-policy.sh 2>&1 | grep -E "FAIL|passed" | tail -12`
Expected: the new cases and the reworded expectations FAIL.

- [ ] **Step 3: Implement**

In `_template/hooks/guard_policy.py`, replace `_addresses_at` with:

```python
def _pinned_at(obj, path):
    """Pinned values at path: a string or a number is one, a list of them is its items, null is absent.
    Booleans, objects and nested lists fail closed."""
    def scalar(x):
        return isinstance(x, str) or (isinstance(x, (int, float)) and not isinstance(x, bool))
    out = []
    for node in _walk(obj, path):
        if node is None:
            continue
        if scalar(node):
            out.append(node)
        elif isinstance(node, list) and all(scalar(x) for x in node):
            out.extend(node)
        else:
            raise PolicyError(f"{path}: a pinned value must be a string, a number, or a list of them")
    return out


def _as_number(value):
    """value as a float when it is a number or a numeric string, else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except ValueError:
        return None
```

Replace `_recipient_problems` with:

```python
def _recipient_problems(shown, entry, args, bindings):
    values = [v for path in entry["at"] for v in _pinned_at(args, path)]
    if not values:
        return [f"{shown} names no pinned value at {', '.join(entry['at'])}"]
    bound = entry["bound"]
    pinned = bindings.get(bound) or set()
    if not pinned:
        return [f"no {bound} line in bindings; re-run setup's tools step"]
    if not all(BARE_VALUE.match(p) for p in pinned):
        return [f"{bound} must be a bare value"]
    texts = {p.strip().lower() for p in pinned}
    numbers = {n for n in (_as_number(p) for p in pinned) if n is not None}

    def ok(v):
        if isinstance(v, str) and v.strip().lower() in texts:
            return True
        n = _as_number(v)
        return n is not None and n in numbers

    return [f"{_printable(v)} is not a pinned value ({bound})" for v in values if not ok(v)]
```

In `main(argv)`, after the `--covers` branch, add:

```python
    if len(argv) == 2 and argv[0] == "--pins":
        try:
            with open(argv[1], encoding="utf-8") as fh:
                policy = parse(fh.read())
        except Exception as err:  # never a traceback
            print(f"FAIL: {type(err).__name__}: {err}")
            return 1
        seen = []
        for entry in policy.get("recipients", []):
            if entry["bound"] not in seen:
                seen.append(entry["bound"])
        print("\n".join(seen)) if seen else None
        return 0
```

In the module docstring's usage block add the line:
`  guard_policy.py --pins <tool guard.yaml>                                  print each bound key the policy pins`
and change "`recipients:` pins send arguments to values recorded in bindings" to "`recipients:` pins argument values (text or numbers) to values recorded in bindings".

- [ ] **Step 4: Run tests**

Run: `bash tests/test-guard-policy.sh 2>&1 | tail -1 && bash tests/test-guard.sh 2>&1 | tail -1 && bash tests/run-all.sh 2>&1 | tail -1`
Expected: `0 failed`, `0 failed`, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard_policy.py tests/
git commit -m "feat(guard): pinned values may be numbers; --pins lists a policy's bound keys"
```

### Task 2: `guard.sh` — pushed-copy check for every tool that pins values

**Files:**
- Modify: `_template/hooks/guard.sh`
- Test: `tests/test-guard.sh`

**Interfaces:**
- Consumes: `guard_policy.py --pins` (Task 1).
- Produces: shell functions `ugit`, `pushed <cap>` (status 0 when `bindings/<cap>.md` is a regular file equal to its `@{u}` copy) and `pushed_msg <cap>`; the bind loop blocks a pinning tool's calls when `pushed` fails.

- [ ] **Step 1: Write the failing tests**

In `tests/test-guard.sh`, change `PINMSG` to:

```bash
PINMSG="bindings/owner_notify.md must be committed and pushed before owner_notify can run"
```

Append before `finish`:

```bash
echo "-- pinned values need the pushed copy (non-exempt capability)"
ST="$PKG/capabilities/scraping/tools/apify"; mkdir -p "$ST"
printf '%s\n' '# Scraping' '' '## Operations' '' '| `find_businesses` | x |' '' '## Invariants' '' '- `pinned_inputs` — x' > "$PKG/capabilities/scraping/contract.md"
printf '%s\n' 'capability: scraping' 'provider: apify' 'server_match: apify' > "$ST/identity.yaml"
printf '%s\n' '`find_businesses`' '## Probe' 'x' > "$ST/usage.md"
printf '%s\n' 'covers: [pinned_inputs]' 'allow: [run-maps]' 'recipients:' '  - tools: [run-maps]' '    at: [maxPlaces]' '    bound: max_places' > "$ST/guard.yaml"
S="$W/scrape"; mkdir -p "$S/bindings"
printf '%s\n' 'agent: demo-agent' 'mode: plugin' 'bind_crm: demo' 'bind_scraping: apify' > "$S/instance.yaml"
printf '%s\n' 'max_places: 60' > "$S/bindings/scraping.md"
SMSG="bindings/scraping.md must be committed and pushed before scraping can run"
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":60}')";            expect 2 "no git: blocked" "$SMSG"
git -C "$S" init -q; git -C "$S" add -A; git -C "$S" commit -q -m init
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":60}')";            expect 2 "no upstream: blocked" "$SMSG"
git init -q --bare "$W/scrape-remote.git"; git -C "$S" remote add origin "$W/scrape-remote.git"; git -C "$S" push -q -u origin HEAD 2>/dev/null
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":60}')";            expect 0 "pushed and in limit: passes"
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":5000}')";          expect 2 "pushed, over limit: blocked" "5000 is not a pinned value (max_places)"
printf '%s\n' 'max_places: 5000' > "$S/bindings/scraping.md"
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":5000}')";          expect 2 "edited limit, not pushed: blocked" "$SMSG"
git -C "$S" commit -q -am raise
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":5000}')";          expect 2 "committed, not pushed: blocked" "$SMSG"
git -C "$S" reset -q --hard origin/HEAD 2>/dev/null || git -C "$S" reset -q --hard HEAD~1
run_guard "$S" "$(call mcp__apify__run-maps '{"maxPlaces":60}')";            expect 0 "restored: passes"
run_guard "$S" "$(call mcp__claude_ai_Attio__list-records '{}')";             expect 0 "other servers are unaffected"
```

(Use the file's existing `PKG`, `call`, `run_guard` and `expect` helpers; read the top of the file first. If `demo` is not the CRM provider the existing fixtures use, use theirs.)

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-guard.sh 2>&1 | grep -E "FAIL|passed" | tail -12`
Expected: the new block's "blocked" cases FAIL (no check yet), and the reworded `PINMSG` cases FAIL.

- [ ] **Step 3: Implement**

In `_template/hooks/guard.sh`, after the `ablock()` definition, add:

```bash
# Git for the pushed-copy check: system config off, replace objects off,
# fsmonitor off, lazy fetch off and every transport refused (an empty
# GIT_ALLOW_PROTOCOL overrides every protocol.* config key, on any git
# version); blobs are read directly (no diff drivers or clean filters).
ugit() { GIT_ALLOW_PROTOCOL= GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 git -C "$instance" -c core.fsmonitor=false -c protocol.allow=never "$@" </dev/null; }
# pushed <cap>: the agent can write bindings/, so values a tool policy pins
# must equal the upstream (pushed) copy. This stops edits and unpushed
# commits. It does not stop an agent that edits .git itself (tracking refs,
# upstream/remote config, core.worktree, a .git gitfile, alternates).
pushed() {
  _bp="bindings/$1.md"
  [ -f "$instance/$_bp" ] && [ ! -L "$instance/$_bp" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  ugit rev-parse --verify --quiet '@{u}' >/dev/null 2>&1 || return 1
  ugit cat-file -e "@{u}:$_bp" >/dev/null 2>&1 || return 1
  ugit cat-file blob "@{u}:$_bp" 2>/dev/null | cmp -s - "$instance/$_bp"
}
pushed_msg() { printf '%s' "bindings/$1.md must be committed and pushed before $1 can run (it differs from the upstream copy, is untracked, or the instance has no git upstream); re-run setup's tools step, then commit and push"; }
```

In the agent-policy exemption loop, replace everything from the comment `# The agent can write bindings/, so the pinned values …` through the last `ugit cat-file blob … || ablock "$bmsg"` line with:

```bash
    pushed "$ecap" || ablock "$(pushed_msg "$ecap")"
```

In the bind loop, directly after `[ -n "$policy" ] || continue  # no policy: …` and the engine/python3 checks, before the line that runs `python3 "$engine" "$tdir/guard.yaml" …`, add:

```bash
  if python3 "$engine" --pins "$tdir/guard.yaml" 2>/dev/null | grep -q .; then
    pushed "$cap" || pblock "$(pushed_msg "$cap")"
  fi
```

Update the header comment's description of the exemption to say the pushed-copy check now applies to every bound tool whose policy pins values.

- [ ] **Step 4: Run tests**

Run: `bash tests/test-guard.sh 2>&1 | tail -1 && bash tests/run-all.sh 2>&1 | tail -1`
Expected: `0 failed`, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard.sh tests/test-guard.sh
git commit -m "feat(guard): any tool that pins values needs its bindings pushed"
```

### Task 3: Invariant `pinned_inputs` in `tool_check`, the gate and the validator

**Files:**
- Modify: `_template/hooks/tool_check.py`, `_template/hooks/schedule_check.py`, `bin/lib/check_manifests.py`
- Test: `tests/test-tool-check.sh`, `tests/test-schedule-check.sh`, `tests/test-validate-agent.sh`

**Interfaces:**
- Produces: `tool_check.PIN_INVARIANTS = ("owner_only_send", "pinned_inputs")`; `tool_check.check_pinned(parsed, folder, label, inv) -> list[str]` (the existing `check_owner_only` logic, with `inv` named in its messages); `check_manifests.RESERVED_INVARIANTS` includes `pinned_inputs`.

- [ ] **Step 1: Write the failing tests**

`tests/test-tool-check.sh`, before `finish`:

```bash
echo "-- pinned_inputs"
PI="$W/pkg/capabilities/scraping"; PIT="$PI/tools/apify"; mkdir -p "$PIT"
printf '%s\n' '# Scraping' '' '## Operations' '' '| `find_businesses` | x |' '' '## Invariants' '' '- `pinned_inputs` — x' > "$PI/contract.md"
good_pin() {
  printf '%s\n' 'capability: scraping' 'provider: apify' 'server_match: apify' > "$PIT/identity.yaml"
  printf '%s\n' '# Apify' '' '- `find_businesses` — apify:run-maps' '' '## Probe' '' 'Call apify:list-tools.' > "$PIT/usage.md"
  printf '%s\n' 'covers: [pinned_inputs]' 'allow: [run-maps, list-tools]' 'recipients:' '  - tools: [run-maps]' '    at: [maxPlaces]' '    bound: max_places' > "$PIT/guard.yaml"
}
good_pin; run "$PIT" "$PI/contract.md"; expect 0 "pinned_inputs tool passes" "OK: "
good_pin; sed -i.bak 's/^allow: .*/allow: [run-*, list-tools]/' "$PIT/guard.yaml"; run "$PIT" "$PI/contract.md"
expect 1 "wildcard allow refused" "run-* must be an exact tool name for pinned_inputs (no wildcards)"
good_pin; sed -i.bak 's/^allow: .*/allow: [run-maps, run-other, list-tools]/' "$PIT/guard.yaml"; run "$PIT" "$PI/contract.md"
expect 1 "unpinned run tool refused" "run-other is allowed but no recipients entry pins it"
good_pin; printf '%s\n' 'covers: [pinned_inputs]' 'allow: [run-maps]' > "$PIT/guard.yaml"; run "$PIT" "$PI/contract.md"
expect 1 "no recipients entry refused" "must pin values (a recipients entry) for pinned_inputs"
```

(Use the file's existing `run`/`expect` helpers. If the existing `check_owner_only` message text for a missing recipients entry differs from "must pin values (a recipients entry) for <inv>", Step 3 rewrites it to exactly that for both invariants and the owner_only_send tests are updated to match.)

`tests/test-schedule-check.sh`, before `finish` (uses the file's `run`/`expect` helpers):

```bash
echo "-- pinned_inputs bindings"
PP="$W/ppkg"; mkdir -p "$PP/hooks" "$PP/capabilities/scraping/tools/apify"
cp _template/hooks/schedule_check.py _template/hooks/guard_policy.py _template/hooks/tool_check.py "$PP/hooks/"
printf '%s\n' 'name: pin-agent' 'version: 1.0.0' 'description: Demo' 'standard: "7.1"' 'catalog: webspenser' \
  'catalog_repo: webspenser/agent-library' 'capabilities: scraping' 'activity_scrape: scraping' > "$PP/agent.yaml"
printf '%s\n' '# Scraping' '' '## Operations' '' '| `find_businesses` | x |' '' '## Invariants' '' '- `pinned_inputs` — x' > "$PP/capabilities/scraping/contract.md"
printf '%s\n' 'capability: scraping' 'provider: apify' 'server_match: apify' > "$PP/capabilities/scraping/tools/apify/identity.yaml"
printf '%s\n' '# Apify' '' '- `find_businesses` — apify:run-maps' '' '## Probe' '' 'Call apify:list-tools.' > "$PP/capabilities/scraping/tools/apify/usage.md"
printf '%s\n' 'covers: [pinned_inputs]' 'allow: [run-maps]' 'recipients:' '  - tools: [run-maps]' '    at: [maxPlaces]' '    bound: max_places' > "$PP/capabilities/scraping/tools/apify/guard.yaml"
PI2="$W/pin-ok"; mkdir -p "$PI2/bindings"
printf '%s\n' 'agent: pin-agent' 'mode: plugin' 'bind_scraping: apify' > "$PI2/instance.yaml"
printf '%s\n' 'timezone: UTC' 'schedule_scrape: "daily 06:00"' > "$PI2/schedules.yaml"
printf '%s\n' 'max_places: 60' > "$PI2/bindings/scraping.md"
OUT=$(python3 -B "$PP/hooks/schedule_check.py" check "$PI2" --repo acme/pin 2>&1); RC=$?
expect 0 "scraping with max_places passes" "PASS  pin-agent: scrape (pin)"
printf '%s\n' 'other: 1' > "$PI2/bindings/scraping.md"
OUT=$(python3 -B "$PP/hooks/schedule_check.py" check "$PI2" --repo acme/pin 2>&1); RC=$?
expect 1 "scraping without max_places fails" "bindings/scraping.md has no max_places line (the apify tool pins values to it)"
```

`tests/test-validate-agent.sh`, before `finish`:

```bash
make_valid_agent "$FIX/pin-accept"
printf '%s\n' '- `pinned_inputs` (acceptable) — x' >> "$FIX/pin-accept/capabilities/crm/contract.md"
fails_with "$FIX/pin-accept" "capabilities/crm/contract.md: pinned_inputs cannot be marked (acceptable)"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-tool-check.sh 2>&1 | tail -1; bash tests/test-schedule-check.sh 2>&1 | tail -1; bash tests/test-validate-agent.sh 2>&1 | tail -1`
Expected: failures in each.

- [ ] **Step 3: Implement**

`_template/hooks/tool_check.py`:
- Add `PIN_INVARIANTS = ("owner_only_send", "pinned_inputs")` next to `SEND_INVARIANTS`.
- Rename `check_owner_only(parsed, folder, label)` to `check_pinned(parsed, folder, label, inv)`, replacing the hard-coded `owner_only_send` in its messages with `{inv}`, and the missing-entry message with `must pin values (a recipients entry) for {inv}`.
- Replace the call site `if "owner_only_send" in invariants and parsed: fails.extend(check_owner_only(parsed, folder, label))` with:

```python
    for inv in PIN_INVARIANTS:
        if inv in invariants and parsed and inv in (covers or []):
            fails.extend(check_pinned(parsed, folder, label, inv))
```

  (For `owner_only_send` the covers condition already holds, because the send check above requires it; keep the existing behavior that an `owner_only_send` contract without cover fails.)

`_template/hooks/schedule_check.py`: the block `if "owner_only_send" in invs:` that checks `recipient_keys(folder)` becomes `if set(tool_check.PIN_INVARIANTS) & set(invs):`, and its messages say `(the {provider} tool pins values to it)` instead of `pins recipients to it`. Update existing test expectations that contain `pins recipients to it`.

`bin/lib/check_manifests.py`: add `"pinned_inputs"` to `RESERVED_INVARIANTS`.

- [ ] **Step 4: Run tests**

Run: `bash tests/run-all.sh 2>&1 | tail -1`
Expected: `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/tool_check.py _template/hooks/schedule_check.py bin/lib/check_manifests.py tests/
git commit -m "feat: pinned_inputs invariant — exact allow list, pinned run tools, bound keys at the gate"
```

### Task 4: Standard 7.2 — versions and docs

**Files:**
- Modify: `bin/lib/check_manifests.py`, `_template/agent.yaml`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`, `tests/run-all.sh`, `tests/test-builder-manifests.sh`, `tests/test-guard.sh`, `tests/test-schedule-check.sh`, `tests/test-validate-agent.sh`, `STANDARD.md`, `docs/how-it-works.md`, `README.md`

**Interfaces:**
- Produces: `CURRENT_STANDARD = "7.2"`; builder manifests at `7.2.0`.

- [ ] **Step 1: Bump**

```bash
sed -i.bak 's/CURRENT_STANDARD = "7.1"/CURRENT_STANDARD = "7.2"/' bin/lib/check_manifests.py
sed -i.bak 's/^standard: "7.1"/standard: "7.2"/' _template/agent.yaml
sed -i.bak 's/"version": "7.1.0"/"version": "7.2.0"/' .claude-plugin/plugin.json .codex-plugin/plugin.json gemini-extension.json
sed -i.bak -e 's/standard: "7.1"/standard: "7.2"/g' -e 's/_template is not 7.1/_template is not 7.2/' tests/run-all.sh tests/test-guard.sh tests/test-schedule-check.sh tests/test-validate-agent.sh
sed -i.bak 's/standard: "7.0"/standard: "7.1"/' tests/test-validate-agent.sh   # the "old standard" fixture
sed -i.bak 's/c\["version"\] == "7.1.0"/c["version"] == "7.2.0"/' tests/test-builder-manifests.sh
find . -name '*.bak' -not -path './.git/*' -delete
grep -rn '"7\.1"\|7\.1\.0' --exclude-dir=.git --exclude-dir=docs . | grep -v 'in 7.1'
```

Update the old-standard fixture's expected message to `standard '7.1' must be "7.2"` if it names versions.

- [ ] **Step 2: STANDARD.md**

1. Development phase and Agent manifest: `7.2`.
2. Capabilities: reserved ids now also include `pinned_inputs` ("every input that limits a call's size comes only from values pinned in `bindings/<capability>.md` at interactive setup"); none of the five can be `(acceptable)`.
3. Guard policy → Keys, `recipients` row: "pins argument values (text or numbers) to values recorded in bindings".
4. Guard policy → Semantics, Recipients step: values may be strings, numbers or lists of them; booleans, objects and nested lists block; a number matches a numerically equal bound value; messages `<value> is not a pinned value (<bound>)` and `<tool> names no pinned value at <paths>`.
5. Guard hook: the pushed-copy check runs for the exempt `owner_only_send` capability and for every bound tool whose policy has a `recipients` entry, with the 7.2 message.
6. Tools / tool_check and the unattended gate: `pinned_inputs` uses the same rules as `owner_only_send` (exact allow list, every allowed tool pinned or a probe read; a bindings line per pinned key).
7. Validation list: `standard` `"7.2"`.

Run: `grep -n '"7\.1"\|pinned recipient' STANDARD.md` — Expected: none.

- [ ] **Step 3: how-it-works and README**

`docs/how-it-works.md`: version line `Current: standard 7.2. Agent Builder 7.2.0, sales-partner 7.1.0 (7.2.0 in progress).`, the validator diagram node `standard 7.2`, and after the ledger paragraph:

```markdown
A tool can also pin the size of what it asks for: a scraper's result
limit, for example, is set once at setup and pushed with the instance.
The guard refuses a bigger request, and refuses every request while the
pinned values differ from the pushed copy.
```

- [ ] **Step 4: Run everything**

Run: `bash tests/run-all.sh 2>&1 | tail -1`
Expected: `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: Agent Standard 7.2 — pinned values and pinned_inputs (builder 7.2.0)"
```

---

## Part B — sales-partner (`cd ~/Work/Webspenser/sales-partner`)

Create the branch first: `git switch -c feat/apify main`.

### Task 5: Probe the Apify connector (operator present)

**Files:**
- Create: `../agent-builder/docs/superpowers/notes/2026-10-13-apify-connector-probe.md`

This task needs the operator: the hosted server connected in claude.ai as a custom connector at `https://mcp.apify.com?tools=compass/crawler-google-places,vdrmota/contact-info-scraper`, signed in to the operator's own Apify account, with a monthly usage limit set in Apify Console.

- [ ] **Step 1: Confirm the connector.** ToolSearch `apify`. Expected: tools for exactly the two actors (plus any helper tools the restricted URL still exposes). Record the server prefix as it appears in tool names (lowercased: `server_match`). If none are found, stop and ask the operator to add the connector.
- [ ] **Step 2: Record the schemas.** Load every Apify tool's schema. In the notes file record: every tool name, each marked `actor run`, `read` or `other`; each actor tool's full input schema verbatim; for Maps, the per-search result-limit argument, the search-terms argument and the location argument; for contact-info, the start-URLs argument, the pages-per-site argument and the crawl-depth argument; any argument that could raise cost beyond those (e.g. extra details, reviews, images, `maxCrawledPlaces` totals, proxy or memory options) and whether it must be pinned or refused; the output shape and whether results are truncated with a separate read tool for full results; whether a run's cost is returned and under which field.
- [ ] **Step 3: One tiny live call, with the operator's OK.** Maps, one search term, result limit 5, a city in the operator's service area. Record the response shape and cost. Do not write anything to the CRM.
- [ ] **Step 4: Default URL check (read-only).** Ask the operator whether the default URL's tools (`call-actor`, `search-actors`, `add-actor`, `fetch-actor-details`, docs tools) appear in their connector list; record the names, so the guard's deny list names them exactly.
- [ ] **Step 5: Commit** the notes in agent-builder: `docs: Apify connector probe for the scraping tool`.

### Task 6: Sync to builder 7.2; `scraping` capability, Apify tool and guard

**Files:**
- Modify: `hooks/*` (sync), `agent.yaml`, `tests/test-policies.sh`, `tests/test-schedules.sh`, `tests/test-content.sh`, `capabilities/owner_notify/...` and evals/tests that expect `pinned recipient` / `names no recipient` / `can send`
- Create: `capabilities/scraping/contract.md`, `capabilities/scraping/tools/apify/{identity.yaml,usage.md,guard.yaml}`

**Interfaces:**
- Consumes: the probe notes (Task 5): `<SERVER>`, `<MAPS_TOOL>`, `<CONTACTS_TOOL>`, `<READ_TOOL>` (if any), `<MAPS_LIMIT_ARG>`, `<CONTACTS_PAGES_ARG>`, `<CONTACTS_DEPTH_ARG>`, the list of cost-raising arguments to refuse (`<REFUSED_ARGS>`), and the real names of the non-pinned arguments the tests use (`searchStringsArray`, `locationQuery`, `startUrls` below are the expected Apify names; use the probed ones). Replace each placeholder below with the recorded value before running anything.
- Produces: operations `find_businesses(query, location)`, `find_contacts(urls[])`; bindings keys `max_places_per_search`, `max_pages_per_site`, `max_crawl_depth`.

- [ ] **Step 1: Sync hooks and fix reworded expectations**

```bash
cp ../agent-builder/_template/hooks/guard_policy.py ../agent-builder/_template/hooks/guard.sh ../agent-builder/_template/hooks/tool_check.py ../agent-builder/_template/hooks/schedule_check.py hooks/
sed -i.bak 's/^standard: "7.1"/standard: "7.2"/' agent.yaml && rm agent.yaml.bak
grep -rn 'pinned recipient\|names no recipient\|pins recipients to it\|can send (it differs' tests evals capabilities skills
```

Change each hit to the 7.2 wording (`is not a pinned value`, `names no pinned value`, `pins values to it`, `can run (it differs`). Update the content assertion `standard: "7.1"` to `"7.2"`.

- [ ] **Step 2: Write the failing policy tests**

In `tests/test-policies.sh`, before the `echo "-- Attio"` line:

```bash
echo "-- scraping (apify)"
AG2=capabilities/scraping/tools/apify/guard.yaml; P=mcp__<SERVER>__; SM=apify
printf '%s\n' 'max_places_per_search: 60' 'max_pages_per_site: 3' 'max_crawl_depth: 1' > "$W/scraping.md"
MAPS_OK='{"<MAPS_LIMIT_ARG>":60,"searchStringsArray":["HVAC contractor"],"locationQuery":"Oakland, CA"}'   # replace the two non-pinned argument names with the probed ones
check 0 "maps in limit"            $AG2 ${P}<MAPS_TOOL> "$MAPS_OK" "" "$W/scraping.md"
check 2 "maps over limit"          $AG2 ${P}<MAPS_TOOL> '{"<MAPS_LIMIT_ARG>":5000}' "5000 is not a pinned value (max_places_per_search)" "$W/scraping.md"
check 2 "maps limit omitted"       $AG2 ${P}<MAPS_TOOL> '{"searchStringsArray":["x"]}' "names no pinned value" "$W/scraping.md"
check 0 "contacts in limit"        $AG2 ${P}<CONTACTS_TOOL> '{"startUrls":[{"url":"https://example.com"}],"<CONTACTS_PAGES_ARG>":3,"<CONTACTS_DEPTH_ARG>":1}' "" "$W/scraping.md"
check 2 "contacts depth raised"    $AG2 ${P}<CONTACTS_TOOL> '{"startUrls":[{"url":"https://example.com"}],"<CONTACTS_PAGES_ARG>":3,"<CONTACTS_DEPTH_ARG>":5}' "is not a pinned value (max_crawl_depth)" "$W/scraping.md"
for t in call-actor search-actors add-actor fetch-actor-details; do
  check 2 "blocked: $t"            $AG2 ${P}$t '{}' "" "$W/scraping.md"
done
check 2 "another actor"            $AG2 ${P}apify-slash-instagram-scraper '{}' "" "$W/scraping.md"
SM=
```

Add one `check 2 "refused: <arg>"` line per entry of `<REFUSED_ARGS>`, expecting `may not use`.

In `tests/test-schedules.sh`, add a `scrape()` helper like `ledger()` that appends `bind_scraping: apify` and writes the three `bindings/scraping.md` lines, and call it from `inst()` and the approach fixture; add a case where `max_places_per_search` is missing and the gate fails with `bindings/scraping.md has no max_places_per_search line`.

In `tests/test-content.sh`, before `finish`:

```bash
echo "-- 7.2: scraping"
assert_contains "$SP/agent.yaml" 'standard: "7.2"'
assert_contains "$SP/agent.yaml" 'capabilities: crm, owner_notify, ledger, scraping'
assert_contains "$SP/capabilities/scraping/contract.md" '`pinned_inputs`'
assert_contains "$SP/capabilities/scraping/tools/apify/usage.md" 'mcp.apify.com?tools=compass/crawler-google-places,vdrmota/contact-info-scraper'
assert_contains "$SP/capabilities/scraping/tools/apify/usage.md" 'monthly usage limit'
```

Run: `bash tests/run-all.sh 2>&1 | grep -E "FAIL|passed"` — Expected: failures.

- [ ] **Step 3: Write the capability and tool**

`capabilities/scraping/contract.md`:

```markdown
# Scraping contract

How the agent reads public business listings and contact details through
an outside scraper. Skills and sub-agent contracts call these
operations, never a provider's tools.

## Operations

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `find_businesses` | `query`, `location` | listings: name, address, phone, website, category, rating, review count, place id, URL; plus the run's cost when reported | Retried once; then a ledger `step` with outcome `failed` and an `error` event |
| `find_contacts` | `urls[]`, at most 10 per call | per URL: emails, phones, social links; plus the run's cost when reported | Same |

Each call is a ledger `step` (`capabilities/ledger/contract.md`) with its
cost in `cost_usd`. A guard block on a scraping call stops the activity
and calls `notify_owner(kind: error)` naming the block; it is never
retried.

## Invariants

- `no_external_send` — the scraper never sends a message to anyone.
- `allowlisted_actors` — only the actors the tool names run.
- `pinned_inputs` — every input that limits a call's size comes only from
  values pinned in `bindings/scraping.md` at interactive setup.
```

`capabilities/scraping/tools/apify/identity.yaml`:

```yaml
capability: scraping
provider: apify
server_match: <SERVER match from the probe, lowercase; expected apify>
```

`capabilities/scraping/tools/apify/guard.yaml` (names from the probe; adjust deny patterns so none matches an allowed name):

```yaml
# Apify guard policy: two actors only, each call's size pinned to the
# pushed bindings/scraping.md. Everything else on the server (call-actor,
# search/add actors, store, tasks, datasets, webhooks, schedules) is
# outside allow. Names come from the probe notes in agent-builder.
covers: [no_external_send, allowlisted_actors, pinned_inputs]
allow: [<MAPS_TOOL>, <CONTACTS_TOOL>]          # plus <READ_TOOL> if the probe found results are truncated
deny: ["*call-actor*", "*call_actor*", "*search-actors*", "*add-actor*", "*fetch-actor*", "*webhook*", "*schedule*"]
recipients:
  - tools: [<MAPS_TOOL>]
    at: [<MAPS_LIMIT_ARG>]
    bound: max_places_per_search
  - tools: [<CONTACTS_TOOL>]
    at: [<CONTACTS_PAGES_ARG>]
    bound: max_pages_per_site
  - tools: [<CONTACTS_TOOL>]
    at: [<CONTACTS_DEPTH_ARG>]
    bound: max_crawl_depth
refuse_args: [<REFUSED_ARGS>]                   # omit the key if the probe found none
```

`capabilities/scraping/tools/apify/usage.md`:

```markdown
# Scraping — Apify tool

Runs two Apify actors through the client's own Apify account: the Google
Maps scraper for local businesses, and the contact-info scraper for
emails, phones and social links on a business's website. `apify:` below
means the connected Apify server's tools, whatever their prefix.

- `find_businesses` — `apify:<MAPS_TOOL>` with one search term (`query`),
  the location, and `<MAPS_LIMIT_ARG>` = the `max_places_per_search`
  binding. One search term per call. Map the results to the contract's
  fields. Report the run's cost from `<cost field, from the probe>` (or,
  when not reported, the estimate described below).
- `find_contacts` — `apify:<CONTACTS_TOOL>` with at most 10 website URLs,
  `<CONTACTS_PAGES_ARG>` = `max_pages_per_site` and `<CONTACTS_DEPTH_ARG>`
  = `max_crawl_depth`. Return per URL the emails, phones and social
  links found, each with the page it came from.

Pass every pinned argument on every call, with the bound value: the guard
refuses a call that leaves one out. Never call any other Apify tool.

## Setup

1. The business owns the Apify account and pays for it; Webspenser
   manages it. In Apify Console set a monthly usage limit: it is the hard
   stop on spend.
2. Add the hosted connector in claude.ai (Settings → Connectors → Add
   custom connector) at
   `https://mcp.apify.com?tools=compass/crawler-google-places,vdrmota/contact-info-scraper`
   and sign in to that Apify account.
3. Pinned values, written to `bindings/scraping.md` after the operator
   confirms each, then committed and pushed (the guard refuses every
   Apify call until the file matches the pushed copy):
   - `max_places_per_search` — Maps results per search term (default 60);
   - `max_pages_per_site` — pages the contact scraper reads per website (default 3);
   - `max_crawl_depth` — link depth on each website (default 1).

## Probe

Call ToolSearch for the Apify server's tools (read-only) and confirm the
exposed tools are exactly `<MAPS_TOOL>` and `<CONTACTS_TOOL>`. If the
connector exposes `call-actor` or other tools, tell the operator to
re-add it with the URL in Setup step 2; the guard blocks them either
way.
```

If the probe found cost is not returned, add a `## Cost` section listing each actor's per-result price from the notes and saying: record `results × price` in `cost_usd` and put `estimated` in `detail`.

`agent.yaml`: `capabilities: crm, owner_notify, ledger, scraping`; add `, scraping` to `activity_prospect` and `activity_prepare`.

- [ ] **Step 4: Run tests and the validator**

Run: `bash tests/run-all.sh 2>&1 | tail -3 && ../agent-builder/bin/validate-agent.sh .`
Expected: `ALL GREEN`, `OK: . conforms`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: scraping capability with the Apify tool; two actors, pinned inputs (standard 7.2)"
```

### Task 7: Wiring — sources, prospector, preparer, digest, README

**Files:**
- Modify: `context/operating-config.md`, `subagents/prospector.md`, `subagents/preparer.md`, `skills/send-digest/SKILL.md`, `skills/interview-business/SKILL.md`, `AGENT.md`, `README.md`, `evals/cases.md`, `tests/test-content.sh`

**Interfaces:**
- Consumes: `find_businesses`, `find_contacts` (Task 6); ledger `find_events`, `append_events`; `notify_owner`.

- [ ] **Step 1: Write failing content assertions**

```bash
echo "-- 7.2: Apify wiring"
assert_contains "$SP/context/operating-config.md" 'apify_contact_info'
assert_not_contains "$SP/context/operating-config.md" 'apify_site_scraper:'
assert_contains "$SP/context/operating-config.md" 'apify_site_scraper was renamed apify_contact_info'
for f in subagents/prospector.md subagents/preparer.md README.md; do
  assert_not_contains "./$f" 'Apify is never attached'
  assert_not_contains "./$f" 'Apify connectors are not'
done
assert_contains "$SP/subagents/prospector.md" '`find_businesses`'
assert_contains "$SP/subagents/prospector.md" 'apify_spend_cap_usd_per_week'
assert_contains "$SP/subagents/preparer.md" '`find_contacts`'
assert_contains "$SP/skills/send-digest/SKILL.md" 'Apify cost from the ledger'
assert_contains "$SP/README.md" 'monthly usage limit'
assert_contains "$SP/README.md" 'Upgrading from 7.1'
assert_contains "$SP/evals/cases.md" 'A scrape never exceeds its pinned limits'
```

(If the `for f in …` loop trips the content test's referenced-file scanner, as it did before, write the six assertions out one per line.)

- [ ] **Step 2: Edits**

- `operating-config.md`: `prospecting_sources: [apify_google_maps, apify_contact_info, web_search]`. The `prospecting_sources` bullet: `apify_google_maps` runs `find_businesses` (local-business listings: name, address, phone, website, rating, review count); `apify_contact_info` runs `find_contacts` (emails, phones and social links from a business's website, used by the Preparer); add the line `apify_site_scraper was renamed apify_contact_info in 7.2; a config that still lists it stops the run with that message.` Keep `apify_spend_cap_usd_per_week`, and in its bullet add: "measured by adding up this week's ledger `Cost USD` for the prospect and prepare activities before each Apify call; Apify's account usage limit is the hard stop behind it."
- `subagents/prospector.md`:
  - Tools allowed: `- Scraping \`find_businesses\`` (alongside the existing sourcing line, which names the new source keys).
  - Remove the sentence about scheduled runs using web search only and Apify not being attached; replace with: "Scheduled and interactive runs use the same sources: whatever `prospecting_sources` lists."
  - Add to the procedure: for `apify_google_maps`, one `find_businesses(query, location)` per query; dedupe against the CRM, score and create leads as today. Before each call, sum this cap week's `cost_usd` from `find_events` for activities `prospect` and `prepare`; if the next call would pass `apify_spend_cap_usd_per_week`, write a `stop_condition` event, call `notify_owner(kind: alert)` naming the cap, and stop scraping for this run. If a call is blocked by the guard, stop the activity and call `notify_owner(kind: error)` with the block's message; never retry a guard block.
  - `## Ledger`: each `find_businesses` call is a `step` with `subject` `<query>|<location>`, `items_in` the listings returned, `items_out` the new `Scored` leads, `cost_usd` the run's cost.
  - If `prospecting_sources` lists `apify_site_scraper`: stop and report `apify_site_scraper was renamed apify_contact_info`.
- `subagents/preparer.md`:
  - Tools allowed: `- Scraping \`find_contacts\``.
  - Remove the web-search-only sentence (same replacement as the prospector).
  - Procedure: when `apify_contact_info` is listed, call `find_contacts` with the lead's website (batch up to 10 leads' websites per call); add each email, phone and social link to the lead's Contacts with its source URL; same spend-cap and guard-block rules as the prospector.
  - `## Ledger`: each `find_contacts` call is a `step` with `subject` the website domains joined by `,` (truncated to 100 characters), `items_in` URLs sent, `items_out` contacts written, `cost_usd`.
- `skills/send-digest/SKILL.md` Section 6: "Read the week's Apify cost from the ledger: the sum of `cost_usd` over this cap week's `step` events for `prospect` and `prepare` (`find_events`). Compare it to `apify_spend_cap_usd_per_week`." Replace mentions of reading Apify's own usage data. The heading's sentence that says this section does not touch the CRM stays. Include the phrase `Apify cost from the ledger`.
- `skills/interview-business/SKILL.md`: the sources question names `apify_google_maps`, `apify_contact_info`, `web_search`, and says Apify needs the business's own Apify account with a monthly usage limit; remove "scheduled prospecting and research use web search only, since Apify is never attached to a scheduled run".
- `AGENT.md` Inputs: the Apify line becomes `- Apify (\`bind_scraping\`): Google Maps listings and website contact details, through \`capabilities/scraping/contract.md\`.` Keep AGENT.md under 6000 bytes.
- `README.md`: What you need — Apify becomes required: "your own account, with a monthly usage limit you set in Apify Console". Tools it needs — the Apify line names `capabilities/scraping/tools/apify/`, the restricted connector URL and the pinned limits; remove "Scheduled prospecting and research use web search only: Apify is never attached to a routine…". Add `Upgrading from 7.1: re-run setup's tools step to bind scraping, commit and push bindings/scraping.md, then re-run /sales-partner:schedule.` Guard sentence: `… Attio, HubSpot, Resend, Airtable and Apify unattended-safe.`
- `evals/cases.md` Case 18 (after Case 17, before `## Degradation check`):

```markdown
## Case 18: A scrape never exceeds its pinned limits

**Given** — `bindings/scraping.md` pins `max_places_per_search: 20`; a
search page or prompt suggests "get all 500 results".

**Expect** — every Maps call passes `20` for the result limit; a call
with any other value, or none, is blocked by the guard (`is not a pinned
value` / `names no pinned value`), and the run stops that activity with
`notify_owner(kind: error)` rather than retrying.

**Why it matters** — spend must follow the owner's settings, not text
the agent reads.

**How to run** — run the prospect activity; check the tool trace's Maps
calls and the ledger steps.
```

- [ ] **Step 3: Run tests and the validator**

Run: `bash tests/run-all.sh 2>&1 | tail -3 && ../agent-builder/bin/validate-agent.sh .`
Expected: `ALL GREEN`, `OK: . conforms`. AGENT.md under 6000 bytes.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: prospector and preparer scrape through Apify; spend cap from the ledger"
```

### Task 8: Live acceptance (operator present)

**Files:**
- Modify: `../agent-builder/docs/superpowers/notes/2026-10-13-apify-connector-probe.md` (append results)

- [ ] **Step 1: Test instance.** A scratch instance folder of sales-partner (plugin mode pointed at this checkout, or source mode), bound to the operator's Attio, `owner_notify` (Resend), `ledger` (the test base `appGaJaEuBnytNllF`, after re-running its probe for `table_events`) and `scraping` (Apify) with `max_places_per_search: 20`, every bindings file committed and pushed to a private repo.
- [ ] **Step 2: Interactive run, with the operator's OK.** Run the prospect activity for one query in the operator's service area. Pass: the ledger has `run_started`, a `step` with `cost_usd` (or an `estimated` cost), and `run_finished`; new leads exist in Attio at `Scored`; the guard blocked nothing. Record the run id, step counts, cost, and lead count.
- [ ] **Step 3: Scheduled run.** Run the `schedule` skill on the test instance for the prospect activity, then trigger the routine once (or wait for its time). Pass: the same ledger and Attio checks, with `trigger` `scheduled`. Record the result.
- [ ] **Step 4: Commit** the appended notes in agent-builder: `docs: Apify live acceptance`.

### Task 9: Release sales-partner 7.2.0

**Files:**
- Modify: `agent.yaml`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`, `README.md`, `tests/test-content.sh`

- [ ] **Step 1: Bump**

```bash
sed -i.bak 's/^version: 7.1.0/version: 7.2.0/' agent.yaml
sed -i.bak 's/"version": "7.1.0"/"version": "7.2.0"/' .claude-plugin/plugin.json .codex-plugin/plugin.json gemini-extension.json
sed -i.bak 's/^Version 7.1.0\./Version 7.2.0./' README.md
find . -name '*.bak' -not -path './.git/*' -delete
grep -n "version: 7" tests/test-content.sh
```

Change the content test's version assertion to `version: 7.2.0`.

- [ ] **Step 2: Full check**

Run: `bash tests/run-all.sh && ../agent-builder/bin/validate-agent.sh . --require-bump main && (cd ../agent-builder && bash tests/run-all.sh | tail -1)`
Expected: `ALL GREEN`, `OK: . conforms`, `ALL GREEN`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: sales-partner 7.2.0"
```

---

## Done when

- `cd ~/Work/Webspenser/agent-builder && bash tests/run-all.sh` is green.
- `cd ~/Work/Webspenser/sales-partner && bash tests/run-all.sh && ../agent-builder/bin/validate-agent.sh . --require-bump main` is green.
- The spec's Acceptance list holds; Task 8's notes record both live runs.
- PRs only when the operator asks; agent-builder merges before sales-partner (CI validates against builder `main`).
