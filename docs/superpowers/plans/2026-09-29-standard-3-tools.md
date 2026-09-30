# Agent Standard 3.0 (tools, not adapters) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename every tool file by its purpose. Add one tool checker (`hooks/tool_check.py`) and an `add-tool` skill. Ship Agent Standard 3.0 in the builder (3.0.0) and in sales-partner (3.0.0).

**Architecture:** Tool folders become `capabilities/<cap>/tools/<tool>/{identity.yaml, usage.md, guard.yaml?, bootstrap.py?}`, host shims move to `hosts/`, and instance custom tools move to `custom-tools/<cap>/`.
- A new reference hook, `tool_check.py`, is the single checker of a tool folder. The validator, `schedule_check.py` and the `add-tool` skill all use it.
- `guard.sh` changes paths only, plus one fail-closed rule: a bound tool with no `identity.yaml` blocks.
- `schedule_check.py` keeps its guard-parity reader for identity values and also runs `tool_check`.

**Tech Stack:** bash, Python 3 (stdlib only), Markdown skills, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-standard-3-tools-design.md`

## Global Constraints

- Development-phase policy: no backward compatibility. The validator accepts only `standard: "3.0"`. Old layouts FAIL with a message naming the 3.0 location.
- Every file in `hooks/` is byte-identical to `_template/hooks/` in every agent. The set is `hooks.json`, `session-start.sh`, `guard.sh`, `guard_policy.py`, `schedule_check.py` and `tool_check.py`. All scripts are executable.
- `_template/skills/schedule/SKILL.md` and `_template/skills/add-tool/SKILL.md` are copied into agents byte-identical.
- `identity.yaml` keys are exactly `capability`, `provider` and `server_match`. `server_match` must fully match `[a-z0-9_-]+`.
- Checkers never traceback. `tool_check.py` exits 0 OK, 1 FAIL, 2 ERROR.
- Hooks fail closed: when state can't be read, block.
- Never write credentials to files.
- The word "adapter" disappears from the standard (STANDARD.md, the skills, the template, the docs). Git history and `docs/superpowers/` specs and plans are exempt.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Never touch `~/Work/Webspenser/live-agents`.

## Review Focus

1. **A leftover 2.x file next to a new one.** If `adapter.yaml` sits beside `identity.yaml`, the checker FAILs naming the old file. It never silently reads one of them. Tested in Task 1 and Task 4.
2. **A custom tool without `guard.yaml` for a `no_send` capability.** `tool_check --custom` FAILs. Tested in Task 1.
3. **An instance still on `custom-adapters/` after the upgrade.** `guard.sh` blocks every MCP call and says to apply the 3.0 migration. The schedule gate FAILs the same way. Tested in Task 2 and Task 3.
4. **`add-tool` run outside an instance or package.** The skill stops with directions. This is skill text; it is checked by the Task 5 grep test and exercised in the Task 7 acceptance.
5. **`server_match` taken from a display name with spaces or capitals ("HubSpot CRM").** `tool_check` FAILs it, and the skill text says to normalize. Tested in Task 1; the skill text is checked in Task 5.

---

### Task 1: `hooks/tool_check.py` (the tool checker)

**Files:**
- Create: `_template/hooks/tool_check.py` (mode 755)
- Create: `tests/test-tool-check.sh` (mode 755)
- Modify: `tests/run-all.sh` (add the suite)

**Interfaces:**
- Produces:
  - `tool_check.read_contract(path: pathlib.Path) -> tuple[list[str], list[str]]`: (operations, invariants). Raises `tool_check.ToolError` when the file can't be read.
  - `tool_check.check_tool(folder: pathlib.Path, cap: str, ops: list[str], invariants: set[str], custom: bool = False, label: str | None = None) -> tuple[list[str], dict]`: (FAIL messages without the `FAIL: ` prefix, identity dict). It never raises for bad content.
  - `tool_check.ToolError(Exception)`.
  - CLI: `tool_check.py <tool-folder> <contract.md> [--custom]`.

- [ ] **Step 1: Write the failing test** `tests/test-tool-check.sh`:

```bash
#!/usr/bin/env bash
# Behavior of the Agent Standard tool checker (_template/hooks/tool_check.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
TC="$PWD/_template/hooks/tool_check.py"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
C="$W/pkg/capabilities/crm"; T="$C/tools/demo"; mkdir -p "$T"
printf '%s\n' '# CRM' '' '## Operations' '' '| `create_lead` | x |' '| `get_lead` | y |' '' \
  '## Invariants' '' '- `draft_only` — x' '- `no_delete` — y' > "$C/contract.md"
