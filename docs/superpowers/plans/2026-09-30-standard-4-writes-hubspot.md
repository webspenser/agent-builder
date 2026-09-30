# Agent Standard 4.0 (`writes`, tool setup choices) and the HubSpot tool: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- Replace the guard policy's `create_tools`, `update_tools` and `values_at` keys with a single `writes:` list.
- Require a `## Setup` section on every tool that ships a `bootstrap.py`, and have setup offer two ways to create missing fields.
- Ship Agent Standard 4.0 (builder 4.0.0) and sales-partner 4.0.0, including a new HubSpot CRM tool.

**Architecture:**
- `guard_policy.py` tags each value map with the kind of the `writes` entry that found it. That lets one tool, such as HubSpot's `manage_crm_objects`, carry both creates and updates.
- `tool_check.py` gains one rule. The setup skill's tools step gains the two-choice field setup.
- sales-partner converts its three policies to `writes`, adds Setup sections, and adds `capabilities/crm/tools/hubspot/`.

**Tech Stack:** bash, Python 3 (stdlib only), Markdown skills, the claude.ai HubSpot connector (MCP), HubSpot CRM properties API (bootstrap only).

**Spec:** `docs/superpowers/specs/2026-09-30-standard-4-writes-hubspot-design.md`

## Global Constraints

- **No backward compatibility (development-phase policy).**
  - The validator accepts only `standard: "4.0"`.
  - The old guard keys `create_tools`, `update_tools` and `values_at` are a `PolicyError` with this message: `<key> is the Agent Standard 3 form; 4.0 uses writes: (see STANDARD.md "Guard policy")`.
- **Hooks.** Every file in `hooks/` is byte-identical to `_template/hooks/` in every agent. Scripts are 755; `hooks.json` is 644.
- **Skills.** `skills/add-tool` and `skills/schedule` are byte-identical copies.
- **Failure behavior.** Hooks fail closed and never produce a traceback. Checkers exit 0 for OK, 1 for FAIL, 2 for ERROR.
- **API keys never enter the chat or any file.** Skills tell the user to run `bootstrap.py` in their own terminal, with the key set only in that terminal's environment. `bootstrap.py` never prints the key.
- **Versions.** Builder 4.0.0, sales-partner 4.0.0, action tag `v4`. `v3` stays where it is.
- **Commit trailer.** Every commit ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Off limits.** Never touch `~/Work/Webspenser/live-agents`.

## Review Focus

1. **One call carrying both a create and an update.** A `manage_crm_objects` call with both `createRequest` (at `approved`) and `updateRequest` (harmless) must block. Test: Task 1.
2. **Values at a path no entry lists.** If the tool matches no entry and `unknown_writes: block` is set, the call is blocked. If the tool matches an entry but uses an unlisted sibling path, the values go unchecked. That limit is stated in STANDARD. Test: Task 1, both halves.
3. **`"true"` and `true`.** A string `"true"` and a JSON boolean `true` both satisfy `update: ["true"]`. `"false"` and `false` both block. Test: Task 1.
4. **Old keys left in a custom tool's `guard.yaml` after the upgrade.** The guard blocks calls to that tool with the migration message, and the schedule gate FAILs. Test: Task 2 (guard), Task 2 (schedule_check).
5. **The key never echoed.** `bootstrap.py` never prints `HUBSPOT_TOKEN`'s value. Skill text never asks for the key in chat. Test: Task 5 (grep plus a run with a fake token), Task 3 (skill text grep).

---

### Task 1: `writes:` in the guard-policy engine

**Files:**
- Modify: `_template/hooks/guard_policy.py` (the `KEYS`/`LIST_KEYS`/`RULE_KEYS` constants, `_parse_rules`, `_validate`, `parse`, `problems`)
- Modify: `tests/test-guard-policy.sh`, `tests/test-guard.sh` (fixtures at lines ~15 and ~101), `_capability-template/tools/example-provider/guard.yaml`

**Interfaces:**
- Produces:
  - `guard_policy.parse(text) -> dict` with `policy["writes"]` as a `list[dict]` with keys `kind` (`"create"` or `"update"`), `tools` (`list[str]`) and `at` (`list[str]`).
  - `guard_policy.problems(policy, event, bindings, server_match=None) -> list[str]`, with the same signature as today.

- [ ] **Step 1: Convert the test fixtures and add the new cases (they must fail first).**
  - In `tests/test-guard-policy.sh`, rewrite every policy that uses `create_tools`, `update_tools` or `values_at` into `writes:` entries with the same meaning.
    - `create_tools: [c]`, `update_tools: [u]` and `values_at: [v]` become the lines `'writes:' '  - kind: create' '    tools: [c]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [v]'`.
    - Keep every existing expectation. Only the parse-error cases that named the old keys change their wording: "rules without writes", and "bad at path".
  - Add before `finish`:

```bash
echo "-- writes (Agent Standard 4.0)"
policy 'covers: [x]' 'create_tools: [c]';             parses 1 "create_tools is the old form"
policy 'covers: [x]' 'values_at: [v]';                parses 1 "values_at is the old form"
policy 'covers: [x]' 'writes:' '  - kind: delete' '    tools: [t]' '    at: [v]'; parses 1 "kind must be create or update"
policy 'covers: [x]' 'writes:' '  - kind: create' '    at: [v]';                    parses 1 "writes entry needs tools"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [t]' '    at: ["bad path!"]'; parses 1 "writes at must be a path"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [t]' '    at: [v]' '    extra: [y]'; parses 1 "unknown writes key"
policy 'covers: [x]' 'rules:' '  - field: s' '    any: [a]';                          parses 1 "rules need writes"
out=$(printf '%s\n' 'covers: [x]' 'update_tools: [u]' > "$W/old.yaml"; python3 "$E" --check "$W/old.yaml" 2>&1)
printf '%s' "$out" | grep -qF 'update_tools is the Agent Standard 3 form; 4.0 uses writes:' && _report ok "old-key message names writes" || _report no "old-key message: $out"

H() { policy 'covers: [draft_only, dnc_one_way]' 'allow: [manage_crm_objects, get_*]' 'deny: ["*delete*"]' \
  'writes:' '  - kind: create' '    tools: [manage_crm_objects]' '    at: ["createRequest.objects[].properties"]' \
  '  - kind: update' '    tools: [manage_crm_objects]' '    at: ["updateRequest.objects[].properties"]' \
  "unknown_writes: ${1:-block}" 'rules:' '  - field: sp_status' '    create: [draft]' '    update: [voided]' \
  '  - field: sp_do_not_contact' '    update: ["true"]'; }
T=mcp__claude_ai_HubSpot__manage_crm_objects
H; parses 0 "hubspot-shaped policy parses"
run 0 "create at draft allowed" $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"sp_status":"draft"}}]}}'
run 2 "create at sent blocked" $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"sp_status":"sent"}}]}}' "sp_status may only be written as draft on create"
run 0 "update to voided allowed" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"voided"}}]}}'
run 2 "update to approved blocked" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"approved"}}]}}' "on update"
run 2 "create draft is not an allowed update" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"draft"}}]}}'
run 2 "both kinds in one call: bad create next to harmless update blocks" $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"sp_status":"approved"}}]},"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"voided"}}]}}' "on create"
run 0 "dnc set to string true" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":"true"}}]}}'
run 0 "dnc set to boolean true" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":true}}]}}'
run 2 "dnc cleared (string) blocked" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":"false"}}]}}'
run 2 "dnc cleared (boolean) blocked" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":false}}]}}'
run 0 "association-only update (no properties) allowed" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"associations":[{"targetObjectId":2,"targetObjectType":"companies"}]}]}}'
run 2 "delete denied" mcp__claude_ai_HubSpot__delete_records '{}' "denied"
run 2 "unmatched tool writing at a listed path, unknown_writes: block" mcp__claude_ai_HubSpot__get_thing '{"createRequest":{"objects":[{"properties":{"sp_status":"draft"}}]}}' "not a known create or update tool"
H update
run 2 "unmatched tool at a listed path, unknown_writes: update checks as update" mcp__claude_ai_HubSpot__get_thing '{"createRequest":{"objects":[{"properties":{"sp_status":"draft"}}]}}' "on update"
H
run 0 "stated limit: matched tool, unlisted sibling path is not checked" $T '{"upsertRequest":{"objects":[{"properties":{"sp_status":"sent"}}]}}'
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `tests/test-guard-policy.sh`. Expect FAIL lines, because the engine doesn't know `writes`.

- [ ] **Step 3: Implement `writes` in `_template/hooks/guard_policy.py`.**
  - Constants:

```python
KEYS = ("covers", "allow", "deny", "writes", "unwrap", "unknown_writes", "refuse_keys", "rules")
LIST_KEYS = ("covers", "allow", "deny", "unwrap", "refuse_keys")
OLD_KEYS = ("create_tools", "update_tools", "values_at")
RULE_KEYS = ("field", "binding_id", "create", "update", "any")
WRITE_KEYS = ("kind", "tools", "at")
```

  - Generalize `_parse_rules(lines, i)` into `_parse_items(lines, i, name, allowed)`, with the same body.
    - Replace `rules` with a local `items`, and `RULE_KEYS` with `allowed`.
    - Messages use `name`: `f"line {lineno}: {name} items are '  - key: value' with further keys indented 4 spaces"`, `f"line {lineno}: unknown {name} key '{key}'"`, `f"line {lineno}: duplicate {name} key '{key}'"` and `f"{name}: has no items"`.
  - In `parse`, just after `key` and `value` are read:

```python
        if key in OLD_KEYS:
            raise PolicyError(f'{key} is the Agent Standard 3 form; 4.0 uses writes: (see STANDARD.md "Guard policy")')
```

    and replace the `if key == "rules":` block with:

```python
        if key in ("rules", "writes"):
            if value:
                raise PolicyError(f"line {lineno}: {key}: takes '  - ...' items on the following lines")
            policy[key], i = _parse_items(lines, i, key, RULE_KEYS if key == "rules" else WRITE_KEYS)
            continue
```

  - In `_validate`:
    - Delete the `values_at` path loop.
    - Delete `create_tools`/`update_tools` from the empty-entry loop, leaving `("allow", "deny", "unwrap")`.
    - Delete the two `values_at`-required checks.
    - Delete the `for key in ("create_tools", "update_tools", "values_at")` block.
    - Add:

```python
    for entry in policy.get("writes", []):
        if entry.get("kind") not in ("create", "update"):
            raise PolicyError("writes: kind must be create or update")
        for k in ("tools", "at"):
            if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
                raise PolicyError(f"writes: each entry needs a non-empty {k} list")
        for path in entry["at"]:
            if not PATH.match(path):
                raise PolicyError(f"writes: {path} is not a path like values or \"records[].fields\"")
    if ("rules" in policy or "refuse_keys" in policy) and not policy.get("writes"):
        raise PolicyError("writes is required when rules or refuse_keys are present")
