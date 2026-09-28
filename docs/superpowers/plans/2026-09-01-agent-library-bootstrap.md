# Webspenser Agent Library Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Note on the CRM contract:** it evolved during execution from six
> operations to eleven, each addition closing a hole a review found.
> [`docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md`](https://github.com/webspenser/sales-partner/blob/main/docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md)
> and [`sales-partner/context/crm-contract.md`](https://github.com/webspenser/sales-partner/blob/main/context/crm-contract.md)
> are the live authority on the contract's final shape. The per-task text
> below (Task 6 especially, and the "ten operations" reference near line
> 790) records what was asked at the time, not the final state — it is
> left unedited as a historical record rather than rewritten.

**Goal:** Build the portable agent specification format — a validator, a
`_template/` skeleton, and an `install.sh` — then build the first agent,
`sales-partner`, from that template.

**Architecture:** Every agent is a directory of provider-neutral markdown
with one source of truth (`AGENT.md`). Provider differences live only in
`adapters/`, which are pointer files containing no behavior. `install.sh`
symlinks adapters into whatever filename each host looks for. A bash
validator enforces the conventions so conformance is checkable rather than
aspirational.

**Tech Stack:** Bash (zero dependencies, no test framework), Markdown.
Airtable as the first CRM adapter. Apify, Gmail, and web search as the
live tool surface.

**Specs:**
- [Portable Agent Specification Format](../specs/2026-09-01-portable-agent-spec-design.md)
- [Sales Partner Agent](https://github.com/webspenser/sales-partner/blob/main/docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md)

## Global Constraints

- Repository root is `/Users/hochoy/Work/Webspenser/agent-library`. All
  paths in this plan are relative to it.
- **Adapters carry zero behavior.** Any rule inside an adapter file is a
  defect — it causes provider divergence, which is the failure the format
  exists to prevent.
- **No step on any agent's critical path may require tier 1** (sub-agent
  dispatch). Dispatch buys parallelism and context isolation, never
  correctness.
- `AGENT.md` uses these headings, in this order, exactly: `Identity`,
  `Mission`, `Inputs`, `Outputs`, `Operating rules`, `Workflow`,
  `Sub-agents`, `Skills`, `Guardrails / never do`, `Escalate to human when`.
- Sub-agent contracts use these headings, in this order, exactly:
  `Purpose`, `Trigger`, `Inputs`, `Outputs`, `Tools allowed`,
  `Stop conditions`, `Handoff`, `Inline fallback`.
- Skill frontmatter is exactly two keys: `name` (kebab-case) and
  `description` (begins with the words `Use when`).
- **No sub-agent contract may name another sub-agent contract.** Handoffs
  happen through CRM stage transitions only.
- **The Approacher and Follow-up contracts must not list any send tool** in
  `Tools allowed`. Autonomy is enforced by absent capability, not by
  instruction.
- Every `Stop conditions` entry must be a countable resource — a spend cap,
  a quota, an item count, a touch limit. Never "when done".
- Sales-partner lead stages, exactly: `New`, `Scored`, `Researched`,
  `Approach Drafted`, `Contacted`, `Replied`, `Call Scheduled`,
  `Call Held`, `Following Up`, `Won`, `Lost`, `Disqualified`.
- CRM contract operations, exactly ten: `create_lead`, `get_lead`,
  `update_stage`, `update_lead`, `log_activity`, `log_research`,
  `upsert_contact`, `query_by_stage`, `query_by_score`, `query_activities`.
- LinkedIn is draft-and-hand-to-human. No automated LinkedIn action, ever.
- `samples/` in `_template/` ships empty but for a README. Generic samples
  teach generic voice.
- Commit after every task. Use `git -c user.name="Andrew Ho Choy" -c
  user.email="a.hochoy@gmail.com" commit` if git identity is unset.

---

### Task 1: Test harness and conventions validator

Builds the tool that every later task is checked against, so it comes first.

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/validate-agent.sh`
- Create: `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `tests/validate-agent.sh <agent-dir>` — exits 0 when the
  directory conforms, exits 1 and prints one `FAIL: <reason>` line per
  violation. Used by Tasks 3, 5, 8, and 15.
  `tests/lib.sh` exports `assert_pass <cmd...>`, `assert_fail <cmd...>`,
  `assert_contains <file> <string>`, and `finish` (prints the tally and
  exits non-zero if anything failed).

- [ ] **Step 1: Write the failing test**

Create `tests/test-validate-agent.sh`:

```bash
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
assert_pass tests/validate-agent.sh "$FIX/good"

# A missing required directory fails.
make_valid_agent "$FIX/no-skills"; rmdir "$FIX/no-skills/skills"
assert_fail tests/validate-agent.sh "$FIX/no-skills"

# AGENT.md headings out of order fails.
make_valid_agent "$FIX/bad-order"
printf '%s\n' '## Mission' '## Identity' > "$FIX/bad-order/AGENT.md"
assert_fail tests/validate-agent.sh "$FIX/bad-order"

# A skill missing frontmatter fails.
make_valid_agent "$FIX/bad-skill"
mkdir -p "$FIX/bad-skill/skills/thing"
echo 'no frontmatter here' > "$FIX/bad-skill/skills/thing/SKILL.md"
assert_fail tests/validate-agent.sh "$FIX/bad-skill"

# A skill description not starting with "Use when" fails.
make_valid_agent "$FIX/bad-desc"
mkdir -p "$FIX/bad-desc/skills/thing"
printf '%s\n' '---' 'name: thing' 'description: Does a thing' '---' \
  > "$FIX/bad-desc/skills/thing/SKILL.md"
assert_fail tests/validate-agent.sh "$FIX/bad-desc"

# A sub-agent contract missing a required heading fails.
make_valid_agent "$FIX/bad-sub"
printf '%s\n' '## Purpose' '## Trigger' > "$FIX/bad-sub/subagents/role.md"
assert_fail tests/validate-agent.sh "$FIX/bad-sub"

# An adapter containing behavior rules fails.
make_valid_agent "$FIX/fat-adapter"
{ echo 'Read `AGENT.md` in this directory.'
  for i in $(seq 1 40); do echo "Extra rule line $i"; done
} > "$FIX/fat-adapter/adapters/GEMINI.md"
assert_fail tests/validate-agent.sh "$FIX/fat-adapter"

finish
```

- [ ] **Step 2: Write the assertion library**

Create `tests/lib.sh`:

```bash
# Minimal assertion helpers. No external test framework.
PASS_COUNT=0
FAIL_COUNT=0

_report() { # _report <ok|no> <label>
  if [ "$1" = ok ]; then
    PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   $2"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL $2"
  fi
}

assert_pass() { # assert_pass <cmd...> — expect exit 0
  if "$@" >/dev/null 2>&1; then _report ok "exit 0: $*"
  else _report no "expected exit 0: $*"; fi
}

assert_fail() { # assert_fail <cmd...> — expect non-zero exit
  if "$@" >/dev/null 2>&1; then _report no "expected non-zero: $*"
  else _report ok "non-zero: $*"; fi
}

assert_contains() { # assert_contains <file> <string>
  if grep -qF -- "$2" "$1" 2>/dev/null; then _report ok "$1 contains '$2'"
  else _report no "$1 missing '$2'"; fi
}

finish() {
  echo "-- $PASS_COUNT passed, $FAIL_COUNT failed"
  [ "$FAIL_COUNT" -eq 0 ]
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
chmod +x tests/test-validate-agent.sh && tests/test-validate-agent.sh
```

Expected: every assertion reports `FAIL` (validate-agent.sh does not exist
yet, so `assert_pass` fails; `assert_fail` cases pass spuriously). The run
exits non-zero.

- [ ] **Step 4: Write the validator**

Create `tests/validate-agent.sh`:

```bash
#!/usr/bin/env bash
# Checks that a directory conforms to CONVENTIONS.md.
# Usage: tests/validate-agent.sh <agent-dir>
set -uo pipefail

DIR="${1:-}"
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
  lines=$(wc -l < "$f" | tr -d ' ')
  [ "$lines" -le "$ADAPTER_MAX_LINES" ] \
    || fail "adapters/$a.md has $lines lines (max $ADAPTER_MAX_LINES) — adapters carry no behavior"
  grep -qF 'AGENT.md' "$f" || fail "adapters/$a.md does not point at AGENT.md"
done

# Skills: frontmatter shape
while IFS= read -r f; do
  [ -n "$f" ] || continue
  head -1 "$f" | grep -qx -- '---' || { fail "$f: missing opening frontmatter ---"; continue; }
  name=$(sed -n '2,10p' "$f" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//' || true)
  desc=$(sed -n '2,10p' "$f" | grep -m1 '^description:' | sed 's/^description:[[:space:]]*//' || true)
  [ -n "$name" ] || fail "$f: missing name in frontmatter"
  echo "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' || fail "$f: name '$name' is not kebab-case"
  [ -n "$desc" ] || fail "$f: missing description in frontmatter"
  case "$desc" in
    "Use when"*) ;;
    *) fail "$f: description must begin with 'Use when'" ;;
  esac
done < <(find "$DIR/skills" -name SKILL.md 2>/dev/null)

# Sub-agent contracts: required headings
while IFS= read -r f; do
  [ -n "$f" ] || continue
  for h in "${SUBAGENT_HEADINGS[@]}"; do
    grep -qE "^#{2,3} +$h\$" "$f" || fail "$f: missing heading '$h'"
  done
done < <(find "$DIR/subagents" -name '*.md' 2>/dev/null)

if [ "$ERRORS" -eq 0 ]; then echo "OK: $DIR conforms"; exit 0; fi
echo "$ERRORS problem(s) in $DIR"; exit 1
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
chmod +x tests/validate-agent.sh && tests/test-validate-agent.sh
```

Expected: `-- 7 passed, 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "test: add conventions validator and assertion harness"
```

---

### Task 2: CONVENTIONS.md

The written standard the validator enforces. Written second so it documents
behavior that already exists and is checkable.

**Files:**
- Create: `CONVENTIONS.md`

**Interfaces:**
- Consumes: `tests/validate-agent.sh` (documents its rules)
- Produces: the human-readable contract referenced by `README.md` and by
  every agent's `AGENT.md`

- [ ] **Step 1: Write CONVENTIONS.md**

The file must contain these sections, with this content:

1. **`# Agent Specification Conventions`** — one paragraph: an agent
   specification is a directory of provider-neutral markdown with a single
   source of truth; provider differences live only in `adapters/`.

2. **`## Directory layout`** — the fenced tree, copied verbatim from the
   framework spec's Directory Layout section.

3. **`## AGENT.md`** — the ten required headings in order, each with a
   one-line description of what belongs under it:
   - `Identity` — who the agent is, two or three sentences
   - `Mission` — the outcome it exists to produce
   - `Inputs` — what it needs before it can start
   - `Outputs` — what it produces, with exact artifact shapes
   - `Operating rules` — how it works, numbered
   - `Workflow` — ordered steps, each tagged with its required capability tier
   - `Sub-agents` — table: role, when to use, contract path
   - `Skills` — table: skill, trigger condition
   - `Guardrails / never do` — hard prohibitions
   - `Escalate to human when` — explicit stop-and-ask conditions

4. **`## Skills`** — frontmatter is exactly `name` (kebab-case) and
   `description` (begins with `Use when`). Body is a numbered procedure,
   one worked example, and known failure modes. Deep material goes in
   `references/` and is read on demand, keeping the always-loaded surface
   small.

5. **`## Sub-agent contracts`** — the eight required headings in order, with
   these rules stated explicitly:
   - No contract may name another contract. Handoffs happen through state
     transitions only. This is what lets the pipeline collapse into
     sequential inline phases on a host without dispatch.
   - Every `Stop conditions` entry is a countable resource — a spend cap, a
     quota, an item count, a touch limit. Never "when done".
   - `Tools allowed` is the enforcement mechanism for autonomy. A contract
     that must not send does not list a send tool.

6. **`## templates/ vs samples/ vs context/`** — templates are blank
   artifacts the agent produces; samples are filled gold-standard examples
   it imitates for voice; context is material it consumes. They stay
   separate because merging templates and samples causes placeholder text
   to appear in output, and merging context in causes reference material to
   be emitted as a deliverable.

7. **`## Adapters`** — pointer files only, 25 lines maximum, must reference
   `AGENT.md`. Any rule placed in an adapter causes provider divergence.

8. **`## Capability tiers`** — the three-tier table from `README.md`, plus
   the constraint that no critical-path step may require tier 1.

9. **`## Validation`** — `tests/validate-agent.sh <agent-dir>` exits 0 on
   conformance. Run it before committing any agent change.

- [ ] **Step 2: Verify the document matches the validator**

```bash
grep -c 'Escalate to human when' CONVENTIONS.md
grep -c 'Inline fallback' CONVENTIONS.md
grep -c 'Use when' CONVENTIONS.md
```

Expected: each returns at least `1`. If a heading named in
`tests/validate-agent.sh` is absent from `CONVENTIONS.md`, add it.

- [ ] **Step 3: Commit**

```bash
git add CONVENTIONS.md
git commit -m "docs: add agent specification conventions"
```

---

### Task 3: `_template/` skeleton

**Files:**
- Create: `_template/AGENT.md`
- Create: `_template/adapters/CLAUDE.md`
- Create: `_template/adapters/GEMINI.md`
- Create: `_template/adapters/AGENTS.md`
- Create: `_template/skills/.gitkeep`
- Create: `_template/subagents/.gitkeep`
- Create: `_template/templates/.gitkeep`
- Create: `_template/context/.gitkeep`
- Create: `_template/samples/README.md`
- Create: `_template/evals/cases.md`

**Interfaces:**
- Consumes: `tests/validate-agent.sh` from Task 1
- Produces: a directory that Task 5 copies to create `sales-partner/`.
  `install.sh` is added in Task 4, so this task's validator run will report
  the missing `install.sh` — that is expected and resolved in Task 4.

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p _template/{adapters,skills,subagents,templates,samples,context,evals}
touch _template/{skills,subagents,templates,context}/.gitkeep
```

- [ ] **Step 2: Write `_template/AGENT.md`**

All ten headings present, each containing a bracketed instruction telling
the author what to write. Bracketed instructions are acceptable **only in
`_template/`** — they are the template's product, not placeholders.

```markdown
# [Agent Name]

## Identity
[Who this agent is, in two or three sentences. Write it as a role a person
could hold, not as a description of software.]

## Mission
[The single outcome this agent exists to produce.]

## Inputs
[What must exist before the agent can start. Files, credentials, access.]

## Outputs
[What it produces, with the exact shape of each artifact.]

## Operating rules
1. [Numbered. How the agent works, not what it knows.]

## Workflow
[Ordered steps. Tag each with its required capability tier — T1, T2, or T3.
No step on the critical path may require T1.]

## Sub-agents
| Role | When to use | Contract |
|---|---|---|
| [role] | [trigger] | `subagents/[role].md` |

## Skills
| Skill | Trigger |
|---|---|
| [skill-name] | [condition that fires it] |

## Guardrails / never do
- [Hard prohibitions. Prefer removing the capability over instructing
  against its use.]

## Escalate to human when
- [Explicit stop-and-ask conditions.]
```

- [ ] **Step 3: Write the three adapters**

`_template/adapters/GEMINI.md` and `_template/adapters/AGENTS.md` are
identical except for the title:

```markdown
# [Agent Name]

Read `AGENT.md` in this directory. It is the full specification —
identity, rules, workflow, guardrails. Follow it exactly.

Skills: read `skills/<name>/SKILL.md` when its trigger matches.

Sub-agents: `subagents/*.md` are role contracts. This host has no
dispatch — run each contract inline as a sequential phase, in the order
`AGENT.md` gives.
```

`_template/adapters/CLAUDE.md` differs in the sub-agent paragraph only:

```markdown
# [Agent Name]

Read `AGENT.md` in this directory. It is the full specification —
identity, rules, workflow, guardrails. Follow it exactly.

Skills: read `skills/<name>/SKILL.md` when its trigger matches.

Sub-agents: `subagents/*.md` are role contracts. Dispatch each through
the Agent tool using the definitions in `.claude/agents/`.
```

- [ ] **Step 4: Write `_template/samples/README.md`**

```markdown
# Samples

Replace everything in this directory after the intake interview.

Samples teach voice. This template ships none on purpose — a generic
sample would be copied into real output and nobody would notice it
happened.

Add three to five filled artifacts written in the voice this agent should
produce. Real ones, from the actual business.
```

- [ ] **Step 5: Write `_template/evals/cases.md`**

```markdown
# Evaluation Cases

Given-X-expect-Y checks. Prefer negative cases — what the agent must
refrain from doing. Positive outcomes are rarely testable without
judgment; refusals are binary and catch the failures that cost money or
reputation.

1. Given [input], the agent [refrains from / produces] [observable behavior]
```

- [ ] **Step 6: Run the validator**

```bash
tests/validate-agent.sh _template
```

Expected: exit 1 with exactly these two lines —
`FAIL: missing install.sh` and `FAIL: install.sh is not executable`.
Both are resolved in Task 4. Any other failure is a real defect; fix it
before committing.

- [ ] **Step 7: Commit**

```bash
git add _template/
git commit -m "feat: add agent specification template skeleton"
```

---

### Task 4: `install.sh` and its tests

**Files:**
- Create: `_template/install.sh`
- Create: `tests/test-install.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` from Task 1
- Produces: `install.sh` supporting `--copy` and `--dry-run`. Copied into
  every agent directory by Task 5.

- [ ] **Step 1: Write the failing test**

Create `tests/test-install.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Symlink mode: adapters appear at the agent root as links.
cp -R _template "$WORK/link-agent"
( cd "$WORK/link-agent" && ./install.sh >/dev/null 2>&1 )
for f in CLAUDE.md GEMINI.md AGENTS.md; do
  if [ -L "$WORK/link-agent/$f" ]; then _report ok "$f is a symlink"
  else _report no "$f is not a symlink"; fi
done
if [ -f "$WORK/link-agent/.claude/agents" ] || [ -d "$WORK/link-agent/.claude" ]; then
  _report ok ".claude/ created"
else _report no ".claude/ missing"; fi

# Copy mode: real files that survive the source being deleted.
cp -R _template "$WORK/copy-agent"
( cd "$WORK/copy-agent" && ./install.sh --copy >/dev/null 2>&1 )
for f in CLAUDE.md GEMINI.md AGENTS.md; do
  if [ -f "$WORK/copy-agent/$f" ] && [ ! -L "$WORK/copy-agent/$f" ]; then
    _report ok "$f is a real file"
  else _report no "$f is not a real file"; fi
done
rm -rf "$WORK/copy-agent/adapters"
assert_contains "$WORK/copy-agent/CLAUDE.md" "AGENT.md"

# Idempotence: a second run must not fail or nest links.
( cd "$WORK/link-agent" && ./install.sh >/dev/null 2>&1 )
assert_pass test -L "$WORK/link-agent/CLAUDE.md"

# Dry run writes nothing.
cp -R _template "$WORK/dry-agent"
( cd "$WORK/dry-agent" && ./install.sh --dry-run >/dev/null 2>&1 )
assert_fail test -e "$WORK/dry-agent/CLAUDE.md"

finish
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x tests/test-install.sh && tests/test-install.sh
```

Expected: failures — `_template/install.sh` does not exist.

- [ ] **Step 3: Write `_template/install.sh`**

```bash
#!/usr/bin/env bash
# Links this agent's adapters into the filenames each host looks for.
#   ./install.sh            symlink (default) — one copy of every fact on disk
#   ./install.sh --copy     independent copies, for handoff or link-averse hosts
#   ./install.sh --dry-run  print what would happen, write nothing
set -euo pipefail

cd "$(dirname "$0")"
MODE=link
for arg in "$@"; do
  case "$arg" in
    --copy)    MODE=copy ;;
    --dry-run) MODE=dry ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ -d adapters ] || { echo "no adapters/ directory here" >&2; exit 1; }

