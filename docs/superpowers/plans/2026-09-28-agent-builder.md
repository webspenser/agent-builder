# Agent Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `webspenser/agent-builder` into an installable builder plugin that ships Agent Standard 1.0, a validator that enforces it, a `new-agent` wizard, a `validate-agent` skill, and a GitHub Action.

**Architecture:** The repo root becomes the plugin (Claude, Gemini, Codex manifests side by side). The validator stays a bash script, moved to `bin/`, and delegates the new JSON/YAML checks to one Python standard-library helper. Skills are markdown procedures; the Action is a thin composite wrapper over a testable shell script.

**Tech Stack:** bash, Python 3 standard library, git, markdown; Claude Code / Gemini CLI / Codex plugin manifests; GitHub Actions (composite).

**Spec:** `docs/superpowers/specs/2026-09-28-agent-builder-design.md` (umbrella: `docs/superpowers/specs/2026-09-27-agent-distribution-architecture-design.md`)

## Global Constraints

- Repo is `webspenser/agent-builder`; plugin name `agent-builder`; skills surface as `/agent-builder:new-agent` and `/agent-builder:validate-agent`; builder version `1.0.0`.
- `CONVENTIONS.md` becomes `STANDARD.md`, titled "Agent Standard 1.0". No shims, no compatibility with old paths — there are no users.
- `tests/validate-agent.sh` is removed; the validator is `bin/validate-agent.sh <agent-dir> [--require-bump <git-ref>]`.
- Output contract: `OK: <dir> conforms` + exit 0, or one `FAIL:` line per problem, a count line, exit 1. Pre-1.0 agents (no `agent.yaml`) print `WARN: <dir> has no agent.yaml — checked as pre-1.0` and exit on the pre-1.0 result.
- `agent.yaml` keys (1.0): `name` (kebab-case), `version` (`MAJOR.MINOR.PATCH`), `description`, `standard` (`1.x`). Unknown keys ignored. Folder name is never checked.
- Host manifests: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`; name/version/description equal `agent.yaml`; Claude `agents` lists every `subagents/*.md` as `./subagents/<role>.md`, files only; marketplace = exactly one entry, the agent's name, `"source": "./"`, plus `owner.name`; Gemini `contextFileName: "AGENT.md"`; Codex `skills: "./skills/"`.
- Parsing uses only the Python 3 standard library; no package installs.
- Skill frontmatter keys are `name` and `description` only; descriptions start with "Use when".
- `sales-partner/` stays in the repo, unmodified, validated as pre-1.0.
- Commits end with: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **`agent.yaml` written the way people write YAML** — quoted values, trailing `# comments`, blank lines, indented future keys — must parse, not fail. Pinned in Task 2.
2. **A manifest that exists but is broken JSON** must produce one readable `FAIL:` line, never a Python traceback. Pinned in Task 2.
3. **`--require-bump` on a brand-new agent** (no `agent.yaml` at the ref) must pass; an unknown ref must fail with a clear message. Pinned in Task 3.
4. **Agent paths with spaces, and running from another directory,** must work. Pinned in Task 2.
5. **No Python on the machine** must fail with a clear "python3 is required" message, not a shell error. Pinned in Task 2 via `AGENT_VALIDATOR_PYTHON`.

---

## File map

| File | Change | Task |
|---|---|---|
| `bin/validate-agent.sh` | moved from `tests/validate-agent.sh`; 1.0 checks; `--require-bump` | 1, 2, 3 |
| `bin/lib/check_manifests.py` | new — 1.0 manifest checks | 2 |
| `STANDARD.md` | renamed from `CONVENTIONS.md`; 1.0 sections | 1, 2, 3 |
| `tests/test-validate-agent.sh`, `tests/run-all.sh` | paths; new fixtures; new suites | 1–6 |
| `_template/agent.yaml`, `_template/.claude-plugin/*.json`, `_template/gemini-extension.json`, `_template/.codex-plugin/plugin.json` | new | 4 |
| `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`, `LICENSE` | new (builder) | 5 |
| `skills/new-agent/SKILL.md`, `skills/validate-agent/SKILL.md` | new | 5 |
| `tests/test-builder-manifests.sh` | new | 5 |
| `validate/action.yml`, `validate/run.sh`, `tests/test-action.sh` | new | 6 |
| `README.md`, `docs/writing-an-agent.md` | rewrite / new | 6 |

---

### Task 1: Move the validator and rename the standard

**Files:**
- Move: `tests/validate-agent.sh` → `bin/validate-agent.sh`
- Move: `CONVENTIONS.md` → `STANDARD.md`
- Modify: `tests/test-validate-agent.sh`, `tests/run-all.sh`

**Interfaces:**
- Produces: `bin/validate-agent.sh <agent-dir>` with today's behavior; `STANDARD.md`.

- [ ] **Step 1: Point the tests at the new path first (failing)**

In `tests/test-validate-agent.sh` replace every `tests/validate-agent.sh` with `bin/validate-agent.sh`. In `tests/run-all.sh` replace `tests/validate-agent.sh "$d"` with `bin/validate-agent.sh "$d"`, and extend the skip list so tool folders are never treated as agents:

```bash
  case "$d" in docs|tests|bin|skills|validate|.git) continue ;; esac
```

- [ ] **Step 2: Run, expect failure**

Run: `tests/run-all.sh`
Expected: failures — `bin/validate-agent.sh: No such file or directory`.

- [ ] **Step 3: Move the files with git**

```bash
mkdir -p bin
git mv tests/validate-agent.sh bin/validate-agent.sh
git mv CONVENTIONS.md STANDARD.md
```

In `bin/validate-agent.sh` change the header comment to:

```bash
# Checks that a directory conforms to the Agent Standard (STANDARD.md).
# Usage: bin/validate-agent.sh <agent-dir> [--require-bump <git-ref>]
```

In `STANDARD.md`: change the title to `# Agent Standard 1.0`; replace every `tests/validate-agent.sh` with `bin/validate-agent.sh`; replace `CONVENTIONS.md` with `STANDARD.md` in the Directory layout block and prose; in the layout block rename the root folder `agent-library/` to `agent-builder/` and replace the line `CONVENTIONS.md            # the portable-agent standard, one page` with `STANDARD.md               # the Agent Standard`.

- [ ] **Step 4: Run, expect pass**

Run: `tests/run-all.sh`
Expected: last line `ALL GREEN`.

- [ ] **Step 5: Check no stale references remain outside history docs**

Run: `grep -rn "tests/validate-agent\|CONVENTIONS.md" --exclude-dir=.git --exclude-dir=docs --exclude-dir=.superpowers --exclude-dir=.claude . || echo clean`
Expected: only `README.md` lines (Task 6 rewrites it) or `clean`.

- [ ] **Step 6: Commit**

```bash
git add -A bin tests STANDARD.md CONVENTIONS.md
git commit -m "refactor: move validator to bin/, rename CONVENTIONS.md to STANDARD.md"
```

---

### Task 2: Agent Standard 1.0 manifest checks

**Files:**
- Create: `bin/lib/check_manifests.py`
- Modify: `bin/validate-agent.sh`, `STANDARD.md`, `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `bin/validate-agent.sh` (Task 1).
- Produces: `bin/lib/check_manifests.py <agent-dir>` → prints one `FAIL: <message>` line per problem, exit 0 always; env `AGENT_VALIDATOR_PYTHON` (default `python3`) selects the interpreter. Test helper `make_valid_v1_agent <dir> [name] [version]` in `tests/test-validate-agent.sh`.

- [ ] **Step 1: Add a 1.0 fixture builder and failing tests**

In `tests/test-validate-agent.sh`, after the existing `make_valid_agent` function, add:

```bash
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
```

Before the final `finish`, add:

```bash
echo "-- Agent Standard 1.0"
V=bin/validate-agent.sh

# A pre-1.0 agent (no agent.yaml) passes with a WARN line.
make_valid_agent "$FIX/pre10"
assert_pass $V "$FIX/pre10"
if $V "$FIX/pre10" 2>&1 | grep -q '^WARN: .* has no agent.yaml'; then _report ok "pre-1.0 WARN"; else _report no "pre-1.0 WARN missing"; fi

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
if $V "$FIX/v1-badjson" 2>&1 | grep -q 'Traceback'; then _report no "bad JSON produced a traceback"
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
if AGENT_VALIDATOR_PYTHON=/nonexistent/python3 $V "$FIX/v1-nopy" 2>&1 | grep -q '^FAIL: python3 is required'; then
  _report ok "missing python reported clearly"; else _report no "missing python not reported clearly"; fi
```

- [ ] **Step 2: Run, expect failures**

Run: `tests/test-validate-agent.sh`
Expected: FAIL lines for the pre-1.0 WARN check, every `assert_fail` in the 1.0 block (the current validator ignores manifests), and the missing-python check.

- [ ] **Step 3: Create `bin/lib/check_manifests.py`**

```python
#!/usr/bin/env python3
"""Agent Standard 1.0 manifest checks.

Usage: check_manifests.py <agent-dir>
Prints one 'FAIL: <message>' line per problem and always exits 0;
bin/validate-agent.sh counts the lines.
"""
import json
import pathlib
import re
import sys

REQUIRED_KEYS = ("name", "version", "description", "standard")
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SUPPORTED_STANDARD = re.compile(r"^1\.\d+$")
IDENTITY_MANIFESTS = (".claude-plugin/plugin.json", "gemini-extension.json", ".codex-plugin/plugin.json")
ALL_MANIFESTS = IDENTITY_MANIFESTS + (".claude-plugin/marketplace.json",)


def read_agent_yaml(path):
    """Top-level `key: value` pairs; quotes and trailing comments stripped."""
    data = {}
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#") or raw[0] in " \t" or ":" not in raw:
            continue
        key, value = raw.split(":", 1)
        value = re.sub(r"\s+#.*$", "", value).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        data[key.strip()] = value
    return data


def main(agent_dir):
    root = pathlib.Path(agent_dir)
    fails = []
    meta = read_agent_yaml(root / "agent.yaml")
    for key in REQUIRED_KEYS:
        if not meta.get(key):
            fails.append(f"agent.yaml: missing {key}")
    name, version, desc, std = (meta.get(k, "") for k in REQUIRED_KEYS)
    if name and not KEBAB.match(name):
        fails.append(f"agent.yaml: name '{name}' is not kebab-case")
    if version and not SEMVER.match(version):
        fails.append(f"agent.yaml: version '{version}' is not MAJOR.MINOR.PATCH")
    if std and not SUPPORTED_STANDARD.match(std):
        fails.append(f"agent.yaml: standard '{std}' is not supported (this validator understands 1.x)")

    manifests = {}
    for rel in ALL_MANIFESTS:
        path = root / rel
        if not path.is_file():
            fails.append(f"missing {rel}")
            continue
        try:
            manifests[rel] = json.loads(path.read_text())
        except json.JSONDecodeError as err:
            fails.append(f"{rel}: not valid JSON ({err.msg}, line {err.lineno})")

    for rel in IDENTITY_MANIFESTS:
        manifest = manifests.get(rel)
        if manifest is None:
            continue
        for key, want in (("name", name), ("version", version), ("description", desc)):
            if manifest.get(key) != want:
                fails.append(f"{rel}: {key} {manifest.get(key)!r} does not match agent.yaml {want!r}")

    claude = manifests.get(".claude-plugin/plugin.json")
    if claude is not None:
        agents = claude.get("agents", [])
        agents = [agents] if isinstance(agents, str) else list(agents)
        expected = {f"./subagents/{p.name}" for p in (root / "subagents").glob("*.md")}
        files = set()
        for entry in agents:
            if entry.endswith("/") or (root / entry).is_dir():
                fails.append(f".claude-plugin/plugin.json: agents entry '{entry}' is a directory — list each file")
            else:
                files.add(entry)
        for missing in sorted(expected - files):
            fails.append(f".claude-plugin/plugin.json: agents does not list {missing}")
        for extra in sorted(files - expected):
            fails.append(f".claude-plugin/plugin.json: agents lists {extra}, which is not a file in subagents/")

    market = manifests.get(".claude-plugin/marketplace.json")
    if market is not None:
        if market.get("name") != name:
            fails.append(f".claude-plugin/marketplace.json: name {market.get('name')!r} does not match agent.yaml {name!r}")
        if not (market.get("owner") or {}).get("name"):
            fails.append(".claude-plugin/marketplace.json: missing owner.name")
        plugins = market.get("plugins") or []
        if len(plugins) != 1 or plugins[0].get("name") != name or plugins[0].get("source") != "./":
            fails.append(f".claude-plugin/marketplace.json: must hold exactly one plugin entry named {name!r} with source \"./\"")

    gemini = manifests.get("gemini-extension.json")
    if gemini is not None and gemini.get("contextFileName") != "AGENT.md":
        fails.append("gemini-extension.json: contextFileName must be \"AGENT.md\"")

    codex = manifests.get(".codex-plugin/plugin.json")
    if codex is not None and codex.get("skills") != "./skills/":
        fails.append(".codex-plugin/plugin.json: skills must be \"./skills/\"")

    for message in fails:
        print(f"FAIL: {message}")


if __name__ == "__main__":
    main(sys.argv[1])
```

- [ ] **Step 4: Call it from `bin/validate-agent.sh`**

After `ADAPTER_MAX_LINES=25` add:

```bash
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${AGENT_VALIDATOR_PYTHON:-python3}"
```

Immediately before the final `if [ "$ERRORS" -eq 0 ]` block add:

```bash
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
```

- [ ] **Step 5: Document 1.0 in `STANDARD.md`**

Add a `## Versioning` section directly under the title's intro paragraph, and `## Agent manifest` and `## Host manifests` sections directly before `## Validation`, with this text:

````markdown
## Versioning

The standard uses semantic versioning: a minor release adds optional
rules, a major release changes what an agent must do to conform. It
grows with the builder's sub-projects — 1.0 packaging (this version),
1.1 instance rules, 1.2 capability contracts and adapters. An agent
declares the version it follows in `agent.yaml`; the validator
understands `1.x` and fails any other. A folder with no `agent.yaml` is
a pre-1.0 agent: it is checked by the rules above only and passes with
a warning.

## Agent manifest

Every 1.0 agent has `agent.yaml` at its root:

```yaml
name: sales-partner            # kebab-case; the plugin / extension name
version: 1.3.0                 # MAJOR.MINOR.PATCH — the agent's own version
description: One sentence, what the agent does
standard: "1.0"                # the Agent Standard version followed
```

All four keys are required, one `key: value` per line; quotes and
trailing comments are allowed. Later versions add keys; a 1.0 validator
ignores keys it does not know. The folder name is not checked — a clone
may live under any name.

## Host manifests

Four static files let each host install the agent. None carries
behavior; each repeats the agent's identity.

| File | Required content |
|---|---|
| `.claude-plugin/plugin.json` | `name`, `version`, `description` equal to `agent.yaml`; `agents` lists every file in `subagents/` as `"./subagents/<role>.md"` — files only, no directories, none missing or extra |
| `.claude-plugin/marketplace.json` | `name` equal to the agent name; `owner.name`; exactly one plugin entry with the agent's name and `"source": "./"` |
| `gemini-extension.json` | `name`, `version`, `description` equal to `agent.yaml`; `"contextFileName": "AGENT.md"` |
| `.codex-plugin/plugin.json` | `name`, `version`, `description` equal to `agent.yaml`; `"skills": "./skills/"` |

Claude rejects a directory in `agents`, which is why each file is
listed. The one-entry marketplace lets the repo install on its own for
local testing.
````

Also add the four manifests and `agent.yaml` to the Directory layout block under `<agent-name>/`:

```
    agent.yaml              # identity + standard version (1.0)
    .claude-plugin/         # plugin.json, marketplace.json
    .codex-plugin/          # plugin.json
    gemini-extension.json
```

- [ ] **Step 6: Run, expect pass**

Run: `tests/test-validate-agent.sh && tests/run-all.sh`
Expected: `-- N passed, 0 failed`; run-all ends `ALL GREEN` (sales-partner and `_template` print the pre-1.0 WARN and still pass).

- [ ] **Step 7: Commit**

```bash
git add bin STANDARD.md tests/test-validate-agent.sh
git commit -m "feat: Agent Standard 1.0 manifest checks in the validator"
```

---

### Task 3: Release rule — `--require-bump <ref>`

**Files:**
- Modify: `bin/validate-agent.sh`, `STANDARD.md`, `tests/test-validate-agent.sh`

**Interfaces:**
- Consumes: `make_valid_v1_agent` (Task 2).
- Produces: `bin/validate-agent.sh <dir> --require-bump <git-ref>` (flag may come before or after the dir).

- [ ] **Step 1: Failing tests**

Before `finish` in `tests/test-validate-agent.sh` add:

```bash
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
if $V "$G/agent" --require-bump no-such-ref 2>&1 | grep -q "^FAIL: --require-bump: unknown git ref 'no-such-ref'"; then
  _report ok "unknown ref reported"; else _report no "unknown ref not reported"; fi
```

- [ ] **Step 2: Run, expect failures**

Run: `tests/test-validate-agent.sh`
Expected: FAIL for the "changed without a bump" cases and the unknown-ref check (the flag is currently treated as the directory argument or ignored).

- [ ] **Step 3: Argument parsing**

Replace the `DIR="${1:-}"` line in `bin/validate-agent.sh` with:

```bash
DIR=""
BUMP_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-bump) BUMP_REF="${2:-}"; shift 2 ;;
    *) DIR="$1"; shift ;;
  esac
done
```

(Keep the following `[ -n "$DIR" ] && [ -d "$DIR" ] || …` line unchanged.)

- [ ] **Step 4: The check**

Immediately before the final `if [ "$ERRORS" -eq 0 ]` block add:

```bash
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
```

- [ ] **Step 5: Document in `STANDARD.md`**

Add after `## Host manifests`:

```markdown
## Release rule

Any change to an agent's files ships with a `version` bump, applied to
`agent.yaml` and all four host manifests together — hosts update a
GitHub-sourced plugin only when its version changes. The validator
enforces this against a git ref when asked:

    bin/validate-agent.sh <agent-dir> --require-bump origin/main

An agent that did not exist at the ref needs no bump.
```

- [ ] **Step 6: Run, expect pass**

Run: `tests/test-validate-agent.sh && tests/run-all.sh`
Expected: 0 failed; `ALL GREEN`.

- [ ] **Step 7: Commit**

```bash
git add bin STANDARD.md tests/test-validate-agent.sh
git commit -m "feat: --require-bump enforces the release rule"
```

---

### Task 4: Template becomes a 1.0 agent

**Files:**
- Create: `_template/agent.yaml`, `_template/.claude-plugin/plugin.json`, `_template/.claude-plugin/marketplace.json`, `_template/gemini-extension.json`, `_template/.codex-plugin/plugin.json`
- Modify: `tests/run-all.sh` (assert no WARN for `_template`)

- [ ] **Step 1: Failing check**

In `tests/run-all.sh`, after the validation loop and before the final `ALL GREEN` line, add:

```bash
echo "== template is Agent Standard 1.0"
if bin/validate-agent.sh _template 2>&1 | grep -q '^WARN:'; then
  echo "FAIL: _template is still pre-1.0"; STATUS=1
fi
```

- [ ] **Step 2: Run, expect failure**

Run: `tests/run-all.sh`
Expected: `FAIL: _template is still pre-1.0` and `FAILURES ABOVE`.

- [ ] **Step 3: Add the template manifests**

`_template/agent.yaml`:

```yaml
name: agent-template
version: 0.0.0
description: Template — replace with one sentence describing what the agent does
standard: "1.0"
```

`_template/.claude-plugin/plugin.json`:

```json
{
  "name": "agent-template",
  "version": "0.0.0",
  "description": "Template — replace with one sentence describing what the agent does",
  "agents": []
}
```

`_template/.claude-plugin/marketplace.json`:

```json
{
  "name": "agent-template",
  "owner": { "name": "Replace with your name or organization" },
  "plugins": [
    { "name": "agent-template", "source": "./", "description": "Template — replace with one sentence describing what the agent does" }
  ]
}
```

`_template/gemini-extension.json`:

```json
{
  "name": "agent-template",
  "version": "0.0.0",
  "description": "Template — replace with one sentence describing what the agent does",
  "contextFileName": "AGENT.md"
}
```

`_template/.codex-plugin/plugin.json`:

```json
{
  "name": "agent-template",
  "version": "0.0.0",
  "description": "Template — replace with one sentence describing what the agent does",
  "skills": "./skills/"
}
```

- [ ] **Step 4: Run, expect pass**

Run: `bin/validate-agent.sh _template && tests/run-all.sh`
Expected: `OK: _template conforms` with no WARN; `ALL GREEN` (the install tests copy `_template` and must still pass).

- [ ] **Step 5: Commit**

```bash
git add _template tests/run-all.sh
git commit -m "feat: template ships agent.yaml and host manifests (Standard 1.0)"
```

---

### Task 5: The builder plugin and its skills

**Files:**
- Create: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`, `LICENSE`, `skills/new-agent/SKILL.md`, `skills/validate-agent/SKILL.md`, `tests/test-builder-manifests.sh`
- Modify: `tests/run-all.sh`

**Interfaces:**
- Consumes: `bin/validate-agent.sh` (Tasks 1–3), `_template/` (Task 4).

- [ ] **Step 1: Failing test** — create `tests/test-builder-manifests.sh` (executable):

```bash
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
```

Add to `tests/run-all.sh` after the install tests line:

```bash
echo "== builder manifests"; tests/test-builder-manifests.sh || STATUS=1
```

- [ ] **Step 2: Run, expect failures**

Run: `chmod +x tests/test-builder-manifests.sh && tests/test-builder-manifests.sh`
Expected: `missing` for every file.

- [ ] **Step 3: Builder manifests and license**

`.claude-plugin/plugin.json`:

```json
{
  "name": "agent-builder",
  "version": "1.0.0",
  "description": "Build your own AI agent on the Webspenser Agent Standard — a guided wizard, a template, and a validator.",
  "author": { "name": "Webspenser" },
  "repository": "https://github.com/webspenser/agent-builder",
  "license": "Apache-2.0"
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "agent-builder",
  "owner": { "name": "Webspenser" },
  "plugins": [
    { "name": "agent-builder", "source": "./", "description": "Build your own AI agent on the Webspenser Agent Standard — a guided wizard, a template, and a validator." }
  ]
}
```

`gemini-extension.json`:

```json
{
  "name": "agent-builder",
  "version": "1.0.0",
  "description": "Build your own AI agent on the Webspenser Agent Standard — a guided wizard, a template, and a validator.",
  "contextFileName": "STANDARD.md"
}
```

`.codex-plugin/plugin.json`:

```json
{
  "name": "agent-builder",
  "version": "1.0.0",
  "description": "Build your own AI agent on the Webspenser Agent Standard — a guided wizard, a template, and a validator.",
  "skills": "./skills/",
  "license": "Apache-2.0"
}
```

License: `gh api licenses/apache-2.0 --jq .body > LICENSE`

- [ ] **Step 4: `skills/validate-agent/SKILL.md`**

```markdown
---
name: validate-agent
description: Use when checking whether an agent folder conforms to the Agent Standard, before a commit or a release, or when a validator FAIL line needs explaining.
---

Checks one agent folder against the Agent Standard (`STANDARD.md` in
this plugin) and explains every problem in plain language.

## Procedure

1. Pick the folder: the one the user names, otherwise the current
   folder. If it has no `AGENT.md`, say it is not an agent folder and
   stop.
2. Locate the validator: `bin/validate-agent.sh` in this plugin's root
   (`${CLAUDE_PLUGIN_ROOT}/bin/validate-agent.sh` on Claude Code; on
   other hosts, the `bin/` folder beside this `skills/` folder).
3. Run it: `bash <validator> <folder>`. If the user is preparing a
   release, add `--require-bump <ref>` with the ref they compare
   against (usually `origin/main`).
4. Report the result:
   - `OK: … conforms` — say so in one line; mention a `WARN:` line if
     present (a pre-1.0 agent: suggest adding `agent.yaml` and the four
     host manifests from `_template/`).
   - Each `FAIL:` line — restate it plainly, name the file, and give
     the exact fix (the key to add, the value to change, the heading to
     move). Group fixes by file.
5. Offer to apply the fixes. Apply only after the user agrees, then run
   the validator again and report the new result.

If no shell is available, perform the same checks by reading the files
against `STANDARD.md` and report in the same `OK` / `FAIL:` form.

## Failure modes

- **Fixing silently.** Never change files before the user agrees.
- **Declaring success without the validator.** When a shell exists,
  only the validator's `OK` line counts as conforming.
```

- [ ] **Step 5: `skills/new-agent/SKILL.md`**

```markdown
---
name: new-agent
description: Use when someone wants to create a new agent — interviews them and builds a complete agent folder on the Agent Standard, then validates it.
---

A conversation that turns "I want an agent that…" into a working agent
folder following `STANDARD.md` (in this plugin). Ask one question at a
time. Write each answer to its file before asking the next question, so
an interrupted run resumes by reading what already exists. Never invent
the user's domain facts — anything they haven't supplied stays as a
bracketed prompt.

The template lives at `_template/` in this plugin's root
(`${CLAUDE_PLUGIN_ROOT}/_template` on Claude Code; on other hosts, the
`_template/` folder beside this `skills/` folder). The validator is
`bin/validate-agent.sh` in the same root.

## Procedure

1. **Purpose.** Ask what job the agent does, for whom, and what a good
   week with it looks like. If the answer is "everything", ask for the
   one job it should do first. Summarize back in two sentences and get
   a yes.
2. **Name and place.** Propose a kebab-case name; ask where to create
   it (default `./<name>`). If the folder exists and has no
   `agent.yaml`, stop and ask. If it has an `agent.yaml` naming this
   agent, it is an interrupted run: read what exists and resume at the
   first unfinished step.
3. **Mode.** Ask: *personal* (only you use it; we fill your details in
   after building) or *distributable* (others install it; your details
   never go in it).
4. **Scaffold.** Copy the template folder to the target. Set
   `agent.yaml`: `name`, `version: 0.1.0`, one-sentence `description`,
   `standard: "1.0"`. Set the same name, version, and description in
   `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
   (its `name` and its single entry), `gemini-extension.json`, and
   `.codex-plugin/plugin.json`; set the marketplace `owner.name` to the
   user's name or organization. Set the title in `AGENT.md` and the
   three `adapters/` files to the agent's display name.
5. **Specification, section by section.** For each, ask, draft,
   confirm, write:
   - Identity and Mission — a role a person could hold; one outcome.
   - Inputs and Outputs — what must exist first; what it produces,
     with the shape of each artifact.
   - Context files — the facts about the user's world the agent needs
     (for a training coach: goals, schedule, current fitness). Write
     each as `context/<name>.md` with bracketed interview prompts, not
     answers.
   - Operating rules — numbered, about how it works.
   - Workflow — ordered steps, each tagged T1, T2, or T3; no critical
     step may need T1.
   - Skills — for each repeated procedure: `skills/<name>/SKILL.md`
     with frontmatter `name` and a `description` starting "Use when",
     then a numbered procedure, one worked example, and failure modes.
   - Sub-agents — only where a step benefits from its own isolated
     context; each contract in `subagents/<role>.md` with the eight
     required headings (Purpose, Trigger, Inputs, Outputs, Tools
     allowed, Stop conditions, Handoff, Inline fallback) and
     frontmatter `name` and `description`.
   - Guardrails / never do, and Escalate to human when.
   Fill the Sub-agents and Skills tables in `AGENT.md` to match.
6. **Evals.** Write at least three cases in `evals/cases.md`, each a
   thing the agent must refuse or never do, in the form Given / Expect
   / Why it matters / How to run.
7. **Manifests.** Set `agents` in `.claude-plugin/plugin.json` to list
   every file in `subagents/` as `"./subagents/<role>.md"` (an empty
   list if none).
8. **Validate.** Run `bash <validator> <folder>`. Fix every `FAIL:`
   line and run it again until it prints `OK`.
9. **Finish.**
   - Personal: offer to fill the `context/` files now by interviewing
     the user with each file's bracketed prompts, writing their
     answers in place.
   - Distributable: offer `git init` and a first commit; explain
     publishing — push to a GitHub repo, enable "Template repository"
     in its settings so others can copy it without forking, and list it
     in a catalog. Every later change bumps `version` in `agent.yaml`
     and all four host manifests.

## Worked example (abridged)

User: "I'm training for an Ironman and want something to keep my
training log and tell me what to adjust each week."
- Purpose confirmed: "A training coach that keeps your Ironman log and
  proposes next week's plan every Sunday."
- Name `ironman-coach`, folder `./ironman-coach`, mode personal.
- Context files: `context/athlete-profile.md` (race date, current
  volume, injuries — as prompts), `context/training-log.md`.
- Skills: `log-session`, `weekly-review`. No sub-agents.
- Evals: never prescribes training through a reported injury without
  flagging it; never invents a session that isn't in the log; never
  changes the race date.
- Validator prints `OK: ./ironman-coach conforms`; the user fills
  `athlete-profile.md` by interview.

## Failure modes

- **Writing the user's facts for them.** Race dates, prices, client
  names — only what the user said; everything else stays a prompt.
- **Skipping validation.** The agent is not done until the validator
  prints `OK`.
- **Sub-agents by default.** Add one only when a step needs isolation;
  most personal agents need none.
```

- [ ] **Step 6: Run, expect pass**

Run: `tests/test-builder-manifests.sh && tests/run-all.sh`
Expected: 0 failed; `ALL GREEN`.

- [ ] **Step 7: Commit**

```bash
git add .claude-plugin .codex-plugin gemini-extension.json LICENSE skills tests
git commit -m "feat: agent-builder plugin with new-agent and validate-agent skills"
```

---

### Task 6: GitHub Action and documentation

**Files:**
- Create: `validate/action.yml`, `validate/run.sh`, `tests/test-action.sh`, `docs/writing-an-agent.md`
- Modify: `README.md`, `tests/run-all.sh`

- [ ] **Step 1: Failing test** — `tests/test-action.sh` (executable):

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_pass validate/run.sh _template
assert_pass validate/run.sh _template ""
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/not-an-agent"
assert_fail validate/run.sh "$W/not-an-agent"
assert_contains validate/action.yml 'using: composite'
assert_contains validate/action.yml 'require-bump-against'
assert_contains validate/action.yml '$GITHUB_ACTION_PATH/run.sh'

finish
```

Add to `tests/run-all.sh` after the builder manifests line:

```bash
echo "== action";  tests/test-action.sh || STATUS=1
```

- [ ] **Step 2: Run, expect failure**

Run: `chmod +x tests/test-action.sh && tests/test-action.sh`
Expected: failures — `validate/run.sh` missing.

- [ ] **Step 3: `validate/run.sh`** (executable)

```bash
#!/usr/bin/env bash
# Runs the Agent Standard validator; used by the GitHub Action and locally.
# Usage: validate/run.sh <agent-path> [<require-bump-ref>]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
path="${1:-.}"
ref="${2:-}"
if [ -n "$ref" ]; then
  exec "$here/../bin/validate-agent.sh" "$path" --require-bump "$ref"
fi
exec "$here/../bin/validate-agent.sh" "$path"
```

- [ ] **Step 4: `validate/action.yml`**

```yaml
name: Validate agent (Agent Standard)
description: Checks an agent folder against the Webspenser Agent Standard.
inputs:
  path:
    description: Agent folder to validate
    default: "."
  require-bump-against:
    description: Git ref (e.g. origin/main); fail if the agent changed since it without a version bump. Needs a checkout with history (fetch-depth 0).
    default: ""
runs:
  using: composite
  steps:
    - shell: bash
      run: '"$GITHUB_ACTION_PATH/run.sh" "${{ inputs.path }}" "${{ inputs.require-bump-against }}"'
```

- [ ] **Step 5: Rewrite `README.md`**

```markdown
# Agent Builder

Build your own AI agent on the **Webspenser Agent Standard** — a guided
wizard, a template, and a validator, packaged as a plugin.

An agent here is a folder of plain markdown: one `AGENT.md` that
defines who it is and how it works, skills for its repeated
procedures, optional sub-agent roles, the context it needs about your
world, and evals that say what it must never do. The same folder runs
on Claude Code, Gemini CLI, and Codex.

## Install

**Claude Code** (supported)

    /plugin marketplace add webspenser/agent-builder
    /plugin install agent-builder@agent-builder

**Gemini CLI** and **Codex** — manifests ship, not yet verified:

    gemini extensions install https://github.com/webspenser/agent-builder

## Build an agent

Open your host in the folder where the agent should live and run:

    /agent-builder:new-agent

It interviews you one question at a time — purpose, name, personal or
distributable, then the agent section by section — writes the files as
it goes, and finishes when the validator passes. Personal agents are
for you alone; distributable agents are ones others install.

## Validate

    /agent-builder:validate-agent            # inside the host
    bin/validate-agent.sh path/to/agent      # from a clone of this repo

In CI, from any agent repo:

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- uses: webspenser/agent-builder/validate@v1
  with:
    path: .
    require-bump-against: origin/main   # optional: enforce version bumps
```

## What's here

| Path | What it is |
|---|---|
| `STANDARD.md` | The Agent Standard 1.0 |
| `_template/` | The skeleton every agent starts from |
| `skills/` | `new-agent` (the wizard) and `validate-agent` |
| `bin/validate-agent.sh` | The validator |
| `validate/` | The GitHub Action |
| `docs/writing-an-agent.md` | How to write a good agent by hand |
| `sales-partner/` | The first agent; moving to its own repo |

## Developing the builder

    tests/run-all.sh     # must end ALL GREEN before any commit

## License

Apache-2.0.
```

- [ ] **Step 6: `docs/writing-an-agent.md`**

```markdown
# Writing an agent

What the `new-agent` wizard does, for anyone building by hand. The
rules are in `STANDARD.md`; this is the craft.

1. **One job.** An agent that "helps with everything" helps with
   nothing measurable. Name the one outcome in Mission.
2. **Identity as a role.** Write it as a job a person could hold —
   "a sales partner for one business" — not a description of software.
3. **Context is the user's world, not yours.** Every fact about the
   user lives in `context/`, written by an interview. Ship those files
   as bracketed prompts. Nothing in `AGENT.md` or a skill should be
   specific to one user.
4. **Rules about how, not what.** Operating rules describe how the
   agent works (read state before acting; cite a source for every
   claim). Facts belong in context.
5. **Skills for repeated procedures.** If the agent does it more than
   once, it's a skill: a trigger ("Use when…"), numbered steps, one
   worked example, and the ways it goes wrong.
6. **Sub-agents only for isolation.** A step earns a sub-agent when its
   work should not see the rest of the conversation. Every contract
   also runs inline on hosts without dispatch — write it that way.
7. **Guardrails as mechanisms.** A rule the agent can break is a
   request. Where a guarantee matters (never send, never delete), make
   the tool unable to do it rather than asking the model not to.
8. **Evals are refusals.** "Writes good emails" can't be checked.
   "Never drafts to an opted-out contact" can. Write at least three.
9. **Validate before you commit.** `bin/validate-agent.sh <folder>`
   must print `OK`.
10. **Version every release.** Bump `version` in `agent.yaml` and all
    four host manifests together.
```

- [ ] **Step 7: Run, expect pass**

Run: `tests/test-action.sh && tests/run-all.sh`
Expected: 0 failed; `ALL GREEN`.

- [ ] **Step 8: Commit**

```bash
git add validate tests README.md docs/writing-an-agent.md
git commit -m "feat: validate GitHub Action; builder README and writing guide"
```

---

### Task 7: Acceptance — install the builder locally

**Files:** none changed (throwaway install; uninstall at the end).

- [ ] **Step 1: Install from the working copy**

```bash
claude plugin marketplace add "$PWD"
claude plugin install agent-builder@agent-builder
claude plugin details agent-builder@agent-builder
```

Expected: install succeeds; details lists skills `new-agent` and `validate-agent`.

- [ ] **Step 2: The validate skill works from an unrelated folder**

```bash
W=$(mktemp -d) && cp -R _template "$W/demo" && cd "$W/demo" && \
  claude -p "/agent-builder:validate-agent" --model haiku --allowedTools "Bash Read" ; cd -
```

Expected: the reply reports `OK: … conforms`.

- [ ] **Step 3: Record and uninstall**

Record both outputs in the task report, then:

```bash
claude plugin uninstall agent-builder@agent-builder
claude plugin marketplace remove agent-builder
```

- [ ] **Step 4: Tag nothing yet**

The `v1` tag for the Action is created after merge, from `main` (release step, not this plan).
