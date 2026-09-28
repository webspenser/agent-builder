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

finish