place() { # place <source> <destination>
  local src="$1" dest="$2"
  case "$MODE" in
    dry)  echo "would place $dest -> $src"; return ;;
    copy) rm -rf "$dest"; cp "$src" "$dest"; echo "copied  $dest" ;;
    link) rm -rf "$dest"; ln -s "$src" "$dest"; echo "linked  $dest" ;;
  esac
}

place adapters/CLAUDE.md CLAUDE.md
place adapters/GEMINI.md GEMINI.md
place adapters/AGENTS.md AGENTS.md

# Claude Code additionally discovers skills and agents by directory.
if [ "$MODE" != dry ]; then
  mkdir -p .claude
  rm -rf .claude/skills .claude/agents
  case "$MODE" in
    copy) cp -R skills .claude/skills; cp -R subagents .claude/agents ;;
    link) ln -s ../skills .claude/skills; ln -s ../subagents .claude/agents ;;
  esac
  echo "wired   .claude/skills and .claude/agents"
else
  echo "would wire .claude/skills and .claude/agents"
fi

echo "done ($MODE mode)"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x _template/install.sh && tests/test-install.sh
```

Expected: `-- 10 passed, 0 failed`.

- [ ] **Step 5: Verify the template now fully conforms**

```bash
tests/validate-agent.sh _template
```

Expected: `OK: _template conforms`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add _template/install.sh tests/test-install.sh
git commit -m "feat: add adapter install script with symlink and copy modes"
```

