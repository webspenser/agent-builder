#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_pass validate/run.sh _template
assert_pass validate/run.sh _template ""
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/not-an-agent"
assert_fail validate/run.sh "$W/not-an-agent"
assert_contains validate/action.yml 'using: composite'
assert_contains validate/action.yml 'require-bump-against'
assert_contains validate/action.yml '$GITHUB_ACTION_PATH/run.sh'

RUN_LINES=$(grep '^\s*run:' validate/action.yml || true)
if printf '%s' "$RUN_LINES" | grep -q '\${{'; then
  _report no "validate/action.yml run: line free of \${{ (script injection)"
else
  _report ok "validate/action.yml run: line free of \${{ (script injection)"
fi

finish
