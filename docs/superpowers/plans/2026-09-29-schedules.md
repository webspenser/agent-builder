# Scheduled Runs (Agent Standard 2.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let agents run activities on Claude cloud routines only when every capability they use is guarded: Agent Standard 2.1 (activities, `schedules.yaml`, the scheduled prompt, a schedule skill, a checker script), agent-builder 2.1.0 and sales-partner 2.1.0.

**Architecture:** `hooks/schedule_check.py` (stdlib, byte-identical in every agent, beside `guard_policy.py`) applies the unattended gate to an instance's `schedules.yaml`, prints the routine form values and the cloud-environment setup script, and verifies a routine's API JSON against them. The generic `schedule` skill walks the user through it and uses the routines API only to read and optionally run. The validator checks `activity_*` declarations.

**Tech Stack:** Python 3 standard library (`zoneinfo`), bash, markdown/YAML, Claude Code routines (research preview) via `RemoteTrigger`.

**Spec:** `docs/superpowers/specs/2026-09-29-schedules-design.md` (builder repo).

## Global Constraints

- No backward compatibility: the validator accepts only `standard: "2.1"`; sales-partner moves in the same release.
- Builder checkout `/Users/hochoy/Work/Webspenser/agent-library`, branch `feat/standard-2.1` from `spec/schedules`. sales-partner checkout `/Users/hochoy/Work/Webspenser/sales-partner`, branch `release/2.1.0` from `main`.
- Versions: builder `2.1.0`; sales-partner `2.1.0`; standard `"2.1"`.
- `hooks/schedule_check.py` mode 755, byte-identical to builder `_template/hooks/schedule_check.py`; CLI `check <instance> [--repo owner/name] [--json]` and `verify <instance> <activity> <routine.json> [--repo owner/name]`; exits 0 ok / 1 failing entries or mismatches / 2 errors; never tracebacks; imports `guard_policy` from its own folder.
- `agent.yaml` activity keys: `activity_<kebab-name>: <capability>[, <capability>…]` or `none`.
- `schedules.yaml` keys: `timezone` (IANA), `schedule_<activity>: "<Monday…Sunday|daily> HH:MM"`, `then_<activity>: a, b`, `routine_<activity>: <id>`.
- Scheduled prompt (exact): ``Scheduled run of `<activity>`[, then `<next>`…] (unattended). Follow this agent's instructions for each activity, in order. Do not ask questions and do not edit or commit files in this repository. If something needs the operator, stop and say exactly what.``
- Never create, run, or change routines, and never call Attio/Gmail/Airtable tools, outside Task 5.
- Never commit `.pyc`/`__pycache__`; run python with `-B` in tests.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Scripts mode 100755 (check `git ls-files -s`). The bash-guard hook blocks compound commands resembling exfiltration and anything containing "credentials"; use simple separate commands.

## Review Focus

1. **Gate through `then`** — an entry whose `then` activity uses an unbound or uncovered capability fails. Pinned in Task 1 (test "then activity's capabilities are gated").
2. **Verification drift** — disabled, wrong repo, edited prompt, missing connector, wrong day/time each produce a `MISMATCH`. Pinned in Task 1.
3. **Timezone** — day shifts across midnight in the UTC cron; unknown zones are errors. Pinned in Task 1.
4. **Unattended behavior** — no sales-partner schedulable step asks questions or edits instance files. Pinned by content tests in Task 4.
5. **Stale plugin in the cloud** — the skill always prints the version comment and says to update it. Pinned by the skill text (Task 3) and acceptance (Task 5).

---

## Builder (tasks 1–3)

### Task 1: The schedule checker

**Files:**
- Create: `_template/hooks/schedule_check.py` (755), `tests/test-schedule-check.sh` (755)
- Modify: `tests/run-all.sh` — add `echo "== schedule check"; tests/test-schedule-check.sh || STATUS=1` after the `== guard policy` line

**Interfaces:**
- Consumes: `_template/hooks/guard_policy.py` (`parse`, `PolicyError`).
- Produces: the CLI above; Task 2's validator byte-compares the script; Task 3's skill calls it; Task 4 copies it.

- [ ] **Step 1: Branch** — `git -C /Users/hochoy/Work/Webspenser/agent-library switch -c feat/standard-2.1 spec/schedules`
- [ ] **Step 2: Failing tests** — `tests/test-schedule-check.sh`:

```bash
#!/usr/bin/env bash
# Behavior of the Agent Standard schedule checker (_template/hooks/schedule_check.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PKG="$W/pkg"; mkdir -p "$PKG/hooks"
cp _template/hooks/schedule_check.py _template/hooks/guard_policy.py "$PKG/hooks/"
SC="$PKG/hooks/schedule_check.py"
printf '%s\n' 'name: demo-agent' 'version: 2.1.0' 'description: Demo' 'standard: "2.1"' \
  'catalog: webspenser' 'catalog_repo: webspenser/agent-library' 'capabilities: crm, email_drafts' \
  'activity_research: none' 'activity_prospect: crm' 'activity_digest: crm, email_drafts' > "$PKG/agent.yaml"
mkdir -p "$PKG/capabilities/crm/adapters/good" "$PKG/capabilities/crm/adapters/half" "$PKG/capabilities/crm/adapters/bare" "$PKG/capabilities/email_drafts/adapters/mail"
printf '%s\n' '# CRM' '' '## Operations' '' '| `get` | x |' '' '## Invariants' '' '- `draft_only` — x' '- `no_delete` — y' > "$PKG/capabilities/crm/contract.md"
printf '%s\n' '# Email' '' '## Operations' '' '| `draft` | x |' '' '## Invariants' '' '- `no_send` — x' > "$PKG/capabilities/email_drafts/contract.md"
printf '%s\n' 'capability: crm' 'provider: good' 'server_match: goodcrm' > "$PKG/capabilities/crm/adapters/good/adapter.yaml"
printf '%s\n' 'covers: [draft_only, no_delete]' 'deny: ["*delete*"]' > "$PKG/capabilities/crm/adapters/good/guard.yaml"
printf '%s\n' 'capability: crm' 'provider: half' 'server_match: halfcrm' > "$PKG/capabilities/crm/adapters/half/adapter.yaml"
printf '%s\n' 'covers: [draft_only]' > "$PKG/capabilities/crm/adapters/half/guard.yaml"
printf '%s\n' 'capability: crm' 'provider: bare' 'server_match: barecrm' > "$PKG/capabilities/crm/adapters/bare/adapter.yaml"
printf '%s\n' 'capability: email_drafts' 'provider: mail' 'server_match: mail' > "$PKG/capabilities/email_drafts/adapters/mail/adapter.yaml"
printf '%s\n' 'covers: [no_send]' 'deny: ["*send*"]' > "$PKG/capabilities/email_drafts/adapters/mail/guard.yaml"

instance() { # instance <dir> <crm provider|-> <email provider|-> <schedule lines...>
  local d="$1" crm="$2" mail="$3"; shift 3
  mkdir -p "$d"
  { echo 'agent: demo-agent'; echo 'agent_version: 2.1.0'; echo 'mode: plugin'
    [ "$crm" = - ] || echo "bind_crm: $crm"; [ "$mail" = - ] || echo "bind_email_drafts: $mail"; } > "$d/instance.yaml"
  printf '%s\n' "$@" > "$d/schedules.yaml"
}
run() { OUT=$(python3 -B "$SC" "$@" 2>&1); RC=$?; }
expect() { # expect <rc> <label> [text]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; } && ! printf '%s' "$OUT" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}

echo "-- gate"
I="$W/ok"; instance "$I" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'then_prospect: research' 'schedule_digest: "Monday 08:00"'
run check "$I" --repo acme/sales;                  expect 0 "all entries pass" "PASS  demo-agent: prospect (sales)"
expect 0 "digest passes" "PASS  demo-agent: digest (sales)"
expect 0 "env setup script" "claude plugin install demo-agent@webspenser"
expect 0 "version comment" "# demo-agent 2.1.0"
expect 0 "UTC cron" "(UTC cron: 0 7 * * 1)"
expect 0 "connectors" "connectors: good, mail"
expect 0 "prompt with then" 'prompt: Scheduled run of `prospect`, then `research` (unattended). Follow this agent'"'"'s instructions for each activity, in order.'
N="$W/nomail"; instance "$N" good - 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'schedule_digest: "Monday 08:00"'
run check "$N";                                    expect 1 "unbound capability fails its entry" "email_drafts is not bound"
expect 1 "other entry still passes" "PASS  demo-agent: prospect (nomail)"
H="$W/half"; instance "$H" half mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$H";                                    expect 1 "uncovered invariant fails" "crm: invariant no_delete is not covered by the half adapter's guard policy"
B="$W/bare"; instance "$B" bare mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$B";                                    expect 1 "adapter without a policy fails" "invariant draft_only is not covered"
T="$W/then"; instance "$T" good - 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'then_prospect: digest'
run check "$T";                                    expect 1 "then activity's capabilities are gated" "email_drafts is not bound"
R="$W/none"; instance "$R" - - 'timezone: UTC' 'schedule_research: "daily 06:30"'
run check "$R";                                    expect 0 "activity using no capability needs no binding" "(UTC cron: 30 6 * * *)"
U="$W/unknown"; instance "$U" good mail 'timezone: UTC' 'schedule_launch: "Monday 07:00"'
run check "$U";                                    expect 1 "unknown activity fails" "launch is not an activity of demo-agent"
X="$W/badwhen"; instance "$X" good mail 'timezone: UTC' 'schedule_prospect: "Mondays at 7"'
run check "$X";                                    expect 1 "bad schedule fails" "is not '<weekday|daily> HH:MM'"
C="$W/custom"; instance "$C" custom mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mkdir -p "$C/custom-adapters/crm"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: mycrm' > "$C/custom-adapters/crm/adapter.yaml"
printf '%s\n' 'covers: [draft_only, no_delete]' > "$C/custom-adapters/crm/guard.yaml"
run check "$C";                                    expect 0 "custom adapter with full policy passes" "connectors: custom"

echo "-- time zones"
K="$W/kolkata"; instance "$K" good mail 'timezone: Asia/Kolkata' 'schedule_prospect: "Monday 03:00"'
run check "$K";                                    expect 0 "day shifts back across midnight" "(UTC cron: 30 21 * * 0)"
Z="$W/badtz"; instance "$Z" good mail 'timezone: Mars/Olympus' 'schedule_prospect: "Monday 07:00"'
run check "$Z";                                    expect 2 "unknown time zone is an error" "not an IANA time zone"

echo "-- errors"
E="$W/empty"; instance "$E" good mail 'timezone: UTC'
run check "$E";                                    expect 2 "no entries is an error" "no schedule_<activity> entries"
O="$W/other"; instance "$O" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; sed -i.bak 's/^agent: .*/agent: someone-else/' "$O/instance.yaml"
run check "$O";                                    expect 2 "another agent's instance is an error" "is not 'demo-agent'"
run check "$W/missing";                            expect 2 "missing instance is an error" "cannot read instance.yaml"
run bogus;                                         expect 2 "usage" "Usage"
run check "$I" --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["entries"][0]["ok"] and d["entries"][0]["connectors"]==["good"]' \
  && _report ok "json output" || _report no "json output: $OUT"

echo "-- verify"
PROMPT='Scheduled run of `prospect`, then `research` (unattended). Follow this agent'"'"'s instructions for each activity, in order. Do not ask questions and do not edit or commit files in this repository. If something needs the operator, stop and say exactly what.'
routine() { # routine <file> <enabled> <repo url> <prompt> <connector name> <next_run_at> [wrap]
  python3 -B - "$@" <<'PY'
import json, sys
f, enabled, url, prompt, conn, nxt = sys.argv[1:7]
r = {"enabled": enabled == "true", "next_run_at": nxt,
     "job_config": {"ccr": {"session_context": {"sources": [{"git_repository": {"url": url}}]},
                            "events": [{"data": {"message": {"role": "user", "content": prompt}}}]}},
     "mcp_connections": [{"name": conn}] if conn else []}
if len(sys.argv) > 7:
    r = {"trigger": r}
json.dump(r, open(f, "w"))
PY
}
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" Good 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "matching routine" "OK: the routine matches schedule_prospect"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" Good 2026-10-05T07:00:00Z wrap
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "API wrapper accepted"
routine "$W/r.json" false https://github.com/acme/sales "$PROMPT" Good 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "disabled" "the routine is not enabled"
routine "$W/r.json" true https://github.com/acme/other "$PROMPT" Good 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "wrong repo" "does not clone acme/sales"
routine "$W/r.json" true https://github.com/acme/sales "Do the prospecting" Good 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "edited prompt" "is not the scheduled prompt"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "" 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "missing connector" "no good connector is attached"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" Good 2026-10-05T08:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "wrong time" "next run is Monday 08:00 local, not Monday 07:00"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" Good 2026-10-06T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "wrong day" "next run is Tuesday 07:00 local"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" Good 2026-10-05T07:00:00Z
run verify "$N" digest "$W/r.json";                      expect 1 "gate failure reported by verify" "does not pass the unattended gate"
run verify "$I" nothing "$W/r.json";                     expect 2 "unknown entry" "no schedule_nothing"
echo '[1]' > "$W/r.json"
run verify "$I" prospect "$W/r.json";                    expect 2 "routine JSON not an object" "not an object"
[ -x _template/hooks/schedule_check.py ] && _report ok "script executable" || _report no "script not executable"

finish
```

