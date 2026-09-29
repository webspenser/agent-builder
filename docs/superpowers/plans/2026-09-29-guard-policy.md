# Agent Standard 2.0 (Guard Policies, Clean Standard) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the standard's enforcement mechanisms with declarative guard policies (`guard.yaml`) enforced by one reference engine, and collapse the standard to a single current version (2.0) with no compatibility layer — agent-builder 2.0.0 and sales-partner 2.0.0.

**Architecture:** `hooks/guard_policy.py` (stdlib only, byte-identical in every agent) parses a strict YAML subset and decides one PreToolUse call: deny/allow globs on the tool name, then field rules on attribute maps. `hooks/guard.sh` runs it for every bound adapter that has a `guard.yaml` (package or custom). The validator checks one standard (2.0), imports the engine's parser, and requires `no_send` coverage. Everything the policy replaces — `block`, `guard.py`, `enforce_*` levels, host-deny rules, per-version checks, pre-1.0 support, versioned references — is deleted.

**Tech Stack:** bash (macOS 3.2 compatible), Python 3 standard library, markdown/YAML, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-guard-policy-design.md` (builder repo) — "Agent Standard 2.0 — Guard Policies and a Clean Standard".

## Global Constraints

- No backward compatibility: the validator accepts only `standard: "2.0"`; delete superseded mechanisms instead of keeping them alongside.
- Builder checkout `/Users/hochoy/Work/Webspenser/agent-library`; branch `feat/standard-2.0` from `spec/guard-policy`.
- sales-partner checkout `/Users/hochoy/Work/Webspenser/sales-partner`; branch `release/2.0.0` from `main`.
- Versions: builder `2.0.0`; sales-partner `2.0.0`; standard `"2.0"`.
- `adapter.yaml` keys: exactly `capability`, `provider`, `server_match`.
- Engine: `hooks/guard_policy.py`, mode 755, byte-identical to builder `_template/hooks/guard_policy.py`; invocation `python3 guard_policy.py <guard.yaml> <bindings-file|-> [label]` (hook JSON on stdin) or `--check <guard.yaml>`; exit 0 allow, 2 block; never tracebacks.
- Block message prefix from guard.sh: `Blocked by <agent> guard policy (<capability>/<provider>): `.
- `hooks/hooks.json` unchanged.
- `docs/superpowers/` files are history: never edit old specs/plans.
- Never modify `/Users/hochoy/Work/Webspenser/live-agents`. Never call Attio, Gmail, or Airtable tools except in Task 8's read-only acceptance.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- After editing scripts, confirm `git ls-files -s` shows `100755`.
- The bash-guard hook blocks compound commands resembling exfiltration and anything containing the word "credentials"; use simple separate commands.

## Review Focus

1. **Grammar edge cases** — the parser rejects, never guesses. Pinned in Task 1.
2. **Airtable field keyed by ID** — `fld…` recognized via bindings; missing required ID blocks. Pinned in Tasks 1 and 7.
3. **Default-deny surprises** — every tool an `adapter.md` names is in its `allow`. Pinned in Tasks 6 and 7 content tests.
4. **Nothing left behind** — no `block:`, `guard.py`, `enforce_`, `host-deny`, `permissions.deny`, "pre-1.0", or "1.x" in either repo outside `docs/superpowers/`. Pinned by greps in Tasks 5 and 7.
5. **No path back to allow** — engine or `python3` missing blocks the bound adapter's calls. Pinned in Task 2.

---

## Builder (tasks 1–5)

### Task 1: The guard-policy engine

**Files:**
- Create: `_template/hooks/guard_policy.py` (755), `tests/test-guard-policy.sh` (755)
- Modify: `tests/run-all.sh` — add `echo "== guard policy"; tests/test-guard-policy.sh || STATUS=1` after the `== guard` line

**Interfaces:**
- Produces: `guard_policy.parse(text) -> dict` raising `guard_policy.PolicyError`; the CLI in Global Constraints. Task 3 imports `parse`/`PolicyError`.

- [ ] **Step 1: Branch** — `git -C /Users/hochoy/Work/Webspenser/agent-library switch -c feat/standard-2.0 spec/guard-policy`
- [ ] **Step 2: Failing tests** — `tests/test-guard-policy.sh`:

```bash
#!/usr/bin/env bash
# The Agent Standard guard-policy engine (_template/hooks/guard_policy.py).
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

`chmod 755`; add the run-all line; run it — every case fails (no engine).

- [ ] **Step 3: `_template/hooks/guard_policy.py`**

```python
#!/usr/bin/env python3
"""Agent Standard guard-policy engine — identical in every agent.

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

`chmod 755 _template/hooks/guard_policy.py`.

- [ ] **Step 4:** `tests/test-guard-policy.sh` → `0 failed` (this code was dry-run against these tests while planning: 51/51); `tests/run-all.sh` → ALL GREEN.
- [ ] **Step 5: Commit** — `git add _template/hooks/guard_policy.py tests/test-guard-policy.sh tests/run-all.sh` then `git commit -m "feat: guard-policy engine"`.

---

### Task 2: `guard.sh` enforces guard policies only

**Files:**
- Replace: `_template/hooks/guard.sh` (755), `tests/test-guard.sh` (755)

**Interfaces:**
- Consumes: engine CLI (Task 1).
- Produces: the reference `guard.sh` (Task 6 copies it).

- [ ] **Step 1: Failing tests** — replace `tests/test-guard.sh` entirely with:

```bash
#!/usr/bin/env bash
# Behavior of the Agent Standard guard hook (_template/hooks/guard.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
GUARD="$PWD/_template/hooks/guard.sh"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PKG="$W/pkg"; AD="$PKG/capabilities/crm/adapters/demo"; mkdir -p "$AD" "$PKG/hooks"
cp _template/hooks/guard_policy.py "$PKG/hooks/"
printf '%s\n' 'name: demo-agent' 'version: 1.0.0' 'description: Demo' 'standard: "2.0"' > "$PKG/agent.yaml"
printf '%s\n' 'capability: crm' 'provider: demo' 'server_match: DemoCRM' > "$AD/adapter.yaml"
write_policy() {
  printf '%s\n' 'covers: [draft_only]' 'allow: [list-*, get-*, update-entry]' 'deny: ["*delete*", "*merge*"]' \
    'create_tools: [add-entry]' 'update_tools: [update-entry]' 'values_at: [values]' \
    'rules:' '  - field: status' '    update: [voided]' > "$AD/guard.yaml"
}
write_policy

I="$W/inst"; mkdir -p "$I/sub"
printf '%s\n' 'agent: demo-agent' 'agent_version: 1.0.0' 'mode: plugin' 'bind_crm: demo' > "$I/instance.yaml"