good_tool() { # good_tool <dir> <provider>
  mkdir -p "$1"
  printf '%s\n' 'capability: crm' "provider: $2" 'server_match: demo' > "$1/identity.yaml"
  printf '%s\n' '# Demo' '' '- `create_lead` — demo:create' '- `get_lead` — demo:get' '' '## Probe' '' 'Call demo:whoami.' > "$1/usage.md"
  printf '%s\n' 'covers: [draft_only, no_delete]' 'deny: ["*delete*"]' > "$1/guard.yaml"
}
run() { OUT=$(python3 -B "$TC" "$@" 2>&1); RC=$?; }
expect() { # expect <rc> <label> [text]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; } && ! printf '%s' "$OUT" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}
fresh() { rm -rf "$T"; good_tool "$T" demo; }

echo "-- valid"
fresh; run "$T" "$C/contract.md";                        expect 0 "shipped tool passes" "OK: "
I="$W/inst/custom-tools/crm"; good_tool "$I" custom
run "$I" "$C/contract.md" --custom;                      expect 0 "custom tool passes"
fresh; rm "$T/guard.yaml"; run "$T" "$C/contract.md";    expect 0 "no guard.yaml: allowed (instruction-only)"

echo "-- identity.yaml"
fresh; rm "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "missing identity" "missing $T/identity.yaml"
fresh; sed -i.bak 's/^capability: .*/capability: crmx/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "wrong capability" "capability 'crmx' must be 'crm'"
fresh; sed -i.bak 's/^provider: .*/provider: other/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "wrong provider" "provider 'other' must be 'demo'"
run "$I" "$C/contract.md";                               expect 2 "custom folder checked as shipped" "expected capabilities/<cap>/tools/<tool>/"
fresh; sed -i.bak '/^server_match/d' "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "missing server_match" "missing server_match"
fresh; sed -i.bak 's/^server_match: .*/server_match: HubSpot CRM/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "display-name server_match refused" "server_match must be lowercase letters, digits, _ or -"
fresh; echo 'block: send' >> "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "unknown key" "unknown key 'block' (identity.yaml holds capability, provider, server_match)"
fresh; echo 'server_match: other' >> "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "repeated key" "server_match appears more than once"
fresh; sed -i.bak 's/^server_match: .*/server_match:/' "$T/identity.yaml"; echo '  - demo' >> "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "list value refused" "holds flat 'key: value' lines only"
fresh; sed -i.bak 's/^server_match: .*/server_match: [demo]/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "inline list refused" "server_match must be a plain value"
fresh; printf 'capability : crm\n' > "$T/x"; cat "$T/identity.yaml" >> "$T/x"; mv "$T/x" "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "space before colon refused" "no spaces before the colon"
fresh; printf 'server_match: de\001mo\n' > "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "control char refused" "control character"

echo "-- usage.md"
fresh; rm "$T/usage.md"; run "$T" "$C/contract.md";      expect 1 "missing usage" "missing $T/usage.md"
fresh; sed -i.bak '/get_lead/d' "$T/usage.md"; run "$T" "$C/contract.md"; expect 1 "unmapped operation" 'does not map operation `get_lead`'
fresh; sed -i.bak '/^## Probe/d' "$T/usage.md"; run "$T" "$C/contract.md"; expect 1 "no probe" "needs a ## Probe section"

echo "-- guard.yaml"
fresh; echo 'bogus: 1' >> "$T/guard.yaml"; run "$T" "$C/contract.md"; expect 1 "policy must parse" "$T/guard.yaml:"
fresh; printf '%s\n' 'covers: [draft_only, no_spam]' > "$T/guard.yaml"; run "$T" "$C/contract.md"
expect 1 "covers unknown invariant" "covers names no_spam, which is not an invariant of the contract"
E="$W/pkg/capabilities/email"; mkdir -p "$E/tools/mail"
printf '%s\n' '# Email' '' '## Operations' '' '| `draft` | x |' '' '## Invariants' '' '- `no_send` — x' > "$E/contract.md"
printf '%s\n' 'capability: email' 'provider: mail' 'server_match: mail' > "$E/tools/mail/identity.yaml"
printf '%s\n' '`draft`' '## Probe' 'x' > "$E/tools/mail/usage.md"
run "$E/tools/mail" "$E/contract.md";                    expect 1 "no_send needs guard.yaml" "the contract has no_send, so guard.yaml must cover it"
printf '%s\n' 'covers: []' > "$E/tools/mail/guard.yaml"; run "$E/tools/mail" "$E/contract.md"
expect 1 "no_send must be covered" "covers must include no_send"
CE="$W/inst/custom-tools/email"; mkdir -p "$CE"
printf '%s\n' 'capability: email' 'provider: custom' 'server_match: mail' > "$CE/identity.yaml"; cp "$E/tools/mail/usage.md" "$CE/"
run "$CE" "$E/contract.md" --custom;                     expect 1 "custom no_send without guard refused" "must cover it"

echo "-- 2.x names"
fresh; cp "$T/identity.yaml" "$T/adapter.yaml"; run "$T" "$C/contract.md"
expect 1 "adapter.yaml beside identity.yaml refused" "adapter.yaml is the Agent Standard 2 name; 3.0 uses identity.yaml"
fresh; cp "$T/usage.md" "$T/adapter.md"; run "$T" "$C/contract.md"
expect 1 "adapter.md refused" "adapter.md is the Agent Standard 2 name; 3.0 uses usage.md"
fresh; mv "$T" "$C/tools/Demo_X"; sed -i.bak 's/^provider: .*/provider: Demo_X/' "$C/tools/Demo_X/identity.yaml"
run "$C/tools/Demo_X" "$C/contract.md";                  expect 1 "tool folder kebab-case" "tool folder name is not kebab-case"; rm -rf "$C/tools/Demo_X"

echo "-- errors"
run "$W/nope" "$C/contract.md";                          expect 2 "missing folder" "ERROR:"
fresh; run "$T" "$W/nope.md";                            expect 2 "missing contract" "ERROR:"
run;                                                     expect 2 "usage" "Usage:"
printf '%s\n' '# empty' > "$W/empty.md"; run "$T" "$W/empty.md"; expect 2 "contract without operations" "ERROR:"

echo "-- importable"
if python3 -B -c "import sys; sys.path.insert(0, '_template/hooks'); import tool_check as t; print(t.read_contract.__name__, t.check_tool.__name__)" >/dev/null 2>&1; then
  _report ok "module imports"; else _report no "module does not import"; fi
finish
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `chmod +x tests/test-tool-check.sh && tests/test-tool-check.sh`
Expected: FAIL lines, because `_template/hooks/tool_check.py` does not exist yet.

- [ ] **Step 3: Write `_template/hooks/tool_check.py`**

```python
#!/usr/bin/env python3
"""Agent Standard tool checker — identical in every agent.

Usage:
  tool_check.py <tool-folder> <contract.md> [--custom]

Checks one tool folder against its capability's contract: a package's
capabilities/<cap>/tools/<tool>/, or with --custom an instance's
custom-tools/<cap>/. Prints one 'FAIL: <message>' line per problem, or one
'OK:' line. Exit 0 valid, 1 FAIL lines, 2 ERROR (unreadable input). Never a
traceback. The validator, schedule_check.py and the add-tool skill all use it.
"""
import pathlib
import re
import sys

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
try:
    import guard_policy  # noqa: E402  (same folder, reference engine)
except Exception:  # reported per tool that has a guard.yaml
    guard_policy = None

USAGE = "Usage: tool_check.py <tool-folder> <contract.md> [--custom]"
IDENTITY_KEYS = ("capability", "provider", "server_match")
KEBAB = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
SERVER_MATCH = re.compile(r"[a-z0-9_-]+")
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")  # C0 controls and DEL other than tab, LF, CR
OPERATION = re.compile(r"^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`")
INVARIANT = re.compile(r"^[-*]\s+`([^`]+)`")
OLD_NAMES = (("adapter.yaml", "identity.yaml"), ("adapter.md", "usage.md"))  # Agent Standard 2 names


class ToolError(Exception):
    """Input that cannot be read."""


def read(path):
    try:
        return path.read_bytes().decode("utf-8-sig")
    except (OSError, UnicodeDecodeError) as err:
        raise ToolError(f"cannot read {path}: {err}")


def section(text, heading):
    """Lines under `## heading` up to the next `## ` heading, or None when there is no such heading."""
    lines, found, inside = [], False, False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = line[3:].strip() == heading
            found = found or inside
            continue
        if inside:
            lines.append(line)
    return lines if found else None


def read_contract(path):
    """(operations, invariants) from a capability's contract.md."""
    text = read(path)
    ops = [m.group(1) for line in section(text, "Operations") or [] for m in [OPERATION.match(line)] if m]
    invs = [m.group(1) for line in section(text, "Invariants") or [] for m in [INVARIANT.match(line)] if m]
    return ops, invs


def _scalar(raw):
    """A value the way guard.sh's yaml_get reads it: trailing ' # comment' and one pair of quotes removed."""
    value = re.sub(r"[ \t]+#.*$", "", raw.strip(" \t")).rstrip(" \t")
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def parse_identity(text, rel):
    """(identity dict, problems). Anything guard.sh could read differently is a problem."""
    data, fails = {}, []
    bad = CONTROL.search(text)
    if bad:
        line = text.count("\n", 0, bad.start()) + 1
        return data, [f"{rel} line {line} has a control character (0x{ord(bad.group()):02x}) the guard cannot read reliably"]
    for n, line in enumerate(text.split("\n"), 1):
        line = line[:-1] if line.endswith("\r") else line
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] in " \t" or ":" not in line:
            fails.append(f"{rel} line {n}: identity.yaml holds flat 'key: value' lines only (no lists or nesting)")
            continue
        key, raw = line.split(":", 1)
        if key != key.strip():
            fails.append(f"{rel} line {n}: write '{key.strip()}:' with no spaces before the colon")
            continue
        if key not in IDENTITY_KEYS:
            fails.append(f"{rel}: unknown key '{key}' (identity.yaml holds capability, provider, server_match)")
            continue
        if key in data:
            fails.append(f"{rel}: {key} appears more than once")
            continue
        value = _scalar(raw)
        if value[:1] in ("[", "{"):
            fails.append(f"{rel}: {key} must be a plain value, not a YAML list or map")
            value = ""
        data[key] = value
    return data, fails


