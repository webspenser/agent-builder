#!/usr/bin/env bash
# Runs every test and validates every agent directory.
set -uo pipefail
cd "$(dirname "$0")/.."

STATUS=0
echo "== validator tests"; tests/test-validate-agent.sh || STATUS=1
echo "== install tests";   tests/test-install.sh        || STATUS=1
echo "== hook";  tests/test-hook.sh || STATUS=1
echo "== builder manifests"; tests/test-builder-manifests.sh || STATUS=1
echo "== action";  tests/test-action.sh || STATUS=1

for d in */; do  # _template/ is matched here
  d="${d%/}"
  case "$d" in docs|tests|bin|skills|validate|.git) continue ;; esac
  [ -f "$d/AGENT.md" ] || continue
  echo "== validating $d"
  bin/validate-agent.sh "$d" || STATUS=1
done

echo "== template is Agent Standard 1.1"
if ! grep -q '^standard: "1.1"' _template/agent.yaml; then echo "FAIL: _template is not 1.1"; STATUS=1; fi
TEMPLATE_OUTPUT=$(bin/validate-agent.sh _template 2>&1)
if echo "$TEMPLATE_OUTPUT" | grep -q '^WARN: .* has no agent.yaml'; then
  echo "FAIL: _template is still pre-1.0"; STATUS=1
fi

[ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit "$STATUS"
