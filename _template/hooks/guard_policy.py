#!/usr/bin/env python3
"""Agent Standard guard-policy engine — identical in every agent.

Usage:
  guard_policy.py <guard.yaml> <bindings-file|-> [label] [server_match]   hook input JSON on stdin
  guard_policy.py --agent <guard.yaml> [label] [--exempt <server_match>]... agent policy; hook input on stdin
  guard_policy.py --exempt-caps <agent guard.yaml>                          print each exempt capability
  guard_policy.py --covers <tool guard.yaml>                                print each covers id
  guard_policy.py --pins <tool guard.yaml>                                  print each bound key the policy pins
  guard_policy.py --check [--agent] <guard.yaml>                            parse only

Decides one PreToolUse call against one tool's guard policy (or, with
--agent, against the agent guard policy: deny-only, every server): exit 2 blocks
(stderr says why), exit 0 allows. Any error blocks — a bug fails closed.
With server_match, `allow` only counts a tool-name suffix whose server segment
(the text between the previous "__" and that suffix's "__") contains it, so
"mcp__attio__purge__get-x" cannot ride on `allow: [get-*]`; `deny` still checks
every suffix. Without it, `allow` considers every suffix.
The policy format is a strict YAML subset (a `writes:` list says where values
sit; `rules:` constrain them; `recipients:` pins argument values (text or numbers) to values recorded
in bindings; `limits:` caps a list's length (kind count) or a number (kind max) at a value recorded in
bindings (`required: true` also blocks a call that leaves the path out: found by exact name, and for kind
count a non-empty list); `only_keys:` allows an object
at a path only the keys it lists, spelled exactly (no case or `_`/`-` folding, so it agrees with the
exact-key `recipients` paths); `refuse_args:` refuses an argument, or a nested value at a path like
"startUrls[].payload" (names there are folded, which only makes it stricter); an only_keys allowlist is
the recommended way to restrict arguments); `fixed:` requires an exact JSON value (true, false, null, a
number, or a quoted string; equal in type too) at a path, and with `required: true` also blocks a call that
leaves the path out (found by exact name); `urls:` requires every value at a path to be a URL string that
passes a strict parser (never urllib.parse) and the entry's schemes, hosts, path, query and fragment rules,
on top of always-on refusals (user info, non-default ports, IP literals, local and single-label hosts,
non-ASCII hosts); see STANDARD.md "Guard policy".
"""
import decimal
import fnmatch
import ipaddress
import json
import math
import re
import sys
import unicodedata

KEYS = ("covers", "allow", "deny", "writes", "unwrap", "unknown_writes", "refuse_keys", "bound_keys_only",
        "rules", "recipients", "limits", "only_keys", "refuse_args", "fixed", "urls")
AGENT_KEYS = ("covers", "deny", "exempt")
LIST_KEYS = ("covers", "allow", "deny", "unwrap", "refuse_keys", "refuse_args")
ARG_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
RULE_KEYS = ("field", "forbid", "create", "update", "any")
WRITE_KEYS = ("kind", "tools", "at")
RECIPIENT_KEYS = ("tools", "at", "bound")
LIMIT_KEYS = ("tools", "at", "bound", "kind", "required")
ONLY_KEYS_KEYS = ("tools", "at", "keys")
FIXED_KEYS = ("tools", "at", "value", "required")
URL_KEYS = ("tools", "at", "schemes", "hosts", "path", "query", "fragment", "required")
URL_SCHEMES = {"https": 443, "http": 80}  # each allowed scheme and its default port
URL_MAX = 2048
URL_SCHEME = re.compile(r"^[a-z]+$")
URL_PORT = re.compile(r"^(0|[1-9][0-9]{0,4})$")  # no sign, no padding, ASCII digits only
URL_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")  # LDH, 1-63, no edge hyphen
URL_PREFIX = re.compile(r"^(/[A-Za-z0-9._~-]+)+$")
URL_LOCAL = (".localhost", ".local", ".internal", ".lan", ".home.arpa", ".test")
LIMIT_KINDS = ("count", "max")
ROOT = "$"  # an only_keys path naming the whole tool input
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
NUMERIC = re.compile(r"^[+-]?[0-9]+(\.[0-9]+)?$", re.ASCII)


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