def check_tool(folder, cap, ops, invariants, custom=False, label=None):
    """(FAIL messages, identity dict) for one tool folder. Never raises for bad content."""
    label = label or str(folder)
    fails, identity = [], {}
    for old, new in OLD_NAMES:
        if (folder / old).exists() or (folder / old).is_symlink():
            fails.append(f"{label}/{old} is the Agent Standard 2 name; 3.0 uses {new}")
    if not custom and not KEBAB.fullmatch(folder.name):
        fails.append(f"{label}: tool folder name is not kebab-case")

    rel = f"{label}/identity.yaml"
    if not (folder / "identity.yaml").is_file():
        fails.append(f"missing {rel}")
    else:
        try:
            identity, problems = parse_identity(read(folder / "identity.yaml"), rel)
        except ToolError as err:
            identity, problems = {}, [f"{rel}: {err}"]
        fails.extend(problems)
        if not problems or identity:
            want = "custom" if custom else folder.name
            if identity.get("capability") != cap:
                fails.append(f"{rel}: capability {identity.get('capability')!r} must be {cap!r}")
            if identity.get("provider") != want:
                fails.append(f"{rel}: provider {identity.get('provider')!r} must be {want!r}")
            match = identity.get("server_match", "")
            if "server_match" not in identity:
                fails.append(f"{rel}: missing server_match")
            elif match and not SERVER_MATCH.fullmatch(match):
                fails.append(f"{rel}: server_match must be lowercase letters, digits, _ or - "
                             "(the guard compares it to MCP tool names)")
            elif not match:
                fails.append(f"{rel}: missing server_match")

    usage = folder / "usage.md"
    if not usage.is_file():
        fails.append(f"missing {label}/usage.md")
    else:
        try:
            text = read(usage)
        except ToolError as err:
            fails.append(f"{label}/usage.md: {err}")
        else:
            for op in ops:
                if f"`{op}`" not in text:
                    fails.append(f"{label}/usage.md: does not map operation `{op}`")
            if section(text, "Probe") is None:
                fails.append(f"{label}/usage.md: needs a ## Probe section")

    policy = folder / "guard.yaml"
    has_policy = policy.exists() or policy.is_symlink()
    covers = None
    if has_policy:
        if guard_policy is None:
            fails.append("cannot load guard_policy.py beside tool_check.py")
        else:
            try:
                covers = guard_policy.parse(read(policy))["covers"]
            except (ToolError, guard_policy.PolicyError) as err:
                fails.append(f"{label}/guard.yaml: {err}")
    for inv in covers or []:
        if inv not in invariants:
            fails.append(f"{label}/guard.yaml: covers names {inv}, which is not an invariant of the contract")
    if "no_send" in invariants:
        if not has_policy:
            fails.append(f"{label}: the contract has no_send, so guard.yaml must cover it")
        elif covers is not None and "no_send" not in covers:
            fails.append(f"{label}/guard.yaml: covers must include no_send")
    return fails, identity


def main(argv):
    custom = "--custom" in argv
    args = [a for a in argv if a != "--custom"]
    if len(args) != 2 or any(a.startswith("-") for a in args):
        print(USAGE, file=sys.stderr)
        return 2
    folder, contract = pathlib.Path(args[0]), pathlib.Path(args[1])
    if not folder.is_dir():
        print(f"ERROR: not a folder: {folder}")
        return 2
    parent = folder.resolve().parent
    if custom and parent.name != "custom-tools":
        print("ERROR: --custom expects an instance's custom-tools/<cap>/ folder")
        return 2
    if not custom and parent.name != "tools":
        print("ERROR: expected capabilities/<cap>/tools/<tool>/ (use --custom for an instance's custom-tools/<cap>/)")
        return 2
    try:
        ops, invs = read_contract(contract)
    except ToolError as err:
        print(f"ERROR: {err}")
        return 2
    if not ops or not invs:
        print(f"ERROR: {contract} has no ## Operations table or no ## Invariants list")
        return 2
    cap = folder.resolve().name if custom else parent.parent.name
    fails, _ = check_tool(folder, cap, ops, set(invs), custom, str(folder))
    for fail in fails:
        print(f"FAIL: {fail}")
    if not fails:
        print(f"OK: {folder} is a valid tool for {cap}")
    return 1 if fails else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as err:  # never a traceback
        print(f"ERROR: {err}")
        sys.exit(2)
```

- [ ] **Step 4: Run the tests**

Run: `chmod 755 _template/hooks/tool_check.py && tests/test-tool-check.sh`
Expected: every line `ok`, then `-- N passed, 0 failed`. If a message assertion fails because of a wording mismatch, change the code (not the test), unless the test contradicts the spec.

- [ ] **Step 5: Wire it into `tests/run-all.sh`.** After the `schedule check` line, add:

```bash
echo "== tool check"; tests/test-tool-check.sh || STATUS=1
```

Confirm that no `_template/hooks/__pycache__` was created (run-all.sh already fails on one).

- [ ] **Step 6: Commit**

```bash
git add _template/hooks/tool_check.py tests/test-tool-check.sh tests/run-all.sh
git commit -m "feat: tool_check.py, the single checker for a tool folder"
```

---

### Task 2: `guard.sh` reads 3.0 paths and fails closed on a missing identity

**Files:**
- Modify: `_template/hooks/guard.sh` (the adapter lookup block, currently lines 70-78)
- Modify: `tests/test-guard.sh`

- [ ] **Step 1: Update the test fixtures to the 3.0 layout (failing first).** In `tests/test-guard.sh`, replace these everywhere:
  - `capabilities/crm/adapters/demo` → `capabilities/crm/tools/demo`
  - `capabilities/email/adapters/plain` → `capabilities/email/tools/plain`
  - `/adapter.yaml` → `/identity.yaml`
  - `custom-adapters` → `custom-tools`
  - `standard: "2.0"` → `standard: "3.0"`
  - the fixture `server_match: DemoCRM` → `server_match: democrm` (the uppercase value was a deferred minor from the 2.1 review)

  Rename the section label `-- custom adapters` → `-- custom tools`, and rename the variable `AD` → `TD`.

  Replace the "missing adapter.yaml" expectation line (currently `expect 0 "missing adapter.yaml: allowed with a note" "no adapter.yaml"`) with:

```bash
run_guard "$G2" "$(call mcp__democrm__delete-record)";           expect 2 "bound tool without identity.yaml: blocked" "has no identity.yaml"
```

  Add before `finish`:

```bash
echo "-- 3.0 migration"
M="$W/migrate"; mkdir -p "$M/custom-adapters/crm"
printf '%s\n' 'agent: demo-agent' 'mode: plugin' 'bind_crm: custom' > "$M/instance.yaml"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: democrm' > "$M/custom-adapters/crm/adapter.yaml"
run_guard "$M" "$(call mcp__democrm__list-records)";            expect 2 "custom-adapters/ left after upgrade: blocked" "apply the 3.0 migration"
rm -r "$M/custom-adapters"
run_guard "$M" "$(call mcp__democrm__list-records)";            expect 2 "custom binding with no custom tool: blocked" "run the add-tool skill"
run_guard "$M" "$(call mcp__other__list-records)";              expect 2 "missing identity blocks every MCP call (fail closed)" "has no identity.yaml"
```

- [ ] **Step 2: Run and confirm failures**

Run: `tests/test-guard.sh`
Expected: FAIL lines, because the guard still reads `adapters/…/adapter.yaml`.

- [ ] **Step 3: Change `guard.sh`.** Replace the block from `if [ "$provider" = custom ]; then` through the `continue` after the "no adapter.yaml" note with:

```bash
  if [ "$provider" = custom ]; then
    tdir="$instance/custom-tools/$cap"
  else
    tdir="$root/capabilities/$cap/tools/$provider"
  fi
  if [ ! -f "$tdir/identity.yaml" ]; then # binding state unknown: fail closed
    if [ "$provider" = custom ] && [ -d "$instance/custom-adapters/$cap" ]; then
      block "instance.yaml binds $cap to custom, but custom-tools/$cap/identity.yaml is missing and custom-adapters/$cap/ is the Agent Standard 2 layout; apply the 3.0 migration (move it to custom-tools/$cap/, rename adapter.yaml to identity.yaml and adapter.md to usage.md)"
    elif [ "$provider" = custom ]; then
      block "instance.yaml binds $cap to custom, but custom-tools/$cap/ has no identity.yaml; run the add-tool skill"
    fi
    block "instance.yaml binds $cap to $provider, which has no identity.yaml in $name; fix the binding (setup's tools step)"
  fi
