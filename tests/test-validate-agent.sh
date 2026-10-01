#!/usr/bin/env bash
# Tests for validate-agent.sh, using throwaway fixture directories.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

make_valid_agent() { # make_valid_agent <dir> [name] [version] — a complete agent
  local d="$1" name="${2:-demo-agent}" ver="${3:-0.1.0}"
  mkdir -p "$d"/{hosts,skills/start,skills/setup,skills/add-tool,subagents,templates,samples,context,evals,hooks,.claude-plugin,.codex-plugin}
  printf '%s\n' \
    '## Identity' '## Mission' '## Inputs' '## Outputs' \
    '## Operating rules' '## Workflow' '## Sub-agents' '## Skills' \
    '## Guardrails / never do' '## Escalate to human when' > "$d/AGENT.md"
  for a in CLAUDE GEMINI AGENTS; do echo "Read \`AGENT.md\` in this directory." > "$d/hosts/$a.md"; done
  echo '#!/usr/bin/env bash' > "$d/install.sh"; chmod +x "$d/install.sh"
  echo '# Cases' > "$d/evals/cases.md"
  printf '%s\n' "name: $name" "version: $ver" "description: A demo agent" 'standard: "5.0"' 'capabilities: crm' > "$d/agent.yaml"
  printf '{"name":"%s","owner":{"name":"Test"},"plugins":[{"name":"%s","source":"./"}]}\n' "$name" "$name" > "$d/.claude-plugin/marketplace.json"
  printf '{"name":"%s","version":"%s","description":"A demo agent","contextFileName":"AGENT.md"}\n' "$name" "$ver" > "$d/gemini-extension.json"
  printf '{"name":"%s","version":"%s","description":"A demo agent","skills":"./skills/"}\n' "$name" "$ver" > "$d/.codex-plugin/plugin.json"
  cp _template/hooks/session-start.sh _template/hooks/guard.sh _template/hooks/guard_policy.py _template/hooks/schedule_check.py _template/hooks/tool_check.py _template/hooks/hooks.json "$d/hooks/"
  chmod 755 "$d/hooks/session-start.sh" "$d/hooks/guard.sh" "$d/hooks/guard_policy.py" "$d/hooks/schedule_check.py" "$d/hooks/tool_check.py"
  printf '%s\n' '---' 'name: start' 'description: Use when starting' '---' 'x' > "$d/skills/start/SKILL.md"
  printf '%s\n' '---' 'name: setup' 'description: Use when setting up' '---' 'x' > "$d/skills/setup/SKILL.md"
  cp _template/skills/add-tool/SKILL.md "$d/skills/add-tool/SKILL.md"
  local c="$d/capabilities/crm" a="$d/capabilities/crm/tools/demo"
  mkdir -p "$a"
  printf '%s\n' '# CRM contract' '' '## Operations' '' '| Operation | Arguments |' '|---|---|' \
    '| `create_lead` | `company` |' '| `get_lead` | `lead_id` |' '' '## Invariants' '' \
    '- `draft_only` — only drafts' '- `no_send` — never sends' > "$c/contract.md"
  printf '%s\n' '# Demo tool' '' '- `create_lead` — demo:create' '- `get_lead` — demo:get' '' '## Probe' '' 'Call demo:whoami.' > "$a/usage.md"
  printf '%s\n' 'capability: crm' 'provider: demo' 'server_match: demo' > "$a/identity.yaml"
  printf '%s\n' 'covers: [draft_only, no_send]' 'deny: ["*send*"]' 'writes:' '  - kind: create' '    tools: [create-lead]' '    at: [values]' '  - kind: update' '    tools: [update-lead]' '    at: [values]' > "$a/guard.yaml"
  printf '%s\n' 'covers: [no_send]' 'deny: ["*send*"]' > "$d/guard.yaml"
  sync_agents "$d" "$name" "$ver"
}
sync_agents() { # sync_agents <dir> [name] [version] — rewrite plugin.json's agents list from subagents/
  local d="$1" name="${2:-demo-agent}" ver="${3:-0.1.0}" agents="" f
  for f in "$d"/subagents/*.md; do
    [ -e "$f" ] || continue
    agents="$agents${agents:+,}\"./subagents/$(basename "$f")\""
  done
  printf '{"name":"%s","version":"%s","description":"A demo agent","agents":[%s]}\n' "$name" "$ver" "$agents" > "$d/.claude-plugin/plugin.json"
}
V=bin/validate-agent.sh
fails_with() { # fails_with <dir> <message> [validator args...] — non-zero exit and that exact FAIL line, no traceback
  local d="$1" msg="$2" out rc; shift 2
  out=$($V "$d" "$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL: $msg" && ! printf '%s\n' "$out" | grep -qE 'Traceback|checker error'; then
    _report ok "$(basename "$d"): $msg"; else _report no "$(basename "$d") (rc=$rc) wanted '$msg': $out"; fi
}

# A fully conforming directory passes.
make_valid_agent "$FIX/good"
assert_pass bin/validate-agent.sh "$FIX/good"

# A missing required directory fails.
make_valid_agent "$FIX/no-skills"; rm -r "$FIX/no-skills/skills"
fails_with "$FIX/no-skills" "missing directory: skills/"

# AGENT.md headings out of order fails.
make_valid_agent "$FIX/bad-order"
printf '%s\n' '## Mission' '## Identity' > "$FIX/bad-order/AGENT.md"
fails_with "$FIX/bad-order" "AGENT.md headings missing or out of order"

# A skill missing frontmatter fails.
make_valid_agent "$FIX/bad-skill"
mkdir -p "$FIX/bad-skill/skills/thing"
echo 'no frontmatter here' > "$FIX/bad-skill/skills/thing/SKILL.md"
fails_with "$FIX/bad-skill" "$FIX/bad-skill/skills/thing/SKILL.md: missing opening frontmatter ---"

# A skill description not starting with "Use when" fails.
make_valid_agent "$FIX/bad-desc"
mkdir -p "$FIX/bad-desc/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Does a thing' '---' \
  > "$FIX/bad-desc/skills/thing/SKILL.md"
fails_with "$FIX/bad-desc" "$FIX/bad-desc/skills/thing/SKILL.md: description must begin with 'Use when'"

# A sub-agent contract missing a required heading fails.
make_valid_agent "$FIX/bad-sub"
printf '%s\n' '## Purpose' '## Trigger' > "$FIX/bad-sub/subagents/role.md"
sync_agents "$FIX/bad-sub"
fails_with "$FIX/bad-sub" "$FIX/bad-sub/subagents/role.md: headings missing or out of order"

# A host file containing behavior rules fails.
make_valid_agent "$FIX/fat-host"
{ echo 'Read `AGENT.md` in this directory.'
  for i in $(seq 1 40); do echo "Extra rule line $i"; done
} > "$FIX/fat-host/hosts/GEMINI.md"
fails_with "$FIX/fat-host" "hosts/GEMINI.md has 41 lines (max 25) — host files carry no behavior"

# A sub-agent contract with all headings present but two swapped fails.
make_valid_agent "$FIX/sub-shuffled"
printf '%s\n' '## Trigger' '## Purpose' '## Inputs' '## Outputs' \
  '## Tools allowed' '## Stop conditions' '## Handoff' '## Inline fallback' \
  > "$FIX/sub-shuffled/subagents/role.md"
sync_agents "$FIX/sub-shuffled"
fails_with "$FIX/sub-shuffled" "$FIX/sub-shuffled/subagents/role.md: headings missing or out of order"

# A skill with valid name/description plus an extra frontmatter key fails.
make_valid_agent "$FIX/skill-extra-key"
mkdir -p "$FIX/skill-extra-key/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Use when doing a thing' \
  'version: 1.0' '---' \
  > "$FIX/skill-extra-key/skills/thing/SKILL.md"
fails_with "$FIX/skill-extra-key" "$FIX/skill-extra-key/skills/thing/SKILL.md: frontmatter has keys other than name/description: version: 1.0"

# A skill with an unterminated (no closing ---) frontmatter block fails.
make_valid_agent "$FIX/skill-unterminated"
mkdir -p "$FIX/skill-unterminated/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Use when doing a thing' \
  > "$FIX/skill-unterminated/skills/thing/SKILL.md"
fails_with "$FIX/skill-unterminated" "$FIX/skill-unterminated/skills/thing/SKILL.md: missing closing frontmatter ---"

echo "-- manifests"

# A valid agent passes, including one with a sub-agent listed.
make_valid_agent "$FIX/mf"
assert_pass $V "$FIX/mf"
make_valid_agent "$FIX/mf-sub"
printf '%s\n' '## Purpose' '## Trigger' '## Inputs' '## Outputs' '## Tools allowed' \
  '## Stop conditions' '## Handoff' '## Inline fallback' > "$FIX/mf-sub/subagents/role.md"
sync_agents "$FIX/mf-sub"
assert_pass $V "$FIX/mf-sub"

# agent.yaml written loosely still parses (quotes, comments, blank lines, nested keys).
make_valid_agent "$FIX/mf-loose"
printf '%s\n' '# my agent' '' 'name: "demo-agent"   # the plugin name' \
  "version: '0.1.0'" 'description: A demo agent' 'standard: "5.0"' \
  'capabilities: crm   # the only one' 'extra:' '  - nested' > "$FIX/mf-loose/agent.yaml"
assert_pass $V "$FIX/mf-loose"

# agent.yaml problems.
make_valid_agent "$FIX/mf-nokey"; sed -i.bak '/^description:/d' "$FIX/mf-nokey/agent.yaml"
fails_with "$FIX/mf-nokey" "agent.yaml: missing description"
make_valid_agent "$FIX/mf-badname" "Demo_Agent"
fails_with "$FIX/mf-badname" "agent.yaml: name 'Demo_Agent' is not kebab-case"
make_valid_agent "$FIX/mf-badver" demo-agent "1.0"
fails_with "$FIX/mf-badver" "agent.yaml: version '1.0' is not MAJOR.MINOR.PATCH"
make_valid_agent "$FIX/mf-std20"; sed -i.bak 's/^standard:.*/standard: "3.0"/' "$FIX/mf-std20/agent.yaml"
fails_with "$FIX/mf-std20" "agent.yaml: standard '3.0' must be \"5.0\""

# Host manifest problems.
make_valid_agent "$FIX/mf-nogem"; rm "$FIX/mf-nogem/gemini-extension.json"
fails_with "$FIX/mf-nogem" "missing gemini-extension.json"
make_valid_agent "$FIX/mf-vermismatch"
sed -i.bak 's/"version":"0.1.0"/"version":"0.2.0"/' "$FIX/mf-vermismatch/.codex-plugin/plugin.json"
fails_with "$FIX/mf-vermismatch" ".codex-plugin/plugin.json: version '0.2.0' does not match agent.yaml '0.1.0'"
make_valid_agent "$FIX/mf-badjson"; echo '{"name": ' > "$FIX/mf-badjson/gemini-extension.json"
fails_with "$FIX/mf-badjson" "gemini-extension.json: not valid JSON"
out=$($V "$FIX/mf-badjson" 2>&1)
if printf '%s\n' "$out" | grep -q 'Traceback'; then _report no "bad JSON produced a traceback"
else _report ok "bad JSON reported without traceback"; fi
make_valid_agent "$FIX/mf-agentsdir"
sed -i.bak 's#"agents":\[\]#"agents":["./subagents/"]#' "$FIX/mf-agentsdir/.claude-plugin/plugin.json"
fails_with "$FIX/mf-agentsdir" ".claude-plugin/plugin.json: agents entry './subagents/' is a directory — list each file"
make_valid_agent "$FIX/mf-agentsmissing"
printf '%s\n' '## Purpose' '## Trigger' '## Inputs' '## Outputs' '## Tools allowed' \
  '## Stop conditions' '## Handoff' '## Inline fallback' > "$FIX/mf-agentsmissing/subagents/role.md"
fails_with "$FIX/mf-agentsmissing" ".claude-plugin/plugin.json: agents does not list ./subagents/role.md"
make_valid_agent "$FIX/mf-agentsextra"
sed -i.bak 's#"agents":\[\]#"agents":["./subagents/ghost.md"]#' "$FIX/mf-agentsextra/.claude-plugin/plugin.json"
fails_with "$FIX/mf-agentsextra" ".claude-plugin/plugin.json: agents lists ./subagents/ghost.md, which is not a file in subagents/"
make_valid_agent "$FIX/mf-market"
printf '{"name":"demo-agent","owner":{"name":"Test"},"plugins":[{"name":"demo-agent","source":"./other"}]}\n' \
  > "$FIX/mf-market/.claude-plugin/marketplace.json"
fails_with "$FIX/mf-market" ".claude-plugin/marketplace.json: must hold exactly one plugin entry named 'demo-agent' with source \"./\""
make_valid_agent "$FIX/mf-gemctx"
sed -i.bak 's/"contextFileName":"AGENT.md"/"contextFileName":"GEMINI.md"/' "$FIX/mf-gemctx/gemini-extension.json"
fails_with "$FIX/mf-gemctx" "gemini-extension.json: contextFileName must be \"AGENT.md\""
make_valid_agent "$FIX/mf-codex"
sed -i.bak 's#"skills":"./skills/"#"skills":"./other/"#' "$FIX/mf-codex/.codex-plugin/plugin.json"
fails_with "$FIX/mf-codex" ".codex-plugin/plugin.json: skills must be \"./skills/\""

# Paths with spaces, run from another directory.
make_valid_agent "$FIX/with space"
assert_pass bash -c "cd /tmp && '$PWD/$V' '$FIX/with space'"

# No Python: a clear message, not a shell error.
make_valid_agent "$FIX/mf-nopy"
out=$(AGENT_VALIDATOR_PYTHON=/nonexistent/python3 $V "$FIX/mf-nopy" 2>&1)
if printf '%s\n' "$out" | grep -q '^FAIL: python3 is required'; then
  _report ok "missing python reported clearly"; else _report no "missing python not reported clearly"; fi

# no_traceback <label> <output> — the output holds a FAIL line and no Python traceback.
no_traceback() {
  if printf '%s\n' "$2" | grep -q 'Traceback'; then _report no "$1: traceback"
  elif printf '%s\n' "$2" | grep -q '^FAIL:'; then _report ok "$1: FAIL without traceback"
  else _report no "$1: no FAIL line"; fi
}

echo "-- wrong-typed manifests (I1)"
make_valid_agent "$FIX/mf-arr"; echo '[]' > "$FIX/mf-arr/gemini-extension.json"
out=$($V "$FIX/mf-arr" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "[] manifest exits non-zero" || _report no "[] manifest passed"
no_traceback "[] manifest" "$out"
if printf '%s\n' "$out" | grep -qF 'FAIL: gemini-extension.json: must be a JSON object'; then
  _report ok "[] manifest named"; else _report no "[] manifest not named: $out"; fi

make_valid_agent "$FIX/mf-agentsnull"
sed -i.bak 's#"agents":\[\]#"agents":null#' "$FIX/mf-agentsnull/.claude-plugin/plugin.json"
out=$($V "$FIX/mf-agentsnull" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "agents null exits non-zero" || _report no "agents null passed"
no_traceback "agents null" "$out"
if printf '%s\n' "$out" | grep -qF 'FAIL: .claude-plugin/plugin.json: agents must be a list of file paths'; then
  _report ok "agents null named"; else _report no "agents null not named: $out"; fi

make_valid_agent "$FIX/mf-owner"
sed -i.bak 's#"owner":{"name":"Test"}#"owner":"me"#' "$FIX/mf-owner/.claude-plugin/marketplace.json"
out=$($V "$FIX/mf-owner" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "owner string exits non-zero" || _report no "owner string passed"
no_traceback "owner string" "$out"

make_valid_agent "$FIX/mf-plugin-str"
sed -i.bak 's#"plugins":\[{"name":"demo-agent","source":"./"}\]#"plugins":["demo-agent"]#' \
  "$FIX/mf-plugin-str/.claude-plugin/marketplace.json"
out=$($V "$FIX/mf-plugin-str" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "plugins[0] string exits non-zero" || _report no "plugins[0] string passed"
no_traceback "plugins[0] string" "$out"

make_valid_agent "$FIX/mf-latin1"
printf '{"name":"demo-agent","description":"caf\351"}\n' > "$FIX/mf-latin1/.codex-plugin/plugin.json"
out=$($V "$FIX/mf-latin1" 2>&1); rc=$?
[ "$rc" -ne 0 ] && _report ok "non-UTF-8 exits non-zero" || _report no "non-UTF-8 passed"
no_traceback "non-UTF-8" "$out"
if printf '%s\n' "$out" | grep -qF 'FAIL: .codex-plugin/plugin.json: not valid UTF-8'; then
  _report ok "non-UTF-8 named"; else _report no "non-UTF-8 not named: $out"; fi

# The checker failing is never a pass (fail-closed).
make_valid_agent "$FIX/mf-pyfalse"
out=$(AGENT_VALIDATOR_PYTHON=false $V "$FIX/mf-pyfalse" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF 'FAIL: manifest checker crashed'; then
  _report ok "crashed checker fails closed"; else _report no "crashed checker (rc=$rc): $out"; fi

echo "-- agent.yaml quoting (minor 1)"
make_valid_agent "$FIX/mf-hash"
for f in .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json; do
  sed -i.bak 's/"description":"A demo agent"/"description":"Your #1 helper"/' "$FIX/mf-hash/$f"
done
sed -i.bak 's/^description:.*/description: "Your #1 helper"   # tagline/' "$FIX/mf-hash/agent.yaml"
out=$($V "$FIX/mf-hash" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _report ok "quoted value keeps '#'" || _report no "quoted '#' value failed: $out"

echo "-- --get (minor 2)"
CM=bin/lib/check_manifests.py
printf '%s\n' 'name: x' 'version : 1.2.0   # spaced' > "$FIX/get.yaml"
got=$(python3 "$CM" --get version "$FIX/get.yaml" 2>&1)
[ "$got" = "1.2.0" ] && _report ok "--get reads a spaced key" || _report no "--get gave '$got'"
got=$(printf 'version: "2.0.0"\n' | python3 "$CM" --get version - 2>&1)
[ "$got" = "2.0.0" ] && _report ok "--get reads stdin" || _report no "--get stdin gave '$got'"

echo "-- arguments (minor 3)"
make_valid_agent "$FIX/mf-args"
out=$($V "$FIX/mf-args" extra 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: unexpected argument 'extra'"; then
  _report ok "second positional rejected"; else _report no "second positional (rc=$rc): $out"; fi
out=$($V "$FIX/mf-args" --bogus 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: unknown option '--bogus'"; then
  _report ok "unknown option rejected"; else _report no "unknown option (rc=$rc): $out"; fi
for h in -h --help; do
  out=$($V "$h" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^Usage: '; then
    _report ok "$h prints usage"; else _report no "$h (rc=$rc): $out"; fi
done
out=$($V "$FIX/mf-args" --require-bump "" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: --require-bump requires a git ref"; then
  _report ok "empty --require-bump rejected"; else _report no "empty --require-bump (rc=$rc): $out"; fi

echo "-- symlinked validator (minor 4)"
mkdir -p "$FIX/linkbin"
ln -s "$PWD/$V" "$FIX/linkbin/validate-agent"
make_valid_agent "$FIX/mf-link"
out=$("$FIX/linkbin/validate-agent" "$FIX/mf-link" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^OK:'; then
  _report ok "symlinked validator works"; else _report no "symlinked validator (rc=$rc): $out"; fi

echo "-- nested sub-agent files (minor 5)"
make_valid_agent "$FIX/mf-nested"
mkdir -p "$FIX/mf-nested/subagents/team"
printf '%s\n' '## Purpose' '## Trigger' '## Inputs' '## Outputs' '## Tools allowed' \
  '## Stop conditions' '## Handoff' '## Inline fallback' > "$FIX/mf-nested/subagents/team/role.md"
out=$($V "$FIX/mf-nested" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF 'FAIL: subagents/team/role.md: contracts must sit directly in subagents/'; then
  _report ok "nested sub-agent rejected"; else _report no "nested sub-agent (rc=$rc): $out"; fi

echo "-- release rule"
G="$FIX/bump-repo"
mkdir -p "$G"
git -C "$G" init -q
make_valid_agent "$G/agent"
git -C "$G" add -A && git -C "$G" -c user.email=t@t -c user.name=t commit -qm base
BASE=$(git -C "$G" rev-parse HEAD)

# Unchanged since the ref: passes.
assert_pass $V "$G/agent" --require-bump "$BASE"
# Changed without a bump: fails.
echo "extra" >> "$G/agent/AGENT.md"
fails_with "$G/agent" "files changed since $BASE but version is still 0.1.0" --require-bump "$BASE"
# Flag before the directory works too.
out=$($V --require-bump "$BASE" "$G/agent" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: files changed since $BASE but version is still 0.1.0"; then
  _report ok "flag before directory fails the same way"; else _report no "flag before directory (rc=$rc): $out"; fi
# Changed with a bump everywhere: passes.
for f in agent.yaml .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json; do
  sed -i.bak 's/0\.1\.0/0.1.1/' "$G/agent/$f"; rm -f "$G/agent/$f.bak"
done
assert_pass $V "$G/agent" --require-bump "$BASE"
# A brand-new agent (no agent.yaml at the ref) passes.
make_valid_agent "$G/newagent"
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
make_valid_agent "$S/agent"
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
make_valid_agent "$NOTGIT"
out=$($V "$NOTGIT" --require-bump HEAD 2>&1)
if printf '%s\n' "$out" | grep -q "^FAIL: --require-bump: $NOTGIT is not inside a git repository"; then
  _report ok "non-repo dir reported clearly"; else _report no "non-repo dir not reported clearly"; fi

echo "-- runtime"
make_valid_agent "$FIX/rt";                 assert_pass $V "$FIX/rt"
make_valid_agent "$FIX/rt-nohook"; rm "$FIX/rt-nohook/hooks/session-start.sh"; fails_with "$FIX/rt-nohook" "missing hooks/session-start.sh"
make_valid_agent "$FIX/rt-edited"; echo "# local tweak" >> "$FIX/rt-edited/hooks/session-start.sh"; fails_with "$FIX/rt-edited" "hooks/session-start.sh differs from the Agent Standard reference copy (_template/hooks/session-start.sh in agent-builder)"
make_valid_agent "$FIX/rt-noexec"; chmod 644 "$FIX/rt-noexec/hooks/session-start.sh"; fails_with "$FIX/rt-noexec" "hooks/session-start.sh is not executable"
make_valid_agent "$FIX/rt-badcmd"; printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"hooks/session-start.sh"}]}]}}' > "$FIX/rt-badcmd/hooks/hooks.json"; fails_with "$FIX/rt-badcmd" 'hooks/hooks.json: needs a SessionStart command hook "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"'
make_valid_agent "$FIX/rt-badjson"; echo '{' > "$FIX/rt-badjson/hooks/hooks.json"; fails_with "$FIX/rt-badjson" "hooks/hooks.json: not valid JSON"
out=$($V "$FIX/rt-badjson" 2>&1); printf '%s\n' "$out" | grep -q Traceback && _report no "hooks.json traceback" || _report ok "hooks.json bad JSON reported cleanly"
make_valid_agent "$FIX/rt-nostart"; rm -r "$FIX/rt-nostart/skills/start"; fails_with "$FIX/rt-nostart" "missing skills/start/SKILL.md"
make_valid_agent "$FIX/rt-nosetup"; rm -r "$FIX/rt-nosetup/skills/setup"; fails_with "$FIX/rt-nosetup" "missing skills/setup/SKILL.md"
make_valid_agent "$FIX/rt-catalog"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: webspenser/agent-library' >> "$FIX/rt-catalog/agent.yaml"; assert_pass $V "$FIX/rt-catalog"
make_valid_agent "$FIX/rt-halfcat"; printf '%s\n' 'catalog: webspenser' >> "$FIX/rt-halfcat/agent.yaml"; fails_with "$FIX/rt-halfcat" "agent.yaml: catalog and catalog_repo must be set together as flat keys"
make_valid_agent "$FIX/rt-badrepo"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: not a repo' >> "$FIX/rt-badrepo/agent.yaml"; fails_with "$FIX/rt-badrepo" "agent.yaml: catalog_repo 'not a repo' is not owner/repo"
make_valid_agent "$FIX/rt-srcinst"; printf '%s\n' 'agent: demo-agent' 'standard: "1.1"' 'mode: source' > "$FIX/rt-srcinst/instance.yaml"; assert_pass $V "$FIX/rt-srcinst"
make_valid_agent "$FIX/rt-pluginst"; printf '%s\n' 'agent: demo-agent' 'mode: plugin' > "$FIX/rt-pluginst/instance.yaml"; fails_with "$FIX/rt-pluginst" "instance.yaml in a package must have mode: source"
make_valid_agent "$FIX/rt-wronginst"; printf '%s\n' 'agent: other' 'mode: source' > "$FIX/rt-wronginst/instance.yaml"; fails_with "$FIX/rt-wronginst" "instance.yaml: agent 'other' does not match agent.yaml 'demo-agent'"

for c in hooks5 hooksnull nounread instdir; do make_valid_agent "$FIX/rt-$c"; done
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":5}]}}' > "$FIX/rt-hooks5/hooks/hooks.json"
echo 'null' > "$FIX/rt-hooksnull/hooks/hooks.json"
chmod 000 "$FIX/rt-nounread/hooks/session-start.sh"
mkdir "$FIX/rt-instdir/instance.yaml"
for c in hooks5 hooksnull nounread instdir; do
  out=$($V "$FIX/rt-$c" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && ! printf '%s\n' "$out" | grep -qE 'Traceback|checker error|crashed'; then
    _report ok "rt-$c fails cleanly"; else _report no "rt-$c (rc=$rc): $out"; fi
done
chmod 644 "$FIX/rt-nounread/hooks/session-start.sh"

echo "-- runtime: size warning, catalog, placeholders"
# AGENT.md over 9000 bytes: WARN, still OK.
make_valid_agent "$FIX/rt-bigagent"; head -c 9500 /dev/zero | tr '\0' 'x' >> "$FIX/rt-bigagent/AGENT.md"
out=$($V "$FIX/rt-bigagent" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^WARN: AGENT.md is [0-9]* bytes; the entry hook will point the model at the file instead of inlining it' \
  && printf '%s\n' "$out" | grep -q '^OK:'; then _report ok "large AGENT.md WARNs, still OK"; else _report no "large AGENT.md (rc=$rc): $out"; fi
out=$($V "$FIX/rt" 2>&1)
printf '%s\n' "$out" | grep -q '^WARN:' && _report no "small AGENT.md WARNed: $out" || _report ok "small AGENT.md: no WARN"

# catalog: present but empty (a nested map) fails.
make_valid_agent "$FIX/rt-nestcat"
printf '%s\n' 'catalog:' '  name: webspenser' '  repo: webspenser/agent-library' >> "$FIX/rt-nestcat/agent.yaml"
out=$($V "$FIX/rt-nestcat" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF 'FAIL: agent.yaml: catalog and catalog_repo must be set together as flat keys'; then
  _report ok "nested catalog map fails"; else _report no "nested catalog (rc=$rc): $out"; fi

# Setup placeholders left unfilled fail, except in the template itself.
for ph in '<interview-skill>' '<context-files>'; do
  make_valid_agent "$FIX/rt-ph"; printf 'Run the %s skill.\n' "$ph" >> "$FIX/rt-ph/skills/setup/SKILL.md"
  out=$($V "$FIX/rt-ph" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "FAIL: skills/setup/SKILL.md still has the $ph placeholder"; then
    _report ok "unfilled $ph fails"; else _report no "unfilled $ph (rc=$rc): $out"; fi
  make_valid_agent "$FIX/rt-tpl" agent-template; printf 'Run the %s skill.\n' "$ph" >> "$FIX/rt-tpl/skills/setup/SKILL.md"
  out=$($V "$FIX/rt-tpl" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && _report ok "agent-template keeps $ph" || _report no "agent-template with $ph (rc=$rc): $out"
  rm -rf "$FIX/rt-ph" "$FIX/rt-tpl"
done

echo "-- capabilities"
AD=capabilities/crm/tools/demo
make_valid_agent "$FIX/cap"; assert_pass $V "$FIX/cap"
make_valid_agent "$FIX/cap-notools"; sed -i.bak '/^capabilities:/d' "$FIX/cap-notools/agent.yaml"; rm -rf "$FIX/cap-notools/capabilities" "$FIX/cap-notools/agent.yaml.bak"; assert_pass $V "$FIX/cap-notools"

make_valid_agent "$FIX/cap-noguard"; rm "$FIX/cap-noguard/hooks/guard.sh"
fails_with "$FIX/cap-noguard" "missing hooks/guard.sh"
make_valid_agent "$FIX/cap-edited"; echo "# tweak" >> "$FIX/cap-edited/hooks/guard.sh"
fails_with "$FIX/cap-edited" "hooks/guard.sh differs from the Agent Standard reference copy (_template/hooks/guard.sh in agent-builder)"
make_valid_agent "$FIX/cap-noexec"; chmod 644 "$FIX/cap-noexec/hooks/guard.sh"
fails_with "$FIX/cap-noexec" "hooks/guard.sh is not executable"
make_valid_agent "$FIX/cap-nopre"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\""}]}]}}' > "$FIX/cap-nopre/hooks/hooks.json"
fails_with "$FIX/cap-nopre" 'hooks/hooks.json: needs a PreToolUse command hook "${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh" with matcher mcp__.*'

make_valid_agent "$FIX/cap-nocontract"; rm "$FIX/cap-nocontract/capabilities/crm/contract.md"
fails_with "$FIX/cap-nocontract" "missing capabilities/crm/contract.md"
make_valid_agent "$FIX/cap-noops"; sed -i.bak '/^| `/d' "$FIX/cap-noops/capabilities/crm/contract.md"
fails_with "$FIX/cap-noops" 'capabilities/crm/contract.md: needs a ## Operations table with at least one `operation` in its first column'
make_valid_agent "$FIX/cap-noinv"; sed -i.bak '/^## Invariants/,$d' "$FIX/cap-noinv/capabilities/crm/contract.md"
fails_with "$FIX/cap-noinv" 'capabilities/crm/contract.md: needs a ## Invariants list with at least one `invariant_id`'
make_valid_agent "$FIX/cap-badinv"; echo '- `Draft-Only` — bad id' >> "$FIX/cap-badinv/capabilities/crm/contract.md"
fails_with "$FIX/cap-badinv" "capabilities/crm/contract.md: invariant 'Draft-Only' is not snake_case"
make_valid_agent "$FIX/cap-notool"; rm -r "$FIX/cap-notool/capabilities/crm/tools"
fails_with "$FIX/cap-notool" "capabilities/crm: needs at least one tool in tools/"
make_valid_agent "$FIX/cap-noyaml"; rm "$FIX/cap-noyaml/$AD/identity.yaml"
fails_with "$FIX/cap-noyaml" "missing $AD/identity.yaml"

make_valid_agent "$FIX/cap-wrongcap"; sed -i.bak 's/^capability: .*/capability: crmx/' "$FIX/cap-wrongcap/$AD/identity.yaml"
fails_with "$FIX/cap-wrongcap" "$AD/identity.yaml: capability 'crmx' must be 'crm'"
make_valid_agent "$FIX/cap-wrongprov"; sed -i.bak 's/^provider: .*/provider: other/' "$FIX/cap-wrongprov/$AD/identity.yaml"
fails_with "$FIX/cap-wrongprov" "$AD/identity.yaml: provider 'other' must be 'demo'"
make_valid_agent "$FIX/cap-nomatch"; sed -i.bak '/^server_match/d' "$FIX/cap-nomatch/$AD/identity.yaml"
fails_with "$FIX/cap-nomatch" "$AD/identity.yaml: missing server_match"
make_valid_agent "$FIX/cap-unmapped"; sed -i.bak '/get_lead/d' "$FIX/cap-unmapped/$AD/usage.md"
fails_with "$FIX/cap-unmapped" "$AD/usage.md: does not map operation \`get_lead\`"
make_valid_agent "$FIX/cap-noprobe"; sed -i.bak '/^## Probe/d' "$FIX/cap-noprobe/$AD/usage.md"
fails_with "$FIX/cap-noprobe" "$AD/usage.md: needs a ## Probe section"
make_valid_agent "$FIX/cap-unlisted"; mkdir -p "$FIX/cap-unlisted/capabilities/email"
fails_with "$FIX/cap-unlisted" "capabilities/email is not listed in agent.yaml capabilities"
make_valid_agent "$FIX/cap-badcap"; sed -i.bak 's/^capabilities: .*/capabilities: crm, Email-Drafts/' "$FIX/cap-badcap/agent.yaml"
fails_with "$FIX/cap-badcap" "agent.yaml: capability 'Email-Drafts' is not snake_case"
make_valid_agent "$FIX/cap-badprov"; mv "$FIX/cap-badprov/$AD" "$FIX/cap-badprov/capabilities/crm/tools/Demo_X"
sed -i.bak 's/^provider: .*/provider: Demo_X/' "$FIX/cap-badprov/capabilities/crm/tools/Demo_X/identity.yaml"
fails_with "$FIX/cap-badprov" "capabilities/crm/tools/Demo_X: tool folder name is not kebab-case"
make_valid_agent "$FIX/cap-unread"; chmod 000 "$FIX/cap-unread/capabilities/crm/contract.md"
out=$($V "$FIX/cap-unread" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && ! printf '%s\n' "$out" | grep -qE 'Traceback|checker error'; then _report ok "unreadable contract fails cleanly"; else _report no "unreadable contract (rc=$rc): $out"; fi
chmod 644 "$FIX/cap-unread/capabilities/crm/contract.md"

# The capability skeleton validates once copied into an agent under its own names.
make_valid_agent "$FIX/cap-skel"
mkdir -p "$FIX/cap-skel/capabilities/example_capability"
cp -R _capability-template/. "$FIX/cap-skel/capabilities/example_capability/"
sed -i.bak 's/^capabilities: .*/capabilities: crm, example_capability/' "$FIX/cap-skel/agent.yaml"
assert_pass $V "$FIX/cap-skel"

echo "-- tools and guard policies"
A=capabilities/crm/tools/demo
make_valid_agent "$FIX/cur"; assert_pass $V "$FIX/cur"
make_valid_agent "$FIX/noyaml"; rm "$FIX/noyaml/agent.yaml"
fails_with "$FIX/noyaml" "missing agent.yaml"
make_valid_agent "$FIX/noengine"; rm "$FIX/noengine/hooks/guard_policy.py"
fails_with "$FIX/noengine" "missing hooks/guard_policy.py"
make_valid_agent "$FIX/editengine"; echo "# x" >> "$FIX/editengine/hooks/guard_policy.py"
fails_with "$FIX/editengine" "hooks/guard_policy.py differs from the Agent Standard reference copy (_template/hooks/guard_policy.py in agent-builder)"
make_valid_agent "$FIX/extrakey"; echo 'block: send' >> "$FIX/extrakey/$A/identity.yaml"
fails_with "$FIX/extrakey" "$A/identity.yaml: unknown key 'block' (identity.yaml holds capability, provider, server_match, wrapper)"
make_valid_agent "$FIX/enforce"; echo 'enforce_draft_only: adapter' >> "$FIX/enforce/$A/identity.yaml"
fails_with "$FIX/enforce" "$A/identity.yaml: unknown key 'enforce_draft_only' (identity.yaml holds capability, provider, server_match, wrapper)"
make_valid_agent "$FIX/matchlist"; sed -i.bak 's/^server_match: .*/server_match: [demo]/' "$FIX/matchlist/$A/identity.yaml"
fails_with "$FIX/matchlist" "$A/identity.yaml: server_match must be a plain value, not a YAML list or map"
make_valid_agent "$FIX/matchbare"; sed -i.bak 's/^server_match: .*/server_match:/' "$FIX/matchbare/$A/identity.yaml"; printf '  - demo\n' >> "$FIX/matchbare/$A/identity.yaml"
fails_with "$FIX/matchbare" "$A/identity.yaml line 4: identity.yaml holds flat 'key: value' lines only (no lists or nesting)"
make_valid_agent "$FIX/badpol"; printf '%s\n' 'covers: [draft_only' > "$FIX/badpol/$A/guard.yaml"
fails_with "$FIX/badpol" "$A/guard.yaml: line 1: unclosed '['"
make_valid_agent "$FIX/strange"; printf '%s\n' 'covers: [draft_only, no_send, other]' 'deny: ["*send*"]' > "$FIX/strange/$A/guard.yaml"
fails_with "$FIX/strange" "$A/guard.yaml: covers names other, which is not an invariant of the contract"
make_valid_agent "$FIX/nopolicy"; rm "$FIX/nopolicy/$A/guard.yaml"
fails_with "$FIX/nopolicy" "$A: the contract has no_send, so guard.yaml must cover it"
make_valid_agent "$FIX/nosendcov"; printf '%s\n' 'covers: [draft_only]' > "$FIX/nosendcov/$A/guard.yaml"
fails_with "$FIX/nosendcov" "$A/guard.yaml: covers must include no_send"
make_valid_agent "$FIX/instronly"; sed -i.bak '/no_send/d' "$FIX/instronly/capabilities/crm/contract.md"; rm "$FIX/instronly/$A/guard.yaml"
assert_pass $V "$FIX/instronly"   # a tool without a policy is allowed: instruction-only
make_valid_agent "$FIX/acc"; sed -i.bak 's/^- `draft_only` — only drafts/- `draft_only` (acceptable) — only drafts/' "$FIX/acc/capabilities/crm/contract.md"
assert_pass $V "$FIX/acc"   # an acceptable mark parses; the invariant id is still draft_only
make_valid_agent "$FIX/accnosend"; sed -i.bak 's/^- `no_send` — never sends/- `no_send` (acceptable) — never sends/' "$FIX/accnosend/capabilities/crm/contract.md"
fails_with "$FIX/accnosend" "capabilities/crm/contract.md: no_send cannot be marked (acceptable)"
make_valid_agent "$FIX/noagentpolicy"; rm "$FIX/noagentpolicy/guard.yaml"
fails_with "$FIX/noagentpolicy" "the contract of crm has no_send, so the agent needs a guard.yaml at its root that covers no_send"
make_valid_agent "$FIX/agentnocover"; printf '%s\n' 'deny: ["*send*"]' > "$FIX/agentnocover/guard.yaml"
fails_with "$FIX/agentnocover" "the contract of crm has no_send, so the agent needs a guard.yaml at its root that covers no_send"
make_valid_agent "$FIX/badagentpolicy"; printf '%s\n' 'covers: [no_send]' 'allow: [x]' 'deny: ["*send*"]' > "$FIX/badagentpolicy/guard.yaml"
fails_with "$FIX/badagentpolicy" "guard.yaml: line 2: unknown key 'allow'"
make_valid_agent "$FIX/dirpolicy"; rm "$FIX/dirpolicy/guard.yaml"; mkdir "$FIX/dirpolicy/guard.yaml"
fails_with "$FIX/dirpolicy" "guard.yaml: cannot be read (Is a directory)"
make_valid_agent "$FIX/oldstd"; sed -i.bak 's/standard: "5.0"/standard: "4.0"/' "$FIX/oldstd/agent.yaml"
fails_with "$FIX/oldstd" "agent.yaml: standard '4.0' must be \"5.0\""

echo "-- activities"
make_valid_agent "$FIX/act"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: webspenser/agent-library' 'activity_prospect: crm' 'activity_research: none' >> "$FIX/act/agent.yaml"
mkdir -p "$FIX/act/skills/schedule"; printf '%s\n' '---' 'name: schedule' 'description: Use when scheduling' '---' 'x' > "$FIX/act/skills/schedule/SKILL.md"
assert_pass $V "$FIX/act"
make_valid_agent "$FIX/act-noskill"; echo 'activity_prospect: crm' >> "$FIX/act-noskill/agent.yaml"
fails_with "$FIX/act-noskill" "missing skills/schedule/SKILL.md (agent.yaml declares activities)"
make_valid_agent "$FIX/act-badcap"; echo 'activity_prospect: crm, calendar' >> "$FIX/act-badcap/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-badcap/skills/"
fails_with "$FIX/act-badcap" "agent.yaml: activity_prospect uses calendar, which is not in capabilities"
make_valid_agent "$FIX/act-badname"; echo 'activity_Prospect_Now: crm' >> "$FIX/act-badname/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-badname/skills/"
fails_with "$FIX/act-badname" "agent.yaml: activity 'Prospect_Now' is not kebab-case"
make_valid_agent "$FIX/act-dup"; printf '%s\n' 'activity_prospect: crm' 'activity_prospect : none' >> "$FIX/act-dup/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-dup/skills/"
fails_with "$FIX/act-dup" "agent.yaml: activity_prospect is declared more than once"
make_valid_agent "$FIX/act-dup2"; printf '%s\n' 'activity_prospect: crm' 'activity_prospect: none' >> "$FIX/act-dup2/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-dup2/skills/"
fails_with "$FIX/act-dup2" "agent.yaml: activity_prospect is declared more than once"
make_valid_agent "$FIX/act-indent"; printf '%s\n' 'catalog: webspenser' 'catalog_repo: webspenser/agent-library' 'activity_prospect: crm' '  activity_prospect: none' >> "$FIX/act-indent/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-indent/skills/"
assert_pass $V "$FIX/act-indent"
make_valid_agent "$FIX/act-nocat"; echo 'activity_prospect: crm' >> "$FIX/act-nocat/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-nocat/skills/"
fails_with "$FIX/act-nocat" "agent.yaml: activities need catalog and catalog_repo (the cloud environment installs the agent from its catalog)"
make_valid_agent "$FIX/act-empty"; echo 'activity_prospect:' >> "$FIX/act-empty/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-empty/skills/"
fails_with "$FIX/act-empty" "agent.yaml: activity_prospect lists no capabilities (use none)"
make_valid_agent "$FIX/act-mixed"; echo 'activity_prospect: none, crm' >> "$FIX/act-mixed/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-mixed/skills/"
fails_with "$FIX/act-mixed" "agent.yaml: activity_prospect mixes none with capabilities"
make_valid_agent "$FIX/act-noscript"; rm "$FIX/act-noscript/hooks/schedule_check.py"
fails_with "$FIX/act-noscript" "missing hooks/schedule_check.py"
make_valid_agent "$FIX/act-editscript"; echo "# x" >> "$FIX/act-editscript/hooks/schedule_check.py"
fails_with "$FIX/act-editscript" "hooks/schedule_check.py differs from the Agent Standard reference copy (_template/hooks/schedule_check.py in agent-builder)"

echo "-- tool server_match charset"
make_valid_agent "$FIX/match-space"; sed -i.bak 's/^server_match: .*/server_match: good crm/' "$FIX/match-space/$A/identity.yaml"
fails_with "$FIX/match-space" "$A/identity.yaml: server_match must be lowercase letters, digits, _ or - (the guard compares it to MCP tool names)"
make_valid_agent "$FIX/match-upper"; sed -i.bak 's/^server_match: .*/server_match: GoodCRM/' "$FIX/match-upper/$A/identity.yaml"
fails_with "$FIX/match-upper" "$A/identity.yaml: server_match must be lowercase letters, digits, _ or - (the guard compares it to MCP tool names)"

echo "-- tool checker and add-tool skill"
make_valid_agent "$FIX/no-toolcheck"; rm "$FIX/no-toolcheck/hooks/tool_check.py"
fails_with "$FIX/no-toolcheck" "missing hooks/tool_check.py"
make_valid_agent "$FIX/no-addtool"; rm -r "$FIX/no-addtool/skills/add-tool"
fails_with "$FIX/no-addtool" "missing skills/add-tool/SKILL.md (agent.yaml lists capabilities)"
make_valid_agent "$FIX/edit-addtool"; echo x >> "$FIX/edit-addtool/skills/add-tool/SKILL.md"
fails_with "$FIX/edit-addtool" "skills/add-tool/SKILL.md differs from the Agent Standard reference copy (_template/skills/add-tool/SKILL.md in agent-builder)"

finish
