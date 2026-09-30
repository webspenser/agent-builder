#!/usr/bin/env python3
"""Agent Standard guard-policy engine — identical in every agent.

Usage:
  guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]   hook input JSON on stdin
  guard_policy.py --check <guard.yaml>                                      parse only

Decides one PreToolUse call against one tool's guard policy: exit 2 blocks
(stderr says why), exit 0 allows. Any error blocks — a bug fails closed.
With server_match, `allow` only counts a tool-name suffix whose server segment
(the text between the previous "__" and that suffix's "__") contains it, so
"mcp__attio__purge__get-x" cannot ride on `allow: [get-*]`; `deny` still checks
every suffix. Without it, `allow` considers every suffix.
The policy format is a strict YAML subset (a `writes:` list says where values
sit; `rules:` constrain them); see STANDARD.md "Guard policy".
"""
import fnmatch
import json
import re
import sys
import unicodedata

KEYS = ("covers", "allow", "deny", "writes", "unwrap", "unknown_writes", "refuse_keys", "rules")
LIST_KEYS = ("covers", "allow", "deny", "unwrap", "refuse_keys")
OLD_KEYS = ("create_tools", "update_tools", "values_at")  # Agent Standard 3 keys
RULE_KEYS = ("field", "binding_id", "create", "update", "any")
WRITE_KEYS = ("kind", "tools", "at")
REFUSE_PRESETS = {
    "uuid": re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I),
}
KEY_LINE = re.compile(r"^([a-z_]+):(?: (.*))?$")
SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")
PATH = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[\])?(\.[A-Za-z_][A-Za-z0-9_]*(\[\])?)*$")
BINDING_LINE = re.compile(r"^([a-z_][a-z0-9_]*):\s*(\S.*?)\s*$")
BARE_ID = re.compile(r"^[A-Za-z0-9_.-]+$")


class PolicyError(Exception):
    """The policy file or the call cannot be checked."""


# ---- parsing ---------------------------------------------------------------

def _strip_comment(text, lineno):
    out, quote = [], None
    for ch in text:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#":
            if out and not out[-1].isspace():
                raise PolicyError(f"line {lineno}: '#' must follow whitespace to start a comment")
            break
        out.append(ch)
    if quote:
        raise PolicyError(f"line {lineno}: unterminated quote")
    return "".join(out).rstrip()


def _scalar(token, lineno):
    token = token.strip()
    if not token:
        raise PolicyError(f"line {lineno}: empty value")
    if token[0] in "'\"":
        if len(token) < 2 or token[-1] != token[0]:
            raise PolicyError(f"line {lineno}: bad quoted value {token}")
        body = token[1:-1]
        if token[0] in body:
            raise PolicyError(f"line {lineno}: quoted value {token} contains its own quote or a second value")
        if token[0] == '"' and "\\" in body:
            raise PolicyError(f"line {lineno}: backslashes are not allowed in double quotes; use single quotes")
        return body
    if token[0] in "*&!|>%@`" or any(c in token for c in "[]{}") or ": " in token:
        raise PolicyError(f"line {lineno}: value {token!r} must be quoted")
    if token.startswith(("- ", "? ", ":", ",")) or token in ("-", "?") or token.endswith(":"):
        raise PolicyError(f"line {lineno}: value {token!r} must be quoted")
    if "'" in token or '"' in token:
        raise PolicyError(f"line {lineno}: value {token!r} mixes quotes with plain text; quote the whole value")
    return token


def _flow_list(text, lineno):
    text = text.strip()
    if not (text.startswith("[") and text.endswith("]")):
        raise PolicyError(f"line {lineno}: expected a list like [a, b]")
    items, cur, quote = [], "", None
    for ch in text[1:-1]:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            cur += ch
        elif ch == ",":
            items.append(cur)
            cur = ""
        elif ch in "[]{}":
            raise PolicyError(f"line {lineno}: nested lists and maps are not allowed")
        else:
            cur += ch
    if cur.strip() or items:
        items.append(cur)
    return [_scalar(item, lineno) for item in items]


