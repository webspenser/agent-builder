#!/usr/bin/env bash
# Behavior of the Agent Standard schedule checker (_template/hooks/schedule_check.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PKG="$W/pkg"; mkdir -p "$PKG/hooks"
cp _template/hooks/schedule_check.py _template/hooks/guard_policy.py _template/hooks/tool_check.py "$PKG/hooks/"
SC="$PKG/hooks/schedule_check.py"
printf '%s\n' 'name: demo-agent' 'version: 3.0.0' 'description: Demo' 'standard: "3.0"' \
  'catalog: webspenser' 'catalog_repo: webspenser/agent-library' 'capabilities: crm, email_drafts' \
  'activity_research: none' 'activity_prospect: crm' 'activity_digest: crm, email_drafts' > "$PKG/agent.yaml"
mkdir -p "$PKG/capabilities/crm/tools/good" "$PKG/capabilities/crm/tools/half" "$PKG/capabilities/crm/tools/bare" "$PKG/capabilities/email_drafts/tools/mail"
printf '%s\n' '# CRM' '' '## Operations' '' '| `get` | x |' '' '## Invariants' '' '- `draft_only` — x' '- `no_delete` — y' > "$PKG/capabilities/crm/contract.md"
printf '%s\n' '# Email' '' '## Operations' '' '| `draft` | x |' '' '## Invariants' '' '- `no_send` — x' > "$PKG/capabilities/email_drafts/contract.md"
printf '%s\n' 'capability: crm' 'provider: good' 'server_match: goodcrm' > "$PKG/capabilities/crm/tools/good/identity.yaml"
printf '%s\n' 'covers: [draft_only, no_delete]' 'deny: ["*delete*"]' > "$PKG/capabilities/crm/tools/good/guard.yaml"
printf '%s\n' 'capability: crm' 'provider: half' 'server_match: halfcrm' > "$PKG/capabilities/crm/tools/half/identity.yaml"
printf '%s\n' 'covers: [draft_only]' > "$PKG/capabilities/crm/tools/half/guard.yaml"
printf '%s\n' 'capability: crm' 'provider: bare' 'server_match: barecrm' > "$PKG/capabilities/crm/tools/bare/identity.yaml"
printf '%s\n' 'capability: email_drafts' 'provider: mail' 'server_match: mail' > "$PKG/capabilities/email_drafts/tools/mail/identity.yaml"
printf '%s\n' 'covers: [no_send]' 'deny: ["*send*"]' > "$PKG/capabilities/email_drafts/tools/mail/guard.yaml"
for t in good half bare; do printf '%s\n' '`get`' '## Probe' 'x' > "$PKG/capabilities/crm/tools/$t/usage.md"; done
printf '%s\n' '`draft`' '## Probe' 'x' > "$PKG/capabilities/email_drafts/tools/mail/usage.md"
cusage() { printf '%s\n' '`get`' '## Probe' 'x' > "$1/custom-tools/crm/usage.md"; }  # cusage <instance>: usage.md for a custom crm tool

