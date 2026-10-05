# Agent Standard 6.0 (builder) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Part A of the outbound enrollment design: operator-accepted instruction-only invariants and n8n-wrapped tools, as Agent Standard 6.0 in agent-builder.

**Architecture:** Contract parsing gains an `(acceptable)` mark (`tool_check.acceptable`), the schedule gate honours `accept_instruction_only` in `instance.yaml`, `tool_check.py` validates `wrapper: n8n` tools and their `workflow.n8n.json`, and the validator requires an agent with a wrapped tool to deny n8n's dispatcher tools. Docs and the version move to 6.0.

**Tech Stack:** Python 3 standard library, POSIX bash, the plain-bash test harness in `tests/`.

**Spec:** `docs/superpowers/specs/2026-10-01-outbound-enrollment-design.md` (Part A, decisions 9 and 18)

## Global Constraints

- No backward compatibility, no migration notes. Standard string `"6.0"`, builder `6.0.0`.
- **Do not merge the builder PR on its own.** `validate@main` would then require `standard: "6.0"` and break sales-partner's CI. Open it, then merge it back to back with the sales-partner 6.0.0 PR (Part B, separate plan).
- `tool_check.py`, `schedule_check.py`, `guard_policy.py` never print a traceback; bad input is a FAIL/ERROR line.
- Hooks in an agent are byte-identical to `_template/hooks/`; `skills/add-tool/SKILL.md` is byte-identical to the template.
- Repo: `~/Work/Webspenser/agent-builder`, branch `feat/standard-6` (already holds the spec commits).

## Review Focus

1. **An `(acceptable)` invariant accepted for one capability but named by another capability's contract without the mark** — the gate must fail that other capability, not pass it. Pinned in Task 2.
2. **`accept_instruction_only` with extra spaces, quotes or a trailing comment** — read the way other instance keys are (`flat_yaml`, `listed`). Pinned in Task 2.
3. **A workflow export whose tool node is connected to a different node than the MCP trigger** — not counted as an exposed tool. Pinned in Task 3.
4. **A wrapped tool whose `usage.md` mentions `<server_match>:name` inside prose for a tool the workflow lacks** — reported, so docs and workflow can't drift. Pinned in Task 3.
5. **Root `guard.yaml` denies `*execute_workflow*` with different case or quoting** — the validator compares patterns ignoring case. Pinned in Task 4.

---

### Task 1: The `(acceptable)` mark

**Files:**
- Modify: `_template/hooks/tool_check.py` (constant `ACCEPTABLE`, function `acceptable`)
- Modify: `bin/lib/check_manifests.py` (`check_capability`)
- Test: `tests/test-validate-agent.sh`