def _parse_items(lines, i, name, allowed):
    items = []
    while i < len(lines):
        lineno = i + 1
        raw = lines[i]
        if "\t" in raw:
            raise PolicyError(f"line {lineno}: tabs are not allowed")
        line = _strip_comment(raw, lineno)
        if not line.strip():
            i += 1
            continue
        if not line.startswith(" "):
            break
        if line.startswith("  - "):
            items.append({})
            body = line[4:]
        elif line.startswith("    ") and items and not line[4:5].isspace():
            body = line[4:]
        else:
            raise PolicyError(f"line {lineno}: {name} items are '  - key: value' with further keys indented 4 spaces")
        m = KEY_LINE.match(body)
        if not m:
            raise PolicyError(f"line {lineno}: expected 'key: value'")
        key, value = m.group(1), (m.group(2) or "").strip()
        if key not in allowed:
            raise PolicyError(f"line {lineno}: unknown {name} key '{key}'")
        if key in items[-1]:
            raise PolicyError(f"line {lineno}: duplicate {name} key '{key}'")
        if value.startswith("["):
            items[-1][key] = _flow_list(value, lineno)
        else:
            items[-1][key] = _scalar(value, lineno)
        i += 1
    if not items:
        raise PolicyError(f"{name}: has no items")
    return items, i


def _validate(policy):
    if "covers" not in policy:
        raise PolicyError("covers is required")
    for key in LIST_KEYS:
        if key in policy and not isinstance(policy[key], list):
            raise PolicyError(f"{key} must be a list like [a, b]")
    if not policy["covers"]:
        raise PolicyError("covers must name at least one invariant")
    for inv in policy["covers"]:
        if not SNAKE.match(inv):
            raise PolicyError(f"covers: '{inv}' is not a snake_case invariant id")
    if policy.get("unknown_writes", "update") not in ("update", "block"):
        raise PolicyError("unknown_writes must be update or block")
    for preset in policy.get("refuse_keys", []):
        if preset not in REFUSE_PRESETS:
            raise PolicyError(f"refuse_keys: unknown preset '{preset}'")
    for key in ("allow", "deny", "unwrap"):
        for item in policy.get(key, []):
            if not item:
                raise PolicyError(f"{key}: empty entry")
    for entry in policy.get("writes", []):
        if entry.get("kind") not in ("create", "update"):
            raise PolicyError("writes: kind must be create or update")
        for k in ("tools", "at"):
            if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
                raise PolicyError(f"writes: each entry needs a non-empty {k} list")
        for path in entry["at"]:
            if not PATH.match(path):
                raise PolicyError(f"writes: {path} is not a path like values or \"records[].fields\"")
    if ("rules" in policy or "refuse_keys" in policy) and not policy.get("writes"):
        raise PolicyError("writes is required when rules or refuse_keys are present")
    if "rules" in policy:
        for rule in policy["rules"]:
            if not isinstance(rule.get("field"), str) or not rule["field"]:
                raise PolicyError("each rule needs a field")
            if rule.get("binding_id", "required") != "required":
                raise PolicyError("binding_id may only be 'required'")
            lists = [k for k in ("create", "update", "any") if k in rule]
            if not lists:
                raise PolicyError(f"rule for {rule['field']} needs create, update, or any")
            for k in lists:
                if not isinstance(rule[k], list) or not rule[k]:
                    raise PolicyError(f"rule for {rule['field']}: {k} must be a non-empty list")


