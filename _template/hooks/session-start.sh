#!/usr/bin/env bash
# Agent Standard 1.1 entry hook — identical in every agent.
# When the session's folder is (inside) an instance of this agent, prints the
# agent's instructions and where its files live. Prints nothing otherwise.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

yaml_get() { # yaml_get <file> <key>: top-level scalar; quotes and trailing comments removed
  sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

name=$(yaml_get "$root/agent.yaml" name)
version=$(yaml_get "$root/agent.yaml" version)
[ -n "$name" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
instance=""
while [ -n "$dir" ]; do
  if [ -f "$dir/instance.yaml" ]; then instance="$dir"; break; fi
  [ "$dir" = "/" ] && break
  dir=$(dirname "$dir")
done
[ -n "$instance" ] || exit 0
[ "$(yaml_get "$instance/instance.yaml" agent)" = "$name" ] || exit 0
instance_version=$(yaml_get "$instance/instance.yaml" agent_version)

printf '%s\n' \
  "# Agent: $name $version" \
  "This folder is an instance of the $name agent. Follow the instructions below." \
  "Instance folder: $instance" \
  "Package folder: $root" \
  "Paths: context/ means the instance folder's context/. templates/, samples/, skills/, subagents/ and migrations/ mean the package folder's. Write only into the instance folder."
if [ -n "$instance_version" ] && [ "$instance_version" != "$version" ]; then
  printf '%s\n' "Migration: this instance was set up with $name $instance_version; the agent is now $version. Read migrations/ in the package folder, show the user the proposed changes to the instance's files as a diff, apply them only after they confirm, then set agent_version in instance.yaml to $version."
fi
printf '\n'
if [ -f "$root/AGENT.md" ]; then
  cat "$root/AGENT.md"
else
  printf '%s\n' "(AGENT.md is missing from $root)"
fi
exit 0
