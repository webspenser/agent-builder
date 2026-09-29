# Guard Policy (Agent Standard 1.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add declarative guard policies (`guard.yaml`) enforced by a reference Python engine, with validator-checked coverage, as Agent Standard 1.3 in agent-builder 1.3.0; move sales-partner (1.2.0) to guard policies for Attio, Gmail, and Airtable.

**Architecture:** `hooks/guard_policy.py` (stdlib only, byte-identical in every 1.3 agent) parses a strict YAML subset and decides one PreToolUse call: deny/allow globs on the tool name, then field rules on attribute maps found at configured paths. `hooks/guard.sh` runs it for every bound adapter that has a `guard.yaml`, including custom adapters. The validator imports the same parser, checks that `covers` matches the adapter's `enforce_*: adapter` invariants, and accepts each agent's hooks against the references for its own standard version or later.

**Tech Stack:** bash (macOS 3.2 compatible), Python 3 standard library, markdown/YAML, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-guard-policy-design.md` (builder repo).

## Global Constraints

- Builder checkout `/Users/hochoy/Work/Webspenser/agent-library`; work on branch `feat/standard-1.3` (create it from `spec/guard-policy`).
- sales-partner checkout `/Users/hochoy/Work/Webspenser/sales-partner`; work on branch `release/1.2.0` from `main`.
- Versions: builder `1.3.0`; sales-partner `1.2.0`; standard string `"1.3"`.
- Engine path in agents: `hooks/guard_policy.py`, mode 755, byte-identical to builder `_template/hooks/guard_policy.py`. Python 3 standard library only.
- Engine invocation: `python3 hooks/guard_policy.py <guard.yaml> <bindings-file|-> [label]` with the hook JSON on stdin; `python3 hooks/guard_policy.py --check <guard.yaml>` parses only.
- Engine exit codes: 0 allow, 2 block (stderr one line per problem). It never tracebacks.
- Block message prefix: `Blocked by <label>: ` where `guard.sh` passes label `<agent> guard policy (<capability>/<provider>)`.
- Versioned references live in builder `bin/lib/references/<version>/`; `_template/hooks/` always equals the newest version's directory.
- `hooks/hooks.json` does not change.
- Never modify `/Users/hochoy/Work/Webspenser/live-agents`. Never call Attio, Gmail, or Airtable tools except in Task 9's read-only acceptance.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- After editing scripts, confirm `git ls-files -s` shows `100755`.
- The bash-guard hook blocks compound commands resembling exfiltration and anything containing the word "credentials"; use simple separate commands.

## Review Focus

1. **Grammar edge cases** — tabs, nested maps, unclosed `[`, unknown keys, duplicate keys, unquoted glob starting with `*`: each must fail to parse (validator FAIL, runtime block). Pinned in Task 2.
2. **Airtable field keyed by ID** — `fld…` for Status is recognized via bindings; missing ID with `binding_id: required` blocks. Pinned in Task 2 and Task 8.
3. **Default-deny surprises** — every tool an adapter's `adapter.md` names must match its `allow` list. Pinned in Task 7/8 content tests.
4. **Versioned references** — a 1.2 agent with the 1.2 `guard.sh` still validates after 1.3 lands. Pinned in Task 1 and Task 3.
5. **Layer interplay** — `block`, `guard.yaml`, `guard.py` on one adapter all narrow; a policy `allow` never re-allows a `block`ed tool. Pinned in Task 3.

---

## Builder (tasks 1–6)

### Task 1: Versioned reference hooks

**Files:**
- Create: `bin/lib/references/1.1/session-start.sh`, `bin/lib/references/1.2/session-start.sh`, `bin/lib/references/1.2/guard.sh` (copies of today's `_template/hooks/` files, mode 755)
- Modify: `bin/lib/check_manifests.py`, `tests/test-validate-agent.sh`, `tests/run-all.sh`

**Interfaces:**
- Produces: `references_for(rel, minor) -> list[pathlib.Path]` in `check_manifests.py`; `check_reference_script(root, rel, references)` now takes a list. Later tasks add `bin/lib/references/1.3/`.

- [ ] **Step 1: Branch and archive**

```bash
git -C /Users/hochoy/Work/Webspenser/agent-library switch -c feat/standard-1.3 spec/guard-policy
cd /Users/hochoy/Work/Webspenser/agent-library
mkdir -p bin/lib/references/1.1 bin/lib/references/1.2
cp _template/hooks/session-start.sh bin/lib/references/1.1/
cp _template/hooks/session-start.sh bin/lib/references/1.2/
cp _template/hooks/guard.sh bin/lib/references/1.2/
chmod 755 bin/lib/references/1.1/*.sh bin/lib/references/1.2/*.sh
```

- [ ] **Step 2: Failing tests.** Append to the 1.2 block of `tests/test-validate-agent.sh` (before `finish`):

```bash
echo "-- versioned references"
# An agent whose guard.sh is an older version's reference still passes while that version is current or later.
make_valid_v12_agent "$FIX/v12-oldref"; cp bin/lib/references/1.2/guard.sh "$FIX/v12-oldref/hooks/guard.sh"
assert_pass $V "$FIX/v12-oldref"
```

and in `tests/run-all.sh`, after the template section:

```bash
echo "== template hooks equal the newest reference"
LATEST=$(ls bin/lib/references | sort -t. -k1,1n -k2,2n | tail -n 1)
for f in bin/lib/references/"$LATEST"/*; do
  cmp -s "$f" "_template/hooks/$(basename "$f")" || { echo "FAIL: _template/hooks/$(basename "$f") differs from bin/lib/references/$LATEST"; STATUS=1; }
done
```

This task is a refactor guarded by the existing tests: the new case passes before and after (today the 1.2 reference equals the template). Task 3 adds the cases that fail without `references_for`. Run `tests/run-all.sh` to record the baseline.

- [ ] **Step 3: Implement.** In `bin/lib/check_manifests.py`:

Add below `TEMPLATE_HOOKS`:

```python
REFERENCES = pathlib.Path(__file__).resolve().parent / "references"


def _version_key(name):
    try:
        major, minor = name.split(".")
        return int(major), int(minor)
    except ValueError:
        return None


def references_for(rel, minor):
    """Reference copies of hooks/<file> an agent at standard 1.<minor> may carry:
    its own version's and every later one's, plus the template's (the newest)."""
    name = pathlib.PurePosixPath(rel).name
    found = []
    if REFERENCES.is_dir():
        for d in sorted(REFERENCES.iterdir(), key=lambda p: _version_key(p.name) or (0, 0)):
            key = _version_key(d.name)
            if key and key[0] == 1 and key[1] >= minor and (d / name).is_file():
                found.append(d / name)
    template = TEMPLATE_HOOKS / name
    if template.is_file():
        found.append(template)
    return found
```

Replace `check_reference_script` with:

```python
def check_reference_script(root, rel, references):
    """`rel` exists, is executable, and is byte-identical to one of `references`."""
    script = root / rel
    if not script.is_file():
        return [f"missing {rel}"]
    fails = []
    if not os.access(script, os.X_OK):
        fails.append(f"{rel} is not executable")
    if not references:
        fails.append(f"validator is missing its reference hook for {rel}")
        return fails
    try:
        data = script.read_bytes()
        same = any(data == ref.read_bytes() for ref in references)
    except OSError:
        fails.append(f"{rel} cannot be read")
    else:
        if not same:
            fails.append(f"{rel} differs from the Agent Standard reference copy (_template/{rel} in agent-builder)")
    return fails
```

Remove the constants `REFERENCE_HOOK` and `REFERENCE_GUARD`. Change the two call sites: in `check_v11` use `check_reference_script(root, "hooks/session-start.sh", references_for("hooks/session-start.sh", minor))` and in `check_v12` use `check_reference_script(root, "hooks/guard.sh", references_for("hooks/guard.sh", minor))`. Give `check_v11(root, meta, name, minor)` and `check_v12(root, meta, minor)` a `minor` parameter and pass it from `check`.

- [ ] **Step 4: Verify** — `tests/run-all.sh` ends `ALL GREEN` (all messages unchanged).

- [ ] **Step 5: Commit**

```bash
git add bin/lib/references bin/lib/check_manifests.py tests/test-validate-agent.sh tests/run-all.sh
git commit -m "feat: versioned reference hooks in the validator"
```

---

### Task 2: The guard-policy engine

**Files:**
- Create: `_template/hooks/guard_policy.py` (mode 755)
- Create: `tests/test-guard-policy.sh` (mode 755)
- Modify: `tests/run-all.sh` (add `echo "== guard policy"; tests/test-guard-policy.sh || STATUS=1` after the guard line)

**Interfaces:**
- Produces: `guard_policy.parse(text) -> dict` raising `guard_policy.PolicyError`; CLI as in Global Constraints. Task 4 imports `parse` and `PolicyError`.

- [ ] **Step 1: Failing tests** — `tests/test-guard-policy.sh`:

```bash
#!/usr/bin/env bash
# The Agent Standard 1.3 guard-policy engine (_template/hooks/guard_policy.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
E="$PWD/_template/hooks/guard_policy.py"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

policy() { printf '%s\n' "$@" > "$W/guard.yaml"; }
parses() { # parses <0|1> <label>
  local out rc; out=$(python3 "$E" --check "$W/guard.yaml" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && ! printf '%s' "$out" | grep -q Traceback; then _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
run() { # run <rc> <label> <tool_name> <tool_input JSON> [text] [bindings]
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":%s}' "$3" "$4" | python3 "$E" "$W/guard.yaml" "${6:--}" "demo guard policy (crm/demo)" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && { [ -z "${5:-}" ] || printf '%s\n' "$out" | grep -qF -- "$5"; } && ! printf '%s' "$out" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}

echo "-- grammar"
policy 'covers: [draft_only]' 'allow: [list-*, "*read*",' '        get-*]  # continued' 'deny: ["*delete*"]'; parses 0 "flow lists, quotes, continuation, comments"
policy 'covers: [draft_only]' 'rules:' '  - field: status' '    create: [draft]' '    update: [voided]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]'; parses 0 "rules block"
policy 'allow: [a]';                                  parses 1 "covers is required"
policy 'covers: [x]' 'bogus: 1';                      parses 1 "unknown key"
policy 'covers: [x]' 'covers: [y]';                   parses 1 "duplicate key"
policy 'covers: [x]' 'allow: [a, b';                  parses 1 "unclosed ["
policy 'covers: [x]' $'allow:\t[a]';                  parses 1 "tab"
policy 'covers: [x]' 'allow:' '  a: b';               parses 1 "nested map"
policy 'covers: [x]' 'allow: [*delete*]';             parses 1 "unquoted glob starting with *"
policy 'covers: [x]' 'allow: [[a]]';                  parses 1 "nested list"
policy 'covers: [x]' 'allow: a';                      parses 1 "list key given a scalar"
policy 'covers: [Bad-Id]';                            parses 1 "covers id not snake_case"
policy 'covers: [x]' 'unknown_writes: maybe';         parses 1 "unknown_writes value"
policy 'covers: [x]' 'refuse_keys: [nope]';           parses 1 "unknown refuse_keys preset"
policy 'covers: [x]' 'rules:' '  - field: status' '    create: [draft]'; parses 1 "rules without create_tools/update_tools/values_at"
policy 'covers: [x]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]' 'rules:' '  - field: status'; parses 1 "rule without a list"
policy 'covers: [x]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: ["bad path!"]' 'rules:' '  - field: s' '    any: [a]'; parses 1 "bad values_at path"
policy 'covers: [x]' 'rules:';                        parses 1 "empty rules"
: > "$W/guard.yaml"; parses 1 "empty file"

echo "-- tool names"
policy 'covers: [no_delete]' 'allow: [list-*, update-record]' 'deny: ["*delete*"]'
run 0 "allowed tool"                 mcp__attio__list-records '{}'
run 2 "not in allow list"            mcp__attio__create-list '{}' "is not in the allow list"
run 2 "deny beats allow"             mcp__attio__list-delete-me '{}' "is denied"
run 2 "deny on a later __ suffix"    mcp__attio__delete__record '{}' "is denied"
run 0 "server containing __"         mcp__x__Attio__list-records '{}'
run 0 "case-insensitive"             mcp__attio__LIST-Records '{}'
policy 'covers: [no_delete]' 'deny: ["*delete*"]'
run 0 "no allow list: others allowed" mcp__attio__create-list '{}'

echo "-- writes and rules"
policy 'covers: [draft_only, dnc_one_way]' 'create_tools: [add-record-to-list]' 'update_tools: [update-entry]' \
  'values_at: [entry_values, values, "records[].fields"]' 'unwrap: [option, value]' 'refuse_keys: [uuid]' \
  'rules:' '  - field: status' '    create: [draft]' '    update: [voided]' '  - field: do_not_contact' '    update: [true]'
run 0 "create draft"                 mcp__a__add-record-to-list '{"entry_values":{"status":"draft"}}'
run 2 "create approved"              mcp__a__add-record-to-list '{"entry_values":{"status":"approved"}}' "status may only be written as draft on create"
run 0 "wrapped value"                mcp__a__add-record-to-list '{"entry_values":{"status":{"option":"Draft"}}}'
run 2 "mixed wrapped values"         mcp__a__add-record-to-list '{"entry_values":{"status":{"option":"draft","value":"sent"}}}'
run 2 "unknown object shape"         mcp__a__add-record-to-list '{"entry_values":{"status":{"foo":1}}}' "cannot check this call"
run 0 "update voided"                mcp__a__update-entry '{"entry_values":{"status":"voided"}}'
run 2 "update draft"                 mcp__a__update-entry '{"entry_values":{"status":"draft"}}' "on update"
run 0 "dnc true"                     mcp__a__update-entry '{"values":{"do_not_contact":true}}'
run 2 "dnc false"                    mcp__a__update-entry '{"values":{"do_not_contact":false}}' "do_not_contact may only be written as true"
run 0 "dnc false on create (no create list)" mcp__a__add-record-to-list '{"entry_values":{"do_not_contact":false}}'
run 2 "uuid key refused"             mcp__a__update-entry '{"values":{"925c1cde-cba6-453e-96f9-5bd8f498d8a3":"sent"}}' "addressed by ID"
run 2 "unknown tool with values is an update" mcp__a__assert-entry '{"entry_values":{"status":"approved"}}'
run 0 "unknown tool without values"  mcp__a__create-note '{"title":"x"}'
run 2 "list path"                    mcp__a__update-entry '{"records":[{"fields":{"status":"voided"}},{"fields":{"Status":"sent"}}]}'
run 2 "field name normalization"     mcp__a__update-entry '{"records":[{"fields":{"Do Not Contact":false}}]}'
run 2 "attribute map not an object"  mcp__a__update-entry '{"entry_values":[1]}' "cannot check this call"
policy 'covers: [x]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]' 'unknown_writes: block' 'rules:' '  - field: s' '    any: [a]'
run 2 "unknown_writes: block"        mcp__a__other '{"v":{"s":"a"}}' "not a known create or update tool"

echo "-- field identity"
policy 'covers: [draft_only]' 'create_tools: [create_records]' 'update_tools: [update_records]' 'values_at: ["records[].fields"]' \
  'rules:' '  - field: Status' '    binding_id: required' '    create: [draft]' '    update: [voided]'
printf '%s\n' '# CRM binding — Airtable' 'base_id: appXXXXXXXXXXXXXX' 'field_status: fldAAAAAAAAAAAAAA' > "$W/bindings.md"
run 2 "status by field ID"           mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"approved"}}]}' "Status may only be written as voided" "$W/bindings.md"
run 0 "draft by field ID on create"  mcp__airtable__create_records '{"records":[{"fields":{"fldAAAAAAAAAAAAAA":"draft","fldBBBBBBBBBBBBBB":"x"}}]}' "" "$W/bindings.md"
run 2 "required ID missing"          mcp__airtable__create_records '{"records":[{"fields":{"fldBBBBBBBBBBBBBB":"x"}}]}' "has not recorded field_status"
run 0 "read tool needs no binding"   mcp__airtable__list_records '{}'

echo "-- fail closed"
policy 'covers: [x]' 'allow: [a'
run 2 "invalid policy blocks"        mcp__a__a '{}' "cannot check this call"
out=$(printf '{not json' | python3 "$E" "$W/guard.yaml" - x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "bad JSON blocks" || _report no "bad JSON (rc=$rc): $out"
out=$(printf '{}' | python3 "$E" "$W/missing.yaml" - x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "missing policy blocks" || _report no "missing policy (rc=$rc): $out"
[ -x "$E" ] && _report ok "engine executable" || _report no "engine not executable"

finish
```

`chmod 755 tests/test-guard-policy.sh`; add the run-all line. Run it: every case fails (no engine).

- [ ] **Step 2: Implement `_template/hooks/guard_policy.py`**

```python
#!/usr/bin/env python3
"""Agent Standard 1.3 guard-policy engine — identical in every agent.

Usage:
  guard_policy.py <guard.yaml> <bindings-file|-> [label]   hook input JSON on stdin
  guard_policy.py --check <guard.yaml>                      parse only

Decides one PreToolUse call against one adapter's guard policy: exit 2 blocks
(stderr says why), exit 0 allows. Any error blocks — a bug fails closed.
The policy format is a strict YAML subset; see STANDARD.md "Guard policy".
"""
import fnmatch
import json
import re
import sys

KEYS = ("covers", "allow", "deny", "create_tools", "update_tools", "values_at",
        "unwrap", "unknown_writes", "refuse_keys", "rules")
LIST_KEYS = ("covers", "allow", "deny", "create_tools", "update_tools", "values_at",
             "unwrap", "refuse_keys")
RULE_KEYS = ("field", "binding_id", "create", "update", "any")
REFUSE_PRESETS = {
    "uuid": re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I),
}
KEY_LINE = re.compile(r"^([a-z_]+):(.*)$")
SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")
PATH = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[\])?(\.[A-Za-z_][A-Za-z0-9_]*(\[\])?)*$")
BINDING_LINE = re.compile(r"^([a-z_][a-z0-9_]*):\s*(\S.*?)\s*$")


class PolicyError(Exception):
    """The policy file or the call cannot be checked."""


# ---- parsing ---------------------------------------------------------------

def _strip_comment(text, lineno):
    out, quote = [], None
    for ch in text:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#":
            break
        out.append(ch)
    if quote:
        raise PolicyError(f"line {lineno}: unterminated quote")
    return "".join(out).rstrip()


def _scalar(token, lineno):
    token = token.strip()
    if not token:
        raise PolicyError(f"line {lineno}: empty value")
    if token[0] in "'\"":
        if len(token) < 2 or token[-1] != token[0]:
            raise PolicyError(f"line {lineno}: bad quoted value {token}")
        return token[1:-1]
    if token[0] in "*&!|>%@`" or any(c in token for c in "[]{}") or ": " in token:
        raise PolicyError(f"line {lineno}: value {token!r} must be quoted")
    return token


def _flow_list(text, lineno):
    text = text.strip()
    if not (text.startswith("[") and text.endswith("]")):
        raise PolicyError(f"line {lineno}: expected a list like [a, b]")
    items, cur, quote = [], "", None
    for ch in text[1:-1]:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            cur += ch
        elif ch == ",":
            items.append(cur)
            cur = ""
        elif ch in "[]{}":
            raise PolicyError(f"line {lineno}: nested lists and maps are not allowed")
        else:
            cur += ch
    if cur.strip() or items:
        items.append(cur)
    return [_scalar(item, lineno) for item in items]


def _parse_rules(lines, i):
    rules = []
    while i < len(lines):
        lineno = i + 1
        raw = lines[i]
        if "\t" in raw:
            raise PolicyError(f"line {lineno}: tabs are not allowed")
        line = _strip_comment(raw, lineno)
        if not line.strip():
            i += 1
            continue
        if not line.startswith(" "):
            break
        if line.startswith("  - "):
            rules.append({})
            body = line[4:]
        elif line.startswith("    ") and rules and not line[4:5].isspace():
            body = line[4:]
        else:
            raise PolicyError(f"line {lineno}: rule items are '  - key: value' with further keys indented 4 spaces")
        m = KEY_LINE.match(body)
        if not m:
            raise PolicyError(f"line {lineno}: expected 'key: value'")
        key, value = m.group(1), m.group(2).strip()
        if key not in RULE_KEYS:
            raise PolicyError(f"line {lineno}: unknown rule key '{key}'")
        if key in rules[-1]:
            raise PolicyError(f"line {lineno}: duplicate rule key '{key}'")
        if value.startswith("["):
            rules[-1][key] = _flow_list(value, lineno)
        else:
            rules[-1][key] = _scalar(value, lineno)
        i += 1
    if not rules:
        raise PolicyError("rules: has no items")
    return rules, i


def _validate(policy):
    if "covers" not in policy:
        raise PolicyError("covers is required")
    for key in LIST_KEYS:
        if key in policy and not isinstance(policy[key], list):
            raise PolicyError(f"{key} must be a list like [a, b]")
    if not policy["covers"]:
        raise PolicyError("covers must name at least one invariant")
    for inv in policy["covers"]:
        if not SNAKE.match(inv):
            raise PolicyError(f"covers: '{inv}' is not a snake_case invariant id")
    if policy.get("unknown_writes", "update") not in ("update", "block"):
        raise PolicyError("unknown_writes must be update or block")
    for preset in policy.get("refuse_keys", []):
        if preset not in REFUSE_PRESETS:
            raise PolicyError(f"refuse_keys: unknown preset '{preset}'")
    for path in policy.get("values_at", []):
        if not PATH.match(path):
            raise PolicyError(f"values_at: '{path}' is not a path like values or records[].fields")
    for key in ("allow", "deny", "create_tools", "update_tools", "unwrap"):
        for item in policy.get(key, []):
            if not item:
                raise PolicyError(f"{key}: empty entry")
    if "rules" in policy:
        for key in ("create_tools", "update_tools", "values_at"):
            if key not in policy:
                raise PolicyError(f"{key} is required when rules are present")
        if not policy["values_at"]:
            raise PolicyError("values_at must name at least one path")
        for rule in policy["rules"]:
            if not isinstance(rule.get("field"), str) or not rule["field"]:
                raise PolicyError("each rule needs a field")
            if rule.get("binding_id", "required") != "required":
                raise PolicyError("binding_id may only be 'required'")
            lists = [k for k in ("create", "update", "any") if k in rule]
            if not lists:
                raise PolicyError(f"rule for {rule['field']} needs create, update, or any")
            for k in lists:
                if not isinstance(rule[k], list) or not rule[k]:
                    raise PolicyError(f"rule for {rule['field']}: {k} must be a non-empty list")


def parse(text):
    """Parse and validate a guard.yaml text. Raises PolicyError."""
    lines = text.splitlines()
    policy, i = {}, 0
    while i < len(lines):
        lineno = i + 1
        raw = lines[i]
        if "\t" in raw:
            raise PolicyError(f"line {lineno}: tabs are not allowed")
        line = _strip_comment(raw, lineno)
        if not line.strip():
            i += 1
            continue
        m = KEY_LINE.match(line)
        if line[0] == " " or not m:
            raise PolicyError(f"line {lineno}: expected 'key: value' at column 0")
        key, value = m.group(1), m.group(2).strip()
        if key not in KEYS:
            raise PolicyError(f"line {lineno}: unknown key '{key}'")
        if key in policy:
            raise PolicyError(f"line {lineno}: duplicate key '{key}'")
        i += 1
        if key == "rules":
            if value:
                raise PolicyError(f"line {lineno}: rules: takes '  - field: ...' items on the following lines")
            policy["rules"], i = _parse_rules(lines, i)
            continue
        if not value:
            raise PolicyError(f"line {lineno}: {key} has no value")
        if value.startswith("["):
            while not value.endswith("]"):
                if i >= len(lines) or not lines[i].startswith(" "):
                    raise PolicyError(f"line {lineno}: unclosed '['")
                if "\t" in lines[i]:
                    raise PolicyError(f"line {i + 1}: tabs are not allowed")
                value += " " + _strip_comment(lines[i], i + 1).strip()
                i += 1
            policy[key] = _flow_list(value, lineno)
        else:
            policy[key] = _scalar(value, lineno)
    if not policy:
        raise PolicyError("the policy is empty")
    _validate(policy)
    return policy


# ---- deciding a call -------------------------------------------------------

def _norm(name):
    return re.sub(r"[\s-]+", "_", str(name).strip().lower())


def _candidates(tool_name):
    if not isinstance(tool_name, str) or not tool_name.startswith("mcp__"):
        raise PolicyError("not an MCP tool name")
    rest, found, at = tool_name[5:], [], 0
    while True:
        at = rest.find("__", at)
        if at < 0:
            break
        if rest[at + 2:]:
            found.append(rest[at + 2:].lower())
        at += 2
    if not found:
        raise PolicyError("no tool name after the server")
    return found


def _matches(candidates, patterns):
    return any(fnmatch.fnmatchcase(c, p.lower()) for c in candidates for p in patterns)


def _maps_at(obj, path):
    nodes = [obj]
    for part in path.split("."):
        many = part.endswith("[]")
        name = part[:-2] if many else part
        nxt = []
        for node in nodes:
            if not isinstance(node, dict) or name not in node:
                continue
            value = node[name]
            if many:
                if not isinstance(value, list):
                    raise PolicyError(f"{path}: {name} is not a list")
                nxt.extend(value)
            else:
                nxt.append(value)
        nodes = nxt
    for node in nodes:
        if not isinstance(node, dict):
            raise PolicyError(f"{path}: attribute values are not an object")
    return nodes


def _leaves(value, unwrap):
    if isinstance(value, list):
        return [leaf for item in value for leaf in _leaves(item, unwrap)]
    if isinstance(value, dict):
        leaves = [leaf for key in unwrap if key in value for leaf in _leaves(value[key], unwrap)]
        if not leaves:
            raise PolicyError("unrecognized value shape")
        return leaves
    if isinstance(value, bool):
        return ["true" if value else "false"]
    if value is None:
        return ["null"]
    return [str(value).strip().lower()]


def read_bindings(path):
    if path == "-":
        return {}
    data = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = BINDING_LINE.match(line.rstrip("\r\n"))
            if m:
                data[m.group(1)] = m.group(2)
    return data


def problems(policy, event, bindings):
    tool_name = event.get("tool_name")
    names = _candidates(tool_name)
    shown = names[0]
    for pattern in policy.get("deny", []):
        if _matches(names, [pattern]):
            return [f"{shown} is denied ({pattern})"]
    if "allow" in policy and not _matches(names, policy["allow"]):
        return [f"{shown} is not in the allow list"]
    rules = policy.get("rules", [])
    refuse = [REFUSE_PRESETS[p] for p in policy.get("refuse_keys", [])]
    if not rules and not refuse:
        return []
    if _matches(names, policy.get("create_tools", [])):
        kind = "create"
    elif _matches(names, policy.get("update_tools", [])):
        kind = "update"
    else:
        kind = None
    args = event.get("tool_input")
    if not isinstance(args, dict):
        if kind:
            raise PolicyError("tool_input is not an object")
        return []
    maps = [m for path in policy.get("values_at", []) for m in _maps_at(args, path)]
    if kind is None:
        if not maps:
            return []
        if policy.get("unknown_writes", "update") == "block":
            return [f"{shown} writes values but is not a known create or update tool"]
        kind = "update"
    found = []
    ids = {}
    for rule in rules:
        field = _norm(rule["field"])
        bound = bindings.get(f"field_{field}")
        if rule.get("binding_id") == "required" and not bound:
            found.append(f"the probe has not recorded field_{field} in bindings; re-run setup's tools step")
        ids[field] = {field} | ({_norm(bound)} if bound else set())
    unwrap = policy.get("unwrap", [])
    for amap in maps:
        for key in amap:
            if any(p.match(str(key)) for p in refuse):
                found.append(f"attribute {key} is addressed by ID; use its name")
        for rule in rules:
            field = _norm(rule["field"])
            allowed = rule.get(kind) or rule.get("any")
            if not allowed:
                continue
            for key, value in amap.items():
                if _norm(key) not in ids[field]:
                    continue
                if _leaves(value, unwrap) not in [[a.lower()] for a in allowed]:
                    found.append(f"{rule['field']} may only be written as {', '.join(allowed)} on {kind}")
    return found


def main(argv):
    if len(argv) == 2 and argv[0] == "--check":
        try:
            with open(argv[1], encoding="utf-8") as fh:
                parse(fh.read())
        except (OSError, UnicodeDecodeError, PolicyError) as err:
            print(f"FAIL: {err}")
            return 1
        return 0
    if len(argv) not in (2, 3):
        print("usage: guard_policy.py <guard.yaml> <bindings-file|-> [label] | --check <guard.yaml>", file=sys.stderr)
        return 2
    label = argv[2] if len(argv) == 3 else "guard policy"
    try:
        with open(argv[0], encoding="utf-8") as fh:
            policy = parse(fh.read())
        bindings = read_bindings(argv[1])
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise PolicyError("hook input is not an object")
        found = problems(policy, event, bindings)
    except Exception as err:  # fail closed
        print(f"Blocked by {label}: cannot check this call ({type(err).__name__}: {err})", file=sys.stderr)
        return 2
    for problem in dict.fromkeys(found):
        print(f"Blocked by {label}: {problem}", file=sys.stderr)
    return 2 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Note on "rule applies when": `allowed = rule.get(kind) or rule.get("any")` — a rule with only `create` does not check updates, matching the spec ("A field with no applicable list for this kind of write is not checked").

`chmod 755 _template/hooks/guard_policy.py`.

- [ ] **Step 3: Run** `tests/test-guard-policy.sh` → `0 failed`; fix the engine (not the tests) for any failure, unless a test contradicts the spec — then explain in the report.

- [ ] **Step 4:** `tests/run-all.sh` → `ALL GREEN`. (The "template hooks equal the newest reference" check iterates the newest reference directory, still `1.2`, so the new `_template/hooks/guard_policy.py` does not trip it; Task 3 adds `references/1.3`.)

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard_policy.py tests/test-guard-policy.sh tests/run-all.sh
git commit -m "feat: guard-policy engine (Agent Standard 1.3)"
```

---

### Task 3: `guard.sh` runs guard policies; 1.3 references

**Files:**
- Modify: `_template/hooks/guard.sh`, `tests/test-guard.sh`
- Create: `bin/lib/references/1.3/{session-start.sh,guard.sh,guard_policy.py}` (copies of `_template/hooks/` after this change, mode 755)
- Modify: `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: engine CLI (Task 2).
- Produces: 1.3 `guard.sh` (Tasks 5, 7 copy it).

- [ ] **Step 1: Failing tests.** In `tests/test-guard.sh`, after the existing cases and before the hooks.json assertions, add:

```bash
echo "-- guard policies (1.3)"
mkdir -p "$PKG/hooks"; cp _template/hooks/guard_policy.py "$PKG/hooks/"
GP="$PKG/capabilities/crm/adapters/pol"; mkdir -p "$GP"
printf '%s\n' 'capability: crm' 'provider: pol' 'server_match: polcrm' 'block: merge' 'enforce_draft_only: adapter' > "$GP/adapter.yaml"
printf '%s\n' 'covers: [draft_only]' 'allow: [list-*, update-entry, "*merge*"]' 'update_tools: [update-entry]' 'create_tools: [add-entry]' \
  'values_at: [values]' 'rules:' '  - field: status' '    update: [voided]' > "$GP/guard.yaml"
PI="$W/polinst"; mkdir -p "$PI"
printf '%s\n' 'agent: demo-agent' 'mode: plugin' 'bind_crm: pol' > "$PI/instance.yaml"
run_guard "$PI" "$(call mcp__polcrm__list-records)";                           expect 0 "policy: allowed tool"
run_guard "$PI" "$(call mcp__polcrm__drop-table)";                             expect 2 "policy: not in allow list" "Blocked by demo-agent guard policy (crm/pol): drop-table is not in the allow list"
run_guard "$PI" "$(call mcp__polcrm__update-entry '{"values":{"status":"sent"}}')"; expect 2 "policy: field rule" "status may only be written as voided on update"
run_guard "$PI" "$(call mcp__polcrm__merge-records)";                          expect 2 "block beats policy allow" "is blocked for crm (pol adapter)"
run_guard "$PI" "$(call mcp__other__drop-table)";                              expect 0 "policy: other servers untouched"
# Custom adapter policies run (data, not code).
CP="$W/custpol"; mkdir -p "$CP/custom-adapters/crm"
printf '%s\n' 'agent: demo-agent' 'mode: plugin' 'bind_crm: custom' > "$CP/instance.yaml"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: polcrm' > "$CP/custom-adapters/crm/adapter.yaml"
printf '%s\n' 'covers: [draft_only]' 'allow: [list-*]' > "$CP/custom-adapters/crm/guard.yaml"
run_guard "$CP" "$(call mcp__polcrm__drop-table)";                             expect 2 "custom policy enforced" "is not in the allow list"
# Bindings file is passed to the engine.
printf '%s\n' 'covers: [draft_only]' 'update_tools: [update-entry]' 'create_tools: [add-entry]' 'values_at: [values]' \
  'rules:' '  - field: status' '    binding_id: required' '    update: [voided]' > "$GP/guard.yaml"
run_guard "$PI" "$(call mcp__polcrm__update-entry '{"values":{"fldS":"sent"}}')"; expect 2 "required binding missing" "has not recorded field_status"
mkdir -p "$PI/bindings"; printf '%s\n' 'field_status: fldS' > "$PI/bindings/crm.md"
run_guard "$PI" "$(call mcp__polcrm__update-entry '{"values":{"fldS":"voided"}}')"; expect 0 "binding ID recognized"
run_guard "$PI" "$(call mcp__polcrm__update-entry '{"values":{"fldS":"sent"}}')"; expect 2 "binding ID enforced"
# Engine missing / python3 missing / invalid policy: fail closed.
mv "$PKG/hooks/guard_policy.py" "$W/gp.bak"
run_guard "$PI" "$(call mcp__polcrm__list-records)";                           expect 2 "engine missing blocks" "engine is missing"
mv "$W/gp.bak" "$PKG/hooks/guard_policy.py"
OUT=$(printf '%s' "$(call mcp__polcrm__list-records)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$PI" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 2 "policy without python3 blocks" "python3 is required"
printf '%s\n' 'covers: [draft_only]' 'allow: [list-*' > "$GP/guard.yaml"
run_guard "$PI" "$(call mcp__polcrm__list-records)";                           expect 2 "invalid policy blocks" "cannot check this call"
```

In `tests/test-validate-agent.sh` 1.2 block, add after the `v12-oldref` case:

```bash
# A 1.2 agent may also carry the newer (1.3) guard.sh.
make_valid_v12_agent "$FIX/v12-newref"; cp bin/lib/references/1.3/guard.sh "$FIX/v12-newref/hooks/guard.sh"
assert_pass $V "$FIX/v12-newref"
# ...and a 1.2 agent with the 1.2 guard.sh passes although the template is now 1.3.
make_valid_v12_agent "$FIX/v12-keep"; cp bin/lib/references/1.2/guard.sh "$FIX/v12-keep/hooks/guard.sh"
assert_pass $V "$FIX/v12-keep"
```

Run `tests/test-guard.sh`: the new cases fail.

- [ ] **Step 2: Implement.** In `_template/hooks/guard.sh`, replace the line `  [ "$provider" = custom ] && continue  # never execute code from an instance folder` with:

```bash
  if [ -f "$adir/guard.yaml" ]; then  # declarative policy (1.3): data, so custom adapters get it too
    engine="$root/hooks/guard_policy.py"
    [ -f "$engine" ] || block "the guard policy engine is missing from $name"
    command -v python3 >/dev/null 2>&1 || block "python3 is required to run the $provider guard policy for $cap"
    bfile="$instance/bindings/$cap.md"
    [ -f "$bfile" ] || bfile=-
    printf '%s' "$input" | python3 "$engine" "$adir/guard.yaml" "$bfile" "$name guard policy ($cap/$provider)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -eq 2 ] && exit 2
      block "the $provider guard policy for $cap failed (exit $rc)"
    fi
  fi
  [ "$provider" = custom ] && continue  # never execute code from an instance folder
```

Update the header comment's second sentence to: "…a tool whose name contains one of the adapter's `block` entries is refused, then the adapter's guard policy (`guard.yaml`, run by `guard_policy.py`) and its code guard (package adapters only) inspect the call."

- [ ] **Step 3: 1.3 references**

```bash
mkdir -p bin/lib/references/1.3
cp _template/hooks/session-start.sh _template/hooks/guard.sh _template/hooks/guard_policy.py bin/lib/references/1.3/
chmod 755 bin/lib/references/1.3/*
```

- [ ] **Step 4: Verify** — `tests/test-guard.sh`, `tests/test-validate-agent.sh`, `tests/run-all.sh` → all pass, ALL GREEN.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard.sh tests/test-guard.sh tests/test-validate-agent.sh bin/lib/references/1.3
git commit -m "feat: guard.sh runs guard policies; 1.3 reference hooks"
```

---

### Task 4: Validator checks for 1.3

**Files:**
- Modify: `bin/lib/check_manifests.py`, `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `parse`, `PolicyError` from `_template/hooks/guard_policy.py`; `references_for`.

- [ ] **Step 1: Failing tests.** Append a 1.3 block to `tests/test-validate-agent.sh` before `finish`:

```bash
echo "-- Agent Standard 1.3"
make_valid_v13_agent() { # make_valid_v13_agent <dir>
  local d="$1" a="$1/capabilities/crm/adapters/demo"
  make_valid_v12_agent "$d"
  sed -i.bak 's/^standard:.*/standard: "1.3"/' "$d/agent.yaml" && rm -f "$d/agent.yaml.bak"
  cp _template/hooks/guard.sh _template/hooks/guard_policy.py "$d/hooks/"; chmod 755 "$d/hooks/guard.sh" "$d/hooks/guard_policy.py"
  printf '%s\n' 'covers: [draft_only, no_send]' 'deny: ["*send*"]' > "$a/guard.yaml"
}
A13=capabilities/crm/adapters/demo
make_valid_v13_agent "$FIX/v13"; assert_pass $V "$FIX/v13"
make_valid_v13_agent "$FIX/v13-noengine"; rm "$FIX/v13-noengine/hooks/guard_policy.py"
fails_with "$FIX/v13-noengine" "missing hooks/guard_policy.py"
make_valid_v13_agent "$FIX/v13-oldguard"; cp bin/lib/references/1.2/guard.sh "$FIX/v13-oldguard/hooks/guard.sh"
fails_with "$FIX/v13-oldguard" "hooks/guard.sh differs from the Agent Standard reference copy (_template/hooks/guard.sh in agent-builder)"
make_valid_v13_agent "$FIX/v13-badpol"; printf '%s\n' 'covers: [draft_only' > "$FIX/v13-badpol/$A13/guard.yaml"
fails_with "$FIX/v13-badpol" "$A13/guard.yaml: line 1: unclosed '['"
make_valid_v13_agent "$FIX/v13-uncovered"; printf '%s\n' 'covers: [draft_only]' > "$FIX/v13-uncovered/$A13/guard.yaml"
fails_with "$FIX/v13-uncovered" "$A13/guard.yaml: covers must list no_send (enforce_no_send: adapter)"
make_valid_v13_agent "$FIX/v13-strange"; printf '%s\n' 'covers: [draft_only, no_send, other]' > "$FIX/v13-strange/$A13/guard.yaml"
fails_with "$FIX/v13-strange" "$A13/guard.yaml: covers names other, which is not an invariant of the contract"
make_valid_v13_agent "$FIX/v13-level"; sed -i.bak 's/^enforce_draft_only: .*/enforce_draft_only: instruction/' "$FIX/v13-level/$A13/adapter.yaml"
fails_with "$FIX/v13-level" "$A13/guard.yaml: covers draft_only, but adapter.yaml enforces it by instruction"
make_valid_v13_agent "$FIX/v13-nopol"; rm "$FIX/v13-nopol/$A13/guard.yaml"
fails_with "$FIX/v13-nopol" "$A13: enforce_draft_only is adapter, so guard.yaml must cover it"
make_valid_v12_agent "$FIX/v12-with-pol"; printf '%s\n' 'covers: [draft_only' > "$FIX/v12-with-pol/$A13/guard.yaml"
fails_with "$FIX/v12-with-pol" "$A13/guard.yaml: line 1: unclosed '['"
```

Run it; the 1.3 cases fail.

- [ ] **Step 2: Implement** in `bin/lib/check_manifests.py`:

Add near the top (after imports):

```python
import importlib.util