def _typed_scalar(token, lineno):
    """A `fixed` value as the JSON value it stands for: unquoted true/false → bool, null → None, a strict
    decimal (the _as_number grammar) → Decimal; a quoted token → str. Any other unquoted token is an error,
    so a string must be quoted and its type is never a guess."""
    token = token.strip()
    if token.startswith("["):
        raise PolicyError(f"line {lineno}: a fixed value is one scalar, not a list")
    text = _scalar(token, lineno)  # every quoting rule of a plain value still applies
    if token[0] in "'\"":
        return text
    if text in ("true", "false"):
        return text == "true"
    if text == "null":
        return None
    if NUMERIC.match(text):
        return decimal.Decimal(text)
    raise PolicyError(f"line {lineno}: fixed value {text!r} is not true, false, null or a number; quote a string")


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


def _parse_items(lines, i, name, allowed, typed=()):
    """A block list of entries; a key in typed keeps its JSON type (see _typed_scalar)."""
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
        if key in typed:
            items[-1][key] = _typed_scalar(value, lineno)
        elif value.startswith("["):
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
    for name in ("recipients", "limits"):
        for entry in policy.get(name, []):
            if name == "limits" and entry.get("kind") not in LIMIT_KINDS:
                raise PolicyError("limits: kind must be count or max")
            if name == "limits" and "required" in entry and entry["required"] != "true":
                raise PolicyError("limits: required may only be true")
            for k in ("tools", "at"):
                if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
                    raise PolicyError(f"{name}: each entry needs a non-empty {k} list")
            for path in entry["at"]:
                if not PATH.match(path):
                    raise PolicyError(f"{name}: {path} is not a path like to or \"message.to\"")
            if not isinstance(entry.get("bound"), str) or not SNAKE.match(entry["bound"]):
                raise PolicyError(f"{name}: bound must be a snake_case binding key")
    for entry in policy.get("only_keys", []):
        for k in ("tools", "at", "keys"):
            if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
                raise PolicyError(f"only_keys: each entry needs a non-empty {k} list")
        for path in entry["at"]:
            if path != ROOT and not PATH.match(path):
                raise PolicyError(f"only_keys: {path} is not a path like \"$\" or \"startUrls[]\"")
        for name in entry["keys"]:
            if not ARG_NAME.match(name):
                raise PolicyError(f"only_keys: '{name}' is not a plain argument name")
    for entry in policy.get("fixed", []):
        for k in ("tools", "at"):
            if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
                raise PolicyError(f"fixed: each entry needs a non-empty {k} list")
        for path in entry["at"]:
            if not PATH.match(path):
                raise PolicyError(f"fixed: {path} is not a path like personalData or \"a[].b\"")
        if "value" not in entry:
            raise PolicyError("fixed: each entry needs a value")
        if type(entry["value"]) not in (bool, type(None), decimal.Decimal, str):
            raise PolicyError("fixed: value must be true, false, null, a number or a quoted string")
        if entry.get("required", "false") not in ("true", "false"):
            raise PolicyError("fixed: required may only be true or false")
    for entry in policy.get("urls", []):
        _validate_url_entry(entry)
    if "refuse_args" in policy:
        if not policy["refuse_args"]:
            raise PolicyError("refuse_args must name at least one argument")
        for name in policy["refuse_args"]:
            if not PATH.match(name):  # a plain argument name is the one-segment path
                raise PolicyError(f"refuse_args: '{name}' is not an argument name or a path like \"a[].b\"")
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


def _validate_url_entry(entry):
    for k in ("tools", "at"):
        if not isinstance(entry.get(k), list) or not entry[k] or not all(entry[k]):
            raise PolicyError(f"urls: each entry needs a non-empty {k} list")
    for path in entry["at"]:
        if not PATH.match(path):
            raise PolicyError(f"urls: {path} is not a path like url or \"startUrls[].url\"")
    schemes = entry.get("schemes")
    if not isinstance(schemes, list) or not schemes:
        raise PolicyError("urls: each entry needs a non-empty schemes list")
    for scheme in schemes:
        if scheme not in URL_SCHEMES:
            raise PolicyError(f"urls: scheme '{scheme}' is not https or http")
    hosts = entry.get("hosts")
    if isinstance(hosts, list):
        if not hosts:
            raise PolicyError("urls: hosts must list at least one host, or be public")
        for host in hosts:
            why = _host_reason(host)
            if why:
                raise PolicyError(f"urls: hosts item '{host}' is not an exact public hostname ({why})")
    elif hosts != "public":
        raise PolicyError("urls: each entry needs hosts, a list of hostnames or the word public")
    path = entry.get("path")
    if not isinstance(path, str) or not (path in ("root", "any") or (
            URL_PREFIX.match(path) and ".." not in path and "." not in path.split("/"))):
        raise PolicyError("urls: path must be root, any or a prefix like '/pages' (no trailing /, no . or ..)")
    for k in ("query", "fragment"):
        if entry.get(k, "forbid") not in ("forbid", "allow"):
            raise PolicyError(f"urls: {k} may only be forbid or allow")
    if "required" in entry and entry["required"] != "true":
        raise PolicyError("urls: required may only be true")


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
        if key in ("rules", "writes", "recipients", "limits", "only_keys", "fixed", "urls"):
            if value:
                raise PolicyError(f"line {lineno}: {key}: takes '  - ...' items on the following lines")
            allowed = {"rules": RULE_KEYS, "writes": WRITE_KEYS, "recipients": RECIPIENT_KEYS,
                       "limits": LIMIT_KEYS, "only_keys": ONLY_KEYS_KEYS, "fixed": FIXED_KEYS,
                       "urls": URL_KEYS}[key]
            typed = ("value",) if key == "fixed" else ()
            policy[key], i = _parse_items(lines, i, key, allowed, typed)
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