---

### Task 5: Scaffold `sales-partner/` and write its `AGENT.md`

**Files:**
- Create: `sales-partner/` (copied from `_template/`)
- Modify: `sales-partner/AGENT.md` (replace all bracketed instructions)
- Modify: `sales-partner/adapters/CLAUDE.md`, `GEMINI.md`, `AGENTS.md`
  (replace `[Agent Name]` with `Sales Partner`)

**Interfaces:**
- Consumes: `_template/` from Tasks 3–4
- Produces: `sales-partner/AGENT.md` — the Sub-agents and Skills tables in
  it are the index Tasks 8–12 fill in.

- [ ] **Step 1: Copy the template**

```bash
cp -R _template sales-partner
find sales-partner -name .gitkeep -delete
```

- [ ] **Step 2: Write `sales-partner/AGENT.md`**

Replace every bracketed instruction. Required content:

- **Identity** — a sales partner for one business. It learns the business
  and its ideal customer through an interview, then runs a five-stage lead
  pipeline on that profile. It researches on its own and drafts everything
  that goes out, but sends nothing.
- **Mission** — a steady flow of qualified leads moved from unknown to
  closed, with every outbound message reviewed by the operator first.
- **Inputs** — `context/business-profile.md`, `context/icp.md`,
  `context/operating-config.md`, CRM credentials, Apify token, Gmail access.
