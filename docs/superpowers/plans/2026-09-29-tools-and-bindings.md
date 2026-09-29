# Tools and Bindings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Agent Standard 1.2 (capability contracts, adapters, instance bindings, an automatic guard hook, setup's tools step, validator checks) in agent-builder 1.2.0, and adopt it in sales-partner 1.1.0 with `crm` (Attio, Airtable) and `email_drafts` (Gmail).

**Architecture:** Every 1.2 agent carries a byte-identical `hooks/guard.sh`, registered as a `PreToolUse` hook on `mcp__.*`. Inside an instance it reads `bind_<capability>: <provider>` lines from `instance.yaml`, finds the adapter's `adapter.yaml`, refuses tools whose names contain a `block` substring on matching servers, and runs the adapter's optional `guard.py` for argument rules. It fails closed. The validator checks contracts, adapters, and the hook, and setup binds each capability after a read-only probe.

**Tech Stack:** bash (macOS bash 3.2 compatible), Python 3 standard library, markdown, JSON, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-tools-and-bindings-design.md` (builder repo), including its "Rulings during planning" section.

## Global Constraints

- Builder checkout `/Users/hochoy/Work/Webspenser/agent-library` (GitHub `webspenser/agent-builder`). Work on branch `feat/standard-1.2`, created from `spec/tools-bindings`.
- sales-partner checkout `/Users/hochoy/Work/Webspenser/sales-partner`. Work on branch `release/1.1.0` from `main`. Its origin is SSH; workflow files push over SSH.
- **Read-only:** `/Users/hochoy/Work/Webspenser/live-agents/agent-library`. Copy from it; never modify, commit, or run anything that writes there.
- Versions: builder `1.2.0`; sales-partner `1.1.0`; standard string `"1.2"`.
- Hook command strings, exact: `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"` (with the surrounding double quotes inside the JSON string); matcher `mcp__.*`.
- Custom adapters live in the instance at `custom-adapters/<capability>/`. Probe facts go in the instance at `bindings/<capability>.md`.
- Capability names are `snake_case`; provider (adapter folder) names are kebab-case.
- No secrets in any file. `bootstrap.py` reads `ATTIO_API_KEY` from the environment only.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- After editing any script, confirm its executable bit with `git ls-files -s <file>` (mode `100755`); the Edit tool has dropped it before.
- The buildatscale bash-guard hook blocks compound shell commands that look like exfiltration, and any command or path containing the word "credentials". Run simple, separate commands.
- Never run `claude`, Attio, or Gmail tools that write. The acceptance run in Task 8 is read-only against Attio.

## Review Focus

1. **Spoofed tool name.** A `tool_input` value containing its own `"tool_name"` key must not redirect the guard. More than one distinct `tool_name` in the input blocks. Pinned in Task 1 (test "two tool names block").
2. **Guard unavailable.** No `python3` on `PATH`, a missing guard file, or a guard crash blocks calls to the matched server only. Unrelated MCP calls stay allowed. Pinned in Task 1.
3. **Attribute keyed by ID, or status by option UUID.** Either must not slip past the Attio guard: only api slugs and literal allowed values pass. Pinned in Task 6.
4. **Untrusted instance.** A `bind_crm: custom` adapter that names a `guard` is never executed. A hostile `bind_*` value (`../../x`) is ignored. Pinned in Task 1.
5. **Server-name variants.** `mcp__claude_ai_Attio__…`, `mcp__attio__…` and plugin-provided names all match `server_match: attio`. Pinned in Task 1 (case variant) and Task 6 (guard dispatch by tool suffix).

---

## Builder (tasks 1–4) — repo `/Users/hochoy/Work/Webspenser/agent-library`, branch `feat/standard-1.2`

### Task 1: The guard hook

**Files:**
- Create: `_template/hooks/guard.sh` (mode 755)
- Modify: `_template/hooks/hooks.json`
- Create: `tests/test-guard.sh` (mode 755)
- Modify: `tests/run-all.sh`

**Interfaces:**
- Produces: the reference `_template/hooks/guard.sh`, which Tasks 2, 5 and 7 byte-compare or copy. Hook input is Claude Code's PreToolUse JSON on stdin (`tool_name`, `tool_input`, …). Exit 2 blocks with stderr; exit 0 allows. Adapter lookup:
  - package: `$root/capabilities/<cap>/adapters/<provider>/adapter.yaml`;
  - custom: `$instance/custom-adapters/<cap>/adapter.yaml`.
  - Keys read: `server_match`, `block`, `guard`.

- [ ] **Step 1: Branch**

```bash
git -C /Users/hochoy/Work/Webspenser/agent-library switch -c feat/standard-1.2 spec/tools-bindings
```

- [ ] **Step 2: Write the failing test** `tests/test-guard.sh`:

```bash
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
```

- [ ] **Step 3: Run it; confirm it fails**

Run: `chmod 755 tests/test-guard.sh` then `tests/test-guard.sh`
Expected: many `FAIL` lines. `_template/hooks/guard.sh` doesn't exist yet.

- [ ] **Step 4: Write `_template/hooks/guard.sh`**

```bash
#!/usr/bin/env bash
# Agent Standard 1.2 guard hook — identical in every agent.
# PreToolUse hook for MCP tools. Inside an instance of this agent, applies each
# bound adapter's rules to calls on the servers it matches: a tool whose name
# contains one of the adapter's `block` entries is refused, then the adapter's
# guard (package adapters only) inspects the call. Exit 2 blocks the call and
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
rest=${tool#mcp__}
server_lc=$(lower "${rest%%__*}")
tname=${rest#*__}
tname_lc=$(lower "$tname")
show_tool=$(printf '%s' "$tname" | tr -d '\000-\037')

while IFS= read -r line || [ -n "$line" ]; do
  key=${line%%:*}
  case "$key" in bind_*) ;; *) continue ;; esac
  cap=${key#bind_}
  case "$cap" in ''|*[!a-z0-9_]*) continue ;; esac
  provider=$(yaml_get "$instance/instance.yaml" "$key")
  case "$provider" in ''|*[!a-z0-9-]*) continue ;; esac
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
  case "$server_lc" in *"$match"*) ;; *) continue ;; esac
  IFS=, read -r -a subs <<< "$(yaml_get "$adir/adapter.yaml" block)"
  for sub in "${subs[@]}"; do
    sub=$(lower "$(printf '%s' "$sub" | tr -d '[:space:]')")
    [ -n "$sub" ] || continue
    case "$tname_lc" in *"$sub"*) block "$show_tool is blocked for $cap ($provider adapter)" ;; esac
  done
  [ "$provider" = custom ] && continue  # never execute code from an instance folder
  guard=$(yaml_get "$adir/adapter.yaml" guard)
  [ -n "$guard" ] || continue
  case "$guard" in .*|*/*|*[!A-Za-z0-9._-]*) block "the $provider adapter for $cap names an invalid guard" ;; esac
  [ -f "$adir/$guard" ] || block "the $provider guard for $cap is missing"
  command -v python3 >/dev/null 2>&1 || block "python3 is required to run the $provider guard for $cap"
  printf '%s' "$input" | python3 "$adir/$guard"; rc=$?
  [ "$rc" -eq 0 ] && continue
  [ "$rc" -eq 2 ] && exit 2
  block "the $provider guard for $cap failed (exit $rc)"
done < "$instance/instance.yaml"
exit 0
```

Then `chmod 755 _template/hooks/guard.sh`.

- [ ] **Step 5: Replace `_template/hooks/hooks.json`**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\"" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "mcp__.*",
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh\"" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Wire into `tests/run-all.sh`.** After the `== hook` line add:

```bash
echo "== guard"; tests/test-guard.sh || STATUS=1
```

- [ ] **Step 7: Run the tests and make sure they pass**

Run: `tests/test-guard.sh`. Expected: every line `ok`, `-- N passed, 0 failed`.
Run: `tests/run-all.sh`. Expected: `ALL GREEN`. The 1.1 checks ignore the new `PreToolUse` entry.

- [ ] **Step 8: Commit**

```bash
git add _template/hooks/guard.sh _template/hooks/hooks.json tests/test-guard.sh tests/run-all.sh
git commit -m "feat: Agent Standard 1.2 guard hook"
```

Check `git ls-files -s _template/hooks/guard.sh tests/test-guard.sh` shows `100755`.

---

### Task 2: Validator checks for 1.2

**Files:**
- Modify: `bin/lib/check_manifests.py`
- Modify: `tests/test-validate-agent.sh` (append before the final `finish`)

**Interfaces:**
- Consumes: `_template/hooks/guard.sh` and `_template/hooks/hooks.json` from Task 1.
- Produces: `FAIL:` messages exactly as written below. Task 3's template test and Tasks 5–7 rely on 1.2 validation.

- [ ] **Step 1: Write the failing tests.** Append before the final `finish` in `tests/test-validate-agent.sh`:

