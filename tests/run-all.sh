#!/usr/bin/env bash
# Runs every test and validates every agent directory.
set -uo pipefail
cd "$(dirname "$0")/.."

STATUS=0
echo "== validator tests"; tests/test-validate-agent.sh || STATUS=1
echo "== install tests";   tests/test-install.sh        || STATUS=1
echo "== hook";  tests/test-hook.sh || STATUS=1
echo "== guard"; tests/test-guard.sh || STATUS=1
echo "== guard policy"; tests/test-guard-policy.sh || STATUS=1
echo "== schedule check"; tests/test-schedule-check.sh || STATUS=1
echo "== builder manifests"; tests/test-builder-manifests.sh || STATUS=1
echo "== action";  tests/test-action.sh || STATUS=1

for d in */; do  # _template/ is matched here
  d="${d%/}"
  case "$d" in docs|tests|bin|skills|validate|.git) continue ;; esac
  [ -f "$d/AGENT.md" ] || continue
  echo "== validating $d"
  bin/validate-agent.sh "$d" || STATUS=1
done

echo "== template is Agent Standard 2.0"
if ! grep -q '^standard: "2.0"' _template/agent.yaml; then echo "FAIL: _template is not 2.0"; STATUS=1; fi
if ! grep -qF '**Tools.**' _template/skills/setup/SKILL.md; then echo "FAIL: setup has no tools step"; STATUS=1; fi
if grep -qE 'permissions\.deny|host-deny|enforce_|standard: "1' _template/skills/setup/SKILL.md; then echo "FAIL: setup still describes removed mechanisms"; STATUS=1; fi
if ! python3 _template/hooks/guard_policy.py --check _capability-template/adapters/example-provider/guard.yaml; then echo "FAIL: skeleton guard.yaml does not parse"; STATUS=1; fi
if [ -d _template/hooks/__pycache__ ]; then echo "FAIL: bytecode in _template/hooks"; STATUS=1; fi

[ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit "$STATUS"
