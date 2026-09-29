# Instance Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Agent Standard 1.1 (instances, entry hook, setup, migrations) in the builder (1.1.0), adopt it in sales-partner (1.0.0), update the catalog, and prove a catalog install comes alive in an instance folder.

**Architecture:** A byte-identical bash `SessionStart` hook in every 1.1 agent prints the agent's `AGENT.md` plus instance/package paths when the working folder is inside a matching `instance.yaml`. The validator's Python helper gains 1.1 checks, comparing the hook to the builder's reference copy in `_template/`.

**Tech Stack:** bash, Python 3 stdlib, markdown skills, Claude Code plugins, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-28-instance-mode-design.md` (builder repo)

## Global Constraints

- Builder: `/Users/hochoy/Work/Webspenser/agent-library`, branch `feat/instance-mode` (based on `feat/catalog`). sales-partner: `/Users/hochoy/Work/Webspenser/sales-partner` (SSH origin). Catalog: `/Users/hochoy/Work/Webspenser/agent-library-catalog` (SSH origin).
- Reference hook: `_template/hooks/session-start.sh` in the builder; every 1.1 agent's `hooks/session-start.sh` is byte-identical to it and executable.
- `hooks/hooks.json` command string exactly: `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"` (with the double quotes).
- `instance.yaml` keys: `agent`, `agent_version`, `standard: "1.1"`, `mode` (`plugin` | `source`).
- **Ruling (spec deviation):** `agent.yaml` catalog fields are two flat optional keys — `catalog: webspenser` and `catalog_repo: webspenser/agent-library` — not the spec's `catalog: { name, repo }` map, because the Python helper and the bash hook read top-level `key: value` lines only. Same information.
- Hook: bash only; no `jq`, no `python`; plain-text stdout; always exit 0.
- Builder version `1.1.0` (three manifests + test pin). sales-partner version `1.0.0` (agent.yaml + four manifests + README).
- Test checks capture output before grepping (`set -uo pipefail`). Scripts 100755 — the Edit tool drops the bit; check `git ls-files -s` before each commit.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Instance folder names with spaces, and `CLAUDE_PROJECT_DIR` unset** — the hook must still find the instance. Pinned in Task 1.
2. **Quoted or commented values in `instance.yaml`/`agent.yaml`** (`agent: "sales-partner"  # mine`) — must match. Pinned in Task 1.
3. **An `instance.yaml` for a different agent above the folder** — the hook must stay silent (it stops at the nearest marker). Pinned in Task 1.
4. **`setup` run in a folder that already has an instance, or has a `.claude/settings.json`** — must not overwrite; offers interview only / merges settings. Pinned in Task 3 (skill text) and reviewed.
5. **A 1.0 agent validated by the 1.1 validator** — must pass unchanged. Pinned in Task 2.

---

### Task 1: The reference entry hook

**Repo:** builder. **Files:** Create `_template/hooks/session-start.sh`, `_template/hooks/hooks.json`, `tests/test-hook.sh`; modify `tests/run-all.sh`.

- [ ] **Step 1: Failing test** — `tests/test-hook.sh` (executable):