call() { # call <tool_name> [tool_input JSON] — hook input on one line
  local args=${2:-}; [ -n "$args" ] || args='{}'
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$args"
}
run_guard() { # run_guard <project dir> <input> — output in $OUT, exit code in $RC
  OUT=$(printf '%s' "$2" | CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$1" bash "$GUARD" 2>&1); RC=$?
}
expect() { # expect <rc> <label> [text the output must contain]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; }; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}

echo "-- scope"
run_guard "$I" "$(call Bash '{"command":"ls"}')";                expect 0 "non-MCP tool allowed"
run_guard "$W" "$(call mcp__claude_ai_DemoCRM__delete-record)";  expect 0 "no instance: allowed"
run_guard "$I" "$(call mcp__other__delete-record)";              expect 0 "unbound server allowed"
O="$W/other"; mkdir -p "$O"; printf '%s\n' 'agent: someone-else' 'bind_crm: demo' > "$O/instance.yaml"
run_guard "$O" "$(call mcp__democrm__delete-record)";            expect 0 "another agent's instance allowed"

echo "-- policy enforcement"
run_guard "$I" "$(call mcp__claude_ai_DemoCRM__delete-record)"
expect 2 "denied tool blocked" "Blocked by demo-agent guard policy (crm/demo): delete-record is denied"
run_guard "$I" "$(call mcp__democrm__merge-records)";            expect 2 "server match is case-insensitive"
run_guard "$I/sub" "$(call mcp__democrm__merge-records)";        expect 2 "found from a subfolder"
run_guard "$I" "$(call mcp__x__DemoCRM__delete-record)";         expect 2 "server containing __ still matches"
run_guard "$I" "$(call mcp__democrm__delete__record)";           expect 2 "tool containing __ still denied"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 0 "allowed tool passes"
run_guard "$I" "$(call mcp__democrm__drop-table)";               expect 2 "tool outside allow blocked" "is not in the allow list"
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"status":"sent"}}')"; expect 2 "field rule enforced" "status may only be written as voided on update"
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"status":"voided"}}')"; expect 0 "field rule allows voided"

echo "-- tool name input"
run_guard "$I" "$(call mcp__other__x '{"tool_name":"mcp__democrm__delete-record"}')"; expect 2 "two tool names block" "more than one tool"
run_guard "$I" "$(call mcp__other__x '{"note":"say \"tool_name\": \"y\""}')";         expect 0 "escaped tool_name ignored"

echo "-- bindings"
PL="$PKG/capabilities/email/adapters/plain"; mkdir -p "$PL"
printf '%s\n' 'capability: email' 'provider: plain' 'server_match: plainmail' > "$PL/adapter.yaml"
P2="$W/plain"; mkdir -p "$P2"; printf '%s\n' 'agent: demo-agent' 'bind_email: plain' > "$P2/instance.yaml"
run_guard "$P2" "$(call mcp__plainmail__send_message)";          expect 0 "adapter without guard.yaml: instruction-only, allowed"
G2="$W/ghost"; mkdir -p "$G2"; printf '%s\n' 'agent: demo-agent' 'bind_crm: ghost' > "$G2/instance.yaml"
run_guard "$G2" "$(call mcp__democrm__delete-record)";           expect 0 "missing adapter.yaml: allowed with a note" "no adapter.yaml"
R="$W/repeat"; mkdir -p "$R"; printf '%s\n' 'agent: demo-agent' 'bind_crm: ghost' 'bind_crm: demo' > "$R/instance.yaml"
run_guard "$R" "$(call mcp__democrm__delete-record)";            expect 2 "repeated bind_ key applies every adapter"
SP="$W/spaced"; mkdir -p "$SP"; printf '%s\n' 'agent: demo-agent' 'bind_crm : "Demo"  # note' > "$SP/instance.yaml"
run_guard "$SP" "$(call mcp__democrm__delete-record)";           expect 2 "spaced colon, quoted uppercase provider"
H="$W/hostile"; mkdir -p "$H"
printf '%s\n' 'agent: demo-agent' 'bind_crm: ../../x' 'bind_$(touch PWNED): demo' > "$H/instance.yaml"
run_guard "$H" "$(call mcp__democrm__list-records)"
[ "$RC" -eq 2 ] && [ ! -e PWNED ] && [ ! -e "$H/PWNED" ] && printf '%s' "$OUT" | grep -qF "cannot read" \
  && _report ok "unreadable binding blocks, nothing executed" || _report no "hostile bindings (rc=$RC): $OUT"

echo "-- field IDs from bindings"
printf '%s\n' 'covers: [draft_only]' 'create_tools: [add-entry]' 'update_tools: [update-entry]' 'values_at: [values]' \
  'rules:' '  - field: status' '    binding_id: required' '    update: [voided]' > "$AD/guard.yaml"
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"fldS":"sent"}}')"; expect 2 "required binding missing" "has not recorded field_status"
mkdir -p "$I/bindings"; printf '%s\n' 'field_status: fldS' > "$I/bindings/crm.md"
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"fldS":"voided"}}')"; expect 0 "binding ID recognized"
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"fldS":"sent"}}')"; expect 2 "binding ID enforced"
rm -r "$I/bindings"; write_policy

echo "-- custom adapters"
C="$W/custom"; mkdir -p "$C/custom-adapters/crm"
printf '%s\n' 'agent: demo-agent' 'mode: plugin' 'bind_crm: custom' > "$C/instance.yaml"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: democrm' > "$C/custom-adapters/crm/adapter.yaml"
printf '%s\n' 'covers: [draft_only]' 'allow: [list-*]' > "$C/custom-adapters/crm/guard.yaml"
printf '%s\n' 'import pathlib' "pathlib.Path('$W/EVIL-RAN').touch()" > "$C/custom-adapters/crm/guard.py"
run_guard "$C" "$(call mcp__democrm__drop-table)";               expect 2 "custom policy enforced" "is not in the allow list"
run_guard "$C" "$(call mcp__democrm__list-records)"
[ "$RC" -eq 0 ] && [ ! -e "$W/EVIL-RAN" ] && _report ok "no code from the instance runs" || _report no "instance code ran (rc=$RC): $OUT"