def _walk_folded(obj, path, exact=False):
    """(nodes at path, shape mismatch). Each segment matches the way refuse_args names do (_arg_key), and
    every key that matches counts; with exact, a segment matches only the identical key. A null where an object or list is expected holds nothing; any other
    wrong shape sets the mismatch flag (the caller decides what that means) and is never an exception."""
    nodes, mismatch = [obj], False
    for part in path.split("."):
        many = part.endswith("[]")
        want = part[:-2] if many else part
        if not exact:
            want = _arg_key(want)
        nxt = []
        for node in nodes:
            if node is None:
                continue
            if not isinstance(node, dict):
                mismatch = True
                continue
            for key, value in node.items():
                if (key if exact else _arg_key(key)) != want:
                    continue
                if many and value is None:
                    continue
                if many and not isinstance(value, list):
                    mismatch = True
                elif many:
                    nxt.extend(value)
                else:
                    nxt.append(value)
        nodes = nxt
    return nodes, mismatch


def _maps_at(obj, path):
    nodes = _walk(obj, path)
    for node in nodes:
        if not isinstance(node, dict):
            raise PolicyError(f"{path}: attribute values are not an object")
    return nodes


def _pinned_at(obj, path):
    """Pinned values at path: a string or a number is one, a list of them is its items, null is absent.
    Booleans, objects and nested lists fail closed."""
    def scalar(x):
        return isinstance(x, str) or (isinstance(x, (int, float)) and not isinstance(x, bool))
    out = []
    for node in _walk(obj, path):
        if node is None:
            continue
        if scalar(node):
            out.append(node)
        elif isinstance(node, list) and all(scalar(x) for x in node):
            out.extend(node)
        else:
            raise PolicyError(f"{path}: a pinned value must be a string, a number, or a list of them")
    return out


def _as_number(value):
    """value as an exact Decimal when it is a number or a plain decimal string, else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return decimal.Decimal(value)
    if isinstance(value, float):
        return decimal.Decimal(repr(value)) if math.isfinite(value) else None
    if isinstance(value, str):
        text = value.strip()
        return decimal.Decimal(text) if NUMERIC.match(text) else None
    return None


def _refused_at(obj, path):
    """"present" when a refuse_args path holds anything but null or "", "shape" when the call does not have
    the path's shape (and holds nothing refused), else None."""
    nodes, mismatch = _walk_folded(obj, path)
    if any(node not in (None, "") for node in nodes):
        return "present"
    return "shape" if mismatch else None


def _only_keys_problems(shown, entry, args):
    """only_keys: every object at the paths holds only the listed keys, spelled exactly (a folded match
    would let a variant spelling past the exact-key checks of recipients and writes)."""
    allowed = set(entry["keys"])
    found = []
    for path in entry["at"]:
        if path == ROOT:
            nodes, mismatch = [args], False
        else:
            nodes, mismatch = _walk_folded(args, path, exact=True)
        if mismatch:
            found.append(f"{path}: unexpected shape")
        for node in nodes:
            if node is None:
                continue
            if not isinstance(node, dict):
                found.append(f"{path}: expected an object")
                continue
            for key in node:
                if key not in allowed:
                    found.append(f"{shown} may not use {key}" if path == ROOT else f"{shown} may not use {path}.{key}")
    return found


def _supplied(args, path, kind):
    """A required limits path is supplied only under its exact name (a variant spelling is capped by the
    folded walk but does not satisfy `required`), and a counted list needs at least one item."""
    nodes, _ = _walk_folded(args, path, exact=True)
    return any(node is not None and not (kind == "count" and node == []) for node in nodes)