def parse(text):
    """Parse and validate a guard.yaml text. Raises PolicyError."""
    lines = text.splitlines()
    policy, i = {}, 0
    while i < len(lines):
        lineno = i + 1
        raw = lines[i]
        if "\t" in raw:
            raise PolicyError(f"line {lineno}: tabs are not allowed")
        line = _strip_comment(raw, lineno)
        if not line.strip():
            i += 1
            continue
        m = KEY_LINE.match(line)
        if line[0] == " " or not m:
            raise PolicyError(f"line {lineno}: expected 'key: value' at column 0")
        key, value = m.group(1), (m.group(2) or "").strip()
        if key in OLD_KEYS:
            raise PolicyError(f'{key} is the Agent Standard 3 form; 4.0 uses writes: (see STANDARD.md "Guard policy")')
        if key not in KEYS:
            raise PolicyError(f"line {lineno}: unknown key '{key}'")
        if key in policy:
            raise PolicyError(f"line {lineno}: duplicate key '{key}'")
        i += 1
        if key in ("rules", "writes"):
            if value:
                raise PolicyError(f"line {lineno}: {key}: takes '  - ...' items on the following lines")
            policy[key], i = _parse_items(lines, i, key, RULE_KEYS if key == "rules" else WRITE_KEYS)
            continue
        if not value:
            raise PolicyError(f"line {lineno}: {key} has no value")
        if value.startswith("["):
            while not value.endswith("]"):
                if i >= len(lines) or not lines[i].startswith(" "):
                    raise PolicyError(f"line {lineno}: unclosed '['")
                if "\t" in lines[i]:
                    raise PolicyError(f"line {i + 1}: tabs are not allowed")
                value += " " + _strip_comment(lines[i], i + 1).strip()
                i += 1
            policy[key] = _flow_list(value, lineno)
        else:
            policy[key] = _scalar(value, lineno)
    if not policy:
        raise PolicyError("the policy is empty")
    _validate(policy)
    return policy


# ---- deciding a call -------------------------------------------------------

def _norm(name):
    return re.sub(r"[\s-]+", "_", str(name).strip().lower())


def _candidates(tool_name):
    """(suffix, server segment) for every suffix after a '__'; the server
    segment is the text between the previous '__' and this one."""
    if not isinstance(tool_name, str) or not tool_name.startswith("mcp__"):
        raise PolicyError("not an MCP tool name")
    rest, found, at = tool_name[5:], [], 0
    while True:
        at = rest.find("__", at)
        if at < 0:
            break
        if rest[at + 2:]:
            found.append((rest[at + 2:].lower(), rest[:at].rsplit("__", 1)[-1].lower()))
        at += 2
    if not found:
        raise PolicyError("no tool name after the server")
    return found


def _matches(candidates, patterns):
    return any(fnmatch.fnmatchcase(c, p.lower()) for c in candidates for p in patterns)


def _maps_at(obj, path):
    nodes = [obj]
    for part in path.split("."):
        many = part.endswith("[]")
        name = part[:-2] if many else part
        nxt = []
        for node in nodes:
            if not isinstance(node, dict):
                raise PolicyError(f"{path}: unexpected shape at {name}")
            if name not in node:
                continue
            value = node[name]
            if many:
                if not isinstance(value, list):
                    raise PolicyError(f"{path}: {name} is not a list")
                nxt.extend(value)
            else:
                nxt.append(value)
        nodes = nxt
    for node in nodes:
        if not isinstance(node, dict):
            raise PolicyError(f"{path}: attribute values are not an object")
    return nodes


def _leaves(value, unwrap):
    if isinstance(value, list):
        return [leaf for item in value for leaf in _leaves(item, unwrap)]
    if isinstance(value, dict):
        if any(key not in unwrap for key in value):
            raise PolicyError("unrecognized value shape")
        leaves = [leaf for key in unwrap if key in value for leaf in _leaves(value[key], unwrap)]
        if not leaves:
            raise PolicyError("unrecognized value shape")
        return leaves
    if isinstance(value, bool):
        return ["true" if value else "false"]
    if value is None:
        return ["null"]
    return [str(value).strip().lower()]


def read_bindings(path):
    if path == "-":
        return {}
    data = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = BINDING_LINE.match(line.rstrip("\r\n"))
            if not m:
                continue
            key, value = m.group(1), m.group(2)
            if key.startswith("field_"):
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "`'\"":
                    value = value[1:-1]
                if not BARE_ID.match(value):
                    shown = "".join(c for c in m.group(2) if c.isprintable())[:60]
                    raise PolicyError(f"bindings: {key} must be a bare ID, got {shown}")
            data[key] = value
    return data