instance() { # instance <dir> <crm provider|-> <email provider|-> <schedule lines...>
  local d="$1" crm="$2" mail="$3"; shift 3
  mkdir -p "$d"
  { echo 'agent: demo-agent'; echo 'agent_version: 3.0.0'; echo 'mode: plugin'
    [ "$crm" = - ] || echo "bind_crm: $crm"; [ "$mail" = - ] || echo "bind_email_drafts: $mail"; } > "$d/instance.yaml"
  printf '%s\n' "$@" > "$d/schedules.yaml"
}
run() { OUT=$(python3 -B "$SC" "$@" 2>&1); RC=$?; }
expect() { # expect <rc> <label> [text]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; } && ! printf '%s' "$OUT" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}

echo "-- gate"
I="$W/ok"; instance "$I" good mail 'timezone: UTC' 'environment: env_01Abc' 'schedule_prospect: "Monday 07:00"' 'then_prospect: research' 'schedule_digest: "Monday 08:00"'
run check "$I" --repo acme/sales;                  expect 0 "all entries pass" "PASS  demo-agent: prospect (sales)"
expect 0 "digest passes" "PASS  demo-agent: digest (sales)"
expect 0 "env setup script" "claude plugin install demo-agent@webspenser"
expect 0 "version comment" "# demo-agent 3.0.0"
expect 0 "UTC cron" "(UTC cron: 0 7 * * 1)"
expect 0 "connectors with server_match" 'connectors: good (matches "goodcrm"), mail (matches "mail")'
expect 0 "prompt with then" 'prompt: Scheduled run of `prospect`, then `research` (unattended). Follow this agent'"'"'s instructions for each activity, in order.'
N="$W/nomail"; instance "$N" good - 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'schedule_digest: "Monday 08:00"'
run check "$N";                                    expect 1 "unbound capability fails its entry" "email_drafts is not bound"
expect 1 "other entry still passes" "PASS  demo-agent: prospect (nomail)"
H="$W/half"; instance "$H" half mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$H";                                    expect 1 "uncovered invariant fails" "crm: invariant no_delete is not covered by the half tool's guard policy"
B="$W/bare"; instance "$B" bare mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
run check "$B";                                    expect 1 "tool without a policy fails" "invariant draft_only is not covered"
T="$W/then"; instance "$T" good - 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'then_prospect: digest'
run check "$T";                                    expect 1 "then activity's capabilities are gated" "email_drafts is not bound"
R="$W/none"; instance "$R" - - 'timezone: UTC' 'schedule_research: "daily 06:30"'
run check "$R";                                    expect 0 "activity using no capability needs no binding" "(UTC cron: 30 6 * * *)"
U="$W/unknown"; instance "$U" good mail 'timezone: UTC' 'schedule_launch: "Monday 07:00"'
run check "$U";                                    expect 1 "unknown activity fails" "launch is not an activity of demo-agent"
X="$W/badwhen"; instance "$X" good mail 'timezone: UTC' 'schedule_prospect: "Mondays at 7"'
run check "$X";                                    expect 1 "bad schedule fails" "is not '<weekday|daily> HH:MM'"
C="$W/custom"; instance "$C" custom mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mkdir -p "$C/custom-tools/crm"
cusage "$C"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: mycrm' > "$C/custom-tools/crm/identity.yaml"
printf '%s\n' 'covers: [draft_only, no_delete]' > "$C/custom-tools/crm/guard.yaml"
run check "$C";                                    expect 0 "custom tool with full policy passes" "connectors: custom"

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
run bogus;                                         expect 2 "usage" "schedule_check.py check"
run check "$I" --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["entries"][0]["ok"] and d["entries"][0]["connectors"]==["good"] and d["entries"][0]["server_matches"]==["goodcrm"]' \
  && _report ok "json output" || _report no "json output: $OUT"

echo "-- verify"
PROMPT='Scheduled run of `prospect`, then `research` (unattended). Follow this agent'"'"'s instructions for each activity, in order. Do not ask questions and do not edit or commit files in this repository. If something needs the operator, stop and say exactly what.'
routine() { # routine <file> <enabled> <repo url> <prompt> <connector name> <next_run_at> [wrap]
  python3 -B - "$@" <<'PY'
import json, sys
f, enabled, url, prompt, conn, nxt = sys.argv[1:7]
r = {"enabled": enabled == "true", "next_run_at": nxt,
     "job_config": {"ccr": {"environment_id": "env_01Abc", "session_context": {"sources": [{"git_repository": {"url": url}}]},
                            "events": [{"data": {"message": {"role": "user", "content": prompt}}}]}},
     "mcp_connections": [{"name": conn}] if conn else []}
if len(sys.argv) > 7:
    r = {"trigger": r}
json.dump(r, open(f, "w"))
PY
}
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "GoodCRM Mail" 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "matching routine" "OK: the routine matches schedule_prospect"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "GoodCRM Mail" 2026-10-05T07:00:00Z wrap
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "API wrapper accepted"
routine "$W/r.json" false https://github.com/acme/sales "$PROMPT" "GoodCRM Mail" 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "disabled" "the routine is not enabled"
routine "$W/r.json" true https://github.com/acme/other "$PROMPT" "GoodCRM Mail" 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "wrong repo" "does not clone acme/sales"
routine "$W/r.json" true https://github.com/acme/sales "Do the prospecting" "GoodCRM Mail" 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "edited prompt" "is not the scheduled prompt"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "" 2026-10-05T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "missing connector" 'no connector whose name contains "goodcrm" is attached (crm: good)'
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "GoodCRM Mail" 2026-10-05T08:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "wrong time" "next run is Monday 08:00 local, not Monday 07:00"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "GoodCRM Mail" 2026-10-06T07:00:00Z
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "wrong day" "next run is Tuesday 07:00 local"
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "GoodCRM Mail" 2026-10-05T07:00:00Z
run verify "$N" digest "$W/r.json";                      expect 1 "gate failure reported by verify" "does not pass the unattended gate"
run verify "$I" nothing "$W/r.json";                     expect 2 "unknown entry" "no schedule_nothing"
echo '[1]' > "$W/r.json"
run verify "$I" prospect "$W/r.json";                    expect 2 "routine JSON not an object" "not an object"
echo "-- binding rules (mirror guard.sh)"
BX="$W/badbind"; instance "$BX" - mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; echo 'bind_crm: ../../x' >> "$BX/instance.yaml"
run check "$BX";                                   expect 1 "unreadable binding line fails every entry" "cannot read (bind_crm: ../../x)"
BD="$W/dupbind"; instance "$BD" half mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; echo 'bind_crm: good' >> "$BD/instance.yaml"
run check "$BD";                                   expect 1 "duplicate binding fails" "crm is bound more than once; the guard applies every binding"
expect 1 "every bound tool is gated" "invariant no_delete is not covered by the half tool"
BN="$W/nomatch"; instance "$BN" custom mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mkdir -p "$BN/custom-tools/crm"
cusage "$BN"
printf '%s\n' 'capability: crm' 'provider: custom' > "$BN/custom-tools/crm/identity.yaml"
printf '%s\n' 'covers: [draft_only, no_delete]' > "$BN/custom-tools/crm/guard.yaml"
run check "$BN";                                   expect 1 "tool without server_match fails" "crm: the custom tool is not valid: custom-tools/crm/identity.yaml: missing server_match"
BQ="$W/quoted"; instance "$BQ" - mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; echo "bind_crm: \"GOOD\"  # note" >> "$BQ/instance.yaml"
run check "$BQ";                                   expect 0 "quotes, comments and case are normalized like the guard" "connectors: good"
BA="$W/notool"; instance "$BA" ghost mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'schedule_digest: "Monday 08:00"'
run check "$BA";                                   expect 1 "missing tool fails the entries that use it" "crm: no identity.yaml for ghost"
expect 1 "missing tool: the rest still prints" "FAIL  demo-agent: digest"
BM="$W/nomatchmix"; instance "$BM" good mail 'timezone: UTC' 'schedule_research: "daily 06:30"' 'schedule_prospect: "Monday 07:00"'
sed -i.bak 's/^bind_crm: good/bind_crm: ghost/' "$BM/instance.yaml"
run check "$BM";                                   expect 1 "unaffected entry still printed" "PASS  demo-agent: research (nomatchmix)"
DP="$W/dupsched"; instance "$DP" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'schedule_prospect: "Tuesday 07:00"'
run check "$DP";                                   expect 1 "duplicate schedule key fails" "schedule_prospect appears more than once"

echo "-- verify shapes and matching"
rj() { # rj <file> <python statements mutating r> ; r starts as a matching routine
  python3 -B - "$1" "$2" <<'PY2'
import json, sys
prompt = ("Scheduled run of `prospect`, then `research` (unattended). Follow this agent's instructions for each activity, in order. "
          "Do not ask questions and do not edit or commit files in this repository. If something needs the operator, stop and say exactly what.")
r = {"enabled": True, "next_run_at": "2026-10-05T07:00:00Z",
     "job_config": {"ccr": {"environment_id": "env_01Abc", "session_context": {"sources": [{"git_repository": {"url": "https://github.com/acme/sales"}}]},
                            "events": [{"data": {"message": {"role": "user", "content": prompt}}}]}},
     "mcp_connections": [{"name": "GoodCRM Mail"}]}
exec(sys.argv[2])
json.dump(r, open(sys.argv[1], "w"))
PY2
}
rj "$W/r.json" 'r["job_config"]["ccr"]["events"] = None; r["mcp_connections"] = None; r["next_run_at"] = 123'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "null events, null connections, numeric next_run_at" "MISMATCH:"
expect 1 "numeric next_run_at is a mismatch" "no readable next_run_at (123)"
rj "$W/r.json" 'r = {"trigger": None}'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "null trigger" "MISMATCH: trigger is not an object"
rj "$W/r.json" 'r["job_config"] = None'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "null job_config" "MISMATCH:"
rj "$W/r.json" 'r["job_config"]["ccr"]["session_context"]["sources"] = "x"; r["mcp_connections"] = [1, {"name": None}]; r["job_config"]["ccr"]["events"] = [3]'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "non-list and non-object entries" "session_context.sources is not a list"
rj "$W/r.json" 'r["job_config"]["ccr"]["events"][0]["data"]["message"]["content"] = [{"type": "text", "text": prompt}]'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "content as text blocks" "OK:"
rj "$W/r.json" 'r["job_config"]["ccr"]["session_context"]["sources"][0]["git_repository"]["url"] = "https://github.com/Acme/Sales.git"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "URL with .git, case-insensitive" "OK:"
rj "$W/r.json" 'r["job_config"]["ccr"]["session_context"]["sources"][0]["git_repository"]["url"] = "git@github.com:acme/sales.git"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "scp-style SSH URL" "OK:"
rj "$W/r.json" 'r["job_config"]["ccr"]["session_context"]["sources"][0]["git_repository"]["url"] = "ssh://git@github.com/acme/sales"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "ssh:// URL" "OK:"
rj "$W/r.json" 'r["next_run_at"] = "2026-10-05T07:00:00"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "naive next_run_at is UTC" "OK:"
DG='p = prompt.replace("`prospect`, then `research`", "`digest`"); r["next_run_at"] = "2026-10-05T08:00:00Z"; r["job_config"]["ccr"]["events"][0]["data"]["message"]["content"] = p; '
rj "$W/r.json" "$DG"'r["mcp_connections"] = [{"name": "Mail Sandbox"}, {"name": "GoodCRM Prod"}]'
run verify "$I" digest "$W/r.json" --repo acme/sales;    expect 0 "connector matched on server_match" "OK:"
rj "$W/r.json" "$DG"'r["mcp_connections"] = [{"name": "GoodCRM"}, {"name": "Other"}]'
run verify "$I" digest "$W/r.json" --repo acme/sales;    expect 1 "connector not matching server_match" 'no connector whose name contains "mail" is attached'
rj "$W/r.json" 'r["job_config"]["ccr"]["session_context"]["sources"][0]["git_repository"]["url"] = "https://github.com/other/sales"'
run verify "$W/ok" prospect "$W/r.json";                 expect 1 "no --repo: name-only comparison says so" "only the name was compared"
run verify "$DP" prospect "$W/r.json" --repo acme/sales; expect 1 "invalid entry yields the gate mismatch" "does not pass the unattended gate"

echo "-- guard_policy import"
mkdir -p "$W/nopolicy/hooks"; cp _template/hooks/schedule_check.py "$W/nopolicy/hooks/"
run_np() { OUT=$(python3 -B "$W/nopolicy/hooks/schedule_check.py" check "$I" 2>&1); RC=$?; }
run_np;                                            expect 2 "missing guard_policy.py is an error" "ERROR: cannot load guard_policy.py beside this script"
echo "-- round 2: guard parity"
CR="$W/lonecr"; instance "$CR" - mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; printf '# note\rbind_crm: good\n' >> "$CR/instance.yaml"
run check "$CR";                                   expect 1 "lone CR does not create a binding line" "crm is not bound"
CL="$W/crlf"; instance "$CL" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; sed -i.bak 's/$/\r/' "$CL/instance.yaml"
run check "$CL";                                   expect 0 "CRLF instance.yaml still works" "PASS  demo-agent: prospect"
RA="$W/repagent"; instance "$RA" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; sed -i.bak 's/^agent: demo-agent/agent: other/' "$RA/instance.yaml"; echo 'agent: demo-agent' >> "$RA/instance.yaml"
run check "$RA";                                   expect 2 "first agent: line wins (like the guard)" "is not 'demo-agent'"
RM="$W/repmatch"; instance "$RM" custom mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mkdir -p "$RM/custom-tools/crm"
cusage "$RM"
printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: first' 'server_match: second' > "$RM/custom-tools/crm/identity.yaml"
printf '%s\n' 'covers: [draft_only, no_delete]' > "$RM/custom-tools/crm/guard.yaml"
run check "$RM";                                   expect 1 "repeated server_match fails (tool_check refuses what the guard reads by first match)" "server_match appears more than once"
RS="$W/repsched"; instance "$RS" good mail 'timezone: UTC' 'timezone: Asia/Tokyo' 'schedule_prospect: "Monday 07:00"'
run check "$RS";                                   expect 0 "schedules.yaml: first timezone wins" "timezone UTC"
NB="$W/nbsp"; instance "$NB" - mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; printf 'bind_crm: good\xc2\xa0\n' >> "$NB/instance.yaml"
run check "$NB";                                   expect 1 "NBSP is not whitespace to the guard" "cannot read"
FS="$W/fs"; instance "$FS" - mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; printf 'bind_crm: good\x1f\n' >> "$FS/instance.yaml"
run check "$FS";                                   expect 2 "0x1f in instance.yaml is an error" "instance.yaml line 5 has a control character (0x1f)"
rj "$W/r.json" 'r["next_run_at"] = "9999-12-31T23:59:00-12:00"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "overflowing next_run_at is a mismatch" "no readable next_run_at"
rj "$W/r.json" 'r["enabled"] = "false"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "string enabled is not enabled" "the routine is not enabled"
echo "-- round 3: agent.yaml name and activities"
mkdir -p "$W/pkg3/hooks"; cp "$PKG/hooks/"*.py "$W/pkg3/hooks/"; cp -R "$PKG/capabilities" "$W/pkg3/"
run3() { OUT=$(python3 -B "$W/pkg3/hooks/schedule_check.py" "$@" 2>&1); RC=$?; }
A3="$W/agent-good.yaml"; cp "$PKG/agent.yaml" "$A3"
sed 's/^name:/name :/' "$A3" > "$W/pkg3/agent.yaml"
NA="$W/noagent"; instance "$NA" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; sed -i.bak '/^agent:/d' "$NA/instance.yaml"
run3 check "$NA";                                  expect 2 "spaced name: with no instance agent: line" "agent.yaml has no name: line the guard can read"
{ printf '# x\rname: demo-agent\n'; grep -v '^name:' "$A3"; } > "$W/pkg3/agent.yaml"
run3 check "$NA";                                  expect 2 "CR-hidden name: line" "agent.yaml has no name: line the guard can read"
cp "$A3" "$W/pkg3/agent.yaml"
EA="$W/emptyagent"; instance "$EA" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; sed -i.bak 's/^agent: .*/agent:/' "$EA/instance.yaml"
run3 check "$EA";                                  expect 2 "empty agent: line" "instance.yaml has no agent: line the guard can read"
{ cat "$A3"; echo 'activity_prospect: crm'; } > "$W/pkg3/agent.yaml"
run3 check "$I";                                   expect 1 "repeated activity key fails entries using it" "agent.yaml declares activity_prospect more than once"
expect 1 "unaffected entry still passes" "PASS  demo-agent: digest"
{ cat "$A3"; echo 'activity_prospect : crm'; } > "$W/pkg3/agent.yaml"
run3 check "$I";                                   expect 1 "repeated activity key, spaced spelling" "declares activity_prospect more than once"
sed 's/^catalog_repo:/catalog_repo :/' "$A3" > "$W/pkg3/agent.yaml"
run3 check "$I";                                   expect 0 "spaced catalog_repo still reaches env_setup" "claude plugin marketplace add webspenser/agent-library"
grep -v '^catalog' "$A3" > "$W/pkg3/agent.yaml"
run3 check "$I";                                   expect 1 "no catalog fails every entry" "agent.yaml has no catalog/catalog_repo, so the cloud environment cannot install the agent"
grep -v '^catalog_repo' "$A3" > "$W/pkg3/agent.yaml"
run3 check "$I";                                   expect 1 "no catalog_repo fails too" "cannot install the agent"
cp "$A3" "$W/pkg3/agent.yaml"
echo "-- round 4: control bytes, server_match, name messages"
NU="$W/nulagent"; instance "$NU" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
{ printf 'agent: demo\000-agent\n'; grep -v '^agent:' "$I/instance.yaml"; } > "$NU/instance.yaml"
{ printf 'name: demo\000-agent\n'; grep -v '^name:' "$A3"; } > "$W/pkg3/agent.yaml"
run3 check "$NU";                                  expect 2 "NUL inside name: (and the same agent:) is an error" "agent.yaml line 1 has a control character (0x00)"
cp "$A3" "$W/pkg3/agent.yaml"
run check "$NU";                                   expect 2 "NUL in the instance agent: is an error" "instance.yaml line 1 has a control character (0x00)"
DL="$W/delinst"; instance "$DL" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; printf '# note\177\n' >> "$DL/instance.yaml"
run check "$DL";                                   expect 2 "DEL anywhere in instance.yaml is an error" "instance.yaml line 6 has a control character (0x7f)"
sm() { # sm <dir> <printf format for the server_match line>: a custom crm tool with a full policy
  instance "$1" custom mail 'timezone: UTC' 'environment: env_01Abc' 'schedule_prospect: "Monday 07:00"' 'then_prospect: research' 'schedule_digest: "Monday 08:00"'
  mkdir -p "$1/custom-tools/crm"; cusage "$1"
cusage "$1"
  { printf '%s\n' 'capability: crm' 'provider: custom'; printf "$2"'\n'; } > "$1/custom-tools/crm/identity.yaml"
  printf '%s\n' 'covers: [draft_only, no_delete]' 'deny: ["*delete*"]' > "$1/custom-tools/crm/guard.yaml"
}
sm "$W/sm-us" 'server_match: good\037crm'
run check "$W/sm-us";                              expect 1 "0x1f in server_match fails the entry" "crm: the custom tool is not valid: custom-tools/crm/identity.yaml line 3 has a control character (0x1f)"
expect 1 "0x1f in identity.yaml: other entries still print" "FAIL  demo-agent: digest"
sm "$W/sm-sp" 'server_match: "goodcrm "'
run check "$W/sm-sp";                              expect 1 "quoted trailing space in server_match fails" "crm: the custom tool is not valid: custom-tools/crm/identity.yaml: server_match must be lowercase letters, digits, _ or - (the guard compares it to MCP tool names)"
sm "$W/sm-in" 'server_match: good crm'
run check "$W/sm-in";                              expect 1 "space inside server_match fails" "server_match must be lowercase letters, digits, _ or -"
sm "$W/sm-dot" 'server_match: good.crm'
run check "$W/sm-dot";                             expect 1 "dot in server_match fails" "server_match must be lowercase letters, digits, _ or -"
sm "$W/sm-uc" 'server_match: GoodCRM'
run check "$W/sm-uc";                              expect 1 "uppercase server_match fails" "server_match must be lowercase letters, digits, _ or -"
sm "$W/sm-ok" 'server_match: good-crm   # the Good CRM server'
run check "$W/sm-ok";                              expect 0 "good-crm with a comment passes" 'custom (matches "good-crm")'
routine "$W/r.json" true https://github.com/acme/sales "$PROMPT" "Good-CRM Prod" 2026-10-05T07:00:00Z
run verify "$W/sm-ok" prospect "$W/r.json" --repo acme/sales;  expect 0 "verify matches connector names case-insensitively" "OK:"
{ cat "$A3"; printf 'notes: a\tb\n'; } > "$W/pkg3/agent.yaml"
TB="$W/tabs"; instance "$TB" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'; printf 'notes: x\ty\n' >> "$TB/instance.yaml"
printf 'agent:\tdemo-agent\n' > "$TB/instance.yaml.new"; grep -v '^agent:' "$TB/instance.yaml" >> "$TB/instance.yaml.new"; mv "$TB/instance.yaml.new" "$TB/instance.yaml"
run3 check "$TB";                                  expect 0 "tabs inside values still work" "PASS  demo-agent: prospect (tabs)"
{ cat "$A3"; echo 'name: other-agent'; } > "$W/pkg3/agent.yaml"
run3 check "$I";                                   expect 2 "disagreeing name: lines are reported as ambiguous" "agent.yaml name: is ambiguous (the guard reads 'demo-agent', the validator reads 'other-agent')"
cp "$A3" "$W/pkg3/agent.yaml"
echo "-- final review: environment, extra connectors, sources, then_, orphan routine_"
run check "$I";                                    expect 0 "check shows the recorded environment" "environment: env_01Abc"
ENV="$W/badenv"; instance "$ENV" good mail 'timezone: UTC' 'environment: env-01!' 'schedule_prospect: "Monday 07:00"' 'schedule_research: "daily 06:30"'
run check "$ENV";                                  expect 1 "bad environment charset fails every entry" "schedules.yaml environment 'env-01!' is not env_<letters and digits>"
expect 1 "bad environment: research fails too" "FAIL  demo-agent: research (badenv)"
EE="$W/emptyenv"; instance "$EE" good mail 'timezone: UTC' 'environment:' 'schedule_prospect: "Monday 07:00"'
run check "$EE";                                   expect 1 "empty environment fails" "schedules.yaml environment '' is not env_<letters and digits>"
NE="$W/noenv"; instance "$NE" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'then_prospect: research'
run check "$NE";                                   expect 0 "environment is optional for check" "PASS  demo-agent: prospect (noenv)"
rj "$W/r.json" 'pass'
run verify "$NE" prospect "$W/r.json" --repo acme/sales; expect 1 "no recorded environment: verify names the routine's" "MISMATCH: schedules.yaml records no environment; this routine uses env_01Abc — confirm it is the environment whose setup script installs this agent, then add environment: env_01Abc"
rj "$W/r.json" 'del r["job_config"]["ccr"]["environment_id"]'
run verify "$NE" prospect "$W/r.json" --repo acme/sales; expect 1 "no recorded environment, none in the routine" "this routine uses unknown — confirm"
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "routine without environment_id" "the routine uses environment unknown, not env_01Abc from schedules.yaml; any other environment runs the agent with no guard"
rj "$W/r.json" 'r["job_config"]["ccr"]["environment_id"] = "env_02Other"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "differing environment" "the routine uses environment env_02Other, not env_01Abc from schedules.yaml"
rj "$W/r.json" 'r["job_config"]["ccr"]["environment_id"] = 7'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "non-string environment_id" "the routine uses environment unknown"
rj "$W/r.json" 'r["job_config"]["ccr"]["environment_id"] = "env_01Abc\nOK: fake"'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "environment_id with a newline is escaped" 'the routine uses environment "env_01Abc\nOK: fake", not env_01Abc'
rj "$W/r.json" 'pass'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 0 "matching environment" "OK:"
rj "$W/r.json" 'r["mcp_connections"].append({"name": "Apify Scraper"})'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "extra connector" 'MISMATCH: connector "Apify Scraper" matches no bound server_match (goodcrm), so it would run with no guard — remove it from the routine'
rj "$W/r.json" 'r["mcp_connections"].append({"name": "Line\nOK: fake"})'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "extra connector name is escaped" 'connector "Line\nOK: fake" matches no bound'
rj "$W/r.json" 'r["mcp_connections"].append({"url": "https://x"})'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "extra connector with no name" "a connector with no readable name is attached"
rj "$W/r.json" 'r["job_config"]["ccr"]["events"][0]["data"]["message"]["content"] = prompt.replace("`prospect`, then `research`", "`research`"); r["next_run_at"] = "2026-10-05T06:30:00Z"'
RE="$W/resonly"; instance "$RE" - - 'timezone: UTC' 'environment: env_01Abc' 'schedule_research: "daily 06:30"'
run verify "$RE" research "$W/r.json" --repo acme/sales; expect 1 "any connector on a no-capability activity is extra" 'connector "GoodCRM Mail" matches no bound server_match (none)'
printf '%s\n' "$OUT" | grep -q "MISMATCH" && [ "$(printf '%s\n' "$OUT" | grep -c MISMATCH)" -eq 1 ] \
  && _report ok "no-capability activity: the connector is the only mismatch" || _report no "no-capability activity: $OUT"
rj "$W/r.json" 'r["job_config"]["ccr"]["session_context"]["sources"] = []'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "zero sources" "MISMATCH: the routine has 0 repository sources; it must clone exactly one, this instance's repository"
rj "$W/r.json" 'del r["job_config"]["ccr"]["session_context"]["sources"]'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "missing sources" "the routine has 0 repository sources"
rj "$W/r.json" 's = r["job_config"]["ccr"]["session_context"]["sources"]; s.append({"git_repository": {"url": "https://github.com/acme/other"}})'
run verify "$I" prospect "$W/r.json" --repo acme/sales;  expect 1 "two sources" "the routine has 2 repository sources; it must clone exactly one"
TT="$W/dupthen"; instance "$TT" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'then_prospect: research' 'then_prospect: digest' 'schedule_research: "daily 06:30"'
run check "$TT";                                   expect 1 "repeated then_ fails its entry" "then_prospect appears more than once"
expect 1 "repeated then_: other entry still passes" "PASS  demo-agent: research (dupthen)"
OR="$W/orphan"; instance "$OR" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"' 'routine_prospect: trig_01A' 'routine_digest: trig_02B'
run check "$OR";                                   expect 1 "orphan routine_ line fails" "FAIL  routine_digest: trig_02B has no schedule_digest entry"
expect 1 "orphan routine_: tells the user what to do" "disable or delete routine trig_02B in the web UI, then remove this line"
expect 1 "orphan routine_: the entry still passes" "PASS  demo-agent: prospect (orphan)"
run check "$OR" --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["orphans"]==[{"activity":"digest","routine_id":"trig_02B"}] and d["environment"] is None' \
  && _report ok "json lists orphans" || _report no "json lists orphans: $OUT"
OO="$W/onlyorphan"; instance "$OO" good mail 'timezone: UTC' 'routine_digest: trig_02B'
run check "$OO";                                   expect 2 "only orphans: still an error, naming the routine" "routine_digest: trig_02B has no schedule_digest entry"
[ -x _template/hooks/schedule_check.py ] && _report ok "script executable" || _report no "script not executable"

echo "-- 3.0 tools"
I="$W/nousage"; instance "$I" good mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mv "$PKG/capabilities/crm/tools/good/usage.md" "$W/usage.bak"
run check "$I";                                    expect 1 "bound tool failing tool_check fails the entry" "usage.md"
mv "$W/usage.bak" "$PKG/capabilities/crm/tools/good/usage.md"
cp "$PKG/capabilities/crm/tools/good/identity.yaml" "$PKG/capabilities/crm/tools/good/adapter.yaml"
run check "$I";                                    expect 1 "leftover adapter.yaml fails the entry" "Agent Standard 2 name"
rm "$PKG/capabilities/crm/tools/good/adapter.yaml"
I="$W/oldcustom"; instance "$I" custom mail 'timezone: UTC' 'schedule_prospect: "Monday 07:00"'
mkdir -p "$I/custom-adapters/crm"; printf '%s\n' 'capability: crm' 'provider: custom' 'server_match: democrm' > "$I/custom-adapters/crm/adapter.yaml"
run check "$I";                                    expect 1 "custom-adapters/ after upgrade fails with migration hint" "apply the 3.0 migration"
rm -r "$I/custom-adapters"
run check "$I";                                    expect 1 "custom binding with no custom tool fails" "run the add-tool skill"

finish
