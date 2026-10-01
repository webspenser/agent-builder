#!/usr/bin/env python3
"""Agent Standard manifest checks.

Usage: check_manifests.py <agent-dir>
       check_manifests.py --get <key> <agent.yaml | ->
The first form prints one 'FAIL: <message>' line per problem and one
'WARN: <message>' line per advisory, and exits 0; bin/validate-agent.sh
counts the FAIL lines, passes WARN lines through uncounted, and treats any
other exit status as a crash. The second prints one parsed top-level value from agent.yaml (or
stdin, with '-'), or nothing when the key is absent.
"""
import importlib.util
import json
import os
import pathlib
import re
import sys

sys.dont_write_bytecode = True

REQUIRED_KEYS = ("name", "version", "description", "standard")
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
CURRENT_STANDARD = "5.0"
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
AGENT_MD_INLINE_MAX = 9000  # bytes; the entry hook inlines AGENT.md only up to this size
SETUP_PLACEHOLDERS = ("<interview-skill>", "<context-files>")
TEMPLATE_NAME = "agent-template"
HOOK_COMMAND = '"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"'
TEMPLATE_HOOKS = pathlib.Path(__file__).resolve().parents[2] / "_template" / "hooks"
REFERENCE_HOOK = TEMPLATE_HOOKS / "session-start.sh"
REFERENCE_GUARD = TEMPLATE_HOOKS / "guard.sh"
REFERENCE_POLICY = TEMPLATE_HOOKS / "guard_policy.py"
REFERENCE_SCHEDULE = TEMPLATE_HOOKS / "schedule_check.py"
REFERENCE_TOOLCHECK = TEMPLATE_HOOKS / "tool_check.py"
REFERENCE_ADD_TOOL = TEMPLATE_HOOKS.parent / "skills" / "add-tool" / "SKILL.md"
ACTIVITY = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
GUARD_COMMAND = '"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"'
GUARD_MATCHER = "mcp__.*"
SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")
OPERATION = re.compile(r"^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`")
INVARIANT = re.compile(r"^[-*]\s+`([^`]+)`")
IDENTITY_MANIFESTS = (".claude-plugin/plugin.json", "gemini-extension.json", ".codex-plugin/plugin.json")
ALL_MANIFESTS = IDENTITY_MANIFESTS + (".claude-plugin/marketplace.json",)


def load_policy_engine():
    """The reference guard_policy module, or None when it cannot be loaded."""
    try:
        spec = importlib.util.spec_from_file_location("guard_policy_reference", REFERENCE_POLICY)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:
        return None


def load_tool_checker():
    """The reference tool_check module, or None when it cannot be loaded."""
    try:
        spec = importlib.util.spec_from_file_location("tool_check_reference", REFERENCE_TOOLCHECK)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:
        return None


class ReadError(Exception):
    """A file that exists but cannot be read as UTF-8 text."""


def read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise ReadError("not valid UTF-8")
    except OSError as err:
        raise ReadError(f"cannot be read ({err.strerror})")


def parse_value(value):
    """A quoted value runs to its matching closing quote (the rest is ignored);
    an unquoted value loses a trailing ` # comment`."""
    value = value.strip()
    if value and value[0] in "\"'":
        end = value.find(value[0], 1)
        if end != -1:
            return value[1:end]
    return re.sub(r"(^|\s)#.*$", "", value).strip()


def parse_agent_yaml(text):
    """Top-level `key: value` pairs; indented lines and comments are skipped."""
    data = {}
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#") or raw[0] in " \t" or ":" not in raw:
            continue
        key, value = raw.split(":", 1)
        data[key.strip()] = parse_value(value)
    return data


class Warn(str):
    """An advisory: printed as WARN, never counted as a failure."""


def hook_commands(hooks, event, matcher=None):
    """Commands of `event`'s command hooks; with `matcher`, only groups whose matcher equals it."""
    events = hooks.get("hooks") if isinstance(hooks, dict) else None
    groups = events.get(event) if isinstance(events, dict) else None
    commands = []
    for group in groups if isinstance(groups, list) else []:
        if not isinstance(group, dict) or (matcher is not None and group.get("matcher") != matcher):
            continue
        inner = group.get("hooks")
        for hook in inner if isinstance(inner, list) else []:
            if isinstance(hook, dict) and hook.get("type") == "command":
                commands.append(hook.get("command"))
    return commands


