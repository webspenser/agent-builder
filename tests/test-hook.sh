#!/usr/bin/env bash
# Behavior of the Agent Standard 1.1 entry hook (_template/hooks/session-start.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
HOOK="$PWD/_template/hooks/session-start.sh"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PKG="$W/pkg"; mkdir -p "$PKG"
printf '%s\n' 'name: demo-agent' 'version: 1.2.0' 'description: Demo' 'standard: "1.1"' > "$PKG/agent.yaml"
printf '%s\n' '# Demo' 'DEMO-AGENT-MARKER' > "$PKG/AGENT.md"

run_hook() { # run_hook <project dir> — prints hook stdout; exit code in $RC
  OUT=$(CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>&1); RC=$?
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# No instance: silent.
mkdir -p "$W/plain"
run_hook "$W/plain"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && _report ok "silent without instance" || _report no "not silent without instance: $OUT"

# Matching instance: header + AGENT.md, no migration line.
I="$W/inst"; mkdir -p "$I"
printf '%s\n' 'agent: demo-agent' 'agent_version: 1.2.0' 'standard: "1.1"' 'mode: plugin' > "$I/instance.yaml"
run_hook "$I"
has 'DEMO-AGENT-MARKER' && has "Instance folder: $I" && has "Package folder: $PKG" && ! has 'Migration:' \
  && _report ok "loads in matching instance" || _report no "matching instance output wrong: $OUT"

# From a subfolder: finds the parent instance.
mkdir -p "$I/a/b"; run_hook "$I/a/b"
has "Instance folder: $I" && _report ok "finds parent instance" || _report no "parent instance not found"

# Another agent's instance nearer than ours: silent.
mkdir -p "$I/other"; printf '%s\n' 'agent: someone-else' 'agent_version: 1.0.0' > "$I/other/instance.yaml"
run_hook "$I/other"
[ -z "$OUT" ] && _report ok "silent in another agent's instance" || _report no "spoke in another agent's instance"

# Version gap: migration line names both versions.
G="$W/gap"; mkdir -p "$G"; printf '%s\n' 'agent: demo-agent' 'agent_version: 1.1.0' > "$G/instance.yaml"
run_hook "$G"
has 'Migration:' && has '1.1.0' && has '1.2.0' && _report ok "migration line on version gap" || _report no "no migration line"

# Quoted values and trailing comments.
Q="$W/quoted"; mkdir -p "$Q"; printf '%s\n' 'agent: "demo-agent"   # mine' "agent_version: '1.2.0'" > "$Q/instance.yaml"
run_hook "$Q"
has 'DEMO-AGENT-MARKER' && ! has 'Migration:' && _report ok "quoted values match" || _report no "quoted values failed: $OUT"

# Spaces in the instance path.
S="$W/with space/inst"; mkdir -p "$S"; printf '%s\n' 'agent: demo-agent' 'agent_version: 1.2.0' > "$S/instance.yaml"
run_hook "$S"
has "Instance folder: $S" && _report ok "path with spaces" || _report no "path with spaces failed"

# CLAUDE_PROJECT_DIR unset: uses the working directory.
OUT=$(cd "$I/a" && env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT="$PKG" bash "$HOOK" 2>&1)
has 'DEMO-AGENT-MARKER' && _report ok "falls back to PWD" || _report no "PWD fallback failed"

# Missing AGENT.md: one line, exit 0.
mv "$PKG/AGENT.md" "$PKG/AGENT.bak"; run_hook "$I"
[ "$RC" -eq 0 ] && has 'AGENT.md is missing' && _report ok "missing AGENT.md reported" || _report no "missing AGENT.md not handled"
mv "$PKG/AGENT.bak" "$PKG/AGENT.md"

# hooks.json points at the script.
assert_contains _template/hooks/hooks.json '"\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\""'
[ -x "$HOOK" ] && _report ok "hook is executable" || _report no "hook not executable"

finish