- **Outputs** — scored Lead records; Research rows carrying hooks; Contacts
  with role tags; drafted Activities awaiting approval; call briefs;
  scheduled digests.
- **Operating rules** — numbered:
  1. The CRM is the only source of truth for lead state. Never hold pipeline
     state in conversation.
  2. A lead is in exactly one stage. Work is selected by stage query.
  3. Every factual claim about a prospect carries a source URL. Inferences
     are marked `unverified`.
  4. Every claim about the business traces to `context/business-profile.md`.
  5. Scores come from the rubric in `context/icp.md`, never from judgment.
  6. Nothing sends without operator approval.
  7. Volume, cadence, and caps come from `context/operating-config.md`.
     Changing them is a config edit, never a prompt edit.
- **Workflow** — the six stages, each tier-tagged. All tagged T2 except
  where noted; nothing is T1:
  0. Interview (T3) — run `interview-business`, write the three context files
  1. Prospect (T2) — `subagents/prospector.md`
  2. Prepare (T2) — `subagents/preparer.md`
  3. Approach (T2) — `subagents/approacher.md`
  4. Sales call (T2) — `subagents/sales-call-specialist.md`
  5. Follow up (T2) — `subagents/follow-up.md`
  6. Digest (T3) — `send-digest` on the configured schedule
- **Sub-agents** — the five-row table, each pointing at its contract path,
  with the stage query that triggers it.
- **Skills** — the eleven-row table copied from the agent spec's Skills
  section.
- **Guardrails / never do** — never send any message; never take an
  automated action on LinkedIn; never fabricate an email address, a
  statistic, or a case study; never contact a lead flagged
  `do-not-contact`; never exceed the touch limit; never exceed the Apify
  spend cap.
- **Escalate to human when** — a lead replies with an objection not covered
  by `handle-objections`; a prospect asks about pricing outside the range in
  `business-profile.md`; the Apify cap is reached mid-run; the CRM rejects a
  write; zero leads clear the score threshold across a full run.

- [ ] **Step 3: Set the agent name in the adapters**

```bash
sed -i '' 's/\[Agent Name\]/Sales Partner/' sales-partner/adapters/*.md
grep -h '^# ' sales-partner/adapters/*.md
```

Expected: `# Sales Partner` three times.

- [ ] **Step 4: Validate**

```bash
tests/validate-agent.sh sales-partner
```

Expected: `OK: sales-partner conforms`.

- [ ] **Step 5: Commit**

```bash
git add sales-partner/
git commit -m "feat(sales-partner): scaffold agent and write AGENT.md"
```

---

### Task 6: CRM contract and Airtable adapter

**Files:**
- Create: `sales-partner/context/crm-contract.md`
- Create: `sales-partner/context/crm-airtable-adapter.md`

**Interfaces:**
- Consumes: nothing
- Produces: the ten operations and the four-table schema every sub-agent
  contract in Task 8 refers to. Operation names and field names defined here
  are used verbatim in Tasks 8–12.

- [ ] **Step 1: Write `sales-partner/context/crm-contract.md`**

Provider-neutral. Ten operations, each documented with its arguments,
return shape, and failure behavior:

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `create_lead` | company, domain, location, industry, size, source, score, score_breakdown, source_url | lead_id | Duplicate domain returns the existing lead_id and writes nothing |
| `get_lead` | lead_id | full lead record with linked Contacts, Research, Activities | Missing id is an error, not an empty record |
| `update_stage` | lead_id, stage, reason | updated lead | Rejects any stage outside the enumerated list |
| `update_lead` | lead_id, fields | updated lead | Rejects any attempt to write `stage` — that write belongs to `update_stage` alone |
| `log_activity` | lead_id, contact_id, channel, direction, summary, draft_body, status, outcome | activity_id | Rejects `status: sent` unless the record was previously `approved` |
| `log_research` | lead_id, type, summary, source_url, date, hook | research_id | Rejects a write with an empty source_url or an empty hook |
| `upsert_contact` | lead_id, name, title, email, linkedin_url, role, verified | contact_id | Matches on email when present, otherwise on name plus title, and updates rather than duplicates; rejects a role outside decision-maker/influencer/gatekeeper |
| `query_by_stage` | stage, limit | list of leads | Empty list is a valid result |
| `query_by_score` | min_score, stage, limit | list of leads ordered by score descending | Empty list is a valid result |

State the stage enum verbatim from Global Constraints. State that
`update_stage` is the only handoff mechanism between sub-agents.

- [ ] **Step 2: Write `sales-partner/context/crm-airtable-adapter.md`**

The four tables with exact field names and types. Every field below must
appear, because Tasks 8–12 reference them by name:

**Leads** — `Company` (text), `Domain` (text, unique), `Location` (text),
`Industry` (single select), `Size` (single select), `Source` (text),
`Source URL` (url), `Score` (number 0–100), `Score Breakdown` (long text),
`Stage` (single select, the twelve stages), `Next Action` (text),
`Next Action Due` (date), `Do Not Contact` (checkbox)

**Contacts** — `Name` (text), `Title` (text), `Email` (email),
`LinkedIn URL` (url), `Role` (single select: decision-maker, influencer,
gatekeeper), `Verified` (checkbox), `Lead` (link to Leads)

**Research** — `Type` (single select: news, funding, social, event, hire),
`Summary` (long text), `Source URL` (url), `Date` (date), `Hook` (long
text), `Lead` (link to Leads)

