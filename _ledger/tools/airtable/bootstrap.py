#!/usr/bin/env python3
"""Create or upgrade the ledger base that usage.md describes.

Additive and idempotent: every table and field is created only if
missing, so re-running after a partial failure is safe. A missing select
option, or a field of the wrong type, stops the script with an error
naming what to fix by hand. Nothing is ever deleted, renamed or retyped.
Computed fields (formula, createdTime) are added after their table is
created, because Airtable cannot create them as part of table creation.

Reads AIRTABLE_TOKEN from the environment (set it in your shell with
`read -rs AIRTABLE_TOKEN && export AIRTABLE_TOKEN`; never write it to a
file). Token scopes: schema.bases:read, schema.bases:write.

    python3 capabilities/ledger/tools/airtable/bootstrap.py --workspace <wsp…> [--name <base name>]
    python3 capabilities/ledger/tools/airtable/bootstrap.py --base <app…> [--dry-run]
"""
import importlib.util
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
API = "https://api.airtable.com/v0"
HERE = pathlib.Path(__file__).resolve().parent
BASE_ID = re.compile(r"^app[A-Za-z0-9]{14}$")
WORKSPACE_ID = re.compile(r"^wsp[A-Za-z0-9]{14}$")
COMPUTED_TYPES = ("formula", "createdTime")
DATE_TIME = {"dateFormat": {"name": "iso"}, "timeFormat": {"name": "24hour"}, "timeZone": "utc"}


def _load_tool_check():
    """The agent's hooks/tool_check.py (package root is four levels up), or the builder's template copy."""
    for candidate in (HERE.parents[3] / "hooks" / "tool_check.py",
                      HERE.parents[2] / "_template" / "hooks" / "tool_check.py"):
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location("tool_check", candidate)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise SystemExit("ERROR: cannot find hooks/tool_check.py")


tool_check = _load_tool_check()


def field_spec(name, ftype, options):
    """The Airtable Web API field object for one declared field."""
    spec = {"name": name, "type": ftype}
    if ftype in ("singleSelect", "multipleSelects"):
        spec["options"] = {"choices": [{"name": o} for o in options]}
    elif ftype == "formula":
        spec["options"] = {"formula": options[0]}
    elif ftype == "number":
        spec["options"] = {"precision": 0}
    elif ftype == "currency":
        spec["options"] = {"precision": 2, "symbol": "$"}
    elif ftype == "checkbox":
        spec["options"] = {"icon": "check", "color": "greenBright"}
    elif ftype == "dateTime":
        spec["options"] = dict(DATE_TIME)
    elif ftype == "date":
        spec["options"] = {"dateFormat": {"name": "iso"}}
    return spec


def wanted(root, events_only=False):
    """[(table, [(field, type, options)])]: Events first, then the agent's tables.md tables."""
    tables = [("Events", list(tool_check.LEDGER_EVENTS))]
    if events_only:
        return tables
    path = pathlib.Path(root) / "capabilities" / "ledger" / "tables.md"
    _, declared, problems = tool_check.parse_tables(path.read_text(encoding="utf-8"))
    if problems:
        raise SystemExit("ERROR: capabilities/ledger/tables.md: " + "; ".join(problems))
    for name, table in declared.items():
        tables.append((name, [(f, t, o) for f, (t, o) in table["fields"].items()]))
    return tables


def plan(existing, tables):
    """(actions, errors) that bring `existing` up to `tables`, additively.

    A new table is created with its plain fields (the first is the primary field);
    computed fields follow as create_field actions, after the fields they may read."""
    actions, errors = [], []
    for table, fields in tables:
        have = existing.get(table)
        plain = [f for f in fields if f[1] not in COMPUTED_TYPES]
        computed = [f for f in fields if f[1] in COMPUTED_TYPES]
        if have is None:
            actions.append(("create_table", table, [field_spec(*f) for f in plain]))
            actions.extend(("create_field", table, field_spec(*f)) for f in computed)
            continue
        for name, ftype, options in plain + computed:
            got = have["fields"].get(name)
            if got is None:
                actions.append(("create_field", table, field_spec(name, ftype, options)))
            elif got["type"] != ftype:
                errors.append(f"{table}.{name} is {got['type']}, the ledger needs {ftype}; fix it by hand")
            elif ftype in ("singleSelect", "multipleSelects"):
                for option in options:
                    if option not in got.get("choices", []):
                        errors.append(f"{table}.{name} lacks option {option}; add it by hand")
    return actions, errors