def load_policy_engine():
    """The reference guard_policy module, or None when it cannot be loaded."""
    path = TEMPLATE_HOOKS / "guard_policy.py"
    try:
        spec = importlib.util.spec_from_file_location("guard_policy_reference", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except (OSError, ImportError, AttributeError, SyntaxError):
        return None
```

(Place `load_policy_engine` after `TEMPLATE_HOOKS` is defined.) Give `check_capability(root, cap, minor)` and `check_adapter(adir, cap, ops, invariants, minor)` a `minor` parameter (pass it from `check_v12`). At the end of `check_adapter`, before `return fails`, add:

```python
    policy_path = adir / "guard.yaml"
    covers = None
    if policy_path.is_file():
        engine = load_policy_engine()
        if engine is None:
            fails.append("validator cannot load its guard-policy engine (_template/hooks/guard_policy.py)")
        else:
            try:
                covers = engine.parse(read_text(policy_path))["covers"]
            except ReadError as err:
                fails.append(f"{prefix}/guard.yaml: {err}")
            except engine.PolicyError as err:
                fails.append(f"{prefix}/guard.yaml: {err}")
    if minor >= 3 and "adapter.yaml" in texts:
        levels = {k[len("enforce_"):]: v for k, v in parse_agent_yaml(texts["adapter.yaml"]).items()
                  if k.startswith("enforce_")}
        if covers is not None:
            for inv in covers:
                if inv not in invariants:
                    fails.append(f"{prefix}/guard.yaml: covers names {inv}, which is not an invariant of the contract")
                elif levels.get(inv) != "adapter":
                    fails.append(f"{prefix}/guard.yaml: covers {inv}, but adapter.yaml enforces it by {levels.get(inv, 'nothing')}")
            for inv, level in sorted(levels.items()):
                if level == "adapter" and inv not in covers:
                    fails.append(f"{prefix}/guard.yaml: covers must list {inv} (enforce_{inv}: adapter)")
        elif not policy_path.is_file():
            for inv, level in sorted(levels.items()):
                if level == "adapter":
                    fails.append(f"{prefix}: enforce_{inv} is adapter, so guard.yaml must cover it")
```

Add `check_v13`:

```python
def check_v13(root, minor):
    """Agent Standard 1.3: the guard-policy engine."""
    return check_reference_script(root, "hooks/guard_policy.py", references_for("hooks/guard_policy.py", minor))
```

and in `check`: `if minor >= 3: fails.extend(check_v13(root, minor))`.

- [ ] **Step 3: Verify** — `tests/test-validate-agent.sh` 0 failed; `tests/run-all.sh` ALL GREEN.

- [ ] **Step 4: Commit**

```bash
git add bin/lib/check_manifests.py tests/test-validate-agent.sh
git commit -m "feat: validator checks guard policies and coverage (Agent Standard 1.3)"
```

---

### Task 5: Template 1.3 and the capability skeleton

**Files:**
- Modify: `_template/agent.yaml` (`standard: "1.3"`), `_template/skills/setup/SKILL.md`, `tests/run-all.sh`
- Create: `_capability-template/adapters/example-provider/guard.yaml`
- Modify: `_capability-template/adapters/example-provider/adapter.yaml` (keep `enforce_example_invariant: instruction`)

- [ ] **Step 1: Failing test** — in `tests/run-all.sh` change the template check to 1.3:

```bash
echo "== template is Agent Standard 1.3"
if ! grep -q '^standard: "1.3"' _template/agent.yaml; then echo "FAIL: _template is not 1.3"; STATUS=1; fi
if ! grep -qF 'guard.yaml' _template/skills/setup/SKILL.md; then echo "FAIL: setup does not mention guard.yaml"; STATUS=1; fi
if ! python3 _template/hooks/guard_policy.py --check _capability-template/adapters/example-provider/guard.yaml; then echo "FAIL: skeleton guard.yaml does not parse"; STATUS=1; fi
```

(keep the `**Tools.**` check). Run: fails.

- [ ] **Step 2: `_capability-template/adapters/example-provider/guard.yaml`**

```yaml
# Guard policy for this adapter (Agent Standard 1.3). Declarative: the
# agent's guard_policy.py enforces it before every call to this provider.
# covers lists the contract invariants it enforces; set each of them to
# `enforce_<id>: adapter` in adapter.yaml. Example below: read tools are
# allowed, deletes are denied, and a status field may only be created as
# "draft". Replace it with your provider's tool names and fields.
covers: [example_invariant]
allow: [whoami, list-*, get-*, search-*, create-thing, update-thing]
deny: ["*delete*"]
create_tools: [create-thing]
update_tools: [update-thing]
values_at: [values]
rules:
  - field: status
    create: [draft]
```

In `adapter.yaml`, change `enforce_example_invariant: instruction` to `enforce_example_invariant: adapter` and remove its `block: delete` line (the policy's `deny` covers it). Check the Task-3 (1.2) skeleton test in `tests/test-validate-agent.sh` still passes (it copies the skeleton into a 1.2 fixture; a `guard.yaml` is parsed there too — it must parse).

- [ ] **Step 3: `_template/agent.yaml`** → `standard: "1.3"`.

- [ ] **Step 4: Setup text** (`_template/skills/setup/SKILL.md`, step 9):
  - In sub-step 1, after "…write `custom-adapters/<capability>/adapter.md` and `adapter.yaml` in the instance…", add: "and, for each invariant the user wants enforced by mechanism, a `guard.yaml` guard policy (an `allow` list of the tools the adapter uses, a `deny` list, and any field rules), then check it with `python3 <package>/hooks/guard_policy.py --check custom-adapters/<capability>/guard.yaml`. A custom adapter never has a `guard.py`."
  - In sub-step 3, add: "If the adapter's `## Probe` says to record field IDs, write them as `field_<name>: <id>` lines."
  - Replace sub-step 7 with: "7. Tell the user, for each capability, whether it is **unattended-safe**: every invariant enforced by `adapter` (listed in the adapter's `guard.yaml` `covers`) or by `host-deny` with its rules written. List each invariant and what enforces it. Scheduled runs may use only unattended-safe capabilities."

- [ ] **Step 5: Verify** — `tests/run-all.sh` ALL GREEN (template validates as 1.3; `_template` has no capabilities).

- [ ] **Step 6: Commit**

```bash
git add _template _capability-template tests/run-all.sh
git commit -m "feat: template follows Agent Standard 1.3; skeleton guard policy"
```

---

### Task 6: Standard text, wizard, docs, builder 1.3.0

**Files:**
- Modify: `STANDARD.md`, `skills/new-agent/SKILL.md`, `docs/writing-an-agent.md`, `README.md`, the three builder manifests (`1.3.0`), `tests/test-builder-manifests.sh` (expects `1.3.0`)

- [ ] **Step 1:** test-builder-manifests expects `1.3.0` (RED), bump manifests (GREEN).
- [ ] **Step 2: `STANDARD.md`:**
  - Title `# Agent Standard 1.3`; Versioning notes 1.3 adds guard policies (additive).
  - New section `## Guard policy (1.3)` before `## Guard hook`: purpose (declarative enforcement of contract invariants; data, so custom adapters may ship one); the example from the spec's "The guard policy format"; the grammar bullets; the keys table; the seven semantics points; "Field identity and bindings" with the `binding_id: required` example. Copy these from the spec verbatim where possible.
  - `## Guard hook`: add that for an adapter with `guard.yaml` the hook runs `hooks/guard_policy.py` with the policy and the instance's `bindings/<capability>.md`, for package and custom adapters alike; python3 or the engine missing blocks.
  - `## Capabilities and adapters`: `adapter.yaml` example unchanged; add one sentence that in 1.3 every `enforce_<id>: adapter` must be listed in the adapter's `guard.yaml` `covers`.
  - `## Setup — tools step`: custom adapters may write `guard.yaml`; probe may record `field_<name>` IDs; unattended-safe report lists each invariant and its enforcer.
  - `## Validation`: add the 1.3 checks (engine file, `guard.yaml` parses, coverage both directions) and the versioned-references rule (an agent's hooks must equal the reference for its own version or a later one; references live in `bin/lib/references/<version>/`).
  - Directory layout: add `hooks/guard_policy.py` (1.3) and `guard.yaml` beside `adapter.yaml`.
  - `## Instances` example: `standard: "1.3"`.
- [ ] **Step 3: Wizard** — the Tools bullet: write `guard.yaml` from the skeleton; every invariant set to `adapter` must be in `covers`; list every tool the adapter uses in `allow`; verify with `python3 _template/hooks/guard_policy.py --check <path>`; step 4 says `standard: "1.3"` and keep `hooks/` exactly as copied (three scripts).
- [ ] **Step 4: `docs/writing-an-agent.md`** Tools section: guard policies replace most `guard.py` use; one short YAML example; "unattended-safe means every invariant is covered".
- [ ] **Step 5: README** — "Agent Standard 1.3"; the feature sentence mentions guard policies.
- [ ] **Step 6: Verify and commit** — `tests/run-all.sh` ALL GREEN; `grep -n 'Standard 1\.2' README.md skills/new-agent/SKILL.md` shows only historical mentions.

```bash
git add STANDARD.md skills/new-agent/SKILL.md docs/writing-an-agent.md README.md .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json tests/test-builder-manifests.sh
git commit -m "docs: Agent Standard 1.3 guard policies; builder 1.3.0"
git push -u origin feat/standard-1.3
```

---

## sales-partner (tasks 7–8) — `/Users/hochoy/Work/Webspenser/sales-partner`, branch `release/1.2.0`

Validate with `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .` (builder on `feat/standard-1.3`).

### Task 7: Attio guard policy replaces `guard.py`; hooks 1.3

**Files:**
- Copy: builder `_template/hooks/guard.sh`, `_template/hooks/guard_policy.py` → `hooks/` (755)
- Create: `capabilities/crm/adapters/attio/guard.yaml`
- Delete: `capabilities/crm/adapters/attio/guard.py`, `tests/test-attio-guard.sh`
- Create: `tests/test-policies.sh` (755)
- Modify: `capabilities/crm/adapters/attio/adapter.yaml`, `capabilities/crm/adapters/attio/adapter.md`, `agent.yaml` (`standard: "1.3"`), `tests/run-all.sh`, `tests/test-content.sh`

- [ ] **Step 1: Branch** — `git -C /Users/hochoy/Work/Webspenser/sales-partner switch -c release/1.2.0`.
- [ ] **Step 2: Failing tests** — `tests/test-policies.sh`:

```bash
#!/usr/bin/env bash
# This agent's guard policies, run through the Agent Standard engine.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
E=hooks/guard_policy.py
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

check() { # check <rc> <label> <policy> <tool_name> <tool_input> [text] [bindings]
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":%s}' "$4" "$5" | python3 "$E" "$3" "${7:--}" "sales-partner guard policy" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && { [ -z "${6:-}" ] || printf '%s\n' "$out" | grep -qF -- "$6"; }; then _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
for p in capabilities/*/adapters/*/guard.yaml; do
  python3 "$E" --check "$p" >/dev/null && _report ok "$p parses" || _report no "$p does not parse"
done

echo "-- Attio"
AT=capabilities/crm/adapters/attio/guard.yaml; P=mcp__claude_ai_Attio__
L='"list":"sales_partner_outreach","parent_object":"companies","parent_record_id":"00000000-0000-0000-0000-000000000001"'
X='"list":"sales_partner_outreach","entry_id":"00000000-0000-0000-0000-000000000002"'
check 0 "create draft"              $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":\"draft\",\"summary\":\"x\"}}"
check 0 "create draft as list"      $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":[\"draft\"]}}"
check 2 "create approved"           $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":\"approved\"}}" "status may only be written as draft on create"
check 2 "create sent via option"    $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":{\"option\":\"sent\"}}}"
check 2 "create voided"             $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":\"voided\"}}"
check 2 "mixed wrapped status"      $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":{\"option\":\"draft\",\"title\":\"approved\"}}}"
check 0 "create lead, dnc false ok" $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"stage\":\"New\",\"do_not_contact\":false}}"
check 0 "update voided"             $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"status\":\"voided\",\"outcome\":\"dup\"}}"
check 2 "update draft"              $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"status\":\"draft\"}}" "status may only be written as voided on update"
check 2 "update approved by record" $AT ${P}update-list-entry-by-record-id "{$L,\"entry_values\":{\"status\":\"Approved\"}}"
check 2 "status by option UUID"     $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"status\":\"49e56c99-597b-40b5-9413-162ce1adadfc\"}}"
check 2 "unknown value shape"       $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"status\":{\"foo\":1}}}" "cannot check this call"
check 2 "dnc cleared"               $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"do_not_contact\":false}}" "do_not_contact may only be written as true"
check 2 "dnc cleared as string"     $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"do_not_contact\":\"false\"}}"
check 0 "dnc set true"              $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"do_not_contact\":true}}"
check 2 "attribute by ID"           $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"925c1cde-cba6-453e-96f9-5bd8f498d8a3\":\"sent\"}}" "addressed by ID"
check 2 "upsert with approved"      $AT ${P}upsert-record '{"object":"people","matching_attribute":"email_addresses","values":{"status":"approved"}}'
check 0 "update person"             $AT ${P}update-record '{"object":"people","record_id":"00000000-0000-0000-0000-000000000003","values":{"sp_role":"influencer"}}'
check 2 "create-record approved"    $AT ${P}create-record '{"object":"companies","values":{"status":"approved"}}'
check 2 "create-list refused"       $AT ${P}create-list '{"name":"x"}' "is denied"
check 2 "update-list refused"       $AT ${P}update-list '{"list":"sales_partner_outreach"}'
check 2 "delete refused"            $AT ${P}delete-comment '{}' "is denied"
check 2 "merge refused"             $AT ${P}merge-records '{}' "is denied"
check 2 "unlisted tool refused"     $AT ${P}create-comment '{}' "is not in the allow list"
check 0 "read tool allowed"         $AT ${P}list-records-in-list '{"list":"sales_partner_outreach"}'
check 0 "note without values"       $AT ${P}create-note '{"title":"x","content":"y"}'
out=$(printf '{not json' | python3 "$E" "$AT" - x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "malformed JSON blocks" || _report no "malformed JSON (rc=$rc)"

finish
```

Also add to `tests/test-content.sh` (Attio block): every `attio:<tool>` named in `capabilities/crm/adapters/attio/adapter.md` must be allowed:

```bash
for t in $(grep -oE 'attio:[a-z-]+' "$SP/capabilities/crm/adapters/attio/adapter.md" | sort -u | cut -d: -f2); do
  out=$(printf '{"tool_name":"mcp__attio__%s","tool_input":{}}' "$t" | python3 "$SP/hooks/guard_policy.py" "$SP/capabilities/crm/adapters/attio/guard.yaml" - x 2>&1)
  printf '%s' "$out" | grep -q 'not in the allow list' && _report no "Attio tool $t not allowed by guard.yaml" || _report ok "Attio tool $t allowed"
done
```

Replace the run-all line for `test-attio-guard.sh` with `echo "== policies"; tests/test-policies.sh || STATUS=1`. Run: fails (no engine, no policy).

- [ ] **Step 3: Implement**
  - Copy the builder's `guard.sh` and `guard_policy.py` into `hooks/`; `chmod 755`.
  - `capabilities/crm/adapters/attio/guard.yaml` — exactly the spec's example (Attio `covers`, `allow`, `deny`, `create_tools`, `update_tools`, `values_at`, `unwrap`, `unknown_writes: update`, `refuse_keys: [uuid]`, the two rules), with a two-line comment header.
  - `adapter.yaml`: remove `block:` and `guard:` lines; invariants stay `adapter`.
  - `git rm capabilities/crm/adapters/attio/guard.py tests/test-attio-guard.sh`.
  - `adapter.md` "Approval invariant under Attio": item 1 becomes "`guard.yaml` in this folder — the agent's guard policy engine enforces it before every Attio call inside an instance: …" (same rules, now including "tools not in its allow list, and any delete or merge tool"); item 2 (block) is folded into item 1.
  - `agent.yaml`: `standard: "1.3"`.
  - `tests/test-content.sh`: replace assertions that mention `guard.py`/`block: delete, merge` with `assert_contains` on `guard.yaml` (`covers: [draft_only, dnc_one_way, no_delete]`) and `[ ! -e .../guard.py ]`.
- [ ] **Step 4: Verify** — `tests/run-all.sh` ALL GREEN; validator OK. Grep: `grep -rn 'guard.py' --include='*.md' . | grep -v -e '^./docs/' -e '^./migrations/'` → no output.
- [ ] **Step 5: Commit** — `git add -A` then `git commit -m "feat: Attio guard policy replaces guard.py (Standard 1.3)"`.

---

### Task 8: Gmail and Airtable guard policies; release 1.2.0

**Files:**
- Create: `capabilities/email_drafts/adapters/gmail/guard.yaml`, `capabilities/crm/adapters/airtable/guard.yaml`, `migrations/1.1.0-1.2.0.md`
- Modify: both adapters' `adapter.yaml` and `adapter.md`, `agent.yaml` (`version: 1.2.0`), three host manifests, `README.md`, `tests/test-policies.sh`, `tests/test-content.sh`, `skills/setup/SKILL.md` (sync with builder template)

- [ ] **Step 1: Failing tests** — append to `tests/test-policies.sh` before `finish`:

```bash
echo "-- Gmail"
GM=capabilities/email_drafts/adapters/gmail/guard.yaml; G=mcp__claude_ai_Gmail__
check 0 "create draft"              $GM ${G}create_draft '{"to":"a@b.c","subject":"s","body":"b"}'
check 0 "search threads"            $GM ${G}search_threads '{"query":"x"}'
check 2 "send refused"              $GM ${G}send_message '{}' "is denied"
check 2 "reply refused"             $GM ${G}reply_to_thread '{}' "is denied"
check 2 "forward refused"           $GM ${G}forward_message '{}' "is denied"
check 2 "trash not allowed"         $GM ${G}trash_thread '{}' "is not in the allow list"
check 2 "new unlisted tool"         $GM ${G}schedule_email '{}' "is not in the allow list"

echo "-- Airtable"
AR=capabilities/crm/adapters/airtable/guard.yaml; A=mcp__claude_ai_Airtable__
printf '%s\n' '# CRM binding — Airtable' 'base_id: appAAAAAAAAAAAAAA' 'field_status: fldSSSSSSSSSSSSSS' 'field_do_not_contact: fldDDDDDDDDDDDDDD' > "$W/b.md"
B='"baseId":"appAAAAAAAAAAAAAA","tableId":"tblTTTTTTTTTTTTTT"'
check 0 "create draft by ID"        $AR ${A}create_records_for_table "{$B,\"records\":[{\"fields\":{\"fldSSSSSSSSSSSSSS\":\"draft\"}}]}" "" "$W/b.md"
check 2 "create approved by ID"     $AR ${A}create_records_for_table "{$B,\"records\":[{\"fields\":{\"fldSSSSSSSSSSSSSS\":\"approved\"}}]}" "Status may only be written as draft on create" "$W/b.md"
check 2 "update sent by name"       $AR ${A}update_records_for_table "{$B,\"records\":[{\"id\":\"recRRRRRRRRRRRRRR\",\"fields\":{\"Status\":\"sent\"}}]}" "" "$W/b.md"
check 0 "update voided by ID"       $AR ${A}update_records_for_table "{$B,\"records\":[{\"id\":\"recRRRRRRRRRRRRRR\",\"fields\":{\"fldSSSSSSSSSSSSSS\":\"voided\"}}]}" "" "$W/b.md"
check 2 "clear DNC by ID"           $AR ${A}update_records_for_table "{$B,\"records\":[{\"id\":\"recRRRRRRRRRRRRRR\",\"fields\":{\"fldDDDDDDDDDDDDDD\":false}}]}" "Do Not Contact may only be written as true" "$W/b.md"
check 2 "write without field IDs"   $AR ${A}create_records_for_table "{$B,\"records\":[{\"fields\":{\"fldXXXXXXXXXXXXXX\":\"x\"}}]}" "has not recorded field_status"
check 2 "delete refused"            $AR ${A}delete_records_for_table "{$B}" "is denied"
check 2 "schema change refused"     $AR ${A}create_field "{$B}" "is not in the allow list"
check 0 "read allowed"              $AR ${A}list_records_for_table "{$B}"
```

In `tests/test-content.sh` add: `assert_contains "$SP/capabilities/crm/adapters/airtable/adapter.yaml" 'enforce_draft_only: adapter'`, same for `enforce_dnc_one_way`; `assert_contains "$SP/capabilities/crm/adapters/airtable/adapter.md" 'field_status'`; `assert_contains "$SP/migrations/1.1.0-1.2.0.md" 'field IDs'`; `assert_contains "$SP/agent.yaml" 'version: 1.2.0'`; and the "every named tool is allowed" loop for Gmail and Airtable, written out in full like Attio's in Task 7 but with `grep -oE 'gmail:[a-z_]+'` over the Gmail `adapter.md` / prefix `mcp__gmail__` / policy `capabilities/email_drafts/adapters/gmail/guard.yaml`, and `grep -oE 'airtable:[a-z_]+'` over the Airtable `adapter.md` / prefix `mcp__airtable__` / policy `capabilities/crm/adapters/airtable/guard.yaml` (these tool names use underscores, not hyphens). Remove the obsolete `version: 1.1.0` assertion. Run: failures.

- [ ] **Step 2: Gmail** — `capabilities/email_drafts/adapters/gmail/guard.yaml`:

```yaml
# Gmail guard policy: drafts and reading only. The guard policy engine
# blocks every tool not listed here, and anything that sends.
covers: [no_send]
allow: [create_draft, list_drafts, get_draft, search_threads, get_thread,
        get_message, list_labels]
deny: ["*send*", "*reply*", "*forward*"]
```

`adapter.yaml`: remove `block:`. `adapter.md`: the paragraph about `block` becomes "`guard.yaml` allows only the draft and read tools this adapter uses and denies anything that sends, replies, or forwards, so `no_send` holds by mechanism — including against tools a Gmail server adds later. If your Gmail server names these tools differently, add its names to `allow`."

- [ ] **Step 3: Airtable** — `capabilities/crm/adapters/airtable/guard.yaml`:

```yaml
# Airtable guard policy. Airtable writes name fields by ID, so the Status
# and Do Not Contact rules need the IDs setup's probe records in
# bindings/crm.md (field_status, field_do_not_contact).
covers: [draft_only, dnc_one_way, no_delete]
allow: [list_bases, search_bases, list_tables_for_base, get_table_schema,
        list_records_for_table, search_records, create_records_for_table,
        update_records_for_table]
deny: ["*delete*"]
create_tools: [create_records_for_table]
update_tools: [update_records_for_table]
values_at: ["records[].fields"]
unknown_writes: block
rules:
  - field: Status
    binding_id: required
    create: [draft]
    update: [voided]
  - field: Do Not Contact
    binding_id: required
    update: [true]
```

The rule field `Do Not Contact` is a plain scalar with spaces, which the grammar allows; confirm with `python3 hooks/guard_policy.py --check capabilities/crm/adapters/airtable/guard.yaml` (exit 0).

`adapter.yaml`: remove `block:`; set `enforce_draft_only: adapter`, `enforce_dnc_one_way: adapter` (keep `enforce_no_delete: adapter`). `adapter.md` `## Probe`: step 2 also records `field_status: <id of Activities.Status>` and `field_do_not_contact: <id of Leads."Do Not Contact">` from `list_tables_for_base`; add a paragraph "Guard policy" explaining the rules and that writes are blocked until the probe has recorded both IDs. Cross-check: every `airtable:` tool named in `adapter.md` is in `allow` (the content test enforces it) — if `adapter.md` names a tool not listed above (for example `get_table_schema` vs. another read tool), add it to `allow` only if it is a read or one of the two record-write tools; never add a delete, schema, or automation tool.

- [ ] **Step 4: Setup sync** — copy the builder template's setup step 9 changes (Task 5) into `skills/setup/SKILL.md`; check `diff <(sed 's/<interview-skill>/interview-business/g' /Users/hochoy/Work/Webspenser/agent-library/_template/skills/setup/SKILL.md) skills/setup/SKILL.md` shows only the context-files line.

- [ ] **Step 5: Release 1.2.0** — `agent.yaml` `version: 1.2.0`; the three host manifests `1.2.0`; README version line and tools text ("guard policies make Attio, Airtable, and Gmail unattended-safe"). `migrations/1.1.0-1.2.0.md`:

```markdown
# 1.1.0 → 1.2.0

sales-partner now follows Agent Standard 1.3: each tool's safety rules
are a declarative guard policy (`guard.yaml`) that the agent's guard
enforces, and Airtable joins Attio and Gmail as unattended-safe.

**Your context files do not change shape.**

- **Airtable users:** re-run setup's tools step (`/sales-partner:setup`,
  then choose the tools step). Its probe records the field IDs of
  Activities `Status` and Leads `Do Not Contact` in `bindings/crm.md`;
  until then the guard blocks Airtable writes.
- **Attio and Gmail users:** nothing to do.
- Set `standard: "1.3"` and `agent_version: 1.2.0` in `instance.yaml`.
- Source mode: `capabilities/crm/adapters/attio/guard.py` is replaced by
  `guard.yaml`, and `hooks/guard_policy.py` is new.
```

- [ ] **Step 6: Verify** — `tests/run-all.sh` ALL GREEN; validator OK; `--require-bump origin/main` passes (`git fetch origin` first).
- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "feat: Gmail and Airtable guard policies; Airtable unattended-safe; release 1.2.0 (Standard 1.3)"
git push -u origin release/1.2.0
```

---

## Task 9: Release and acceptance (controller; the user merges)

- [ ] Open PR `feat/standard-1.3` → `main` (agent-builder; supersedes the spec PR if open). The user merges with a merge commit, then moves `v1`: `! git -C ~/Work/Webspenser/agent-library fetch origin --tags && git -C ~/Work/Webspenser/agent-library tag -f v1 origin/main && git -C ~/Work/Webspenser/agent-library push -f origin v1`.
- [ ] Open PR `release/1.2.0` → `main` (sales-partner); re-run its CI after the tag move; the user merges.
- [ ] Catalog README status: "1.2 — install, run setup, bind Attio or Airtable and Gmail; all three unattended-safe". PR; user merges.
- [ ] Acceptance from the catalog (read-only): install `sales-partner@webspenser` (shows 1.2.0, hooks SessionStart + PreToolUse); in a scratch instance with `bind_crm: attio`, an instructed `update-list-entry-by-id` with `status: approved` on entry `00000000-0000-0000-0000-000000000000` is blocked with `Blocked by sales-partner guard policy (crm/attio): status may only be written as voided on update`; Attio `list-lists` from a plain folder succeeds; uninstall.
- [ ] Clean up merged branches in all three repos.