**Interfaces:**
- Produces: `tool_check.ACCEPTABLE = re.compile(r"^[-*]\s+`([^`]+)`\s+\(acceptable\)")`; `tool_check.acceptable(text: str) -> set[str]` (ids under `## Invariants` carrying the mark). Validator FAIL `capabilities/<cap>/contract.md: no_send cannot be marked (acceptable)`.

- [ ] **Step 1: Failing tests.** In `tests/test-validate-agent.sh`, near the other no_send cases (after the `instronly` case), add:

```bash
make_valid_agent "$FIX/acc"; sed -i.bak 's/^- `draft_only` — only drafts/- `draft_only` (acceptable) — only drafts/' "$FIX/acc/capabilities/crm/contract.md"
assert_pass $V "$FIX/acc"   # an acceptable mark parses; the invariant id is still draft_only
make_valid_agent "$FIX/accnosend"; sed -i.bak 's/^- `no_send` — never sends/- `no_send` (acceptable) — never sends/' "$FIX/accnosend/capabilities/crm/contract.md"
fails_with "$FIX/accnosend" "capabilities/crm/contract.md: no_send cannot be marked (acceptable)"
```

Run: `bash tests/test-validate-agent.sh 2>&1 | grep -E "FAIL|passed"`
Expected: FAIL on the `accnosend` case only (the `acc` case already passes because `INVARIANT` captures the id before the mark — confirm; if it fails, that is a finding about `INVARIANT` and the fix is in Step 2).

- [ ] **Step 2: Implement.** `tool_check.py`, after `INVARIANT`:

```python
ACCEPTABLE = re.compile(r"^[-*]\s+`([^`]+)`\s+\(acceptable\)")
```

after `read_contract`:

```python
def acceptable(text):
    """Invariant ids under ## Invariants marked (acceptable): an instance may accept them as instruction-only."""
    return {m.group(1) for line in section(text, "Invariants") or [] for m in [ACCEPTABLE.match(line)] if m}
```

`check_manifests.py` `check_capability`, after the snake_case loop:

```python
    checker = load_tool_checker()
    if checker is not None and "no_send" in checker.acceptable(text):
        fails.append(f"{rel}: no_send cannot be marked (acceptable)")
```

- [ ] **Step 3: Verify and commit**

Run: `bash tests/test-validate-agent.sh 2>&1 | tail -1` → `0 failed`.

```bash
git add _template/hooks/tool_check.py bin/lib/check_manifests.py tests/test-validate-agent.sh
git commit -m "feat: contracts can mark an invariant (acceptable); no_send never"
```

### Task 2: The gate honours `accept_instruction_only`

**Files:**
- Modify: `_template/hooks/schedule_check.py` (`expected`, `_text`, docstring)
- Test: `tests/test-schedule-check.sh`

**Interfaces:**
- Consumes: `tool_check.acceptable(text)` (Task 1).
- Produces: each entry dict gains `"accepted": [str]` ("<cap>: <invariant>"); text output line `  ACCEPTED (instruction-only): <cap>: <invariant>` under a PASS entry; problem `<cap>: <invariant> is listed in accept_instruction_only, but the contract does not mark it (acceptable)`.

- [ ] **Step 1: Failing tests.** Append to `-- gate` in `tests/test-schedule-check.sh` (fixtures: crm contract has `draft_only`, `no_delete`; tool `half` covers only `draft_only`):

```bash
cp "$PKG/capabilities/crm/contract.md" "$W/crm-contract.bak"
sed -i.bak 's/^- `no_delete` — y/- `no_delete` (acceptable) — y/' "$PKG/capabilities/crm/contract.md"
HA="$W/halfacc"; instance "$HA" half mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
printf '%s\n' 'accept_instruction_only: no_delete  # owner accepted 2026-10-01' >> "$HA/instance.yaml"
run check "$HA";  expect 0 "accepted acceptable invariant passes" "PASS  demo-agent: prospect (halfacc)"
expect 0 "accepted invariant is shown" "ACCEPTED (instruction-only): crm: no_delete"
HN="$W/halfnoacc"; instance "$HN" half mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$HN";  expect 1 "acceptable but not accepted still fails" "crm: invariant no_delete is not covered by the half tool's guard policy"
HB="$W/bareacc"; instance "$HB" bare mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
printf '%s\n' 'accept_instruction_only: "draft_only, no_delete"' >> "$HB/instance.yaml"
run check "$HB";  expect 1 "accepting an unmarked invariant fails" "crm: draft_only is listed in accept_instruction_only, but the contract does not mark it (acceptable)"
run check "$HA" --json; expect 0 "json carries accepted" '"accepted": ['
cp "$W/crm-contract.bak" "$PKG/capabilities/crm/contract.md"
```

(Check `instance`'s signature in the file: `instance <dir> <crm provider|-> <email provider|-> <schedule lines...>`; the `--json` flag position must match `run check`'s argument order used elsewhere in the file — adjust if `--json` must come before the folder.)

Run: `bash tests/test-schedule-check.sh 2>&1 | grep -E "FAIL|passed"` → the new cases FAIL.

- [ ] **Step 2: Implement.** In `expected()`, after `bound, bad_line = bindings(instance)`:

```python
    accepted = listed(inst.get("accept_instruction_only", ""))
```

In the per-entry setup, next to `"problems": []`, add `"accepted": []`. In the capability loop, right after `invs = invariants(cap)` (and the 5.0 `no_send` block), add:

```python
            try:
                marked = tool_check.acceptable(_read(ROOT / "capabilities" / cap / "contract.md", guard=False))
            except CheckError as err:
                entry["problems"].append(f"{cap}: {err}")
                marked = set()
            for inv in accepted:
                if inv in invs and inv not in marked:
                    entry["problems"].append(
                        f"{cap}: {inv} is listed in accept_instruction_only, but the contract does not mark it (acceptable)")
```

Replace the uncovered-invariant loop with:

```python
                for inv in invs:
                    if inv in covered:
                        continue
                    if inv in accepted and inv in marked:
                        if f"{cap}: {inv}" not in entry["accepted"]:
                            entry["accepted"].append(f"{cap}: {inv}")
                        continue
                    entry["problems"].append(
                        f"{cap}: invariant {inv} is not covered by the {provider} tool's guard policy")
```

In `_text`, inside `if e["ok"]:` after the `prompt` line:

```python
            for a in e["accepted"]:
                out.append(f"  ACCEPTED (instruction-only): {a}")
```

Docstring of `check`: add "an invariant the contract marks (acceptable) and instance.yaml lists in accept_instruction_only counts as covered and is shown as ACCEPTED".

- [ ] **Step 3: Verify and commit**

Run: `bash tests/test-schedule-check.sh 2>&1 | tail -1` → `0 failed`.

```bash
git add _template/hooks/schedule_check.py tests/test-schedule-check.sh
git commit -m "feat: the schedule gate accepts operator-accepted instruction-only invariants and shows them"
```

### Task 3: Wrapped tools in `tool_check.py`

**Files:**
- Modify: `_template/hooks/tool_check.py` (`IDENTITY_KEYS`, `parse_identity` message, new `check_workflow`, `check_tool`)
- Test: `tests/test-tool-check.sh` (new section `-- wrapped (n8n)`)

**Interfaces:**
- Produces: identity key `wrapper` (only value `n8n`); `check_workflow(folder, label, server_match, usage_text) -> list[str]`; constants `N8N_TRIGGER = "@n8n/n8n-nodes-langchain.mcpTrigger"`, `N8N_AUTH = ("bearerAuth", "headerAuth")`.

- [ ] **Step 1: Failing tests.** Append before `finish` in `tests/test-tool-check.sh`:

```bash
echo "-- wrapped (n8n)"
wf() { # wf <dir> <auth> <tool names...> — a minimal n8n export: trigger + one HTTP tool node per name
  local d="$1" auth="$2"; shift 2
  python3 - "$d/workflow.n8n.json" "$auth" "$@" <<'PY'
import json, sys
path, auth, names = sys.argv[1], sys.argv[2], sys.argv[3:]
nodes = [{"name": "MCP", "type": "@n8n/n8n-nodes-langchain.mcpTrigger", "parameters": {"authentication": auth}}]
conns = {}
for n in names:
    nodes.append({"name": n, "type": "n8n-nodes-base.httpRequestTool", "parameters": {"method": "POST", "url": "https://api.example.com/v1/x"}})
    conns[n] = {"ai_tool": [[{"node": "MCP", "type": "ai_tool", "index": 0}]]}
json.dump({"nodes": nodes, "connections": conns}, open(path, "w"))
PY
}
wrapped() { # wrapped: the demo tool as an n8n-wrapped tool with tools create and get
  fresh; printf '%s\n' 'wrapper: n8n' >> "$T/identity.yaml"; wf "$T" bearerAuth create get whoami
}
wrapped; run "$T" "$C/contract.md";                       expect 0 "wrapped tool passes" "OK: "
fresh; printf '%s\n' 'wrapper: zapier' >> "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "unknown wrapper" "wrapper must be n8n"
wrapped; rm "$T/workflow.n8n.json"; run "$T" "$C/contract.md"; expect 1 "missing workflow" "missing $T/workflow.n8n.json"
wrapped; printf '{not json' > "$T/workflow.n8n.json"; run "$T" "$C/contract.md"; expect 1 "bad JSON" "not valid JSON"
wrapped; wf "$T" none create get whoami; run "$T" "$C/contract.md"; expect 1 "trigger without auth" "must require Bearer or Header auth"
wrapped; wf "$T" bearerAuth create get whoami extra; run "$T" "$C/contract.md"; expect 1 "tool not in usage" "tool extra is not mapped in usage.md as demo:extra"
wrapped; wf "$T" bearerAuth create whoami; run "$T" "$C/contract.md"; expect 1 "usage names a missing tool" '`demo:get` is not a tool of the workflow'
wrapped; wf "$T" bearerAuth "Create Lead" get whoami; run "$T" "$C/contract.md"; expect 1 "tool name not snake_case" "must be named in snake_case"
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"][1]["parameters"]["url"] = "={{ $fromAI('url') }}"; json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "caller-set URL refused" "tool create lets the caller set its url"
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"][1]["parameters"]["headerParameters"] = {"parameters": [{"name": "Authorization", "value": "Bearer ivq_live_abcdefghijkl"}]}
json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "literal token refused" "holds a literal bearer token"
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"].append({"name": "Other", "type": "n8n-nodes-base.noOp", "parameters": {}})
d["connections"]["get"] = {"ai_tool": [[{"node": "Other", "type": "ai_tool", "index": 0}]]}
json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "tool wired elsewhere is not exposed" '`demo:get` is not a tool of the workflow'
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"].append(dict(d["nodes"][0], name="MCP2")); json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "two triggers refused" "needs exactly one MCP Server Trigger node"
```

Note the fixture `usage.md` names `demo:create`, `demo:get` and (in its Probe) `demo:whoami` (see `good_tool`), so the workflow exposes `create`, `get`, `whoami`.

Run: `bash tests/test-tool-check.sh 2>&1 | grep -E "FAIL|passed"` → the new cases FAIL (first one with `unknown key 'wrapper'`).

- [ ] **Step 2: Implement.** In `tool_check.py`: add `import json`; set

```python
IDENTITY_KEYS = ("capability", "provider", "server_match", "wrapper")
N8N_TRIGGER = "@n8n/n8n-nodes-langchain.mcpTrigger"
N8N_AUTH = ("bearerAuth", "headerAuth")
TOOL_NAME = re.compile(r"[a-z][a-z0-9_]*")
LITERAL_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")
```

and change the unknown-key message to `(identity.yaml holds capability, provider, server_match, wrapper)`. Add:

```python
def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for value in obj.values():
            yield from _strings(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _strings(value)


def check_workflow(folder, label, server_match, usage_text):
    """FAIL messages for a wrapped tool's workflow.n8n.json (an n8n workflow export)."""
    rel = f"{label}/workflow.n8n.json"
    path = folder / "workflow.n8n.json"
    if not path.is_file():
        return [f"missing {rel} (identity.yaml says wrapper: n8n)"]
    try:
        wf = json.loads(read(path))
    except (ToolError, ValueError) as err:
        return [f"{rel}: not valid JSON ({err})"]
    nodes = wf.get("nodes") if isinstance(wf, dict) else None
    conns = wf.get("connections") if isinstance(wf, dict) else None
    if not isinstance(nodes, list) or not isinstance(conns, dict) or not all(isinstance(n, dict) for n in nodes):
        return [f"{rel}: needs a nodes list and a connections object (an n8n workflow export)"]
    triggers = [n for n in nodes if n.get("type") == N8N_TRIGGER]
    if len(triggers) != 1:
        return [f"{rel}: needs exactly one MCP Server Trigger node ({N8N_TRIGGER}), found {len(triggers)}"]
    trigger, fails = triggers[0], []
    auth = (trigger.get("parameters") or {}).get("authentication")
    if auth not in N8N_AUTH:
        fails.append(f"{rel}: the MCP Server Trigger must require Bearer or Header auth (authentication is {auth!r})")
    tools = set()
    for source, outputs in conns.items():
        groups = outputs.get("ai_tool", []) if isinstance(outputs, dict) else []
        for group in groups if isinstance(groups, list) else []:
            for link in group if isinstance(group, list) else []:
                if isinstance(link, dict) and link.get("node") == trigger.get("name"):
                    tools.add(source)
    if not tools:
        fails.append(f"{rel}: the MCP Server Trigger exposes no tools")
    by_name = {n.get("name"): n for n in nodes}
    for name in sorted(tools):
        if not TOOL_NAME.fullmatch(name):
            fails.append(f"{rel}: tool node {name!r} must be named in snake_case (the name is the MCP tool name)")
        params = (by_name.get(name) or {}).get("parameters") or {}
        for key in ("url", "method"):
            value = params.get(key)
            if isinstance(value, str) and "$fromAI" in value:
                fails.append(f"{rel}: tool {name} lets the caller set its {key}; fix it in the workflow")
    mapped = set(re.findall(rf"(?<![A-Za-z0-9_-]){re.escape(server_match)}:([A-Za-z0-9_]+)", usage_text))
    for name in sorted(tools - mapped):
        fails.append(f"{rel}: tool {name} is not mapped in usage.md as {server_match}:{name}")
    for name in sorted(mapped - tools):
        fails.append(f"{label}/usage.md: `{server_match}:{name}` is not a tool of the workflow's MCP Server Trigger")
    if any(LITERAL_BEARER.search(s) for s in _strings(wf)):
        fails.append(f"{rel}: holds a literal bearer token; keep secrets in n8n credentials")
    return fails
```

In `check_tool`, after the identity block (where `identity` is known), add the wrapper value check:

```python
            wrapper = identity.get("wrapper")
            if wrapper is not None and wrapper != "n8n":
                fails.append(f"{rel}: wrapper must be n8n (got {wrapper!r})")
```

and after the usage block (where `text` is the usage text), add:

```python
    if identity.get("wrapper") == "n8n" and usage.is_file():
        try:
            usage_text = read(usage)
        except ToolError:
            usage_text = ""  # already reported
        fails.extend(check_workflow(folder, label, identity.get("server_match", ""), usage_text))
```

- [ ] **Step 3: Verify and commit**

Run: `bash tests/test-tool-check.sh 2>&1 | tail -1` → `0 failed`. Then `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`.

```bash
git add _template/hooks/tool_check.py tests/test-tool-check.sh
git commit -m "feat: tool_check validates n8n-wrapped tools and their MCP workflow"
```

### Task 4: Validator — wrapped tools need the dispatcher deny

**Files:**
- Modify: `bin/lib/check_manifests.py` (`check_agent_policy`)
- Test: `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `tool_check.parse_identity`, `guard_policy.parse_agent` (5.0).
- Produces: FAIL `capabilities/<cap>/tools/<tool> is wrapped in n8n, so guard.yaml at the root must deny "*execute_workflow*"` (one per missing pattern of `N8N_DISPATCHERS`).

- [ ] **Step 1: Failing tests.** In `tests/test-validate-agent.sh`, after the agent-policy cases:

```bash
wrapdemo() { # wrapdemo <dir>: the demo tool becomes n8n-wrapped with a valid workflow
  local a="$1/capabilities/crm/tools/demo"
  printf '%s\n' 'wrapper: n8n' >> "$a/identity.yaml"
  python3 - "$a/workflow.n8n.json" <<'PY'
import json, sys
nodes = [{"name": "MCP", "type": "@n8n/n8n-nodes-langchain.mcpTrigger", "parameters": {"authentication": "bearerAuth"}}]
conns = {}
for n in ("create", "get", "whoami"):
    nodes.append({"name": n, "type": "n8n-nodes-base.httpRequestTool", "parameters": {"method": "POST", "url": "https://api.example.com"}})
    conns[n] = {"ai_tool": [[{"node": "MCP", "type": "ai_tool", "index": 0}]]}
json.dump({"nodes": nodes, "connections": conns}, open(sys.argv[1], "w"))
PY
}
make_valid_agent "$FIX/wrapnodeny"; wrapdemo "$FIX/wrapnodeny"
fails_with "$FIX/wrapnodeny" 'capabilities/crm/tools/demo is wrapped in n8n, so guard.yaml at the root must deny "*execute_workflow*"'
make_valid_agent "$FIX/wrapok"; wrapdemo "$FIX/wrapok"
printf '%s\n' 'covers: [no_send]' 'deny: ["*send*", "*EXECUTE_WORKFLOW*", "*create_workflow*", "*update_workflow*",' \
  '       "*archive_workflow*", "*publish_workflow*"]' > "$FIX/wrapok/guard.yaml"
assert_pass $V "$FIX/wrapok"
```

The fixture usage.md names `demo:create`, `demo:get` and `demo:whoami` (see `make_valid_agent`), matching the tool names.

Run: `bash tests/test-validate-agent.sh 2>&1 | grep -E "FAIL|passed"` → `wrapnodeny` FAILs.

- [ ] **Step 2: Implement.** In `check_manifests.py` add near the top constants:

```python
N8N_DISPATCHERS = ("*execute_workflow*", "*create_workflow*", "*update_workflow*",
                   "*archive_workflow*", "*publish_workflow*")
```

In `check_agent_policy`, keep the parsed deny list (`deny = [p.lower() for p in policy.get("deny", [])]`, `[]` when there is no root policy), then before `return fails`:

```python
    checker = load_tool_checker()
    for cap in caps:
        for ident in sorted((root / "capabilities" / cap / "tools").glob("*/identity.yaml")):
            try:
                data, _ = checker.parse_identity(read_text(ident), str(ident)) if checker else ({}, [])
            except ReadError:
                continue  # reported by the tool check
            if data.get("wrapper") != "n8n":
                continue
            for pattern in N8N_DISPATCHERS:
                if pattern not in deny:
                    fails.append(f"capabilities/{cap}/tools/{ident.parent.name} is wrapped in n8n, "
                                 f'so guard.yaml at the root must deny "{pattern}"')
```

(Restructure `check_agent_policy` so the deny list is available when the policy parsed, and the function does not return early before this loop on a missing policy. Keep the 5.0 messages and tests unchanged.)

- [ ] **Step 3: Verify and commit**

Run: `bash tests/test-validate-agent.sh 2>&1 | tail -1` → `0 failed`; `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`.

```bash
git add bin/lib/check_manifests.py tests/test-validate-agent.sh
git commit -m "feat: an agent with an n8n-wrapped tool must deny n8n's dispatcher tools"
```

### Task 5: Docs, skills, Standard 6.0

**Files:**
- Modify: `STANDARD.md`, `docs/how-it-works.md`, `docs/writing-an-agent.md`, `_template/skills/add-tool/SKILL.md`, `_template/skills/setup/SKILL.md`, `_template/agent.yaml`, `bin/lib/check_manifests.py` (`CURRENT_STANDARD`), builder manifests (`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `gemini-extension.json`), `tests/` fixtures, `tests/test-builder-manifests.sh`, `tests/run-all.sh`

- [ ] **Step 1: Version.** `CURRENT_STANDARD = "6.0"`; `_template/agent.yaml` `standard: "6.0"`; `grep -l 'standard: "5.0"' tests/*.sh | xargs sed -i '' 's/standard: "5.0"/standard: "6.0"/g'`; `tests/test-validate-agent.sh` the `must be "5.0"` and `oldstd` expectations to `6.0` (oldstd now sets `5.0` and expects `standard '5.0' must be "6.0"`); `tests/run-all.sh` template check to `6.0`; builder manifests and `tests/test-builder-manifests.sh` to `6.0.0`. Run `bash tests/run-all.sh` → `ALL GREEN`.

- [ ] **Step 2: STANDARD.md.** Development phase → 5.0 becomes 6.0. Capabilities: an invariant line may end its id with ` (acceptable)`; `no_send` never. Instances: `accept_instruction_only: <invariant>[, …]`, written only by setup after showing the risk. The unattended gate: accepted acceptable invariants count as covered and print `ACCEPTED (instruction-only): <cap>: <invariant>`; accepting an unmarked one fails. Tools: identity key `wrapper` (only `n8n`) and a new subsection "Wrapped tools (n8n)" with the rules of spec A2 and every `tool_check.py` message from Task 3. Validation: Task 1 and Task 4 checks.

- [ ] **Step 3: Skills.** `_template/skills/add-tool/SKILL.md`: when the system has no MCP server, offer the n8n wrapper (`wrapper: n8n`, a `workflow.n8n.json` with an MCP Server Trigger, Bearer or Header auth, one snake_case tool node per mapped tool, secrets in n8n credentials, never a caller-set URL), and remind that the agent's root `guard.yaml` must deny the five dispatcher patterns. `_template/skills/setup/SKILL.md` tools step: when a bound tool leaves an invariant uncovered that the contract marks `(acceptable)`, explain in plain words what is not enforced and what could happen, and write `accept_instruction_only` only after the user agrees; never for an unmarked invariant.

- [ ] **Step 4: how-it-works and writing-an-agent.** how-it-works: a short "Accepted risks" paragraph (what an accepted invariant is, where it shows), and "Wrapping a service in n8n" (why per-workflow triggers, why instance-level n8n MCP is denied, where secrets live); header line `Current: standard 6.0. Agent Builder 6.0.0, sales-partner 6.0.0.`. writing-an-agent: the `(acceptable)` mark (use it only for invariants a guard can't check by design) and wrapped tools.

- [ ] **Step 5: Verify and commit; open the PR (do not merge)**

Run: `bash tests/run-all.sh 2>&1 | tail -1` → `ALL GREEN`.

```bash
git add -A STANDARD.md docs/ _template/ bin/ tests/ .claude-plugin .codex-plugin gemini-extension.json
git commit -m "docs: Agent Standard 6.0 — accepted instruction-only invariants, n8n-wrapped tools"
git push -u origin feat/standard-6
gh pr create --title "Agent Standard 6.0: accepted invariants, n8n-wrapped tools" --body "Part A of docs/superpowers/specs/2026-10-01-outbound-enrollment-design.md. Merge together with sales-partner 6.0.0 (Part B).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
