#!/usr/bin/env python3
"""Agent Standard schedule checker — identical in every agent.

Usage:
  schedule_check.py check <instance-dir> [--repo owner/name] [--json]
  schedule_check.py verify <instance-dir> <activity> <routine.json> [--repo owner/name]

check  — for every schedule_<activity> in the instance's schedules.yaml:
         applies the unattended gate (every capability its activities use is
         bound, and every contract invariant is in the bound tool's
         guard.yaml covers) and prints what the user needs to create the
         routine: name, schedule and UTC cron, connectors, prompt, and the
         cloud-environment setup script. A routine_<activity> line with no
         schedule_<activity> also fails. Exit 0 when every entry passes,
         1 when any entry (or orphan routine_ line) fails, 2 on usage or
         read errors.
verify — compares a routine (the JSON the routines API returns for it,
         with or without a top-level "trigger" wrapper) against what check
         expects for <activity>: repository (exactly one source), cloud
         environment, enabled, prompt, connectors (one per binding and no
         others), next run. Exit 0 on a match, 1 with one line per
         mismatch, 2 on usage or read errors.

The package root is the parent of this script's folder.
"""
import datetime
import json
import pathlib
import re
import sys
import zoneinfo

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
try:
    import guard_policy  # noqa: E402  (same folder, reference engine)
except Exception:  # missing, unreadable or broken: never a traceback
    print("ERROR: cannot load guard_policy.py beside this script", file=sys.stderr)
    sys.exit(2)
try:
    import tool_check  # noqa: E402  (same folder, reference tool checker)
except Exception:  # missing, unreadable or broken: never a traceback
    print("ERROR: cannot load tool_check.py beside this script", file=sys.stderr)
    sys.exit(2)

DAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
WHEN = re.compile(r"^(monday|tuesday|wednesday|thursday|friday|saturday|sunday|daily) ([01]\d|2[0-3]):([0-5]\d)$", re.I)
INVARIANT = re.compile(r"^[-*]\s+`([^`]+)`")
CAP = re.compile(r"[a-z0-9_]+")
PROVIDER = re.compile(r"[a-z0-9-]+")
SERVER_MATCH = re.compile(r"[a-z0-9_-]+")  # MCP tool names hold only [A-Za-z0-9_-]; the builder requires lowercase
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")  # C0 controls and DEL other than tab, LF, CR
ENVIRONMENT = re.compile(r"env_[A-Za-z0-9]+")  # a cloud environment id, used with fullmatch
GITHUB = re.compile(r"^(?:https?://(?:[^/@\s]+@)?|ssh://git@|git@)github\.com[/:]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", re.I)
PROMPT_TAIL = ("(unattended). Follow this agent's instructions for each activity, in order. "
               "Do not ask questions and do not edit or commit files in this repository. "
               "If something needs the operator, stop and say exactly what.")


class CheckError(Exception):
    """The instance or package cannot be read."""


WS = " \t\n\v\f\r"  # sed's [[:space:]], which Python's \s and str.strip() are wider than
WSRE = "[ \t\n\v\f\r]"


def _value(raw):
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        end = raw.find(raw[0], 1)
        if end != -1:
            return raw[1:end]
    return re.sub(r"(^|\s)#.*$", "", raw).strip()


def _guard_value(raw):
    """A scalar normalized the way guard.sh does: trim, drop ` #` comment, trim, strip surrounding quotes."""
    raw = re.sub(f"^{WSRE}+", "", raw)
    raw = re.sub(f"{WSRE}+#.*$", "", raw)
    raw = re.sub(f"{WSRE}+$", "", raw)
    raw = re.sub(r'^"(.*)"$', r"\1", raw)
    return re.sub(r"^'(.*)'$", r"\1", raw)


