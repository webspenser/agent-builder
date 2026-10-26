#!/usr/bin/env bash
# Agent Standard guard hook — identical in every agent.
# PreToolUse hook for MCP tools. Inside an instance of this agent, the agent
# guard policy (package-root guard.yaml, deny-only) applies to every MCP call
# (it may exempt the server of one owner_only_send capability, which its own
# tool policy then still enforces); then every bound tool whose server_match appears in the tool name gets its
# guard policy (guard.yaml) enforced by hooks/guard_policy.py. A bound tool whose
# policy pins values, and the exempted owner_only_send tool, also need their
# bindings file to equal its pushed copy (git upstream, else origin/HEAD). Exit 2 blocks the
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

# Git for the pushed-copy check: system config off, replace objects off,
# fsmonitor off, lazy fetch off and every transport refused (an empty
# GIT_ALLOW_PROTOCOL overrides every protocol.* config key, on any git
# version); blobs are read directly (no diff drivers or clean filters).
ugit() { GIT_ALLOW_PROTOCOL= GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 git -C "$instance" -c core.fsmonitor=false -c protocol.allow=never "$@" </dev/null; }
# pushed_ref: the ref holding the pushed copy, in $pref. The branch's
# upstream (@{u}); on a branch with none (a cloud routine clones the default
# branch, then works on a new branch), the remote's default branch
# (refs/remotes/origin/HEAD). Both are bytes that were actually pushed.
pushed_ref() {
  pref='@{u}'
  ugit rev-parse --verify --quiet "$pref" >/dev/null 2>&1 && return 0
  pref=$(ugit symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || return 1
  ugit rev-parse --verify --quiet "$pref" >/dev/null 2>&1
}
# pushed <cap>: the agent can write bindings/, so values a tool policy pins
# must equal the pushed copy. This stops edits and unpushed commits. It does
# not stop an agent that edits .git itself (tracking refs, upstream/remote
# config, core.worktree, a .git gitfile, alternates). The engine is then
# given the verified pushed bytes, not the working file.
pushed() {
  _bp="bindings/$1.md"
  [ -f "$instance/$_bp" ] && [ ! -L "$instance/$_bp" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  pushed_ref || return 1
  ugit cat-file -e "$pref:$_bp" >/dev/null 2>&1 || return 1
  ugit cat-file blob "$pref:$_bp" 2>/dev/null | cmp -s - "$instance/$_bp"
}
pushed_msg() { printf '%s' "bindings/$1.md must be committed and pushed before $1 can run (it differs from the pushed copy, is untracked, or the instance has neither a git upstream nor an origin/HEAD); re-run setup's tools step, then commit and push"; }

# Private scratch for the bind loop (policy snapshot, verified bindings copy);
# removed on every exit path, including the early exit 2 blocks.
tmp=""
trap '[ -z "$tmp" ] || rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

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
# engine, which fails closed on it. A capability the policy lists in exempt:
# lifts its deny for the bound tool's server, but only while that tool's own
# guard.yaml covers owner_only_send and its pinned bindings file matches the
# pushed copy; the bind_ loop below still enforces the tool policy.
apolicy="$root/guard.yaml"
if [ -e "$apolicy" ] || [ -L "$apolicy" ]; then
  engine="$root/hooks/guard_policy.py"
  [ -f "$engine" ] || ablock "the guard policy engine is missing from $name"
  command -v python3 >/dev/null 2>&1 || ablock "python3 is required to run the guard policy"
  set -- --agent "$apolicy" "$name agent guard policy"
  for ecap in $(python3 "$engine" --exempt-caps "$apolicy" 2>/dev/null); do
    case "$ecap" in ''|*[!a-z0-9_]*) continue ;; esac
    eprov=$(lower "$(yaml_get "$instance/instance.yaml" "bind_$ecap")")
    case "$eprov" in ''|*[!a-z0-9-]*) continue ;; esac
    # Only a tool shipped in the package can lift the deny: custom-tools/ is
    # instance content the agent can write, so a custom binding grants nothing.
    [ "$eprov" != custom ] || continue
    etdir="$root/capabilities/$ecap/tools/$eprov"
    ematch=$(lower "$(yaml_get "$etdir/identity.yaml" server_match)")
    case "$ematch" in ''|*[!a-z0-9_-]*) continue ;; esac
    [ -f "$etdir/guard.yaml" ] && [ ! -L "$etdir/guard.yaml" ] || continue
    python3 "$engine" --covers "$etdir/guard.yaml" 2>/dev/null | grep -qx owner_only_send || continue
    case "$rest_lc" in *"$ematch"*) ;; *) continue ;; esac
    pushed "$ecap" || ablock "$(pushed_msg "$ecap")"
    set -- "$@" --exempt "$ematch"
  done
  printf '%s' "$input" | python3 "$engine" "$@"; rc=$?
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
  # The tool policy and the pinned bindings can be agent-writable (source mode,
  # custom-tools/, bindings/): read each once into private scratch, so the
  # checks below and the engine see the same bytes.
  if [ -z "$tmp" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/guard.XXXXXX" 2>/dev/null) || { tmp=""; pblock "cannot check this call (no private temporary directory)"; }
  fi
  cat "$tdir/guard.yaml" > "$tmp/policy" 2>/dev/null || pblock "cannot check this call (the guard policy cannot be read)"
  pins=$(python3 "$engine" --pins "$tmp/policy" 2>&1); prc=$?
  if [ "$prc" -ne 0 ]; then
    case "$pins" in
      "FAIL: "*) pblock "cannot check this call (${pins#FAIL: })" ;;
      *) pblock "the guard policy engine failed (exit $prc)" ;;
    esac
  fi
  bfile="$instance/bindings/$cap.md"
  [ -f "$bfile" ] || bfile=-
  if [ -n "$pins" ]; then
    pushed "$cap" || pblock "$(pushed_msg "$cap")"
    ugit cat-file blob "$pref:bindings/$cap.md" > "$tmp/bindings" 2>/dev/null || pblock "$(pushed_msg "$cap")"
    bfile="$tmp/bindings"
  fi
  printf '%s' "$input" | python3 "$engine" "$tmp/policy" "$bfile" "$name guard policy ($cap/$provider)" "$match"; rc=$?
  [ "$rc" -eq 0 ] && continue
  [ "$rc" -eq 2 ] && exit 2
  pblock "the guard policy engine failed (exit $rc)"
done < "$instance/instance.yaml"
exit 0