def problems(policy, event, bindings, server_match=None):
    tool_name = event.get("tool_name")
    pairs = _candidates(tool_name)
    names = [suffix for suffix, _ in pairs]
    if server_match:
        wanted = server_match.lower()
        allow_names = [suffix for suffix, server in pairs if wanted in server]
    else:
        allow_names = names
    shown = names[0]
    for pattern in policy.get("deny", []):
        if _matches(names, [pattern]):
            return [f"{shown} is denied ({pattern})"]
    if "allow" in policy and not _matches(allow_names, policy["allow"]):
        return [f"{shown} is not in the allow list"]
    rules = policy.get("rules", [])
    refuse = [REFUSE_PRESETS[p] for p in policy.get("refuse_keys", [])]
    if not rules and not refuse:
        return []
    writes = policy.get("writes", [])
    matched = [w for w in writes if _matches(names, w["tools"])]
    args = event.get("tool_input")
    if not isinstance(args, dict):
        if matched:
            raise PolicyError("tool_input is not an object")
        return []
    tagged = [(w["kind"], m) for w in matched for path in w["at"] for m in _maps_at(args, path)]
    if not matched:
        loose = [m for w in writes for path in w["at"] for m in _maps_at(args, path)]
        if not loose:
            return []
        if policy.get("unknown_writes", "update") == "block":
            return [f"{shown} writes values but is not a known create or update tool"]
        tagged = [("update", m) for m in loose]
    else:
        own = {path for w in matched for path in w["at"]}
        for w in writes:
            for path in w["at"]:
                if path in own:
                    continue
                stray = _maps_at(args, path)
                if not stray:
                    continue
                if policy.get("unknown_writes", "update") == "block":
                    return [f"{shown} writes values at {path}, which no writes entry for this tool lists"]
                tagged += [("update", m) for m in stray]
    found = []
    ids = {}
    for rule in rules:
        field = _norm(rule["field"])
        bound = bindings.get(f"field_{field}")
        if rule.get("binding_id") == "required" and not bound:
            found.append(f"the probe has not recorded field_{field} in bindings; re-run setup's tools step")
        ids[field] = {field} | ({_norm(bound)} if bound else set())
    unwrap = policy.get("unwrap", [])
    for kind, amap in tagged:
        for key in amap:
            if any(unicodedata.category(ch) == "Cf" for ch in str(key)):
                raise PolicyError("attribute key contains invisible characters")
            if any(p.match(str(key)) for p in refuse):
                found.append(f"attribute {key} is addressed by ID; use its name")
        for rule in rules:
            field = _norm(rule["field"])
            allowed = rule.get(kind) or rule.get("any")
            if not allowed:
                continue
            for key, value in amap.items():
                if _norm(key) not in ids[field]:
                    continue
                if _leaves(value, unwrap) not in [[a.lower()] for a in allowed]:
                    found.append(f"{rule['field']} may only be written as {', '.join(allowed)} on {kind}")
    return found


def main(argv):
    if len(argv) == 2 and argv[0] == "--check":
        try:
            with open(argv[1], encoding="utf-8") as fh:
                parse(fh.read())
        except Exception as err:  # never a traceback
            print(f"FAIL: {type(err).__name__}: {err}")
            return 1
        return 0
    if len(argv) not in (2, 3, 4):
        print("usage: guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match] | --check <guard.yaml>", file=sys.stderr)
        return 2
    label = argv[2] if len(argv) >= 3 else "guard policy"
    server_match = argv[3] if len(argv) == 4 else None
    try:
        with open(argv[0], encoding="utf-8") as fh:
            policy = parse(fh.read())
        bindings = read_bindings(argv[1])
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise PolicyError("hook input is not an object")
        found = problems(policy, event, bindings, server_match)
    except Exception as err:  # fail closed
        print(f"Blocked by {label}: cannot check this call ({type(err).__name__}: {err})", file=sys.stderr)
        return 2
    for problem in dict.fromkeys(found):
        print(f"Blocked by {label}: {problem}", file=sys.stderr)
    return 2 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
