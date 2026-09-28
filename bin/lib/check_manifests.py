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