echo "-- fail closed"
mv "$PKG/hooks/guard_policy.py" "$W/gp.bak"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "engine missing blocks" "engine is missing"
run_guard "$I" "$(call mcp__other__list-records)";               expect 0 "engine missing: other servers allowed"
mv "$W/gp.bak" "$PKG/hooks/guard_policy.py"
BIN="$W/bin"; mkdir -p "$BIN"
for t in bash cat sed head tr grep sort dirname cut; do ln -s "$(command -v "$t")" "$BIN/$t"; done
OUT=$(printf '%s' "$(call mcp__democrm__list-records)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$I" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 2 "no python3 blocks" "python3 is required"
OUT=$(printf '%s' "$(call mcp__other__list-records)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$I" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 0 "no python3: other servers allowed"
printf '%s\n' 'covers: [draft_only]' 'allow: [list-*' > "$AD/guard.yaml"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "invalid policy blocks" "cannot check this call"
write_policy

echo "-- paths"
S="$W/with space/inst"; mkdir -p "$S"; cp "$I/instance.yaml" "$S/"
run_guard "$S" "$(call mcp__democrm__delete-record)";            expect 2 "path with spaces"
cp "$GUARD" "$PKG/hooks/guard.sh"
printf '%s\n' 'agent: demo-agent' 'mode: source' 'bind_crm: demo' > "$PKG/instance.yaml"
OUT=$(printf '%s' "$(call mcp__democrm__delete-record)" | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$PKG" bash "$PKG/hooks/guard.sh" 2>&1); RC=$?
expect 2 "source mode guards"
rm "$PKG/instance.yaml"

assert_contains _template/hooks/hooks.json '"\"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh\""'
assert_contains _template/hooks/hooks.json '"matcher": "mcp__.*"'
[ -x "$GUARD" ] && _report ok "guard is executable" || _report no "guard not executable"

finish
```

Run it: the policy cases fail against today's guard.sh.

- [ ] **Step 2: Replace `_template/hooks/guard.sh`** entirely with:

```bash
#!/usr/bin/env bash
# Agent Standard guard hook — identical in every agent.
# PreToolUse hook for MCP tools. Inside an instance of this agent, every bound
# adapter whose server_match appears in the tool name gets its guard policy
# (guard.yaml) enforced by hooks/guard_policy.py. Exit 2 blocks the call and
# shows stderr to the model; exit 0 hands it to the normal permission flow.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

yaml_get() { # yaml_get <file> <key>: top-level scalar; quotes and trailing comments removed
  sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
block() { printf 'Blocked by %s guard: %s\n' "$name" "$1" >&2; exit 2; }

name=$(yaml_get "$root/agent.yaml" name)
[ -n "$name" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$dir" in /*) ;; *) dir=$(CDPATH= cd "$dir" 2>/dev/null && pwd) || exit 0 ;; esac
instance=""
while [ -n "$dir" ]; do
  if [ -f "$dir/instance.yaml" ]; then instance="$dir"; break; fi
  parent=$(dirname "$dir")
  [ "$parent" = "$dir" ] && break
  dir=$parent
done
[ -n "$instance" ] || exit 0
[ "$(yaml_get "$instance/instance.yaml" agent)" = "$name" ] || exit 0

# JSON strings hold no raw newlines, so joining lines is safe. An escaped
# \"tool_name\" inside a string value never matches the pattern.
input=$(cat)
names=$(printf '%s' "$input" | tr '\n' ' ' \
  | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"\\]*"' \
  | sed 's/^.*"\([^"]*\)"$/\1/' | sort -u)
[ -n "$names" ] || exit 0
[ "$(printf '%s\n' "$names" | grep -c .)" -eq 1 ] || block "the hook input names more than one tool"
tool=$names
case "$tool" in mcp__?*__?*) ;; *) exit 0 ;; esac
rest_lc=$(lower "${tool#mcp__}")  # server and tool may both contain __: match on the whole

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in bind_*) ;; *) continue ;; esac
  # Each line supplies its own key and value, so a repeated bind_ key still
  # applies every adapter.
  key=$(printf '%s' "${line%%:*}" | sed 's/[[:space:]]*$//')
  case "$line" in *:*) raw=${line#*:} ;; *) raw="" ;; esac
  provider=$(lower "$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
    -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")")
  cap=${key#bind_}
  case "$cap" in ''|*[!a-z0-9_]*) bad=1 ;; *) bad="" ;; esac
  case "$provider" in ''|*[!a-z0-9-]*) bad=1 ;; esac
  if [ -n "$bad" ]; then # binding state unknown: fail closed
    shown=$(printf '%s' "$line" | tr -d '\000-\037' | cut -c1-80)
    block "instance.yaml has a binding line it cannot read ($shown); fix it or re-run setup's tools step"
  fi
  if [ "$provider" = custom ]; then
    adir="$instance/custom-adapters/$cap"
  else
    adir="$root/capabilities/$cap/adapters/$provider"
  fi
  if [ ! -f "$adir/adapter.yaml" ]; then
    printf '%s guard: no adapter.yaml for %s (%s)\n' "$name" "$cap" "$provider" >&2
    continue
  fi
  match=$(lower "$(yaml_get "$adir/adapter.yaml" server_match)")
  [ -n "$match" ] || continue
  case "$rest_lc" in *"$match"*) ;; *) continue ;; esac
  [ -f "$adir/guard.yaml" ] || continue  # no policy: this adapter's invariants are instruction-only
  engine="$root/hooks/guard_policy.py"
  [ -f "$engine" ] || block "the guard policy engine is missing from $name"
  command -v python3 >/dev/null 2>&1 || block "python3 is required to run the $provider guard policy for $cap"
  bfile="$instance/bindings/$cap.md"
  [ -f "$bfile" ] || bfile=-
  printf '%s' "$input" | python3 "$engine" "$adir/guard.yaml" "$bfile" "$name guard policy ($cap/$provider)"; rc=$?
  [ "$rc" -eq 0 ] && continue
  [ "$rc" -eq 2 ] && exit 2
  block "the $provider guard policy for $cap failed (exit $rc)"
done < "$instance/instance.yaml"
exit 0
```

- [ ] **Step 3:** `tests/test-guard.sh` → `0 failed` (dry-run while planning: 35/35); `tests/run-all.sh` → ALL GREEN except validator fixtures that copy the new `guard.sh` into 1.2 agents — Task 3 rewrites those; if `tests/run-all.sh` fails only there, note it in the report and proceed.
- [ ] **Step 4: Commit** — `git add _template/hooks/guard.sh tests/test-guard.sh` then `git commit -m "feat: guard.sh enforces guard policies; block and guard.py removed"`.

---

### Task 3: One validator for Standard 2.0

**Files:**
- Modify: `bin/validate-agent.sh`, `bin/lib/check_manifests.py`, `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `_template/hooks/guard_policy.py` (`parse`, `PolicyError`), the three template hooks.