def check_reference_script(root, rel, reference):
    """`rel` exists, is executable, and is byte-identical to the builder's reference copy."""
    script = root / rel
    if not script.is_file():
        return [f"missing {rel}"]
    fails = []
    if not os.access(script, os.X_OK):
        fails.append(f"{rel} is not executable")
    if not reference.is_file():
        fails.append(f"validator is missing its reference hook at {reference}")
        return fails
    try:
        same = script.read_bytes() == reference.read_bytes()
    except OSError:
        fails.append(f"{rel} cannot be read")
    else:
        if not same:
            fails.append(f"{rel} differs from the Agent Standard reference copy (_template/{rel} in agent-builder)")
    return fails


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


def check_runtime(root, meta, name):
    """Entry hook, start/setup skills, catalog, instance marker."""
    fails = []
    agent_md = root / "AGENT.md"
    if agent_md.is_file():
        size = agent_md.stat().st_size
        if size > AGENT_MD_INLINE_MAX:
            fails.append(Warn(f"AGENT.md is {size} bytes; the entry hook will point the model at the file instead of inlining it"))
    hooks, parsed = None, False
    try:
        hooks = json.loads(read_text(root / "hooks" / "hooks.json"))
        parsed = True
    except ReadError as err:
        fails.append(f"hooks/hooks.json: {err}")
    except json.JSONDecodeError as err:
        fails.append(f"hooks/hooks.json: not valid JSON ({err.msg}, line {err.lineno})")
    if parsed:
        if not isinstance(hooks, dict):
            fails.append("hooks/hooks.json must be a JSON object")
        commands = hook_commands(hooks, "SessionStart")
        if HOOK_COMMAND not in commands:
            fails.append(f"hooks/hooks.json: needs a SessionStart command hook {HOOK_COMMAND}")

    fails.extend(check_reference_script(root, "hooks/session-start.sh", REFERENCE_HOOK))

    for skill in ("start", "setup"):
        if not (root / "skills" / skill / "SKILL.md").is_file():
            fails.append(f"missing skills/{skill}/SKILL.md")
    setup = root / "skills" / "setup" / "SKILL.md"
    if name != TEMPLATE_NAME and setup.is_file():
        try:
            setup_text = read_text(setup)
        except ReadError as err:
            fails.append(f"skills/setup/SKILL.md: {err}")
        else:
            for placeholder in SETUP_PLACEHOLDERS:
                if placeholder in setup_text:
                    fails.append(f"skills/setup/SKILL.md still has the {placeholder} placeholder")

    catalog, catalog_repo = meta.get("catalog", ""), meta.get("catalog_repo", "")
    if ("catalog" in meta or "catalog_repo" in meta) and not (catalog and catalog_repo):
        fails.append("agent.yaml: catalog and catalog_repo must be set together as flat keys")
    if catalog and not KEBAB.match(catalog):
        fails.append(f"agent.yaml: catalog '{catalog}' is not kebab-case")
    if catalog_repo and not REPO.match(catalog_repo):
        fails.append(f"agent.yaml: catalog_repo '{catalog_repo}' is not owner/repo")

    marker = root / "instance.yaml"
    if marker.is_dir():
        fails.append("instance.yaml must be a file")
    elif marker.is_file():
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


def check_tool_folder(tdir, cap, ops, invariants):
    """One shipped tool folder, checked by the reference tool_check.py."""
    checker = load_tool_checker()
    if checker is None:
        return ["validator cannot load its tool checker (_template/hooks/tool_check.py)"]
    fails, _ = checker.check_tool(tdir, cap, ops, invariants, custom=False,
                                  label=f"capabilities/{cap}/tools/{tdir.name}")
    return fails


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


def check_capability(root, cap):
    """capabilities/<cap>/contract.md and every tool under it."""
    base = root / "capabilities" / cap
    rel = f"capabilities/{cap}/contract.md"
    if not (base / "contract.md").is_file():
        return [f"missing {rel}"]
    try:
        text = read_text(base / "contract.md")
    except ReadError as err:
        return [f"{rel}: {err}"]
    fails = []
    ops = [m.group(1) for line in section(text, "Operations") or [] for m in [OPERATION.match(line)] if m]
    invariants = [m.group(1) for line in section(text, "Invariants") or [] for m in [INVARIANT.match(line)] if m]
    if not ops:
        fails.append(f"{rel}: needs a ## Operations table with at least one `operation` in its first column")
    if not invariants:
        fails.append(f"{rel}: needs a ## Invariants list with at least one `invariant_id`")
    for inv in invariants:
        if not SNAKE.match(inv):
            fails.append(f"{rel}: invariant '{inv}' is not snake_case")
    checker = load_tool_checker()
    if checker is not None and "no_send" in checker.acceptable(text):
        fails.append(f"{rel}: no_send cannot be marked (acceptable)")
    folder = base / "tools"
    tools = sorted(p for p in folder.iterdir() if p.is_dir()) if folder.is_dir() else []
    if not tools:
        fails.append(f"capabilities/{cap}: needs at least one tool in tools/")
    for tdir in tools:
        fails.extend(check_tool_folder(tdir, cap, ops, set(invariants)))
    return fails


