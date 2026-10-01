# Agent Standard 5.0 Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Agent Standard 5.0: an agent-wide deny-only guard policy, `forbid: update`, and `bound_keys_only` (Airtable known field IDs), then move sales-partner to 5.0.0.

**Architecture:** All enforcement lives in the one reference engine `_template/hooks/guard_policy.py` (byte-copied into every agent). `guard.sh` gains one step that runs the engine in a new `--agent` mode on the package-root `guard.yaml` before the per-binding loop. The validator and the schedule gate learn that a `no_send` contract requires the agent policy. Sales-partner copies the new hooks and updates its policies and usage docs.

**Tech Stack:** Python 3 (stdlib only), POSIX bash, plain-bash test harness (`tests/lib.sh`, `_report`).

**Spec:** `docs/superpowers/specs/2026-10-01-standard-5-guard-design.md`

## Global Constraints

- No backward compatibility: no migration notes, no "old name" messages, no detection of old keys. `binding_id` becomes an unknown key like any typo.
- Standard string is `"5.0"`; builder and sales-partner versions `5.0.0`. No git tags; agents' CI stays on `webspenser/agent-builder/validate@main`.
- The engine fails closed: any exception blocks, never prints a traceback.
- The guard never waits on the network or a prompt.
- Hooks in an agent are byte-identical to `_template/hooks/` (validator enforces).
- Docs that describe a changed part (`STANDARD.md`, `docs/how-it-works.md`, `docs/writing-an-agent.md`) change in the same PR.
- Repos: builder at `~/Work/Webspenser/agent-builder` (branch `feat/standard-5`, already holds the spec commit); sales-partner at `~/Work/Webspenser/sales-partner` (new branch `feat/standard-5`).

## Review Focus

1. **Agent deny pattern hitting a read tool** — e.g. `*reply*` vs Attio `list-comment-replies`, `*publish*` vs Beehiiv `list_publications`. Expected: reads pass. Pinned in Task 7 Step 2.
2. **Agent policy on a call that a bound tool would also judge** — both run; either can block. Expected: a bound Gmail `send_message` is blocked by the agent policy first, and a bound CRM `list-records` passes both. Pinned in Task 4.
3. **Repeated `field_` keys with the same name in two tables** — both IDs must count as recorded and both must be ruled. Pinned in Task 2.
4. **`bound_keys_only` with a write map whose key differs only in case from a recorded ID** — allowed (spec: ignoring case). Pinned in Task 2.
5. **Agent `guard.yaml` present but unreadable (directory or dangling symlink)** — blocks every MCP call in the instance, no traceback. Pinned in Task 4.

---

## Part A — agent-builder (`~/Work/Webspenser/agent-builder`, branch `feat/standard-5`)

### Task 1: Engine — `forbid: update`, drop `binding_id`

**Files:**
- Modify: `_template/hooks/guard_policy.py` (constants at top, `_validate`, `problems`)
- Test: `tests/test-guard-policy.sh` (sections `-- field identity`, `-- forbid`)

**Interfaces:**
- Produces: rule key set `RULE_KEYS = ("field", "forbid", "create", "update", "any")`; `forbid` values `"true"` and `"update"`; messages `<field> may not be written` and `<field> may not be changed after create`.

- [ ] **Step 1: Write the failing tests.** In `tests/test-guard-policy.sh`, in `-- forbid` (after line 217, before the `binding_id` lines), add:

```bash
F '    forbid: update';                 parses 0 "forbid: update parses"
F '    forbid: update' '    create: [x]'; parses 1 "forbid: update combined with create fails"
F '    forbid: update'
run 0 "forbid: update allows the field on create" mcp__a__c '{"v":{"hs_pipeline_stage":"done","hs_task_status":"NOT_STARTED"}}'
run 2 "forbid: update blocks the field on update" mcp__a__u '{"v":{"hs_pipeline_stage":"done"}}' "hs_pipeline_stage may not be changed after create"
run 2 "forbid: update blocks on an unknown write checked as update" mcp__a__other '{"v":{"hs_pipeline_stage":"done"}}' "may not be changed after create"
```

Before writing, read lines 195–221 to see how `F` builds the policy (writes entries `c` = create, `u` = update at path `v`, plus an `hs_task_status` rule, `unknown_writes` default `update`). If `F` sets `unknown_writes: block`, change the last case's expectation to `"not a known create or update tool"` and the label accordingly.

Replace the two `binding_id` lines at the end of `-- forbid` (lines 218–221) with:

```bash
F '    forbid: true' '    binding_id: required'; parses 1 "binding_id is an unknown rule key"
```

In `-- field identity` (lines 115–137): delete every `binding_id: required` from the policy line; delete the cases `required ID missing` and `bullet form ignored: not recorded` (Task 2 replaces them).

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-guard-policy.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: FAIL on `forbid: update parses`, `forbid: update blocks…`, `binding_id is an unknown rule key`.

- [ ] **Step 3: Implement.** In `guard_policy.py`:

```python
RULE_KEYS = ("field", "forbid", "create", "update", "any")
```

In `_validate`, delete the `binding_id` check and change the forbid block to:

```python
            if "forbid" in rule:
                if rule["forbid"] not in ("true", "update"):
                    raise PolicyError(f"rule for {rule['field']}: forbid may only be true or update")
                if lists:
                    raise PolicyError(f"rule for {rule['field']}: forbid cannot be combined with create, update, or any")
                continue
```

In `problems`, delete the `binding_id` branch in the `for rule in rules:` id-building loop (Task 2 rewrites this loop; for now keep `bound = bindings.get(f"field_{field}")` and `ids[field] = {field} | ({_norm(bound)} if bound else set())`). Replace the forbid branch in the per-map loop with:

```python
            forbid = rule.get("forbid")
            if forbid:
                if forbid == "true" or kind == "update":
                    if any(_norm(key) in ids[field] for key in amap):
                        found.append(f"{rule['field']} may not be written" if forbid == "true"
                                     else f"{rule['field']} may not be changed after create")
                continue
```