- [ ] **Step 1: `bin/validate-agent.sh`**
  - `PY_MISSING="python3 is required for Agent Standard checks (set AGENT_VALIDATOR_PYTHON to its path)"`.
  - The comment `# Agent Standard 1.0: agent.yaml and host manifests` becomes `# agent.yaml, host manifests, hooks, capabilities`.
  - Replace the `else … echo "WARN: $DIR has no agent.yaml — checked as pre-1.0"` branch with `else fail "missing agent.yaml"`.

- [ ] **Step 2: `bin/lib/check_manifests.py`**
  - Docstring first line: `"""Agent Standard manifest checks.`
  - Replace `SUPPORTED_STANDARD = …` with `CURRENT_STANDARD = "2.0"`.
  - After `REFERENCE_GUARD`, add `REFERENCE_POLICY = TEMPLATE_HOOKS / "guard_policy.py"` and `ADAPTER_KEYS = ("capability", "provider", "server_match")`. Delete `LEVELS` and `GUARD_FILE`.
  - Add, after the constants:

```python
import importlib.util


def load_policy_engine():
    """The reference guard_policy module, or None when it cannot be loaded."""
    try:
        spec = importlib.util.spec_from_file_location("guard_policy_reference", REFERENCE_POLICY)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except (OSError, ImportError, AttributeError, SyntaxError):
        return None
```

  - Rename `check_v11` → `check_runtime` (docstring "Entry hook, start/setup skills, migrations, catalog, instance marker.") and `check_v12` → `check_tools` (docstring "Guard hook and engine, capability contracts, adapters, guard policies."). In `check_tools`, after the `guard.sh` reference check, add `fails.extend(check_reference_script(root, "hooks/guard_policy.py", REFERENCE_POLICY))`.
  - Replace `check_adapter` entirely:

```python
def check_adapter(adir, cap, ops, invariants):
    """One adapter folder against its capability's contract."""
    fails = []
    prefix = f"capabilities/{cap}/adapters/{adir.name}"
    if not KEBAB.match(adir.name):
        fails.append(f"{prefix}: adapter folder name is not kebab-case")
    texts = {}
    for fname in ("adapter.md", "adapter.yaml"):
        path = adir / fname
        if not path.is_file():
            fails.append(f"missing {prefix}/{fname}")
            continue
        try:
            texts[fname] = read_text(path)
        except ReadError as err:
            fails.append(f"{prefix}/{fname}: {err}")
    if "adapter.yaml" in texts:
        rel = f"{prefix}/adapter.yaml"
        ay = parse_agent_yaml(texts["adapter.yaml"])
        for key in ay:
            if key not in ADAPTER_KEYS:
                fails.append(f"{rel}: unknown key '{key}' (adapter.yaml holds capability, provider, server_match)")
        if ay.get("capability") != cap:
            fails.append(f"{rel}: capability {ay.get('capability')!r} must be {cap!r}")
        if ay.get("provider") != adir.name:
            fails.append(f"{rel}: provider {ay.get('provider')!r} must be {adir.name!r}")
        match = ay.get("server_match", "")
        bare = re.search(r"(?m)^server_match:\s*(#.*)?$", texts["adapter.yaml"])
        if "[" in match or "]" in match or bare:
            fails.append(f"{rel}: server_match must be a plain value, not a YAML list")
        elif not match:
            fails.append(f"{rel}: missing server_match")
    if "adapter.md" in texts:
        rel = f"{prefix}/adapter.md"
        for op in ops:
            if f"`{op}`" not in texts["adapter.md"]:
                fails.append(f"{rel}: does not map operation `{op}`")
        if section(texts["adapter.md"], "Probe") is None:
            fails.append(f"{rel}: needs a ## Probe section")
    policy = adir / "guard.yaml"
    covers = None
    if policy.is_file():
        engine = load_policy_engine()
        if engine is None:
            fails.append("validator cannot load its guard-policy engine (_template/hooks/guard_policy.py)")
        else:
            try:
                covers = engine.parse(read_text(policy))["covers"]
            except ReadError as err:
                fails.append(f"{prefix}/guard.yaml: {err}")
            except engine.PolicyError as err:
                fails.append(f"{prefix}/guard.yaml: {err}")
    for inv in covers or []:
        if inv not in invariants:
            fails.append(f"{prefix}/guard.yaml: covers names {inv}, which is not an invariant of the contract")
    if "no_send" in invariants:
        if not policy.is_file():
            fails.append(f"{prefix}: the contract has no_send, so guard.yaml must cover it")
        elif covers is not None and "no_send" not in covers:
            fails.append(f"{prefix}/guard.yaml: covers must include no_send")
    return fails
```

  - In `check`, replace the standard/minor block with:

```python
    if std and std != CURRENT_STANDARD:
        fails.append(f"agent.yaml: standard '{std}' is not {CURRENT_STANDARD}; update the agent to the current Agent Standard")
    fails.extend(check_runtime(root, meta, name))
    fails.extend(check_tools(root, meta))
```

  - Grep the file afterwards: no `v11`, `v12`, `minor`, `1.x`, `LEVELS`, `enforce_`, `host-deny`, `block`, `guard.py` remain.

- [ ] **Step 3: Consolidate `tests/test-validate-agent.sh`**
  - Replace the helpers `make_valid_agent`, `make_valid_v1_agent`, `make_valid_v11_agent`, `make_valid_v12_agent` with this one helper plus `sync_agents` (put them where `make_valid_agent` is today):