def _read(path, guard=True):
    """A file's text, BOM ignored. guard=True (a file guard.sh reads) rejects control characters:
    a NUL or other C0 control byte can make sed abort, so the guard would read nothing."""
    try:
        text = path.read_bytes().decode("utf-8-sig")
    except (OSError, UnicodeDecodeError) as err:
        raise CheckError(f"cannot read {path.name}: {err}")
    bad = CONTROL.search(text) if guard else None
    if bad:
        line = text.count("\n", 0, bad.start()) + 1
        raise CheckError(f"{path.name} line {line} has a control character (0x{ord(bad.group()):02x}) "
                         "the guard cannot read reliably")
    return text


def _lines(path, guard=True):
    """Lines of a file as guard.sh reads them: split on \\n only, one trailing \\r removed, BOM ignored."""
    return [ln[:-1] if ln.endswith("\r") else ln for ln in _read(path, guard).split("\n")]


def flat_yaml(path, dups=None, guard=True):
    """Top-level `key: value` pairs of a flat YAML file; the first occurrence of a key wins.

    guard=True reads the way guard.sh's yaml_get does (exact `key:` at line start, sed whitespace).
    guard=False (schedules.yaml) is lenient about spacing; keys seen more than once are appended to dups."""
    data = {}
    for line in _lines(path, guard):
        if guard:
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            value = _guard_value(value)
        else:
            if not line.strip() or line.lstrip().startswith("#") or line[0] in " \t" or ":" not in line:
                continue
            key, value = line.split(":", 1)
            key, value = key.strip(), _value(value)
        if key in data:
            if dups is not None and key not in dups:
                dups.append(key)
            continue
        data[key] = value
    return data


def agent_yaml(path):
    """agent.yaml the way the builder's validator reads it (keys stripped, last value wins).

    Returns (data, keys seen more than once)."""
    data, dups = {}, []
    for line in _read(path).splitlines():
        if not line.strip() or line.lstrip().startswith("#") or line[0] in " \t" or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if key in data and key not in dups:
            dups.append(key)
        data[key] = _value(value)
    return data, dups


def bindings(instance):
    """({cap: [provider, ...]}, unreadable line or None), read the way hooks/guard.sh reads bind_ lines."""
    bound, bad = {}, None
    for line in _lines(instance / "instance.yaml"):
        if not line.startswith("bind_"):
            continue
        head, _, raw = line.partition(":")
        provider, cap = _guard_value(raw).lower(), head.rstrip(WS)[len("bind_"):]
        if not CAP.fullmatch(cap) or not PROVIDER.fullmatch(provider):
            bad = bad or re.sub(r"[\x00-\x1f]", "", line)[:80]
            continue
        bound.setdefault(cap, []).append(provider)
    return bound, bad


def listed(value):
    return [v.strip() for v in value.split(",") if v.strip()]


def invariants(cap):
    path = ROOT / "capabilities" / cap / "contract.md"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as err:
        raise CheckError(f"cannot read capabilities/{cap}/contract.md: {err}")
    found, inside = [], False
    for line in lines:
        if line.startswith("## "):
            inside = line[3:].strip() == "Invariants"
            continue
        m = INVARIANT.match(line) if inside else None
        if m:
            found.append(m.group(1))
    return found


def tool(instance, cap, provider):
    """(folder, identity dict read as guard.sh reads it) for a binding: a package tool or the instance's custom tool."""
    folder = instance / "custom-tools" / cap if provider == "custom" else ROOT / "capabilities" / cap / "tools" / provider
    if not (folder / "identity.yaml").is_file():
        if provider == "custom":
            raise CheckError(f"custom-tools/{cap}/ has no identity.yaml; run the add-tool skill")
        raise CheckError(f"no identity.yaml for {provider}")
    contract = ROOT / "capabilities" / cap / "contract.md"
    try:
        ops, invs = tool_check.read_contract(contract)
    except tool_check.ToolError as err:
        raise CheckError(str(err))
    label = f"custom-tools/{cap}" if provider == "custom" else f"capabilities/{cap}/tools/{provider}"
    fails, _ = tool_check.check_tool(folder, cap, ops, set(invs), provider == "custom", label)
    if fails:
        raise CheckError(f"the {provider} tool is not valid: " + "; ".join(fails))
    try:
        return folder, flat_yaml(folder / "identity.yaml")
    except CheckError as err:
        raise CheckError(f"the {provider} tool's {err}")


