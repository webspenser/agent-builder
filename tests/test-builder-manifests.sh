#!/usr/bin/env bash
# The builder's own manifests agree, and its skills follow the standard's skill rules.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json .codex-plugin/plugin.json LICENSE \
         skills/new-agent/SKILL.md skills/validate-agent/SKILL.md; do
  if [ -f "$f" ]; then _report ok "$f exists"; else _report no "$f missing"; fi
done

if python3 - <<'PY'
import json, sys
c = json.load(open(".claude-plugin/plugin.json"))
m = json.load(open(".claude-plugin/marketplace.json"))
g = json.load(open("gemini-extension.json"))
x = json.load(open(".codex-plugin/plugin.json"))
ok = (c["name"] == "agent-builder" and c["version"] == "1.0.0"
      and all(d.get(k) == c.get(k) for d in (g, x) for k in ("name", "version", "description"))
      and m["name"] == "agent-builder" and m["owner"]["name"]
      and len(m["plugins"]) == 1 and m["plugins"][0]["name"] == "agent-builder" and m["plugins"][0]["source"] == "./"
      and g.get("contextFileName") == "STANDARD.md" and x.get("skills") == "./skills/")
sys.exit(0 if ok else 1)
PY
then _report ok "builder manifests agree"; else _report no "builder manifests disagree"; fi

for s in skills/*/SKILL.md; do
  [ -f "$s" ] || continue
  fm=$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f' "$s")
  echo "$fm" | grep -q '^name: ' && echo "$fm" | grep -q '^description: Use when' \
    && [ -z "$(echo "$fm" | grep -vE '^(name|description):' | grep -vE '^[[:space:]]*$')" ] \
    && _report ok "$s frontmatter" || _report no "$s frontmatter"
done

if grep -q 'Apache License' LICENSE 2>/dev/null; then _report ok "LICENSE is Apache-2.0"; else _report no "LICENSE not Apache-2.0"; fi

finish