```bash
make_valid_agent() { # make_valid_agent <dir> [name] [version] — a complete Agent Standard 2.0 agent
  local d="$1" name="${2:-demo-agent}" ver="${3:-0.1.0}"
  mkdir -p "$d"/{adapters,skills/start,skills/setup,subagents,templates,samples,context,evals,hooks,migrations,.claude-plugin,.codex-plugin}
  printf '%s\n' \
    '## Identity' '## Mission' '## Inputs' '## Outputs' \
    '## Operating rules' '## Workflow' '## Sub-agents' '## Skills' \
    '## Guardrails / never do' '## Escalate to human when' > "$d/AGENT.md"
  for a in CLAUDE GEMINI AGENTS; do echo "Read \`AGENT.md\` in this directory." > "$d/adapters/$a.md"; done
  echo '#!/usr/bin/env bash' > "$d/install.sh"; chmod +x "$d/install.sh"
  echo '# Cases' > "$d/evals/cases.md"
  printf '%s\n' "name: $name" "version: $ver" "description: A demo agent" 'standard: "2.0"' 'capabilities: crm' > "$d/agent.yaml"
  printf '{"name":"%s","owner":{"name":"Test"},"plugins":[{"name":"%s","source":"./"}]}\n' "$name" "$name" > "$d/.claude-plugin/marketplace.json"
  printf '{"name":"%s","version":"%s","description":"A demo agent","contextFileName":"AGENT.md"}\n' "$name" "$ver" > "$d/gemini-extension.json"
  printf '{"name":"%s","version":"%s","description":"A demo agent","skills":"./skills/"}\n' "$name" "$ver" > "$d/.codex-plugin/plugin.json"
  cp _template/hooks/session-start.sh _template/hooks/guard.sh _template/hooks/guard_policy.py _template/hooks/hooks.json "$d/hooks/"
  chmod 755 "$d/hooks/session-start.sh" "$d/hooks/guard.sh" "$d/hooks/guard_policy.py"
  printf '%s\n' '---' 'name: start' 'description: Use when starting' '---' 'x' > "$d/skills/start/SKILL.md"
  printf '%s\n' '---' 'name: setup' 'description: Use when setting up' '---' 'x' > "$d/skills/setup/SKILL.md"
  local c="$d/capabilities/crm" a="$d/capabilities/crm/adapters/demo"
  mkdir -p "$a"
  printf '%s\n' '# CRM contract' '' '## Operations' '' '| Operation | Arguments |' '|---|---|' \
    '| `create_lead` | `company` |' '| `get_lead` | `lead_id` |' '' '## Invariants' '' \
    '- `draft_only` — only drafts' '- `no_send` — never sends' > "$c/contract.md"
  printf '%s\n' '# Demo adapter' '' '- `create_lead` — demo:create' '- `get_lead` — demo:get' '' '## Probe' '' 'Call demo:whoami.' > "$a/adapter.md"
  printf '%s\n' 'capability: crm' 'provider: demo' 'server_match: demo' > "$a/adapter.yaml"
  printf '%s\n' 'covers: [draft_only, no_send]' 'deny: ["*send*"]' > "$a/guard.yaml"
  sync_agents "$d" "$name" "$ver"
}
sync_agents() { # sync_agents <dir> [name] [version] — rewrite plugin.json's agents list from subagents/
  local d="$1" name="${2:-demo-agent}" ver="${3:-0.1.0}" agents="" f
  for f in "$d"/subagents/*.md; do
    [ -e "$f" ] || continue
    agents="$agents${agents:+,}\"./subagents/$(basename "$f")\""
  done
  printf '{"name":"%s","version":"%s","description":"A demo agent","agents":[%s]}\n' "$name" "$ver" "$agents" > "$d/.claude-plugin/plugin.json"
}
```

  - Every call to a removed helper becomes `make_valid_agent` with the same `<dir> [name] [version]` arguments.
  - Cases that add or change sub-agent files and expect a specific failure: call `sync_agents "$FIX/<case>"` after the change, so the failure is the intended one and not a manifest mismatch. Where a case uses bare `assert_fail`, convert it to `fails_with` with the exact message the validator prints for that problem (run it once to read the message) — a bare `assert_fail` against a fixture with several problems proves nothing.
  - Delete these cases (they test removed behavior): the pre-1.0 WARN case (`pre10`), `v10-still`, `v11-again` and any other "older version still validates" case, and every case about `enforce_`, levels, `host-deny`, `deny`, `guard.py`, or `block` (`v12-missenf`, `v12-extraenf`, `v12-badlevel`, `v12-nodeny`, `v12-deny`, `v12-nosend`, `v12-guardgone`, `v12-guardnx`, `v12-guardpath`, `v12-blocklist`, `v12-blockseq`). Keep every other check's cases. Rename section headers that name versions (`-- Agent Standard 1.0`, `-- Agent Standard 1.1`, `-- Agent Standard 1.2`) to what they test (`-- manifests`, `-- runtime`, `-- capabilities`).
  - Change the `v1-std2` case (standard "2.0" rejected) to reject `standard: "1.2"` with `fails_with … "agent.yaml: standard '1.2' is not 2.0; update the agent to the current Agent Standard"`.
  - Add before `finish`:

```bash
echo "-- Agent Standard 2.0"
A=capabilities/crm/adapters/demo
make_valid_agent "$FIX/cur"; assert_pass $V "$FIX/cur"
make_valid_agent "$FIX/noyaml"; rm "$FIX/noyaml/agent.yaml"
fails_with "$FIX/noyaml" "missing agent.yaml"
make_valid_agent "$FIX/noengine"; rm "$FIX/noengine/hooks/guard_policy.py"
fails_with "$FIX/noengine" "missing hooks/guard_policy.py"
make_valid_agent "$FIX/editengine"; echo "# x" >> "$FIX/editengine/hooks/guard_policy.py"
fails_with "$FIX/editengine" "hooks/guard_policy.py differs from the Agent Standard reference copy (_template/hooks/guard_policy.py in agent-builder)"
make_valid_agent "$FIX/extrakey"; echo 'block: send' >> "$FIX/extrakey/$A/adapter.yaml"
fails_with "$FIX/extrakey" "$A/adapter.yaml: unknown key 'block' (adapter.yaml holds capability, provider, server_match)"
make_valid_agent "$FIX/enforce"; echo 'enforce_draft_only: adapter' >> "$FIX/enforce/$A/adapter.yaml"
fails_with "$FIX/enforce" "$A/adapter.yaml: unknown key 'enforce_draft_only' (adapter.yaml holds capability, provider, server_match)"
make_valid_agent "$FIX/matchlist"; sed -i.bak 's/^server_match: .*/server_match: [demo]/' "$FIX/matchlist/$A/adapter.yaml"
fails_with "$FIX/matchlist" "$A/adapter.yaml: server_match must be a plain value, not a YAML list"
make_valid_agent "$FIX/badpol"; printf '%s\n' 'covers: [draft_only' > "$FIX/badpol/$A/guard.yaml"
fails_with "$FIX/badpol" "$A/guard.yaml: line 1: unclosed '['"
make_valid_agent "$FIX/strange"; printf '%s\n' 'covers: [draft_only, no_send, other]' 'deny: ["*send*"]' > "$FIX/strange/$A/guard.yaml"
fails_with "$FIX/strange" "$A/guard.yaml: covers names other, which is not an invariant of the contract"
make_valid_agent "$FIX/nopolicy"; rm "$FIX/nopolicy/$A/guard.yaml"
fails_with "$FIX/nopolicy" "$A: the contract has no_send, so guard.yaml must cover it"
make_valid_agent "$FIX/nosendcov"; printf '%s\n' 'covers: [draft_only]' > "$FIX/nosendcov/$A/guard.yaml"
fails_with "$FIX/nosendcov" "$A/guard.yaml: covers must include no_send"
make_valid_agent "$FIX/instronly"; sed -i.bak '/no_send/d' "$FIX/instronly/capabilities/crm/contract.md"; rm "$FIX/instronly/$A/guard.yaml"
assert_pass $V "$FIX/instronly"   # an adapter without a policy is allowed: instruction-only
```

