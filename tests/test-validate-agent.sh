#!/usr/bin/env bash
# Tests for validate-agent.sh, using throwaway fixture directories.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

make_valid_agent() {
  local d="$1"
  mkdir -p "$d"/{adapters,skills,subagents,templates,samples,context,evals}
  printf '%s\n' \
    '## Identity' '## Mission' '## Inputs' '## Outputs' \
    '## Operating rules' '## Workflow' '## Sub-agents' '## Skills' \
    '## Guardrails / never do' '## Escalate to human when' > "$d/AGENT.md"
  for a in CLAUDE GEMINI AGENTS; do
    echo "Read \`AGENT.md\` in this directory." > "$d/adapters/$a.md"
  done
  echo '#!/usr/bin/env bash' > "$d/install.sh"
  chmod +x "$d/install.sh"
  echo '# Cases' > "$d/evals/cases.md"
}

make_valid_v1_agent() { # make_valid_v1_agent <dir> [name] [version]
  local d="$1" name="${2:-demo-agent}" ver="${3:-0.1.0}"
  make_valid_agent "$d"
  mkdir -p "$d/.claude-plugin" "$d/.codex-plugin"
  printf '%s\n' "name: $name" "version: $ver" \
    "description: A demo agent" 'standard: "1.0"' > "$d/agent.yaml"
  local agents="" f
  for f in "$d"/subagents/*.md; do
    [ -e "$f" ] || continue
    agents="$agents${agents:+,}\"./subagents/$(basename "$f")\""
  done
  printf '{"name":"%s","version":"%s","description":"A demo agent","agents":[%s]}\n' \
    "$name" "$ver" "$agents" > "$d/.claude-plugin/plugin.json"
  printf '{"name":"%s","owner":{"name":"Test"},"plugins":[{"name":"%s","source":"./"}]}\n' \
    "$name" "$name" > "$d/.claude-plugin/marketplace.json"
  printf '{"name":"%s","version":"%s","description":"A demo agent","contextFileName":"AGENT.md"}\n' \
    "$name" "$ver" > "$d/gemini-extension.json"
  printf '{"name":"%s","version":"%s","description":"A demo agent","skills":"./skills/"}\n' \
    "$name" "$ver" > "$d/.codex-plugin/plugin.json"
}

# A fully conforming directory passes.
make_valid_agent "$FIX/good"
assert_pass bin/validate-agent.sh "$FIX/good"

# A missing required directory fails.
make_valid_agent "$FIX/no-skills"; rmdir "$FIX/no-skills/skills"
assert_fail bin/validate-agent.sh "$FIX/no-skills"

# AGENT.md headings out of order fails.
make_valid_agent "$FIX/bad-order"
printf '%s\n' '## Mission' '## Identity' > "$FIX/bad-order/AGENT.md"
assert_fail bin/validate-agent.sh "$FIX/bad-order"

# A skill missing frontmatter fails.
make_valid_agent "$FIX/bad-skill"
mkdir -p "$FIX/bad-skill/skills/thing"
echo 'no frontmatter here' > "$FIX/bad-skill/skills/thing/SKILL.md"
assert_fail bin/validate-agent.sh "$FIX/bad-skill"

# A skill description not starting with "Use when" fails.
make_valid_agent "$FIX/bad-desc"
mkdir -p "$FIX/bad-desc/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Does a thing' '---' \
  > "$FIX/bad-desc/skills/thing/SKILL.md"
assert_fail bin/validate-agent.sh "$FIX/bad-desc"

# A sub-agent contract missing a required heading fails.
make_valid_agent "$FIX/bad-sub"
printf '%s\n' '## Purpose' '## Trigger' > "$FIX/bad-sub/subagents/role.md"
assert_fail bin/validate-agent.sh "$FIX/bad-sub"

# An adapter containing behavior rules fails.
make_valid_agent "$FIX/fat-adapter"
{ echo 'Read `AGENT.md` in this directory.'
  for i in $(seq 1 40); do echo "Extra rule line $i"; done
} > "$FIX/fat-adapter/adapters/GEMINI.md"
assert_fail bin/validate-agent.sh "$FIX/fat-adapter"

# A sub-agent contract with all headings present but two swapped fails.
make_valid_agent "$FIX/sub-shuffled"
printf '%s\n' '## Trigger' '## Purpose' '## Inputs' '## Outputs' \
  '## Tools allowed' '## Stop conditions' '## Handoff' '## Inline fallback' \
  > "$FIX/sub-shuffled/subagents/role.md"
assert_fail bin/validate-agent.sh "$FIX/sub-shuffled"

# A skill with valid name/description plus an extra frontmatter key fails.
make_valid_agent "$FIX/skill-extra-key"
mkdir -p "$FIX/skill-extra-key/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Use when doing a thing' \
  'version: 1.0' '---' \
  > "$FIX/skill-extra-key/skills/thing/SKILL.md"
assert_fail bin/validate-agent.sh "$FIX/skill-extra-key"

# A skill with an unterminated (no closing ---) frontmatter block fails.
make_valid_agent "$FIX/skill-unterminated"
mkdir -p "$FIX/skill-unterminated/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Use when doing a thing' \
  > "$FIX/skill-unterminated/skills/thing/SKILL.md"
assert_fail bin/validate-agent.sh "$FIX/skill-unterminated"

echo "-- Agent Standard 1.0"
V=bin/validate-agent.sh

# A pre-1.0 agent (no agent.yaml) passes with a WARN line.
make_valid_agent "$FIX/pre10"
assert_pass $V "$FIX/pre10"
out=$($V "$FIX/pre10" 2>&1)
if printf '%s\n' "$out" | grep -q '^WARN: .* has no agent.yaml'; then _report ok "pre-1.0 WARN"; else _report no "pre-1.0 WARN missing"; fi

# A valid 1.0 agent passes, including one with a sub-agent listed.
make_valid_v1_agent "$FIX/v1"
assert_pass $V "$FIX/v1"
make_valid_agent "$FIX/v1-sub"
printf '%s\n' '## Purpose' '## Trigger' '## Inputs' '## Outputs' '## Tools allowed' \
  '## Stop conditions' '## Handoff' '## Inline fallback' > "$FIX/v1-sub/subagents/role.md"
make_valid_v1_agent "$FIX/v1-sub"
assert_pass $V "$FIX/v1-sub"

# agent.yaml written loosely still parses (quotes, comments, blank lines, nested keys).
make_valid_v1_agent "$FIX/v1-loose"
printf '%s\n' '# my agent' '' 'name: "demo-agent"   # the plugin name' \
  "version: '0.1.0'" 'description: A demo agent' 'standard: "1.0"' \
  'capabilities:' '  - crm' > "$FIX/v1-loose/agent.yaml"
assert_pass $V "$FIX/v1-loose"

# agent.yaml problems.
make_valid_v1_agent "$FIX/v1-nokey"; sed -i.bak '/^description:/d' "$FIX/v1-nokey/agent.yaml"
assert_fail $V "$FIX/v1-nokey"
make_valid_v1_agent "$FIX/v1-badname" "Demo_Agent"
assert_fail $V "$FIX/v1-badname"
make_valid_v1_agent "$FIX/v1-badver" demo-agent "1.0"
assert_fail $V "$FIX/v1-badver"
make_valid_v1_agent "$FIX/v1-std2"; sed -i.bak 's/^standard:.*/standard: "2.0"/' "$FIX/v1-std2/agent.yaml"
assert_fail $V "$FIX/v1-std2"

# Host manifest problems.
make_valid_v1_agent "$FIX/v1-nogem"; rm "$FIX/v1-nogem/gemini-extension.json"
assert_fail $V "$FIX/v1-nogem"
make_valid_v1_agent "$FIX/v1-vermismatch"
sed -i.bak 's/"version":"0.1.0"/"version":"0.2.0"/' "$FIX/v1-vermismatch/.codex-plugin/plugin.json"
assert_fail $V "$FIX/v1-vermismatch"
make_valid_v1_agent "$FIX/v1-badjson"; echo '{"name": ' > "$FIX/v1-badjson/gemini-extension.json"
assert_fail $V "$FIX/v1-badjson"
out=$($V "$FIX/v1-badjson" 2>&1)
if printf '%s\n' "$out" | grep -q 'Traceback'; then _report no "bad JSON produced a traceback"
else _report ok "bad JSON reported without traceback"; fi
make_valid_v1_agent "$FIX/v1-agentsdir"
sed -i.bak 's#"agents":\[\]#"agents":["./subagents/"]#' "$FIX/v1-agentsdir/.claude-plugin/plugin.json"
assert_fail $V "$FIX/v1-agentsdir"
make_valid_v1_agent "$FIX/v1-agentsmissing"
printf '%s\n' '## Purpose' '## Trigger' '## Inputs' '## Outputs' '## Tools allowed' \
  '## Stop conditions' '## Handoff' '## Inline fallback' > "$FIX/v1-agentsmissing/subagents/role.md"
assert_fail $V "$FIX/v1-agentsmissing"
make_valid_v1_agent "$FIX/v1-agentsextra"
sed -i.bak 's#"agents":\[\]#"agents":["./subagents/ghost.md"]#' "$FIX/v1-agentsextra/.claude-plugin/plugin.json"
assert_fail $V "$FIX/v1-agentsextra"
make_valid_v1_agent "$FIX/v1-market"
printf '{"name":"demo-agent","owner":{"name":"Test"},"plugins":[{"name":"demo-agent","source":"./other"}]}\n' \
  > "$FIX/v1-market/.claude-plugin/marketplace.json"
assert_fail $V "$FIX/v1-market"
make_valid_v1_agent "$FIX/v1-gemctx"
sed -i.bak 's/"contextFileName":"AGENT.md"/"contextFileName":"GEMINI.md"/' "$FIX/v1-gemctx/gemini-extension.json"
assert_fail $V "$FIX/v1-gemctx"
make_valid_v1_agent "$FIX/v1-codex"
sed -i.bak 's#"skills":"./skills/"#"skills":"./other/"#' "$FIX/v1-codex/.codex-plugin/plugin.json"
assert_fail $V "$FIX/v1-codex"

# Paths with spaces, run from another directory.
make_valid_v1_agent "$FIX/with space"
assert_pass bash -c "cd /tmp && '$PWD/$V' '$FIX/with space'"

# No Python: a clear message, not a shell error.
make_valid_v1_agent "$FIX/v1-nopy"
out=$(AGENT_VALIDATOR_PYTHON=/nonexistent/python3 $V "$FIX/v1-nopy" 2>&1)
if printf '%s\n' "$out" | grep -q '^FAIL: python3 is required'; then
  _report ok "missing python reported clearly"; else _report no "missing python not reported clearly"; fi

echo "-- release rule"
G="$FIX/bump-repo"
mkdir -p "$G"
git -C "$G" init -q
make_valid_v1_agent "$G/agent"
git -C "$G" add -A && git -C "$G" -c user.email=t@t -c user.name=t commit -qm base
BASE=$(git -C "$G" rev-parse HEAD)

# Unchanged since the ref: passes.
assert_pass $V "$G/agent" --require-bump "$BASE"
# Changed without a bump: fails.
echo "extra" >> "$G/agent/AGENT.md"
assert_fail $V "$G/agent" --require-bump "$BASE"
# Flag before the directory works too.
assert_fail $V --require-bump "$BASE" "$G/agent"
# Changed with a bump everywhere: passes.
for f in agent.yaml .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json; do
  sed -i.bak 's/0\.1\.0/0.1.1/' "$G/agent/$f"; rm -f "$G/agent/$f.bak"
done
assert_pass $V "$G/agent" --require-bump "$BASE"
# A brand-new agent (no agent.yaml at the ref) passes.
make_valid_v1_agent "$G/newagent"
assert_pass $V "$G/newagent" --require-bump "$BASE"
# An unknown ref fails with a clear message.
out=$($V "$G/agent" --require-bump no-such-ref 2>&1)
if printf '%s\n' "$out" | grep -q "^FAIL: --require-bump: unknown git ref 'no-such-ref'"; then
  _report ok "unknown ref reported"; else _report no "unknown ref not reported"; fi

# --require-bump with no following value: fails fast instead of hanging.
# Guarded with a 10s alarm so a regression to the old shift-2 bug can't hang the suite.
out=$(perl -e 'alarm 10; exec @ARGV' -- "$V" "$G/agent" --require-bump 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: --require-bump requires a git ref"; then
  _report ok "--require-bump with no value fails fast"
else
  _report no "--require-bump with no value did not fail fast (rc=$rc): $out"
fi

# Agent directory not inside a git repository: a clear message, not "unknown git ref".
NOTGIT="$FIX/not-a-repo"
make_valid_v1_agent "$NOTGIT"
out=$($V "$NOTGIT" --require-bump HEAD 2>&1)
if printf '%s\n' "$out" | grep -q "^FAIL: --require-bump: $NOTGIT is not inside a git repository"; then
  _report ok "non-repo dir reported clearly"; else _report no "non-repo dir not reported clearly"; fi

finish