def check_agent_policy(root, caps):
    """The package-root guard.yaml: parses as an agent policy; required to cover no_send when a contract has it."""
    path = root / "guard.yaml"
    covers = None
    if path.exists() or path.is_symlink():
        engine = load_policy_engine()
        if engine is None:
            return ["cannot load the reference guard_policy.py to check guard.yaml"]
        try:
            covers = engine.parse_agent(read_text(path)).get("covers", [])
        except (ReadError, engine.PolicyError) as err:
            return [f"guard.yaml: {err}"]
    fails = []
    for cap in caps:
        try:
            text = read_text(root / "capabilities" / cap / "contract.md")
        except ReadError:
            continue  # reported by check_capability
        invariants = [m.group(1) for line in section(text, "Invariants") or [] for m in [INVARIANT.match(line)] if m]
        if "no_send" in invariants and (covers is None or "no_send" not in covers):
            fails.append(f"the contract of {cap} has no_send, so the agent needs a guard.yaml at its root that covers no_send")
    return fails


def check_activities(root, meta, caps):
    """activity_<name>: capabilities (or none); a schedule skill when any exist."""
    fails = []
    acts = {k[len("activity_"):]: v for k, v in meta.items() if k.startswith("activity_")}
    try:
        raw = read_text(root / "agent.yaml").splitlines()
    except ReadError:
        raw = []  # already reported
    seen = set()
    for line in raw:  # the same lines parse_agent_yaml reads: top-level keys only
        if not line.strip() or line.lstrip().startswith("#") or line[0] in " \t" or ":" not in line:
            continue
        key = line.split(":", 1)[0].strip()
        if not key.startswith("activity_"):
            continue
        if key in seen:
            fails.append(f"agent.yaml: {key} is declared more than once")
        seen.add(key)
    if acts and not (meta.get("catalog") and meta.get("catalog_repo")):
        fails.append("agent.yaml: activities need catalog and catalog_repo (the cloud environment installs the agent from its catalog)")
    for act, value in sorted(acts.items()):
        if not ACTIVITY.match(act):
            fails.append(f"agent.yaml: activity '{act}' is not kebab-case")
        names = [c.strip() for c in value.split(",") if c.strip()]
        if not names:
            fails.append(f"agent.yaml: activity_{act} lists no capabilities (use none)")
        if "none" in names and len(names) > 1:
            fails.append(f"agent.yaml: activity_{act} mixes none with capabilities")
        for cap in names:
            if cap != "none" and cap not in caps:
                fails.append(f"agent.yaml: activity_{act} uses {cap}, which is not in capabilities")
    if acts and not (root / "skills" / "schedule" / "SKILL.md").is_file():
        fails.append("missing skills/schedule/SKILL.md (agent.yaml declares activities)")
    return fails


def check_tools(root, meta):
    """Guard hook and engine, capability contracts, tools, guard policies."""
    fails = []
    try:
        hooks = json.loads(read_text(root / "hooks" / "hooks.json"))
    except (ReadError, json.JSONDecodeError):
        hooks = None  # already reported by check_runtime
    if hooks is not None and GUARD_COMMAND not in hook_commands(hooks, "PreToolUse", GUARD_MATCHER):
        fails.append(f"hooks/hooks.json: needs a PreToolUse command hook {GUARD_COMMAND} with matcher {GUARD_MATCHER}")
    fails.extend(check_reference_script(root, "hooks/guard.sh", REFERENCE_GUARD))
    fails.extend(check_reference_script(root, "hooks/guard_policy.py", REFERENCE_POLICY))
    fails.extend(check_reference_script(root, "hooks/schedule_check.py", REFERENCE_SCHEDULE))
    fails.extend(check_reference_script(root, "hooks/tool_check.py", REFERENCE_TOOLCHECK))
    caps = [c.strip() for c in meta.get("capabilities", "").split(",") if c.strip()]
    if caps:
        if not (root / "skills" / "add-tool" / "SKILL.md").is_file():
            fails.append("missing skills/add-tool/SKILL.md (agent.yaml lists capabilities)")
        else:
            fails.extend(check_reference_file(root, "skills/add-tool/SKILL.md", REFERENCE_ADD_TOOL))
    fails.extend(check_activities(root, meta, caps))
    for cap in caps:
        if not SNAKE.match(cap):
            fails.append(f"agent.yaml: capability '{cap}' is not snake_case")
            continue
        fails.extend(check_capability(root, cap))
    fails.extend(check_agent_policy(root, [c for c in caps if SNAKE.match(c)]))
    folder = root / "capabilities"
    if folder.is_dir():
        for d in sorted(folder.iterdir()):
            if d.is_dir() and d.name not in caps:
                fails.append(f"capabilities/{d.name} is not listed in agent.yaml capabilities")
    return fails