```bash
echo "-- Agent Standard 1.2"
make_valid_v12_agent() { # make_valid_v12_agent <dir> [name]
  local d="$1"
  make_valid_v11_agent "$d" "${2:-demo-agent}"
  sed -i.bak 's/^standard:.*/standard: "1.2"/' "$d/agent.yaml" && rm -f "$d/agent.yaml.bak"
  echo 'capabilities: crm' >> "$d/agent.yaml"
  cp _template/hooks/guard.sh "$d/hooks/"; chmod 755 "$d/hooks/guard.sh"
  local c="$d/capabilities/crm" a="$d/capabilities/crm/adapters/demo"
  mkdir -p "$a"
  printf '%s\n' '# CRM contract' '' '## Operations' '' '| Operation | Arguments |' '|---|---|' \
    '| `create_lead` | `company` |' '| `get_lead` | `lead_id` |' '' '## Invariants' '' \
    '- `draft_only` — only drafts' '- `no_send` — never sends' > "$c/contract.md"
  printf '%s\n' '# Demo adapter' '' '- `create_lead` — demo:create' '- `get_lead` — demo:get' '' '## Probe' '' 'Call demo:whoami.' > "$a/adapter.md"
  printf '%s\n' 'capability: crm' 'provider: demo' 'server_match: demo' 'block: send' 'guard: guard.py' \
    'enforce_draft_only: adapter' 'enforce_no_send: adapter' > "$a/adapter.yaml"
  printf '%s\n' '#!/usr/bin/env python3' 'import sys' 'sys.exit(0)' > "$a/guard.py"; chmod 755 "$a/guard.py"
}
fails_with() { # fails_with <dir> <message> — non-zero exit and that exact FAIL line, no traceback
  local out rc; out=$($V "$1" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL: $2" && ! printf '%s\n' "$out" | grep -qE 'Traceback|checker error'; then
    _report ok "$(basename "$1"): $2"; else _report no "$(basename "$1") (rc=$rc) wanted '$2': $out"; fi
}
AD=capabilities/crm/adapters/demo
make_valid_v12_agent "$FIX/v12"; assert_pass $V "$FIX/v12"
make_valid_v11_agent "$FIX/v11-again"; assert_pass $V "$FIX/v11-again"   # 1.1 unchanged
make_valid_v12_agent "$FIX/v12-notools"; sed -i.bak '/^capabilities:/d' "$FIX/v12-notools/agent.yaml"; rm -rf "$FIX/v12-notools/capabilities" "$FIX/v12-notools/agent.yaml.bak"; assert_pass $V "$FIX/v12-notools"

make_valid_v12_agent "$FIX/v12-noguard"; rm "$FIX/v12-noguard/hooks/guard.sh"
fails_with "$FIX/v12-noguard" "missing hooks/guard.sh"
make_valid_v12_agent "$FIX/v12-edited"; echo "# tweak" >> "$FIX/v12-edited/hooks/guard.sh"
fails_with "$FIX/v12-edited" "hooks/guard.sh differs from the Agent Standard reference copy (_template/hooks/guard.sh in agent-builder)"
make_valid_v12_agent "$FIX/v12-noexec"; chmod 644 "$FIX/v12-noexec/hooks/guard.sh"
fails_with "$FIX/v12-noexec" "hooks/guard.sh is not executable"
make_valid_v12_agent "$FIX/v12-nopre"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\""}]}]}}' > "$FIX/v12-nopre/hooks/hooks.json"
fails_with "$FIX/v12-nopre" 'hooks/hooks.json: needs a PreToolUse command hook "${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh" with matcher mcp__.*'

make_valid_v12_agent "$FIX/v12-nocontract"; rm "$FIX/v12-nocontract/capabilities/crm/contract.md"
fails_with "$FIX/v12-nocontract" "missing capabilities/crm/contract.md"
make_valid_v12_agent "$FIX/v12-noops"; sed -i.bak '/^| `/d' "$FIX/v12-noops/capabilities/crm/contract.md"
fails_with "$FIX/v12-noops" 'capabilities/crm/contract.md: needs a ## Operations table with at least one `operation` in its first column'
make_valid_v12_agent "$FIX/v12-noinv"; sed -i.bak '/^## Invariants/,$d' "$FIX/v12-noinv/capabilities/crm/contract.md"
fails_with "$FIX/v12-noinv" 'capabilities/crm/contract.md: needs a ## Invariants list with at least one `invariant_id`'
make_valid_v12_agent "$FIX/v12-badinv"; echo '- `Draft-Only` — bad id' >> "$FIX/v12-badinv/capabilities/crm/contract.md"
fails_with "$FIX/v12-badinv" "capabilities/crm/contract.md: invariant 'Draft-Only' is not snake_case"
make_valid_v12_agent "$FIX/v12-noadapter"; rm -r "$FIX/v12-noadapter/capabilities/crm/adapters"
fails_with "$FIX/v12-noadapter" "capabilities/crm: needs at least one adapter in adapters/"
make_valid_v12_agent "$FIX/v12-noyaml"; rm "$FIX/v12-noyaml/$AD/adapter.yaml"
fails_with "$FIX/v12-noyaml" "missing $AD/adapter.yaml"

