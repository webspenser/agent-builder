#!/usr/bin/env python3
"""Agent Standard guard-policy engine — identical in every agent.

Usage:
  guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]   hook input JSON on stdin
  guard_policy.py --agent <guard.yaml> [label] [--exempt <server_match>]... agent policy; hook input on stdin
  guard_policy.py --exempt-caps <agent guard.yaml>                          print each exempt capability
  guard_policy.py --covers <tool guard.yaml>                                print each covers id
  guard_policy.py --check [--agent] <guard.yaml>                            parse only

Decides one PreToolUse call against one tool's guard policy (or, with
--agent, against the agent guard policy: deny-only, every server): exit 2 blocks
(stderr says why), exit 0 allows. Any error blocks — a bug fails closed.
With server_match, `allow` only counts a tool-name suffix whose server segment
(the text between the previous "__" and that suffix's "__") contains it, so
"mcp__attio__purge__get-x" cannot ride on `allow: [get-*]`; `deny` still checks
every suffix. Without it, `allow` considers every suffix.
The policy format is a strict YAML subset (a `writes:` list says where values
sit; `rules:` constrain them; `recipients:` pins send arguments to values recorded
in bindings); see STANDARD.md "Guard policy".
"""
import fnmatch
import json
import re
import sys
import unicodedata

KEYS = ("covers", "allow", "deny", "writes", "unwrap", "unknown_writes", "refuse_keys", "bound_keys_only",
        "rules", "recipients", "refuse_args")
AGENT_KEYS = ("covers", "deny", "exempt")
LIST_KEYS = ("covers", "allow", "deny", "unwrap", "refuse_keys", "refuse_args")
ARG_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
RULE_KEYS = ("field", "forbid", "create", "update", "any")
WRITE_KEYS = ("kind", "tools", "at")
RECIPIENT_KEYS = ("tools", "at", "bound")
REFUSE_PRESETS = {
    "uuid": re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I),
}
KEY_LINE = re.compile(r"^([a-z_]+):(?: (.*))?$")
SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")
SERVER_MATCH = re.compile(r"^[a-z0-9_-]+$")
PATH = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[\])?(\.[A-Za-z_][A-Za-z0-9_]*(\[\])?)*$")
BINDING_LINE = re.compile(r"^([a-z_][a-z0-9_]*):\s*(\S.*?)\s*$")
BARE_ID = re.compile(r"^[A-Za-z0-9_.-]+$")
BARE_VALUE = re.compile(r"^[^\s<>\"',;]+$")


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
        i += 1
        if value.startswith("["):
            while not value.endswith("]"):
                if i >= len(lines):
                    raise PolicyError(f"line {lineno}: unclosed '['")
                if "\t" in lines[i]:
                    raise PolicyError(f"line {i + 1}: tabs are not allowed")
                more = _strip_comment(lines[i], i + 1)
                if more.strip() and not more.startswith("    "):
                    raise PolicyError(f"line {lineno}: unclosed '[' (line {i + 1} continues it indented less than 4 spaces)")
                if KEY_LINE.match(more.strip()):
                    raise PolicyError(f"line {lineno}: unclosed '[' (line {i + 1} starts a new key)")
                value += " " + more.strip()
                i += 1
            items[-1][key] = _flow_list(value, lineno)
        else:
            items[-1][key] = _scalar(value, lineno)
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
    if policy.get("bound_keys_only", "true") != "true":
        raise PolicyError("bound_keys_only may only be true")
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
    for entry in policy.get("recipients", []):
        for k in ("tools", "at"):
            if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
                raise PolicyError(f"recipients: each entry needs a non-empty {k} list")
        for path in entry["at"]:
            if not PATH.match(path):
                raise PolicyError(f"recipients: {path} is not a path like to or \"message.to\"")
        if not isinstance(entry.get("bound"), str) or not SNAKE.match(entry["bound"]):
            raise PolicyError("recipients: bound must be a snake_case binding key")
    if "refuse_args" in policy:
        if not policy["refuse_args"]:
            raise PolicyError("refuse_args must name at least one argument")
        for name in policy["refuse_args"]:
            if not ARG_NAME.match(name):
                raise PolicyError(f"refuse_args: '{name}' is not an argument name")
    if ("rules" in policy or "refuse_keys" in policy or "bound_keys_only" in policy) and not policy.get("writes"):
        raise PolicyError("writes is required when rules, refuse_keys or bound_keys_only are present")
    if "rules" in policy:
        for rule in policy["rules"]:
            if not isinstance(rule.get("field"), str) or not rule["field"]:
                raise PolicyError("each rule needs a field")
            lists = [k for k in ("create", "update", "any") if k in rule]
            if "forbid" in rule:
                if rule["forbid"] not in ("true", "update"):
                    raise PolicyError(f"rule for {rule['field']}: forbid may only be true or update")
                if lists:
                    raise PolicyError(f"rule for {rule['field']}: forbid cannot be combined with create, update, or any")
                continue
            if not lists:
                raise PolicyError(f"rule for {rule['field']} needs forbid, create, update, or any")
            for k in lists:
                if not isinstance(rule[k], list) or not rule[k]:
                    raise PolicyError(f"rule for {rule['field']}: {k} must be a non-empty list")