- [ ] **Step 4: Verify** — `tests/test-validate-agent.sh` → `0 failed`; `tests/run-all.sh` → ALL GREEN except `== validating _template` (the template is still 1.x until Task 4) — if that is the only failure, note it and proceed.
- [ ] **Step 5: Commit** — `git add bin tests/test-validate-agent.sh` then `git commit -m "feat: one validator for Agent Standard 2.0; guard policies checked"`.

---

### Task 4: Template 2.0, setup, and the capability skeleton

**Files:**
- Modify: `_template/agent.yaml`, `_template/skills/setup/SKILL.md`, `tests/run-all.sh`, `_capability-template/adapters/example-provider/adapter.yaml`
- Create: `_capability-template/adapters/example-provider/guard.yaml`

- [ ] **Step 1: Failing checks** — in `tests/run-all.sh`, the template section becomes:

```bash
echo "== template is Agent Standard 2.0"
if ! grep -q '^standard: "2.0"' _template/agent.yaml; then echo "FAIL: _template is not 2.0"; STATUS=1; fi
if ! grep -qF '**Tools.**' _template/skills/setup/SKILL.md; then echo "FAIL: setup has no tools step"; STATUS=1; fi
if grep -qE 'permissions\.deny|host-deny|enforce_|standard: "1' _template/skills/setup/SKILL.md; then echo "FAIL: setup still describes removed mechanisms"; STATUS=1; fi
if ! python3 _template/hooks/guard_policy.py --check _capability-template/adapters/example-provider/guard.yaml; then echo "FAIL: skeleton guard.yaml does not parse"; STATUS=1; fi
```

Remove the old `TEMPLATE_OUTPUT` pre-1.0 check. Run: FAILs.

- [ ] **Step 2: `_template/agent.yaml`** — `standard: "2.0"`.
- [ ] **Step 3: Skeleton** — `adapter.yaml` becomes exactly:

```yaml
capability: example_capability
provider: example-provider
server_match: example
```

`_capability-template/adapters/example-provider/guard.yaml`:

```yaml
# Guard policy for this adapter. The agent's guard_policy.py enforces it
# before every call to this provider. covers lists the contract
# invariants it enforces; invariants it does not list are enforced only
# by the agent's instructions. Example: read tools allowed, deletes
# denied, and a status field may only be created as "draft". Replace it
# with your provider's tool names and fields.
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

In `_capability-template/contract.md`, the Invariants intro becomes: "An adapter's `guard.yaml` lists in `covers` the invariants it enforces by mechanism; the rest rely on the agent's instructions."

- [ ] **Step 4: Setup (`_template/skills/setup/SKILL.md`)**
  - Step 4 (Marker): `instance.yaml` holds `agent: <name>`, `agent_version: <version>`, `mode: plugin` — no `standard` line.
  - Replace step 9 entirely with:

```markdown
9. **Tools.** Skip if `agent.yaml` lists no `capabilities`. For each
   capability listed there:
   1. List the shipped adapters (`capabilities/<capability>/adapters/`
      in the package) and ask which system the user uses. If none
      fits, offer a custom adapter: interview the user about their
      tool and write, in the instance's
      `custom-adapters/<capability>/`, an `adapter.md` mapping every
      operation in the contract, an `adapter.yaml` (`capability`,
      `provider: custom`, `server_match`), and — for every invariant
      the user wants enforced by mechanism — a `guard.yaml` guard
      policy: an `allow` list of the tools the adapter uses, a `deny`
      list, and any field rules. Check it with
      `python3 <package>/hooks/guard_policy.py --check custom-adapters/<capability>/guard.yaml`.
   2. Find the tools in this session whose name contains the adapter's
      `server_match` after `mcp__`, ignoring case. If there are none,
      explain how to connect that system in the host (a connector or
      an MCP server), and that the user enters any key or login there
      themselves; leave the capability unbound and go on.
   3. Run the adapter's `## Probe` calls. They only read. On failure,
      say what failed and leave the capability unbound. Write what the
      probe found to `bindings/<capability>.md` in the instance,
      including any `field_<name>: <id>` lines the probe records.
   4. If the contract has a `no_send` invariant and the adapter's
      `guard.yaml` does not list it in `covers`, refuse to bind it and
      say why.
   5. Add `bind_<capability>: <provider>` (or `custom`) to
      `instance.yaml`, replacing an earlier line for that capability.
   6. Source mode only: merge into `.claude/settings.json` a
      `PreToolUse` hook with matcher `mcp__.*` and command
      `"$CLAUDE_PROJECT_DIR/hooks/guard.sh"`, unless one is there
      already. Keep every existing key.
   7. Tell the user, for each capability, each contract invariant and
      whether the adapter's guard policy covers it. A capability is
      **unattended-safe** when every invariant is covered. Scheduled
      runs may use only unattended-safe capabilities.
```

  - In step 1, "the tools step (step 9)" stays; check other step references still hold.
- [ ] **Step 5: Verify** — `tests/run-all.sh` ALL GREEN (template validates as 2.0 with no capabilities).
- [ ] **Step 6: Commit** — `git add _template _capability-template tests/run-all.sh` then `git commit -m "feat: template follows Agent Standard 2.0; guard policies in setup and the skeleton"`.

---

### Task 5: `STANDARD.md` 2.0, wizard, docs, builder 2.0.0

**Files:**
- Modify: `STANDARD.md`, `skills/new-agent/SKILL.md`, `docs/writing-an-agent.md`, `README.md`, `validate/action.yml` (only if it names a standard version), the three builder manifests (`2.0.0`), `tests/test-builder-manifests.sh` (expects `2.0.0`)

- [ ] **Step 1:** test-builder-manifests expects `2.0.0` (RED); bump the three manifests (GREEN).
- [ ] **Step 2: `STANDARD.md`** — rewrite as "Agent Standard 2.0", one document for the current standard:
  - `## Versioning` becomes "Development phase": the standard is 2.0; the validator checks only the current version; breaking changes are allowed and every Webspenser agent is updated in the same release; compatibility rules will return when agents have outside users. Keep the release rule (every change bumps the agent's version).
  - Remove every section version tag ("(1.1)", "(1.2)", "(1.1, bindings 1.2)") and every "Later versions add keys; a 1.0 validator ignores…"-style compatibility sentence. The Directory layout comments drop version numbers and add `hooks/guard_policy.py` and `guard.yaml`.
  - `## Capabilities and adapters`: `adapter.yaml` has exactly `capability`, `provider`, `server_match`; delete enforcement levels, `block`, `guard`, `deny`. Invariants: an adapter's `guard.yaml` `covers` lists those enforced by mechanism; the rest are instruction-only; `no_send` must be covered.
  - New `## Guard policy`: purpose; the Attio example; grammar; keys table; semantics 1–8; field identity with `binding_id: required` — copied from the spec's "The guard policy format" section.
  - `## Guard hook`: rewritten to the spec's "Engine and hook" (no `block`, no `guard.py`).
  - `## Bindings`, `## Setup — tools step`: per the spec; no `permissions.deny`; `instance.yaml` has no `standard`.
  - `## Instances` example: `agent`, `agent_version`, `mode`, `bind_crm` — no `standard`.
  - `## Validation`: the spec's "Validator" list; remove "A 1.0 or 1.1 agent is checked exactly as today" and all per-version wording.
  - Afterwards `grep -nE '1\.[0-3]\b|pre-1\.0|host-deny|enforce_|guard\.py|block:' STANDARD.md` prints nothing except semver examples like `version: 1.3.0` for an agent's own version.