make_valid_v12_agent "$FIX/v12-missenf"; sed -i.bak '/^enforce_no_send/d' "$FIX/v12-missenf/$AD/adapter.yaml"
fails_with "$FIX/v12-missenf" "$AD/adapter.yaml: missing enforce_no_send"
make_valid_v12_agent "$FIX/v12-extraenf"; echo 'enforce_other: adapter' >> "$FIX/v12-extraenf/$AD/adapter.yaml"
fails_with "$FIX/v12-extraenf" "$AD/adapter.yaml: enforce_other names no invariant in the contract"
make_valid_v12_agent "$FIX/v12-badlevel"; sed -i.bak 's/^enforce_draft_only: .*/enforce_draft_only: maybe/' "$FIX/v12-badlevel/$AD/adapter.yaml"
fails_with "$FIX/v12-badlevel" "$AD/adapter.yaml: enforce_draft_only must be adapter, host-deny, or instruction"
make_valid_v12_agent "$FIX/v12-nodeny"; sed -i.bak 's/^enforce_draft_only: .*/enforce_draft_only: host-deny/' "$FIX/v12-nodeny/$AD/adapter.yaml"
fails_with "$FIX/v12-nodeny" "$AD/adapter.yaml: host-deny needs a deny list of tool names"
make_valid_v12_agent "$FIX/v12-deny"; sed -i.bak 's/^enforce_draft_only: .*/enforce_draft_only: host-deny/' "$FIX/v12-deny/$AD/adapter.yaml"; echo 'deny: update-record' >> "$FIX/v12-deny/$AD/adapter.yaml"
assert_pass $V "$FIX/v12-deny"
make_valid_v12_agent "$FIX/v12-nosend"; sed -i.bak 's/^enforce_no_send: .*/enforce_no_send: instruction/' "$FIX/v12-nosend/$AD/adapter.yaml"
fails_with "$FIX/v12-nosend" "$AD/adapter.yaml: no_send cannot be enforced by instruction"
make_valid_v12_agent "$FIX/v12-wrongcap"; sed -i.bak 's/^capability: .*/capability: crmx/' "$FIX/v12-wrongcap/$AD/adapter.yaml"
fails_with "$FIX/v12-wrongcap" "$AD/adapter.yaml: capability 'crmx' must be 'crm'"
make_valid_v12_agent "$FIX/v12-wrongprov"; sed -i.bak 's/^provider: .*/provider: other/' "$FIX/v12-wrongprov/$AD/adapter.yaml"
fails_with "$FIX/v12-wrongprov" "$AD/adapter.yaml: provider 'other' must be 'demo'"
make_valid_v12_agent "$FIX/v12-nomatch"; sed -i.bak '/^server_match/d' "$FIX/v12-nomatch/$AD/adapter.yaml"
fails_with "$FIX/v12-nomatch" "$AD/adapter.yaml: missing server_match"
make_valid_v12_agent "$FIX/v12-guardgone"; rm "$FIX/v12-guardgone/$AD/guard.py"
fails_with "$FIX/v12-guardgone" "$AD/adapter.yaml: guard guard.py does not exist"
make_valid_v12_agent "$FIX/v12-guardnx"; chmod 644 "$FIX/v12-guardnx/$AD/guard.py"
fails_with "$FIX/v12-guardnx" "$AD/guard.py is not executable"
make_valid_v12_agent "$FIX/v12-guardpath"; sed -i.bak 's|^guard: .*|guard: ../x.py|' "$FIX/v12-guardpath/$AD/adapter.yaml"
fails_with "$FIX/v12-guardpath" "$AD/adapter.yaml: guard '../x.py' must be a file name in the adapter folder"
make_valid_v12_agent "$FIX/v12-unmapped"; sed -i.bak '/get_lead/d' "$FIX/v12-unmapped/$AD/adapter.md"
fails_with "$FIX/v12-unmapped" "$AD/adapter.md: does not map operation \`get_lead\`"
make_valid_v12_agent "$FIX/v12-noprobe"; sed -i.bak '/^## Probe/d' "$FIX/v12-noprobe/$AD/adapter.md"
fails_with "$FIX/v12-noprobe" "$AD/adapter.md: needs a ## Probe section"
make_valid_v12_agent "$FIX/v12-unlisted"; mkdir -p "$FIX/v12-unlisted/capabilities/email"
fails_with "$FIX/v12-unlisted" "capabilities/email is not listed in agent.yaml capabilities"
make_valid_v12_agent "$FIX/v12-badcap"; sed -i.bak 's/^capabilities: .*/capabilities: crm, Email-Drafts/' "$FIX/v12-badcap/agent.yaml"
fails_with "$FIX/v12-badcap" "agent.yaml: capability 'Email-Drafts' is not snake_case"
make_valid_v12_agent "$FIX/v12-badprov"; mv "$FIX/v12-badprov/$AD" "$FIX/v12-badprov/capabilities/crm/adapters/Demo_X"
sed -i.bak 's/^provider: .*/provider: Demo_X/' "$FIX/v12-badprov/capabilities/crm/adapters/Demo_X/adapter.yaml"
fails_with "$FIX/v12-badprov" "capabilities/crm/adapters/Demo_X: adapter folder name is not kebab-case"
make_valid_v12_agent "$FIX/v12-unread"; chmod 000 "$FIX/v12-unread/capabilities/crm/contract.md"
out=$($V "$FIX/v12-unread" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && ! printf '%s\n' "$out" | grep -qE 'Traceback|checker error'; then _report ok "unreadable contract fails cleanly"; else _report no "unreadable contract (rc=$rc): $out"; fi
chmod 644 "$FIX/v12-unread/capabilities/crm/contract.md"
```

- [ ] **Step 2: Run it; confirm the new cases fail**

Run: `tests/test-validate-agent.sh`
Expected: the `v12-*` cases that expect FAIL lines report `FAIL` (the validator doesn't know 1.2 yet). `v12` itself passes; the earlier sections still pass.

- [ ] **Step 3: Implement in `bin/lib/check_manifests.py`**

(a) Update the docstring's first line to `"""Agent Standard 1.x manifest checks.`.

(b) Replace the `REFERENCE_HOOK = …` line with:

```python
TEMPLATE_HOOKS = pathlib.Path(__file__).resolve().parents[2] / "_template" / "hooks"
REFERENCE_HOOK = TEMPLATE_HOOKS / "session-start.sh"
REFERENCE_GUARD = TEMPLATE_HOOKS / "guard.sh"
GUARD_COMMAND = '"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"'
GUARD_MATCHER = "mcp__.*"
LEVELS = ("adapter", "host-deny", "instruction")
SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")
OPERATION = re.compile(r"^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`")
INVARIANT = re.compile(r"^[-*]\s+`([^`]+)`")
GUARD_FILE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")
```

(c) Add these helpers above `check_v11`:

```python
def hook_commands(hooks, event, matcher=None):
    """Commands of `event`'s command hooks; with `matcher`, only groups whose matcher equals it."""
    events = hooks.get("hooks") if isinstance(hooks, dict) else None
    groups = events.get(event) if isinstance(events, dict) else None
    commands = []
    for group in groups if isinstance(groups, list) else []:
        if not isinstance(group, dict) or (matcher is not None and group.get("matcher") != matcher):
            continue
        inner = group.get("hooks")
        for hook in inner if isinstance(inner, list) else []:
            if isinstance(hook, dict) and hook.get("type") == "command":
                commands.append(hook.get("command"))
    return commands


def check_reference_script(root, rel, reference):
    """`rel` exists, is executable, and is byte-identical to the builder's reference copy."""
    script = root / rel
    if not script.is_file():
        return [f"missing {rel}"]
    fails = []
    if not os.access(script, os.X_OK):
        fails.append(f"{rel} is not executable")
    if not reference.is_file():
        fails.append(f"validator is missing its reference hook at {reference}")
        return fails
    try:
        same = script.read_bytes() == reference.read_bytes()
    except OSError:
        fails.append(f"{rel} cannot be read")
    else:
        if not same:
            fails.append(f"{rel} differs from the Agent Standard reference copy (_template/{rel} in agent-builder)")
    return fails


def section(text, heading):
    """Lines under `## heading` up to the next `## ` heading, or None when there is no such heading."""
    lines, found, inside = [], False, False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = line[3:].strip() == heading
            found = found or inside
            continue
        if inside:
            lines.append(line)
    return lines if found else None
```

(d) In `check_v11`, replace the inline SessionStart loop (from `commands = []` through the nested `for hook …` loop) with `commands = hook_commands(hooks, "SessionStart")`. Keep the `if not isinstance(hooks, dict)` message and the `HOOK_COMMAND not in commands` check. Replace the whole `script = root / "hooks" / "session-start.sh"` block with:

```python
    fails.extend(check_reference_script(root, "hooks/session-start.sh", REFERENCE_HOOK))
```

The messages come out identical to before, so the 1.1 tests stay green.

(e) Add after `check_v11`:

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
        if ay.get("capability") != cap:
            fails.append(f"{rel}: capability {ay.get('capability')!r} must be {cap!r}")
        if ay.get("provider") != adir.name:
            fails.append(f"{rel}: provider {ay.get('provider')!r} must be {adir.name!r}")
        if not ay.get("server_match"):
            fails.append(f"{rel}: missing server_match")
        levels = {k[len("enforce_"):]: v for k, v in ay.items() if k.startswith("enforce_")}
        for inv in sorted(invariants - levels.keys()):
            fails.append(f"{rel}: missing enforce_{inv}")
        for inv in sorted(levels.keys() - invariants):
            fails.append(f"{rel}: enforce_{inv} names no invariant in the contract")
        for inv, level in sorted(levels.items()):
            if level not in LEVELS:
                fails.append(f"{rel}: enforce_{inv} must be adapter, host-deny, or instruction")
        if "host-deny" in levels.values() and not ay.get("deny"):
            fails.append(f"{rel}: host-deny needs a deny list of tool names")
        if levels.get("no_send") == "instruction":
            fails.append(f"{rel}: no_send cannot be enforced by instruction")
        guard = ay.get("guard")
        if guard:
            if not GUARD_FILE.match(guard):
                fails.append(f"{rel}: guard '{guard}' must be a file name in the adapter folder")
            elif not (adir / guard).is_file():
                fails.append(f"{rel}: guard {guard} does not exist")
            elif not os.access(adir / guard, os.X_OK):
                fails.append(f"{prefix}/{guard} is not executable")
    if "adapter.md" in texts:
        rel = f"{prefix}/adapter.md"
        for op in ops:
            if f"`{op}`" not in texts["adapter.md"]:
                fails.append(f"{rel}: does not map operation `{op}`")
        if section(texts["adapter.md"], "Probe") is None:
            fails.append(f"{rel}: needs a ## Probe section")
    return fails


def check_capability(root, cap):
    """capabilities/<cap>/contract.md and every adapter under it."""
    base = root / "capabilities" / cap
    rel = f"capabilities/{cap}/contract.md"
    if not (base / "contract.md").is_file():
        return [f"missing {rel}"]
    try:
        text = read_text(base / "contract.md")
    except ReadError as err:
        return [f"{rel}: {err}"]
    fails = []
    ops = [m.group(1) for line in section(text, "Operations") or [] for m in [OPERATION.match(line)] if m]
    invariants = [m.group(1) for line in section(text, "Invariants") or [] for m in [INVARIANT.match(line)] if m]
    if not ops:
        fails.append(f"{rel}: needs a ## Operations table with at least one `operation` in its first column")
    if not invariants:
        fails.append(f"{rel}: needs a ## Invariants list with at least one `invariant_id`")
    for inv in invariants:
        if not SNAKE.match(inv):
            fails.append(f"{rel}: invariant '{inv}' is not snake_case")
    folder = base / "adapters"
    adapters = sorted(p for p in folder.iterdir() if p.is_dir()) if folder.is_dir() else []
    if not adapters:
        fails.append(f"capabilities/{cap}: needs at least one adapter in adapters/")
    for adir in adapters:
        fails.extend(check_adapter(adir, cap, ops, set(invariants)))
    return fails


def check_v12(root, meta):
    """Agent Standard 1.2: guard hook, capability contracts, adapters."""
    fails = []
    try:
        hooks = json.loads(read_text(root / "hooks" / "hooks.json"))
    except (ReadError, json.JSONDecodeError):
        hooks = None  # already reported by check_v11
    if hooks is not None and GUARD_COMMAND not in hook_commands(hooks, "PreToolUse", GUARD_MATCHER):
        fails.append(f"hooks/hooks.json: needs a PreToolUse command hook {GUARD_COMMAND} with matcher {GUARD_MATCHER}")
    fails.extend(check_reference_script(root, "hooks/guard.sh", REFERENCE_GUARD))
    caps = [c.strip() for c in meta.get("capabilities", "").split(",") if c.strip()]
    for cap in caps:
        if not SNAKE.match(cap):
            fails.append(f"agent.yaml: capability '{cap}' is not snake_case")
            continue
        fails.extend(check_capability(root, cap))
    folder = root / "capabilities"
    if folder.is_dir():
        for d in sorted(folder.iterdir()):
            if d.is_dir() and d.name not in caps:
                fails.append(f"capabilities/{d.name} is not listed in agent.yaml capabilities")
    return fails
```

(f) In `check`, replace the `if std and SUPPORTED_STANDARD.match(std) and int(…) >= 1:` block with:

```python
    minor = int(std.split(".")[1]) if std and SUPPORTED_STANDARD.match(std) else 0
    if minor >= 1:
        fails.extend(check_v11(root, meta, name))
    if minor >= 2:
        fails.extend(check_v12(root, meta))
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `tests/test-validate-agent.sh`. Expected: `-- N passed, 0 failed`.
Run: `tests/run-all.sh`. Expected: `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/check_manifests.py tests/test-validate-agent.sh
git commit -m "feat: validator checks for Agent Standard 1.2"
```

---

### Task 3: Template 1.2 — setup's tools step and the capability skeleton

**Files:**
- Modify: `_template/agent.yaml`, `_template/skills/setup/SKILL.md`
- Create: `_capability-template/contract.md`, `_capability-template/adapters/example-provider/adapter.md`, `_capability-template/adapters/example-provider/adapter.yaml`
- Modify: `tests/run-all.sh`, `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: Task 2's validator.
- Produces: the tools-step text (Step 3 below). Task 7 copies it verbatim into sales-partner. It also produces `_capability-template/`, which the wizard (Task 4) copies.

- [ ] **Step 1: Write the failing tests.**

(a) In `tests/run-all.sh`, change the template section to:

```bash
echo "== template is Agent Standard 1.2"
if ! grep -q '^standard: "1.2"' _template/agent.yaml; then echo "FAIL: _template is not 1.2"; STATUS=1; fi
if ! grep -qF '**Tools.**' _template/skills/setup/SKILL.md; then echo "FAIL: setup has no tools step"; STATUS=1; fi
```

Keep the existing `TEMPLATE_OUTPUT` pre-1.0 check below it.

(b) Append to the 1.2 section of `tests/test-validate-agent.sh`, before `finish`:

```bash
# The capability skeleton validates once copied into an agent under its own names.
make_valid_v12_agent "$FIX/v12-skel"
mkdir -p "$FIX/v12-skel/capabilities/example_capability"
cp -R _capability-template/. "$FIX/v12-skel/capabilities/example_capability/"
sed -i.bak 's/^capabilities: .*/capabilities: crm, example_capability/' "$FIX/v12-skel/agent.yaml"
assert_pass $V "$FIX/v12-skel"
```

Run: `tests/run-all.sh`. Expected: `FAIL: _template is not 1.2`, `FAIL: setup has no tools step`, and the skeleton case fails.

- [ ] **Step 2: `_template/agent.yaml`** — `standard: "1.1"` → `standard: "1.2"`.

- [ ] **Step 3: `_template/skills/setup/SKILL.md`.** Make these edits:
  - Step 1: replace `stop — offer to re-run only the interview there.` with `stop — offer to re-run the interview, the tools step (step 9), or both there.`
  - Step 3: replace `stop and offer\n   to re-run only the interview.` (keep the line wrapping) with `stop and offer to re-run the interview or the tools step.`
  - Step 4: `` `standard: "1.1"` `` → `` `standard: "1.2"` ``.
  - Renumber step 9 (**Version control.**) to 10 and step 10 (**Open.**) to 11, and change "If step 3 created a subfolder" in the new step 11 so it still reads correctly.
  - Insert this as the new step 9, after step 8:

```markdown
9. **Tools.** Skip if `agent.yaml` lists no `capabilities`. For each
   capability listed there:
   1. List the shipped adapters (`capabilities/<capability>/adapters/`
      in the package) and ask which system the user uses. If none
      fits, offer a custom adapter: interview the user about their
      tool and write `custom-adapters/<capability>/adapter.md` and
      `adapter.yaml` in the instance, mapping every operation in the
      contract and declaring each invariant's level (`adapter`,
      `host-deny`, or `instruction`). A custom adapter never has a
      `guard`.
   2. Find the tools in this session whose server name (the part
      between `mcp__` and the next `__`) contains the adapter's
      `server_match`, ignoring case. If there are none, explain how to
      connect that system in the host (a connector or an MCP server),
      and that the user enters any key or login there themselves;
      leave the capability unbound and go on.
   3. Run the adapter's `## Probe` calls. They only read. On failure,
      say what failed and leave the capability unbound. Write what the
      probe found to `bindings/<capability>.md` in the instance.
   4. If the contract has a `no_send` invariant and the adapter
      enforces it by `instruction`, refuse to bind it and say why.
   5. Add `bind_<capability>: <provider>` (or `custom`) to
      `instance.yaml`, replacing an earlier line for that capability,
      and set `standard: "1.2"` there. Create or merge
      `.claude/settings.json`: add to `permissions.deny` one rule
      `mcp__<server>__<tool>` for every tool of a matched server whose
      name contains a `block` entry or ends with a `deny` entry. Keep
      every existing rule and key; never add a rule twice.
   6. Source mode only: also merge into `.claude/settings.json` a
      `PreToolUse` hook with matcher `mcp__.*` and command
      `"$CLAUDE_PROJECT_DIR/hooks/guard.sh"`, unless one is there
      already.
   7. Tell the user, for each capability, whether it is
      **unattended-safe**: every invariant enforced by `adapter`, or by
      `host-deny` with its rules written. Scheduled runs may use only
      unattended-safe capabilities.
```

  - In the **Source mode** paragraph, after `skip step 7 (settings)`, add ` except what step 9 writes`.

- [ ] **Step 4: `_capability-template/`**

`_capability-template/contract.md`:

```markdown
# <Capability> contract

What this capability does for the agent, in one paragraph. Skills and
sub-agent contracts call these operations by name — never a provider's
tools.

## Operations

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `example_operation` | `argument` | what it returns | what it rejects |

## Invariants

Each adapter declares in its `adapter.yaml` how it enforces each of
these: `adapter`, `host-deny`, or `instruction`.

- `example_invariant` — a rule every adapter must uphold. Name one
  `no_send` if the capability must never send a message to anyone.
```

`_capability-template/adapters/example-provider/adapter.md`:

```markdown
# <Capability> — <Provider> adapter

Maps the contract (`../../contract.md`) onto <Provider>'s tools.
`provider:` below means the connected <Provider> server's tools,
whatever their prefix.

- `example_operation` — `provider:tool-name` with the arguments; what
  to check first, and when to refuse.

## Probe

Read-only calls setup makes when binding this adapter, and what it
writes to `bindings/<capability>.md` in the instance.

1. `provider:whoami` — record the account or workspace name.
```

`_capability-template/adapters/example-provider/adapter.yaml`:

```yaml
capability: example_capability
provider: example-provider
server_match: example
block: delete
enforce_example_invariant: instruction
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `tests/run-all.sh`. Expected: `ALL GREEN`, including `== validating _template` with `OK`. `_capability-template/` has no `AGENT.md`, so run-all doesn't validate it as an agent.

- [ ] **Step 6: Commit**

```bash
git add _template/agent.yaml _template/skills/setup/SKILL.md _capability-template tests/run-all.sh tests/test-validate-agent.sh
git commit -m "feat: template follows Agent Standard 1.2; setup binds tools"
```

---

### Task 4: Standard text, wizard, docs, builder 1.2.0

**Files:**
- Modify: `STANDARD.md`, `skills/new-agent/SKILL.md`, `docs/writing-an-agent.md`, `README.md`
- Modify: `.claude-plugin/plugin.json`, `gemini-extension.json`, `.codex-plugin/plugin.json` (version `1.2.0`)
- Modify: `tests/test-builder-manifests.sh` (expects `1.2.0`)

**Interfaces:**
- Consumes: the names and messages from Tasks 1–3.

- [ ] **Step 1: Failing test** — in `tests/test-builder-manifests.sh`, change the expected version `"1.1.0"` to `"1.2.0"`. Run it; expect a failure.

- [ ] **Step 2: Versions** — `1.1.0` → `1.2.0` in the three builder manifests. Run `tests/test-builder-manifests.sh`; expect it to pass.

- [ ] **Step 3: `STANDARD.md`**
  - Title: `# Agent Standard 1.2`. In `## Versioning`, add a line saying 1.2 adds capabilities, adapters, bindings, and the guard hook (additive; 1.1 agents stay valid).
  - In `## Agent manifest`, document the optional flat key `capabilities: crm, email_drafts` (comma-separated `snake_case` names).
  - Insert these sections before `## Validation`:

```markdown
## Capabilities and adapters (1.2)

A capability is an outside system the agent works through — a CRM, a
mailbox. The package describes it in two layers:

- `capabilities/<capability>/contract.md` — the neutral operations the
  agent thinks in (a `## Operations` table whose first column is each
  operation name in backticks) and the rules every adapter must uphold
  (a `## Invariants` list, each item starting with a `snake_case` id in
  backticks). Skills and sub-agent contracts call operations, never a
  provider's tools.
