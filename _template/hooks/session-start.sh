#!/usr/bin/env bash
# Agent Standard entry hook — identical in every agent.
# When the session's folder is (inside) a plugin-mode instance of this agent,
# prints where its files live and the agent's instructions (AGENT.md inline up
# to 9000 bytes, otherwise a pointer to the file). Prints nothing otherwise.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

BOM=$(printf '\357\273\277')  # a leading UTF-8 byte-order mark must not hide line 1
yaml_get() { # yaml_get <file> <key>: top-level scalar; quotes and trailing comments removed
  sed -e "1s/^$BOM//" -n -e "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

version_older() { # version_older <a> <b>: true when a is older than b.
  # Dot-separated fields compared numerically; a non-numeric field means "differs" (older).
  [ "$1" = "$2" ] && return 1
  case "$1$2" in *[!0-9.]*) return 0 ;; esac  # also keeps glob characters out of the split
  local IFS=. i x y
  local -a a b
  a=($1); b=($2)
  local n=${#a[@]}; [ "${#b[@]}" -gt "$n" ] && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    [ "${#x}" -gt 9 ] || [ "${#y}" -gt 9 ] && return 0
    [ $((10#$x)) -lt $((10#$y)) ] && return 0
    [ $((10#$x)) -gt $((10#$y)) ] && return 1
  done
  return 1
}

name=$(yaml_get "$root/agent.yaml" name)
version=$(yaml_get "$root/agent.yaml" version)
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
# Source-mode copies load AGENT.md through their own host files.
[ "$(yaml_get "$instance/instance.yaml" mode)" = "source" ] && exit 0
instance_version=$(yaml_get "$instance/instance.yaml" agent_version)
if [ -n "$instance_version" ] && [ -n "$(printf '%s' "$instance_version" | tr -d '0-9A-Za-z.+_-')" ]; then
  instance_version=""  # not a plain version string: ignore it
fi
# Control characters (newlines included) in paths must not forge header lines.
show_instance=$(printf '%s' "$instance" | tr -d '\000-\037')
show_root=$(printf '%s' "$root" | tr -d '\000-\037')

printf '%s\n' \
  "# Agent: $name $version" \
  "This folder is an instance of the $name agent. Follow its instructions." \
  "Instance folder: $show_instance" \
  "Package folder: $show_root" \
  "Paths: context/ means the instance folder's context/. templates/, samples/, skills/, subagents/ and migrations/ mean the package folder's. Write only into the instance folder."
if [ -n "$instance_version" ] && [ -n "$version" ] && version_older "$instance_version" "$version"; then
  printf '%s\n' "Migration: this instance was set up with $name $instance_version; the agent is now $version. Read migrations/ in the package folder, show the user the proposed changes to the instance's files as a diff, apply them only after they confirm, then set agent_version in instance.yaml to $version. If migrations/ has no note covering this change, just update agent_version."
fi
printf '%s\n' "Read the full instructions now, before anything else: $show_root/AGENT.md"
printf '\n'
if [ -f "$root/AGENT.md" ]; then
  size=$(wc -c < "$root/AGENT.md" | tr -d '[:space:]')
  if [ "${size:-0}" -le 9000 ]; then
    cat "$root/AGENT.md"
  else
    printf '%s\n' "(AGENT.md is $size bytes — read it from the path above.)"
  fi
else
  printf '%s\n' "(AGENT.md is missing from $show_root)"
fi
exit 0