`chmod 755`; add the run-all line; run it — every case fails (no script).

- [ ] **Step 3: `_template/hooks/schedule_check.py`**

```python
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
```

`chmod 755 _template/hooks/schedule_check.py`.

- [ ] **Step 4:** `tests/test-schedule-check.sh` → `0 failed` (dry-run while planning: 35/35); `tests/run-all.sh` → ALL GREEN; `git status` shows no `.pyc`.
- [ ] **Step 5: Commit** — `git add _template/hooks/schedule_check.py tests/test-schedule-check.sh tests/run-all.sh` then `git commit -m "feat: schedule checker (Agent Standard 2.1)"`.

---

### Task 2: Validator and template for 2.1

**Files:**
- Modify: `bin/lib/check_manifests.py`, `tests/test-validate-agent.sh`, `_template/agent.yaml`, `tests/run-all.sh`

**Interfaces:**
- Consumes: `_template/hooks/schedule_check.py` (Task 1).

- [ ] **Step 1: Failing tests.** In `tests/test-validate-agent.sh`:
  - In `make_valid_agent`: write `standard: "2.1"` instead of `"2.0"`; copy `_template/hooks/schedule_check.py` into `$d/hooks/` with the other hooks and `chmod 755` it.
  - Change the old-standard case to reject `standard: "2.0"` with `fails_with … "agent.yaml: standard '2.0' is not 2.1; update the agent to the current Agent Standard"` (rename the fixture accordingly).
  - Add before `finish`:

```bash
echo "-- Agent Standard 2.1: activities"
make_valid_agent "$FIX/act"; printf '%s\n' 'activity_prospect: crm' 'activity_research: none' >> "$FIX/act/agent.yaml"
mkdir -p "$FIX/act/skills/schedule"; printf '%s\n' '---' 'name: schedule' 'description: Use when scheduling' '---' 'x' > "$FIX/act/skills/schedule/SKILL.md"
assert_pass $V "$FIX/act"
make_valid_agent "$FIX/act-noskill"; echo 'activity_prospect: crm' >> "$FIX/act-noskill/agent.yaml"
fails_with "$FIX/act-noskill" "missing skills/schedule/SKILL.md (agent.yaml declares activities)"
make_valid_agent "$FIX/act-badcap"; echo 'activity_prospect: crm, calendar' >> "$FIX/act-badcap/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-badcap/skills/"
fails_with "$FIX/act-badcap" "agent.yaml: activity_prospect uses calendar, which is not in capabilities"
make_valid_agent "$FIX/act-badname"; echo 'activity_Prospect_Now: crm' >> "$FIX/act-badname/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-badname/skills/"
fails_with "$FIX/act-badname" "agent.yaml: activity 'Prospect_Now' is not kebab-case"
make_valid_agent "$FIX/act-empty"; echo 'activity_prospect:' >> "$FIX/act-empty/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-empty/skills/"
fails_with "$FIX/act-empty" "agent.yaml: activity_prospect lists no capabilities (use none)"
make_valid_agent "$FIX/act-mixed"; echo 'activity_prospect: none, crm' >> "$FIX/act-mixed/agent.yaml"; cp -R "$FIX/act/skills/schedule" "$FIX/act-mixed/skills/"
fails_with "$FIX/act-mixed" "agent.yaml: activity_prospect mixes none with capabilities"
make_valid_agent "$FIX/act-noscript"; rm "$FIX/act-noscript/hooks/schedule_check.py"
fails_with "$FIX/act-noscript" "missing hooks/schedule_check.py"
make_valid_agent "$FIX/act-editscript"; echo "# x" >> "$FIX/act-editscript/hooks/schedule_check.py"
fails_with "$FIX/act-editscript" "hooks/schedule_check.py differs from the Agent Standard reference copy (_template/hooks/schedule_check.py in agent-builder)"
```

  In `tests/run-all.sh`, the template checks become `standard: "2.1"` ("template is Agent Standard 2.1"). Run: failures.

- [ ] **Step 2: Implement** in `bin/lib/check_manifests.py`:
  - `CURRENT_STANDARD = "2.1"`.
  - After `REFERENCE_POLICY`, add `REFERENCE_SCHEDULE = TEMPLATE_HOOKS / "schedule_check.py"` and `ACTIVITY = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")`.
  - Add:

```python
def check_activities(root, meta, caps):
    """activity_<name>: capabilities (or none); a schedule skill when any exist."""
    fails = []
    acts = {k[len("activity_"):]: v for k, v in meta.items() if k.startswith("activity_")}
    for act, value in sorted(acts.items()):
        if not ACTIVITY.match(act):
            fails.append(f"agent.yaml: activity '{act}' is not kebab-case")
        names = [c.strip() for c in value.split(",") if c.strip()]
        if not names:
            fails.append(f"agent.yaml: activity_{act} lists no capabilities (use none)")
        if "none" in names and len(names) > 1:
            fails.append(f"agent.yaml: activity_{act} mixes none with capabilities")
        for cap in names:
            if cap != "none" and cap not in caps:
                fails.append(f"agent.yaml: activity_{act} uses {cap}, which is not in capabilities")
    if acts and not (root / "skills" / "schedule" / "SKILL.md").is_file():
        fails.append("missing skills/schedule/SKILL.md (agent.yaml declares activities)")
    return fails
```

  - In `check_tools`, after the `guard_policy.py` reference check add `fails.extend(check_reference_script(root, "hooks/schedule_check.py", REFERENCE_SCHEDULE))`, and after `caps` is computed add `fails.extend(check_activities(root, meta, caps))`.
- [ ] **Step 3: `_template/agent.yaml`** → `standard: "2.1"`.
- [ ] **Step 4: Verify** — `tests/run-all.sh` ALL GREEN (the template validates as 2.1; it declares no activities, so no schedule skill is required yet — Task 3 adds it anyway).
- [ ] **Step 5: Commit** — `git add bin tests _template/agent.yaml` then `git commit -m "feat: validator for Agent Standard 2.1 activities"`.

---

### Task 3: Schedule skill, setup, standard text, builder 2.1.0

**Files:**
- Create: `_template/skills/schedule/SKILL.md`
- Modify: `_template/skills/setup/SKILL.md`, `STANDARD.md`, `skills/new-agent/SKILL.md`, `docs/writing-an-agent.md`, `README.md`, the three builder manifests (`2.1.0`), `tests/test-builder-manifests.sh`, `tests/run-all.sh`

- [ ] **Step 1: Failing checks** — `tests/test-builder-manifests.sh` expects `2.1.0`; in `tests/run-all.sh` template section add: `if [ ! -f _template/skills/schedule/SKILL.md ]; then echo "FAIL: template has no schedule skill"; STATUS=1; fi`. Run: failures.
- [ ] **Step 2: `_template/skills/schedule/SKILL.md`** — exactly:

```markdown
---
name: schedule
description: Use when setting up, checking, or changing this agent's scheduled runs — turns schedules.yaml into Claude cloud routines that run unattended, only for activities whose capabilities are all covered by guard policies.
---

Scheduled runs happen in Claude cloud routines: each run clones this
instance's GitHub repository, loads the agent from the cloud
environment's setup script, and runs one activity with no one watching.
This skill checks that it is safe, tells the user exactly what to
create, and verifies what they created. It never creates or deletes
routines itself.

The checker is `hooks/schedule_check.py` in the package
(`${CLAUDE_PLUGIN_ROOT}/hooks/schedule_check.py` on Claude Code; in
source mode, `hooks/schedule_check.py` in this folder). Run it with
`python3`. Below, `<checker>` means that command and `<repo>` means the
instance's GitHub repository as `owner/name`.

1. **Instance.** Work in the instance folder (the one holding this
   agent's `instance.yaml`). If `schedules.yaml` is missing or has no
   `schedule_<activity>` line, stop: the interview writes it — offer to
   run the interview's scheduling questions.
2. **Repository.** Run `git remote get-url origin` and `git status
   --porcelain`. The instance must be a git repository whose `origin` is
   on GitHub, with nothing uncommitted and nothing unpushed, and with
   `instance.yaml`, `schedules.yaml`, `context/`, and `bindings/`
   committed (the guard needs `bindings/` in the cloud). If not, say
   exactly what to do (create a private GitHub repository, commit,
   push) and stop until it is done. Take `<repo>` from the remote.
3. **Gate.** Run `<checker> check . --repo <repo>`. Each entry prints
   `PASS` or `FAIL`. A `FAIL` names every capability that is unbound or
   whose contract invariants the bound adapter's guard policy does not
   cover: tell the user, and that the fix is to bind an adapter whose
   `guard.yaml` covers them (setup's tools step). Continue only with
   `PASS` entries. Never offer to schedule a failing entry.
4. **Environment.** Show the "Cloud environment setup script" lines the
   checker printed. Tell the user: in claude.ai/code, create (once) or
   open a cloud environment — suggested name `webspenser-agents` — and
   put these lines in its setup script, merged with any other agents'
   lines. Every time this agent is updated, change the version comment
   so the environment reinstalls it. Every routine for this agent uses
   that environment.
5. **Routines.** For each `PASS` entry, give the user the values to
   create one routine at claude.ai/code/routines (New routine → Cloud):
   - name: the entry's routine name, e.g. `sales-partner: prospect (acme-sales)`;
   - repository: `<repo>`;
   - environment: the one from step 4;
   - connectors: exactly the entry's connectors (by provider name, e.g.
     Attio, Gmail) — no others;
   - schedule: the entry's day and time in the instance's timezone;
     the checker also prints the UTC cron for forms that ask in UTC;
     say that a UTC schedule shifts by an hour when daylight saving
     changes;
   - prompt: the entry's prompt, copied exactly.
6. **Verify.** When the user says a routine is created, find it with
   the routines API (`RemoteTrigger` action `list`, then `get` with its
   id). Write the JSON the API returned to a temporary file outside the
   repository, then run `<checker> verify . <activity> <file> --repo
   <repo>`. Report every `MISMATCH` line and what to change; re-verify
   after the user fixes it. On `OK`, add `routine_<activity>: <id>` to
   `schedules.yaml` and tell the user to commit and push. If the
   routines API is not available, give the user the step 5 values as a
   checklist to compare by hand instead.
7. **Smoke run (optional).** Offer to run a verified routine once now
   (`RemoteTrigger` action `run`). Say first that it does the activity's
   real work in the connected systems. Afterwards read its log
   (`list_runs`, then `get_run_log`) and report: whether the agent's
   entry context loaded (a line starting `# Agent: <name>`), whether
   the plugin's hooks ran, any line starting `Blocked by`, and the
   run's final result. If the agent did not load, the environment's
   setup script is missing or stale — back to step 4.