- `capabilities/<capability>/adapters/<provider>/` — one folder per
  system: `adapter.md` maps every operation to that provider's tools
  and has a `## Probe` section (read-only calls setup makes when
  binding); `adapter.yaml` holds flat keys:

      capability: crm
      provider: attio
      server_match: attio          # substring of the MCP server name, any case
      block: delete, merge         # optional: tool-name substrings refused
      guard: guard.py              # optional: argument checks (package adapters only)
      deny: delete-record          # optional: tool-name suffixes for host-deny
      enforce_draft_only: adapter  # one line per contract invariant

Enforcement levels: `adapter` (a mechanism in the package holds it —
no violating tool exists, `block` removes it, or `guard` rejects the
arguments), `host-deny` (setup writes host deny rules for the `deny`
tools), `instruction` (only the agent's instructions hold it). An
invariant named `no_send` can never be `instruction`.

## Bindings (1.2)

`instance.yaml` binds each capability with one flat line,
`bind_<capability>: <provider>`. `custom` means the instance's own
adapter in `custom-adapters/<capability>/` (it may use `block`, never
`guard`). What the probe discovers — workspace IDs, optional
attributes — goes in the instance's `bindings/<capability>.md`. A
capability with no binding is not set up: the agent offers setup's
tools step instead of calling anything. Credentials stay in the host.

## Guard hook (1.2)

`hooks/guard.sh`, byte-identical to `_template/hooks/guard.sh`, is
registered in `hooks/hooks.json` as a `PreToolUse` command hook with
matcher `mcp__.*` and command `"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"`.
Inside an instance of the agent (source mode included) it refuses any
tool of a bound adapter's servers whose name contains a `block` entry,
then runs the adapter's `guard` with `python3`, the hook input on
stdin. Exit 2 blocks. It fails closed: a missing guard, a missing
`python3`, a guard crash, or hook input naming two different tools
blocks the call. Outside an instance it allows everything.

A guard reads the hook input JSON, exits 2 with one stderr line per
broken rule, or 0; any internal error must become exit 2.

## Setup — tools step (1.2)

Setup's tools step binds each capability: pick an adapter (or write a
custom one), find the matching connected server, run the probe, write
`bind_<capability>` and `bindings/<capability>.md`, merge deny rules
into `.claude/settings.json`, and report which capabilities are
unattended-safe (every invariant at `adapter`, or `host-deny` with its
rules written). It refuses to bind a `no_send` capability enforced by
`instruction`. Scheduled runs may use only unattended-safe
capabilities.
```

  - In `## Validation`, add a paragraph listing the 1.2 checks, one per bullet, using the spec's "Validator (1.2 agents)" list.