```

  Then rename `adir` → `tdir` in the rest of the loop (`match=…"$tdir/identity.yaml"…`, the `guard.yaml` test, and the engine call). Update the header comment: "every bound tool whose server_match appears in the tool name gets its guard policy". Leave the rest of the file unchanged.

- [ ] **Step 4: Run the tests**

Run: `tests/test-guard.sh`
Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/guard.sh tests/test-guard.sh
git commit -m "feat: guard reads Agent Standard 3.0 tool paths; a bound tool without identity.yaml blocks"
```

---

### Task 3: `schedule_check.py` on 3.0 paths, backed by `tool_check`

**Files:**
- Modify: `_template/hooks/schedule_check.py` (`adapter()` at ~line 180, `expected()` binding loop at ~lines 293-322, messages that say "adapter")
- Modify: `tests/test-schedule-check.sh`

**Interfaces:**
- Consumes: `tool_check.check_tool(folder, cap, ops, invariants, custom, label)` and `tool_check.read_contract(path)` from Task 1.

- [ ] **Step 1: Update the fixtures (failing first).** In `tests/test-schedule-check.sh`:
  - copy `_template/hooks/tool_check.py` into `$PKG/hooks/` next to the other hooks;
  - replace `/adapters/` with `/tools/`, `adapter.yaml` with `identity.yaml`, and `custom-adapters` with `custom-tools`;
  - `version: 2.1.0` → `3.0.0` and `standard: "2.1"` → `"3.0"`.

  After the fixture tools are created, give every fixture tool a `usage.md`:

```bash
for t in good half bare; do printf '%s\n' '`get`' '## Probe' 'x' > "$PKG/capabilities/crm/tools/$t/usage.md"; done
printf '%s\n' '`draft`' '## Probe' 'x' > "$PKG/capabilities/email_drafts/tools/mail/usage.md"
```

  Do the same for any custom-tool fixture the file creates: add a `usage.md` mapping `` `get` `` with a `## Probe`.

  Add before `finish`:

```bash
echo "-- 3.0 tools"
I="$W/nousage"; instance "$I" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mv "$PKG/capabilities/crm/tools/good/usage.md" "$W/usage.bak"
run check "$I";                                    expect 1 "bound tool failing tool_check fails the entry" "usage.md"
mv "$W/usage.bak" "$PKG/capabilities/crm/tools/good/usage.md"
cp "$PKG/capabilities/crm/tools/good/identity.yaml" "$PKG/capabilities/crm/tools/good/adapter.yaml"
run check "$I";                                    expect 1 "leftover adapter.yaml fails the entry" "Agent Standard 2 name"
rm "$PKG/capabilities/crm/tools/good/adapter.yaml"
I="$W/oldcustom"; instance "$I" custom mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mkdir -p "$I/custom-adapters/crm"; printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: democrm' > "$I/custom-adapters/crm/adapter.yaml"
run check "$I";                                    expect 1 "custom-adapters/ after upgrade fails with migration hint" "apply the 3.0 migration"
rm -r "$I/custom-adapters"
run check "$I";                                    expect 1 "custom binding with no custom tool fails" "run the add-tool skill"
```

- [ ] **Step 2: Run and confirm failures**

Run: `tests/test-schedule-check.sh`
Expected: FAIL lines, because the checker still reads `adapters/`.

- [ ] **Step 3: Change `schedule_check.py`.**
  - Next to the `import guard_policy` block (~line 37), add the same guarded import for `tool_check`:

```python
try:
    import tool_check  # noqa: E402  (same folder, reference tool checker)
except Exception:
    print("ERROR: cannot load tool_check.py beside this script", file=sys.stderr)
    sys.exit(2)
```

  (Mirror exactly how the existing `guard_policy` import handles failure.)

  - Replace `adapter()` with:

```python
def tool(instance, cap, provider):
    """(folder, identity dict read as guard.sh reads it) for a binding: a package tool or the instance's custom tool."""
    folder = instance / "custom-tools" / cap if provider == "custom" else ROOT / "capabilities" / cap / "tools" / provider
    if not (folder / "identity.yaml").is_file():
        if provider == "custom" and (instance / "custom-adapters" / cap).is_dir():
            raise CheckError(f"custom-adapters/{cap}/ is the Agent Standard 2 layout; apply the 3.0 migration "
                             f"(move it to custom-tools/{cap}/, rename adapter.yaml to identity.yaml and adapter.md to usage.md)")
        if provider == "custom":
            raise CheckError(f"custom-tools/{cap}/ has no identity.yaml; run the add-tool skill")
        raise CheckError(f"no identity.yaml for {provider}")
    contract = ROOT / "capabilities" / cap / "contract.md"
    try:
        ops, invs = tool_check.read_contract(contract)
    except tool_check.ToolError as err:
        raise CheckError(str(err))
    label = f"custom-tools/{cap}" if provider == "custom" else f"capabilities/{cap}/tools/{provider}"
    fails, _ = tool_check.check_tool(folder, cap, ops, set(invs), provider == "custom", label)
    if fails:
        raise CheckError(f"the {provider} tool is not valid: " + "; ".join(fails))
    try:
        return folder, flat_yaml(folder / "identity.yaml")
    except CheckError as err:
        raise CheckError(f"the {provider} tool's {err}")
```

  - In `expected()`, call `tool(instance, cap, provider)` instead of `adapter(...)`.
  - In every message, replace "adapter" with "tool": "the {provider} tool has no server_match…", "…by the {provider} tool's guard policy". Replace "run setup's tools step" with "run setup's tools step or the add-tool skill".
  - Change the module docstring's wording the same way.
  - Keep the guard-parity `flat_yaml` read for `server_match`: it must equal what `guard.sh` reads. `tool_check` has already refused anything ambiguous.