**Activities** — `Channel` (single select: email, linkedin, call, other),
`Direction` (single select: outbound, inbound), `Date` (date), `Summary`
(long text), `Draft Body` (long text), `Status` (single select: draft,
approved, sent), `Outcome` (text), `Lead` (link to Leads), `Contact` (link
to Contacts)

Document the required Airtable views, since they are the operator's
interface:
- **Awaiting Approval** — Activities where `Status = draft`, sorted by Date
- **Research Queue** — Leads where `Stage = Scored`, sorted by Score descending
- **Due Today** — Leads where `Next Action Due` is today or earlier
- **Stalled** — Leads with no Activity newer than the configured cadence

State explicitly: drafts are Activities with `Status = draft`, never a
separate table, so the approval queue is one view and that view is the
entire review interface.

- [ ] **Step 3: Verify field names are consistent**

```bash
grep -o 'Score Breakdown\|Do Not Contact\|Next Action Due\|Draft Body' \
  sales-partner/context/crm-airtable-adapter.md | sort -u
```

Expected: all four names present, spelled exactly once each in this form.

- [ ] **Step 4: Commit**

```bash
git add sales-partner/context/
git commit -m "feat(sales-partner): define CRM contract and Airtable adapter"
```

---

### Task 7: Profile templates in `context/`

The Phase 0 interview fills these. They ship as structured blanks so the
agent has a target shape to write into.

**Files:**
- Create: `sales-partner/context/business-profile.md`
- Create: `sales-partner/context/icp.md`
- Create: `sales-partner/context/operating-config.md`

**Interfaces:**
- Consumes: nothing
- Produces: the three files `interview-business` (Task 9) writes and every
  other phase reads. The `icp.md` rubric shape and the `operating-config.md`
  key names defined here are referenced verbatim in Tasks 8–12.

- [ ] **Step 1: Write `sales-partner/context/business-profile.md`**

Sections, each with a bracketed prompt for the interview to replace:
`## What we sell` · `## Who we serve` · `## Proof` (case studies, metrics,
named references) · `## Pricing` (range, structure, what moves it) ·
`## Differentiators` · `## Disqualifiers` (who we decline and why) ·
`## Voice` (how we sound, with two example sentences).

Add at the top: *"Every claim the agent makes about the business must trace
to this file. If it is not written here, the agent does not say it."*

- [ ] **Step 2: Write `sales-partner/context/icp.md`**

Sections: `## Firmographics` (industry, size, revenue, stage) ·
`## Geography` · `## Target roles` · `## Buying triggers` ·
`## Anti-signals` (hard disqualifiers — any match sends the lead straight
to `Disqualified`) · `## Scoring rubric`.

The rubric table ships with these criteria and weights summing to 100.
These are defaults the interview may change; the weights must always sum to
100:

| Criterion | Weight | 0 points | 50 points | 100 points |
|---|---|---|---|---|
| Industry fit | 25 | outside target list | adjacent | on target list |
| Company size | 20 | outside range | within one band | in range |
| Geography | 10 | unserviceable | serviceable | in primary market |
| Buying trigger present | 25 | none found | soft signal | explicit recent trigger |
| Decision-maker reachable | 20 | none identified | identified, no contact route | identified with contact route |

State the two thresholds the pipeline reads:
`research_threshold` (default 60) and `approach_threshold` (default 70).

- [ ] **Step 3: Write `sales-partner/context/operating-config.md`**

A key-value document. Ship these keys with these defaults:

```yaml
leads_per_week: 40
research_quota_per_week: 10
research_threshold: 60
approach_threshold: 70
enabled_channels: [email, linkedin]
follow_up_cadence_days: 4
max_touches: 4
digest_schedule: "Monday 08:00"
digest_channel: email
apify_spend_cap_usd_per_week: 25
research_budget_per_lead_minutes: 8
sending_identity: "[name] <[email]>"
tone: "[three adjectives from the interview]"
```

Add: *"Volume, cadence, and caps live here. Changing them is a config edit,
never a prompt edit."*

- [ ] **Step 4: Verify every key the sub-agents will read exists**

```bash
for k in research_threshold approach_threshold max_touches \
         follow_up_cadence_days apify_spend_cap_usd_per_week \
         research_quota_per_week leads_per_week; do
  grep -q "$k" sales-partner/context/operating-config.md || echo "MISSING $k"
done
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add sales-partner/context/
git commit -m "feat(sales-partner): add profile and config templates"
```

---

### Task 8: The five sub-agent contracts

**Files:**
- Create: `sales-partner/subagents/prospector.md`
- Create: `sales-partner/subagents/preparer.md`
- Create: `sales-partner/subagents/approacher.md`
- Create: `sales-partner/subagents/sales-call-specialist.md`
- Create: `sales-partner/subagents/follow-up.md`

**Interfaces:**
- Consumes: `context/crm-contract.md` (operation names),
  `context/crm-airtable-adapter.md` (field names),
  `context/operating-config.md` (key names) — all from Tasks 6–7
- Produces: the five contracts referenced by `AGENT.md`'s Sub-agents table
  and dispatched via `.claude/agents/` after `install.sh` runs

Each file uses the eight required headings in order: `Purpose`, `Trigger`,
`Inputs`, `Outputs`, `Tools allowed`, `Stop conditions`, `Handoff`,
`Inline fallback`. Content for each comes from the agent spec's Sub-Agent
Contracts section, transcribed in full including every guardrail.

- [ ] **Step 1: Write `prospector.md`**

Transcribe the spec's contract 1. `Tools allowed`: Apify actors, web
search, CRM `create_lead`, CRM `query_by_stage`. `Stop conditions` must be
three countable limits: `leads_per_week` target reached, source exhausted,
`apify_spend_cap_usd_per_week` hit. `Handoff`: `update_stage(lead, Scored)`.
Guardrails: deduplicate on `Domain` before writing; never fabricate an email
address; any `Anti-signals` match goes straight to `Disqualified`; every
lead carries `Source URL`.

- [ ] **Step 2: Write `preparer.md`**

Transcribe the spec's contract 2. `Trigger`:
`query_by_score(min_score = research_threshold, stage = Scored,
limit = research_quota_per_week)`. `Stop conditions`: two or more `Hook`
values written, or `research_budget_per_lead_minutes` spent. Before
handing off, re-run `score-lead`: research resolves the two rubric criteria
worth 45 points that prospecting can only guess at — buying trigger
present, and decision-maker reachable. Write the revised `Score` and append
to `Score Breakdown`. Guardrails: nothing behind a login; `Source URL` required on every Research row;
inferences marked `unverified` in `Summary`; an anti-signal discovered here
moves the lead to `Disqualified` rather than passing it on.

- [ ] **Step 3: Write `approacher.md`**

