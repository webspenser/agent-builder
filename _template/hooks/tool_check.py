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
import fnmatch
import json
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
IDENTITY_KEYS = ("capability", "provider", "server_match", "wrapper")
KEBAB = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
SERVER_MATCH = re.compile(r"[a-z0-9_-]+")
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")  # C0 controls and DEL other than tab, LF, CR
OPERATION = re.compile(r"^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`")
INVARIANT = re.compile(r"^[-*]\s+`([^`]+)`")
ACCEPTABLE = re.compile(r"^[-*]\s+`([^`]+)`\s+\(acceptable\)")
N8N_TRIGGER = "@n8n/n8n-nodes-langchain.mcpTrigger"
N8N_AUTH = ("n8nOAuth2", "bearerAuth", "headerAuth")
TOOL_NAME = re.compile(r"[a-z][a-z0-9_]*")
N8N_DISPATCHER_TOOLS = ("execute_workflow", "create_workflow_from_code", "update_workflow", "archive_workflow",
                        "publish_workflow", "unpublish_workflow", "test_workflow", "restore_workflow_version")
CALLER_SET = re.compile(r"(?i)\$fromai")
PLACEHOLDER = re.compile(r"(?<!\{)\{[A-Za-z_][A-Za-z0-9_]*\}(?!\})")
LITERAL_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")


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


def acceptable(text):
    """Invariant ids under ## Invariants marked (acceptable): an instance may accept them as instruction-only."""
    return {m.group(1) for line in section(text, "Invariants") or [] for m in [ACCEPTABLE.match(line)] if m}


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
            fails.append(f"{rel}: unknown key '{key}' (identity.yaml holds capability, provider, server_match, wrapper)")
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


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for value in obj.values():
            yield from _strings(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _strings(value)


def dispatchers_not_denied(deny):
    """n8n instance-level tools that run or rebuild any workflow and that no deny pattern matches."""
    patterns = [p.lower() for p in deny]
    return [t for t in N8N_DISPATCHER_TOOLS if not any(fnmatch.fnmatchcase(t, p) for p in patterns)]


def _caller_set(params, path=""):
    """Paths under a tool node's parameters where the caller sets a URL, method or request body."""
    found = []
    items = params.items() if isinstance(params, dict) else enumerate(params) if isinstance(params, list) else []
    for key, value in items:
        here = f"{path}.{key}" if path and isinstance(key, str) else (key if isinstance(key, str) else path)
        name = key.lower() if isinstance(key, str) else ""
        if isinstance(value, str):
            risky = name.endswith("url") or name in ("method", "jsonbody", "body")
            if risky and (CALLER_SET.search(value) or (name.endswith("url") and PLACEHOLDER.search(value))):
                found.append(here)
        else:
            found.extend(_caller_set(value, here))
    return found


def check_workflow(folder, label, server_match, usage_text):
    """FAIL messages for a wrapped tool's workflow.n8n.json (an n8n workflow export)."""
    rel = f"{label}/workflow.n8n.json"
    path = folder / "workflow.n8n.json"
    if not path.is_file():
        return [f"missing {rel} (identity.yaml says wrapper: n8n)"]
    try:
        wf = json.loads(read(path))
    except (ToolError, ValueError) as err:
        return [f"{rel}: not valid JSON ({err})"]
    nodes = wf.get("nodes") if isinstance(wf, dict) else None
    conns = wf.get("connections") if isinstance(wf, dict) else None
    if not isinstance(nodes, list) or not isinstance(conns, dict) or not all(isinstance(n, dict) for n in nodes):
        return [f"{rel}: needs a nodes list and a connections object (an n8n workflow export)"]
    if not all(isinstance(n.get("name"), str) for n in nodes):
        return [f"{rel}: every node needs a text name"]
    triggers = [n for n in nodes if n.get("type") == N8N_TRIGGER]
    if len(triggers) != 1:
        return [f"{rel}: needs exactly one MCP Server Trigger node ({N8N_TRIGGER}), found {len(triggers)}"]
    trigger, fails = triggers[0], []
    params = trigger.get("parameters")
    auth = params.get("authentication") if isinstance(params, dict) else None
    if auth not in N8N_AUTH:
        fails.append(f"{rel}: the MCP Server Trigger must require n8n OAuth2, Bearer or Header auth (authentication is {auth!r})")
    tools = set()
    for source, outputs in conns.items():
        groups = outputs.get("ai_tool", []) if isinstance(outputs, dict) else []
        for group in groups if isinstance(groups, list) else []:
            for link in group if isinstance(group, list) else []:
                if isinstance(link, dict) and link.get("node") == trigger.get("name"):
                    tools.add(source)
    if not tools:
        fails.append(f"{rel}: the MCP Server Trigger exposes no tools")
    by_name = {n.get("name"): n for n in nodes}
    for name in sorted(tools):
        if not TOOL_NAME.fullmatch(name):
            fails.append(f"{rel}: tool node {name!r} must be named in snake_case (the name is the MCP tool name)")
        for where in _caller_set((by_name.get(name) or {}).get("parameters")):
            fails.append(f"{rel}: tool {name} lets the caller set its {where}; fix it in the workflow")
    mapped = set(re.findall(rf"(?<![A-Za-z0-9_-]){re.escape(server_match)}:([A-Za-z0-9_]+)", usage_text)) if server_match else set()
    for name in sorted(tools - mapped):
        fails.append(f"{rel}: tool {name} is not mapped in usage.md as {server_match}:{name}")
    for name in sorted(mapped - tools):
        fails.append(f"{label}/usage.md: `{server_match}:{name}` is not a tool of the workflow's MCP Server Trigger")
    if any(LITERAL_BEARER.search(text) for text in _strings(wf)):
        fails.append(f"{rel}: holds a literal bearer token; keep secrets in n8n credentials")
    return fails


def check_tool(folder, cap, ops, invariants, custom=False, label=None):
    """(FAIL messages, identity dict) for one tool folder. Never raises for bad content."""
    label = label or str(folder)
    fails, identity = [], {}
    if not custom and not KEBAB.fullmatch(folder.name):
        fails.append(f"{label}: tool folder name is not kebab-case")
    if not custom and folder.name == "custom":
        fails.append(f"{label}: 'custom' is reserved for an instance's own tool (bind_<cap>: custom); choose another tool name")

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
            wrapper = identity.get("wrapper")
            if wrapper is not None and wrapper != "n8n":
                fails.append(f"{rel}: wrapper must be n8n (got {wrapper!r})")

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

    if identity.get("wrapper") == "n8n" and usage.is_file():
        try:
            usage_text = read(usage)
        except ToolError:
            usage_text = ""  # already reported
        fails.extend(check_workflow(folder, label, identity.get("server_match", ""), usage_text))

    if (folder / "bootstrap.py").exists() and usage.is_file():
        try:
            has_setup = section(read(usage), "Setup") is not None
        except ToolError:
            has_setup = True  # the unreadable usage.md is already reported
        if not has_setup:
            fails.append(f"{label}/usage.md: needs a ## Setup section "
                         "(bootstrap.py is optional; people must be able to create the fields by hand)")

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
                err_str = str(err)
                # Special case: if error is about empty covers and contract has no_send, report no_send error instead
                if "covers must name at least one invariant" in err_str and "no_send" in invariants:
                    fails.append(f"{label}/guard.yaml: covers must include no_send")
                else:
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
    parent = folder.absolute().parent  # not resolve(): a symlinked folder keeps its place, as in schedule_check
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
    cap = folder.absolute().name if custom else parent.parent.name
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