def _limit_problems(shown, entry, args, bindings):
    """limits: kind count caps a list's length, kind max caps a number (at least 1), both at the one number
    bound to entry["bound"]. A path the call does not have is fine unless the entry says `required: true`,
    which also blocks a call that leaves the path out."""
    bound = entry["bound"]
    lines = bindings.get(bound) or set()
    if not lines:
        return [f"no {bound} line in bindings; re-run setup's tools step"]
    numbers = {_as_number(v) for v in lines}
    if len(numbers) != 1 or None in numbers:
        return [f"{bound} must be one number"]
    (cap,) = numbers
    found = []
    for path in entry["at"]:
        nodes, mismatch = _walk_folded(args, path)
        if mismatch:
            raise PolicyError(f"{path}: unexpected shape")
        if entry.get("required") and not _supplied(args, path, entry["kind"]):
            found.append(f"{shown} names no {path}")
        for node in nodes:
            if node is None:
                continue
            if entry["kind"] == "count":
                if not isinstance(node, list):
                    found.append(f"{path}: expected a list")
                    continue
                if any(isinstance(item, list) for item in node):
                    found.append(f"{path}: a counted list may not contain lists")
                    continue
                size = decimal.Decimal(len(node))
            else:
                size = _as_number(node)
                if size is None:
                    found.append(f"{path}: expected a number")
                    continue
                if size < 1:
                    found.append(f"{path}: must be at least 1")
                    continue
            if size > cap:
                found.append(f"{shown} exceeds {bound} at {path} ({_printable(size)} > {cap})")
    return found


def _required_everywhere(obj, path):
    """Why a required path is not supplied everywhere, or None when it is. The path is walked with exact
    key names, and through each `[]` segment every item must carry the rest of the path: "absent" when a
    key is missing, an item or an object on the way is null, or a list has no items (zero values);
    "shape" when a non-null value on the way is not an object, or a `[]` value is not a list. A null at the
    end of the path is present (the caller checks its value)."""
    nodes, why = [obj], None
    for part in path.split("."):
        many = part.endswith("[]")
        name = part[:-2] if many else part
        nxt = []
        for node in nodes:
            if node is None:
                why = why or "absent"
                continue
            if not isinstance(node, dict):
                why = "shape"
                continue
            if name not in node:
                why = why or "absent"
                continue
            value = node[name]
            if not many:
                nxt.append(value)
            elif value is None or value == []:
                why = why or "absent"
            elif not isinstance(value, list):
                why = "shape"
            else:
                nxt.extend(value)
        nodes = nxt
    return why


def _same_value(want, got):
    """got is the fixed value want, in type as well: false is not 0 or "false", 5 is 5.0, text is exact."""
    if want is None or isinstance(want, bool):
        return got is want
    if isinstance(want, decimal.Decimal):
        if isinstance(got, bool) or not isinstance(got, (int, float)):
            return False  # a numeric string is not a number here
        number = _as_number(got)
        return number is not None and number == want
    return isinstance(got, str) and got == want


def _json_text(value):
    if isinstance(value, decimal.Decimal):
        return format(value, "f")
    return json.dumps(value)


def _fixed_problems(shown, entry, args):
    """fixed: every value at the paths (segments folded, which only makes it stricter) is the entry's value.
    A path the call does not have is fine unless the entry says `required: true`; then the path must be
    supplied under its exact names, by every item of every list on the way (see _required_everywhere; a
    null at the end counts as present, and is checked like any value)."""
    want = entry["value"]
    found = []
    for path in entry["at"]:
        nodes, mismatch = _walk_folded(args, path)
        if mismatch:
            found.append(f"{path}: unexpected shape")
        why = _required_everywhere(args, path) if entry.get("required") == "true" else None
        if why == "absent":
            found.append(f"{shown} names no {path}")
        elif why == "shape" and not mismatch:
            found.append(f"{path}: unexpected shape")
        for node in nodes:
            if not _same_value(want, node):
                found.append(f"{shown} must send {path} = {_json_text(want)} (got {_printable(_json_text(node))})")
    return found