- [ ] **Step 4: Run the tests**

Run: `tests/test-schedule-check.sh && tests/test-tool-check.sh`
Expected: 0 failed in both. Fix any older test that asserts an "adapter" wording, so it asserts the new "tool" wording instead.

- [ ] **Step 5: Commit**

```bash
git add _template/hooks/schedule_check.py tests/test-schedule-check.sh
git commit -m "feat: schedule checker reads 3.0 tools and fails entries whose bound tool fails tool_check"
```

---

### Task 4: Validator, template and skeleton on Standard 3.0

**Files:**
- Modify: `bin/lib/check_manifests.py`, `bin/validate-agent.sh`
- Move: `_template/adapters/` → `_template/hosts/`; `_capability-template/adapters/example-provider/` → `_capability-template/tools/example-provider/` (`adapter.yaml` → `identity.yaml`, `adapter.md` → `usage.md`)
- Modify: `_template/install.sh`, `_template/agent.yaml` (`standard: "3.0"`)
- Modify: `tests/test-validate-agent.sh`, `tests/test-install.sh`, `tests/run-all.sh`, `tests/test-builder-manifests.sh`, the three builder manifests (`3.0.0`)

**Interfaces:**
- Consumes: `tool_check.check_tool` (Task 1).

- [ ] **Step 1: Update the tests (failing first).**
  - `tests/test-validate-agent.sh` `make_valid_agent`:
    - `adapters` → `hosts` in the `mkdir` list, and the host shims are written to `$d/hosts/$a.md`;
    - `standard: "3.0"`;
    - copy `_template/hooks/tool_check.py` next to the other hooks (`chmod 755`);
    - the capability fixture is `capabilities/crm/tools/demo/{identity.yaml,usage.md,guard.yaml}`;
    - write `skills/add-tool/SKILL.md` by copying `_template/skills/add-tool/SKILL.md`. Task 5 creates the real skill. For now create a placeholder `_template/skills/add-tool/SKILL.md` with frontmatter `name: add-tool` and `description: Use when adding a tool for one of this agent's capabilities.` Task 5 replaces its body.
  - Rewrite the capability failure cases:
    - `AD`/`A` = `capabilities/crm/tools/demo`;
    - `adapter.yaml` → `identity.yaml`, `adapter.md` → `usage.md`;
    - expected messages as Task 1 produces them, prefixed with the path (e.g. `$A/identity.yaml: unknown key 'block' (identity.yaml holds capability, provider, server_match)`, `$A/usage.md: does not map operation \`get_lead\``, `capabilities/crm/tools/Demo_X: tool folder name is not kebab-case`);
    - "needs at least one adapter" → `capabilities/crm: needs at least one tool in tools/`;
    - the `server_match: [demo]` case → `$A/identity.yaml: server_match must be a plain value, not a YAML list or map`;
    - the bare list case → `holds flat 'key: value' lines only`.
  - The fat-shim case becomes `hosts/GEMINI.md has 41 lines (max 25) — host files carry no behavior`.
  - The old-standard case rejects `"2.1"`: `agent.yaml: standard '2.1' is not 3.0; update the agent to the current Agent Standard`.
  - Add:

```bash
echo "-- Agent Standard 3.0 layout"
make_valid_agent "$FIX/old-hosts"; mv "$FIX/old-hosts/hosts" "$FIX/old-hosts/adapters"
fails_with "$FIX/old-hosts" "adapters/ is the Agent Standard 2 name; 3.0 uses hosts/"
make_valid_agent "$FIX/old-tools"; mv "$FIX/old-tools/capabilities/crm/tools" "$FIX/old-tools/capabilities/crm/adapters"
fails_with "$FIX/old-tools" "capabilities/crm/adapters/ is the Agent Standard 2 layout; 3.0 uses capabilities/crm/tools/<tool>/"
make_valid_agent "$FIX/leftover"; cp "$FIX/leftover/capabilities/crm/tools/demo/identity.yaml" "$FIX/leftover/capabilities/crm/tools/demo/adapter.yaml"
fails_with "$FIX/leftover" "capabilities/crm/tools/demo/adapter.yaml is the Agent Standard 2 name; 3.0 uses identity.yaml"
make_valid_agent "$FIX/no-toolcheck"; rm "$FIX/no-toolcheck/hooks/tool_check.py"
fails_with "$FIX/no-toolcheck" "missing hooks/tool_check.py"
make_valid_agent "$FIX/no-addtool"; rm -r "$FIX/no-addtool/skills/add-tool"
fails_with "$FIX/no-addtool" "missing skills/add-tool/SKILL.md (agent.yaml lists capabilities)"
make_valid_agent "$FIX/edit-addtool"; echo x >> "$FIX/edit-addtool/skills/add-tool/SKILL.md"
fails_with "$FIX/edit-addtool" "skills/add-tool/SKILL.md differs from the Agent Standard reference copy (_template/skills/add-tool/SKILL.md in agent-builder)"
```

  - `tests/test-install.sh`: every `adapters/` → `hosts/`. The "survives deleting adapters/" label → `hosts/`.
  - `tests/run-all.sh`:
    - "template is Agent Standard 3.0" with `grep -q '^standard: "3.0"'`;
    - the skeleton guard check path → `_capability-template/tools/example-provider/guard.yaml`;
    - add `if [ ! -f _template/skills/add-tool/SKILL.md ]; then echo "FAIL: template has no add-tool skill"; STATUS=1; fi`;
    - add `python3 -B _template/hooks/tool_check.py _capability-template/tools/example-provider _capability-template/contract.md >/dev/null || { echo "FAIL: skeleton tool fails tool_check"; STATUS=1; }`.
  - `tests/test-builder-manifests.sh` expects `3.0.0`.

- [ ] **Step 2: Run and confirm failures**

Run: `tests/run-all.sh`
Expected: FAILURES ABOVE.

- [ ] **Step 3: Move the files**

```bash
git mv _template/adapters _template/hosts
git mv _capability-template/adapters _capability-template/tools
git mv _capability-template/tools/example-provider/adapter.yaml _capability-template/tools/example-provider/identity.yaml
git mv _capability-template/tools/example-provider/adapter.md _capability-template/tools/example-provider/usage.md
```

  In `_template/install.sh`:
  - replace `adapters` with `hosts` in the directory check, its error message and the three `place` lines;
  - the header comment becomes "Links this agent's host files into the filenames each host looks for.";
  - change "adapter" to "tool" in the skeleton files' prose.

- [ ] **Step 4: Change `bin/validate-agent.sh`.**
  - `ADAPTER_MAX_LINES` → `HOST_MAX_LINES`.
  - The required directory list uses `hosts`, not `adapters`.
  - The host files are checked at `$DIR/hosts/$a.md`, with the messages `missing hosts/$a.md`, `hosts/$a.md has $lines lines (max $HOST_MAX_LINES) — host files carry no behavior` and `hosts/$a.md does not point at AGENT.md`.
  - The section comment becomes "# Host files are pointers, not behavior".
  - Before the host checks, add:

```bash
[ -d "$DIR/adapters" ] && fail "adapters/ is the Agent Standard 2 name; 3.0 uses hosts/"
```

- [ ] **Step 5: Change `bin/lib/check_manifests.py`.**
  - `CURRENT_STANDARD = "3.0"`.
  - Add `REFERENCE_TOOLCHECK = TEMPLATE_HOOKS / "tool_check.py"` and `REFERENCE_ADD_TOOL = TEMPLATE_HOOKS.parent / "skills" / "add-tool" / "SKILL.md"`.
  - Delete `ADAPTER_KEYS` and `SERVER_MATCH` if nothing else uses them.
  - Add a loader beside `load_policy_engine`:

```python
def load_tool_checker():
    """The reference tool_check module, or None when it cannot be loaded."""
    try:
        spec = importlib.util.spec_from_file_location("tool_check_reference", REFERENCE_TOOLCHECK)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:
        return None
```

  - Replace `check_adapter` with:

```python
def check_tool_folder(tdir, cap, ops, invariants):
    """One shipped tool folder, checked by the reference tool_check.py."""
    checker = load_tool_checker()
    if checker is None:
        return ["validator cannot load its tool checker (_template/hooks/tool_check.py)"]
    fails, _ = checker.check_tool(tdir, cap, ops, invariants, custom=False,
                                  label=f"capabilities/{cap}/tools/{tdir.name}")
    return fails
```

  - In `check_capability`, replace the `folder = base / "adapters"` block with:

```python
    if (base / "adapters").exists():
        fails.append(f"capabilities/{cap}/adapters/ is the Agent Standard 2 layout; 3.0 uses capabilities/{cap}/tools/<tool>/")
    folder = base / "tools"
    tools = sorted(p for p in folder.iterdir() if p.is_dir()) if folder.is_dir() else []
    if not tools:
        fails.append(f"capabilities/{cap}: needs at least one tool in tools/")
    for tdir in tools:
        fails.extend(check_tool_folder(tdir, cap, ops, set(invariants)))
```

  - Add a byte-identity helper for skill files:

```python
def check_reference_file(root, rel, reference):
    """`rel` exists and is byte-identical to the builder's reference copy."""
    path = root / rel
    if not path.is_file():
        return [f"missing {rel}"]
    try:
        same = reference.is_file() and path.read_bytes() == reference.read_bytes()
    except OSError:
        return [f"{rel} cannot be read"]
    return [] if same else [f"{rel} differs from the Agent Standard reference copy (_template/{rel} in agent-builder)"]
```

  - In `check_tools`, after the `schedule_check.py` reference check:

```python
    fails.extend(check_reference_script(root, "hooks/tool_check.py", REFERENCE_TOOLCHECK))
```

    and after `caps` is computed:

```python
    if caps:
        if not (root / "skills" / "add-tool" / "SKILL.md").is_file():
            fails.append("missing skills/add-tool/SKILL.md (agent.yaml lists capabilities)")
        else:
            fails.extend(check_reference_file(root, "skills/add-tool/SKILL.md", REFERENCE_ADD_TOOL))
```

  - Change every remaining "adapter" in docstrings and messages to "tool".

