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
