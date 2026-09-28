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
import pathlib
import re
import sys

REQUIRED_KEYS = ("name", "version", "description", "standard")
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SUPPORTED_STANDARD = re.compile(r"^1\.\d+$")
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