- [ ] **Step 6: Version bump.** `_template/agent.yaml` gets `standard: "3.0"`. The builder manifests (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` if it carries a version, and the others listed in `tests/test-builder-manifests.sh`) go to `3.0.0`.

- [ ] **Step 7: Run everything**

Run: `tests/run-all.sh`
Expected: `ALL GREEN`, and `find . -name __pycache__ -not -path './.git/*'` prints nothing.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: validator and template on Agent Standard 3.0 (tools/, identity.yaml, usage.md, hosts/)"
```

---

### Task 5: The `add-tool` skill, setup, STANDARD and docs

**Files:**
- Modify: `_template/skills/add-tool/SKILL.md` (replace the placeholder body)
- Modify: `_template/skills/setup/SKILL.md` (step 9), `STANDARD.md`, `skills/new-agent/SKILL.md`, `docs/writing-an-agent.md`, `docs/how-it-works.md`, `README.md`
- Modify: `tests/run-all.sh` (text checks)

- [ ] **Step 1: Failing text checks.** Append to `tests/run-all.sh` before the final status line:

```bash
echo "== Agent Standard 3.0 text"
if grep -rniE '\badapters?\b' STANDARD.md README.md docs/how-it-works.md docs/writing-an-agent.md skills _template _capability-template \
     | grep -v 'Agent Standard 2' | grep -v 'custom-adapters' | grep -q .; then
  echo "FAIL: 'adapter' still used outside 2.x migration notes:"; grep -rniE '\badapters?\b' STANDARD.md README.md docs/how-it-works.md docs/writing-an-agent.md skills _template _capability-template | grep -v 'Agent Standard 2' | grep -v 'custom-adapters' | head; STATUS=1
fi
for want in 'custom-tools/<cap>/' 'capabilities/<cap>/tools/<tool>/' 'stop' 'server_match' 'lowercase' 'no_send' 'tool_check.py'; do
  grep -qF -- "$want" _template/skills/add-tool/SKILL.md || { echo "FAIL: add-tool skill does not mention $want"; STATUS=1; }
done
grep -qF 'add-tool' _template/skills/setup/SKILL.md || { echo "FAIL: setup does not hand off to add-tool"; STATUS=1; }
grep -qF 'validate@v3' README.md || { echo "FAIL: README does not use validate@v3"; STATUS=1; }
```

Run `tests/run-all.sh`. Expected: FAIL lines for 'adapter' usage and for the skill text.

- [ ] **Step 2: Write `_template/skills/add-tool/SKILL.md`** exactly:

```markdown
---
name: add-tool
description: Use when adding a tool for one of this agent's capabilities — a client's own system in their instance (custom-tools/), or a new shipped tool in the agent's package (capabilities/<cap>/tools/) — and checking that it is guarded.
---

A tool connects one capability's contract to one system (a CRM, a
mailbox). This skill writes the tool's files, checks them with
`hooks/tool_check.py`, and, in a client's instance, binds it. Never write
credentials to any file: logins live in the host's connectors.

The checker is `${CLAUDE_PLUGIN_ROOT}/hooks/tool_check.py` on Claude Code
(in source mode, `hooks/tool_check.py` in the package folder). Run it
with `python3`.

1. **Target.** Look for this agent's files, starting in the current folder:
   - A folder holding `instance.yaml` whose `agent:` is this agent and whose
     `mode:` is `plugin`: the target is **instance**. Files go to
     `custom-tools/<cap>/`.
   - The agent's own package (a folder holding this agent's `agent.yaml`),
     or a source-mode instance (it is its own package copy): the target is
     **package**. Files go to `capabilities/<cap>/tools/<tool>/`.
   - Neither: stop. Say that this skill runs inside a set-up instance of
     this agent (run `setup` first) or inside the agent's package
     repository, and write nothing.
2. **Capability.** List the capabilities in `agent.yaml` and ask which one.
   Read `capabilities/<cap>/contract.md` in the package: its Operations
   and its Invariants.
3. **Tool.** Ask which system it is.
   - Package target: ask for a kebab-case tool name (e.g. `hubspot`), and
     refuse one that already exists in `capabilities/<cap>/tools/`.
   - Instance target: if `custom-tools/<cap>/` exists, show what is there
     and ask whether to replace it.

   Find this session's tools for that system: MCP tool names look like
   `mcp__<server>__<tool>`. Propose a `server_match`: the lowercase text,
   using only letters, digits, `_` or `-`, that appears after `mcp__` in
   every one of this system's tool names and in no other connector's.
   Never use a display name with spaces or capitals ("HubSpot CRM" → look
   for the tool names' own spelling, e.g. `hubspot`). Show the matching
   tool names and confirm with the user. If the system has no tools in
   this session, explain how to connect it in the host (a connector or an
   MCP server, where the user enters any login themselves), and stop.
4. **`identity.yaml`.** Write exactly three lines: `capability: <cap>`,
   `provider: <tool>` (or `provider: custom` for the instance target),
   and `server_match: <text>`.
5. **`usage.md`.** Write how the agent uses this system:
   - For every contract operation, name it in backticks (e.g.
     `` `create_lead` ``) and give the exact tool calls, object and field
     names, filters and views. Take these from the system's real tool list
     and schema, which you read now with read-only calls only.
   - Add a `## Probe` section: the read-only calls setup (or step 8) runs
     when binding, and what they record in `bindings/<cap>.md`, such as
     the workspace and any IDs the guard needs, as plain
     `field_<name>: <id>` lines.
6. **`guard.yaml`.** For each contract invariant, propose how to enforce it
   on this system's tool calls:
   - an `allow` list of the tools `usage.md` uses, and `deny` globs for
     anything destructive;
   - `create_tools` and `update_tools`, and `values_at`;
   - field `rules`, with `binding_id: required` when the system writes
     fields by ID rather than by name.

   Put every enforced invariant in `covers`. Tell the user plainly which
   invariants stay instruction-only (not in `covers`), and that a
   capability with any instruction-only invariant cannot run on a
   schedule. If the contract has `no_send`, do not continue until
   `guard.yaml` covers it. The policy format is in the Agent Standard
   ("Guard policy").
7. **Check.** Run `python3 <checker> <tool folder> <package>/capabilities/<cap>/contract.md`
   (add `--custom` for the instance target). Fix every `FAIL` line and run
   it again until it prints `OK`. For the package target, also run the
   Agent Builder's validator if it is installed; otherwise say that CI
   runs it on the pull request.
8. **Bind (instance target only).**
   1. Run the `## Probe` calls. On failure, say what failed and stop.
   2. Write what they found to `bindings/<cap>.md`, as plain lines.
   3. Set `bind_<cap>: custom` in `instance.yaml`, replacing any earlier
      `bind_<cap>:` line.
   4. For each invariant, say whether it is covered or instruction-only,
      and whether the capability is now unattended-safe.
   5. If `schedules.yaml` has `schedule_` lines, offer to run the
      `schedule` skill: bindings changed, so every schedule must be checked
      again.
9. **Share (instance target, optional).** If other businesses could use
   this tool, explain the path: run this skill in the agent's package
   repository (the package target) and open a pull request there.
```

- [ ] **Step 3: Setup step 9** (`_template/skills/setup/SKILL.md`). Replace sub-step 1's custom path, from "If none fits, offer a custom adapter:" through the `guard_policy.py --check` sentence, with:
  - "If none fits, run the `add-tool` skill for this capability, then continue with the next capability."

  Other changes in the tools step:
  - "shipped adapters (`capabilities/<capability>/adapters/` in the package)" → "shipped tools (`capabilities/<capability>/tools/` in the package)";
  - "adapter" → "tool" everywhere else in the step;
  - "the adapter's `## Probe` calls" → "the tool's `usage.md` `## Probe` calls".

- [ ] **Step 4: `STANDARD.md`.**
  - "The standard is 2.1" → "The standard is 3.0".
  - **Vocabulary:** "adapter" → "tool" throughout. The directory layout shows `hosts/`, `capabilities/<cap>/tools/<tool>/{identity.yaml, usage.md, guard.yaml, bootstrap.py}`, `hooks/tool_check.py`, `skills/add-tool/` and the instance's `custom-tools/<cap>/`.
  - **New section `## Tools`**, replacing the adapter section:
    - the purpose of each of the four files;
    - the `identity.yaml` keys;
    - `usage.md`'s operation mapping and `## Probe`;
    - `tool_check.py`: its CLI, its checks, and that it is byte-identical;
    - the `add-tool` skill in brief: two targets, the steps, never credentials.
  - **Guard section:** a bound tool with no `identity.yaml` blocks every MCP call (fail closed), with the migration and add-tool messages.
  - **Validation list:**
    - `hosts/`;
    - tools pass `tool_check.py`;
    - the 2.x names and layouts FAIL;
    - `add-tool` is required and byte-identical when capabilities exist;
    - the `tool_check.py` reference copy.
  - **CI snippet:** `validate@v3`.
  - **A short `## Changes from 2.1` list:** the renames table from the spec, `tool_check.py`, `add-tool`, and the missing-identity rule.

  This is the only place the word "adapter" may appear, and only in the form "Agent Standard 2". Include that exact phrase on each line that names an old file, so the Step 1 grep exempts it.

- [ ] **Step 5: Wizard, docs, README.**
  - `skills/new-agent/SKILL.md`:
    - `standard: "3.0"`;
    - the `hooks/` list includes `tool_check.py`;
    - the three `hosts/` files;
    - the skeleton path `_capability-template/tools/example-provider/` with its renamed files;
    - "keep `skills/add-tool` and `skills/schedule` as copied";
    - "adapter" → "tool".
  - `docs/writing-an-agent.md`: the same vocabulary and paths.
  - `docs/how-it-works.md`:
    - the vocabulary table: rename the Adapter row to Tool, and delete the paragraph about the second meaning of adapter;
    - the package and instance trees;
    - "Current: **Agent Standard 3.0**. Agent Builder 3.0.0, sales-partner 3.0.0.";
    - the validator diagram: "each tool passes tool_check.py", plus the `hosts/` and add-tool nodes;
    - the guard diagram: `find adapter` → `find tool`, and a new branch from it, `identity.yaml missing?`, that leads to BLOCK;
    - the "Custom adapters" section → "Custom tools", describing the `add-tool` skill;
    - the known-limits list: remove the adapter-naming and dedicated-skill items.
  - `README.md`:
    - `validate@v2` → `validate@v3`;
    - "Agent Standard 2.1" → "3.0";
    - add a `docs/how-it-works.md` row if one is missing.

- [ ] **Step 6: Run everything**

Run: `tests/run-all.sh`
Expected: `ALL GREEN`.

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "feat: add-tool skill; Agent Standard 3.0 docs; builder 3.0.0"
git push -u origin feat/standard-3.0
```

---

### Task 6: sales-partner 3.0.0

**Repository:** `/Users/hochoy/Work/Webspenser/sales-partner`, a new branch `release/3.0.0` from `main`.

**Files:**
- Move: `adapters/` → `hosts/`, and each `capabilities/*/adapters/<tool>/` → `capabilities/*/tools/<tool>/` (with `adapter.yaml` → `identity.yaml` and `adapter.md` → `usage.md`)
- Copy from the builder: `hooks/{hooks.json,session-start.sh,guard.sh,guard_policy.py,schedule_check.py,tool_check.py}`, `skills/{schedule,add-tool}/SKILL.md`
- Modify: `install.sh`, `agent.yaml` (3.0.0, `standard: "3.0"`), the four host manifests (3.0.0), `skills/setup/SKILL.md` (tools step as in the template), `capabilities/crm/contract.md`, `context/operating-config.md`, `skills/send-digest/SKILL.md`, `evals/cases.md`, `tests/*.sh`, `capabilities/crm/tools/attio/bootstrap.py` (docstring), `README.md`, `.github/workflows/*.yml` (`@v2` → `@v3`)
- Create: `migrations/3.0.0.md`

- [ ] **Step 1: Branch and move**

```bash
cd /Users/hochoy/Work/Webspenser/sales-partner && git checkout main && git pull && git checkout -b release/3.0.0
git mv adapters hosts
for c in capabilities/*/; do
  git mv "${c}adapters" "${c}tools"
  for t in "${c}tools"/*/; do
    git mv "${t}adapter.yaml" "${t}identity.yaml"; git mv "${t}adapter.md" "${t}usage.md"
  done
done
```

- [ ] **Step 2: Copy the reference files**

```bash
B=/Users/hochoy/Work/Webspenser/agent-library
cp "$B"/_template/hooks/{hooks.json,session-start.sh,guard.sh,guard_policy.py,schedule_check.py,tool_check.py} hooks/
chmod 755 hooks/*.sh hooks/*.py
mkdir -p skills/add-tool && cp "$B/_template/skills/add-tool/SKILL.md" skills/add-tool/ && cp "$B/_template/skills/schedule/SKILL.md" skills/schedule/
cp "$B/_template/install.sh" install.sh && chmod 755 install.sh
```

  Diff the builder's `_template/skills/setup/SKILL.md` against `skills/setup/SKILL.md` before copying. Setup is agent-specific (its placeholders are filled in). Apply only the step 9 changes from Task 5 Step 3 by hand.

- [ ] **Step 3: Update references.** Find them all:

```bash
grep -rnE 'adapters?\b|adapter\.(md|yaml)|custom-adapters' --exclude-dir=.git . | grep -v '^./migrations/'
```

  Rewrite each hit:
  - paths become `tools/<tool>/`, `identity.yaml`, `usage.md`, `hosts/` and `custom-tools/`;
  - the word "adapter" becomes "tool" (e.g. "the bound adapter's guard policy" → "the bound tool's guard policy").

  When you're done, the command above prints nothing except lines that say "Agent Standard 2" in `migrations/3.0.0.md`.

- [ ] **Step 4: `migrations/3.0.0.md`**

```markdown
# 3.0.0 — Agent Standard 3.0

Tools replace adapters. For an instance, only custom tools move:

- If the instance has `custom-adapters/<capability>/` (the Agent Standard 2
  layout), move it to `custom-tools/<capability>/`, then inside it rename
  `adapter.yaml` to `identity.yaml` and `adapter.md` to `usage.md`. Show
  the user the moves, apply them after they confirm, then check the tool:
  `python3 <package>/hooks/tool_check.py custom-tools/<capability> <package>/capabilities/<capability>/contract.md --custom`.
- Nothing else changes: `instance.yaml` bindings, `bindings/`, `context/`
  and `schedules.yaml` stay as they are.

Until this is done, the guard blocks every connector call in this instance
when a capability is bound to `custom`.
```

- [ ] **Step 5: Version and CI.**
  - `agent.yaml`: `version: 3.0.0` and `standard: "3.0"`.
  - The four host manifests: `3.0.0`.
  - The workflow: `webspenser/agent-builder/validate@v3` in both steps.
  - `tests/test-schedules.sh` fixtures: `agent_version: 3.0.0`.

- [ ] **Step 6: Verify**

```bash
tests/run-all.sh
/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .
for f in hooks.json session-start.sh guard.sh guard_policy.py schedule_check.py tool_check.py; do cmp "hooks/$f" "/Users/hochoy/Work/Webspenser/agent-library/_template/hooks/$f"; done
cmp skills/add-tool/SKILL.md /Users/hochoy/Work/Webspenser/agent-library/_template/skills/add-tool/SKILL.md
cmp skills/schedule/SKILL.md /Users/hochoy/Work/Webspenser/agent-library/_template/skills/schedule/SKILL.md
for t in capabilities/*/tools/*/; do c=${t%/tools/*}; python3 -B hooks/tool_check.py "$t" "$c/contract.md"; done
```

  Expected:
  - ALL GREEN;
  - `OK: . conforms` (the known AGENT.md size WARN is allowed);
  - no `cmp` output;
  - one `OK:` line per tool (attio, airtable, gmail).

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "feat: sales-partner 3.0.0 on Agent Standard 3.0 (tools, hosts, add-tool)"
git push -u origin release/3.0.0
```

---

### Task 7: Release and acceptance (controller and user)

- [ ] **Step 1:** Open PR `feat/standard-3.0` → `main` (agent-builder). The user merges it with a merge commit.
- [ ] **Step 2:** The user creates the new tag. This is not a force-push:
  `! git -C ~/Work/Webspenser/agent-library fetch origin && git -C ~/Work/Webspenser/agent-library tag v3 origin/main && git -C ~/Work/Webspenser/agent-library push origin v3`
- [ ] **Step 3:** Open PR `release/3.0.0` → `main` (sales-partner). Wait for CI (`@v3`) to go green. The user merges it.
- [ ] **Step 4:** Catalog README (`/Users/hochoy/Work/Webspenser/agent-library-catalog`): both rows at 3.0, and the sales-partner row adds "add your own CRM or mailbox with `/sales-partner:add-tool`". Open a PR; the user merges it.
- [ ] **Step 5: Acceptance.** Work in the scratchpad only.
  1. Build a 3.0 instance: Attio and Gmail bound, `schedules.yaml` with `schedule_digest`. Run `python3 <sales-partner>/hooks/schedule_check.py check <instance>`: PASS.
  2. Pipe an Attio `update-list-entry-by-id` call with `status: approved` into `<sales-partner>/hooks/guard.sh` (with `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PROJECT_DIR` set): exit 2, `Blocked by`.
  3. Run the `add-tool` skill steps by hand in instance mode against a connected CRM (HubSpot if connected, otherwise Airtable as `custom`). The result `custom-tools/crm/` must pass `tool_check.py --custom`, and `guard.sh` must block a denied call through it.
  4. `git -C /Users/hochoy/Work/Webspenser/sales-partner worktree add <scratchpad>/sp-2.1 17cddb2` (the 2.1.0 merge). Run the 3.0 validator on it: it must FAIL naming `hosts/`, `tools/`, `identity.yaml` and `usage.md`. Then run `git worktree remove` on it.

  Record the results in the ledger.
- [ ] **Step 6:** Clean up the merged branches in all three repos. Update the roadmap memory.
