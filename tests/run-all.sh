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
echo "== tool check"; tests/test-tool-check.sh || STATUS=1
echo "== builder manifests"; tests/test-builder-manifests.sh || STATUS=1
echo "== action";  tests/test-action.sh || STATUS=1

for d in */; do  # _template/ is matched here
  d="${d%/}"
  case "$d" in docs|tests|bin|skills|validate|.git) continue ;; esac
  [ -f "$d/AGENT.md" ] || continue
  echo "== validating $d"
  bin/validate-agent.sh "$d" || STATUS=1
done

echo "== template is Agent Standard 3.0"
if ! grep -q '^standard: "3.0"' _template/agent.yaml; then echo "FAIL: _template is not 3.0"; STATUS=1; fi
if ! grep -qF '**Tools.**' _template/skills/setup/SKILL.md; then echo "FAIL: setup has no tools step"; STATUS=1; fi
if grep -qE 'permissions\.deny|host-deny|enforce_|standard: "1' _template/skills/setup/SKILL.md; then echo "FAIL: setup still describes removed mechanisms"; STATUS=1; fi
if ! python3 _template/hooks/guard_policy.py --check _capability-template/tools/example-provider/guard.yaml; then echo "FAIL: skeleton guard.yaml does not parse"; STATUS=1; fi
if [ -d _template/hooks/__pycache__ ]; then echo "FAIL: bytecode in _template/hooks"; STATUS=1; fi
if [ ! -f _template/skills/add-tool/SKILL.md ]; then echo "FAIL: template has no add-tool skill"; STATUS=1; fi
SKEL=$(mktemp -d); mkdir -p "$SKEL/capabilities"; cp -R _capability-template "$SKEL/capabilities/example_capability"  # tool_check reads the capability name from the path
python3 -B _template/hooks/tool_check.py "$SKEL/capabilities/example_capability/tools/example-provider" "$SKEL/capabilities/example_capability/contract.md" >/dev/null || { echo "FAIL: skeleton tool fails tool_check"; STATUS=1; }
rm -r "$SKEL"
if [ ! -f _template/skills/schedule/SKILL.md ]; then echo "FAIL: template has no schedule skill"; STATUS=1; fi
for f in CLAUDE GEMINI AGENTS; do  # hosts/ sources stay tracked though root links are ignored
  if git check-ignore --no-index -q "_template/hosts/$f.md"; then echo "FAIL: .gitignore ignores _template/hosts/$f.md"; STATUS=1; fi
done

echo "== Agent Standard 3.0 text"
if grep -rniE '\badapters?\b' STANDARD.md README.md docs/how-it-works.md docs/writing-an-agent.md skills _template _capability-template \
     | grep -v 'Agent Standard 2' | grep -v 'custom-adapters' | grep -q .; then
  echo "FAIL: 'adapter' still used outside 2.x migration notes:"; grep -rniE '\badapters?\b' STANDARD.md README.md docs/how-it-works.md docs/writing-an-agent.md skills _template _capability-template | grep -v 'Agent Standard 2' | grep -v 'custom-adapters' | head; STATUS=1
fi
for want in 'custom-tools/<cap>/' 'capabilities/<cap>/tools/<tool>/' 'stop' 'server_match' 'lowercase' 'no_send' 'tool_check.py'; do
  grep -qF -- "$want" _template/skills/add-tool/SKILL.md || { echo "FAIL: add-tool skill does not mention $want"; STATUS=1; }
done
grep -qF 'add-tool' _template/skills/setup/SKILL.md || { echo "FAIL: setup does not hand off to add-tool"; STATUS=1; }
grep -qF 'validate@v3' README.md || { echo "FAIL: README does not use validate@v3"; STATUS=1; }

[ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit "$STATUS"
