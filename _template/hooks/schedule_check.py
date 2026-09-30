#!/usr/bin/env python3
"""Agent Standard schedule checker — identical in every agent.

Usage:
  schedule_check.py check <instance-dir> [--repo owner/name] [--json]
  schedule_check.py verify <instance-dir> <activity> <routine.json> [--repo owner/name]

check  — for every schedule_<activity> in the instance's schedules.yaml:
         applies the unattended gate (every capability its activities use is
         bound, and every contract invariant is in the bound adapter's
         guard.yaml covers) and prints what the user needs to create the
         routine: name, schedule and UTC cron, connectors, prompt, and the
         cloud-environment setup script. Exit 0 when every entry passes,
         1 when any entry fails, 2 on usage or read errors.
verify — compares a routine (the JSON the routines API returns for it,
         with or without a top-level "trigger" wrapper) against what check
         expects for <activity>. Exit 0 on a match, 1 with one line per
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
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "hooks"))
import guard_policy  # noqa: E402  (same folder, reference engine)

DAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
WHEN = re.compile(r"^(monday|tuesday|wednesday|thursday|friday|saturday|sunday|daily) ([01]\d|2[0-3]):([0-5]\d)$", re.I)
INVARIANT = re.compile(r"^[-*]\s+`([^`]+)`")
PROMPT_TAIL = ("(unattended). Follow this agent's instructions for each activity, in order. "
               "Do not ask questions and do not edit or commit files in this repository. "
               "If something needs the operator, stop and say exactly what.")


class CheckError(Exception):
    """The instance or package cannot be read."""


def _value(raw):
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        end = raw.find(raw[0], 1)
        if end != -1:
            return raw[1:end]
    return re.sub(r"(^|\s)#.*$", "", raw).strip()


def flat_yaml(path):
    """Top-level `key: value` pairs of a flat YAML file (a leading BOM is ignored)."""
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as err:
        raise CheckError(f"cannot read {path.name}: {err}")
    data = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#") or line[0] in " \t" or ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = _value(value)
    return data


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


def adapter(instance, cap, provider):
    """(folder, adapter.yaml dict) for a binding; package adapter or instance custom adapter."""
    folder = instance / "custom-adapters" / cap if provider == "custom" else ROOT / "capabilities" / cap / "adapters" / provider
    if not (folder / "adapter.yaml").is_file():
        raise CheckError(f"no adapter.yaml for {cap} ({provider})")
    return folder, flat_yaml(folder / "adapter.yaml")


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


def expected(instance, repo=None):
    """Everything check reports, as a dict."""
    meta = flat_yaml(ROOT / "agent.yaml")
    inst = flat_yaml(instance / "instance.yaml")
    if inst.get("agent") != meta.get("name"):
        raise CheckError(f"instance.yaml agent {inst.get('agent')!r} is not {meta.get('name')!r}")
    sched = flat_yaml(instance / "schedules.yaml")
    activities = {k[len("activity_"):]: listed(v) for k, v in meta.items() if k.startswith("activity_")}
    tzname = sched.get("timezone", "")
    try:
        tz = zoneinfo.ZoneInfo(tzname)
    except (ValueError, zoneinfo.ZoneInfoNotFoundError):
        raise CheckError(f"schedules.yaml: timezone {tzname!r} is not an IANA time zone")
    name = meta.get("name", "")
    repo_name = (repo or instance.name).split("/")[-1]
    result = {
        "agent": name, "version": meta.get("version", ""), "timezone": tzname,
        "env_setup": [f"# {name} {meta.get('version', '')}",
                      f"claude plugin marketplace add {meta.get('catalog_repo', '')}",
                      f"claude plugin install {name}@{meta.get('catalog', '')}"],
        "entries": [],
    }
    for key in sched:
        if not key.startswith("schedule_"):
            continue
        act = key[len("schedule_"):]
        entry = {"activity": act, "then": listed(sched.get(f"then_{act}", "")),
                 "schedule": sched[key], "routine_id": sched.get(f"routine_{act}", ""),
                 "problems": []}
        chain = [act] + entry["then"]
        for a in chain:
            if a not in activities:
                entry["problems"].append(f"{a} is not an activity of {name} (agent.yaml activity_*)")
        if not WHEN.match(entry["schedule"].strip()):
            entry["problems"].append(f"schedule {entry['schedule']!r} is not '<weekday|daily> HH:MM'")
        caps = []
        for a in chain:
            for cap in activities.get(a, []):
                if cap != "none" and cap not in caps:
                    caps.append(cap)
        entry["capabilities"] = caps
        connectors = []
        for cap in caps:
            provider = inst.get(f"bind_{cap}", "").lower()
            if not provider:
                entry["problems"].append(f"{cap} is not bound (run setup's tools step)")
                continue
            folder, ay = adapter(instance, cap, provider)
            covered = covers(folder)
            for inv in invariants(cap):
                if inv not in covered:
                    entry["problems"].append(
                        f"{cap}: invariant {inv} is not covered by the {provider} adapter's guard policy")
            connectors.append(ay.get("provider", provider))
        entry["connectors"] = connectors
        entry["ok"] = not entry["problems"]
        entry["routine_name"] = f"{name}: {act} ({repo_name})"
        entry["prompt"] = "Scheduled run of " + ", then ".join(f"`{a}`" for a in chain) + " " + PROMPT_TAIL
        entry["utc_cron"] = utc_cron(entry["schedule"], tz) if WHEN.match(entry["schedule"].strip()) else ""
        result["entries"].append(entry)
    if not result["entries"]:
        raise CheckError("schedules.yaml has no schedule_<activity> entries")
    return result


def verify(instance, activity, routine, repo=None):
    """Mismatches between a routine (API JSON) and what check expects for activity."""
    full = expected(instance, repo)
    exp = next((e for e in full["entries"] if e["activity"] == activity), None)
    if exp is None:
        raise CheckError(f"schedules.yaml has no schedule_{activity}")
    r = routine.get("trigger", routine)
    ccr = (r.get("job_config") or {}).get("ccr") or {}
    problems = []
    if not exp["ok"]:
        problems.append(f"{activity} does not pass the unattended gate: " + "; ".join(exp["problems"]))
    if not r.get("enabled"):
        problems.append("the routine is not enabled")
    sources = [s.get("git_repository", {}).get("url", "") for s in (ccr.get("session_context") or {}).get("sources", [])]
    if repo and not any(u.rstrip("/").lower().endswith("/" + repo.lower()) for u in sources):
        problems.append(f"the routine does not clone {repo} (it clones: {', '.join(sources) or 'nothing'})")
    prompts = [((e.get("data") or {}).get("message") or {}).get("content", "") for e in ccr.get("events", [])]
    if exp["prompt"] not in [p.strip() for p in prompts]:
        problems.append("the routine's prompt is not the scheduled prompt for this entry")
    names = [c.get("name", "").lower() for c in r.get("mcp_connections", [])]
    for provider in exp["connectors"]:
        if not any(provider.lower() in n for n in names):
            problems.append(f"no {provider} connector is attached")
    nxt = r.get("next_run_at", "")
    try:
        when = datetime.datetime.fromisoformat(nxt.replace("Z", "+00:00")).astimezone(zoneinfo.ZoneInfo(full["timezone"]))
    except (ValueError, TypeError):
        problems.append(f"the routine has no readable next_run_at ({nxt!r})")
    else:
        m = WHEN.match(exp["schedule"].strip())
        day, hh, mm = m.group(1).lower(), int(m.group(2)), int(m.group(3))
        if (when.hour, when.minute) != (hh, mm) or (day != "daily" and DAYS[when.weekday()] != day):
            problems.append(f"next run is {when:%A %H:%M} local, not {exp['schedule']}")
    return problems


def _text(result):
    out = [f"{result['agent']} {result['version']} — timezone {result['timezone']}", "",
           "Cloud environment setup script (merge with other agents' lines; keep the version comment current):"]
    out += ["    " + line for line in result["env_setup"]]
    for e in result["entries"]:
        out += ["", f"{'PASS' if e['ok'] else 'FAIL'}  {e['routine_name']}"]
        for p in e["problems"]:
            out.append(f"  - {p}")
        if e["ok"]:
            out += [f"  schedule: {e['schedule']} {result['timezone']}  (UTC cron: {e['utc_cron']})",
                    f"  connectors: {', '.join(e['connectors']) or 'none'}",
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
            return 0 if all(e["ok"] for e in result["entries"]) else 1
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
    print(__doc__.strip().splitlines()[2], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