```bash
#!/usr/bin/env bash
# Behavior of the Agent Standard 1.1 entry hook (_template/hooks/session-start.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
HOOK="$PWD/_template/hooks/session-start.sh"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PKG="$W/pkg"; mkdir -p "$PKG"
printf '%s\n' 'name: demo-agent' 'version: 1.2.0' 'description: Demo' 'standard: "1.1"' > "$PKG/agent.yaml"
printf '%s\n' '# Demo' 'DEMO-AGENT-MARKER' > "$PKG/AGENT.md"

run_hook() { # run_hook <project dir> — prints hook stdout; exit code in $RC
  OUT=$(CLAUDE_PLUGIN_ROOT="$PKG" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>&1); RC=$?
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# No instance: silent.
mkdir -p "$W/plain"
run_hook "$W/plain"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && _report ok "silent without instance" || _report no "not silent without instance: $OUT"

# Matching instance: header + AGENT.md, no migration line.
I="$W/inst"; mkdir -p "$I"
printf '%s\n' 'agent: demo-agent' 'agent_version: 1.2.0' 'standard: "1.1"' 'mode: plugin' > "$I/instance.yaml"
run_hook "$I"
has 'DEMO-AGENT-MARKER' && has "Instance folder: $I" && has "Package folder: $PKG" && ! has 'Migration:' \
  && _report ok "loads in matching instance" || _report no "matching instance output wrong: $OUT"

# From a subfolder: finds the parent instance.
mkdir -p "$I/a/b"; run_hook "$I/a/b"
has "Instance folder: $I" && _report ok "finds parent instance" || _report no "parent instance not found"

# Another agent's instance nearer than ours: silent.
mkdir -p "$I/other"; printf '%s\n' 'agent: someone-else' 'agent_version: 1.0.0' > "$I/other/instance.yaml"
run_hook "$I/other"
[ -z "$OUT" ] && _report ok "silent in another agent's instance" || _report no "spoke in another agent's instance"

# Version gap: migration line names both versions.
G="$W/gap"; mkdir -p "$G"; printf '%s\n' 'agent: demo-agent' 'agent_version: 1.1.0' > "$G/instance.yaml"
run_hook "$G"
has 'Migration:' && has '1.1.0' && has '1.2.0' && _report ok "migration line on version gap" || _report no "no migration line"

# Quoted values and trailing comments.
Q="$W/quoted"; mkdir -p "$Q"; printf '%s\n' 'agent: "demo-agent"   # mine' "agent_version: '1.2.0'" > "$Q/instance.yaml"
run_hook "$Q"
has 'DEMO-AGENT-MARKER' && ! has 'Migration:' && _report ok "quoted values match" || _report no "quoted values failed: $OUT"

# Spaces in the instance path.
S="$W/with space/inst"; mkdir -p "$S"; printf '%s\n' 'agent: demo-agent' 'agent_version: 1.2.0' > "$S/instance.yaml"
run_hook "$S"
has "Instance folder: $S" && _report ok "path with spaces" || _report no "path with spaces failed"

# CLAUDE_PROJECT_DIR unset: uses the working directory.
OUT=$(cd "$I/a" && env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT="$PKG" bash "$HOOK" 2>&1)
has 'DEMO-AGENT-MARKER' && _report ok "falls back to PWD" || _report no "PWD fallback failed"

# Missing AGENT.md: one line, exit 0.
mv "$PKG/AGENT.md" "$PKG/AGENT.bak"; run_hook "$I"
[ "$RC" -eq 0 ] && has 'AGENT.md is missing' && _report ok "missing AGENT.md reported" || _report no "missing AGENT.md not handled"
mv "$PKG/AGENT.bak" "$PKG/AGENT.md"

# hooks.json points at the script.
assert_contains _template/hooks/hooks.json '"\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\""'
[ -x "$HOOK" ] && _report ok "hook is executable" || _report no "hook not executable"

finish
```

Add to `tests/run-all.sh` after the install tests line: `echo "== hook";  tests/test-hook.sh || STATUS=1`

Run: `chmod 755 tests/test-hook.sh && tests/test-hook.sh` — Expected: failures (hook missing).

- [ ] **Step 2: `_template/hooks/session-start.sh`** (executable)