8. **Changes.** Re-run this skill after changing `schedules.yaml`,
   bindings, or the agent version. It re-checks every entry. It cannot
   delete routines: when an entry was removed or now fails the gate,
   tell the user which routine to disable or delete in the web UI, and
   remove its `routine_<activity>` line.

Never put credentials in any file. Never schedule an entry the checker
failed.
```

- [ ] **Step 3: Setup** (`_template/skills/setup/SKILL.md`): at the end of step 9 (Tools), add a sub-step: "8. If the agent declares activities (`activity_*` in `agent.yaml`) and the interview wrote `schedule_*` lines to `schedules.yaml`, offer to run the `schedule` skill next." In step 8 (Context), after the interview sentence, add: "The interview also writes `schedules.yaml` at the instance root (timezone and `schedule_*` lines) when the agent declares activities."
- [ ] **Step 4: `STANDARD.md`** — add a section `## Activities and schedules` after `## Setup — tools step`, from the spec's "Agent Standard 2.1" section: activities (`activity_*`, `none`, schedule skill required), `schedules.yaml` keys, the exact scheduled prompt, what scheduled runs may and may not do (no questions, no instance-file edits, work in connected systems), the cloud environment (one per account, setup script with the version comment), the unattended gate, the schedule skill's steps in brief, and `hooks/schedule_check.py` (CLI, byte-identical). Update: Development-phase line → "The standard is 2.1"; Directory layout adds `hooks/schedule_check.py`, `skills/schedule/`, and the instance's `schedules.yaml`; Validation adds the three 2.1 checks (activity names, activity capabilities, schedule skill when activities exist) and the schedule_check.py byte-identity.
- [ ] **Step 5: Wizard** (`skills/new-agent/SKILL.md`): step 4 `standard: "2.1"`, `hooks/` holds four scripts kept exactly as copied; in step 5 add a bullet: "Schedules — which Workflow steps may run on a schedule. For each, add `activity_<name>: <capabilities or none>` to `agent.yaml` and make the step's instructions work unattended under the scheduled prompt (no questions; stop and report when an input is missing; write only to connected systems). If there are any, the interview must write `schedules.yaml` (`timezone`, `schedule_<activity>`)." Keep the schedule skill as copied.
- [ ] **Step 6: `docs/writing-an-agent.md`** — a short "Schedules" section (activities, `schedules.yaml`, the schedule skill, the cloud-environment setup script). **README** — "Agent Standard 2.1"; one sentence on scheduled runs. Manifests → `2.1.0`.
- [ ] **Step 7: Verify, commit, push** — `tests/run-all.sh` ALL GREEN; `grep -rn 'Standard 2\.0\b' README.md skills STANDARD.md docs/writing-an-agent.md` shows no stale current-version claims.

