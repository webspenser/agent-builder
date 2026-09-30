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