def covers(folder):
    policy = folder / "guard.yaml"
    if not policy.is_file():
        return []
    try:
        return guard_policy.parse(policy.read_text(encoding="utf-8"))["covers"]
    except (OSError, UnicodeDecodeError, guard_policy.PolicyError) as err:
        raise CheckError(f"{folder.name}/guard.yaml: {err}")


def utc_cron(when, tz):
    """UTC cron for `<day|daily> HH:MM` in tz, taken at the next occurrence."""
    m = WHEN.match(when.strip())
    day, hour, minute = m.group(1).lower(), int(m.group(2)), int(m.group(3))
    now = datetime.datetime.now(tz)
    local = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if day != "daily":
        local += datetime.timedelta(days=(DAYS.index(day) - local.weekday()) % 7)
    if local <= now:
        local += datetime.timedelta(days=1 if day == "daily" else 7)
    utc = local.astimezone(datetime.timezone.utc)
    dow = "*" if day == "daily" else str((utc.weekday() + 1) % 7)
    return f"{utc.minute} {utc.hour} * * {dow}"


def default_repo(instance, repo=None):
    return repo or instance.name or instance.resolve().name


def expected(instance, repo=None):
    """Everything check reports, as a dict."""
    meta, agent_dups = agent_yaml(ROOT / "agent.yaml")
    strict_name = flat_yaml(ROOT / "agent.yaml").get("name", "")
    if not strict_name:
        raise CheckError("agent.yaml has no name: line the guard can read")
    if strict_name != meta.get("name"):
        raise CheckError(f"agent.yaml name: is ambiguous (the guard reads {strict_name!r}, "
                         f"the validator reads {meta.get('name', '')!r})")
    inst = flat_yaml(instance / "instance.yaml")
    if not inst.get("agent"):
        raise CheckError("instance.yaml has no agent: line the guard can read")
    if inst.get("agent") != meta.get("name"):
        raise CheckError(f"instance.yaml agent {inst.get('agent')!r} is not {meta.get('name')!r}")
    bound, bad_line = bindings(instance)
    dups = []
    sched = flat_yaml(instance / "schedules.yaml", dups, guard=False)
    activities = {k[len("activity_"):]: listed(v) for k, v in meta.items() if k.startswith("activity_")}
    tzname = sched.get("timezone", "")
    try:
        tz = zoneinfo.ZoneInfo(tzname)
    except (ValueError, zoneinfo.ZoneInfoNotFoundError):
        raise CheckError(f"schedules.yaml: timezone {tzname!r} is not an IANA time zone")
    name = meta.get("name", "")
    env = sched.get("environment")
    env_problem = None
    if env is not None and not ENVIRONMENT.fullmatch(env):
        env_problem = f"schedules.yaml environment {env!r} is not env_<letters and digits>"
    orphans = [{"activity": k[len("routine_"):], "routine_id": v} for k, v in sched.items()
               if k.startswith("routine_") and f"schedule_{k[len('routine_'):]}" not in sched]
    repo_name = default_repo(instance, repo).split("/")[-1]
    result = {
        "agent": name, "version": meta.get("version", ""), "timezone": tzname,
        "env_setup": [f"# {name} {meta.get('version', '')}",
                      f"claude plugin marketplace add {meta.get('catalog_repo', '')}",
                      f"claude plugin install {name}@{meta.get('catalog', '')}"],
        "environment": env,  # None when schedules.yaml records none
        "entries": [], "orphans": orphans,
    }
    for key in sched:
        if not key.startswith("schedule_"):
            continue
        act = key[len("schedule_"):]
        entry = {"activity": act, "then": listed(sched.get(f"then_{act}", "")),
                 "schedule": sched[key], "routine_id": sched.get(f"routine_{act}", ""),
                 "problems": []}
        for k in (key, f"then_{act}"):
            if k in dups:
                entry["problems"].append(f"{k} appears more than once")
        if env_problem:
            entry["problems"].append(env_problem)
        if bad_line is not None:
            entry["problems"].append(f"instance.yaml has a binding line the guard cannot read ({bad_line})")
        if not meta.get("catalog") or not meta.get("catalog_repo"):
            entry["problems"].append("agent.yaml has no catalog/catalog_repo, so the cloud environment cannot install the agent")
        chain = [act] + entry["then"]
        for a in chain:
            if a not in activities:
                entry["problems"].append(f"{a} is not an activity of {name} (agent.yaml activity_*)")
            elif f"activity_{a}" in agent_dups:
                entry["problems"].append(f"agent.yaml declares activity_{a} more than once")
        if not WHEN.match(entry["schedule"].strip()):
            entry["problems"].append(f"schedule {entry['schedule']!r} is not '<weekday|daily> HH:MM'")
        caps = []
        for a in chain:
            for cap in activities.get(a, []):
                if cap != "none" and cap not in caps:
                    caps.append(cap)
        entry["capabilities"] = caps
        connectors, matches, binds = [], [], []
        for cap in caps:
            if not CAP.fullmatch(cap):
                entry["problems"].append(f"capability name {cap!r} in agent.yaml is not [a-z0-9_]+")
                continue
            providers = bound.get(cap, [])
            if not providers:
                entry["problems"].append(f"{cap} is not bound (run setup's tools step or the add-tool skill)")
                continue
            if len(providers) > 1:
                entry["problems"].append(f"{cap} is bound more than once; the guard applies every binding")
            invs = invariants(cap)
            for provider in providers:
                try:
                    folder, ay = tool(instance, cap, provider)
                    covered = covers(folder)
                except CheckError as err:
                    entry["problems"].append(f"{cap}: {err}")
                    continue
                match = ay.get("server_match", "")  # exactly what yaml_get returns; no further trimming
                if not match:
                    entry["problems"].append(
                        f"{cap}: the {provider} tool has no server_match, so the guard never enforces it")
                elif not SERVER_MATCH.fullmatch(match):
                    entry["problems"].append(
                        f"{cap}: the {provider} tool's server_match {match!r} can never match an MCP tool name, "
                        "so the guard never enforces it")
                for inv in invs:
                    if inv not in covered:
                        entry["problems"].append(
                            f"{cap}: invariant {inv} is not covered by the {provider} tool's guard policy")
                connectors.append(ay.get("provider", provider))
                matches.append(match)
                binds.append({"capability": cap, "provider": provider, "server_match": match})
        entry["connectors"], entry["server_matches"], entry["bindings"] = connectors, matches, binds
        entry["ok"] = not entry["problems"]
        entry["routine_name"] = f"{name}: {act} ({repo_name})"
        entry["prompt"] = "Scheduled run of " + ", then ".join(f"`{a}`" for a in chain) + " " + PROMPT_TAIL
        entry["utc_cron"] = utc_cron(entry["schedule"], tz) if WHEN.match(entry["schedule"].strip()) else ""
        result["entries"].append(entry)
    if not result["entries"]:
        raise CheckError("schedules.yaml has no schedule_<activity> entries"
                         + "".join(f"; {_orphan(o)}" for o in orphans))
    return result