Update the module docstring line about the format if it mentions `binding_id` (it does not today; leave it).

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-guard-policy.sh 2>&1 | tail -1`
Expected: `-- N passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard_policy.py tests/test-guard-policy.sh
git commit -m "feat: forbid: update blocks a field only on update; binding_id removed"
```

### Task 2: Engine — `bound_keys_only` and repeated `field_` bindings

**Files:**
- Modify: `_template/hooks/guard_policy.py` (`KEYS`, `_validate`, `read_bindings`, `problems`)
- Test: `tests/test-guard-policy.sh` (`-- field identity`), `tests/test-guard.sh` (`-- field IDs from bindings`)

**Interfaces:**
- Consumes: Task 1's rule shape.
- Produces: `read_bindings(path) -> dict` where every `field_*` key maps to a `set` of raw IDs and other keys map to the last string value; top-level key `bound_keys_only` (only value `"true"`, requires `writes`); messages `<key> is not a recorded field ID; re-run the probe (setup's tools step)` and `the probe has not recorded any field IDs in bindings; re-run setup's tools step`.

- [ ] **Step 1: Write the failing tests.** Append to `-- field identity` in `tests/test-guard-policy.sh`:

```bash
echo "-- bound_keys_only"
policy 'covers: [x]' 'bound_keys_only: true';         parses 1 "bound_keys_only needs writes"
policy 'covers: [x]' 'bound_keys_only: yes' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]'; parses 1 "bound_keys_only only takes true"
B() { policy 'covers: [draft_only]' 'bound_keys_only: true' 'writes:' '  - kind: create' '    tools: [create_records]' '    at: ["records[].fields"]' \
  '  - kind: update' '    tools: [update_records]' '    at: ["records[].fields"]' \
  'rules:' '  - field: Status' '    create: [draft]' '    update: [voided]'; }
B; parses 0 "bound_keys_only parses"
bind 'base_id: appXXXXXXXXXXXXXX' 'field_status: fldAAAAAAAAAAAAAA' 'field_lead: fldLLLLLLLLLLLLL1' 'field_lead: fldLLLLLLLLLLLLL2' 'field_name: fldNNNNNNNNNNNNNN'
run 0 "recorded IDs pass"            mcp__airtable__create_records '{"records":[{"fields":{"fldAAAAAAAAAAAAAA":"draft","fldNNNNNNNNNNNNNN":"Acme"}}]}' "" "$W/bindings.md"
run 0 "both IDs of a repeated name count" mcp__airtable__create_records '{"records":[{"fields":{"fldLLLLLLLLLLLLL1":["recA"]}},{"fields":{"fldLLLLLLLLLLLLL2":["recB"]}}]}' "" "$W/bindings.md"
run 0 "recorded ID matched ignoring case" mcp__airtable__create_records '{"records":[{"fields":{"FLDNNNNNNNNNNNNNN":"Acme"}}]}' "" "$W/bindings.md"
run 2 "unrecorded fld key blocked"   mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldZZZZZZZZZZZZZZ":"approved"}}]}' "fldZZZZZZZZZZZZZZ is not a recorded field ID" "$W/bindings.md"
run 2 "field name key blocked too"   mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"Status":"voided"}}]}' "Status is not a recorded field ID" "$W/bindings.md"
run 2 "rule still applies to a recorded ID" mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"approved"}}]}' "Status may only be written as voided" "$W/bindings.md"
bind 'field_status: fldS1SSSSSSSSSSSS' 'field_status: fldS2SSSSSSSSSSSS'
run 2 "a rule covers every ID recorded under its name" mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldS2SSSSSSSSSSSS":"sent"}}]}' "Status may only be written as voided" "$W/bindings.md"
bind 'base_id: appXXXXXXXXXXXXXX'
run 2 "no field_ lines: every write blocked" mcp__airtable__create_records '{"records":[{"fields":{"fldNNNNNNNNNNNNNN":"Acme"}}]}' "has not recorded any field IDs" "$W/bindings.md"
run 0 "no field_ lines: reads pass"  mcp__airtable__list_records '{}' "" "$W/bindings.md"
bind '- field_status: fldAAAAAAAAAAAAAA'
run 2 "bulleted line is not a binding" mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"voided"}}]}' "has not recorded any field IDs" "$W/bindings.md"
run 2 "no bindings file: writes blocked" mcp__airtable__create_records '{"records":[{"fields":{"fldNNNNNNNNNNNNNN":"Acme"}}]}' "has not recorded any field IDs"
```

(`bind` is defined earlier in that section; the `run` helper's 6th arg is the bindings file, default `-`.)

In `tests/test-guard.sh` `-- field IDs from bindings` (lines 99–107): replace the policy's `'    binding_id: required'` with nothing and add `'bound_keys_only: true'` after `covers`; change the first case to:

```bash
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"fldS":"sent"}}')"; expect 2 "no field IDs recorded" "has not recorded any field IDs"
```

and add after `binding ID enforced`:

```bash
run_guard "$I" "$(call mcp__democrm__update-entry '{"values":{"fldT":"x"}}')"; expect 2 "unrecorded field ID blocked" "fldT is not a recorded field ID"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-guard-policy.sh 2>&1 | grep -cE '^  FAIL'; bash tests/test-guard.sh 2>&1 | grep -E 'FAIL'`
Expected: failures on the new cases (`bound_keys_only` is an unknown key today).

- [ ] **Step 3: Implement.** In `guard_policy.py`:

```python
KEYS = ("covers", "allow", "deny", "writes", "unwrap", "unknown_writes", "refuse_keys", "bound_keys_only", "rules")
```

In `_validate`, after the `unknown_writes` check:

```python
    if policy.get("bound_keys_only", "true") != "true":
        raise PolicyError("bound_keys_only may only be true")
```

and change the writes-required check to:

```python
    if ("rules" in policy or "refuse_keys" in policy or "bound_keys_only" in policy) and not policy.get("writes"):
        raise PolicyError("writes is required when rules, refuse_keys or bound_keys_only are present")
```

`read_bindings` — `field_` keys accumulate:

```python
            if key.startswith("field_"):
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "`'\"":
                    value = value[1:-1]
                if not BARE_ID.match(value):
                    shown = "".join(c for c in m.group(2) if c.isprintable())[:60]
                    raise PolicyError(f"bindings: {key} must be a bare ID, got {shown}")
                data.setdefault(key, set()).add(value)
                continue
            data[key] = value
```

In `problems`, change the early exit to:

```python
    keyed = policy.get("bound_keys_only") == "true"
    if not rules and not refuse and not keyed:
        return []
```

Replace the id-building loop with:

```python
    found = []
    recorded = {_norm(i) for k, v in bindings.items() if k.startswith("field_") for i in v}
    ids = {}
    for rule in rules:
        field = _norm(rule["field"])
        ids[field] = {field} | {_norm(i) for i in bindings.get(f"field_{field}", ())}
```

In the per-map loop, right after the invisible-character and refuse checks for each key, add the known-ID check; and before the loop, the no-IDs check:

```python
    if keyed and not recorded and any(amap for _, amap in tagged):
        found.append("the probe has not recorded any field IDs in bindings; re-run setup's tools step")
        keyed = False  # one message is enough
    for kind, amap in tagged:
        for key in amap:
            if any(unicodedata.category(ch) == "Cf" for ch in str(key)):
                raise PolicyError("attribute key contains invisible characters")
            if any(p.match(str(key)) for p in refuse):
                found.append(f"attribute {key} is addressed by ID; use its name")
            if keyed and _norm(key) not in recorded:
                found.append(f"{key} is not a recorded field ID; re-run the probe (setup's tools step)")
