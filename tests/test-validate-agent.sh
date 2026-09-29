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

make_valid_v11_agent() { # make_valid_v11_agent <dir>
  local d="$1"
  make_valid_v1_agent "$d"
  sed -i.bak 's/^standard:.*/standard: "1.1"/' "$d/agent.yaml" && rm -f "$d/agent.yaml.bak"
  mkdir -p "$d/hooks" "$d/skills/start" "$d/skills/setup" "$d/migrations"
  cp _template/hooks/session-start.sh _template/hooks/hooks.json "$d/hooks/"
  chmod 755 "$d/hooks/session-start.sh"
  printf '%s\n' '---' 'name: start' 'description: Use when starting' '---' 'x' > "$d/skills/start/SKILL.md"
  printf '%s\n' '---' 'name: setup' 'description: Use when setting up' '---' 'x' > "$d/skills/setup/SKILL.md"
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

# no_traceback <label> <output> — the output holds a FAIL line and no Python traceback.
no_traceback() {
  if printf '%s\n' "$2" | grep -q 'Traceback'; then _report no "$1: traceback"
  elif printf '%s\n' "$2" | grep -q '^FAIL:'; then _report ok "$1: FAIL without traceback"
  else _report no "$1: no FAIL line"; fi
}

echo "-- wrong-typed manifests (I1)"
make_valid_v1_agent "$FIX/v1-arr"; echo '[]' > "$FIX/v1-arr/gemini-extension.json"
out=$($V "$FIX/v1-arr" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "[] manifest exits non-zero" || _report no "[] manifest passed"
no_traceback "[] manifest" "$out"
if printf '%s\n' "$out" | grep -qF 'FAIL: gemini-extension.json: must be a JSON object'; then
  _report ok "[] manifest named"; else _report no "[] manifest not named: $out"; fi

make_valid_v1_agent "$FIX/v1-agentsnull"
sed -i.bak 's#"agents":\[\]#"agents":null#' "$FIX/v1-agentsnull/.claude-plugin/plugin.json"
out=$($V "$FIX/v1-agentsnull" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "agents null exits non-zero" || _report no "agents null passed"
no_traceback "agents null" "$out"
if printf '%s\n' "$out" | grep -qF 'FAIL: .claude-plugin/plugin.json: agents must be a list of file paths'; then
  _report ok "agents null named"; else _report no "agents null not named: $out"; fi

make_valid_v1_agent "$FIX/v1-owner"
sed -i.bak 's#"owner":{"name":"Test"}#"owner":"me"#' "$FIX/v1-owner/.claude-plugin/marketplace.json"
out=$($V "$FIX/v1-owner" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "owner string exits non-zero" || _report no "owner string passed"
no_traceback "owner string" "$out"

make_valid_v1_agent "$FIX/v1-plugin-str"
sed -i.bak 's#"plugins":\[{"name":"demo-agent","source":"./"}\]#"plugins":["demo-agent"]#' \
  "$FIX/v1-plugin-str/.claude-plugin/marketplace.json"
out=$($V "$FIX/v1-plugin-str" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "plugins[0] string exits non-zero" || _report no "plugins[0] string passed"
no_traceback "plugins[0] string" "$out"

make_valid_v1_agent "$FIX/v1-latin1"
printf '{"name":"demo-agent","description":"caf\351"}\n' > "$FIX/v1-latin1/.codex-plugin/plugin.json"
out=$($V "$FIX/v1-latin1" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "non-UTF-8 exits non-zero" || _report no "non-UTF-8 passed"
no_traceback "non-UTF-8" "$out"
if printf '%s\n' "$out" | grep -qF 'FAIL: .codex-plugin/plugin.json: not valid UTF-8'; then
  _report ok "non-UTF-8 named"; else _report no "non-UTF-8 not named: $out"; fi

# The checker failing is never a pass (fail-closed).
make_valid_v1_agent "$FIX/v1-pyfalse"
out=$(AGENT_VALIDATOR_PYTHON=false $V "$FIX/v1-pyfalse" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF 'FAIL: manifest checker crashed'; then
  _report ok "crashed checker fails closed"; else _report no "crashed checker (rc=$rc): $out"; fi

echo "-- agent.yaml quoting (minor 1)"
make_valid_v1_agent "$FIX/v1-hash"
for f in .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json; do
  sed -i.bak 's/"description":"A demo agent"/"description":"Your #1 helper"/' "$FIX/v1-hash/$f"
done
sed -i.bak 's/^description:.*/description: "Your #1 helper"   # tagline/' "$FIX/v1-hash/agent.yaml"
out=$($V "$FIX/v1-hash" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _report ok "quoted value keeps '#'" || _report no "quoted '#' value failed: $out"

echo "-- --get (minor 2)"
CM=bin/lib/check_manifests.py
printf '%s\n' 'name: x' 'version : 1.2.0   # spaced' > "$FIX/get.yaml"
got=$(python3 "$CM" --get version "$FIX/get.yaml" 2>&1)
[ "$got" = "1.2.0" ] && _report ok "--get reads a spaced key" || _report no "--get gave '$got'"
got=$(printf 'version: "2.0.0"\n' | python3 "$CM" --get version - 2>&1)
[ "$got" = "2.0.0" ] && _report ok "--get reads stdin" || _report no "--get stdin gave '$got'"

echo "-- arguments (minor 3)"
make_valid_v1_agent "$FIX/v1-args"
out=$($V "$FIX/v1-args" extra 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: unexpected argument 'extra'"; then
  _report ok "second positional rejected"; else _report no "second positional (rc=$rc): $out"; fi
out=$($V "$FIX/v1-args" --bogus 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: unknown option '--bogus'"; then
  _report ok "unknown option rejected"; else _report no "unknown option (rc=$rc): $out"; fi
for h in -h --help; do
  out=$($V "$h" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^Usage: '; then
    _report ok "$h prints usage"; else _report no "$h (rc=$rc): $out"; fi
done
out=$($V "$FIX/v1-args" --require-bump "" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: --require-bump requires a git ref"; then
  _report ok "empty --require-bump rejected"; else _report no "empty --require-bump (rc=$rc): $out"; fi

echo "-- symlinked validator (minor 4)"
mkdir -p "$FIX/linkbin"
ln -s "$PWD/$V" "$FIX/linkbin/validate-agent"
make_valid_v1_agent "$FIX/v1-link"
out=$("$FIX/linkbin/validate-agent" "$FIX/v1-link" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^OK:'; then
  _report ok "symlinked validator works"; else _report no "symlinked validator (rc=$rc): $out"; fi

echo "-- nested sub-agent files (minor 5)"
make_valid_v1_agent "$FIX/v1-nested"
mkdir -p "$FIX/v1-nested/subagents/team"
printf '%s\n' '## Purpose' '## Trigger' '## Inputs' '## Outputs' '## Tools allowed' \
  '## Stop conditions' '## Handoff' '## Inline fallback' > "$FIX/v1-nested/subagents/team/role.md"
out=$($V "$FIX/v1-nested" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF 'FAIL: subagents/team/role.md: contracts must sit directly in subagents/'; then
  _report ok "nested sub-agent rejected"; else _report no "nested sub-agent (rc=$rc): $out"; fi

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
if printf '%s\n' "$out" | grep -qF "FAIL: --require-bump: unknown git ref 'no-such-ref' (in CI, check out with fetch-depth: 0)"; then
  _report ok "unknown ref reported"; else _report no "unknown ref not reported"; fi

# --require-bump with no following value: fails fast instead of hanging.
# Guarded with a 10s alarm so a regression to the old shift-2 bug can't hang the suite.
out=$(perl -e 'alarm 10; exec @ARGV' -- "$V" "$G/agent" --require-bump 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: --require-bump requires a git ref"; then
  _report ok "--require-bump with no value fails fast"
else
  _report no "--require-bump with no value did not fail fast (rc=$rc): $out"
fi

# Spaced `version :` keys do not break the bump check (one parser).
S="$FIX/spaced-repo"
mkdir -p "$S"; git -C "$S" init -q
make_valid_v1_agent "$S/agent"
sed -i.bak 's/^version: /version : /' "$S/agent/agent.yaml"; rm -f "$S/agent/agent.yaml.bak"
git -C "$S" add -A && git -C "$S" -c user.email=t@t -c user.name=t commit -qm base
SBASE=$(git -C "$S" rev-parse HEAD)
echo "extra" >> "$S/agent/AGENT.md"
for f in agent.yaml .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json; do
  sed -i.bak 's/0\.1\.0/0.1.1/' "$S/agent/$f"; rm -f "$S/agent/$f.bak"
done
out=$($V "$S/agent" --require-bump "$SBASE" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _report ok "spaced version bump accepted" || _report no "spaced version bump (rc=$rc): $out"
sed -i.bak 's/0\.1\.1/0.1.0/' "$S/agent/agent.yaml"; rm -f "$S/agent/agent.yaml.bak"
out=$($V "$S/agent" --require-bump "$SBASE" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF 'but version is still 0.1.0'; then
  _report ok "spaced version, no bump, fails"; else _report no "spaced no-bump (rc=$rc): $out"; fi

# Agent directory not inside a git repository: a clear message, not "unknown git ref".
NOTGIT="$FIX/not-a-repo"
make_valid_v1_agent "$NOTGIT"
out=$($V "$NOTGIT" --require-bump HEAD 2>&1)
if printf '%s\n' "$out" | grep -q "^FAIL: --require-bump: $NOTGIT is not inside a git repository"; then
  _report ok "non-repo dir reported clearly"; else _report no "non-repo dir not reported clearly"; fi

echo "-- Agent Standard 1.1"
make_valid_v11_agent "$FIX/v11";                 assert_pass $V "$FIX/v11"
make_valid_v1_agent "$FIX/v10-still";            assert_pass $V "$FIX/v10-still"   # 1.0 unchanged
make_valid_v11_agent "$FIX/v11-nohook"; rm "$FIX/v11-nohook/hooks/session-start.sh"; assert_fail $V "$FIX/v11-nohook"
make_valid_v11_agent "$FIX/v11-edited"; echo "# local tweak" >> "$FIX/v11-edited/hooks/session-start.sh"; assert_fail $V "$FIX/v11-edited"
make_valid_v11_agent "$FIX/v11-noexec"; chmod 644 "$FIX/v11-noexec/hooks/session-start.sh"; assert_fail $V "$FIX/v11-noexec"
make_valid_v11_agent "$FIX/v11-badcmd"; printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"hooks/session-start.sh"}]}]}}' > "$FIX/v11-badcmd/hooks/hooks.json"; assert_fail $V "$FIX/v11-badcmd"
make_valid_v11_agent "$FIX/v11-badjson"; echo '{' > "$FIX/v11-badjson/hooks/hooks.json"; assert_fail $V "$FIX/v11-badjson"
out=$($V "$FIX/v11-badjson" 2>&1); printf '%s\n' "$out" | grep -q Traceback && _report no "hooks.json traceback" || _report ok "hooks.json bad JSON reported cleanly"
make_valid_v11_agent "$FIX/v11-nostart"; rm -r "$FIX/v11-nostart/skills/start"; assert_fail $V "$FIX/v11-nostart"
make_valid_v11_agent "$FIX/v11-nosetup"; rm -r "$FIX/v11-nosetup/skills/setup"; assert_fail $V "$FIX/v11-nosetup"
make_valid_v11_agent "$FIX/v11-nomig"; rmdir "$FIX/v11-nomig/migrations"; assert_fail $V "$FIX/v11-nomig"
make_valid_v11_agent "$FIX/v11-catalog"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: webspenser/agent-library' >> "$FIX/v11-catalog/agent.yaml"; assert_pass $V "$FIX/v11-catalog"
make_valid_v11_agent "$FIX/v11-halfcat"; printf '%s\n' 'catalog: webspenser' >> "$FIX/v11-halfcat/agent.yaml"; assert_fail $V "$FIX/v11-halfcat"
make_valid_v11_agent "$FIX/v11-badrepo"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: not a repo' >> "$FIX/v11-badrepo/agent.yaml"; assert_fail $V "$FIX/v11-badrepo"
make_valid_v11_agent "$FIX/v11-srcinst"; printf '%s\n' 'agent: demo-agent' 'agent_version: 0.1.0' 'standard: "1.1"' 'mode: source' > "$FIX/v11-srcinst/instance.yaml"; assert_pass $V "$FIX/v11-srcinst"
make_valid_v11_agent "$FIX/v11-pluginst"; printf '%s\n' 'agent: demo-agent' 'mode: plugin' > "$FIX/v11-pluginst/instance.yaml"; assert_fail $V "$FIX/v11-pluginst"
make_valid_v11_agent "$FIX/v11-wronginst"; printf '%s\n' 'agent: other' 'mode: source' > "$FIX/v11-wronginst/instance.yaml"; assert_fail $V "$FIX/v11-wronginst"

finish
