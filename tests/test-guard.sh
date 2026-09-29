#!/usr/bin/env bash
# Behavior of the Agent Standard 1.2 guard hook (_template/hooks/guard.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
GUARD="$PWD/_template/hooks/guard.sh"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PKG="$W/pkg"; AD="$PKG/capabilities/crm/adapters/demo"; mkdir -p "$AD"
printf '%s\n' 'name: demo-agent' 'version: 1.0.0' 'description: Demo' 'standard: "1.2"' > "$PKG/agent.yaml"
printf '%s\n' 'capability: crm' 'provider: demo' 'server_match: DemoCRM' 'block: delete, merge' 'guard: guard.py' \
  'enforce_draft_only: adapter' > "$AD/adapter.yaml"
cat > "$AD/guard.py" <<'EOF'
import sys
data = sys.stdin.read()
if "FORBIDDEN" in data:
    print("demo guard: FORBIDDEN value", file=sys.stderr)
    sys.exit(2)
if "CRASH" in data:
    sys.exit(1)
EOF
chmod 755 "$AD/guard.py"

I="$W/inst"; mkdir -p "$I/sub"
printf '%s\n' 'agent: demo-agent' 'agent_version: 1.0.0' 'standard: "1.2"' 'mode: plugin' 'bind_crm: demo' > "$I/instance.yaml"