```

(The rest of the loop — rules — is unchanged from Task 1.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-guard-policy.sh 2>&1 | tail -1; bash tests/test-guard.sh 2>&1 | tail -1`
Expected: both `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard_policy.py tests/test-guard-policy.sh tests/test-guard.sh
git commit -m "feat: bound_keys_only — writes may use only field IDs the probe recorded"
```

### Task 3: Engine — `--agent` mode

**Files:**
- Modify: `_template/hooks/guard_policy.py` (docstring, new `AGENT_KEYS`, split `parse`, new `parse_agent`, `agent_problems`, `main`)
- Test: `tests/test-guard-policy.sh` (new section `-- agent policy`)

**Interfaces:**
- Produces: `parse_agent(text) -> dict` (keys `deny` list, optional `covers` list; raises `PolicyError`); `agent_problems(policy, event) -> list[str]`; CLI `guard_policy.py --agent <guard.yaml> [label]` (stdin hook input; exit 0/2) and `guard_policy.py --check --agent <guard.yaml>` (exit 0/1, `FAIL: …`).

- [ ] **Step 1: Write the failing tests.** Append before `-- fail closed` in `tests/test-guard-policy.sh`:

```bash
echo "-- agent policy"
aparses() { # aparses <0|1> <label>
  local out rc; out=$(python3 "$E" --check --agent "$W/guard.yaml" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && ! printf '%s' "$out" | grep -q Traceback; then _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
arun() { # arun <rc> <label> <tool_name> [text]
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":{}}' "$3" | python3 "$E" --agent "$W/guard.yaml" "demo agent guard policy" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && { [ -z "${4:-}" ] || printf '%s\n' "$out" | grep -qF -- "$4"; } && ! printf '%s' "$out" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
policy 'covers: [no_send]' 'deny: ["*send*", "*reply*"]'; aparses 0 "agent policy parses"
policy 'deny: ["*send*"]';                         aparses 0 "covers is optional"
policy 'covers: [no_send]';                        aparses 1 "deny is required"
policy 'deny: []';                                 aparses 1 "deny may not be empty"
policy 'deny: ["*send*"]' 'allow: [x]';            aparses 1 "allow is not an agent policy key"
policy 'deny: ["*send*"]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]'; aparses 1 "writes is not an agent policy key"
policy 'covers: [Bad]' 'deny: ["*send*"]';         aparses 1 "covers ids are snake_case"
policy 'covers: [no_send]' 'deny: ["*send*", "*reply*"]'
arun 2 "deny matches on any server" mcp__claude_ai_Slack__slack_send_message "Blocked by demo agent guard policy: slack_send_message is denied (*send*)"
arun 2 "deny matches a suffix after __ in the server" mcp__x__gmail__reply "denied (*reply*)"
arun 0 "replies is not reply" mcp__claude_ai_Attio__list-comment-replies
arun 0 "other tools pass" mcp__claude_ai_Gmail__create_draft
arun 2 "non-MCP name fails closed" Bash "cannot check this call"
out=$(printf '{not json' | python3 "$E" --agent "$W/guard.yaml" x 2>&1); rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && _report ok "agent: bad JSON blocks" || _report no "agent bad JSON (rc=$rc): $out"
out=$(printf '{}' | python3 "$E" --agent "$W/missing.yaml" x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "agent: missing policy blocks" || _report no "agent missing (rc=$rc): $out"
policy 'covers: [x]' 'allow: [a]' 'deny: ["*send*"]'
out=$(python3 "$E" --check "$W/guard.yaml" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _report ok "plain --check still parses a tool policy" || _report no "plain --check (rc=$rc): $out"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-guard-policy.sh 2>&1 | grep -A0 'agent' | grep FAIL | head`
Expected: the new agent cases FAIL (usage error / rc mismatch).

- [ ] **Step 3: Implement.** In `guard_policy.py`, add after `KEYS`:

```python
AGENT_KEYS = ("covers", "deny")
```

Rename the body of `parse` into `_read(text, keys)` (identical loop, but `if key not in keys:` and returning `policy` before `_validate`), then:

```python
def parse(text):
    """Parse and validate a tool's guard.yaml text. Raises PolicyError."""
    policy = _read(text, KEYS)
    _validate(policy)
    return policy


def parse_agent(text):
    """Parse and validate an agent guard policy (the package-root guard.yaml)."""
    policy = _read(text, AGENT_KEYS)
    deny = policy.get("deny")
    if not isinstance(deny, list) or not deny or not all(deny):
        raise PolicyError("deny must be a non-empty list of tool-name patterns")
    covers = policy.get("covers", [])
    if not isinstance(covers, list):
        raise PolicyError("covers must be a list like [a, b]")
    for inv in covers:
        if not SNAKE.match(inv):
            raise PolicyError(f"covers: '{inv}' is not a snake_case invariant id")
    return policy
```

(`_read` keeps the `the policy is empty` error. The `rules`/`writes` block-list branch stays in `_read`; for agent keys it is unreachable because those keys are rejected first.)

Add after `problems`:

```python
def agent_problems(policy, event):
    """The agent policy: deny patterns over every suffix, whatever the server."""
    names = [suffix for suffix, _ in _candidates(event.get("tool_name"))]
    for pattern in policy["deny"]:
        if _matches(names, [pattern]):
            return [f"{names[0]} is denied ({pattern})"]
    return []
```

In `main`, before the existing `--check` branch:

```python
    if len(argv) == 3 and argv[0] == "--check" and argv[1] == "--agent":
        try:
            with open(argv[2], encoding="utf-8") as fh:
                parse_agent(fh.read())
        except Exception as err:  # never a traceback
            print(f"FAIL: {type(err).__name__}: {err}")
            return 1
        return 0
    if argv and argv[0] == "--agent":
        if len(argv) not in (2, 3):
            print("usage: guard_policy.py --agent <guard.yaml> [label]", file=sys.stderr)
            return 2
        label = argv[2] if len(argv) == 3 else "agent guard policy"
        try:
            with open(argv[1], encoding="utf-8") as fh:
                policy = parse_agent(fh.read())
            event = json.load(sys.stdin)
            if not isinstance(event, dict):
                raise PolicyError("hook input is not an object")
            found = agent_problems(policy, event)
        except Exception as err:  # fail closed
            print(f"Blocked by {label}: cannot check this call ({type(err).__name__}: {err})", file=sys.stderr)
            return 2
        for problem in found:
            print(f"Blocked by {label}: {problem}", file=sys.stderr)
        return 2 if found else 0
```