- [ ] **Step 4: `skills/new-agent/SKILL.md`**
  - Step 4: `standard: "1.1"` → `standard: "1.2"`; "The template is Agent Standard 1.1" → "1.2"; "keep `hooks/` exactly as copied" stays (it now covers both scripts).
  - Step 5: add a bullet after "Context files":

```markdown
   - Tools — which outside systems the agent reads or writes (a CRM,
     a mailbox). For each, pick a `snake_case` capability name, copy
     `<builder>/_capability-template/` to `capabilities/<name>/`, write
     the contract's operations and invariants, rename
     `adapters/example-provider/` to the first system's kebab-case
     name and fill its `adapter.md`, `## Probe`, and `adapter.yaml`
     (set `capability` and `provider` to the folder names). List the
     names in `agent.yaml` as `capabilities: a, b`. Skills and
     sub-agents name operations, never a system's tools. If the agent
     must never send messages, give the capability a `no_send`
     invariant and enforce it with `block: send`.
```

  (`<builder>` is the folder the wizard already calls `<template>`'s parent. Use the same variable style the skill already uses for `<template>`.)

- [ ] **Step 5: `docs/writing-an-agent.md`** — add a `## Tools` section: contract vs adapter, the three enforcement levels, `block` vs `guard`, bindings in `instance.yaml`, and "skills name operations, not tools". Point at `STANDARD.md` for the details. Keep it under 30 lines.

- [ ] **Step 6: `README.md`** — every "Agent Standard 1.1" becomes "1.2". Add one sentence to the feature list: agents can declare tools (capabilities) that users bind to their own CRM or mailbox, with a guard that enforces the agent's safety rules.

- [ ] **Step 7: Verify** — `tests/run-all.sh` ends `ALL GREEN`. `grep -rn 'Standard 1\.1' README.md skills/new-agent/SKILL.md` prints only intentional historical mentions.

- [ ] **Step 8: Commit and push**

```bash
git add STANDARD.md skills/new-agent/SKILL.md docs/writing-an-agent.md README.md .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json tests/test-builder-manifests.sh
git commit -m "docs: Agent Standard 1.2 text, wizard tools step; builder 1.2.0"
git push -u origin feat/standard-1.2
```

---

## sales-partner (tasks 5–7) — repo `/Users/hochoy/Work/Webspenser/sales-partner`, branch `release/1.1.0`

Validate locally with the builder branch's validator: `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .` (the builder checkout must be on `feat/standard-1.2`).

### Task 5: CRM capability — move the contract and the Airtable adapter; adopt 1.2 hooks