def parse(text):
    """Parse and validate a tool's guard.yaml text. Raises PolicyError."""
    policy = _read(text, KEYS)
    _validate(policy)
    return policy


def parse_agent(text):
    """Parse and validate an agent guard policy (the package-root guard.yaml)."""
    policy = _read(text, AGENT_KEYS)
    deny = policy.get("deny")
    if not isinstance(deny, list) or not deny or not all(deny):
        raise PolicyError("deny must be a non-empty list of tool-name patterns")
    covers = policy.get("covers", [])
    if not isinstance(covers, list):
        raise PolicyError("covers must be a list like [a, b]")
    for inv in covers:
        if not SNAKE.match(inv):
            raise PolicyError(f"covers: '{inv}' is not a snake_case invariant id")
    exempt = policy.get("exempt")
    if exempt is not None:
        if not isinstance(exempt, list) or not exempt:
            raise PolicyError("exempt must be a non-empty list of capability names")
        for cap in exempt:
            if not SNAKE.match(cap):
                raise PolicyError(f"exempt: '{cap}' is not a snake_case capability name")
    return policy


def _read(text, keys):
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
        if key not in keys:
            raise PolicyError(f"line {lineno}: unknown key '{key}'")
        if key in policy:
            raise PolicyError(f"line {lineno}: duplicate key '{key}'")
        i += 1
        if key in ("rules", "writes", "recipients"):
            if value:
                raise PolicyError(f"line {lineno}: {key}: takes '  - ...' items on the following lines")
            allowed = {"rules": RULE_KEYS, "writes": WRITE_KEYS, "recipients": RECIPIENT_KEYS}[key]
            policy[key], i = _parse_items(lines, i, key, allowed)
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
    return policy


# ---- deciding a call -------------------------------------------------------

def _norm(name):
    return re.sub(r"[\s-]+", "_", str(name).strip().lower())


def _arg_key(name):
    # draftId, draft_id, DRAFT-ID and draftid are one argument to a protobuf-JSON server.
    return re.sub(r"[_-]", "", name).lower()


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


def _walk(obj, path):
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
    return nodes


def _maps_at(obj, path):
    nodes = _walk(obj, path)
    for node in nodes:
        if not isinstance(node, dict):
            raise PolicyError(f"{path}: attribute values are not an object")
    return nodes


def _addresses_at(obj, path):
    """Recipient strings at path: a string is one, a list of strings is its items, null is absent."""
    out = []
    for node in _walk(obj, path):
        if node is None:
            continue
        if isinstance(node, str):
            out.append(node)
        elif isinstance(node, list) and all(isinstance(x, str) for x in node):
            out.extend(node)
        else:
            raise PolicyError(f"{path}: a recipient must be a string or a list of strings")
    return out


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
    """Every `key: value` line, each key mapped to the set of its values (a key may repeat)."""
    if path == "-":
        return {}
    data = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = BINDING_LINE.match(line.rstrip("\r\n"))
            if not m:
                continue
            key, value = m.group(1), m.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "`'\"":
                value = value[1:-1]
            if key.startswith("field_") and not BARE_ID.match(value):
                shown = "".join(c for c in m.group(2) if c.isprintable())[:60]
                raise PolicyError(f"bindings: {key} must be a bare ID, got {shown}")
            data.setdefault(key, set()).add(value)
    return data


def _printable(value):
    return "".join(c for c in str(value) if c.isprintable())[:80]