```bash
#!/usr/bin/env bash
# Agent Standard 1.1 entry hook — identical in every agent.
# When the session's folder is (inside) an instance of this agent, prints the
# agent's instructions and where its files live. Prints nothing otherwise.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

yaml_get() { # yaml_get <file> <key>: top-level scalar; quotes and trailing comments removed
  sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 \
    | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

name=$(yaml_get "$root/agent.yaml" name)
version=$(yaml_get "$root/agent.yaml" version)
[ -n "$name" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
instance=""
while [ -n "$dir" ]; do
  if [ -f "$dir/instance.yaml" ]; then instance="$dir"; break; fi
  [ "$dir" = "/" ] && break
  dir=$(dirname "$dir")
done
[ -n "$instance" ] || exit 0
[ "$(yaml_get "$instance/instance.yaml" agent)" = "$name" ] || exit 0
instance_version=$(yaml_get "$instance/instance.yaml" agent_version)

printf '%s\n' \
  "# Agent: $name $version" \
  "This folder is an instance of the $name agent. Follow the instructions below." \
  "Instance folder: $instance" \
  "Package folder: $root" \
  "Paths: context/ means the instance folder's context/. templates/, samples/, skills/, subagents/ and migrations/ mean the package folder's. Write only into the instance folder."
if [ -n "$instance_version" ] && [ "$instance_version" != "$version" ]; then
  printf '%s\n' "Migration: this instance was set up with $name $instance_version; the agent is now $version. Read migrations/ in the package folder, show the user the proposed changes to the instance's files as a diff, apply them only after they confirm, then set agent_version in instance.yaml to $version."
fi
printf '\n'
if [ -f "$root/AGENT.md" ]; then
  cat "$root/AGENT.md"
else
  printf '%s\n' "(AGENT.md is missing from $root)"
fi
exit 0
```

`_template/hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\"" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Run** — `tests/test-hook.sh && tests/run-all.sh` → `0 failed`, `ALL GREEN`.

- [ ] **Step 4: Commit** — `git add _template/hooks tests && git commit -m "feat: Agent Standard 1.1 reference entry hook"`

---

### Task 2: Validator 1.1 checks and STANDARD.md 1.1

**Repo:** builder. **Files:** Modify `bin/lib/check_manifests.py`, `tests/test-validate-agent.sh`, `STANDARD.md`.

- [ ] **Step 1: Failing tests** — in `tests/test-validate-agent.sh`, after `make_valid_v1_agent`, add:

```bash
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
```

Before `finish`, add:

```bash
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
```

Run: `tests/test-validate-agent.sh` — Expected: the `assert_fail` 1.1 cases FAIL (no 1.1 checks yet).

- [ ] **Step 2: Implement in `bin/lib/check_manifests.py`**
  - Add `import os` and, near the other constants:

```python
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
HOOK_COMMAND = '"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"'
REFERENCE_HOOK = pathlib.Path(__file__).resolve().parents[2] / "_template" / "hooks" / "session-start.sh"
```

  - Add this function above `check`:

```python
def check_v11(root, meta, name):
    """Agent Standard 1.1: entry hook, start/setup skills, migrations, catalog, instance marker."""
    fails = []
    hooks = None
    try:
        hooks = json.loads(read_text(root / "hooks" / "hooks.json"))
    except ReadError as err:
        fails.append(f"hooks/hooks.json: {err}")
    except json.JSONDecodeError as err:
        fails.append(f"hooks/hooks.json: not valid JSON ({err.msg}, line {err.lineno})")
    if hooks is not None:
        commands = []
        events = hooks.get("hooks") if isinstance(hooks, dict) else None
        groups = events.get("SessionStart") if isinstance(events, dict) else None
        for group in groups if isinstance(groups, list) else []:
            for hook in (group.get("hooks") if isinstance(group, dict) else None) or []:
                if isinstance(hook, dict) and hook.get("type") == "command":
                    commands.append(hook.get("command"))
        if HOOK_COMMAND not in commands:
            fails.append(f"hooks/hooks.json: needs a SessionStart command hook {HOOK_COMMAND}")

    script = root / "hooks" / "session-start.sh"
    if not script.is_file():
        fails.append("missing hooks/session-start.sh")
    else:
        if not os.access(script, os.X_OK):
            fails.append("hooks/session-start.sh is not executable")
        if not REFERENCE_HOOK.is_file():
            fails.append(f"validator is missing its reference hook at {REFERENCE_HOOK}")
        elif script.read_bytes() != REFERENCE_HOOK.read_bytes():
            fails.append("hooks/session-start.sh differs from the Agent Standard reference copy (_template/hooks/session-start.sh in agent-builder)")

    for skill in ("start", "setup"):
        if not (root / "skills" / skill / "SKILL.md").is_file():
            fails.append(f"missing skills/{skill}/SKILL.md")
    if not (root / "migrations").is_dir():
        fails.append("missing directory: migrations/")

    catalog, catalog_repo = meta.get("catalog", ""), meta.get("catalog_repo", "")
    if bool(catalog) != bool(catalog_repo):
        fails.append("agent.yaml: catalog and catalog_repo must be set together")
    if catalog and not KEBAB.match(catalog):
        fails.append(f"agent.yaml: catalog '{catalog}' is not kebab-case")
    if catalog_repo and not REPO.match(catalog_repo):
        fails.append(f"agent.yaml: catalog_repo '{catalog_repo}' is not owner/repo")

    marker = root / "instance.yaml"
    if marker.is_file():
        try:
            inst = parse_agent_yaml(read_text(marker))
        except ReadError as err:
            fails.append(f"instance.yaml: {err}")
            inst = None
        if inst is not None:
            if inst.get("agent") != name:
                fails.append(f"instance.yaml: agent {inst.get('agent')!r} does not match agent.yaml {name!r}")
            if inst.get("mode") != "source":
                fails.append("instance.yaml in a package must have mode: source")
    return fails
