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
