#!/usr/bin/env bash
# Runs the Agent Standard validator; used by the GitHub Action and locally.
# Usage: validate/run.sh <agent-path> [<require-bump-ref>]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
path="${1:-.}"
ref="${2:-}"
if [ -n "$ref" ]; then
  exec "$here/../bin/validate-agent.sh" "$path" --require-bump "$ref"
fi
exec "$here/../bin/validate-agent.sh" "$path"