def _host_reason(host):
    """Why host fails the always-on host checks, or None. It must be ASCII before it is lowercased (a
    full-width letter, an ideographic full stop or a Kelvin sign is refused, never mapped the way IDNA would
    map it), hold no %, and be neither an IP literal nor a local name. The IP pre-check refuses what any
    URL parser reads as IPv4 (a last label of digits: dotted, decimal, octal and short forms; a 0x label),
    then ipaddress has the last word."""
    if not host:
        return "the host is empty"
    if "%" in host:
        return "the host has a %"
    if not host.isascii():
        return "the host is not ASCII"
    host = host.lower()
    if host.endswith("."):
        return "the host ends with a dot"
    labels = host.split(".")
    if host.startswith("[") or labels[-1].isdigit() or any(label.startswith("0x") for label in labels):
        return "the host is an IP address"
    try:
        ipaddress.ip_address(host)
        return "the host is an IP address"
    except ValueError:
        pass
    if host == "localhost" or host.endswith(URL_LOCAL):
        return f"host {_printable(host)} is local"
    if len(labels) < 2:
        return "the host needs at least two labels"
    for label in labels:
        if not URL_LABEL.match(label):
            return (f"host label {_printable(label)!r} is not 1 to 63 letters, digits or hyphens"
                    " that start and end with a letter or digit")
    return None


def _parse_url(s):
    """(scheme, host, port, path, query, fragment) from a strict left-to-right read of
    scheme://authority[path][?query][#fragment], or the reason it is refused. Never urllib.parse: a lenient
    parse could see a different host than the HTTP client that fetches the URL. Anything a WHATWG parser
    would repair or reinterpret (a backslash, whitespace, a control character, one slash, user info,
    an empty port) is refused instead. The host comes back lowercased; port is an int or None; query and
    fragment are None when absent and "" for a lone ? or #."""
    if len(s) > URL_MAX:
        return f"is longer than {URL_MAX} characters"
    if any(ch == "\\" or ch.isspace() or unicodedata.category(ch)[0] == "C" for ch in s):
        return "has a control character, whitespace or a backslash"
    shape = "is not scheme://host[path][?query][#fragment]"
    at = s.find("://")
    if at < 0:
        return shape
    scheme, rest = s[:at], s[at + 3:]
    if not URL_SCHEME.match(scheme):
        return "the scheme must be lowercase" if scheme.isascii() and scheme.isalpha() else shape
    end = min([i for i in (rest.find("/"), rest.find("?"), rest.find("#")) if i >= 0] or [len(rest)])
    authority, tail = rest[:end], rest[end:]
    if "@" in authority:
        return "user info (@) is not allowed"
    if authority.startswith("["):
        return "the host is an IP address"
    host, port = authority, None
    if ":" in authority:
        host, _, digits = authority.rpartition(":")
        if not URL_PORT.match(digits) or int(digits) > 65535:
            return "the port is not a plain number"
        port = int(digits)
    why = _host_reason(host)
    if why:
        return why
    path, query, fragment = tail, None, None
    if "#" in path:
        path, fragment = path.split("#", 1)
    if "?" in path:
        path, query = path.split("?", 1)
    return scheme, host.lower(), port, path, query, fragment


def _url_reason(entry, s):
    """Why the URL string s breaks the urls entry, or None."""
    parsed = _parse_url(s)
    if isinstance(parsed, str):
        return parsed
    scheme, host, port, path, query, fragment = parsed
    if scheme not in entry["schemes"]:
        return f"scheme {scheme} is not allowed"
    if port is not None and port != URL_SCHEMES[scheme]:
        return f"port {port} is not the default for {scheme}"
    if entry["hosts"] == "public":
        if any(label.startswith("xn--") for label in host.split(".")):
            return "an xn-- label needs an exact hosts list"
    elif host not in {h.lower() for h in entry["hosts"]}:
        return f"host {_printable(host)} is not in the hosts list"
    rule = entry["path"]
    if rule != "any":
        folded = path.lower()
        # %2E is a dot to a WHATWG parser (%2e%2e is ..) and %5C a backslash to some servers
        if ".." in path or any(code in folded for code in ("%2f", "%2e", "%5c")):
            return "the path holds .., %2F, %2E or %5C"
        if rule == "root":
            if path not in ("", "/"):
                return "only the site root is allowed"
        elif path != rule and not path.startswith(rule + "/"):
            return f"the path is not under {rule}"
    if query is not None and entry.get("query", "forbid") != "allow":
        return "a query is not allowed"
    if fragment is not None and entry.get("fragment", "forbid") != "allow":
        return "a fragment is not allowed"
    return None