```bash
git add -A
git commit -m "feat: schedule skill and Agent Standard 2.1 docs; builder 2.1.0"
git push -u origin feat/standard-2.1
```

---

## sales-partner (task 4) — `/Users/hochoy/Work/Webspenser/sales-partner`, branch `release/2.1.0`

### Task 4: Adopt 2.1

**Files:**
- Copy: builder `_template/hooks/{session-start.sh,guard.sh,guard_policy.py,schedule_check.py}` → `hooks/` (755); builder `_template/skills/schedule/SKILL.md` → `skills/schedule/SKILL.md`
- Create: `tests/test-schedules.sh` (755)
- Modify: `agent.yaml`, host manifests, `AGENT.md`, `context/operating-config.md`, `skills/interview-business/SKILL.md`, `skills/send-digest/SKILL.md`, `skills/setup/SKILL.md` (sync with template), schedulable Workflow skills/sub-agents as needed, `README.md`, `tests/test-content.sh`, `tests/run-all.sh`

- [ ] **Step 1: Branch** — `git -C /Users/hochoy/Work/Webspenser/sales-partner switch -c release/2.1.0`
- [ ] **Step 2: Failing tests** — `tests/test-schedules.sh`:

```bash
#!/usr/bin/env bash
# sales-partner's activities pass the schedule checker when bound to guarded adapters.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
C=hooks/schedule_check.py
inst() { # inst <dir> <crm provider>
  mkdir -p "$1"
  printf '%s\n' 'agent: sales-partner' 'agent_version: 2.1.0' 'mode: plugin' "bind_crm: $2" 'bind_email_drafts: gmail' > "$1/instance.yaml"
  printf '%s\n' 'timezone: America/New_York' 'schedule_prospect: "Monday 07:00"' 'then_prospect: prepare' \
    'schedule_approach: "Tuesday 07:00"' 'schedule_follow-up: "daily 09:00"' 'schedule_digest: "Monday 08:00"' > "$1/schedules.yaml"
}
for crm in attio airtable; do
  inst "$W/$crm" "$crm"
  out=$(python3 -B "$C" check "$W/$crm" --repo acme/sales 2>&1); rc=$?
  [ "$rc" -eq 0 ] && _report ok "all activities pass with $crm + gmail" || _report no "$crm (rc=$rc): $out"
done
printf '%s\n' 'agent: sales-partner' 'mode: plugin' 'bind_crm: attio' > "$W/attio/instance.yaml"
out=$(python3 -B "$C" check "$W/attio" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'email_drafts is not bound' && _report ok "digest refused without email binding" || _report no "unbound email (rc=$rc): $out"
for a in prospect prepare approach follow-up digest; do
  grep -q "^activity_$a:" agent.yaml && _report ok "activity $a declared" || _report no "activity $a missing"
done
finish
```

  `chmod 755`; add `echo "== schedules"; tests/test-schedules.sh || STATUS=1` to `tests/run-all.sh`. In `tests/test-content.sh` add before `finish`:

```bash
echo "-- scheduled runs (Agent Standard 2.1)"
assert_contains "$SP/agent.yaml" 'standard: "2.1"'
assert_contains "$SP/agent.yaml" 'version: 2.1.0'
assert_contains "$SP/agent.yaml" 'activity_digest: crm, email_drafts'
assert_not_contains "$SP/context/operating-config.md" 'schedules:'
assert_not_contains "$SP/context/operating-config.md" 'timezone:'
assert_not_contains "$SP/context/operating-config.md" 'cron + headless CLI'
assert_not_contains "$SP/context/operating-config.md" 'n8n'
assert_contains "$SP/skills/interview-business/SKILL.md" 'schedules.yaml'
assert_contains "$SP/skills/send-digest/SKILL.md" 'schedule_digest'
assert_contains "$SP/AGENT.md" 'schedules.yaml'
assert_contains "$SP/AGENT.md" 'unattended'
[ -f "$SP/skills/schedule/SKILL.md" ] && _report ok "schedule skill present" || _report no "schedule skill missing"
```

  Update or remove existing content-test assertions that pin the old `schedules:` block, `timezone:` in operating-config, `digest_schedule`, the "Running on a schedule" section text, or version `2.0.0`. Run: failures.