**Files:**
- Move: `context/crm-contract.md` → `capabilities/crm/contract.md`
- Move: `context/crm-airtable-adapter.md` → `capabilities/crm/adapters/airtable/adapter.md`
- Create: `capabilities/crm/adapters/airtable/adapter.yaml`
- Create: `hooks/guard.sh` (copy of the builder's `_template/hooks/guard.sh`, mode 755)
- Replace: `hooks/hooks.json` (copy of the builder's `_template/hooks/hooks.json`)
- Modify: `agent.yaml`, `AGENT.md`, `README.md`, `skills/send-digest/SKILL.md`, `subagents/approacher.md`, `subagents/follow-up.md`, `context/operating-config.md`, `evals/cases.md`, `tests/test-content.sh`

**Interfaces:**
- Produces: the paths `capabilities/crm/contract.md` and `capabilities/crm/adapters/<provider>/adapter.md`, and the invariant ids `draft_only`, `dnc_one_way`, `no_delete` (Task 6's Attio `adapter.yaml` must declare exactly these).

- [ ] **Step 1: Branch**

```bash
git -C /Users/hochoy/Work/Webspenser/sales-partner switch -c release/1.1.0
```

- [ ] **Step 2: Failing content tests.** In `tests/test-content.sh`:
  - Change `C="$SP/context/crm-contract.md"; A="$SP/context/crm-airtable-adapter.md"` to `C="$SP/capabilities/crm/contract.md"; A="$SP/capabilities/crm/adapters/airtable/adapter.md"`.
  - Replace the two AGENT.md assertions at the end (`'`context/crm-contract.md` and `context/crm-airtable-adapter.md`, which'` and `'are package files, read from the package'`) with the ones in the block below, placed before `finish`:

```bash
echo "-- capabilities (Agent Standard 1.2)"
assert_contains "$SP/agent.yaml" 'standard: "1.2"'
assert_contains "$SP/capabilities/crm/contract.md" '## Invariants'
assert_contains "$SP/capabilities/crm/contract.md" '- `draft_only` —'
assert_contains "$SP/capabilities/crm/contract.md" '- `dnc_one_way` —'
assert_contains "$SP/capabilities/crm/contract.md" '- `no_delete` —'
assert_contains "$SP/capabilities/crm/adapters/airtable/adapter.md" '## Probe'
assert_contains "$SP/capabilities/crm/adapters/airtable/adapter.yaml" 'enforce_draft_only: instruction'
assert_contains "$SP/AGENT.md" 'bound in `instance.yaml` (`bind_crm`)'
[ ! -e "$SP/context/crm-contract.md" ] && [ ! -e "$SP/context/crm-airtable-adapter.md" ] \
  && _report ok "CRM files left context/" || _report no "CRM files still in context/"
while IFS= read -r f; do
  assert_not_contains "$f" 'context/crm-'
done < <(find "$SP" -name '*.md' -not -path './docs/*' -not -path './tests/*' -not -path './.git/*' -not -path './migrations/*')
```

Run `tests/test-content.sh`; expect failures (the files haven't moved yet).

- [ ] **Step 3: Move**

```bash
mkdir -p capabilities/crm/adapters/airtable
git mv context/crm-contract.md capabilities/crm/contract.md
git mv context/crm-airtable-adapter.md capabilities/crm/adapters/airtable/adapter.md
```

- [ ] **Step 4: Contract.** In `capabilities/crm/contract.md`:
  - Replace every `crm-airtable-adapter.md` with `the Airtable adapter (\`adapters/airtable/adapter.md\`)`. Where the sentence is about adapters in general (the intro around line 14), say "each adapter (`adapters/<provider>/adapter.md`)" instead.
  - Insert this section immediately before `## Stage enum`:

```markdown
## Invariants

Each adapter declares in its `adapter.yaml` how it enforces each of
these — `adapter`, `host-deny`, or `instruction` (Agent Standard 1.2).

- `draft_only` — the agent creates Activities only at `status: draft`,
  and the only status it may later write is `voided`; `approved` and
  `sent` are the operator's alone (see Approval invariant).
- `dnc_one_way` — `Do Not Contact`, once true, is never cleared.
- `no_delete` — the agent never deletes or merges CRM records.
```

- [ ] **Step 5: Airtable adapter.** In `capabilities/crm/adapters/airtable/adapter.md`:
  - Replace `crm-contract.md` with `the contract (\`../../contract.md\`)` on its first mention and `the contract` afterwards.
  - Append:

```markdown
## Probe

Setup runs these read-only calls when binding this adapter, and writes
what they find to `bindings/crm.md` in the instance:

1. `airtable:search_bases` (or `list_bases`) — find the base that
   holds the Leads, Contacts, Research, and Activities tables; ask the
   operator if more than one could. Record `base_id` and `base_name`.
2. `airtable:list_tables_for_base` on that base — every table and
   field named in this adapter must exist with the listed type.

`airtable:` means the connected Airtable server's tools, whatever
their prefix. If a table or field is missing, show the operator the
list and stop; this adapter has no bootstrap script.
```

  Create `capabilities/crm/adapters/airtable/adapter.yaml`:

```yaml
capability: crm
provider: airtable
server_match: airtable
block: delete
enforce_draft_only: instruction
enforce_dnc_one_way: instruction
enforce_no_delete: adapter
```

- [ ] **Step 6: Hooks.**

```bash
cp /Users/hochoy/Work/Webspenser/agent-library/_template/hooks/guard.sh hooks/guard.sh
cp /Users/hochoy/Work/Webspenser/agent-library/_template/hooks/hooks.json hooks/hooks.json
chmod 755 hooks/guard.sh
```

- [ ] **Step 7: `agent.yaml`** — `standard: "1.2"` and a new line `capabilities: crm` (Task 7 adds `email_drafts`). Leave `version` for Task 7.

- [ ] **Step 8: References.**
  - `AGENT.md` Inputs, the "CRM credentials" bullet: replace its first line `- CRM credentials — Airtable is the first adapter for the neutral CRM` with `- A CRM, bound in \`instance.yaml\` (\`bind_crm\`) to one of the adapters in \`capabilities/crm/adapters/\` — the neutral CRM`. Keep the rest (the eleven operations).
  - `AGENT.md` "Where these files live" bullet: replace the title with `(Agent Standard 1.2)`. Replace the clause "except `context/crm-contract.md` and `context/crm-airtable-adapter.md`, which are package files, read from the package" with "`capabilities/` (contracts and adapters) is the package's, and `bindings/` holds what setup learned about the user's connected systems". Add `capabilities/` to the list of package folders.
  - `AGENT.md` guardrail near line 203: `(\`context/crm-contract.md\`)` → `(\`capabilities/crm/contract.md\`)`.
  - Every other file listed under **Files**: `context/crm-contract.md` and bare `crm-contract.md` → `capabilities/crm/contract.md`. `context/crm-airtable-adapter.md` and bare `crm-airtable-adapter.md` → `capabilities/crm/adapters/airtable/adapter.md`, except where the sentence means the operator's CRM in general (named views, the approval queue). There write "the bound CRM adapter" and keep the Airtable path as an example in parentheses. Read each hit in `skills/send-digest/SKILL.md`, `context/operating-config.md`, and `evals/cases.md` before changing it.
  - `README.md` "Tools it needs": replace the CRM bullet with `- A CRM — Attio or Airtable (\`capabilities/crm/adapters/\`); setup binds it after a read-only check.`
  - Do not touch `docs/` or `migrations/`: they are history.

- [ ] **Step 9: Verify**

Run: `tests/run-all.sh`. Expected: `ALL GREEN`.
Run: `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .`. Expected: `OK` (WARN about AGENT.md size is fine).
Run: `grep -rn 'context/crm-' --include='*.md' . | grep -v -e '^./docs/' -e '^./migrations/'`. Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: CRM capability with contract invariants and the Airtable adapter (Standard 1.2)"
```

Check `git ls-files -s hooks/guard.sh` shows `100755`.

---

### Task 6: Attio adapter — port, guard, bootstrap

**Files:**
- Create: `capabilities/crm/adapters/attio/adapter.md`, `adapter.yaml`, `guard.py` (755), `bootstrap.py` (755)
- Create: `tests/test-attio-guard.sh` (755)
- Modify: `tests/run-all.sh`, `tests/test-content.sh`

**Interfaces:**
- Consumes: invariant ids from Task 5; `guard.sh`'s contract (hook input on stdin, exit 2 blocks).
- Sources (read only): `/Users/hochoy/Work/Webspenser/live-agents/agent-library/sales-partner/context/crm-attio-adapter.md` and `.../scripts/attio_bootstrap.py`.

- [ ] **Step 1: Failing guard tests** — `tests/test-attio-guard.sh`:

```bash
#!/usr/bin/env bash
# Rules of the Attio guard (capabilities/crm/adapters/attio/guard.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
G=capabilities/crm/adapters/attio/guard.py
P=mcp__claude_ai_Attio__

check() { # check <expected rc> <label> <tool> <tool_input JSON> [stderr text]
  local out rc
  out=$(printf '{"tool_name":"%s%s","tool_input":%s}' "$P" "$3" "$4" | python3 "$G" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && { [ -z "${5:-}" ] || printf '%s\n' "$out" | grep -qF -- "$5"; }; then
    _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
raw() { # raw <expected rc> <label> <whole stdin>
  local out rc; out=$(printf '%s' "$3" | python3 "$G" 2>&1); rc=$?
  [ "$rc" -eq "$1" ] && _report ok "$2" || _report no "$2 (rc=$rc): $out"
}
L='"list":"sales_partner_outreach","parent_object":"companies","parent_record_id":"00000000-0000-0000-0000-000000000001"'
E='"list":"sales_partner_outreach","entry_id":"00000000-0000-0000-0000-000000000002"'

check 0 "create draft"                 add-record-to-list "{$L,\"entry_values\":{\"status\":\"draft\",\"summary\":\"x\"}}"
check 0 "create draft as list"         add-record-to-list "{$L,\"entry_values\":{\"status\":[\"draft\"]}}"
check 2 "create approved"              add-record-to-list "{$L,\"entry_values\":{\"status\":\"approved\"}}" "status may only be written as draft"
check 2 "create sent via option"       add-record-to-list "{$L,\"entry_values\":{\"status\":{\"option\":\"sent\"}}}"
check 2 "create voided"                add-record-to-list "{$L,\"entry_values\":{\"status\":\"voided\"}}"
check 0 "create lead, dnc false ok"    add-record-to-list "{$L,\"entry_values\":{\"stage\":\"New\",\"do_not_contact\":false}}"
check 0 "update voided"                update-list-entry-by-id "{$E,\"entry_values\":{\"status\":\"voided\",\"outcome\":\"dup\"}}"
check 2 "update draft"                 update-list-entry-by-id "{$E,\"entry_values\":{\"status\":\"draft\"}}" "status may only be written as voided"
check 2 "update approved by record"    update-list-entry-by-record-id "{$L,\"entry_values\":{\"status\":\"Approved\"}}"
check 2 "status by option UUID"        update-list-entry-by-id "{$E,\"entry_values\":{\"status\":\"49e56c99-597b-40b5-9413-162ce1adadfc\"}}"
check 2 "unknown value shape"          update-list-entry-by-id "{$E,\"entry_values\":{\"status\":{\"foo\":1}}}" "cannot check this call"
check 2 "dnc cleared"                  update-list-entry-by-id "{$E,\"entry_values\":{\"do_not_contact\":false}}" "do_not_contact is one-way"
check 2 "dnc cleared as string"        update-list-entry-by-id "{$E,\"entry_values\":{\"do_not_contact\":\"false\"}}"
check 0 "dnc set true"                 update-list-entry-by-id "{$E,\"entry_values\":{\"do_not_contact\":true}}"
check 0 "dnc set \"true\""             update-list-entry-by-id "{$E,\"entry_values\":{\"do_not_contact\":\"true\"}}"
check 2 "attribute by ID"              update-list-entry-by-id "{$E,\"entry_values\":{\"925c1cde-cba6-453e-96f9-5bd8f498d8a3\":\"sent\"}}" "addressed by ID"
check 2 "upsert with approved"         upsert-record '{"object":"people","matching_attribute":"email_addresses","values":{"status":"approved"}}'
check 0 "update person"                update-record '{"object":"people","record_id":"00000000-0000-0000-0000-000000000003","values":{"sp_role":"influencer"}}'
check 2 "create-list refused"          create-list '{"name":"x"}' "list configuration"
check 2 "update-list refused"          update-list '{"list":"sales_partner_outreach"}'
check 0 "read tool allowed"            list-records-in-list '{"list":"sales_partner_outreach"}'
check 2 "entry_values not an object"   update-list-entry-by-id "{$E,\"entry_values\":[1]}"
check 2 "tool_input not an object"     update-list-entry-by-id '"x"'
raw   2 "malformed JSON blocks"        '{not json'
raw   2 "no tool_name blocks"          '{"tool_input":{}}'
[ -x "$G" ] && _report ok "guard is executable" || _report no "guard not executable"

finish
```

`chmod 755 tests/test-attio-guard.sh`. Add `echo "== attio guard"; tests/test-attio-guard.sh || STATUS=1` to `tests/run-all.sh` after the content line. Run it; expect failures (no guard yet).

- [ ] **Step 2: `capabilities/crm/adapters/attio/guard.py`**

```python
#!/usr/bin/env python3
"""Attio guard for sales-partner's CRM invariants (Agent Standard 1.2).

hooks/guard.sh runs this before every call to an Attio MCP tool inside a
sales-partner instance, with the hook input JSON on stdin. Exit 2 blocks the
call and stderr tells the model why; exit 0 allows it. Anything unexpected
blocks: a bug here must fail closed.

Rules (capabilities/crm/contract.md, Invariants):
  draft_only  - a new entry may carry status "draft" only; an update may set
                status to "voided" only. approved and sent are the operator's,
                set in the Attio app, which never passes through this hook.
  dnc_one_way - an update may write do_not_contact only as true.
  no_delete   - list configuration tools are refused; deletes and merges are
                refused by adapter.yaml's `block`.
Write calls must key attributes by api slug: an attribute ID could hide
`status` or `do_not_contact`.
"""
import json
import re
import sys

CREATE_TOOLS = {"add-record-to-list", "create-record"}
UPDATE_TOOLS = {"update-list-entry-by-id", "update-list-entry-by-record-id",
                "update-record", "upsert-record"}
REFUSED_TOOLS = {"create-list", "update-list"}
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def scalars(value):
    """Leaf values of an Attio value: a scalar, a list, or {option|status|value|title: ...}."""
    if isinstance(value, list):
        return [leaf for item in value for leaf in scalars(item)]
    if isinstance(value, dict):
        leaves = [leaf for key in ("option", "status", "value", "title") if key in value
                  for leaf in scalars(value[key])]
        if not leaves:
            raise ValueError("unrecognized value shape")
        return leaves
    return [value]


def as_text(values):
    return [str(v).strip().lower() for v in values]


def problems(event):
    tool_name = event.get("tool_name")
    if not isinstance(tool_name, str) or "__" not in tool_name:
        raise ValueError("no MCP tool_name in the hook input")
    tool = tool_name.rsplit("__", 1)[1]
    if tool in REFUSED_TOOLS:
        return [f"{tool} changes the workspace's list configuration; sales-partner never does"]
    if tool not in CREATE_TOOLS | UPDATE_TOOLS:
        return []
    args = event.get("tool_input")
    if not isinstance(args, dict):
        raise ValueError("tool_input is not an object")
    values = args.get("entry_values", args.get("values", {}))
    if not isinstance(values, dict):
        raise ValueError("attribute values are not an object")
    found = [f"attribute {key} is addressed by ID; use its api slug" for key in values if UUID.match(key)]
    if "status" in values:
        allowed = "draft" if tool in CREATE_TOOLS else "voided"
        if as_text(scalars(values["status"])) != [allowed]:
            found.append(f"status may only be written as {allowed} here (approved and sent are the operator's)")
    if "do_not_contact" in values and tool in UPDATE_TOOLS:
        if as_text(scalars(values["do_not_contact"])) != ["true"]:
            found.append("do_not_contact is one-way and can only be set to true")
    return found


def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("hook input is not an object")
        found = problems(event)
    except Exception as err:  # fail closed
        print(f"Blocked by the Attio guard: cannot check this call ({type(err).__name__}: {err})", file=sys.stderr)
        return 2
    for problem in found:
        print(f"Blocked by the Attio guard: {problem} (capabilities/crm/adapters/attio/adapter.md)", file=sys.stderr)
    return 2 if found else 0


if __name__ == "__main__":
    sys.exit(main())
```

`chmod 755` it. Run `tests/test-attio-guard.sh`; expect `0 failed`.

- [ ] **Step 3: `adapter.yaml`**

```yaml
capability: crm
provider: attio
server_match: attio
block: delete, merge
guard: guard.py
enforce_draft_only: adapter
enforce_dnc_one_way: adapter
enforce_no_delete: adapter
```

- [ ] **Step 4: `adapter.md`.** Copy the live `crm-attio-adapter.md`, then edit:
  - Title `# CRM — Attio adapter`. Opening paragraph: "Maps the contract (`../../contract.md`) onto Attio: …". Delete the sentence about `crm-airtable-adapter.md` staying in the folder.
  - "The schema is created by `scripts/attio_bootstrap.py`" → "The schema is created by `bootstrap.py` in this folder (see Probe)".
  - Replace the "Workspace: **Webspenser**. Object IDs used in record-reference filters: …" paragraph with: "The workspace's object IDs for `companies` and `people` (used in record-reference filters) are in the instance's `bindings/crm.md`, written by the probe. `attio:` below means the connected Attio server's tools, whatever their prefix."
  - In `upsert_contact` and the People table: `lead_source` = `Outbound` is set on create only, and only when `bindings/crm.md` says `lead_source_outbound: yes`. Say this in both places.
  - Every `crm-contract.md` → "the contract"; every `crm-airtable-adapter.md` reference (e.g. Research `summary`/`hook` meaning) → "the Airtable adapter (`../airtable/adapter.md`)".
  - Remove "In the tool names, `attio:` is short for `mcp__claude_ai_Attio__`." (superseded by the sentence above).
  - Replace the whole "## Approval invariant under Attio" section body with:

```markdown
Attio's `update-list-entry-by-id` can write any value to any
attribute, so the contract's guarantees are enforced by mechanism:

1. **`guard.py` in this folder** runs before every Attio call inside an
   instance (the agent's `hooks/guard.sh` starts it; nothing to wire by
   hand). It blocks any write of `status` other than `draft` on create
   or `voided` on update, any `do_not_contact` update other than
   `true`, attribute keys given as IDs instead of slugs, and list
   configuration changes. The operator's own edits in the Attio app
   never pass through it, so approving and sending stay operator-only.
2. **`adapter.yaml` blocks** every Attio tool whose name contains
   `delete` or `merge`.
3. **Nothing can send.** Email goes through the `email_drafts`
   capability, whose adapter blocks send tools.
```

  - Append:

```markdown
## Probe

Setup runs these read-only calls when binding this adapter, and writes
what they find to `bindings/crm.md` in the instance:

1. `attio:whoami` — record `workspace:`.
2. `attio:list-objects` — record `companies_object_id:` and
   `people_object_id:`.
3. `attio:list-list-attribute-definitions` on `sales_partner_pipeline`,
   `sales_partner_research`, and `sales_partner_outreach` — every slug
   in the Schema tables above must exist, and `stage` must hold the
   twelve stages.
4. `attio:list-attribute-definitions` on `people` — `sp_role`,
   `sp_verified`, and `sp_notes` must exist. Record
   `lead_source_outbound: yes` if `lead_source` exists with an
   `Outbound` option, otherwise `no`.

If step 3 or 4 finds anything missing, offer the schema script. The
operator sets `ATTIO_API_KEY` in their shell (never in a file; token
scopes: object_configuration, list_configuration, record_permission,
list_entry, all read-write) and runs
`python3 "<package>/capabilities/crm/adapters/attio/bootstrap.py"`.
It only adds what is missing. Then probe again.

`bindings/crm.md` looks like:

    # CRM binding — Attio
    workspace: Acme
    companies_object_id: 1da534c1-…
    people_object_id: 77bbcd3e-…
    lead_source_outbound: no
```

  - Check that each of the eleven operations appears in backticks (`grep -c` for each). Check there is no `Webspenser` and no hard-coded object ID: `grep -nE 'Webspenser|1da534c1|77bbcd3e' capabilities/crm/adapters/attio/adapter.md` should print only the `bindings/crm.md` example lines.

- [ ] **Step 5: `bootstrap.py`.** Copy the live `attio_bootstrap.py`, then:
  - Docstring: replace "Reads ATTIO_API_KEY from ./.env (gitignored)." with "Reads ATTIO_API_KEY from the environment (set it in your shell; never write it to a file)." Replace the usage line with `python3 capabilities/crm/adapters/attio/bootstrap.py`. Refer to `adapter.md` instead of `context/crm-attio-adapter.md`.
  - Remove `HERE`/`ENV`. Replace `load_key` with:

```python
def load_key():
    key = os.environ.get("ATTIO_API_KEY", "").strip()
    if not key:
        sys.exit("ATTIO_API_KEY is not set. Export it in your shell for this run; never store it in a file.")
    return key
```

  - Replace the module-level `KEY = load_key()` with `KEY = None`, and make `KEY = load_key()` the first line of the `if __name__ == "__main__":` block (that assignment sets the module global that `call` reads). Importing the module must not exit.
  - `chmod 755`. Check: `python3 -c "import ast,sys; ast.parse(open('capabilities/crm/adapters/attio/bootstrap.py').read())"` succeeds. `env -u ATTIO_API_KEY python3 capabilities/crm/adapters/attio/bootstrap.py` exits non-zero with the "is not set" message and makes no network call.

- [ ] **Step 6: Content tests.** Add to `tests/test-content.sh` before `finish`:

```bash
echo "-- Attio adapter"
AT="$SP/capabilities/crm/adapters/attio"
assert_contains "$AT/adapter.md" '## Probe'
assert_contains "$AT/adapter.md" 'lead_source_outbound: yes'
assert_not_contains "$AT/adapter.md" 'Webspenser'
assert_not_contains "$AT/bootstrap.py" '.env'
for op in create_lead get_lead update_stage update_lead log_activity update_activity log_research upsert_contact query_by_stage query_by_score query_activities; do
  assert_contains "$AT/adapter.md" "\`$op\`"
done
```

- [ ] **Step 7: Verify** — `tests/run-all.sh` ends `ALL GREEN`, and the builder validator prints `OK` for `.`.

- [ ] **Step 8: Commit**

```bash
git add capabilities/crm/adapters/attio tests/test-attio-guard.sh tests/run-all.sh tests/test-content.sh
git commit -m "feat: Attio CRM adapter with a fail-closed guard and env-only bootstrap"
```

Check `git ls-files -s capabilities/crm/adapters/attio tests/test-attio-guard.sh` shows `100755` for the three scripts.

---

### Task 7: Email drafts capability, setup's tools step, release 1.1.0

**Files:**
- Create: `capabilities/email_drafts/contract.md`, `capabilities/email_drafts/adapters/gmail/adapter.md`, `capabilities/email_drafts/adapters/gmail/adapter.yaml`
- Create: `migrations/1.0.1-1.1.0.md`
- Modify: `agent.yaml`, `.claude-plugin/plugin.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`, `.claude-plugin/marketplace.json` (only if it carries a version), `skills/setup/SKILL.md`, `AGENT.md`, `subagents/follow-up.md`, `subagents/approacher.md`, `skills/send-digest/SKILL.md`, `context/operating-config.md`, `README.md`, `tests/test-content.sh`

**Interfaces:**
- Consumes: the tools-step text from builder Task 3, Step 3 (copy verbatim from `/Users/hochoy/Work/Webspenser/agent-library/_template/skills/setup/SKILL.md`).

- [ ] **Step 1: Failing content tests** — add before `finish`:

```bash
echo "-- email drafts and release 1.1.0"
assert_contains "$SP/agent.yaml" 'capabilities: crm, email_drafts'
assert_contains "$SP/agent.yaml" 'version: 1.1.0'
assert_contains "$SP/capabilities/email_drafts/contract.md" '- `no_send` —'
assert_contains "$SP/capabilities/email_drafts/adapters/gmail/adapter.yaml" 'block: send'
assert_contains "$SP/capabilities/email_drafts/adapters/gmail/adapter.yaml" 'enforce_no_send: adapter'
assert_contains "$SP/skills/setup/SKILL.md" '**Tools.**'
assert_contains "$SP/skills/setup/SKILL.md" '`standard: "1.2"`'
assert_contains "$SP/migrations/1.0.1-1.1.0.md" 'tools step'
assert_contains "$SP/skills/send-digest/SKILL.md" 'cannot send; delivered as a draft'
assert_contains "$SP/subagents/follow-up.md" '`email_drafts` — `create_draft`'
assert_not_contains "$SP/subagents/follow-up.md" '- Gmail — draft only'
```

Run it; expect failures.

- [ ] **Step 2: `capabilities/email_drafts/contract.md`**

```markdown
# Email drafts contract

The agent composes email as drafts in the operator's mailbox for the
operator to review. It never sends: turning a draft into a sent
message is an operator action taken outside the agent's tools.

## Operations

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `create_draft` | `to, subject, body`, optional `cc` | `draft_id` | Rejects an empty `to` or `body` |
| `search_threads` | `query` | matching threads (sender, subject, date, snippet); read-only | Empty list is a valid result |

## Invariants

- `no_send` — no operation sends mail, and the bound adapter makes
  sending impossible rather than merely discouraged.
```

- [ ] **Step 3: Gmail adapter.** `capabilities/email_drafts/adapters/gmail/adapter.md`:

```markdown
# Email drafts — Gmail adapter

Maps the contract (`../../contract.md`) onto a Gmail MCP server.
`gmail:` means the connected Gmail server's tools, whatever their
prefix; if that server names them differently, use its equivalent
draft-create and thread-search tools.

- `create_draft` — `gmail:create_draft` with `to`, `subject`, `body`
  (and `cc`). Return the draft's id as `draft_id`.
- `search_threads` — `gmail:search_threads` with the query; use
  `gmail:get_thread` when the caller needs a thread's messages.

`adapter.yaml` blocks every tool of the matched server whose name
contains `send`, so `no_send` holds by mechanism even on a Gmail
server that offers sending.

## Probe

1. `gmail:list_drafts` must succeed (read-only). Write
   `mailbox: <address>` to `bindings/email_drafts.md` in the instance
   when the result shows the address; otherwise ask the operator which
   mailbox this is.
```

`capabilities/email_drafts/adapters/gmail/adapter.yaml`:

```yaml
capability: email_drafts
provider: gmail
server_match: gmail
block: send
enforce_no_send: adapter
```

- [ ] **Step 4: References to Gmail.**
  - `AGENT.md` Inputs: replace the bullet starting `- Gmail access, draft-only —` with `- Email drafts, through the \`email_drafts\` capability (\`capabilities/email_drafts/\`, bound in \`instance.yaml\` as \`bind_email_drafts\`) — \`create_draft\` composes the body of approach and follow-up email Activities for operator review, and \`search_threads\` reads replies. Its adapter blocks every send tool: turning a draft into a sent message is an operator action outside the agent's tools.` Keep the digest bullet that follows, but change "Gmail draft" to "draft (`create_draft`)".
  - `subagents/follow-up.md`: `- Gmail — draft only` → ``- `email_drafts` — `create_draft` and `search_threads` only``. In the paragraph after it, change "Gmail access is limited to composing a draft" to "`email_drafts` offers only drafting and reading, and its adapter blocks every send tool".
  - `subagents/approacher.md`: if it names Gmail as a tool, point it at `email_drafts` `create_draft` the same way.
  - `skills/send-digest/SKILL.md` step 10: after the paragraph on the default draft, add:

```markdown
    With Agent Standard 1.2 the email binding blocks every send tool,
    so `digest_delivery: send` cannot be honored: compose the draft
    exactly as for `draft` and put this line first, above the `#`
    heading: "digest_delivery is send, but this agent's email binding
    cannot send; delivered as a draft." A future `email_send`
    capability would make direct delivery possible.
```

  - `context/operating-config.md`, the `digest_delivery` description: add one sentence: "Under Agent Standard 1.2, `send` falls back to a draft (the email binding blocks send tools); see `skills/send-digest/SKILL.md`."
  - `README.md` "Tools it needs": the Apify/Gmail bullet becomes `- Apify for scraping and web search; Gmail for drafts (setup blocks its send tools).`

- [ ] **Step 5: Setup.** In `skills/setup/SKILL.md`, apply the same edits builder Task 3, Step 3 made to the template: step 1 and step 3 wording, step 4 `` `standard: "1.2"` ``, the new step 9 verbatim, renumbering, and the source-mode note. Keep sales-partner's filled `interview-business` and context-file list. Afterwards, `diff <(sed 's/<interview-skill>/interview-business/g' /Users/hochoy/Work/Webspenser/agent-library/_template/skills/setup/SKILL.md) skills/setup/SKILL.md` must show only the `<context-files>` line.

- [ ] **Step 6: Version 1.1.0** — `agent.yaml`: `version: 1.1.0`, `capabilities: crm, email_drafts`. Set `1.1.0` in `.claude-plugin/plugin.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`.

- [ ] **Step 7: `migrations/1.0.1-1.1.0.md`**

```markdown
# 1.0.1 → 1.1.0

sales-partner now follows Agent Standard 1.2: its CRM and email tools
are capabilities you bind to your own systems, and a guard enforces the
CRM's safety rules by mechanism.

**Your context files do not change shape.**

What to do:

1. Run setup's tools step (`/sales-partner:setup` in this instance, then
   choose the tools step). It binds `crm` (Attio or Airtable) and
   `email_drafts` (Gmail) after a read-only check, writes
   `bind_crm` / `bind_email_drafts` and `standard: "1.2"` to
   `instance.yaml`, writes `bindings/`, and adds deny rules for send
   and delete tools to `.claude/settings.json`.
2. Then set `agent_version: 1.1.0` in `instance.yaml`.

If you wired `attio_guard.py` into `.claude/settings.local.json` by
hand, remove that hook: the agent's own guard replaces it.

Source mode: `context/crm-contract.md` moved to
`capabilities/crm/contract.md`, and `context/crm-airtable-adapter.md`
to `capabilities/crm/adapters/airtable/adapter.md`. The tools step also
adds the guard hook to `.claude/settings.json`.

`digest_delivery: send` now falls back to a draft, because the email
binding blocks send tools.
```

- [ ] **Step 8: Verify**
  - `tests/run-all.sh` → `ALL GREEN`.
  - `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .` → `OK`.
  - `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh . --require-bump origin/main` → passes.
  - `grep -rn 'Gmail' AGENT.md subagents skills/setup` shows no remaining "draft-only Gmail access" wording outside the digest's historical explanation.

- [ ] **Step 9: Commit and push**

```bash
git add -A
git commit -m "feat: email_drafts capability, setup binds tools; release 1.1.0 (Standard 1.2)"
git push -u origin release/1.1.0
```

---

## Task 8: Release and acceptance (controller; the user merges)

- [ ] **Step 1: Builder PR.** Open a PR `feat/standard-1.2` → `main` in `webspenser/agent-builder`, noting that it includes the spec commits from PR #9. The user merges it with a merge commit, not a rebase.
- [ ] **Step 2: Move `v1`.** The user runs:
  `! git -C ~/Work/Webspenser/agent-library fetch origin --tags && git -C ~/Work/Webspenser/agent-library tag -f v1 origin/main && git -C ~/Work/Webspenser/agent-library push -f origin v1`
  Verify: `git -C /Users/hochoy/Work/Webspenser/agent-library ls-remote --tags origin v1` matches `origin/main`.
- [ ] **Step 3: sales-partner PR.** Open a PR `release/1.1.0` → `main`. CI must pass with the 1.2 validator (release rule included). The user merges.
- [ ] **Step 4: Catalog.** In `/Users/hochoy/Work/Webspenser/agent-library-catalog`, on a branch: set the sales-partner status cell in `README.md` to `1.1 — install, run \`/sales-partner:setup\`, bind your CRM`, then `python3 tests/check-catalog.py` → `OK`. Open a PR; the user merges.
- [ ] **Step 5: Acceptance, from GitHub through the catalog.** Record each output.
  1. `claude plugin marketplace add webspenser/agent-library`, then `claude plugin install sales-partner@webspenser`. `claude plugin details sales-partner@webspenser` shows 1.1.0.
  2. In an empty scratch folder `A`, write `instance.yaml`: `agent: sales-partner`, `agent_version: 1.1.0`, `standard: "1.2"`, `mode: plugin`, `bind_crm: attio`. Run `claude -p` in `A` asking it to run the Attio adapter's Probe and write `bindings/crm.md`. Confirm the file lists the workspace's object IDs. The probe only reads.
  3. In `A`, run `claude -p` asking it to call the Attio `update-list-entry-by-id` tool on list `sales_partner_outreach`, entry `00000000-0000-0000-0000-000000000000`, with `status: approved`. The session must report `Blocked by the Attio guard: status may only be written as voided…`, and the call never reaches Attio.
  4. In an empty folder `B` with no `instance.yaml`, ask `claude -p` to call Attio `list-lists`. It succeeds (not blocked).
  5. `claude plugin uninstall sales-partner@webspenser` and `claude plugin marketplace remove webspenser`.
- [ ] **Step 6: Clean up branches** that the user has merged (local and remote), as after earlier sub-projects.