```

  - In `problems`, replace everything from `if _matches(names, policy.get("create_tools", [])):` through the line `kind = "update"` (the unknown-writes fallback) with:

```python
    writes = policy.get("writes", [])
    matched = [w for w in writes if _matches(names, w["tools"])]
    args = event.get("tool_input")
    if not isinstance(args, dict):
        if matched:
            raise PolicyError("tool_input is not an object")
        return []
    tagged = [(w["kind"], m) for w in matched for path in w["at"] for m in _maps_at(args, path)]
    if not matched:
        loose = [m for w in writes for path in w["at"] for m in _maps_at(args, path)]
        if not loose:
            return []
        if policy.get("unknown_writes", "update") == "block":
            return [f"{shown} writes values but is not a known create or update tool"]
        tagged = [("update", m) for m in loose]
```

    Then change the loop header `for amap in maps:` to `for kind, amap in tagged:`. The rule check inside the loop (`allowed = rule.get(kind) or rule.get("any")`) stays as it is, and now uses the per-map kind.
  - Update the module docstring's policy-format mention to name `writes`.

- [ ] **Step 4: Convert the other fixtures.**
  - `tests/test-guard.sh`, lines ~15 and ~101: rewrite `'create_tools: [add-entry]' 'update_tools: [update-entry]' 'values_at: [values]'` as the equivalent `writes:` lines. The create entry is `tools: [add-entry]` and the update entry is `tools: [update-entry]`, both with `at: [values]`.
  - `_capability-template/tools/example-provider/guard.yaml`: replace its three keys with:

```yaml
writes:
  - kind: create
    tools: [create-thing]
    at: [values]
  - kind: update
    tools: [update-thing]
    at: [values]
```

- [ ] **Step 5: Run all the tests.** Run `tests/test-guard-policy.sh && tests/test-guard.sh && tests/test-tool-check.sh`, then `tests/run-all.sh`. Expect 0 failed, then `ALL GREEN`. The validator tests' fixtures build guard policies too; convert any that use the old keys, in the same way.

- [ ] **Step 6: Commit.**

```bash
git add -A
git commit -m "feat: guard policy writes: replaces create_tools, update_tools and values_at"
```

---

### Task 2: Standard 4.0 in the validator, `tool_check` Setup rule, and old keys failing closed

**Files:**
- Modify: `_template/hooks/tool_check.py`, `bin/lib/check_manifests.py` (`CURRENT_STANDARD`), `_template/agent.yaml`, the builder manifests, `tests/test-tool-check.sh`, `tests/test-validate-agent.sh`, `tests/test-guard.sh`, `tests/test-schedule-check.sh`, `tests/test-builder-manifests.sh`, `tests/run-all.sh`

**Interfaces:**
- Consumes: Task 1's `guard_policy.parse`, which raises `PolicyError` on the old keys.

- [ ] **Step 1: Write the failing tests.**
  - `tests/test-tool-check.sh`, before `finish`:

```bash
echo "-- Setup section (Agent Standard 4.0)"
fresh; printf '%s\n' '# bootstrap' > "$T/bootstrap.py"; run "$T" "$C/contract.md"
expect 1 "bootstrap.py without ## Setup" "needs a ## Setup section (bootstrap.py is optional; people must be able to create the fields by hand)"
printf '%s\n' '## Setup' '' 'Create field status.' >> "$T/usage.md"; run "$T" "$C/contract.md"; expect 0 "bootstrap.py with ## Setup"
rm "$T/bootstrap.py"; fresh; run "$T" "$C/contract.md";      expect 0 "no bootstrap.py: Setup not required"
fresh; printf '%s\n' 'covers: [draft_only]' 'values_at: [v]' > "$T/guard.yaml"; run "$T" "$C/contract.md"
expect 1 "old guard key fails tool_check" "values_at is the Agent Standard 3 form"
```

  - `tests/test-guard.sh`, before `finish`: a custom tool whose `guard.yaml` still uses `create_tools` must block its calls.

```bash
echo "-- 4.0 old guard keys"
O4="$W/old4"; mkdir -p "$O4/custom-tools/crm"
printf '%s\n' 'agent: demo-agent' 'mode: plugin' 'bind_crm: custom' > "$O4/instance.yaml"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: democrm' > "$O4/custom-tools/crm/identity.yaml"
printf '%s\n' 'covers: [draft_only]' 'create_tools: [add-entry]' > "$O4/custom-tools/crm/guard.yaml"
run_guard "$O4" "$(call mcp__democrm__list-records)";  expect 2 "old guard keys in a custom tool: blocked" "Agent Standard 3 form"
```

  - `tests/test-schedule-check.sh`, before `finish`: an instance bound to a custom tool whose `guard.yaml` uses `update_tools`. It must fail with rc 1, and the output must include `Agent Standard 3 form`. Build it with the file's existing `instance` helper and custom-tool fixture style, including `usage.md`.
  - `tests/test-validate-agent.sh`:
    - `make_valid_agent` writes `standard: "4.0"`, and its fixture `guard.yaml` uses `writes:`.
    - The old-standard case rejects `"3.0"`, with `agent.yaml: standard '3.0' is not 4.0; update the agent to the current Agent Standard`.
  - `tests/test-builder-manifests.sh` expects `4.0.0`. `tests/run-all.sh` checks `^standard: "4.0"`, labelled "template is Agent Standard 4.0".

- [ ] **Step 2: Run the tests and confirm they fail.** Run `tests/run-all.sh`. Expect FAILURES ABOVE.

- [ ] **Step 3: Implement.**
  - `_template/hooks/tool_check.py`: in `check_tool`, after the `usage.md` block, where `text` is available:

```python
    if (folder / "bootstrap.py").exists() and usage.is_file():
        try:
            has_setup = section(read(usage), "Setup") is not None
        except ToolError:
            has_setup = True  # the unreadable usage.md is already reported
        if not has_setup:
            fails.append(f"{label}/usage.md: needs a ## Setup section "
                         "(bootstrap.py is optional; people must be able to create the fields by hand)")
