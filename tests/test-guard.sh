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
run_guard "$I" "$(call mcp__democrm__purge__get-x)";             expect 2 "tool with __ cannot ride on allow" "is not in the allow list"
run_guard "$I" "$(call mcp__x__DemoCRM__get-x)";                 expect 0 "server containing __: allowed tool passes"
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
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "engine missing blocks" "Blocked by demo-agent guard policy (crm/demo): the guard policy engine is missing"
run_guard "$I" "$(call mcp__other__list-records)";               expect 0 "engine missing: other servers allowed"
mv "$W/gp.bak" "$PKG/hooks/guard_policy.py"
BIN="$W/bin"; mkdir -p "$BIN"
for t in bash cat sed head tr grep sort dirname cut; do ln -s "$(command -v "$t")" "$BIN/$t"; done
OUT=$(printf '%s' "$(call mcp__democrm__list-records)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$I" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 2 "no python3 blocks" "Blocked by demo-agent guard policy (crm/demo): python3 is required"
OUT=$(printf '%s' "$(call mcp__other__list-records)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$I" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 0 "no python3: other servers allowed"
printf '%s\n' 'covers: [draft_only]' 'allow: [list-*' > "$AD/guard.yaml"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "invalid policy blocks" "cannot check this call"
rm "$AD/guard.yaml"; mkdir "$AD/guard.yaml"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "guard.yaml as a directory blocks" "cannot check this call"
rmdir "$AD/guard.yaml"; ln -s "$W/nowhere.yaml" "$AD/guard.yaml"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "dangling guard.yaml symlink blocks" "cannot check this call"
rm "$AD/guard.yaml"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 0 "no guard.yaml: instruction-only, allowed"
write_policy
printf '%s\n' '#!/usr/bin/env python3' 'import sys' 'sys.exit(1)' > "$PKG/hooks/guard_policy.py"
run_guard "$I" "$(call mcp__democrm__list-records)";             expect 2 "engine exiting 1 blocks" "Blocked by demo-agent guard policy (crm/demo): the guard policy engine failed (exit 1)"
cp _template/hooks/guard_policy.py "$PKG/hooks/"

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