- [ ] **Step 3: Wizard** — step 4: `standard: "2.0"`; keep `hooks/` exactly as copied (three scripts). Tools bullet: an adapter pack is `adapter.md` + `adapter.yaml` (three keys) + `guard.yaml` from the skeleton; list every tool the adapter uses in `allow`; put each invariant it enforces in `covers`; a `no_send` invariant must be covered (usually `deny: ["*send*", "*reply*", "*forward*"]` plus an `allow` list); verify with `python3 _template/hooks/guard_policy.py --check <path>`. Remove every mention of `enforce_`, levels, `block`, `deny` suffixes, `host-deny`.
- [ ] **Step 4: `docs/writing-an-agent.md`** Tools section rewritten to guard policies (one short YAML example; "unattended-safe means every invariant is covered"). **README** — "Agent Standard 2.0"; feature sentence mentions guard policies.
- [ ] **Step 5: Leftover grep** — `grep -rnE 'host-deny|enforce_|guard\.py|pre-1\.0|Standard 1\.[0-3]|block:' --include='*.md' --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' . | grep -v -e '^./docs/superpowers/' -e '^./tests/'` prints nothing (fix any hit; `tests/` is excluded because negative test cases deliberately contain the removed keys).
- [ ] **Step 6: Verify, commit, push** — `tests/run-all.sh` ALL GREEN.

```bash
git add -A
git commit -m "docs: Agent Standard 2.0; builder 2.0.0"
git push -u origin feat/standard-2.0
```

---

## sales-partner (tasks 6–7) — `/Users/hochoy/Work/Webspenser/sales-partner`, branch `release/2.0.0`

Validate with `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .` (builder on `feat/standard-2.0`).

### Task 6: Adopt 2.0 — hooks, adapter files, Attio and Gmail policies

**Files:**
- Copy: builder `_template/hooks/guard.sh`, `_template/hooks/guard_policy.py` → `hooks/` (755)
- Create: `capabilities/crm/adapters/attio/guard.yaml`, `capabilities/email_drafts/adapters/gmail/guard.yaml`, `tests/test-policies.sh` (755)
- Delete: `capabilities/crm/adapters/attio/guard.py`, `tests/test-attio-guard.sh`
- Modify: all three `adapter.yaml` (three keys only), Attio and Gmail `adapter.md`, `agent.yaml` (`standard: "2.0"`), `tests/run-all.sh`, `tests/test-content.sh`

- [ ] **Step 1: Branch** — `git -C /Users/hochoy/Work/Webspenser/sales-partner switch -c release/2.0.0`
- [ ] **Step 2: Failing tests** — `tests/test-policies.sh` (Attio and Gmail now; Task 7 appends Airtable before `finish`):

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

echo "-- Gmail"
GM=capabilities/email_drafts/adapters/gmail/guard.yaml; G=mcp__claude_ai_Gmail__
check 0 "create draft"              $GM ${G}create_draft '{"to":"a@b.c","subject":"s","body":"b"}'
check 0 "search threads"            $GM ${G}search_threads '{"query":"x"}'
check 2 "send refused"              $GM ${G}send_message '{}' "is denied"
check 2 "reply refused"             $GM ${G}reply_to_thread '{}' "is denied"
check 2 "forward refused"           $GM ${G}forward_message '{}' "is denied"
check 2 "trash not allowed"         $GM ${G}trash_thread '{}' "is not in the allow list"
check 2 "new unlisted tool"         $GM ${G}schedule_email '{}' "is not in the allow list"


finish
```

In `tests/run-all.sh`, replace the attio-guard line with `echo "== policies"; tests/test-policies.sh || STATUS=1`. In `tests/test-content.sh`, add for Attio and Gmail — every tool named in `adapter.md` is allowed by the policy:

```bash
allowed_by() { # allowed_by <policy> <prefix> <tool>
  printf '{"tool_name":"%s%s","tool_input":{}}' "$2" "$3" | python3 "$SP/hooks/guard_policy.py" "$1" - x 2>&1 | grep -q 'not in the allow list' && return 1 || return 0
}
for t in $(grep -oE 'attio:[a-z-]+' "$SP/capabilities/crm/adapters/attio/adapter.md" | sort -u | cut -d: -f2); do
  allowed_by "$SP/capabilities/crm/adapters/attio/guard.yaml" mcp__attio__ "$t" && _report ok "Attio $t allowed" || _report no "Attio $t not in guard.yaml allow"
done
for t in $(grep -oE 'gmail:[a-z_]+' "$SP/capabilities/email_drafts/adapters/gmail/adapter.md" | sort -u | cut -d: -f2); do
  allowed_by "$SP/capabilities/email_drafts/adapters/gmail/guard.yaml" mcp__gmail__ "$t" && _report ok "Gmail $t allowed" || _report no "Gmail $t not in guard.yaml allow"
done
```

Also in `tests/test-content.sh`: replace assertions about `block:`, `guard: guard.py`, `enforce_…` lines with: each `adapter.yaml` has exactly three lines of keys (`capability`, `provider`, `server_match`); `[ ! -e "$SP/capabilities/crm/adapters/attio/guard.py" ]`; `assert_contains` the two new `guard.yaml` `covers` lines. Run: failures.

- [ ] **Step 3: Implement**
  - Copy the builder's `guard.sh` and `guard_policy.py` into `hooks/`; `chmod 755`.
  - `capabilities/crm/adapters/attio/guard.yaml` — exactly the spec's Attio example, with a one-line comment header.
  - `capabilities/email_drafts/adapters/gmail/guard.yaml`:

```yaml
# Gmail guard policy: drafts and reading only. The guard policy engine
# blocks every tool not listed here, and anything that sends.
covers: [no_send]
allow: [create_draft, list_drafts, get_draft, search_threads, get_thread,
        get_message, list_labels]