```

  - `bin/lib/check_manifests.py`: set `CURRENT_STANDARD = "4.0"`.
  - `_template/agent.yaml`: `standard: "4.0"`.
  - Builder manifests: set the version to `4.0.0`.
  - `guard.sh` and `schedule_check.py` need no code change: they already fail closed on a `PolicyError`. Confirm this with the new tests. If `schedule_check`'s message doesn't carry the engine's text, pass it through.

- [ ] **Step 4: Run.** Run `tests/run-all.sh` and expect `ALL GREEN`. Also check that `find . -name __pycache__ -not -path './.git/*'` prints nothing.

- [ ] **Step 5: Commit.**

```bash
git add -A
git commit -m "feat: Agent Standard 4.0 — validator, tool_check Setup rule; old guard keys fail closed"
```

---

### Task 3: The setup skill's two choices, STANDARD and docs

**Files:**
- Modify: `_template/skills/setup/SKILL.md` (steps 1 and 9), `STANDARD.md`, `skills/new-agent/SKILL.md`, `docs/writing-an-agent.md`, `docs/how-it-works.md`, `README.md`, `tests/run-all.sh`

- [ ] **Step 1: Write the failing text checks.** Append to `tests/run-all.sh` before the status line:

```bash
echo "== Agent Standard 4.0 text"
for want in 'Create them yourself' 'Use an API key' 'your own terminal' '## Setup'; do
  grep -qF -- "$want" _template/skills/setup/SKILL.md || { echo "FAIL: setup does not say: $want"; STATUS=1; }
done
if grep -rniE 'paste (the|your) (api )?key|give us your (api )?key' _template/skills skills; then echo "FAIL: a skill asks for a key in chat"; STATUS=1; fi
if grep -rnE 'create_tools|update_tools|values_at' STANDARD.md docs/how-it-works.md docs/writing-an-agent.md skills _template _capability-template | grep -v 'Agent Standard 3' | grep -q .; then
  echo "FAIL: old guard keys outside Agent Standard 3 notes"; STATUS=1; fi
grep -qF 'validate@v4' README.md || { echo "FAIL: README does not use validate@v4"; STATUS=1; }
```

  Run it and confirm it fails.

- [ ] **Step 2: Setup skill** (`_template/skills/setup/SKILL.md`).
  - **Step 1 (Welcome):** add this sentence: "You'll connect each system this agent uses to your host (Claude, Gemini, Codex …). Some systems need fields created: you can create them yourself from a list, or run a script with an API key in your own terminal."
  - **Step 9 (Tools):** replace the probe sub-step ("Run the tool's `usage.md` `## Probe` calls. They only read. On failure, say what failed and leave the capability unbound.") with this text:

```markdown
   3. Run the tool's `usage.md` `## Probe` calls. They only read. If they
      fail because fields or objects are missing and the tool's `usage.md`
      has a `## Setup` section, offer two choices:
      - **Create them yourself.** Show the `## Setup` list (each field with
        its object, type, and options) as plain steps in that system. When
        the user says it is done, run the probe again.
      - **Use an API key.** Only when the tool has a `bootstrap.py`. Show the
        exact command, `python3 <package>/capabilities/<capability>/tools/<tool>/bootstrap.py`,
        and the environment variable and key scopes from `## Setup`. Tell the
        user to run it in **your own terminal** with the key set only in
        that terminal's environment, and never to paste the key into this
        conversation or any file. When they say it is done, run the probe
        again.
      Any other probe failure: say what failed and leave the capability
      unbound. Bind only after the probe passes. Write what the probe found
      to `bindings/<capability>.md` in the instance, including any
      `field_<name>: <id>` lines the probe records. Write each as a plain
      line, `field_<name>: <ID>`, with nothing else on it: no bullet, no
      backticks or quotes, no trailing note. Anything else blocks the
      guarded call.
```

    Keep the existing binding-lines rules. They are restated above, so remove any duplicate.

- [ ] **Step 3: `STANDARD.md`.**
  - "The standard is 4.0".
  - **Guard policy section:** the `writes:` format and its semantics, from the spec's "The `writes:` guard policy key" (the example, the numbered semantics, the parse errors). Include the stated limit: when a tool matches an entry but uses an unlisted path, its values go unchecked, and the allow and deny lists are the backstop. Delete the `create_tools`, `update_tools` and `values_at` text.
  - **Tools section:** `## Setup` is required when `bootstrap.py` exists, and `bootstrap.py` stays optional.
  - **"Setup — tools step":** the two choices, and the rule that keys never enter the chat.
  - **Validation list:** `standard: "4.0"` and the Setup rule.
  - **CI snippet:** `validate@v4`.
  - **New `## Changes from 3.0`:** `writes`, the Setup rule, and the two setup choices. Old key names may appear only on lines that also say "Agent Standard 3".
  - Replace the Attio example policy with its `writes:` form.

