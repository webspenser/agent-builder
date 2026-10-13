#!/usr/bin/env bash
# Behavior of the Agent Standard tool checker (_template/hooks/tool_check.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
TC="$PWD/_template/hooks/tool_check.py"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
C="$W/pkg/capabilities/crm"; T="$C/tools/demo"; mkdir -p "$T"
printf '%s\n' '# CRM' '' '## Operations' '' '| `create_lead` | x |' '| `get_lead` | y |' '' \
  '## Invariants' '' '- `draft_only` — x' '- `no_delete` — y' > "$C/contract.md"
good_tool() { # good_tool <dir> <provider>
  mkdir -p "$1"
  printf '%s\n' 'capability: crm' "provider: $2" 'server_match: demo' > "$1/identity.yaml"
  printf '%s\n' '# Demo' '' '- `create_lead` — demo:create' '- `get_lead` — demo:get' '' '## Probe' '' 'Call demo:whoami.' > "$1/usage.md"
  printf '%s\n' 'covers: [draft_only, no_delete]' 'deny: ["*delete*"]' > "$1/guard.yaml"
}
run() { OUT=$(python3 -B "$TC" "$@" 2>&1); RC=$?; }
expect() { # expect <rc> <label> [text]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; } && ! printf '%s' "$OUT" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}
fresh() { rm -rf "$T"; good_tool "$T" demo; }

echo "-- valid"
fresh; run "$T" "$C/contract.md";                        expect 0 "shipped tool passes" "OK: "
I="$W/inst/custom-tools/crm"; good_tool "$I" custom
run "$I" "$C/contract.md" --custom;                      expect 0 "custom tool passes"
fresh; rm "$T/guard.yaml"; run "$T" "$C/contract.md";    expect 0 "no guard.yaml: allowed (instruction-only)"

echo "-- identity.yaml"
fresh; rm "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "missing identity" "missing $T/identity.yaml"
fresh; sed -i.bak 's/^capability: .*/capability: crmx/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "wrong capability" "capability 'crmx' must be 'crm'"
fresh; sed -i.bak 's/^provider: .*/provider: other/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "wrong provider" "provider 'other' must be 'demo'"
run "$I" "$C/contract.md";                               expect 2 "custom folder checked as shipped" "expected capabilities/<cap>/tools/<tool>/"
fresh; sed -i.bak '/^server_match/d' "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "missing server_match" "missing server_match"
fresh; sed -i.bak 's/^server_match: .*/server_match: HubSpot CRM/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "display-name server_match refused" "server_match must be lowercase letters, digits, _ or -"
fresh; echo 'block: send' >> "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "unknown key" "unknown key 'block' (identity.yaml holds capability, provider, server_match, wrapper)"
fresh; echo 'server_match: other' >> "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "repeated key" "server_match appears more than once"
fresh; sed -i.bak 's/^server_match: .*/server_match:/' "$T/identity.yaml"; echo '  - demo' >> "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "list value refused" "holds flat 'key: value' lines only"
fresh; sed -i.bak 's/^server_match: .*/server_match: [demo]/' "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "inline list refused" "server_match must be a plain value"
fresh; printf 'capability : crm\n' > "$T/x"; cat "$T/identity.yaml" >> "$T/x"; mv "$T/x" "$T/identity.yaml"; run "$T" "$C/contract.md"
expect 1 "space before colon refused" "no spaces before the colon"
fresh; printf 'server_match: de\001mo\n' > "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "control char refused" "control character"

echo "-- usage.md"
fresh; rm "$T/usage.md"; run "$T" "$C/contract.md";      expect 1 "missing usage" "missing $T/usage.md"
fresh; sed -i.bak '/get_lead/d' "$T/usage.md"; run "$T" "$C/contract.md"; expect 1 "unmapped operation" 'does not map operation `get_lead`'
fresh; sed -i.bak '/^## Probe/d' "$T/usage.md"; run "$T" "$C/contract.md"; expect 1 "no probe" "needs a ## Probe section"

echo "-- guard.yaml"
fresh; echo 'bogus: 1' >> "$T/guard.yaml"; run "$T" "$C/contract.md"; expect 1 "policy must parse" "$T/guard.yaml:"
fresh; printf '%s\n' 'covers: [draft_only, no_spam]' > "$T/guard.yaml"; run "$T" "$C/contract.md"
expect 1 "covers unknown invariant" "covers names no_spam, which is not an invariant of the contract"
E="$W/pkg/capabilities/email"; mkdir -p "$E/tools/mail"
printf '%s\n' '# Email' '' '## Operations' '' '| `draft` | x |' '' '## Invariants' '' '- `no_external_send` — x' > "$E/contract.md"
printf '%s\n' 'capability: email' 'provider: mail' 'server_match: mail' > "$E/tools/mail/identity.yaml"
printf '%s\n' '`draft`' '## Probe' 'x' > "$E/tools/mail/usage.md"
run "$E/tools/mail" "$E/contract.md";                    expect 1 "no_external_send needs guard.yaml" "the contract has no_external_send, so guard.yaml must cover it"
printf '%s\n' 'covers: []' > "$E/tools/mail/guard.yaml"; run "$E/tools/mail" "$E/contract.md"
expect 1 "no_external_send must be covered" "covers must include no_external_send"
CE="$W/inst/custom-tools/email"; mkdir -p "$CE"
printf '%s\n' 'capability: email' 'provider: custom' 'server_match: mail' > "$CE/identity.yaml"; cp "$E/tools/mail/usage.md" "$CE/"
run "$CE" "$E/contract.md" --custom;                     expect 1 "custom no_external_send without guard refused" "must cover it"

echo "-- tool folder name"
fresh; mv "$T" "$C/tools/Demo_X"; sed -i.bak 's/^provider: .*/provider: Demo_X/' "$C/tools/Demo_X/identity.yaml"
run "$C/tools/Demo_X" "$C/contract.md";                  expect 1 "tool folder kebab-case" "tool folder name is not kebab-case"; rm -rf "$C/tools/Demo_X"

echo "-- reserved name"
good_tool "$C/tools/custom" custom; run "$C/tools/custom" "$C/contract.md"
expect 1 "shipped tool named custom refused" "FAIL: $C/tools/custom: 'custom' is reserved for an instance's own tool (bind_<cap>: custom); choose another tool name"
rm -rf "$C/tools/custom"

echo "-- symlinked folders"
RL="$W/elsewhere/crm-real"; good_tool "$RL" custom
mkdir -p "$W/linked/custom-tools"; ln -s "$RL" "$W/linked/custom-tools/crm"
run "$W/linked/custom-tools/crm" "$C/contract.md" --custom; expect 0 "symlinked custom-tools/crm passes" "OK: "
RS="$W/elsewhere/demo-real"; good_tool "$RS" demo; ln -s "$RS" "$C/tools/demo2"
sed -i.bak 's/^provider: .*/provider: demo2/' "$RS/identity.yaml"
run "$C/tools/demo2" "$C/contract.md";                   expect 0 "symlinked shipped tool folder passes" "OK: "; rm "$C/tools/demo2"

echo "-- errors"
run "$W/nope" "$C/contract.md";                          expect 2 "missing folder" "ERROR:"
fresh; run "$T" "$W/nope.md";                            expect 2 "missing contract" "ERROR:"
run;                                                     expect 2 "usage" "Usage:"
printf '%s\n' '# empty' > "$W/empty.md"; run "$T" "$W/empty.md"; expect 2 "contract without operations" "ERROR:"

echo "-- importable"
if python3 -B -c "import sys; sys.path.insert(0, '_template/hooks'); import tool_check as t; print(t.read_contract.__name__, t.check_tool.__name__)" >/dev/null 2>&1; then
  _report ok "module imports"; else _report no "module does not import"; fi

echo "-- executable"
if [ -x "$TC" ]; then _report ok "tool_check.py is executable"; else _report no "tool_check.py is not executable"; fi
echo "-- Setup section"
fresh; printf '%s\n' '# bootstrap' > "$T/bootstrap.py"; run "$T" "$C/contract.md"
expect 1 "bootstrap.py without ## Setup" "needs a ## Setup section (bootstrap.py is optional; people must be able to create the fields by hand)"
printf '%s\n' '## Setup' '' 'Create field status.' >> "$T/usage.md"; run "$T" "$C/contract.md"; expect 0 "bootstrap.py with ## Setup"
rm "$T/bootstrap.py"; fresh; run "$T" "$C/contract.md";      expect 0 "no bootstrap.py: Setup not required"
echo "-- wrapped (n8n)"
wf() { # wf <dir> <auth> <tool names...> — a minimal n8n export: trigger + one HTTP tool node per name
  local d="$1" auth="$2"; shift 2
  python3 - "$d/workflow.n8n.json" "$auth" "$@" <<'PY'
import json, sys
path, auth, names = sys.argv[1], sys.argv[2], sys.argv[3:]
nodes = [{"name": "MCP", "type": "@n8n/n8n-nodes-langchain.mcpTrigger", "parameters": {"authentication": auth}}]
conns = {}
for n in names:
    nodes.append({"name": n, "type": "n8n-nodes-base.httpRequestTool", "parameters": {"method": "POST", "url": "https://api.example.com/v1/x"}})
    conns[n] = {"ai_tool": [[{"node": "MCP", "type": "ai_tool", "index": 0}]]}
json.dump({"nodes": nodes, "connections": conns}, open(path, "w"))
PY
}
wrapped() { # wrapped: the demo tool as an n8n-wrapped tool with tools create and get
  fresh; printf '%s\n' 'wrapper: n8n' >> "$T/identity.yaml"; wf "$T" bearerAuth create get whoami
}
wrapped; run "$T" "$C/contract.md";                       expect 0 "wrapped tool passes" "OK: "
fresh; printf '%s\n' 'wrapper: zapier' >> "$T/identity.yaml"; run "$T" "$C/contract.md"; expect 1 "unknown wrapper" "wrapper must be n8n"
wrapped; rm "$T/workflow.n8n.json"; run "$T" "$C/contract.md"; expect 1 "missing workflow" "missing $T/workflow.n8n.json"
wrapped; printf '{not json' > "$T/workflow.n8n.json"; run "$T" "$C/contract.md"; expect 1 "bad JSON" "not valid JSON"
wrapped; wf "$T" none create get whoami; run "$T" "$C/contract.md"; expect 1 "trigger without auth" "must require n8n OAuth2, Bearer or Header auth"
wrapped; wf "$T" n8nOAuth2 create get whoami; run "$T" "$C/contract.md"; expect 0 "trigger with n8n OAuth2 passes" "OK: "
wrapped; wf "$T" headerAuth create get whoami; run "$T" "$C/contract.md"; expect 0 "trigger with header auth passes" "OK: "
wrapped; wf "$T" bearerAuth create get whoami extra; run "$T" "$C/contract.md"; expect 1 "tool not in usage" "tool extra is not mapped in usage.md as demo:extra"
wrapped; wf "$T" bearerAuth create whoami; run "$T" "$C/contract.md"; expect 1 "usage names a missing tool" '`demo:get` is not a tool of the workflow'
wrapped; wf "$T" bearerAuth "Create Lead" get whoami; run "$T" "$C/contract.md"; expect 1 "tool name not snake_case" "must be named in snake_case"
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"][1]["parameters"]["url"] = "={{ $fromAI('url') }}"; json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "caller-set URL refused" "tool create lets the caller set its url"
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"][1]["parameters"]["headerParameters"] = {"parameters": [{"name": "Authorization", "value": "Bearer ivq_live_abcdefghijkl"}]}
json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "literal token refused" "holds a literal bearer token"
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"].append({"name": "Other", "type": "n8n-nodes-base.noOp", "parameters": {}})
d["connections"]["get"] = {"ai_tool": [[{"node": "Other", "type": "ai_tool", "index": 0}]]}
json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "tool wired elsewhere is not exposed" '`demo:get` is not a tool of the workflow'
wrapped; python3 - "$T/workflow.n8n.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
d["nodes"].append(dict(d["nodes"][0], name="MCP2")); json.dump(d, open(p, "w"))
PY
run "$T" "$C/contract.md"; expect 1 "two triggers refused" "needs exactly one MCP Server Trigger node"

echo "-- wrapped (n8n): review fixes"
mutate() { python3 - "$T/workflow.n8n.json" "$1" <<'PY'
import json, sys; p, code = sys.argv[1], sys.argv[2]; d = json.load(open(p)); exec(code); json.dump(d, open(p, "w"))
PY
}
wrapped; mutate 'd["nodes"].append({"name": ["x"], "type": "n8n-nodes-base.noOp"})'
run "$T" "$C/contract.md"; expect 1 "list as a node name: FAIL, not a crash" "every node needs a text name"
wrapped; mutate 'd["nodes"][1]["parameters"]["url"] = "={{ $fromai(\"u\") }}"'
run "$T" "$C/contract.md"; expect 1 "lowercase \$fromai in url refused" "tool create lets the caller set its url"
wrapped; mutate 'd["nodes"][1]["parameters"]["options"] = {"url": "={{ $fromAI(\"u\") }}"}'
run "$T" "$C/contract.md"; expect 1 "nested url refused" "tool create lets the caller set its options.url"
wrapped; mutate 'd["nodes"][1]["parameters"]["jsonBody"] = "={{ $fromAI(\"body\") }}"'
run "$T" "$C/contract.md"; expect 1 "caller-set request body refused" "tool create lets the caller set its jsonBody"
wrapped; mutate 'd["nodes"][1]["parameters"]["url"] = "https://api.example.com/{path}"'
run "$T" "$C/contract.md"; expect 1 "placeholder in url refused" "tool create lets the caller set its url"
wrapped; mutate 'd["nodes"][1]["parameters"]["bodyParameters"] = {"parameters": [{"name": "email", "value": "={{ $fromAI(\"email\") }}"}]}'
run "$T" "$C/contract.md"; expect 0 "a named body field from the caller is fine" "OK: "
echo "-- owner_only_send"
N="$W/pkg/capabilities/owner_notify"; NT="$N/tools/mailer"; mkdir -p "$NT"
printf '%s\n' '# Notify' '' '## Operations' '' '| `notify_owner` | x |' '' '## Invariants' '' '- `owner_only_send` — x' > "$N/contract.md"
good_notify() {
  printf '%s\n' 'capability: owner_notify' 'provider: mailer' 'server_match: mailer' > "$NT/identity.yaml"
  printf '%s\n' '# Mailer' '' '- `notify_owner` — mailer:send-email' '' '## Probe' '' 'Call list-domains.' > "$NT/usage.md"
  printf '%s\n' 'covers: [owner_only_send]' 'allow: [send-email, list-domains]' \
    'recipients:' '  - tools: [send-email]' '    at: [to]' '    bound: recipient_email' > "$NT/guard.yaml"
}
good_notify; run "$NT" "$N/contract.md"; expect 0 "notify tool passes" "OK: "
rm "$NT/guard.yaml"; run "$NT" "$N/contract.md"; expect 1 "owner_only_send needs guard.yaml" "the contract has owner_only_send, so guard.yaml must cover it"
good_notify; printf '%s\n' 'covers: [owner_only_send]' 'allow: [send-email]' > "$NT/guard.yaml"; run "$NT" "$N/contract.md"
expect 1 "owner_only_send needs recipients" "guard.yaml must pin recipients (a recipients entry) for owner_only_send"
good_notify; printf '%s\n' 'covers: [owner_only_send]' 'recipients:' '  - tools: [send-email]' '    at: [to]' '    bound: r' > "$NT/guard.yaml"; run "$NT" "$N/contract.md"
expect 1 "owner_only_send needs allow" "guard.yaml must have an allow list for owner_only_send"
good_notify; sed -i.bak 's/^allow: .*/allow: [send-email, list-domains, send-batch]/' "$NT/guard.yaml"; run "$NT" "$N/contract.md"
expect 1 "allowed tool not pinned" "send-batch is allowed but no recipients entry pins it"
printf '%s\n' '# Notify' '' '## Operations' '' '| `notify_owner` | x |' '' '## Invariants' '' '- `owner_only_send` — x' '- `no_external_send` — y' > "$N/contract.md"
good_notify; run "$NT" "$N/contract.md"; expect 1 "both invariants refused" "a contract may not list both no_external_send and owner_only_send"
printf '%s\n' '# Notify' '' '## Operations' '' '| `notify_owner` | x |' '' '## Invariants' '' '- `no_send` — x' > "$N/contract.md"
good_notify; run "$NT" "$N/contract.md"; expect 1 "old name refused" "no_send was renamed no_external_send"
echo "-- owner_only_send allow must be exact names"
printf '%s\n' '# Notify' '' '## Operations' '' '| `notify_owner` | x |' '' '## Invariants' '' '- `owner_only_send` — x' > "$N/contract.md"
allow_with() { good_notify; sed -i.bak "s/^allow: .*/allow: $1/" "$NT/guard.yaml"; run "$NT" "$N/contract.md"; }
allow_with '["*"]'; expect 1 "allow * refused" "* must be an exact tool name for owner_only_send (no wildcards)"
allow_with '[send-email, "*send*"]'; expect 1 "allow *send* refused" "*send* must be an exact tool name for owner_only_send (no wildcards)"
allow_with '[send-email, send]'; expect 1 "bare send not pinned" "send is allowed but no recipients entry pins it"
allow_with '[send-email, list-domains]'; expect 0 "probe-named exact read passes" "OK: "
allow_with '[send-email, list]'; expect 1 "token must not match inside list-domains" "list is allowed but no recipients entry pins it"
pin_with() { good_notify; printf '%s\n' 'covers: [owner_only_send]' 'allow: [send-email]' 'recipients:' "  - tools: [$1]" '    at: [to]' '    bound: r' > "$NT/guard.yaml"; run "$NT" "$N/contract.md"; }
pin_with '"send-*"'; expect 0 "recipients glob pins send-email" "OK: "
pin_with 'Send-Email'; expect 0 "recipients match is case-insensitive" "OK: "
pin_with 'send_email'; expect 1 "send_email does not pin send-email" "send-email is allowed but no recipients entry pins it"
echo "-- ledger: tables.md"
pt() { # pt <file>: schema, table names, problems from parse_tables
  OUT=$(python3 -B -c 'import sys; sys.path.insert(0, "_template/hooks"); import tool_check as t
s, tb, p = t.parse_tables(open(sys.argv[1], encoding="utf-8").read())
print("schema", s); print("tables", ",".join(tb)); print("\n".join(p))' "$1" 2>&1); RC=$?; }
LT="$W/tables.md"
printf '%s\n' '# Ledger tables' '' 'ledger_schema: 2' '' '## Cells' '' 'key: Cell' '' '| Field | Type | Options |' '|---|---|---|' \
  '| Cell | singleLineText | |' '| Last Run | dateTime | |' '| Status | singleSelect | open, done |' > "$LT"
pt "$LT"; expect 0 "valid tables.md: schema" "schema 2"
expect 0 "valid tables.md: tables" "tables Cells"
printf '%s\n' 'ledger_schema: 1' > "$LT"; pt "$LT"; expect 0 "Events only" "schema 1"
printf '%s\n' '## Cells' 'key: Cell' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "missing schema" "missing ledger_schema: <n>"
printf '%s\n' 'ledger_schema: 0' > "$LT"; pt "$LT"; expect 0 "schema 0" "ledger_schema must be a positive integer"
printf '%s\n' 'ledger_schema: 1' '## Events' 'key: X' '| X | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "Events declared" "Events is the standard table"
printf '%s\n' 'ledger_schema: 1' '## Cells' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "no key" "table Cells has no key: line"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Nope' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "key not a field" "table Cells: key Nope is not one of its fields"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | rainbow | |' > "$LT"; pt "$LT"; expect 0 "bad type" "Cells.Cell: type rainbow is not one of"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Mode | singleSelect | |' > "$LT"; pt "$LT"; expect 0 "select without options" "Cells.Mode: a singleSelect field needs options"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Cell | number | |' > "$LT"; pt "$LT"; expect 0 "duplicate field" "Cells.Cell is declared twice"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Run-ID | singleLineText | |' > "$LT"; pt "$LT"
expect 0 "collision by spelling" "Cells.Run-ID has the same name as the Events field Run ID"
printf '%s\n' 'ledger_schema: 1' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '## Cells' 'key: Cell' '| Cell | singleLineText | |' > "$LT"; pt "$LT"; expect 0 "duplicate table" "table Cells is declared twice"

echo "-- ledger: guard checks"
L="$W/pkg/capabilities/ledger"; LT2="$L/tools/demo"; mkdir -p "$LT2"
printf '%s\n' '# Ledger' '' '## Operations' '' '| `append_events` | x |' '' '## Invariants' '' \
  '- `append_only_events` — x' '- `no_delete` — y' '- `no_schema_change` — z' > "$L/contract.md"
good_ledger() {
  printf '%s\n' 'capability: ledger' 'provider: demo' 'server_match: demo' > "$LT2/identity.yaml"
  printf '%s\n' '# Demo' '' '- `append_events` — demo:create' '' '## Probe' '' 'Call demo:tables.' > "$LT2/usage.md"
  { printf '%s\n' 'covers: [append_only_events, no_delete, no_schema_change]' 'allow: [create_records, update_records]' 'deny: ["*delete*"]' \
      'refuse_args: [typecast, interfaceContext]' 'writes:' '  - kind: create' '    tools: [create_records]' '    at: ["records[].fields"]' \
      '  - kind: update' '    tools: [update_records]' '    at: ["records[].fields"]' 'unknown_writes: block' 'bound_keys_only: true' 'rules:'
    for f in "At" "Run ID" "Seq" "Activity" "Trigger" "Event" "Subject" "Outcome" "Items In" "Items Out" "Cost USD" "Duration s" "Detail" "Agent Version" "Backfilled"; do
      printf '  - field: %s\n    forbid: update\n' "$f"; done; } > "$LT2/guard.yaml"
}
good_ledger; run "$LT2" "$L/contract.md"; expect 0 "complete ledger guard passes" "OK: "
good_ledger; sed -i.bak '/^bound_keys_only/d' "$LT2/guard.yaml"; run "$LT2" "$L/contract.md"
expect 1 "append_only_events needs bound_keys_only" "append_only_events needs bound_keys_only: true"
good_ledger; python3 - "$LT2/guard.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("  - field: Detail\n    forbid: update\n",""))
PY
run "$LT2" "$L/contract.md"; expect 1 "missing forbid rule" "append_only_events needs a forbid: update rule for Detail"
good_ledger; sed -i.bak 's/^refuse_args: .*/refuse_args: [interfaceContext]/' "$LT2/guard.yaml"; run "$LT2" "$L/contract.md"
expect 1 "no_schema_change needs typecast refused" "no_schema_change needs refuse_args to include typecast"
good_ledger; sed -i.bak 's/^covers: .*/covers: [no_delete]/' "$LT2/guard.yaml"; sed -i.bak '/^bound_keys_only/d' "$LT2/guard.yaml"; run "$LT2" "$L/contract.md"
expect 0 "uncovered ledger invariants are not checked here (the gate refuses them)"
finish