```

  - In `check`, after the `SUPPORTED_STANDARD` line, add:

```python
    if std and SUPPORTED_STANDARD.match(std) and int(std.split(".")[1]) >= 1:
        fails.extend(check_v11(root, meta, name))
```

- [ ] **Step 3: `STANDARD.md` 1.1** — title `# Agent Standard 1.1`; in `## Versioning` add "1.1 (this version) adds instances, the entry hook, setup, and migrations; a 1.0 agent still validates as 1.0." Add before `## Validation`:

````markdown
## Instances (1.1)

A folder is an instance of an agent when it holds `instance.yaml`:

```yaml
agent: sales-partner       # the agent's name
agent_version: 1.0.0       # version setup (or the last migration) ran with
standard: "1.1"
mode: plugin               # plugin | source
```

`context/<file>` in `AGENT.md`, skills, and contracts means the
instance's file; if it is missing, run the step that produces it —
never act on the package's blank default. `templates/`, `samples/`,
`skills/`, `subagents/`, and `migrations/` mean the package's files.
Write only into the instance. In source mode the package folder is the
instance (`instance.yaml` with `mode: source` at its root).

## Entry hook (1.1)

Every 1.1 agent ships `hooks/hooks.json` with one `SessionStart`
command hook, `"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"`, and
`hooks/session-start.sh` byte-identical to `_template/hooks/session-start.sh`.
It finds the nearest `instance.yaml` above the session folder; if it
names this agent, it prints where the instance and package live, a
migration notice when versions differ, and `AGENT.md`. Elsewhere it
prints nothing.

## Setup and start (1.1)

`skills/setup/SKILL.md` creates an instance; `skills/start/SKILL.md`
loads `AGENT.md` by hand when the hook did not run. Optional
`agent.yaml` keys `catalog` (marketplace name) and `catalog_repo`
(`owner/repo`) let setup enable the plugin in the instance's
`.claude/settings.json`; set both or neither.

## Migrations (1.1)

`migrations/` holds one `<from>-<to>.md` note per release that changes
the shape of a context file: what changed and how to convert. It may be
empty.
````

In the Directory layout block add `hooks/`, `migrations/` under `<agent-name>/`.

- [ ] **Step 4: Run** — `tests/test-validate-agent.sh && tests/run-all.sh` → `0 failed`, `ALL GREEN`.