Update the docstring usage block:

```
  guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]   hook input JSON on stdin
  guard_policy.py --agent <guard.yaml> [label]                              agent policy; hook input on stdin
  guard_policy.py --check [--agent] <guard.yaml>                            parse only
```

and the generic usage message string to `... | --agent <guard.yaml> [label] | --check [--agent] <guard.yaml>`.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-guard-policy.sh 2>&1 | tail -1`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard_policy.py tests/test-guard-policy.sh
git commit -m "feat: guard engine --agent mode for a deny-only agent guard policy"
```

### Task 4: `guard.sh` runs the agent policy

**Files:**
- Modify: `_template/hooks/guard.sh` (header comment; new block after the `rest_lc=` line, before `first=1`)
- Test: `tests/test-guard.sh` (new section `-- agent policy`, before `-- paths`)

**Interfaces:**
- Consumes: Task 3 CLI `--agent <file> <label>`.
- Produces: block messages prefixed `Blocked by <agent> agent guard policy: `.

- [ ] **Step 1: Write the failing tests.** In `tests/test-guard.sh`, before `echo "-- paths"`:

```bash
echo "-- agent policy"
printf '%s\n' 'covers: [no_send]' 'deny: ["*send*", "*publish*"]' > "$PKG/guard.yaml"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_send_message)"; expect 2 "unbound server: send denied by the agent policy" "Blocked by demo-agent agent guard policy: slack_send_message is denied (*send*)"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_read_channel)"; expect 0 "unbound server: read passes"
run_guard "$I" "$(call mcp__democrm__send-entry)";               expect 2 "bound server: agent policy runs first" "agent guard policy"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 0 "bound server: allowed by both"
run_guard "$I" "$(call mcp__democrm__delete-record)";            expect 2 "bound server: tool policy still applies" "guard policy (crm/demo)"
run_guard "$W" "$(call mcp__claude_ai_Slack__slack_send_message)"; expect 0 "outside an instance: agent policy silent"
run_guard "$O" "$(call mcp__claude_ai_Slack__slack_send_message)"; expect 0 "another agent's instance: agent policy silent"
run_guard "$I" "$(call Bash '{"command":"ls"}')";                expect 0 "non-MCP tool: agent policy silent"
printf '%s\n' 'deny: [' > "$PKG/guard.yaml"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_read_channel)"; expect 2 "invalid agent policy blocks every MCP call" "cannot check this call"
rm "$PKG/guard.yaml"; mkdir "$PKG/guard.yaml"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_read_channel)"; expect 2 "agent guard.yaml as a directory blocks" "cannot check this call"
rmdir "$PKG/guard.yaml"; ln -s "$W/nowhere.yaml" "$PKG/guard.yaml"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_read_channel)"; expect 2 "dangling agent guard.yaml symlink blocks" "cannot check this call"
rm "$PKG/guard.yaml"; printf '%s\n' 'deny: ["*send*"]' > "$PKG/guard.yaml"
mv "$PKG/hooks/guard_policy.py" "$W/gp.bak"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_read_channel)"; expect 2 "agent policy, engine missing: blocks" "Blocked by demo-agent agent guard policy: the guard policy engine is missing"
mv "$W/gp.bak" "$PKG/hooks/guard_policy.py"
rm "$PKG/guard.yaml"
run_guard "$I" "$(call mcp__claude_ai_Slack__slack_send_message)"; expect 0 "no agent guard.yaml: unbound server allowed"
```

Also bump the fixture's `standard: "4.0"` to `"5.0"` (line 11) — harmless here but keeps fixtures current.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-guard.sh 2>&1 | grep FAIL`
Expected: the agent-policy cases that expect 2 FAIL.

- [ ] **Step 3: Implement.** In `_template/hooks/guard.sh` add a helper after `pblock()`:

```bash
ablock() { printf 'Blocked by %s agent guard policy: %s\n' "$name" "$1" >&2; exit 2; }
```

Insert after `rest_lc=$(lower "${tool#mcp__}")  # …` and before `first=1`:

```bash
# The agent guard policy (package-root guard.yaml) applies to every MCP call,
# whatever the server. A dangling symlink or a directory still reaches the
# engine, which fails closed on it.
apolicy="$root/guard.yaml"
if [ -e "$apolicy" ] || [ -L "$apolicy" ]; then
  engine="$root/hooks/guard_policy.py"
  [ -f "$engine" ] || ablock "the guard policy engine is missing from $name"
  command -v python3 >/dev/null 2>&1 || ablock "python3 is required to run the guard policy"
  printf '%s' "$input" | python3 "$engine" --agent "$apolicy" "$name agent guard policy"; rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 2 ] && exit 2
    ablock "the guard policy engine failed (exit $rc)"
  fi
fi
```

Update the header comment (lines 3–6) to:

```bash
# PreToolUse hook for MCP tools. Inside an instance of this agent, the agent
# guard policy (package-root guard.yaml, deny-only) applies to every MCP call;
# then every bound tool whose server_match appears in the tool name gets its
# guard policy (guard.yaml) enforced by hooks/guard_policy.py. Exit 2 blocks the
# call and shows stderr to the model; exit 0 hands it to the normal permission flow.
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-guard.sh 2>&1 | tail -1`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard.sh tests/test-guard.sh
git commit -m "feat: guard hook applies the agent guard policy to every MCP call in an instance"
```

### Task 5: Validator, schedule gate, Standard 5.0

**Files:**
- Modify: `bin/lib/check_manifests.py` (`CURRENT_STANDARD`, new `check_agent_policy`, call it from `check_tools`)
- Modify: `_template/hooks/schedule_check.py` (new `agent_covers`, gate loop)
- Modify: `_template/agent.yaml` (`standard: "5.0"`)
- Test: `tests/test-validate-agent.sh`, `tests/test-schedule-check.sh`; all fixtures `standard: "4.0"` → `"5.0"` across `tests/*.sh`

**Interfaces:**
- Consumes: `parse_agent` from Task 3 (via `load_policy_engine()` in the validator; via `import guard_policy` in `schedule_check.py`).
- Produces: validator FAIL lines `guard.yaml: <error>` and `the contract of <cap> has no_send, so the agent needs a guard.yaml at its root that covers no_send`; gate problem `<cap>: invariant no_send is not covered by the agent guard policy (guard.yaml at the package root)`.

- [ ] **Step 1: Update fixtures and write failing tests.**

Run: `grep -l 'standard: "4.0"' tests/*.sh | xargs sed -i '' 's/standard: "4.0"/standard: "5.0"/g'` (macOS `sed -i ''`).

In `tests/test-validate-agent.sh` `make_valid_agent`, after the tool `guard.yaml` line, add:

```bash
  printf '%s\n' 'covers: [no_send]' 'deny: ["*send*"]' > "$d/guard.yaml"
```

Near the no_send cases (around line 485–495) add:

```bash
make_valid_agent "$FIX/noagentpolicy"; rm "$FIX/noagentpolicy/guard.yaml"
fails_with "$FIX/noagentpolicy" "the contract of crm has no_send, so the agent needs a guard.yaml at its root that covers no_send"
make_valid_agent "$FIX/agentnocover"; printf '%s\n' 'deny: ["*send*"]' > "$FIX/agentnocover/guard.yaml"
fails_with "$FIX/agentnocover" "the contract of crm has no_send, so the agent needs a guard.yaml at its root that covers no_send"
make_valid_agent "$FIX/badagentpolicy"; printf '%s\n' 'covers: [no_send]' 'allow: [x]' 'deny: ["*send*"]' > "$FIX/badagentpolicy/guard.yaml"
fails_with "$FIX/badagentpolicy" "guard.yaml: "
make_valid_agent "$FIX/oldstd"; sed -i.bak 's/standard: "5.0"/standard: "4.0"/' "$FIX/oldstd/agent.yaml"
fails_with "$FIX/oldstd" "standard '4.0' must be \"5.0\""
```

Also: the existing case at line 491 (`instronly`, which deletes `no_send` from the contract) must still pass — the agent policy is optional there, and its root `guard.yaml` still parses. Leave it.

(Check the exact helper name: the file uses `fails_with <dir> <text>` at line 488; reuse it.)

In `tests/test-schedule-check.sh`, after the fixture block (line 25), add:

```bash
printf '%s\n' 'covers: [no_send]' 'deny: ["*send*"]' > "$PKG/guard.yaml"
```

and append to `-- gate`:

```bash
mv "$PKG/guard.yaml" "$W/agent-guard.bak"
run check "$I" --repo acme/sales; expect 1 "no agent policy: digest fails the gate" "email_drafts: invariant no_send is not covered by the agent guard policy"
expect 1 "no agent policy: prospect (crm only) still passes" "PASS  demo-agent: prospect (sales)"
printf '%s\n' 'deny: ["*send*"]' > "$PKG/guard.yaml"
run check "$I" --repo acme/sales; expect 1 "agent policy without no_send in covers fails" "not covered by the agent guard policy"
mv "$W/agent-guard.bak" "$PKG/guard.yaml"
```

(If `check` exits with a different code when some entries fail, read the existing failing-gate cases in the file and match their rc.)

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-validate-agent.sh 2>&1 | grep FAIL; bash tests/test-schedule-check.sh 2>&1 | grep FAIL`
Expected: new cases FAIL; many old ones FAIL on `standard '5.0' must be "4.0"`.

- [ ] **Step 3: Implement.**

`bin/lib/check_manifests.py`:

```python
CURRENT_STANDARD = "5.0"
```

Add after `check_capability`:

```python
def check_agent_policy(root, caps):
    """The package-root guard.yaml: parses as an agent policy; required to cover no_send when a contract has it."""
    fails = []
    path = root / "guard.yaml"
    covers = None
    if path.exists() or path.is_symlink():
        engine = load_policy_engine()
        if engine is None:
            return ["cannot load the reference guard_policy.py to check guard.yaml"]
        try:
            covers = engine.parse_agent(read_text(path)).get("covers", [])
        except (ReadError, engine.PolicyError) as err:
            fails.append(f"guard.yaml: {err}")
            return fails
    for cap in caps:
        try:
            text = read_text(root / "capabilities" / cap / "contract.md")
        except ReadError:
            continue  # reported by check_capability
        invariants = [m.group(1) for line in section(text, "Invariants") or [] for m in [INVARIANT.match(line)] if m]
        if "no_send" in invariants and (covers is None or "no_send" not in covers):
            fails.append(f"the contract of {cap} has no_send, so the agent needs a guard.yaml at its root that covers no_send")
    return fails
```

In `check_tools`, after the `for cap in caps:` loop that calls `check_capability`, add:

```python
    fails.extend(check_agent_policy(root, [c for c in caps if SNAKE.match(c)]))
```

(Read `read_text`'s exceptions first: it raises `ReadError` for a directory/unreadable file — confirm by reading its definition; if a directory raises something else, catch that too so the result is a FAIL line, never a crash.)

`_template/hooks/schedule_check.py`, after `covers(folder)`:

```python
def agent_covers():
    """covers of the agent guard policy (package-root guard.yaml), or [] when there is none."""
    policy = ROOT / "guard.yaml"
    if not (policy.exists() or policy.is_symlink()):
        return []
    try:
        return guard_policy.parse_agent(policy.read_text(encoding="utf-8")).get("covers", [])
    except (OSError, UnicodeDecodeError, guard_policy.PolicyError) as err:
        raise CheckError(f"guard.yaml: {err}")
```

In the gate loop, right after `invs = invariants(cap)`:

```python
            if "no_send" in invs:
                try:
                    if "no_send" not in agent_covers():
                        entry["problems"].append(
                            f"{cap}: invariant no_send is not covered by the agent guard policy (guard.yaml at the package root)")
                except CheckError as err:
                    entry["problems"].append(f"{cap}: {err}")
```

Update the docstring line 9–11 phrase "every capability its activities use is … guard.yaml covers" to add "and, for no_send, the agent guard policy covers it".

`_template/agent.yaml`: `standard: "5.0"`.

- [ ] **Step 4: Run the whole suite**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: every file `0 failed`. Fix any other fixture still pinned to `4.0` (e.g. `tests/test-builder-manifests.sh`, `tests/test-install.sh`, `tests/test-tool-check.sh`) by the same sed.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/check_manifests.py _template/hooks/schedule_check.py _template/agent.yaml tests/
git commit -m "feat: Agent Standard 5.0 — validator and schedule gate require the agent policy for no_send"
```

### Task 6: Builder docs, version, PR

**Files:**
- Modify: `STANDARD.md` (Agent manifest example `standard: "5.0"`; Guard policy Grammar, Keys, Semantics 4 and 6, Parse errors, Field identity; new subsection `### Agent guard policy` after `### Field identity`; Guard hook — agent step and the Known gap paragraph; Validation)
- Modify: `docs/how-it-works.md` (Airtable `binding_id` passage near line 405; add agent-wide deny list and update-only forbid)
- Modify: `docs/writing-an-agent.md` (when to ship a root `guard.yaml`)
- Modify: builder version wherever it is recorded (`grep -rn '4\.0\.0\|"4.0"' README.md STANDARD.md docs/writing-an-agent.md validate/ .github/ 2>/dev/null`)

- [ ] **Step 1: STANDARD.md.** Make these exact content changes (keep the file's style — short declarative sentences):
  - Grammar bullet on `rules`: item holds `field:` plus any of `create:`, `update:`, `any:`, or `field:` plus `forbid: true` or `forbid: update`; `forbid` is never combined with `create`, `update` or `any`. Remove every `binding_id` mention.
  - Keys table: add row `| bound_keys_only | no | true: every key in a write map must be an ID recorded in a field_<name> binding |`; `writes` row: "if `rules`, `refuse_keys` or `bound_keys_only`".
  - Semantics 4: the two forbid forms and their messages, as in spec A2.
  - New Semantics step "Recorded keys" (between 5 and 6): spec A3 text, both messages verbatim.
  - Semantics 6 / Field identity: a `field_<name>` key may repeat, each line adds one ID; a rule matches its normalized name and every ID under `field_<normalized name>`; a rule whose name repeats across tables matches all of them (fails closed). Delete the "`binding_id: required` makes the ID mandatory" sentences and the "bulleted line … counts as not recorded" clause becomes "a bulleted line is not read as a binding".
  - Parse errors: add "`bound_keys_only` is not `true`, or present without `writes`"; "`forbid` is not `true` or `update`".
  - New `### Agent guard policy`: file location, grammar (keys `covers` optional, `deny` required non-empty; anything else is a parse error), engine CLI (`--agent`, `--check --agent`), semantics (every suffix, no `server_match`, message `<tool> is denied (<pattern>)`), required when a contract has `no_send` (and `covers` must include it), the stated limit paragraph from spec A1, and the sales-partner example.
  - Guard hook: a paragraph — inside an instance, before reading `bind_` lines, `guard.sh` runs the agent policy when `guard.yaml` exists at the package root (a dangling symlink or directory still reaches the engine); label `<agent> agent guard policy`; missing engine / python3 / other nonzero exit blocks. Replace the "Known gap" paragraph with: "A custom tool bound to a `no_send` capability is covered by the agent guard policy's deny list, whatever its own files say; `add-tool`, `tool_check.py` and the schedule gate still require its own `guard.yaml`."
  - Validation: the two new validator checks; the gate's extra `no_send` condition (in `### The unattended gate`).

- [ ] **Step 2: how-it-works.md and writing-an-agent.md.** Replace the `binding_id: required` explanation (around line 405) with the known-IDs rule (the probe records every field's ID; any other key is refused until the probe re-runs). Add a short section "One deny list for the whole agent" (what it blocks, that unbound connectors are covered, that names are matched, not behaviour). Mention update-only forbid where approved drafts are described. In writing-an-agent.md add: ship a root `guard.yaml` listing send/publish globs whenever a capability has `no_send`; check the globs against the read tools of the connectors your users will have.

- [ ] **Step 3: Verify docs and suite**

Run: `grep -rn 'binding_id' STANDARD.md docs/how-it-works.md docs/writing-an-agent.md _template _capability-template README.md; bash tests/run-all.sh 2>&1 | tail -3`
Expected: no `binding_id` hits (the spec and old specs under `docs/superpowers/` may keep it); suite `0 failed`.

- [ ] **Step 4: Commit and open PR**

```bash
git add STANDARD.md docs/ README.md
git commit -m "docs: Agent Standard 5.0 — agent guard policy, update-only forbid, recorded field IDs"
git push -u origin feat/standard-5
gh pr create --title "Agent Standard 5.0: agent guard policy, update-only forbid, recorded field IDs" --body "$(cat <<'EOF'
Implements docs/superpowers/specs/2026-10-01-standard-5-guard-design.md (Part A).

- Agent guard policy: optional deny-only guard.yaml at the package root, run by guard.sh on every MCP call in an instance; required to cover no_send when a contract has it (validator + schedule gate).
- forbid: update — blocks a field only on update.
- bound_keys_only — every written key must be a field ID the probe recorded; field_ bindings may repeat; binding_id removed.
- Standard "5.0".

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Wait for CI green, then merge** (`gh pr checks --watch`, then `gh pr merge --merge` after the user confirms).

---

## Part B — sales-partner (`~/Work/Webspenser/sales-partner`, new branch `feat/standard-5`)

Start only after Part A is merged (sales-partner CI validates against `validate@main`).

### Task 7: Hooks, agent policy, version 5.0.0

**Files:**
- Modify: `hooks/guard.sh`, `hooks/guard_policy.py`, `hooks/schedule_check.py`, `hooks/tool_check.py` (copy from builder `_template/hooks/`)
- Create: `guard.yaml` (package root)
- Modify: `agent.yaml`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`, `README.md` (version line)
- Test: `tests/test-policies.sh` (new section `-- agent policy`)

- [ ] **Step 1: Branch and copy hooks**

```bash
cd ~/Work/Webspenser/sales-partner && git checkout main && git pull -q && git checkout -b feat/standard-5
for f in guard.sh guard_policy.py schedule_check.py tool_check.py; do cp ../agent-builder/_template/hooks/$f hooks/$f; done
```

- [ ] **Step 2: Write the failing tests.** In `tests/test-policies.sh`, after the `for p in … parses` loop, add:

```bash
echo "-- agent policy"
AG=guard.yaml
python3 -B "$E" --check --agent "$AG" >/dev/null && _report ok "agent policy parses" || _report no "agent policy does not parse"
acheck() { # acheck <rc> <label> <tool_name>
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":{}}' "$3" | python3 -B "$E" --agent "$AG" "sales-partner agent guard policy" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ]; then _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
for t in mcp__claude_ai_Gmail__send_message mcp__claude_ai_Gmail__reply mcp__claude_ai_Gmail__forward \
         mcp__claude_ai_Slack__slack_send_message mcp__claude_ai_Slack__slack_schedule_message \
         mcp__claude_ai_Zernio__posts_publish_now mcp__claude_ai_Zernio__posts_create mcp__claude_ai_Zernio__posts_cross_post \
         mcp__claude_ai_Zernio__posts_bulk_upload_posts mcp__claude_ai_Loops__execute_write \
         mcp__claude_ai_Zernio__comments_reply_to_inbox_post; do
  acheck 2 "denied: $t" "$t"
done
for t in mcp__claude_ai_Gmail__create_draft mcp__claude_ai_Gmail__list_drafts mcp__claude_ai_Gmail__search_threads \
         mcp__claude_ai_Gmail__get_thread mcp__claude_ai_Attio__list-comment-replies mcp__claude_ai_Attio__list-records \
         mcp__claude_ai_Beehiiv__list_publications mcp__claude_ai_Beehiiv__get_publication \
         mcp__claude_ai_HubSpot__manage_crm_objects mcp__claude_ai_HubSpot__search_crm_objects \
         mcp__claude_ai_Airtable__update_records_for_table mcp__claude_ai_Slack__slack_read_channel \
         mcp__claude_ai_Zernio__posts_list mcp__claude_ai_Loops__execute; do
  acheck 0 "read or CRM write passes: $t" "$t"
done
```

Run: `bash tests/test-policies.sh 2>&1 | grep -E 'FAIL' | head`
Expected: FAIL `agent policy does not parse` and every `denied:` case.

- [ ] **Step 3: Create `guard.yaml`**

```yaml
# sales-partner agent guard policy: applies to every MCP call inside an
# instance, whatever the server. Nothing this agent does sends, replies,
# forwards, publishes or schedules a message; drafts go to the CRM or to
# Gmail drafts.
covers: [no_send]
deny: ["*send*", "*reply*", "*forward*", "*publish*", "*schedule_message*",
       "*cross_post*", "*posts_create*", "*bulk_upload_posts*", "*execute_write*"]
```

- [ ] **Step 4: Bump versions.** `agent.yaml`: `version: 5.0.0`, `standard: "5.0"`. Set `"version": "5.0.0"` in the three host manifests; update the README version line (`grep -n '4\.0\.4' README.md`).

- [ ] **Step 5: Run and commit**

Run: `bash tests/run-all.sh 2>&1 | tail -3 && ../agent-builder/bin/validate-agent.sh . 2>&1 | tail -3`
Expected: `0 failed`; validator passes (the CRM policies still parse — they have no `binding_id` until Task 8 removes it from Airtable; if Airtable fails to parse now because `binding_id` is unknown, do Task 8 Step 3's Airtable edit in this commit instead).

```bash
git add -A && git commit -m "feat: Standard 5.0 hooks and an agent guard policy that denies send and publish tools"
```

### Task 8: CRM and Gmail policies

**Files:**
- Modify: `capabilities/crm/tools/attio/guard.yaml`, `capabilities/crm/tools/airtable/guard.yaml`, `capabilities/crm/tools/hubspot/guard.yaml`, `capabilities/email_drafts/tools/*/guard.yaml` (the Gmail one; check the folder name with `ls capabilities/email_drafts/tools`)
- Test: `tests/test-policies.sh` (Attio, Airtable, HubSpot, Gmail sections)

- [ ] **Step 1: Write the failing tests.** Add to the Attio section:

```bash
check 0 "create with draft_body"    $AT ${P}add-record-to-list "{$L,\"entry_values\":{\"status\":\"draft\",\"draft_body\":\"Hi\"}}"
check 2 "draft_body rewritten on update" $AT ${P}update-list-entry-by-id "{$X,\"entry_values\":{\"draft_body\":\"new\"}}" "draft_body may not be changed after create"
check 2 "create-task not allowed"   $AT ${P}create-task '{"content":"x"}' "is not in the allow list"
check 2 "update-task not allowed"   $AT ${P}update-task '{"task_id":"x"}' "is not in the allow list"
check 2 "create-note not allowed"   $AT ${P}create-note '{"title":"x"}' "is not in the allow list"
```

(Attio `allow` is only enforced with a `server_match`; check how `check` passes it. If `check` passes none, `allow` still applies over every suffix — the existing tests prove the allow list works; follow them.)

Find the Airtable section and replace its bindings fixture so every written field has an ID, e.g.:

```bash
ABIND="$W/airtable.md"
printf '%s\n' 'base_id: appXXXXXXXXXXXXXX' 'field_status: fldSTATUSSSSSSSSS' 'field_do_not_contact: fldDNCCCCCCCCCCCC' \
  'field_draft_body: fldBODYYYYYYYYYYY' 'field_summary: fldSUMMMMMMMMMMMM' 'field_company: fldCOMPPPPPPPPPPP' > "$ABIND"