def _orphan(o):
    return (f"routine_{o['activity']}: {o['routine_id']} has no schedule_{o['activity']} entry, but the routine "
            f"still runs without this gate — disable or delete routine {o['routine_id']} in the web UI, "
            "then remove this line")


def repo_parts(text):
    """(owner or None, name), lowercased, from owner/name, a bare name, or a GitHub URL; None if unreadable."""
    text = (text or "").strip()
    m = GITHUB.match(text)
    if m:
        return m.group(1).lower(), m.group(2).lower()
    if "://" in text or "@" in text:
        return None
    text = text.rstrip("/")
    text = text[:-4] if text.endswith(".git") else text
    parts = text.split("/")
    if not parts[-1]:
        return None
    return (parts[-2].lower() if len(parts) > 1 else None), parts[-1].lower()


def _content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text", "") if isinstance(b, dict) and isinstance(b.get("text"), str)
                       else b if isinstance(b, str) else "" for b in content)
    return ""


def verify(instance, activity, routine, repo=None):
    """Mismatches between a routine (API JSON) and what check expects for activity."""
    repo = default_repo(instance, repo)
    full = expected(instance, repo)
    exp = next((e for e in full["entries"] if e["activity"] == activity), None)
    if exp is None:
        raise CheckError(f"schedules.yaml has no schedule_{activity}")
    problems = []

    def obj(parent, key, label):
        val = parent.get(key)
        if val is None:
            return {}
        if not isinstance(val, dict):
            problems.append(f"{label} is not an object")
            return {}
        return val

    def items(parent, key, label):
        val = parent.get(key)
        if val is None:
            return []
        if not isinstance(val, list):
            problems.append(f"{label} is not a list")
            return []
        good = [v for v in val if isinstance(v, dict)]
        if len(good) != len(val):
            problems.append(f"{label} has an entry that is not an object")
        return good

    r = routine
    if "trigger" in routine:
        r = routine["trigger"]
        if not isinstance(r, dict):
            problems.append("trigger is not an object")
            r = {}
    ccr = obj(obj(r, "job_config", "job_config"), "ccr", "job_config.ccr")
    ctx = obj(ccr, "session_context", "session_context")
    if not exp["ok"]:
        problems.append(f"{activity} does not pass the unattended gate: " + "; ".join(exp["problems"]))
    if r.get("enabled") is not True:
        problems.append("the routine is not enabled")
    raw_sources = ctx.get("sources")
    count = len(raw_sources) if isinstance(raw_sources, list) else 0 if raw_sources is None else None
    if count is not None and count != 1:
        problems.append(f"the routine has {count} repository sources; it must clone exactly one, "
                        "this instance's repository")
    raw_env = ccr.get("environment_id")
    good_env = isinstance(raw_env, str) and ENVIRONMENT.fullmatch(raw_env)
    env = raw_env if good_env else json.dumps(raw_env) if isinstance(raw_env, str) and raw_env else "unknown"
    if full["environment"] is None:
        problems.append(f"schedules.yaml records no environment; this routine uses {env} — confirm it is the "
                        f"environment whose setup script installs this agent, then add environment: {env}")
    elif not good_env or raw_env != full["environment"]:
        problems.append(f"the routine uses environment {env}, not {full['environment']} from schedules.yaml; "
                        "any other environment runs the agent with no guard")
    urls = []
    for s in items(ctx, "sources", "session_context.sources"):
        url = obj(s, "git_repository", "a source's git_repository").get("url")
        if isinstance(url, str):
            urls.append(url)
    want = repo_parts(repo)
    if want:
        def same(url):
            got = repo_parts(url) if GITHUB.match(url.strip()) else None
            return bool(got) and got[1] == want[1] and (want[0] is None or got[0] == want[0])
        if not any(same(u) for u in urls):
            clones = ", ".join(urls) or "nothing"
            if want[0] is None:
                problems.append(f"the routine does not clone a repository named {want[1]} "
                                f"(no owner is known, so only the name was compared; it clones: {clones})")
            else:
                problems.append(f"the routine does not clone {repo} (it clones: {clones})")
    prompts = []
    for e in items(ccr, "events", "events"):
        prompts.append(_content(obj(obj(e, "data", "an event's data"), "message", "an event's message").get("content")).strip())
    if exp["prompt"] not in prompts:
        problems.append("the routine's prompt is not the scheduled prompt for this entry")
    conns = items(r, "mcp_connections", "mcp_connections")
    names = [c["name"].lower() for c in conns if isinstance(c.get("name"), str)]
    for b in exp["bindings"]:
        if b["server_match"] and not any(b["server_match"] in n for n in names):
            problems.append(f"no connector whose name contains \"{b['server_match']}\" is attached "
                            f"({b['capability']}: {b['provider']})")
    bound = [b["server_match"] for b in exp["bindings"] if b["server_match"]]
    for c in conns:
        name = c.get("name")
        if not isinstance(name, str) or not name:
            problems.append("a connector with no readable name is attached; it would run with no guard "
                            "— remove it from the routine")
        elif not any(m in name.lower() for m in bound):
            problems.append(f"connector {json.dumps(name)} matches no bound server_match "
                            f"({', '.join(bound) or 'none'}), so it would run with no guard — remove it from the routine")
    nxt = r.get("next_run_at")
    m = WHEN.match(exp["schedule"].strip())
    if not isinstance(nxt, str):
        problems.append(f"the routine has no readable next_run_at ({nxt!r})")
    elif m:
        try:
            when = datetime.datetime.fromisoformat(nxt.strip().replace("Z", "+00:00"))
            if when.tzinfo is None:
                when = when.replace(tzinfo=datetime.timezone.utc)
            when = when.astimezone(zoneinfo.ZoneInfo(full["timezone"]))
        except (ValueError, TypeError, OverflowError):
            problems.append(f"the routine has no readable next_run_at ({nxt!r})")
        else:
            day, hh, mm = m.group(1).lower(), int(m.group(2)), int(m.group(3))
            if (when.hour, when.minute) != (hh, mm) or (day != "daily" and DAYS[when.weekday()] != day):
                problems.append(f"next run is {when:%A %H:%M} local, not {exp['schedule']}")
    return problems