def check(root):
    fails = []
    try:
        meta = parse_agent_yaml(read_text(root / "agent.yaml"))
    except ReadError as err:
        fails.append(f"agent.yaml: {err}")
        meta = {}
    for key in REQUIRED_KEYS:
        if not meta.get(key):
            fails.append(f"agent.yaml: missing {key}")
    name, version, desc, std = (meta.get(k, "") for k in REQUIRED_KEYS)
    if name and not KEBAB.match(name):
        fails.append(f"agent.yaml: name '{name}' is not kebab-case")
    if version and not SEMVER.match(version):
        fails.append(f"agent.yaml: version '{version}' is not MAJOR.MINOR.PATCH")
    if std and std != CURRENT_STANDARD:
        fails.append(f"agent.yaml: standard '{std}' must be \"{CURRENT_STANDARD}\"")
    fails.extend(check_runtime(root, meta, name))
    fails.extend(check_tools(root, meta))

    manifests = {}
    for rel in ALL_MANIFESTS:
        path = root / rel
        if not path.is_file():
            fails.append(f"missing {rel}")
            continue
        try:
            data = json.loads(read_text(path))
        except ReadError as err:
            fails.append(f"{rel}: {err}")
            continue
        except json.JSONDecodeError as err:
            fails.append(f"{rel}: not valid JSON ({err.msg}, line {err.lineno})")
            continue
        if not isinstance(data, dict):
            fails.append(f"{rel}: must be a JSON object")
            continue
        manifests[rel] = data

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
        if not isinstance(agents, list) or not all(isinstance(a, str) for a in agents):
            fails.append(".claude-plugin/plugin.json: agents must be a list of file paths")
        else:
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
        rel = ".claude-plugin/marketplace.json"
        if market.get("name") != name:
            fails.append(f"{rel}: name {market.get('name')!r} does not match agent.yaml {name!r}")
        owner = market.get("owner")
        if owner is not None and not isinstance(owner, dict):
            fails.append(f"{rel}: owner must be an object")
        elif not (owner or {}).get("name"):
            fails.append(f"{rel}: missing owner.name")
        plugins = market.get("plugins")
        if plugins is None:
            plugins = []
        if not isinstance(plugins, list):
            fails.append(f"{rel}: plugins must be a list")
        else:
            bad = [i for i, p in enumerate(plugins) if not isinstance(p, dict)]
            for i in bad:
                fails.append(f"{rel}: plugins[{i}] must be an object")
            if not bad and (len(plugins) != 1 or plugins[0].get("name") != name
                            or plugins[0].get("source") != "./"):
                fails.append(f"{rel}: must hold exactly one plugin entry named {name!r} with source \"./\"")

    gemini = manifests.get("gemini-extension.json")
    if gemini is not None and gemini.get("contextFileName") != "AGENT.md":
        fails.append("gemini-extension.json: contextFileName must be \"AGENT.md\"")

    codex = manifests.get(".codex-plugin/plugin.json")
    if codex is not None and codex.get("skills") != "./skills/":
        fails.append(".codex-plugin/plugin.json: skills must be \"./skills/\"")

    return fails


def get(key, source):
    """Print agent.yaml's top-level `key` from a path or '-' (stdin)."""
    if source == "-":
        try:
            text = sys.stdin.buffer.read().decode("utf-8")
        except UnicodeDecodeError:
            text = ""
    else:
        path = pathlib.Path(source)
        try:
            text = read_text(path) if path.is_file() else ""
        except ReadError:
            text = ""
    print(parse_agent_yaml(text).get(key, ""))


def main(argv):
    if len(argv) == 3 and argv[0] == "--get":
        get(argv[1], argv[2])
        return 0
    if len(argv) != 1:
        print("FAIL: usage: check_manifests.py <agent-dir> | --get <key> <agent.yaml|->")
        return 2
    for message in check(pathlib.Path(argv[0])):
        print(f"{'WARN' if isinstance(message, Warn) else 'FAIL'}: {message}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as err:  # never a traceback; the caller treats exit 3 as a crash
        print(f"FAIL: manifest checker error: {type(err).__name__}: {err}")
        sys.exit(3)
