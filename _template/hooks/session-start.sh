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
# Control characters (newlines included) in paths must not forge header lines.
show_instance=$(printf '%s' "$instance" | tr -d '\000-\037')
show_root=$(printf '%s' "$root" | tr -d '\000-\037')

printf '%s\n' \
  "# Agent: $name $version" \
  "This folder is an instance of the $name agent. Follow its instructions." \
  "Instance folder: $show_instance" \
  "Package folder: $show_root" \
  "Paths: context/ means the instance folder's context/. templates/, samples/, skills/ and subagents/ mean the package folder's. Write only into the instance folder."
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