- [ ] **Step 5: Commit** — `git add bin STANDARD.md tests && git commit -m "feat: Agent Standard 1.1 checks in the validator"`

---

### Task 3: Template, wizard, docs, builder 1.1.0

**Repo:** builder. **Files:** `_template/agent.yaml`, `_template/skills/start/SKILL.md`, `_template/skills/setup/SKILL.md`, `_template/migrations/.gitkeep`, `skills/new-agent/SKILL.md`, `README.md`, `docs/writing-an-agent.md`, builder manifests, `tests/test-builder-manifests.sh`, `tests/run-all.sh`.

- [ ] **Step 1: Failing check** — in `tests/run-all.sh`, change the template check to require 1.1:

```bash
echo "== template is Agent Standard 1.1"
if ! grep -q '^standard: "1.1"' _template/agent.yaml; then echo "FAIL: _template is not 1.1"; STATUS=1; fi
```

(replacing the old "template is Agent Standard 1.0" block, keeping its WARN check). Change the builder version pin in `tests/test-builder-manifests.sh` to `1.1.0`. Run `tests/run-all.sh` → failures.

- [ ] **Step 2: Template** — `_template/agent.yaml` `standard: "1.1"`; `mkdir -p _template/migrations && touch _template/migrations/.gitkeep`.

`_template/skills/start/SKILL.md`:

```markdown
---
name: start
description: Use when this agent's instructions did not load at the start of a session, or the user asks to start the agent — loads AGENT.md by hand.
---

1. Read `AGENT.md` from this agent's package folder
   (`${CLAUDE_PLUGIN_ROOT}/AGENT.md` on Claude Code; on other hosts, the
   `AGENT.md` beside this `skills/` folder).
2. Find the instance: the nearest folder at or above the current one
   holding an `instance.yaml` whose `agent` is this agent. If there is
   none, say so and offer the `setup` skill.
3. Follow `AGENT.md` from here on. `context/` means the instance's
   `context/`; `templates/`, `samples/`, `skills/`, `subagents/`, and
   `migrations/` mean the package's. Write only into the instance.
```

`_template/skills/setup/SKILL.md`:

```markdown
---
name: setup
description: Use when setting this agent up in a folder for the first time — creates the instance (instance.yaml, host files, your context) and runs the interview.
---

Creates an instance: the folder that holds your data for this agent.
The agent's logic stays in its package; nothing here is written there.
Read this agent's name, version, and optional `catalog` /
`catalog_repo` from `agent.yaml` in the package folder.

1. **Folder.** If the current folder is empty (dot files aside), use it.
   Otherwise propose `./<agent name>/` and confirm. If an
   `instance.yaml` for this agent already exists there, stop and offer
   to re-run only the interview.
2. **Marker.** Write `instance.yaml`:
   `agent: <name>`, `agent_version: <version>`, `standard: "1.1"`,
   `mode: plugin`.
3. **Host files.** Write `CLAUDE.md`, `GEMINI.md`, and `AGENTS.md`, each:
   "This folder is an instance of <name>. Its instructions load from the
   <name> plugin; if they didn't, run the `start` skill." Do not
   overwrite an existing file — append the line instead.
4. **.gitignore.** Create or extend it with: `.env`, `.env.*`,
   `**/credentials.json`, `**/*.key`, `.DS_Store`.
5. **Host settings.** If `catalog` and `catalog_repo` are set, create or
   merge `.claude/settings.json` so it contains
   `extraKnownMarketplaces.<catalog>` = `{"source": {"source": "github",
   "repo": "<catalog_repo>"}}` and `enabledPlugins."<name>@<catalog>"` =
   `true`. Keep every existing key; never replace the file.
6. **Context.** Copy each file in the package's `context/` into the
   instance's `context/` (skip any that already exist), then run the
   `<interview-skill>` skill to fill them with the user.
7. **Version control.** Offer `git init` and a first commit, in a
   private repository. Remind the user that credentials belong in the
   host (connectors, MCP settings, environment variables), never in
   these files.

Never invent the user's facts; what they don't supply stays as the
package's bracketed prompt.
```

- [ ] **Step 3: Wizard** — in `skills/new-agent/SKILL.md`:
  - Step 4 (Scaffold): add "The template is Agent Standard 1.1: keep `hooks/` exactly as copied (the validator checks it byte for byte)."
  - Step 5: add a bullet "Interview — which skill gathers the user's context; replace `<interview-skill>` in `skills/setup/SKILL.md` with its name."
  - Step 9 personal: replace "offer to fill the `context/` files now by interviewing the user…" with "run `setup` in source mode: write `instance.yaml` at the agent folder with `mode: source`, then run the interview to fill `context/` in place."
  - Step 9 distributable: add "If you publish to a catalog, set `catalog` and `catalog_repo` in `agent.yaml`."

- [ ] **Step 4: Docs** — `README.md`: after "Build an agent", add a short "## Instances" section: installed agents keep your data in your own folder; run `/<agent>:setup` in an empty folder; opening your host there loads the agent. `docs/writing-an-agent.md`: add item "11. **Your data lives in an instance.** Write `context/` paths as if they are the user's folder — the entry hook and `setup` make that true."

- [ ] **Step 5: Version** — `1.0.1` → `1.1.0` in `.claude-plugin/plugin.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`.

- [ ] **Step 6: Run** — `bin/validate-agent.sh _template` → OK (1.1 checks pass on the template itself); `tests/run-all.sh` → ALL GREEN.

- [ ] **Step 7: Commit and push** — `git add -A _template skills README.md docs/writing-an-agent.md .claude-plugin gemini-extension.json .codex-plugin tests && git commit -m "feat: template and wizard on Agent Standard 1.1; builder 1.1.0" && git push -u origin feat/instance-mode`

---

### Task 4: sales-partner 1.0.0 on Standard 1.1

**Repo:** sales-partner, new branch `release/1.0.0`. Validate with the builder checkout's validator (`/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh`, on `feat/instance-mode`).

- [ ] **Step 1: Failing check** — set `standard: "1.1"` in `agent.yaml`; run the builder validator → FAIL lines for the missing 1.1 files.

- [ ] **Step 2: Files**

```bash
B=/Users/hochoy/Work/Webspenser/agent-library
mkdir -p hooks skills/start skills/setup migrations
cp "$B/_template/hooks/session-start.sh" "$B/_template/hooks/hooks.json" hooks/
chmod 755 hooks/session-start.sh
cp "$B/_template/skills/start/SKILL.md" skills/start/SKILL.md
sed 's/`<interview-skill>`/`interview-business`/' "$B/_template/skills/setup/SKILL.md" > skills/setup/SKILL.md
```

`agent.yaml`: `version: 1.0.0`, `standard: "1.1"`, plus `catalog: webspenser` and `catalog_repo: webspenser/agent-library`. Version `1.0.0` in the four manifests and README's "Version …" line.

`migrations/0.9.x-1.0.0.md`:

```markdown
# 0.9.x → 1.0.0

Context file shapes are unchanged. What's new is the instance marker.

- **Source mode** (your own copy made with "Use this template"): add
  `instance.yaml` at the repo root:

      agent: sales-partner
      agent_version: 1.0.0
      standard: "1.1"
      mode: source

- **Plugin mode** is new in 1.0.0: install from the catalog and run
  `/sales-partner:setup` in an empty folder. To move an existing source
  copy's data, copy its `context/` folder into the new instance.
```

- [ ] **Step 3: AGENT.md** — at the end of `## Inputs`, add:

```markdown
- **Where these files live (Agent Standard 1.1).** `context/…` above
  means the instance folder — the folder holding this agent's
  `instance.yaml`, where the user's data lives. `templates/`,
  `samples/`, `skills/`, and `subagents/` mean this package's files.
  Everything the agent writes goes into the instance.
```

- [ ] **Step 4: README** — replace "## Use it today (source mode)" through the paragraph "Plugin installs — …" with:

```markdown
## Install (plugin mode)

    /plugin marketplace add webspenser/agent-library
    /plugin install sales-partner@webspenser

Then open Claude Code in an empty folder — this becomes your instance,
where your data lives — and run `/sales-partner:setup`. It writes
`instance.yaml`, runs the interview to fill `context/`, and offers to
make the folder a private git repo. From then on, opening Claude Code
in that folder loads the agent. Plugin updates never touch your folder.

## Use it from source

1. Click **Use this template** to create your own private copy.
2. Clone it, run `./install.sh`, and add `instance.yaml` at the root
   with `mode: source` (see `migrations/0.9.x-1.0.0.md`).
3. Ask the agent to run its interview (the `interview-business` skill).
```

- [ ] **Step 5: Tests** — add to `tests/test-content.sh` before `finish`:

```bash
echo "-- instance mode (1.1)"
assert_contains "$SP/agent.yaml" 'standard: "1.1"'
assert_contains "$SP/agent.yaml" 'catalog_repo: webspenser/agent-library'
assert_contains "$SP/skills/setup/SKILL.md" '`interview-business`'
assert_contains "$SP/migrations/0.9.x-1.0.0.md" 'mode: source'
assert_contains "$SP/AGENT.md" 'Agent Standard 1.1'
```

- [ ] **Step 6: Verify** — `tests/run-all.sh` ALL GREEN; builder validator → `OK`, no WARN; `validate-agent.sh . --require-bump origin/main` → OK.

- [ ] **Step 7: PR** — commit (`feat: instance mode — sales-partner 1.0.0 on Agent Standard 1.1`), push `release/1.0.0` over SSH, `gh pr create --repo webspenser/sales-partner --base main --head release/1.0.0 --title "1.0.0: instance mode (Agent Standard 1.1)"`, watch CI to green, record URLs. Do not merge.

---

### Task 5: Catalog status

**Runs after the controller merges Task 4's PR.** **Repo:** catalog, branch `main`.

- [ ] In `README.md`: remove the deferral paragraph after the Install block; add `/plugin install sales-partner@webspenser` back to the Install block; change the sales-partner status cell to `1.0 — install, then run \`/sales-partner:setup\` in an empty folder`.
- [ ] `python3 tests/check-catalog.py` → OK. Commit (`docs: sales-partner 1.0 installs from the catalog`), push, CI green.

---

### Task 6: Acceptance through the catalog

**Runs after Tasks 4–5.** No commits.

```bash
claude plugin marketplace add webspenser/agent-library
claude plugin install sales-partner@webspenser
W=$(mktemp -d); mkdir -p "$W/inst" "$W/plain" "$W/old"
printf '%s\n' 'agent: sales-partner' 'agent_version: 1.0.0' 'standard: "1.1"' 'mode: plugin' > "$W/inst/instance.yaml"
printf '%s\n' 'agent: sales-partner' 'agent_version: 0.9.1' > "$W/old/instance.yaml"
```

From each folder run `claude -p "Without using tools: reply with the Instance folder line and the first heading of your agent instructions, and any Migration line; or NONE." --model haiku`:
- `inst` → the instance path and "# Sales Partner"; no Migration line.
- `plain` → NONE.
- `old` → a Migration line naming 0.9.1 and 1.0.0.

Then `claude plugin uninstall sales-partner@webspenser` and `claude plugin marketplace remove webspenser`; confirm `claude plugin list` / `marketplace list` show no webspenser traces. Record all outputs.

---

## After the plan (controller)

- Builder: open a PR for `feat/instance-mode` after PR #6 merges.
- The `v1` tag for `webspenser/agent-builder/validate@v1` must move to the merged `main` so CI in agent repos checks 1.1; moving a tag needs a force push, which a hook blocks — the user runs it.