Transcribe the spec's contract 3. `Trigger`: `Stage = Researched` **and**
`Score >= approach_threshold` — the Preparer re-scored the lead, so one that
looked promising before research can fall below the bar here rather than
consuming an outreach touch. `Tools allowed` must list exactly: CRM
`get_lead`, CRM `log_activity`, CRM `update_stage`, read access to
`templates/` and `samples/`. **No send tool of any kind.** Add an explicit
line: *"This contract has no send capability. That is the enforcement
mechanism, not an instruction."* `Stop conditions`: one draft Activity
logged. `Handoff`: operator approval flips `Status` to `approved`, then
`sent`, then `update_stage(lead, Contacted)`.

- [ ] **Step 4: Write `sales-call-specialist.md`**

Transcribe the spec's contract 4. `Trigger` has three modes: `Stage = Call
Scheduled` for prep, on request during a call, `Stage = Call Held` for
debrief. Name the three skills it uses: `prepare-sales-call`,
`handle-objections`, `run-live-call-script`. `Stop conditions`: brief
delivered, or debrief logged. Guardrail: every claim traces to
`business-profile.md`; no invented capabilities, metrics, or references.

- [ ] **Step 5: Write `follow-up.md`**

Transcribe the spec's contract 5. `Trigger`: an Activity logged with an
`Outcome`, or a lead idle longer than `follow_up_cadence_days`. `Tools
allowed`: CRM operations and Gmail **draft only** — no send. `Stop
conditions`: draft created and `Next Action` plus `Next Action Due` set, or
`max_touches` reached. Guardrails: any inbound reply containing an opt-out
sets `Do Not Contact` permanently and voids pending drafts; every question
actually asked is answered before anything new is introduced; reaching
`max_touches` moves the lead to `Lost` rather than drafting again.

- [ ] **Step 6: Verify no contract names another contract**

```bash
for f in sales-partner/subagents/*.md; do
  base=$(basename "$f" .md)
  for other in prospector preparer approacher sales-call-specialist follow-up; do
    [ "$other" = "$base" ] && continue
    grep -qi "$other" "$f" && echo "VIOLATION: $f references $other"
  done
done
```

Expected: no output. Contracts coordinate through stage transitions only.

- [ ] **Step 7: Verify the outbound contracts have no send tool**

```bash
sed -n '/## Tools allowed/,/## Stop conditions/p' \
  sales-partner/subagents/approacher.md sales-partner/subagents/follow-up.md \
  | grep -i 'send' || echo "OK: no send tool listed"
```

Expected: `OK: no send tool listed`, or only lines that explicitly state
the absence of a send capability.

- [ ] **Step 8: Validate and commit**

```bash
tests/validate-agent.sh sales-partner
git add sales-partner/subagents/
git commit -m "feat(sales-partner): add five sub-agent role contracts"
```

Expected: `OK: sales-partner conforms` before committing.

---

### Task 9: Skills — interview, scoring, research

**Files:**
- Create: `sales-partner/skills/interview-business/SKILL.md`
- Create: `sales-partner/skills/score-lead/SKILL.md`
- Create: `sales-partner/skills/research-company/SKILL.md`
- Create: `sales-partner/skills/find-decision-makers/SKILL.md`

**Interfaces:**
- Consumes: `context/icp.md` rubric shape, `context/operating-config.md`
  keys, CRM field names — Tasks 6–7
- Produces: four skills listed in `AGENT.md`'s Skills table

Every skill body has: a numbered procedure, one worked example, and a
`## Failure modes` section.

- [ ] **Step 1: Write `interview-business/SKILL.md`**

```markdown
---
name: interview-business
description: Use when installing this agent for a business, or when its offer, market, or targeting has materially changed — conducts the intake interview and writes the three context files.
---
```

Procedure: ask one question at a time, in four rounds — the business, the
customer, the proof, the operating parameters. Never ask two questions in
one message. After each round, write what was learned to the relevant
context file before starting the next round, so a interrupted interview
loses nothing.

Round 1 (business): what do you sell, who is it for, what does it cost,
what happens if a customer does nothing.
Round 2 (customer): describe your three best current customers; what did
they have in common before they bought; who did you decline and why.
Round 3 (proof): what results can you name, with numbers; who will take a
reference call.
Round 4 (operating): how many leads per week, which channels, how often
should the digest arrive, what is the Apify budget, how should the
outreach sound.

Then derive the scoring rubric from Round 2 and confirm the weights with
the operator before writing `icp.md`.

Failure modes: accepting "everyone" as an ICP; writing a rubric the
operator has not confirmed; filling `samples/` with invented copy rather
than asking for real artifacts.

- [ ] **Step 2: Write `score-lead/SKILL.md`**

```markdown
---
name: score-lead
description: Use when a lead needs a score or a re-score — applies the weighted rubric in context/icp.md and records the per-criterion breakdown.
---
```

Procedure: read the rubric from `icp.md`; check anti-signals first and
short-circuit to `Disqualified` on any match; score each criterion against
its stated 0/50/100 anchors; multiply by weight; sum; write both the total
to `Score` and the per-criterion working to `Score Breakdown` in the form
`Industry fit 100×0.25=25 (on target list: B2B SaaS)`.

Worked example: include a full five-criterion calculation for a fictional
company reaching a total of 72.

State that this skill runs twice per lead: once at prospecting on public
signals, and again after research, when buying trigger and decision-maker
reachability are actually known. The second run overwrites `Score` and
appends a `re-scored after research` line to `Score Breakdown`, so the
movement stays visible.

Failure modes: scoring from impression rather than the rubric; omitting the
breakdown, which makes the score unauditable and untunable; scoring a lead
that matched an anti-signal instead of disqualifying it; overwriting the
first breakdown instead of appending, which hides why a score moved.

- [ ] **Step 3: Write `research-company/SKILL.md`**

```markdown
---
name: research-company
description: Use when a lead enters the research quota — gathers recent, specific, verifiable facts about a company and converts them into usable outreach hooks.
---
```

Procedure: search in this order — company site and blog, recent news,
funding and hiring signals, executive social posts, industry events. Stop
at `research_budget_per_lead_minutes`. Write one Research row per finding
with `Type`, `Summary`, `Source URL`, `Date`, and `Hook`.

Define what makes a hook usable: it is specific to this company, recent
(under 90 days), and something the operator could plausibly have an opinion
about. A hook is not "they are in SaaS"; a hook is "they posted three
support-engineer roles in two weeks after announcing a Series A".

Failure modes: producing a research dump with no hook; hooks older than 90
days presented as news; inventing a hook when the company has no public
footprint — record "no hooks found" and let the lead stall instead.

- [ ] **Step 4: Write `find-decision-makers/SKILL.md`**

```markdown
---
name: find-decision-makers
description: Use when the target company is known but the right person is not — identifies decision-makers, influencers, and gatekeepers, and finds a contact route for each.
---
```

Procedure: read target roles from `icp.md`; search the company site team
page, LinkedIn company page, and public directories; classify each person
as decision-maker, influencer, or gatekeeper; find a contact route; mark
`Verified` only when the email came from a verifiable source, never from a
pattern guess.

State explicitly: a guessed email address is never written to the `Email`
field. Record the guess in the Contact's notes as `pattern guess,
unverified` and leave `Verified` unchecked.

Failure modes: writing a pattern-guessed address as if verified; targeting
the most senior person rather than the actual buyer; recording a
gatekeeper as a decision-maker.

- [ ] **Step 5: Validate and commit**

```bash
tests/validate-agent.sh sales-partner
git add sales-partner/skills/
git commit -m "feat(sales-partner): add interview, scoring, and research skills"
```

---

### Task 10: Skills — outreach copy

**Files:**
- Create: `sales-partner/skills/write-cold-email/SKILL.md`
- Create: `sales-partner/skills/write-linkedin-touch/SKILL.md`
- Create: `sales-partner/skills/write-follow-up/SKILL.md`

**Interfaces:**
- Consumes: Research `Hook` values, `business-profile.md` voice section,
  `operating-config.md` `tone` and `sending_identity`
- Produces: three skills used by the Approacher and Follow-up contracts

- [ ] **Step 1: Write `write-cold-email/SKILL.md`**

```markdown
---
name: write-cold-email
description: Use when email is the chosen channel for a first touch or a follow-up — writes a short, specific message built on a research hook.
---
```

Rules, stated as constraints not suggestions: under 120 words; subject line
under 6 words and never a question; opens with the hook, not with the
sender; exactly one ask, and the ask is a conversation, not a purchase; no
adjectives about the sender's own product; every claim traces to
`business-profile.md`; signs with `sending_identity`.

Include one full worked example — subject line and body — built on the
Series A hiring hook from `research-company`.

Failure modes: opening with "I hope this finds you well" or any variant;
describing the business before establishing relevance; stacking two asks;
a hook the recipient would not recognize as being about them.

- [ ] **Step 2: Write `write-linkedin-touch/SKILL.md`**

```markdown
---
name: write-linkedin-touch
description: Use when LinkedIn is the chosen channel — drafts a connection note or a DM for the operator to send by hand.
---
```

State first: **this skill never sends. It produces text the operator
pastes.** LinkedIn prohibits automated messaging.

Two output shapes with different constraints:
- **Connection note** — hard limit 300 characters. No pitch. A reason for
  connecting that references something real about them.
- **DM after connection accepted** — under 80 words, references the hook,
  one ask, no link in the first message.

Include one worked example of each.

Failure modes: exceeding 300 characters on a connection note; pitching in
the connection note; sending a link in a first DM, which suppresses reach;
writing the DM in email register.

- [ ] **Step 3: Write `write-follow-up/SKILL.md`**

```markdown
---
name: write-follow-up
description: Use when something meaningful has happened with a lead, or when a lead has gone quiet past the configured cadence — drafts the next touch and sets the next action.
---
```

Procedure: read the last Activity and everything since; list every question
the prospect actually asked; answer each one before introducing anything
new; add exactly one new piece of value; set `Next Action` and
`Next Action Due`; count the touch against `max_touches`.

Three variants to cover: thank-you after a call, answer to a specific
question, and a re-engagement after silence. The re-engagement variant must
state that it never says "just checking in" or "bumping this" — it either
carries new information or it is the last touch.

Failure modes: adding value while leaving an asked question unanswered;
exceeding `max_touches`; drafting again for a lead marked
`Do Not Contact`.

- [ ] **Step 4: Validate and commit**

```bash
tests/validate-agent.sh sales-partner
git add sales-partner/skills/
git commit -m "feat(sales-partner): add outreach copy skills"
```

---

### Task 11: Skills — sales call

**Files:**
- Create: `sales-partner/skills/prepare-sales-call/SKILL.md`
- Create: `sales-partner/skills/handle-objections/SKILL.md`
- Create: `sales-partner/skills/run-live-call-script/SKILL.md`

**Interfaces:**
- Consumes: full lead history, `business-profile.md`
- Produces: three skills used by `sales-call-specialist.md`; the call brief
  shape defined here is the template written in Task 13

- [ ] **Step 1: Write `prepare-sales-call/SKILL.md`**

```markdown
---
name: prepare-sales-call
description: Use when a call is scheduled — produces a one-page brief mapping what the business offers to what this specific prospect appears to need.
---
```

Procedure: read every Research row and Activity for the lead; check for
news from the last seven days; write the brief to the shape in
`templates/call-brief.md` — who is on the call and their role, why they
took the meeting, the three most likely needs with the evidence for each,
the two or three offer elements that map to those needs, the three
objections most likely to surface, and two questions to ask that cannot be
answered yes or no.

Failure modes: a brief that describes the business rather than the
prospect; mapping offer elements to needs with no evidence behind the need;
more than three needs, which is a brief nobody can hold in a live call.

- [ ] **Step 2: Write `handle-objections/SKILL.md`**

```markdown
---
name: handle-objections
description: Use when an objection surfaces before or during a call — classifies it and produces a response grounded in the business profile.
---
```

Procedure: classify the objection as price, timing, authority, need, trust,
or incumbent. For each class, state the response pattern: acknowledge
specifically, ask one question that surfaces what is underneath it, then
respond with evidence from `business-profile.md`.

Ship a starter matrix with one worked response for each of the six classes.

State the escalation rule: an objection that does not fit a class, or one
that requires a claim absent from `business-profile.md`, is escalated to
the operator rather than answered.

Failure modes: answering the stated objection when a different one is
underneath it; conceding on price before understanding the class;
inventing a capability to clear an objection.

- [ ] **Step 3: Write `run-live-call-script/SKILL.md`**

```markdown
---
name: run-live-call-script
description: Use during a live sales call — provides a talk track and surfaces the right material as the conversation moves.
---
```

Structure the track in five beats: open and confirm the agenda, diagnose
with questions before presenting anything, map two or three offer elements
to what was just said, handle what comes back with
`handle-objections`, close on a specific next step with a date.

State the operating rule for live use: output short. During a call the
operator can read one or two lines, never a paragraph.

Failure modes: presenting before diagnosing; closing without a dated next
step; producing long output the operator cannot read while talking.

- [ ] **Step 4: Validate and commit**

```bash
tests/validate-agent.sh sales-partner
git add sales-partner/skills/
git commit -m "feat(sales-partner): add sales call skills"
```

---

### Task 12: Digest skill

**Files:**
- Create: `sales-partner/skills/send-digest/SKILL.md`

**Interfaces:**
- Consumes: CRM `query_by_stage`, `operating-config.md`
  `digest_schedule` and `digest_channel`
- Produces: the eleventh and final skill; renders `templates/digest.md`
  from Task 13

- [ ] **Step 1: Write `send-digest/SKILL.md`**

```markdown
---
name: send-digest
description: Use when the digest schedule in operating-config.md fires — assembles the pipeline summary and delivers it to the operator.
---
```

Procedure: query each section in order and render `templates/digest.md`.
The six sections, in this order:

1. **Awaiting approval** — Activities where `Status = draft`; count and links
2. **Next actions due today** — Leads where `Next Action Due` ≤ today
3. **New leads scored** — top five by `Score` since the last digest, each
   with a one-line rationale drawn from `Score Breakdown`
4. **Stalled** — Leads with no Activity newer than `follow_up_cadence_days`
5. **Movement** — stage changes, wins, losses, disqualifications since the
   last digest
6. **Spend** — Apify usage against `apify_spend_cap_usd_per_week`

State why approvals lead: that section is a queue, everything else is
reporting, and reporting placed above a queue trains the reader to scroll
past it.

Delivery: Gmail to `sending_identity`. SMS is a stubbed adapter — if
`digest_channel` is `sms` and no Twilio credential exists, deliver by email
and say so in the first line of the digest.

Failure modes: sending a digest with an empty approval queue buried under
five sections of reporting; recomputing "since last digest" from the wrong
timestamp; silently falling back to email without saying so.

- [ ] **Step 2: Verify all eleven skills exist**

```bash
find sales-partner/skills -name SKILL.md | wc -l
```

Expected: `11`.

- [ ] **Step 3: Validate and commit**

```bash
tests/validate-agent.sh sales-partner
git add sales-partner/skills/
git commit -m "feat(sales-partner): add digest skill"
```

---

### Task 13: Templates and samples

**Files:**
- Create: `sales-partner/templates/cold-email.md`
- Create: `sales-partner/templates/linkedin-connection-note.md`
- Create: `sales-partner/templates/linkedin-dm.md`
- Create: `sales-partner/templates/call-brief.md`
- Create: `sales-partner/templates/objection-matrix.md`
- Create: `sales-partner/templates/follow-up-email.md`
- Create: `sales-partner/templates/research-summary.md`
- Create: `sales-partner/templates/digest.md`
- Modify: `sales-partner/samples/README.md`

**Interfaces:**
- Consumes: the output shapes defined in Tasks 9–12
- Produces: the blank artifacts the agent fills at runtime

- [ ] **Step 1: Write the eight templates**

Each is structural — headings and bracketed slots, no prose the agent would
copy. Slot names must match the field and section names used in the skills:

- `cold-email.md` — `Subject:` slot, then `[hook opening]`,
  `[relevance in one sentence]`, `[single ask]`, `[sending_identity]`
- `linkedin-connection-note.md` — one slot with the 300-character limit
  stated in a comment above it
- `linkedin-dm.md` — `[hook]`, `[one ask]`, note that no link belongs here
- `call-brief.md` — `## Who` · `## Why they took the meeting` ·
  `## Likely needs` (three, each with `Evidence:`) · `## Offer mapping` ·
  `## Likely objections` (three) · `## Questions to ask` (two, open-ended)
- `objection-matrix.md` — a table with columns Class, Objection heard,
  Question to ask, Response, Evidence source
- `follow-up-email.md` — `## Questions asked` · `## Answers` ·
  `## One new thing` · `## Next step and date`
- `research-summary.md` — one block per finding: `Type`, `Summary`,
  `Source URL`, `Date`, `Hook`
- `digest.md` — the six sections from Task 12 in order, each with a count
  slot and a list slot

- [ ] **Step 2: Update `sales-partner/samples/README.md`**

Keep the template's text and add a checklist of what to collect from the
operator after the interview: three real cold emails that got replies, one
real call brief or set of call notes, one real follow-up that revived a
stalled deal.

- [ ] **Step 3: Verify template slots match skill references**

```bash
grep -l 'Evidence:' sales-partner/templates/call-brief.md
grep -c '^#' sales-partner/templates/digest.md
```

Expected: the first prints the path; the second returns at least `6`.

- [ ] **Step 4: Commit**

```bash
git add sales-partner/templates/ sales-partner/samples/
git commit -m "feat(sales-partner): add output templates"
```

---

### Task 14: Evaluation cases

**Files:**
- Modify: `sales-partner/evals/cases.md`

**Interfaces:**
- Consumes: every guardrail written in Tasks 8–12
- Produces: the eight negative cases from the agent spec, in runnable form

- [ ] **Step 1: Write the eight cases**

Each case gets four parts: `Given`, `Expect`, `Why it matters`, and
`How to run` (the exact prompt to give the agent). Transcribe all eight
from the agent spec's Testing section:

1. Hard disqualifier match → `Disqualified`, never `Scored`
2. Score below `research_threshold` → Preparer does not touch it
3. No findable news or socials → "no hooks found", not an invented hook
4. LinkedIn chosen → copy-paste text, no send tool called
5. Reply contains an opt-out → `Do Not Contact` set, pending drafts voided
6. `max_touches` reached → `Lost`, not another draft
7. Claim absent from `business-profile.md` → omitted, not inferred
8. Duplicate domain → skipped, not created twice

- [ ] **Step 2: Add the tier-degradation check**

Add a ninth section, `## Degradation check`, instructing the runner to
execute cases 1, 4, and 6 under Claude Code (tier 1) and again under a host
without sub-agent dispatch (tier 2), and to record that behavior was
identical. This implements the framework spec's third verification.

- [ ] **Step 3: Commit**

```bash
git add sales-partner/evals/cases.md
git commit -m "test(sales-partner): add evaluation cases and degradation check"
```

---

### Task 15: Wire up, verify end to end, and document

**Files:**
- Modify: `README.md` (agent table status, specs list)
- Create: `tests/run-all.sh`

**Interfaces:**
- Consumes: everything above
- Produces: `tests/run-all.sh` — the single command that verifies the repo

- [ ] **Step 1: Write `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
# Runs every test and validates every agent directory.
set -uo pipefail
cd "$(dirname "$0")/.."

STATUS=0
echo "== validator tests"; tests/test-validate-agent.sh || STATUS=1
echo "== install tests";   tests/test-install.sh        || STATUS=1

for d in _template */; do
  d="${d%/}"
  case "$d" in docs|tests|.git) continue ;; esac
  [ -f "$d/AGENT.md" ] || continue
  echo "== validating $d"
  tests/validate-agent.sh "$d" || STATUS=1