def _recipient_problems(shown, entry, args, bindings):
    values = [v for path in entry["at"] for v in _addresses_at(args, path)]
    if not values:
        return [f"{shown} names no recipient at {', '.join(entry['at'])}"]
    bound = entry["bound"]
    pinned = bindings.get(bound) or set()
    if not pinned:
        return [f"no {bound} line in bindings; re-run setup's tools step"]
    if not all(BARE_VALUE.match(p) for p in pinned):
        return [f"{bound} must be a bare value"]
    allowed = {p.strip().lower() for p in pinned}
    return [f"{_printable(v)} is not a pinned recipient ({bound})"
            for v in values if v.strip().lower() not in allowed]


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
    args = event.get("tool_input")
    early = []
    if isinstance(args, dict):
        refused = {_arg_key(name) for name in policy.get("refuse_args", [])}
        for key, value in args.items():
            if _arg_key(key) in refused and value not in (None, ""):
                early.append(f"{shown} may not use {key}")
    for entry in policy.get("recipients", []):
        if not _matches(names, entry["tools"]):
            continue
        if not isinstance(args, dict):
            raise PolicyError("tool_input is not an object")
        early.extend(_recipient_problems(shown, entry, args, bindings))
    if early:
        return early
    rules = policy.get("rules", [])
    refuse = [REFUSE_PRESETS[p] for p in policy.get("refuse_keys", [])]
    keyed = policy.get("bound_keys_only") == "true"
    if not rules and not refuse and not keyed:
        return []
    writes = policy.get("writes", [])
    matched = [w for w in writes if _matches(names, w["tools"])]
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
    recorded = {_norm(i) for k, v in bindings.items() if k.startswith("field_") for i in v}
    ids = {}
    for rule in rules:
        field = _norm(rule["field"])
        ids[field] = {field} | {_norm(i) for i in bindings.get(f"field_{field}", ())}
    unwrap = policy.get("unwrap", [])
    if keyed and not recorded and any(amap for _, amap in tagged):
        found.append("the probe has not recorded any field IDs in bindings; re-run setup's tools step")
        keyed = False  # one message is enough
    for kind, amap in tagged:
        for key in amap:
            if any(unicodedata.category(ch) == "Cf" for ch in str(key)):
                raise PolicyError("attribute key contains invisible characters")
            if any(p.match(str(key)) for p in refuse):
                found.append(f"attribute {key} is addressed by ID; use its name")
            if keyed and _norm(key) not in recorded:
                found.append(f"{key} is not a recorded field ID; re-run the probe (setup's tools step)")
        for rule in rules:
            field = _norm(rule["field"])
            forbid = rule.get("forbid")
            if forbid:
                if forbid == "true" or kind == "update":
                    if any(_norm(key) in ids[field] for key in amap):
                        found.append(f"{rule['field']} may not be written" if forbid == "true"
                                     else f"{rule['field']} may not be changed after create")
                continue
            allowed = rule.get(kind) or rule.get("any")
            if not allowed:
                continue
            for key, value in amap.items():
                if _norm(key) not in ids[field]:
                    continue
                if _leaves(value, unwrap) not in [[a.lower()] for a in allowed]:
                    found.append(f"{rule['field']} may only be written as {', '.join(allowed)} on {kind}")
    return found


def agent_problems(policy, event, exempt=()):
    """The agent policy: deny patterns over every suffix, whatever the server,
    except on a server exempted for an owner_only_send capability (guard.sh decides which)."""
    tool_name = event.get("tool_name")
    names = [suffix for suffix, _ in _candidates(tool_name)]
    rest = tool_name[5:].lower()
    for match in exempt:
        if not SERVER_MATCH.match(match):
            raise PolicyError(f"exempt server_match {match!r} is not [a-z0-9_-]+")
    if any(match in rest for match in exempt):
        return []
    for pattern in policy["deny"]:
        if _matches(names, [pattern]):
            return [f"{names[0]} is denied ({pattern})"]
    return []


def _print_list(path, parser, key):
    try:
        with open(path, encoding="utf-8") as fh:
            values = parser(fh.read()).get(key, [])
    except Exception:  # never a traceback; the caller treats failure as "none"
        return 1
    for value in values:
        print(value)
    return 0


def main(argv):
    if len(argv) == 2 and argv[0] == "--exempt-caps":
        return _print_list(argv[1], parse_agent, "exempt")
    if len(argv) == 2 and argv[0] == "--covers":
        return _print_list(argv[1], parse, "covers")
    if len(argv) == 3 and argv[0] == "--check" and argv[1] == "--agent":
        try:
            with open(argv[2], encoding="utf-8") as fh:
                parse_agent(fh.read())
        except Exception as err:  # never a traceback
            print(f"FAIL: {type(err).__name__}: {err}")
            return 1
        return 0
    if argv and argv[0] == "--agent":
        rest, exempt = list(argv[1:]), []
        while "--exempt" in rest:
            at = rest.index("--exempt")
            if at + 1 >= len(rest):
                print("usage: guard_policy.py --agent <guard.yaml> [label] [--exempt <server_match>]...", file=sys.stderr)
                return 2
            exempt.append(rest[at + 1])
            del rest[at:at + 2]
        if len(rest) not in (1, 2):
            print("usage: guard_policy.py --agent <guard.yaml> [label] [--exempt <server_match>]...", file=sys.stderr)
            return 2
        label = rest[1] if len(rest) == 2 else "agent guard policy"
        try:
            with open(rest[0], encoding="utf-8") as fh:
                policy = parse_agent(fh.read())
            event = json.load(sys.stdin)
            if not isinstance(event, dict):
                raise PolicyError("hook input is not an object")
            found = agent_problems(policy, event, exempt)
        except Exception as err:  # fail closed
            print(f"Blocked by {label}: cannot check this call ({type(err).__name__}: {err})", file=sys.stderr)
            return 2
        for problem in found:
            print(f"Blocked by {label}: {problem}", file=sys.stderr)
        return 2 if found else 0
    if len(argv) == 2 and argv[0] == "--check":
        try:
            with open(argv[1], encoding="utf-8") as fh:
                parse(fh.read())
        except Exception as err:  # never a traceback
            print(f"FAIL: {type(err).__name__}: {err}")
            return 1
        return 0
    if len(argv) not in (2, 3, 4):
        print("usage: guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match] | --agent <guard.yaml> [label] | --check [--agent] <guard.yaml>", file=sys.stderr)
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