def _text(result):
    out = [f"{result['agent']} {result['version']} — timezone {result['timezone']}", "",
           "Cloud environment setup script (merge with other agents' lines; keep the version comment current):"]
    out += ["    " + line for line in result["env_setup"]]
    out.append(f"environment: {'(none recorded in schedules.yaml)' if result['environment'] is None else result['environment']}")
    for o in result["orphans"]:
        out += ["", f"FAIL  {_orphan(o)}"]
    for e in result["entries"]:
        out += ["", f"{'PASS' if e['ok'] else 'FAIL'}  {e['routine_name']}"]
        for p in e["problems"]:
            out.append(f"  - {p}")
        if e["ok"]:
            shown = [f'{p} (matches "{m}")' if m else p for p, m in zip(e["connectors"], e["server_matches"])]
            out += [f"  schedule: {e['schedule']} {result['timezone']}  (UTC cron: {e['utc_cron']})",
                    f"  connectors: {', '.join(shown) or 'none'}",
                    f"  prompt: {e['prompt']}"]
            if e["routine_id"]:
                out.append(f"  recorded routine: {e['routine_id']}")
    return "\n".join(out)


def main(argv):
    args, repo, as_json = [], None, False
    it = iter(argv)
    for a in it:
        if a == "--repo":
            repo = next(it, None)
        elif a == "--json":
            as_json = True
        else:
            args.append(a)
    try:
        if len(args) == 2 and args[0] == "check":
            result = expected(pathlib.Path(args[1]), repo)
            print(json.dumps(result, indent=2) if as_json else _text(result))
            return 0 if all(e["ok"] for e in result["entries"]) and not result["orphans"] else 1
        if len(args) == 4 and args[0] == "verify":
            with open(args[3], encoding="utf-8") as fh:
                routine = json.load(fh)
            if not isinstance(routine, dict):
                raise CheckError("the routine JSON is not an object")
            problems = verify(pathlib.Path(args[1]), args[2], routine, repo)
            for p in problems:
                print(f"MISMATCH: {p}")
            if not problems:
                print(f"OK: the routine matches schedule_{args[2]}")
            return 1 if problems else 0
    except (CheckError, OSError, json.JSONDecodeError) as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 2
    except Exception as err:  # never a traceback
        print(f"ERROR: {type(err).__name__}: {err}", file=sys.stderr)
        return 2
    print("\n".join(__doc__.strip().splitlines()[2:5]), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
