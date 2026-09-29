#!/usr/bin/env python3
"""Agent Standard 1.0 manifest checks.

Usage: check_manifests.py <agent-dir>
       check_manifests.py --get <key> <agent.yaml | ->
The first form prints one 'FAIL: <message>' line per problem and exits 0;
bin/validate-agent.sh counts the lines and treats any other exit status as
a crash. The second prints one parsed top-level value from agent.yaml (or
stdin, with '-'), or nothing when the key is absent.
"""
import json
import os
import pathlib
import re
import sys

REQUIRED_KEYS = ("name", "version", "description", "standard")
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SUPPORTED_STANDARD = re.compile(r"^1\.\d+$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
HOOK_COMMAND = '"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"'
REFERENCE_HOOK = pathlib.Path(__file__).resolve().parents[2] / "_template" / "hooks" / "session-start.sh"
IDENTITY_MANIFESTS = (".claude-plugin/plugin.json", "gemini-extension.json", ".codex-plugin/plugin.json")
ALL_MANIFESTS = IDENTITY_MANIFESTS + (".claude-plugin/marketplace.json",)


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
    if std and not SUPPORTED_STANDARD.match(std):
        fails.append(f"agent.yaml: standard '{std}' is not supported (this validator understands 1.x)")
    if std and SUPPORTED_STANDARD.match(std) and int(std.split(".")[1]) >= 1:
        fails.extend(check_v11(root, meta, name))

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
        print(f"FAIL: {message}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as err:  # never a traceback; the caller treats exit 3 as a crash
        print(f"FAIL: manifest checker error: {type(err).__name__}: {err}")
        sys.exit(3)
