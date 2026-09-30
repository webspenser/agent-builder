#!/usr/bin/env bash
# Checks that a directory conforms to the Agent Standard (STANDARD.md).
# Usage: bin/validate-agent.sh <agent-dir> [--require-bump <git-ref>]
set -uo pipefail

USAGE="Usage: validate-agent.sh <agent-dir> [--require-bump <git-ref>]"
DIR=""
DIR_SET=0
BUMP_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$USAGE"; exit 0 ;;
    --require-bump)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "FAIL: --require-bump requires a git ref"; exit 1; fi
      BUMP_REF="$2"; shift 2 ;;
    -*) echo "FAIL: unknown option '$1'"; echo "$USAGE"; exit 1 ;;
    *)
      if [ "$DIR_SET" -eq 1 ]; then echo "FAIL: unexpected argument '$1'"; echo "$USAGE"; exit 1; fi
      DIR="$1"; DIR_SET=1; shift ;;
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
HOST_MAX_LINES=25
# Resolve symlinks to this script (portable: no GNU `readlink -f`).
SELF="$0"
while [ -L "$SELF" ]; do
  target=$(readlink "$SELF")
  case "$target" in
    /*) SELF="$target" ;;
    *) SELF="$(dirname "$SELF")/$target" ;;
  esac
done
BIN_DIR="$(cd "$(dirname "$SELF")" && pwd)"
PYTHON="${AGENT_VALIDATOR_PYTHON:-python3}"
CHECKER="$BIN_DIR/lib/check_manifests.py"
PY_MISSING="python3 is required for Agent Standard checks (set AGENT_VALIDATOR_PYTHON to its path)"
have_python() { command -v "$PYTHON" >/dev/null 2>&1; }

# Required directories
for d in hosts skills subagents templates samples context evals; do
  [ -d "$DIR/$d" ] || fail "missing directory: $d/"
done

# Required files
[ -f "$DIR/AGENT.md" ]       || fail "missing AGENT.md"
[ -f "$DIR/install.sh" ]     || fail "missing install.sh"
[ -x "$DIR/install.sh" ]     || fail "install.sh is not executable"
[ -f "$DIR/evals/cases.md" ] || fail "missing evals/cases.md"
for a in CLAUDE GEMINI AGENTS; do
  [ -f "$DIR/hosts/$a.md" ] || fail "missing hosts/$a.md"
done

# AGENT.md headings present and in order
if [ -f "$DIR/AGENT.md" ]; then
  found=$(grep -E '^#{2,3} ' "$DIR/AGENT.md" | sed -E 's/^#+ +//' || true)
  expected=$(printf '%s\n' "${AGENT_HEADINGS[@]}")
  filtered=$(echo "$found" | grep -Fx -f <(printf '%s\n' "${AGENT_HEADINGS[@]}") || true)
  [ "$filtered" = "$expected" ] || fail "AGENT.md headings missing or out of order"
fi

# Host files are pointers, not behavior
[ -d "$DIR/adapters" ] && fail "adapters/ is the Agent Standard 2 name; 3.0 uses hosts/"
for a in CLAUDE GEMINI AGENTS; do
  f="$DIR/hosts/$a.md"
  [ -f "$f" ] || continue
  # awk counts every line regardless of a missing trailing newline;
  # `wc -l` undercounts by one in that case.
  lines=$(awk 'END { print NR }' "$f")
  [ "$lines" -le "$HOST_MAX_LINES" ] \
    || fail "hosts/$a.md has $lines lines (max $HOST_MAX_LINES) — host files carry no behavior"
  grep -qF 'AGENT.md' "$f" || fail "hosts/$a.md does not point at AGENT.md"
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

# Sub-agent contracts sit directly in subagents/, never nested.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  fail "subagents/${f#"$DIR/subagents/"}: contracts must sit directly in subagents/"
done < <(find "$DIR/subagents" -mindepth 2 -name '*.md' 2>/dev/null)

# Sub-agent contracts: required headings present AND in order
while IFS= read -r f; do
  [ -n "$f" ] || continue
  found=$(grep -E '^#{2,3} ' "$f" | sed -E 's/^#+ +//' || true)
  expected=$(printf '%s\n' "${SUBAGENT_HEADINGS[@]}")
  filtered=$(echo "$found" | grep -Fx -f <(printf '%s\n' "${SUBAGENT_HEADINGS[@]}") || true)
  [ "$filtered" = "$expected" ] || fail "$f: headings missing or out of order"
done < <(find "$DIR/subagents" -maxdepth 1 -name '*.md' 2>/dev/null)

# agent.yaml, host manifests, hooks, capabilities
if [ -f "$DIR/agent.yaml" ]; then
  if have_python; then
    out=$("$PYTHON" "$CHECKER" "$DIR" 2>&1); rc=$?
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        "WARN: "*) echo "$line" ;;  # advisory: shown, not counted
        *) fail "${line#FAIL: }" ;;
      esac
    done <<< "$out"
    [ "$rc" -eq 0 ] || fail "manifest checker crashed (exit $rc)"
  else
    fail "$PY_MISSING"
  fi
else
  fail "missing agent.yaml"
fi

# Release rule: files changed since the ref require a version bump.
if [ -n "$BUMP_REF" ]; then
  if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "--require-bump: $DIR is not inside a git repository"
  elif ! git -C "$DIR" rev-parse --verify --quiet "$BUMP_REF^{commit}" >/dev/null 2>&1; then
    fail "--require-bump: unknown git ref '$BUMP_REF' (in CI, check out with fetch-depth: 0)"
  elif git -C "$DIR" cat-file -e "$BUMP_REF:./agent.yaml" 2>/dev/null; then
    if ! have_python; then
      [ -f "$DIR/agent.yaml" ] || fail "$PY_MISSING"  # otherwise already reported above
    else
      # One parser for both sides: check_manifests.py --get.
      old_ver=$(git -C "$DIR" show "$BUMP_REF:./agent.yaml" | "$PYTHON" "$CHECKER" --get version - 2>&1); old_rc=$?
      new_ver=$("$PYTHON" "$CHECKER" --get version "$DIR/agent.yaml" 2>&1); new_rc=$?
      if [ "$old_rc" -ne 0 ] || [ "$new_rc" -ne 0 ]; then
        fail "--require-bump: could not read version from agent.yaml (exit $old_rc/$new_rc)"
      else
        changed=$(git -C "$DIR" diff --name-only "$BUMP_REF" -- . | head -1)
        untracked=$(git -C "$DIR" ls-files --others --exclude-standard -- . | head -1)
        if { [ -n "$changed" ] || [ -n "$untracked" ]; } && [ "$old_ver" = "$new_ver" ]; then
          fail "files changed since $BUMP_REF but version is still $new_ver — bump it in agent.yaml and all four host manifests"
        fi
      fi
    fi
  fi
fi

if [ "$ERRORS" -eq 0 ]; then echo "OK: $DIR conforms"; exit 0; fi
echo "$ERRORS problem(s) in $DIR"; exit 1
