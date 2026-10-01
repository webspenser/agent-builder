#!/usr/bin/env bash
# Agent Standard guard hook — identical in every agent.
# PreToolUse hook for MCP tools. Inside an instance of this agent, the agent
# guard policy (package-root guard.yaml, deny-only) applies to every MCP call;
# then every bound tool whose server_match appears in the tool name gets its
# guard policy (guard.yaml) enforced by hooks/guard_policy.py. Exit 2 blocks the
# call and shows stderr to the model; exit 0 hands it to the normal permission flow.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

BOM=$(printf '\357\273\277')  # a leading UTF-8 byte-order mark must not hide line 1
yaml_get() { # yaml_get <file> <key>: top-level scalar; quotes and trailing comments removed
  sed -e "1s/^$BOM//" -n -e "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
block() { printf 'Blocked by %s guard: %s\n' "$name" "$1" >&2; exit 2; }
pblock() { printf 'Blocked by %s guard policy (%s/%s): %s\n' "$name" "$cap" "$provider" "$1" >&2; exit 2; }
ablock() { printf 'Blocked by %s agent guard policy: %s\n' "$name" "$1" >&2; exit 2; }

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
agent=$(yaml_get "$instance/instance.yaml" agent)
if [ "$agent" != "$name" ]; then
  # Another agent's instance stays silent; bindings with no agent: line at all are an error.
  [ -z "$agent" ] && sed -e "1s/^$BOM//" "$instance/instance.yaml" 2>/dev/null | grep -q '^bind_' || exit 0
  unnamed=1
fi

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
[ -z "${unnamed:-}" ] || block "instance.yaml has bindings but no agent: line; fix it or re-run setup"
rest_lc=$(lower "${tool#mcp__}")  # server and tool may both contain __: match on the whole

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

first=1
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$first" ] || { line=${line#"$BOM"}; first=""; }
  case "$line" in bind_*) ;; *) continue ;; esac
  # Each line supplies its own key and value, so a repeated bind_ key still
  # applies every tool.
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
    tdir="$instance/custom-tools/$cap"
  else
    tdir="$root/capabilities/$cap/tools/$provider"
  fi
  if [ ! -f "$tdir/identity.yaml" ]; then # binding state unknown: fail closed
    if [ "$provider" = custom ]; then
      block "instance.yaml binds $cap to custom, but custom-tools/$cap/ has no identity.yaml; run the add-tool skill"
    fi
    block "instance.yaml binds $cap to $provider, which has no identity.yaml in $name; fix the binding (setup's tools step)"
  fi
  match=$(lower "$(yaml_get "$tdir/identity.yaml" server_match)")
  # A dangling symlink or a directory still counts as a policy: the engine fails closed on it.
  policy=""; { [ -e "$tdir/guard.yaml" ] || [ -L "$tdir/guard.yaml" ]; } && policy=1
  if [ -z "$match" ]; then
    [ -z "$policy" ] && continue  # no match and no policy: instruction-only
    block "instance.yaml binds $cap to $provider, whose identity.yaml has no server_match, so its guard policy could never apply; fix identity.yaml (tool_check.py)"
  fi
  case "$rest_lc" in *"$match"*) ;; *) continue ;; esac
  [ -n "$policy" ] || continue  # no policy: this tool's invariants are instruction-only
  engine="$root/hooks/guard_policy.py"
  [ -f "$engine" ] || pblock "the guard policy engine is missing from $name"
  command -v python3 >/dev/null 2>&1 || pblock "python3 is required to run the guard policy"
  bfile="$instance/bindings/$cap.md"
  [ -f "$bfile" ] || bfile=-
  printf '%s' "$input" | python3 "$engine" "$tdir/guard.yaml" "$bfile" "$name guard policy ($cap/$provider)" "$match"; rc=$?
  [ "$rc" -eq 0 ] && continue
  [ "$rc" -eq 2 ] && exit 2
  pblock "the guard policy engine failed (exit $rc)"
done < "$instance/instance.yaml"
exit 0