- [ ] **Step 3: Implement**
  - Copy the four builder hooks and the schedule skill; `chmod 755` the scripts.
  - `agent.yaml`: `version: 2.1.0`, `standard: "2.1"`, and the five keys: `activity_prospect: crm`, `activity_prepare: crm`, `activity_approach: crm, email_drafts`, `activity_follow-up: crm, email_drafts`, `activity_digest: crm, email_drafts`. Host manifests `2.1.0`.
  - `context/operating-config.md`: remove the `timezone` and `schedules` keys and their descriptions; replace the "Running on a schedule" section with two sentences: schedules live in the instance's `schedules.yaml` (written by the interview), and the `schedule` skill turns them into Claude cloud routines, only for activities whose capabilities are all covered by guard policies. Keep the no-send paragraph that follows it.
  - `skills/interview-business/SKILL.md`: where it asks about timezone and schedules, it now writes `schedules.yaml` at the instance root: `timezone` (IANA name), `schedule_<activity>: "<Weekday|daily> HH:MM"` for each activity the operator wants on a schedule, and `then_prospect: prepare` for the shipped default (prospect then prepare, Monday 07:00; digest Monday 08:00).
  - `skills/send-digest/SKILL.md`: it reads when it runs from `schedule_digest` in `schedules.yaml` instead of the `digest` entry in `schedules`.
  - `AGENT.md` "Scheduled activities": the schedulable steps are the five activities in `agent.yaml`; a scheduled run starts with the scheduled prompt; in a scheduled run the agent asks no questions, edits no instance files, writes only to connected systems, and stops with a report when an input it needs is missing. Point at `schedules.yaml` and the `schedule` skill.
  - Each schedulable step's skill or sub-agent contract (prospector, preparer, approacher, follow-up, send-digest): add one sentence under its stop conditions or guardrails: "In a scheduled (unattended) run, never ask the operator a question; if a required input is missing, stop and report what is missing."
  - `skills/setup/SKILL.md`: sync with the builder template (step 8 and step 9 changes); `diff <(sed 's/<interview-skill>/interview-business/g' /Users/hochoy/Work/Webspenser/agent-library/_template/skills/setup/SKILL.md) skills/setup/SKILL.md` shows only the context-files line.
  - `README.md`: version 2.1.0; replace any manual-scheduling text with "Scheduled runs: after setup, run `/sales-partner:schedule`."
- [ ] **Step 4: Verify** — `tests/run-all.sh` ALL GREEN; `bash /Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .` OK; `git fetch origin` then `--require-bump origin/main` passes; `cmp` of the four hooks and the schedule skill against the builder is silent; `grep -rn 'schedules:\|digest_schedule\|cron + headless\|n8n' --include='*.md' . | grep -v -e '^./docs/' -e '^./tests/'` prints nothing; `git status` shows no `.pyc`.
- [ ] **Step 5: Commit and push**

```bash
git add -A
git commit -m "feat: scheduled runs on Claude routines; release 2.1.0 (Agent Standard 2.1)"
git push -u origin release/2.1.0
```

---

## Task 5: Release and acceptance (controller; the user acts where noted)

- [ ] PR `feat/standard-2.1` → `main` (agent-builder; includes the spec and plan). The user merges with a merge commit. Then the `v2` tag moves to the merge: the user runs `! git -C ~/Work/Webspenser/agent-library fetch origin --tags && git -C ~/Work/Webspenser/agent-library tag -f v2 origin/main && git -C ~/Work/Webspenser/agent-library push -f origin v2`.
- [ ] PR `release/2.1.0` → `main` (sales-partner); re-run its CI after the tag move; the user merges. Catalog README status "2.1 — … scheduled runs via `/sales-partner:schedule`"; PR; the user merges.
- [ ] Acceptance on `webspenser/sp-routine-test` (throwaway repo, user-approved):
  1. Make it a real 2.1 instance: `instance.yaml` (`bind_crm: attio`, `bind_email_drafts: gmail`), `bindings/crm.md` from the Attio probe, minimal `context/` files, `schedules.yaml` with `timezone` and `schedule_digest: "Monday 08:00"`; commit and push.
  2. The user updates the cloud environment's setup script to the checker's printed lines (version comment `# sales-partner 2.1.0`).
  3. Run the schedule skill in that folder: gate passes for `digest`; a temporary `schedule_prospect` bound to an uncovered adapter is refused (then removed).
  4. The user edits the existing test routine per the printed values (prompt, Gmail connector added); the skill verifies it (`verify` → OK) and records `routine_digest`.
  5. Smoke run: the log shows the entry context, the plugin's hooks, at most one Gmail draft to the operator, and no other writes. Record whether the routine's cron is UTC or local (from `next_run_at`), and whether the setup script re-ran after the version comment changed.
  6. Disable the routine; the user deletes it and the repo.
- [ ] Clean up merged branches; delete the plan workspace (ask the user to run `rm -r` if the hook blocks it).