deny: ["*send*", "*reply*", "*forward*"]
```

  - All three `adapter.yaml` reduced to `capability`, `provider`, `server_match`.
  - `git rm capabilities/crm/adapters/attio/guard.py tests/test-attio-guard.sh`.
  - Attio `adapter.md` "Approval invariant under Attio": one mechanism — "`guard.yaml` in this folder, enforced by the agent's guard policy engine before every Attio call inside an instance: …" (allow list, denies, status rules, do-not-contact rule, attribute IDs refused); drop the separate `block` item.
  - Gmail `adapter.md`: the paragraph about `block` becomes the `guard.yaml` explanation (allow list of the draft and read tools; send/reply/forward denied; unlisted tools blocked; "if your Gmail server names these tools differently, add its names to `allow`").
  - `agent.yaml`: `standard: "2.0"`.
- [ ] **Step 4: Verify** — `tests/run-all.sh` ALL GREEN; validator OK (Airtable has no policy yet: allowed, instruction-only).
- [ ] **Step 5: Commit** — `git add -A` then `git commit -m "feat: Agent Standard 2.0 — guard policies for Attio and Gmail"`.

---

### Task 7: Airtable policy, cleanup, release 2.0.0

**Files:**
- Create: `capabilities/crm/adapters/airtable/guard.yaml`
- Delete: every file in `migrations/` except a new `migrations/.gitkeep`
- Modify: Airtable `adapter.md`, `AGENT.md`, `README.md`, `skills/setup/SKILL.md`, any skill/sub-agent/context file mentioning removed mechanisms, `agent.yaml` (`version: 2.0.0`), three host manifests, `tests/test-policies.sh`, `tests/test-content.sh`

- [ ] **Step 1: Failing tests** — append to `tests/test-policies.sh` before `finish`:

```bash
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

In `tests/test-content.sh`: the Airtable "every named tool allowed" loop (`grep -oE 'airtable:[a-z_]+'`, prefix `mcp__airtable__`, policy `capabilities/crm/adapters/airtable/guard.yaml`); `assert_contains "$SP/capabilities/crm/adapters/airtable/adapter.md" 'field_status'`; `assert_contains "$SP/agent.yaml" 'version: 2.0.0'`; remove assertions about old migration notes and the old version; add `[ -f "$SP/migrations/.gitkeep" ] && [ "$(ls "$SP/migrations" | wc -l | tr -d ' ')" = 0 ]` style check that `migrations/` holds only `.gitkeep` (use `ls -A` and expect exactly `.gitkeep`). Run: failures.

- [ ] **Step 2: Airtable** — `capabilities/crm/adapters/airtable/guard.yaml`:

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

Confirm `python3 hooks/guard_policy.py --check capabilities/crm/adapters/airtable/guard.yaml` exits 0. In Airtable `adapter.md` `## Probe`, step 2 also records `field_status: <field ID of Activities.Status>` and `field_do_not_contact: <field ID of Leads."Do Not Contact">` from `list_tables_for_base`; add a "Guard policy" paragraph: rules and "writes are blocked until the probe has recorded both IDs". Every `airtable:` tool the adapter names must be in `allow` (content test); add only read tools or the two record-write tools — never delete, schema, or automation tools.

- [ ] **Step 3: Cleanup of removed mechanisms**
  - `git rm` every file in `migrations/`; create `migrations/.gitkeep`.
  - `grep -rnE 'host-deny|enforce_|guard\.py|block:|permissions\.deny|Standard 1\.[0-3]|migrations/[0-9]' --include='*.md' . | grep -v -e '^./docs/' -e '^./tests/'` — rewrite each hit: enforcement is "the adapter's guard policy (`guard.yaml`) covers it" or "instruction-only"; unattended-safe means every invariant covered; no deny rules; no references to deleted migration notes. In `AGENT.md` keep the "Where these files live" paragraph accurate (mention `guard.yaml` only if it already lists adapter files).
  - `skills/setup/SKILL.md`: copy the builder template's step 4 and step 9 text; `diff <(sed 's/<interview-skill>/interview-business/g' /Users/hochoy/Work/Webspenser/agent-library/_template/skills/setup/SKILL.md) skills/setup/SKILL.md` shows only the context-files line.
- [ ] **Step 4: Release 2.0.0** — `agent.yaml` `version: 2.0.0`; three host manifests `2.0.0`; README version and tools text ("each tool's guard policy makes Attio, Airtable, and Gmail unattended-safe").
- [ ] **Step 5: Verify** — `tests/run-all.sh` ALL GREEN; validator OK; `git fetch origin` then validator `--require-bump origin/main` passes; the Step 3 grep prints nothing.
- [ ] **Step 6: Commit and push**

```bash
git add -A
git commit -m "feat: Airtable guard policy; remove superseded mechanisms; release 2.0.0 (Agent Standard 2.0)"
git push -u origin release/2.0.0
```

---

## Task 8: Release and acceptance (controller; the user merges)

- [ ] Open PR `feat/standard-2.0` → `main` (agent-builder; it carries the spec and plan commits). The user merges with a merge commit, then moves `v1`: `! git -C ~/Work/Webspenser/agent-library fetch origin --tags && git -C ~/Work/Webspenser/agent-library tag -f v1 origin/main && git -C ~/Work/Webspenser/agent-library push -f origin v1`.
- [ ] Open PR `release/2.0.0` → `main` (sales-partner); re-run CI after the tag move; the user merges.
- [ ] Catalog README: sales-partner status "2.0 — install, run setup, bind Attio or Airtable and Gmail; all three unattended-safe"; "Adding a plugin" mentions Agent Standard 2.0 if it names a version. PR; the user merges.
- [ ] Acceptance from the catalog (read-only): install `sales-partner@webspenser` (2.0.0; hooks SessionStart + PreToolUse); in a scratch instance with `bind_crm: attio` (no `standard` line), an instructed `update-list-entry-by-id` with `status: approved` on entry `00000000-0000-0000-0000-000000000000` is blocked with `Blocked by sales-partner guard policy (crm/attio): status may only be written as voided on update`; an Attio tool outside `allow` (e.g. `create-comment`) is blocked; Attio `list-lists` from a plain folder succeeds; uninstall.
- [ ] Clean up merged branches in all three repos.