def call(method, path, body=None):
    """(status, parsed JSON) for one Web API request. Never prints the token."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + os.environ["AIRTABLE_TOKEN"], "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        try:
            return err.code, json.loads(err.read() or b"{}")
        except ValueError:
            return err.code, {}
    except urllib.error.URLError as err:
        return 0, {"error": str(err.reason)}


def existing_tables(base):
    status, body = call("GET", f"/meta/bases/{base}/tables")
    if status != 200:
        raise SystemExit(f"ERROR: reading base {base} failed ({status}): {body.get('error', body)}")
    out = {}
    for t in body.get("tables", []):
        fields = {}
        for f in t.get("fields", []):
            choices = [c.get("name") for c in (f.get("options") or {}).get("choices", [])]
            fields[f["name"]] = {"type": f["type"], "choices": choices}
        out[t["name"]] = {"id": t["id"], "fields": fields}
    return out


def apply(base, existing, actions):
    for kind, table, payload in actions:
        if kind == "create_table":
            status, body = call("POST", f"/meta/bases/{base}/tables", {"name": table, "fields": payload})
            if status != 200:
                print(f"ERROR: create table {table} failed ({status}): {body.get('error', body)}")
                return 1
            existing[table] = {"id": body.get("id"), "fields": {}}
            print(f"created table {table}")
        else:
            tid = existing[table]["id"]
            status, body = call("POST", f"/meta/bases/{base}/tables/{tid}/fields", payload)
            if status != 200:
                print(f"ERROR: create field {table}.{payload['name']} failed ({status}): {body.get('error', body)}")
                return 1
            print(f"created field {table}.{payload['name']}")
    return 0


def finish(base, tables, schema, dry, after_create=False):
    """Read `base`, plan and apply what the ledger still needs. after_create: `base` was just
    created by this run, so a failure here is told apart (the base exists; --base finishes it)."""
    try:
        existing = existing_tables(base)
    except SystemExit as err:
        if not after_create:
            raise
        print(f"{err.code}; the base exists, rerun with --base {base} to finish it")
        return 1
    actions, errors = plan(existing, tables)
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        return 1
    if dry:
        for kind, table, payload in actions:
            print(f"would {kind.replace('_', ' ')} {table}" + ("" if kind == "create_table" else f".{payload['name']}"))
        print(f"{len(actions)} change(s) planned")
        return 0
    rc = apply(base, existing, actions)
    if rc:
        if after_create:
            print(f"ERROR: the base {base} exists but is incomplete; rerun with --base {base} to finish it")
        return rc
    if not after_create:
        print(f"base_id: {base}")
    print(f"ledger_schema: {schema} built")
    return 0


def main(argv):
    args = list(argv)
    dry = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    opts = dict(zip(args[::2], args[1::2]))
    if len(args) % 2 or not ({"--base", "--workspace"} & opts.keys()) or {"--base", "--workspace"} <= opts.keys():
        print("usage: bootstrap.py --workspace <wsp…> [--name <base name>] | --base <app…> [--dry-run]")
        print("ERROR: pass exactly one of --workspace <wsp…> or --base <app…>")
        return 2
    if "--base" in opts and not BASE_ID.match(opts["--base"]):
        print(f"ERROR: {opts['--base']!r} is not an Airtable base ID (app + 14 characters)")
        return 2
    if "--workspace" in opts and not WORKSPACE_ID.match(opts["--workspace"]):
        print(f"ERROR: {opts['--workspace']!r} is not an Airtable workspace ID (wsp + 14 characters)")
        return 2
    if not os.environ.get("AIRTABLE_TOKEN") and not ("--workspace" in opts and dry):
        print("ERROR: AIRTABLE_TOKEN is not set; run: read -rs AIRTABLE_TOKEN && export AIRTABLE_TOKEN")
        return 2
    root = HERE.parents[3]
    tables = wanted(root, events_only=not (root / "capabilities" / "ledger" / "tables.md").is_file())
    schema = 1
    if (root / "capabilities" / "ledger" / "tables.md").is_file():
        schema = tool_check.parse_tables((root / "capabilities" / "ledger" / "tables.md").read_text(encoding="utf-8"))[0]
    if "--workspace" in opts:
        if dry:
            print(f"would create a base with tables: {', '.join(t for t, _ in tables)}")
            return 0
        body = {"name": opts.get("--name", "Agent ledger"), "workspaceId": opts["--workspace"],
                "tables": [{"name": t, "fields": [field_spec(*f) for f in fs if f[1] not in COMPUTED_TYPES]}
                           for t, fs in tables]}
        status, resp = call("POST", "/meta/bases", body)
        if status != 200:
            print(f"ERROR: create base failed ({status}): {resp.get('error', resp)}")
            return 1
        base = resp.get("id")
        print(f"base_id: {base}")
        return finish(base, tables, schema, dry=False, after_create=True)
    return finish(opts["--base"], tables, schema, dry)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