```

and add:

```bash
check 2 "unrecorded field ID"       $AR ${AP}update_records_for_table '{"baseId":"appXXXXXXXXXXXXXX","tableId":"tblX","records":[{"id":"recX","fields":{"fldOTHERRRRRRRRRR":"x"}}]}' "is not a recorded field ID" "$ABIND"
check 0 "create draft with body"    $AR ${AP}create_records_for_table '{"baseId":"appXXXXXXXXXXXXXX","tableId":"tblX","records":[{"fields":{"fldSTATUSSSSSSSSS":"draft","fldBODYYYYYYYYYYY":"Hi","fldSUMMMMMMMMMMMM":"x"}}]}' "" "$ABIND"
check 2 "Draft Body rewritten"      $AR ${AP}update_records_for_table '{"baseId":"appXXXXXXXXXXXXXX","tableId":"tblX","records":[{"id":"recX","fields":{"fldBODYYYYYYYYYYY":"new"}}]}' "Draft Body may not be changed after create" "$ABIND"
check 2 "no IDs recorded"           $AR ${AP}create_records_for_table '{"baseId":"appXXXXXXXXXXXXXX","tableId":"tblX","records":[{"fields":{"fldCOMPPPPPPPPPPP":"Acme"}}]}' "has not recorded any field IDs"
```

(Use the section's existing variable names for the policy path and tool prefix; read the section first. Existing Airtable cases that pass a bindings file with only `field_status`/`field_do_not_contact` must switch to `$ABIND`; cases expecting `has not recorded field_status` change to `has not recorded any field IDs`.)

HubSpot section:

```bash
check 0 "task created with body"    $HS $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"hs_task_status":"NOT_STARTED","hs_task_body":"<p>x</p>"}}]}}'
check 2 "task body rewritten"       $HS $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"hs_task_status":"DEFERRED","hs_task_body":"<p>y</p>"}}]}}' "hs_task_body may not be changed after create"
check 0 "void without body passes"  $HS $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"hs_task_status":"DEFERRED"}}]}}'
check 0 "outcome note created"      $HS $T '{"createRequest":{"objects":[{"objectType":"notes","properties":{"hs_note_body":"<p>Outcome for task 1: dup</p>","hs_timestamp":"2026-10-01T00:00:00Z"}}]}}'
```

Gmail section (use its variable names):

```bash
check 0 "prefixed create_draft allowed" $GM mcp__gmail_server__gmail_create_draft '{}'
check 2 "prefixed send still denied"    $GM mcp__gmail_server__gmail_send_message '{}' "denied"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-policies.sh 2>&1 | grep FAIL`
Expected: the new cases FAIL.

- [ ] **Step 3: Edit the policies.**

Attio `allow` — drop the last line's three tools:

```yaml
allow: [whoami, list-*, get-*, search-*, semantic-search-*, run-basic-report,
        add-record-to-list, create-record, upsert-record, update-record,
        update-list-entry-by-id, update-list-entry-by-record-id]
