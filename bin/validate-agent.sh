#!/usr/bin/env bash
# Checks that a directory conforms to the Agent Standard (STANDARD.md).
# Usage: bin/validate-agent.sh <agent-dir> [--require-bump <git-ref>]
set -uo pipefail

DIR=""
BUMP_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-bump) BUMP_REF="${2:-}"; shift 2 ;;
    *) DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "FAIL: not a directory: ${DIR:-<none>}"; exit 1; }

ERRORS=0
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

AGENT_HEADINGS=(
  "Identity" "Mission" "Inputs" "Outputs" "Operating rules" "Workflow"
  "Sub-agents" "Skills" "Guardrails / never do" "Escalate to human when"
)
SUBAGENT_HEADINGS=(
  "Purpose" "Trigger" "Inputs" "Outputs" "Tools allowed"
  "Stop conditions" "Handoff" "Inline fallback"
)
ADAPTER_MAX_LINES=25
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${AGENT_VALIDATOR_PYTHON:-python3}"

# Required directories
for d in adapters skills subagents templates samples context evals; do
  [ -d "$DIR/$d" ] || fail "missing directory: $d/"
done

# Required files
[ -f "$DIR/AGENT.md" ]       || fail "missing AGENT.md"
[ -f "$DIR/install.sh" ]     || fail "missing install.sh"
[ -x "$DIR/install.sh" ]     || fail "install.sh is not executable"
[ -f "$DIR/evals/cases.md" ] || fail "missing evals/cases.md"
for a in CLAUDE GEMINI AGENTS; do
  [ -f "$DIR/adapters/$a.md" ] || fail "missing adapters/$a.md"
done

# AGENT.md headings present and in order
if [ -f "$DIR/AGENT.md" ]; then
  found=$(grep -E '^#{2,3} ' "$DIR/AGENT.md" | sed -E 's/^#+ +//' || true)
  expected=$(printf '%s\n' "${AGENT_HEADINGS[@]}")
  filtered=$(echo "$found" | grep -Fx -f <(printf '%s\n' "${AGENT_HEADINGS[@]}") || true)
  [ "$filtered" = "$expected" ] || fail "AGENT.md headings missing or out of order"
fi

# Adapters are pointers, not behavior
for a in CLAUDE GEMINI AGENTS; do
  f="$DIR/adapters/$a.md"
  [ -f "$f" ] || continue
  # awk counts every line regardless of a missing trailing newline;
  # `wc -l` undercounts by one in that case.
  lines=$(awk 'END { print NR }' "$f")
  [ "$lines" -le "$ADAPTER_MAX_LINES" ] \
    || fail "adapters/$a.md has $lines lines (max $ADAPTER_MAX_LINES) — adapters carry no behavior"
  grep -qF 'AGENT.md' "$f" || fail "adapters/$a.md does not point at AGENT.md"
done

# Skills: frontmatter shape — opening and closing fence, only name/description keys
while IFS= read -r f; do
  [ -n "$f" ] || continue
  head -1 "$f" | grep -qx -- '---' || { fail "$f: missing opening frontmatter ---"; continue; }
  close_line=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$f")
  [ -n "$close_line" ] || { fail "$f: missing closing frontmatter ---"; continue; }
  fm=$(sed -n "2,$((close_line - 1))p" "$f")
  name=$(echo "$fm" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//' || true)
  desc=$(echo "$fm" | grep -m1 '^description:' | sed 's/^description:[[:space:]]*//' || true)
  [ -n "$name" ] || fail "$f: missing name in frontmatter"
  echo "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || fail "$f: name '$name' is not kebab-case"
  [ -n "$desc" ] || fail "$f: missing description in frontmatter"
  case "$desc" in
    "Use when"*) ;;
    *) fail "$f: description must begin with 'Use when'" ;;
  esac
  extra=$(echo "$fm" | grep -vE '^(name|description):' | grep -vE '^[[:space:]]*$' || true)
  [ -z "$extra" ] || fail "$f: frontmatter has keys other than name/description: $(echo "$extra" | head -1)"
done < <(find "$DIR/skills" -name SKILL.md 2>/dev/null)

# Sub-agent contracts: required headings present AND in order
while IFS= read -r f; do
  [ -n "$f" ] || continue
  found=$(grep -E '^#{2,3} ' "$f" | sed -E 's/^#+ +//' || true)
  expected=$(printf '%s\n' "${SUBAGENT_HEADINGS[@]}")
  filtered=$(echo "$found" | grep -Fx -f <(printf '%s\n' "${SUBAGENT_HEADINGS[@]}") || true)
  [ "$filtered" = "$expected" ] || fail "$f: headings missing or out of order"
done < <(find "$DIR/subagents" -name '*.md' 2>/dev/null)

# Agent Standard 1.0: agent.yaml and host manifests
if [ -f "$DIR/agent.yaml" ]; then
  if command -v "$PYTHON" >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -n "$line" ] && fail "${line#FAIL: }"
    done < <("$PYTHON" "$BIN_DIR/lib/check_manifests.py" "$DIR" 2>&1)
  else
    fail "python3 is required for Agent Standard 1.0 checks (set AGENT_VALIDATOR_PYTHON to its path)"
  fi
else
  echo "WARN: $DIR has no agent.yaml — checked as pre-1.0"
fi

# Release rule: files changed since the ref require a version bump.
if [ -n "$BUMP_REF" ]; then
  if ! git -C "$DIR" rev-parse --verify --quiet "$BUMP_REF^{commit}" >/dev/null 2>&1; then
    fail "--require-bump: unknown git ref '$BUMP_REF'"
  elif git -C "$DIR" cat-file -e "$BUMP_REF:./agent.yaml" 2>/dev/null; then
    old_ver=$(git -C "$DIR" show "$BUMP_REF:./agent.yaml" | grep -m1 '^version:' | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//')
    new_ver=$(grep -m1 '^version:' "$DIR/agent.yaml" 2>/dev/null | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//')
    changed=$(git -C "$DIR" diff --name-only "$BUMP_REF" -- . | head -1)
    untracked=$(git -C "$DIR" ls-files --others --exclude-standard -- . | head -1)
    if { [ -n "$changed" ] || [ -n "$untracked" ]; } && [ "$old_ver" = "$new_ver" ]; then
      fail "files changed since $BUMP_REF but version is still $new_ver — bump it in agent.yaml and all four host manifests"
    fi
  fi
fi

if [ "$ERRORS" -eq 0 ]; then echo "OK: $DIR conforms"; exit 0; fi
echo "$ERRORS problem(s) in $DIR"; exit 1