call() { # call <tool_name> [tool_input JSON] — hook input on one line
  local args=${2:-}; [ -n "$args" ] || args='{}'
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$args"
}
run_guard() { # run_guard <project dir> <input> — output (stdout+stderr) in $OUT, exit code in $RC
  OUT=$(printf '%s' "$2" | CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$1" bash "$GUARD" 2>&1); RC=$?
}
expect() { # expect <rc> <label> [text the output must contain]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; }; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}

run_guard "$I" "$(call Bash '{"command":"ls"}')";                 expect 0 "non-MCP tool allowed"
run_guard "$W" "$(call mcp__claude_ai_DemoCRM__delete-record)";   expect 0 "no instance: allowed"
run_guard "$I" "$(call mcp__other__delete-record)";               expect 0 "unbound server allowed"
run_guard "$I" "$(call mcp__claude_ai_DemoCRM__delete-record)"
expect 2 "blocked tool on matched server" "Blocked by demo-agent guard: delete-record is blocked for crm (demo adapter)"
run_guard "$I" "$(call mcp__democrm__merge-records)";             expect 2 "server match is case-insensitive"
run_guard "$I/sub" "$(call mcp__democrm__merge-records)";         expect 2 "found from a subfolder"
run_guard "$I" "$(call mcp__democrm__update-record '{"v":"ok"}')"; expect 0 "allowed call passes the guard"
run_guard "$I" "$(call mcp__democrm__update-record '{"v":"FORBIDDEN"}')"
expect 2 "guard exit 2 blocks with its message" "demo guard: FORBIDDEN value"
run_guard "$I" "$(call mcp__democrm__update-record '{"v":"CRASH"}')"
expect 2 "guard crash blocks" "failed (exit 1)"
run_guard "$I" "$(call mcp__other__update-record '{"v":"FORBIDDEN"}')"; expect 0 "guard not run for other servers"

# Two different tool names (one hidden in tool_input) block.
run_guard "$I" "$(call mcp__other__x '{"tool_name":"mcp__democrm__delete-record"}')"
expect 2 "two tool names block" "more than one tool"
# An escaped "tool_name" inside a string is not a second name.
run_guard "$I" "$(call mcp__other__x '{"note":"say \"tool_name\": \"y\""}')"; expect 0 "escaped tool_name ignored"

# Guard file missing.
mv "$AD/guard.py" "$AD/guard.bak"
run_guard "$I" "$(call mcp__democrm__update-record)"; expect 2 "missing guard blocks" "is missing"
run_guard "$I" "$(call mcp__other__update-record)";   expect 0 "missing guard: other servers allowed"
mv "$AD/guard.bak" "$AD/guard.py"

# python3 absent from PATH.
BIN="$W/bin"; mkdir -p "$BIN"
for t in bash cat sed head tr grep sort dirname; do ln -s "$(command -v "$t")" "$BIN/$t"; done
OUT=$(printf '%s' "$(call mcp__democrm__update-record)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$I" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 2 "no python3 blocks" "python3 is required"
OUT=$(printf '%s' "$(call mcp__other__update-record)" | PATH="$BIN" CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$I" "$BIN/bash" "$GUARD" 2>&1); RC=$?
expect 0 "no python3: other servers allowed"

# Custom adapter: block applies, guard never runs.
C="$W/custom"; mkdir -p "$C/custom-adapters/crm"
printf '%s\n' 'agent: demo-agent' 'agent_version: 1.0.0' 'mode: plugin' 'bind_crm: custom' > "$C/instance.yaml"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: democrm' 'block: delete' 'guard: evil.py' > "$C/custom-adapters/crm/adapter.yaml"
printf '%s\n' 'import pathlib' "pathlib.Path('$W/EVIL-RAN').touch()" > "$C/custom-adapters/crm/evil.py"
run_guard "$C" "$(call mcp__democrm__update-record)"
[ "$RC" -eq 0 ] && [ ! -e "$W/EVIL-RAN" ] && _report ok "custom guard never runs" || _report no "custom guard ran or blocked (rc=$RC): $OUT"
run_guard "$C" "$(call mcp__democrm__delete-record)"; expect 2 "custom block applies"

# Hostile binding values are ignored.
H="$W/hostile"; mkdir -p "$H"
printf '%s\n' 'agent: demo-agent' 'bind_crm: ../../x' 'bind_$(touch PWNED): demo' > "$H/instance.yaml"
run_guard "$H" "$(call mcp__democrm__delete-record)"
[ "$RC" -eq 0 ] && [ ! -e PWNED ] && [ ! -e "$H/PWNED" ] && _report ok "hostile bindings ignored" || _report no "hostile bindings (rc=$RC): $OUT"

# Another agent's instance: allowed.
O="$W/other"; mkdir -p "$O"; printf '%s\n' 'agent: someone-else' 'bind_crm: demo' > "$O/instance.yaml"
run_guard "$O" "$(call mcp__democrm__delete-record)"; expect 0 "another agent's instance allowed"

# Spaces in paths.
S="$W/with space/inst"; mkdir -p "$S"; cp "$I/instance.yaml" "$S/"
run_guard "$S" "$(call mcp__democrm__delete-record)"; expect 2 "path with spaces"

# A server name containing __ still matches; the block applies to the real tool name.
run_guard "$I" "$(call mcp__x__DemoCRM__delete-record)"; expect 2 "server name containing __ matches" "delete-record is blocked"
run_guard "$I" "$(call mcp__x__DemoCRM__update-record)"; expect 0 "server containing __, allowed tool passes"
run_guard "$I" "$(call mcp__democrm__delete__record)";   expect 2 "tool name containing __ still blocked" "delete__record is blocked"

# Invalid guard name in a bound adapter blocks.
BAD="$PKG/capabilities/crm/adapters/bad"; mkdir -p "$BAD"
printf '%s\n' 'capability: crm' 'provider: bad' 'server_match: badcrm' 'guard: ../x.py' > "$BAD/adapter.yaml"
B="$W/badinst"; mkdir -p "$B"
printf '%s\n' 'agent: demo-agent' 'bind_crm: bad' > "$B/instance.yaml"
run_guard "$B" "$(call mcp__badcrm__update-record)"; expect 2 "invalid guard name blocks" "invalid guard"

# Bound provider with no adapter.yaml: allowed, with a note on stderr.
G="$W/ghostinst"; mkdir -p "$G"
printf '%s\n' 'agent: demo-agent' 'bind_crm: ghost' > "$G/instance.yaml"
run_guard "$G" "$(call mcp__democrm__update-record)"; expect 0 "missing adapter.yaml allowed" "no adapter.yaml"

# Source mode: no CLAUDE_PLUGIN_ROOT; the package root is the script's parent folder.
mkdir -p "$PKG/hooks"; cp "$GUARD" "$PKG/hooks/guard.sh"
printf '%s\n' 'agent: demo-agent' 'mode: source' 'bind_crm: demo' > "$PKG/instance.yaml"
OUT=$(printf '%s' "$(call mcp__democrm__delete-record)" | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$PKG" bash "$PKG/hooks/guard.sh" 2>&1); RC=$?
expect 2 "source mode guards"
rm "$PKG/instance.yaml"

assert_contains _template/hooks/hooks.json '"\"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh\""'
assert_contains _template/hooks/hooks.json '"matcher": "mcp__.*"'
[ -x "$GUARD" ] && _report ok "guard is executable" || _report no "guard not executable"

finish