```

and append to its `rules`:

```yaml
  - field: draft_body
    forbid: update
```

Airtable: delete both `    binding_id: required` lines, add `bound_keys_only: true` after `unknown_writes: block`, append:

```yaml
  - field: Draft Body
    forbid: update
```

and replace the header comment with:

```yaml
# Airtable guard policy. The Airtable connector keys fields by ID, so every
# written key must be a field ID the probe recorded in bindings/crm.md
# (bound_keys_only); the rules below match those IDs by field name.
```

HubSpot: append to `rules`:

```yaml
  - field: hs_task_body
    forbid: update
```

Gmail:

```yaml
allow: ["*create_draft", "*list_drafts", "*get_draft", "*search_threads", "*get_thread",
        "*get_message", "*list_labels"]
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run-all.sh 2>&1 | tail -3`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add capabilities tests && git commit -m "feat: approved draft bodies can't be rewritten; Airtable writes only recorded field IDs; Gmail allow by suffix; Attio drops unused write tools"
```

### Task 9: Usage docs — HubSpot void, Airtable probe, small docs

**Files:**
- Modify: `capabilities/crm/tools/hubspot/usage.md` (`### update_activity` around line 264; `get_lead` outcome read; any statement that voiding rewrites the body)
- Modify: `capabilities/crm/tools/airtable/usage.md` (`## Probe` ~line 300, `## Guard policy` ~line 330)
- Modify: `capabilities/crm/tools/attio/usage.md`, airtable, hubspot usage — "write only the fields that change"
- Modify: `capabilities/email_drafts/tools/<gmail>/usage.md` (remove "add its names to `allow`", line ~21)
- Test: `tests/test-content.sh`