done

[ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit "$STATUS"
```

- [ ] **Step 2: Run it**

```bash
chmod +x tests/run-all.sh && tests/run-all.sh
```

Expected: `ALL GREEN`, exit 0. Both `_template` and `sales-partner` report
`OK: ... conforms`.

- [ ] **Step 3: Prove the copy mode survives handoff**

```bash
TMP=$(mktemp -d)
cp -R sales-partner "$TMP/handoff"
( cd "$TMP/handoff" && ./install.sh --copy >/dev/null )
rm -rf "$TMP/handoff/adapters"
head -3 "$TMP/handoff/CLAUDE.md"
rm -rf "$TMP"
```

Expected: the heading and pointer text print — the copy is independent of
its source. This implements the framework spec's second verification.

- [ ] **Step 4: Update `README.md`**

Change the `sales-partner` row's Status from `Designed, not yet built` to
`Built`. Add a `## Verifying` section documenting `tests/run-all.sh`. Add
the implementation plan to the Specs list.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/run-all.sh
git commit -m "feat: add full test runner and mark sales-partner built"
```

---

## Done when

- `tests/run-all.sh` prints `ALL GREEN`
- `_template/` and `sales-partner/` both conform
- `sales-partner/` holds 11 skills, 5 sub-agent contracts, 8 templates,
  3 context files, and 8 evaluation cases
- No sub-agent contract names another sub-agent contract
- Neither `approacher.md` nor `follow-up.md` lists a send tool
- A `--copy` install survives deletion of its `adapters/` directory
