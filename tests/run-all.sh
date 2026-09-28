#!/usr/bin/env bash
# Runs every test and validates every agent directory.
set -uo pipefail
cd "$(dirname "$0")/.."

STATUS=0
echo "== validator tests"; tests/test-validate-agent.sh || STATUS=1
echo "== install tests";   tests/test-install.sh        || STATUS=1
echo "== sales-partner content"; tests/test-sales-partner-content.sh || STATUS=1

for d in _template */; do
  d="${d%/}"
  case "$d" in docs|tests|bin|skills|validate|.git) continue ;; esac
  [ -f "$d/AGENT.md" ] || continue
  echo "== validating $d"
  bin/validate-agent.sh "$d" || STATUS=1
done

echo "== template is Agent Standard 1.0"
TEMPLATE_OUTPUT=$(bin/validate-agent.sh _template 2>&1)
if echo "$TEMPLATE_OUTPUT" | grep -q '^WARN:'; then
  echo "FAIL: _template is still pre-1.0"; STATUS=1
fi

[ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit "$STATUS"