- [ ] **Step 1: Write failing content tests.** Append to `tests/test-content.sh` (use its `assert_contains` / `assert_not_contains` helpers):

```bash
echo "-- 5.0 usage"
HU=capabilities/crm/tools/hubspot/usage.md; AU=capabilities/crm/tools/airtable/usage.md
assert_contains "$HU" "Outcome for task <activity_id>:"
assert_not_contains "$HU" "body with Outcome: line"
assert_contains "$AU" "every field of the four tables"
assert_contains "$AU" "is not a recorded field ID"
assert_not_contains "$AU" "binding_id"
for f in capabilities/crm/tools/*/usage.md; do assert_contains "$f" "Write only the fields that change"; done
assert_not_contains capabilities/email_drafts/tools/*/usage.md "add its names to"
```

Run: `bash tests/test-content.sh 2>&1 | grep FAIL` — Expected: these FAIL.

- [ ] **Step 2: HubSpot `update_activity`.** Replace the section body with:

```markdown
Reject a `status` other than `voided`. Set the Task's status only:

    {"updateRequest": {"objects": [{"objectType": "tasks", "objectId": <activity_id>,
      "properties": {"hs_task_status": "DEFERRED"}}]}}

When an `outcome` is given, also create a Note on the lead's Company:

    {"createRequest": {"objects": [{"objectType": "notes",
      "properties": {"hs_note_body": "<p>Outcome for task <activity_id>: <outcome></p>",
                     "hs_timestamp": "<now, ISO 8601 UTC>"},
      "associations": [{"targetObjectType": "COMPANY", "targetObjectId": <lead_id>}]}]}}

The status change is the only write this tool ever makes to an existing
Task: the guard refuses any change to `hs_task_body` after create.
```

Then in `get_lead` (and anywhere `outcome` is read for an activity — `grep -n -i outcome $HU`), say: a voided activity's `outcome` is the text after `Outcome for task <activity_id>: ` in the newest Note on the company whose body starts with it. Remove the instruction to read the Task body for the Outcome line.

- [ ] **Step 3: Airtable probe and guard text.** (Refinement of spec B4: the "run the probe when no IDs are recorded" rule lives in the Airtable `usage.md`, which every operation already reads on every host, instead of in the generic `start`/`setup` skills.) Probe step 2 becomes:

```markdown
2. `airtable:list_tables_for_base` on that base — every table and
   field named in this tool must exist with the listed type. Record
   every field of the four tables, from that one call, as
   `field_<name>: <field ID>` — the name lowercased, spaces and hyphens
   as underscores (`Do Not Contact` → `field_do_not_contact`). A name
   used in two tables gets two lines.
```

Update the example block to show several lines including a repeated `field_lead`. Add after the example:

```markdown
Before the first Airtable write in a session, if `bindings/crm.md` has
no `field_` lines, run this probe first. If a write is refused with
"is not a recorded field ID" or "has not recorded any field IDs", run
the probe again, rewrite the `field_` lines, and retry the write once;
if it is refused again, stop and tell the user.
```

Rewrite `## Guard policy` to say: the allow list (unchanged text); every key in a write must be a field ID the probe recorded, so a field added or recreated in Airtable is refused until the probe runs again; `Status` only `draft` on create and `voided` on update; `Do Not Contact` only `true`; `Draft Body` can be set on create and never changed after. Delete the paragraph "Every Airtable write stays blocked until the probe has recorded both IDs…".

- [ ] **Step 4: Small docs.** In each CRM `usage.md`, in the section that introduces updates (or `update_stage`), add the sentence: "Write only the fields that change: an update that repeats unchanged fields (for example `do_not_contact: false`) can be refused by the guard." In the Gmail `usage.md`, replace the "add its names to `allow`" sentence with: "The allow list matches names by suffix (`*create_draft`), so a Gmail server that prefixes its tool names still works."

- [ ] **Step 5: Run and commit**

Run: `bash tests/run-all.sh 2>&1 | tail -3 && ../agent-builder/bin/validate-agent.sh . | tail -2`
Expected: `0 failed`, validator PASS.

```bash
git add capabilities tests && git commit -m "docs: HubSpot void writes an outcome Note; Airtable probe records every field ID and re-probes on refusal"
```

### Task 10: sales-partner PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin feat/standard-5
gh pr create --title "sales-partner 5.0.0: Agent Standard 5.0 guard" --body "$(cat <<'EOF'
Implements Part B of agent-builder docs/superpowers/specs/2026-10-01-standard-5-guard-design.md.

- Root guard.yaml: send/reply/forward/publish/schedule denied on every MCP call in an instance.
- Approved draft bodies can't be rewritten (Attio draft_body, Airtable Draft Body, HubSpot hs_task_body).
- HubSpot void sets DEFERRED and records the outcome as a Note on the company.
- Airtable: every written key must be a recorded field ID; the probe records all fields and re-runs on refusal.
- Gmail allow by suffix; Attio drops create-note/create-task/update-task.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: CI green** (`gh pr checks --watch`); merge after the user confirms.

- [ ] **Step 3: Update memory** — `agent-ecosystem-roadmap.md`: Standard 5.0 shipped (builder PR #, sales-partner PR #); next in the agreed order is compliance.