- [ ] **Step 4: Docs.**
  - `docs/how-it-works.md`:
    - "Current: **Agent Standard 4.0**. Agent Builder 4.0.0, sales-partner 4.0.0."
    - In the guard diagram, the create/update node says "writes: kind by tool and path".
    - In the journey section, add that the tools step creates fields by hand or with an API key.
    - Add HubSpot wherever the CRMs are listed (Attio, Airtable, HubSpot).
  - `docs/writing-an-agent.md` and the wizard: switch to the `writes` vocabulary, and state the Setup rule.
  - `README.md`: `validate@v4` and "Agent Standard 4.0".

- [ ] **Step 5: Run.** Run `tests/run-all.sh` and expect `ALL GREEN`.

- [ ] **Step 6: Commit and push.**

```bash
git add -A
git commit -m "feat: setup offers two ways to create tool fields; Agent Standard 4.0 docs"
git push -u origin feat/standard-4.0
```

---

### Task 4: sales-partner 4.0.0, converting the existing tools

**Repository:** `/Users/hochoy/Work/Webspenser/sales-partner`. Create branch `release/4.0.0` from `main`.

**Files:**
- Modify: `capabilities/crm/tools/attio/guard.yaml`, `capabilities/crm/tools/airtable/guard.yaml`, `capabilities/email_drafts/tools/gmail/guard.yaml` (only if it uses the old keys), `capabilities/crm/tools/attio/usage.md` and `capabilities/crm/tools/airtable/usage.md` (new `## Setup` sections), `skills/setup/SKILL.md` (step 1 and step 9 ported by hand), `agent.yaml`, the four host manifests, `.github/workflows/*.yml`, `tests/*.sh`, `README.md`
- Copy byte-identical from the builder: `hooks/*` (all six) and `skills/add-tool/SKILL.md`, `skills/schedule/SKILL.md`
- Create: `migrations/4.0.0.md`

- [ ] **Step 1: Branch, then convert the policies.**
  - Attio `guard.yaml`: replace the `create_tools`, `update_tools` and `values_at` lines with:

```yaml
writes:
  - kind: create
    tools: [add-record-to-list, create-record]
    at: [entry_values, values]
  - kind: update
    tools: [update-list-entry-by-id, update-list-entry-by-record-id,
            update-record, upsert-record]
    at: [entry_values, values]
```

  - Airtable `guard.yaml`:

```yaml
writes:
  - kind: create
    tools: [create_records_for_table]
    at: ["records[].fields"]
  - kind: update
    tools: [update_records_for_table]
    at: ["records[].fields"]
```

  - Gmail: check whether it uses any old key. If it does, convert it the same way; if not, leave it.
  - Run `tests/test-policies.sh`. Every existing case must still pass unchanged. That is the proof the conversion kept the same behavior.

- [ ] **Step 2: Setup sections.**
  - Attio `usage.md` gets `## Setup` covering:
    - every object, list and attribute `bootstrap.py` creates, taken from its `LISTS`, `STAGES` and people-attribute definitions, with type and options, as steps in Attio;
    - then the script route: `ATTIO_API_KEY`, scopes `object_configuration, list_configuration, record_permission, list_entry` (all read-write), and the command.

    The Probe's "offer the schema script" sentence becomes "offer the two choices in `## Setup`".
  - Airtable `usage.md` gets `## Setup` with the tables and fields the Probe expects (tables Leads, Contacts, Research, Activities, with their fields and options, from the existing text), as steps in Airtable. There is no script route.

- [ ] **Step 3: Copy the reference files and port setup.**

```bash
B=/Users/hochoy/Work/Webspenser/agent-library
cp "$B"/_template/hooks/{hooks.json,session-start.sh,guard.sh,guard_policy.py,schedule_check.py,tool_check.py} hooks/
chmod 755 hooks/*.sh hooks/*.py; chmod 644 hooks/hooks.json
cp "$B/_template/skills/add-tool/SKILL.md" skills/add-tool/; cp "$B/_template/skills/schedule/SKILL.md" skills/schedule/
```

  In `skills/setup/SKILL.md`, port only the step 1 sentence and the step 9 probe sub-step from the builder template, by hand.

- [ ] **Step 4: Version, CI and migration.**
  - `agent.yaml`: `version: 4.0.0`, `standard: "4.0"`.
  - The four manifests: `4.0.0`.
  - The workflow: `validate@v4` in both steps.
  - `tests/test-schedules.sh`: `agent_version: 4.0.0`.
  - `tests/test-content.sh`: `migrations/` holds `3.0.0.md` and `4.0.0.md`.
  - Create `migrations/4.0.0.md`:

```markdown
# 4.0.0 — Agent Standard 4.0

Guard policies describe writes with one `writes:` list. For an instance, only
a custom tool's `guard.yaml` can be affected:

- If `custom-tools/<capability>/guard.yaml` uses `create_tools`,
  `update_tools`, or `values_at` (the Agent Standard 3 form), rewrite them as
  `writes:` entries (see the Agent Standard, "Guard policy"): one
  `kind: create` entry with the create tools and the value paths, one
  `kind: update` entry with the update tools and the same paths. Show the user
  the diff, apply it after they confirm, then check the tool:
  `python3 <package>/hooks/tool_check.py custom-tools/<capability> <package>/capabilities/<capability>/contract.md --custom`.
- Nothing else changes: bindings, `bindings/`, `context/`, and
  `schedules.yaml` stay as they are.

Until this is done, the guard blocks calls to that custom tool.
```

- [ ] **Step 5: Verify.**

```bash
tests/run-all.sh
/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .
for f in hooks.json session-start.sh guard.sh guard_policy.py schedule_check.py tool_check.py; do cmp "hooks/$f" "/Users/hochoy/Work/Webspenser/agent-library/_template/hooks/$f"; done
cmp skills/add-tool/SKILL.md /Users/hochoy/Work/Webspenser/agent-library/_template/skills/add-tool/SKILL.md
cmp skills/schedule/SKILL.md /Users/hochoy/Work/Webspenser/agent-library/_template/skills/schedule/SKILL.md
for t in capabilities/*/tools/*/; do c=${t%/tools/*}; python3 -B hooks/tool_check.py "$t" "$c/contract.md"; done
```

  Expected output:
  - `ALL GREEN`;
  - `OK: . conforms` (the known AGENT.md size WARN is allowed);
  - no `cmp` output;
  - `OK:` for attio, airtable and gmail.

- [ ] **Step 6: Commit and push.**

```bash
git add -A
git commit -m "feat: sales-partner 4.0.0 — guard policies use writes:, tool Setup sections"
git push -u origin release/4.0.0
```

---

### Task 5: The HubSpot tool (built with add-tool in package mode)

**Repository:** sales-partner, branch `release/4.0.0`.

**Files:**
- Create: `capabilities/crm/tools/hubspot/identity.yaml`, `usage.md`, `guard.yaml`, `bootstrap.py` (755)
- Modify: `tests/test-policies.sh` (HubSpot cases), `tests/test-content.sh` (only if it enumerates tools), `README.md` (CRMs list), and any skill that lists supported CRMs

**Interfaces:**
- Consumes: Task 1's `writes` semantics. Task 4's copied hooks and `add-tool` skill.

- [ ] **Step 1: Follow `skills/add-tool/SKILL.md` for the package target.** Use capability `crm` and tool `hubspot`. Use the live claude.ai HubSpot connector (`mcp__claude_ai_HubSpot__*`), and only read-only calls: `get_user_details`, `discover_hubspot_schema`, `get_properties`, `search_properties`, `tool_guidance`. Record the connector's real read-tool names, the argument shapes of `manage_crm_objects`, `search_crm_objects` and `get_crm_objects`, and the native property names: company address fields, contact LinkedIn field, task subject, body and timestamp.

- [ ] **Step 2: `identity.yaml`.**

```yaml
capability: crm
provider: hubspot
server_match: hubspot
```

- [ ] **Step 3: `guard.yaml`.** This is the spec's policy exactly, with the allow list checked against the real read-tool names from Step 1. Every name must exist on the connector. Drop any that don't, and list what you dropped in the report.