def _url_problems(shown, entry, args):
    """urls: every value at the paths (segments folded, which only makes it stricter) is a URL string the
    entry accepts. `required: true` works as in fixed: supplied under exact names by every item of every
    list on the way (see _required_everywhere)."""
    found = []
    for path in entry["at"]:
        nodes, mismatch = _walk_folded(args, path)
        if mismatch:
            found.append(f"{path}: unexpected shape")
        why = _required_everywhere(args, path) if entry.get("required") == "true" else None
        if why == "absent":
            found.append(f"{shown} names no {path}")
        elif why == "shape" and not mismatch:
            found.append(f"{path}: unexpected shape")
        for node in nodes:
            if not isinstance(node, str):
                found.append(f"{path} must be a URL string")
                continue
            reason = _url_reason(entry, node)
            if reason:
                found.append(f"{shown} {path}: {reason}")
    return found


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
    values = [v for path in entry["at"] for v in _pinned_at(args, path)]
    if not values:
        return [f"{shown} names no pinned value at {', '.join(entry['at'])}"]
    bound = entry["bound"]
    pinned = bindings.get(bound) or set()
    if not pinned:
        return [f"no {bound} line in bindings; re-run setup's tools step"]
    if not all(BARE_VALUE.match(p) for p in pinned):
        return [f"{bound} must be a bare value"]
    texts = {p.strip().lower() for p in pinned}
    numbers = {n for n in (_as_number(p) for p in pinned) if n is not None}

    def ok(v):
        if isinstance(v, str) and v.strip().lower() in texts:
            return True
        n = _as_number(v)
        return n is not None and n in numbers

    return [f"{_printable(v)} is not a pinned value ({bound})" for v in values if not ok(v)]


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
    refuse_names = [name for name in policy.get("refuse_args", []) if ARG_NAME.match(name)]
    refuse_paths = [name for name in policy.get("refuse_args", []) if not ARG_NAME.match(name)]
    if refuse_paths and not isinstance(args, dict):
        raise PolicyError("tool_input is not an object")
    if isinstance(args, dict):
        refused = {_arg_key(name) for name in refuse_names}
        for key, value in args.items():
            if _arg_key(key) in refused and value not in (None, ""):
                early.append(f"{shown} may not use {key}")
        for path in refuse_paths:
            why = _refused_at(args, path)
            if why:
                early.append(f"{shown} may not use {path}" if why == "present" else f"{path}: unexpected shape")
    for entry in policy.get("recipients", []):
        if not _matches(names, entry["tools"]):
            continue
        if not isinstance(args, dict):
            raise PolicyError("tool_input is not an object")
        early.extend(_recipient_problems(shown, entry, args, bindings))
    for entry in policy.get("limits", []):
        if not _matches(names, entry["tools"]):
            continue
        if not isinstance(args, dict):
            raise PolicyError("tool_input is not an object")
        early.extend(_limit_problems(shown, entry, args, bindings))
    for entry in policy.get("only_keys", []):
        if not _matches(names, entry["tools"]):
            continue
        if not isinstance(args, dict):
            raise PolicyError("tool_input is not an object")
        early.extend(_only_keys_problems(shown, entry, args))
    for entry in policy.get("fixed", []):
        if not _matches(names, entry["tools"]):
            continue
        if not isinstance(args, dict):
            raise PolicyError("tool_input is not an object")
        early.extend(_fixed_problems(shown, entry, args))
    for entry in policy.get("urls", []):
        if not _matches(names, entry["tools"]):
            continue
        if not isinstance(args, dict):
            raise PolicyError("tool_input is not an object")
        early.extend(_url_problems(shown, entry, args))
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
    except on a server exempted for an owner_only_send capability (guard.sh decides which;
    the match must be in a server segment of the name)."""
    tool_name = event.get("tool_name")
    pairs = _candidates(tool_name)
    names = [suffix for suffix, _ in pairs]
    for match in exempt:
        if not SERVER_MATCH.match(match):
            raise PolicyError(f"exempt server_match {match!r} is not [a-z0-9_-]+")
    # Same rule as allow: the match must sit in a server segment, not in the tool name.
    if any(match in server for match in exempt for _, server in pairs):
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
    if len(argv) == 2 and argv[0] == "--pins":
        try:
            with open(argv[1], encoding="utf-8") as fh:
                policy = parse(fh.read())
        except Exception as err:  # never a traceback
            print(f"FAIL: {type(err).__name__}: {err}")
            return 1
        seen = []
        for entry in policy.get("recipients", []) + policy.get("limits", []):
            if entry["bound"] not in seen:
                seen.append(entry["bound"])
        if seen:
            print("\n".join(seen))
        return 0
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