```yaml
# HubSpot guard policy: every write goes through manage_crm_objects;
# creates sit under createRequest, updates under updateRequest.
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

- [ ] **Step 4: `bootstrap.py`.** Write this file, make it mode 755, and confirm the scope names against HubSpot's docs with `npx ctx7@latest docs /websites/developers_hubspot "private app scopes for creating custom properties on companies contacts tasks"`. Correct `SCOPES` if the docs differ.

```python
#!/usr/bin/env python3
"""Create the HubSpot properties usage.md describes (see its ## Setup).

Idempotent: every property group, property, and dropdown option is created
only if missing. Nothing is ever deleted or renamed.

Reads HUBSPOT_TOKEN (a private app access token) from the environment. Set it
in your own terminal only — never in a file, never in a chat. Required
scopes are listed in SCOPES.

    python3 capabilities/crm/tools/hubspot/bootstrap.py
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = "https://api.hubapi.com/crm/v3/properties"
GROUP = "sales_partner"
SCOPES = ["crm.schemas.companies.read", "crm.schemas.companies.write",
          "crm.schemas.contacts.read", "crm.schemas.contacts.write",
          "crm.objects.companies.read", "crm.objects.contacts.read"]

STAGES = ["New", "Scored", "Researched", "Approach Drafted", "Contacted", "Replied",
          "Call Scheduled", "Call Held", "Following Up", "Won", "Lost", "Disqualified"]


def opts(values):
    return [{"label": v, "value": v, "displayOrder": i} for i, v in enumerate(values)]


YESNO = [{"label": "Yes", "value": "true", "displayOrder": 0},
         {"label": "No", "value": "false", "displayOrder": 1}]


def prop(name, label, type_, field, options=None):
    p = {"name": name, "label": label, "type": type_, "fieldType": field, "groupName": GROUP}
    if options is not None:
        p["options"] = options
    return p


PROPERTIES = {
    "companies": [
        prop("sp_stage", "Sales Partner stage", "enumeration", "select", opts(STAGES)),
        prop("sp_stage_changed_at", "Stage changed at", "datetime", "date"),
        prop("sp_stage_reason", "Stage reason", "string", "textarea"),
        prop("sp_score", "Score", "number", "number"),
        prop("sp_score_breakdown", "Score breakdown", "string", "textarea"),
        prop("sp_industry", "Industry (Sales Partner)", "string", "text"),
        prop("sp_size", "Size", "string", "text"),
        prop("sp_location", "Location", "string", "text"),
        prop("sp_source", "Source", "string", "text"),
        prop("sp_source_url", "Source URL", "string", "text"),
        prop("sp_email", "General inbox", "string", "text"),
        prop("sp_next_action", "Next action", "string", "text"),
        prop("sp_next_action_due", "Next action due", "date", "date"),
        prop("sp_do_not_contact", "Do not contact", "bool", "booleancheckbox", YESNO),
    ],
    "contacts": [
        prop("sp_role", "Sales role", "enumeration", "select",
             opts(["decision-maker", "influencer", "gatekeeper"])),
        prop("sp_verified", "Contact verified", "bool", "booleancheckbox", YESNO),
        prop("sp_notes", "Contact notes", "string", "textarea"),
    ],
    "tasks": [
        prop("sp_status", "Outreach status", "enumeration", "select",
             opts(["draft", "approved", "sent", "voided"])),
        prop("sp_channel", "Channel", "enumeration", "select", opts(["email", "linkedin", "call"])),
        prop("sp_direction", "Direction", "enumeration", "select", opts(["outbound", "inbound"])),
        prop("sp_summary", "Summary", "string", "textarea"),
        prop("sp_outcome", "Outcome", "string", "textarea"),
    ],
}


class Stop(Exception):
    """A problem the operator must fix; printed without a traceback."""


def call(token, method, path, body=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        try:
            detail = json.loads(err.read() or b"{}").get("message", "")
        except ValueError:
            detail = ""
        return err.code, {"message": detail}
    except urllib.error.URLError as err:
        raise Stop(f"cannot reach HubSpot: {err.reason}")


def ensure(token, obj):
    status, _ = call(token, "GET", f"/{obj}/groups/{GROUP}")
    if status == 404:
        status, body = call(token, "POST", f"/{obj}/groups", {"name": GROUP, "label": "Sales Partner"})
        if status >= 300:
            raise Stop(f"{obj}: cannot create property group {GROUP}: HTTP {status} {body.get('message', '')}")
        print(f"created group {obj}.{GROUP}")
    elif status >= 300:
        raise Stop(f"{obj}: cannot read property groups: HTTP {status} (check the token's scopes: {', '.join(SCOPES)})")
    for p in PROPERTIES[obj]:
        status, have = call(token, "GET", f"/{obj}/{p['name']}")
        if status == 404:
            status, body = call(token, "POST", f"/{obj}", p)
            if status >= 300:
                raise Stop(f"{obj}.{p['name']}: HubSpot refused the property: HTTP {status} {body.get('message', '')}")
            print(f"created {obj}.{p['name']}")
        elif status >= 300:
            raise Stop(f"{obj}.{p['name']}: cannot read it: HTTP {status} {have.get('message', '')}")
        elif "options" in p and p["type"] == "enumeration":
            existing = {o.get("value") for o in have.get("options", [])}
            missing = [o for o in p["options"] if o["value"] not in existing]
            if missing:
                merged = have.get("options", []) + missing
                status, body = call(token, "PATCH", f"/{obj}/{p['name']}", {"options": merged})
                if status >= 300:
                    raise Stop(f"{obj}.{p['name']}: cannot add options: HTTP {status} {body.get('message', '')}")
                print(f"added {len(missing)} option(s) to {obj}.{p['name']}")


def main():
    token = os.environ.get("HUBSPOT_TOKEN", "").strip()
    if not token:
        print("HUBSPOT_TOKEN is not set. Create a HubSpot private app with these scopes:\n  "
              + "\n  ".join(SCOPES)
              + "\nthen, in this terminal only: export HUBSPOT_TOKEN=<token> and run this again.",
              file=sys.stderr)
        return 2
    try:
        for obj in PROPERTIES:
            ensure(token, obj)
    except Stop as err:
        print(f"stopped: {err}", file=sys.stderr)
        return 1
    print("done: every Sales Partner property exists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

  If the scope check shows task-property scopes are needed (for example `crm.schemas.custom.write` or a tasks-specific scope), add them to `SCOPES` and to `## Setup`.

- [ ] **Step 5: `usage.md`.** Write it following the Attio `usage.md` structure. It must contain:
  - A title, and one paragraph on the data model from the spec's Part B table: Company = lead, Contact, Note = research, Task = activity.
  - **The approval queue:** the Tasks view where `sp_status = draft`. **Pipeline:** a Companies view grouped by `sp_stage`.
  - **The `confirmationStatus` rule, verbatim:** "Interactive runs: follow the connector's confirmation step — on the first write show the change table and offer to skip confirmations for the session. Scheduled runs (the prompt starts `Scheduled run of`): pass `confirmationStatus: CONFIRMATION_WAIVED_FOR_SESSION`; the guard enforces the invariants."
  - The limit: at most 10 objects per `manage_crm_objects` request.
  - One subsection per contract operation, each naming it in backticks: `create_lead`, `get_lead`, `update_stage`, `update_lead`, `log_activity`, `update_activity`, `log_research`, `upsert_contact`, `query_by_stage`, `query_by_score`, `query_activities`. Each gives the exact tool call and argument shape, with filters for `search_crm_objects` and `createRequest`/`updateRequest` for writes. Keep the contract's rules:
    - dedupe order;
    - Stage `New` plus the stamp on create;
    - `update_stage` writes `sp_stage` and `sp_stage_changed_at` in one update;
    - `log_activity` is create-only at `sp_status: draft`, associated to the company and contact, and refuses outbound when the company's `sp_do_not_contact` is `true`;
    - `update_activity` writes only `voided`;
    - `upsert_contact` matches on email, then on name plus title.

    Stage values are the option values in `bootstrap.py`'s `STAGES`.
  - `## Probe`, as in the spec: `get_user_details` records `hub_id:`, then `get_properties` checks. `bindings/crm.md` lines: `hub_id: <id>`.
  - `## Setup`:
    - one table per object (companies, contacts, tasks), listing internal name, label, type and options, exactly matching `PROPERTIES` in `bootstrap.py`, with "Settings → Properties → Create property" steps and the group "Sales Partner";
    - then "Or with an API key": the private app, `SCOPES`, `export HUBSPOT_TOKEN=…` in your own terminal, and the command.

- [ ] **Step 6: Tests in `tests/test-policies.sh`.** Add HubSpot cases against the shipped `capabilities/crm/tools/hubspot/guard.yaml`, using the file's existing helper style and the tool name `mcp__claude_ai_HubSpot__manage_crm_objects`. The cases:
  - a create at draft is allowed;
  - a create at sent is blocked;
  - an update to voided is allowed;
  - an update to approved is blocked;
  - both kinds in one call, with a bad create, are blocked;
  - `sp_do_not_contact` set to `"true"` or `true` is allowed;
  - `sp_do_not_contact` set to `"false"` or `false` is blocked;
  - `mcp__claude_ai_HubSpot__manage_custom_properties` is blocked (not on the allow list);
  - `mcp__claude_ai_HubSpot__manage_marketing_email` is blocked;
  - any `*delete*` tool is denied;
  - `search_crm_objects` is allowed.

  Then add a bootstrap safety test:

```bash
out=$(HUBSPOT_TOKEN=sk-canary-12345 python3 -B capabilities/crm/tools/hubspot/bootstrap.py 2>&1 </dev/null); \
  printf '%s' "$out" | grep -q 'sk-canary-12345' && _report no "bootstrap echoed the token" || _report ok "bootstrap never prints the token"
grep -q 'print(.*token' capabilities/crm/tools/hubspot/bootstrap.py && _report no "bootstrap prints a token variable" || _report ok "no print of the token"
```

  The run with a fake token fails on the network or with HTTP 401. That's expected; only the token check matters.

- [ ] **Step 7: README and CRM lists.** The README names HubSpot next to Attio and Airtable, with the two setup choices. Grep `skills/`, `subagents/`, `AGENT.md` and `context/` for lists of the form "Attio or Airtable", and add HubSpot to each.

- [ ] **Step 8: Verify.** Run `tests/run-all.sh` and the builder validator on `.`. `python3 -B hooks/tool_check.py capabilities/crm/tools/hubspot capabilities/crm/contract.md` must print `OK:`.

- [ ] **Step 9: Commit and push.**

```bash
git add -A
git commit -m "feat: HubSpot CRM tool (Company leads, Task drafts), guarded by writes:"
git push
```

---

### Task 6: Release and acceptance (controller and user)

- [ ] **Step 1:** Open PR `feat/standard-4.0` → `main` in agent-builder. The spec and plan branch is included. The user merges it with a merge commit.
- [ ] **Step 2:** The user creates the new tag: `! git -C ~/Work/Webspenser/agent-library fetch origin && git -C ~/Work/Webspenser/agent-library tag v4 origin/main && git -C ~/Work/Webspenser/agent-library push origin v4`
- [ ] **Step 3:** Open PR `release/4.0.0` → `main` in sales-partner. Once CI on `@v4` passes, the user merges it.
- [ ] **Step 4:** Open the catalog README PR: both agents at 4.0, `validate@v4`, and the sales-partner row naming HubSpot. The user merges it.
- [ ] **Step 5: Acceptance.** Run in the scratchpad, with the user.
  1. **Fields.** The user picks the manual route or the bootstrap route and creates the fields on their portal. The probe (`get_user_details`, `get_properties`) passes. If HubSpot refuses the task properties, stop, report it, and revisit spec decision 6.
  2. **Interactive smoke test.** On a scratch instance with HubSpot and Gmail bound, and following `usage.md`, the agent:
     - creates one test company at `sp_stage: New`;
     - upserts one contact;
     - logs one draft task.

     Show the record links.
  3. **Guard.** Pipe these calls through sales-partner's `guard.sh` with the instance:
     - task update to `approved`: expect 2;
     - task create at `sent`: expect 2;
     - `sp_do_not_contact: "false"`: expect 2;
     - `manage_custom_properties`: expect 2;
     - draft create: expect 0;
     - `voided` update: expect 0.
  4. **Schedule check.** `schedule_check check` on the instance with `schedule_digest` PASSes.
  5. **Old keys.** A `guard.yaml` with `values_at` fails `tool_check` with the "Agent Standard 3 form" message.
  6. **Cleanup.** The user deletes the test company, contact and task in HubSpot.

  Record the results.
- [ ] **Step 6:** Delete the merged branches in all three repos, and update the roadmap memory.
