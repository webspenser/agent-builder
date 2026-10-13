#!/usr/bin/env bash
# The Agent Standard guard-policy engine (_template/hooks/guard_policy.py).
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
E="$PWD/_template/hooks/guard_policy.py"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

policy() { printf '%s\n' "$@" > "$W/guard.yaml"; }
parses() { # parses <0|1> <label>
  local out rc; out=$(python3 "$E" --check "$W/guard.yaml" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && ! printf '%s' "$out" | grep -q Traceback; then _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
run() { # run <rc> <label> <tool_name> <tool_input JSON> [text] [bindings] [server_match]
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":%s}' "$3" "$4" | python3 "$E" "$W/guard.yaml" "${6:--}" "demo guard policy (crm/demo)" ${7:+"$7"} 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && { [ -z "${5:-}" ] || printf '%s\n' "$out" | grep -qF -- "$5"; } && ! printf '%s' "$out" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}

echo "-- grammar"
policy 'covers: [draft_only]' 'allow: [list-*, "*read*",' '        get-*]  # continued' 'deny: ["*delete*"]'; parses 0 "flow lists, quotes, continuation, comments"
policy 'covers: [draft_only]' 'rules:' '  - field: status' '    create: [draft]' '    update: [voided]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [v]'; parses 0 "rules block"
policy 'allow: [a]';                                  parses 1 "covers is required"
policy 'covers: [x]' 'bogus: 1';                      parses 1 "unknown key"
policy 'covers: [x]' 'covers: [y]';                   parses 1 "duplicate key"
policy 'covers: [x]' 'allow: [a, b';                  parses 1 "unclosed ["
policy 'covers: [x]' $'allow:\t[a]';                  parses 1 "tab"
policy 'covers: [x]' 'allow:' '  a: b';               parses 1 "nested map"
policy 'covers: [x]' 'allow: [*delete*]';             parses 1 "unquoted glob starting with *"
policy 'covers: [x]' 'allow: [[a]]';                  parses 1 "nested list"
policy 'covers: [x]' 'allow: a';                      parses 1 "list key given a scalar"
policy 'covers: [Bad-Id]';                            parses 1 "covers id not snake_case"
policy 'covers: [x]' 'unknown_writes: maybe';         parses 1 "unknown_writes value"
policy 'covers: [x]' 'refuse_keys: [nope]';           parses 1 "unknown refuse_keys preset"
policy 'covers: [x]' 'rules:' '  - field: status' '    create: [draft]'; parses 1 "rules without writes"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [v]' 'rules:' '  - field: status'; parses 1 "rule without a list"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c]' '    at: ["bad path!"]' '  - kind: update' '    tools: [u]' '    at: ["bad path!"]' 'rules:' '  - field: s' '    any: [a]'; parses 1 "bad at path"
policy 'covers: [x]' 'rules:';                        parses 1 "empty rules"
policy 'covers:[a]';                                  parses 1 "top-level key without a space after the colon"
policy 'covers: [a]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [v]' 'rules:' '  - field: s' '    any:[a]'; parses 1 "rule key without a space after the colon"
policy 'covers: [a]#x';                               parses 1 "# right after a list"
policy 'covers: [a]' 'unknown_writes: block#x';       parses 1 "# right after a scalar"
policy 'covers: [a]  # fine' '# whole-line comment';  parses 0 "# after whitespace is a comment"
policy 'covers: [x]' 'allow: [get:, x]';              parses 1 "plain scalar ending with a colon"
policy 'covers: [x]' 'allow: [- x]';                  parses 1 "plain scalar starting with '- '"
policy 'covers: [x]' 'allow: [? x]';                  parses 1 "plain scalar starting with '? '"
policy 'covers: [x]' 'allow: [-]';                    parses 1 "plain scalar that is just -"
policy 'covers: [x]' 'allow: [:x]';                   parses 1 "plain scalar starting with a colon"
policy 'covers: [x]' 'allow: ["\x2adelete\x2a"]';     parses 1 "backslash in double quotes"
policy 'covers: [x]' 'allow: ["a"b"]';                parses 1 "quoted scalar containing its own quote"
policy 'covers: [x]' 'allow: ["a" "b"]';              parses 1 "two adjacent scalars in one item"
policy 'covers: [x]' 'allow: [a "b"]';                parses 1 "plain scalar followed by a quoted one"
policy 'covers: [x]' 'allow: [a] b';                  parses 1 "text after the closing ]"
policy 'covers: [x]' "allow: ['a\\b']";               parses 0 "backslash in single quotes is literal"
policy 'covers: [x]' 'refuse_keys: [uuid]';           parses 1 "refuse_keys without writes"
policy 'covers: [x]' 'refuse_keys: [uuid]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]'; parses 0 "refuse_keys with writes"
: > "$W/guard.yaml"; parses 1 "empty file"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [create-record,' '      add-record-to-list]  # continued' '    at: [values]'; parses 0 "writes entry whose tools spans two lines"
policy 'covers: [x]' 'writes:' '  - kind: update' '    tools: [u]' '    at: [values]' 'rules:' '  - field: status' '    update: [voided,' '      lost]'; parses 0 "rules entry whose update spans two lines"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c,' '      d' '    at: [values]'; parses 1 "unclosed list inside an item"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c,'; parses 1 "unclosed list inside an item at end of file"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c,' '  d]' '    at: [values]'; parses 1 "item list continuation indented under 4 spaces"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c,' $'    \td]' '    at: [values]'; parses 1 "tab in an item list continuation"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c,' '      d]' '    at: [values]'
policy 'covers: [x]' 'writes:' '  - tools: [c,' '      d]' '    kind: create' '    at: [values]'; parses 0 "'- key: [' item line continues too"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c,' '      d]' '    at: [values]' 'rules:' '  - field: status' '    any: [draft]'
run 2 "a tool named on a continuation line is a known write tool" mcp__crm__d '{"values":{"status":"x"}}' "may only be written"
awk '/^## Guard policy/{f=1} f&&/^```yaml/{g=1;next} g&&/^```/{exit} g' STANDARD.md > "$W/guard.yaml"; parses 0 "STANDARD.md Guard policy example parses"

echo "-- tool names"
policy 'covers: [no_delete]' 'allow: [list-*, update-record]' 'deny: ["*delete*"]'
run 0 "allowed tool"                 mcp__attio__list-records '{}'
run 2 "not in allow list"            mcp__attio__create-list '{}' "is not in the allow list"
run 2 "deny beats allow"             mcp__attio__list-delete-me '{}' "is denied"
run 2 "deny on a later __ suffix"    mcp__attio__delete__record '{}' "is denied"
run 0 "server containing __"         mcp__x__Attio__list-records '{}'
policy 'covers: [no_delete]' 'allow: [list-*, get-*]' 'deny: ["*delete*"]'
run 0 "server_match: plain server"   mcp__attio__get-x '{}' "" - attio
run 0 "server_match: server with __" mcp__x__Attio__get-x '{}' "" - attio
run 2 "server_match: tool with __ cannot ride on allow" mcp__attio__purge__get-x '{}' "is not in the allow list" - attio
run 0 "no server_match: any suffix counts" mcp__attio__purge__get-x '{}'
run 2 "server_match: deny still checks every suffix" mcp__attio__get__delete-x '{}' "is denied" - attio
policy 'covers: [no_delete]' 'allow: [list-*, update-record]' 'deny: ["*delete*"]'
run 0 "case-insensitive"             mcp__attio__LIST-Records '{}'
policy 'covers: [no_delete]' 'deny: ["*delete*"]'
run 0 "no allow list: others allowed" mcp__attio__create-list '{}'

echo "-- writes and rules"
policy 'covers: [draft_only, dnc_one_way]' 'writes:' '  - kind: create' '    tools: [add-record-to-list]' '    at: [entry_values, values, "records[].fields"]' '  - kind: update' '    tools: [update-entry]' '    at: [entry_values, values, "records[].fields"]' 'unwrap: [option, value]' 'refuse_keys: [uuid]' \
  'rules:' '  - field: status' '    create: [draft]' '    update: [voided]' '  - field: do_not_contact' '    update: [true]'
run 0 "create draft"                 mcp__a__add-record-to-list '{"entry_values":{"status":"draft"}}'
run 2 "create approved"              mcp__a__add-record-to-list '{"entry_values":{"status":"approved"}}' "status may only be written as draft on create"
run 0 "wrapped value"                mcp__a__add-record-to-list '{"entry_values":{"status":{"option":"Draft"}}}'
run 2 "mixed wrapped values"         mcp__a__add-record-to-list '{"entry_values":{"status":{"option":"draft","value":"sent"}}}'
run 2 "unwrap key plus a sibling key" mcp__a__add-record-to-list '{"entry_values":{"status":{"option":"draft","option_id":"approved-id"}}}' "cannot check this call"
run 2 "unknown object shape"         mcp__a__add-record-to-list '{"entry_values":{"status":{"foo":1}}}' "cannot check this call"
run 0 "update voided"                mcp__a__update-entry '{"entry_values":{"status":"voided"}}'
run 2 "update draft"                 mcp__a__update-entry '{"entry_values":{"status":"draft"}}' "on update"
run 0 "dnc true"                     mcp__a__update-entry '{"values":{"do_not_contact":true}}'
run 2 "dnc false"                    mcp__a__update-entry '{"values":{"do_not_contact":false}}' "do_not_contact may only be written as true"
run 0 "dnc false on create (no create list)" mcp__a__add-record-to-list '{"entry_values":{"do_not_contact":false}}'
run 2 "uuid key refused"             mcp__a__update-entry '{"values":{"925c1cde-cba6-453e-96f9-5bd8f498d8a3":"sent"}}' "addressed by ID"
run 2 "unknown tool with values is an update" mcp__a__assert-entry '{"entry_values":{"status":"approved"}}'
run 0 "unknown tool without values"  mcp__a__create-note '{"title":"x"}'
run 2 "list path"                    mcp__a__update-entry '{"records":[{"fields":{"status":"voided"}},{"fields":{"Status":"sent"}}]}'
run 2 "field name normalization"     mcp__a__update-entry '{"records":[{"fields":{"Do Not Contact":false}}]}'
run 2 "list inside a list at a writes path" mcp__a__update-entry '{"records":[[{"fields":{"status":"approved"}}]]}' "cannot check this call"
run 2 "non-object list item at a writes path" mcp__a__update-entry '{"records":["x"]}' "cannot check this call"
run 0 "missing writes path is skipped" mcp__a__update-entry '{"other":1}'
run 2 "zero-width space in a key"    mcp__a__update-entry $'{"values":{"status\u200b":"approved"}}' "invisible characters"
run 2 "attribute map not an object"  mcp__a__update-entry '{"entry_values":[1]}' "cannot check this call"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [v]' 'unknown_writes: block' 'rules:' '  - field: s' '    any: [a]'
run 2 "unknown_writes: block"        mcp__a__other '{"v":{"s":"a"}}' "not a known create or update tool"

echo "-- field identity"
policy 'covers: [draft_only]' 'writes:' '  - kind: create' '    tools: [create_records]' '    at: ["records[].fields"]' '  - kind: update' '    tools: [update_records]' '    at: ["records[].fields"]' \
  'rules:' '  - field: Status' '    create: [draft]' '    update: [voided]'
printf '%s\n' '# CRM binding — Airtable' 'base_id: appXXXXXXXXXXXXXX' 'field_status: fldAAAAAAAAAAAAAA' > "$W/bindings.md"
run 2 "status by field ID"           mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"approved"}}]}' "Status may only be written as voided" "$W/bindings.md"
run 0 "draft by field ID on create"  mcp__airtable__create_records '{"records":[{"fields":{"fldAAAAAAAAAAAAAA":"draft","fldBBBBBBBBBBBBBB":"x"}}]}' "" "$W/bindings.md"
run 0 "read tool needs no binding"   mcp__airtable__list_records '{}'
bind() { printf '%s\n' "$@" > "$W/bindings.md"; }
UPD='{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"approved"}}]}'
VOID='{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"voided"}}]}'
bind 'field_status: `fldAAAAAAAAAAAAAA`'
run 2 "backticked ID enforced"       mcp__airtable__update_records "$UPD" "Status may only be written as voided" "$W/bindings.md"
run 0 "backticked ID: voided allowed" mcp__airtable__update_records "$VOID" "" "$W/bindings.md"
bind 'field_status: "fldAAAAAAAAAAAAAA"'
run 2 "quoted ID enforced"           mcp__airtable__update_records "$UPD" "Status may only be written as voided" "$W/bindings.md"
run 0 "quoted ID: voided allowed"    mcp__airtable__update_records "$VOID" "" "$W/bindings.md"
bind 'field_status: fldAAAAAAAAAAAAAA  # note'
run 2 "ID with trailing comment blocked" mcp__airtable__update_records "$VOID" "field_status must be a bare ID" "$W/bindings.md"
bind 'field_status: fldAAAAAAAAAAAAAA (Activities.Status)'
run 2 "ID with parenthetical blocked" mcp__airtable__update_records "$VOID" "field_status must be a bare ID" "$W/bindings.md"

echo "-- bound_keys_only"
policy 'covers: [x]' 'bound_keys_only: true';         parses 1 "bound_keys_only needs writes"
policy 'covers: [x]' 'bound_keys_only: yes' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]'; parses 1 "bound_keys_only only takes true"
B() { policy 'covers: [draft_only]' 'bound_keys_only: true' 'writes:' '  - kind: create' '    tools: [create_records]' '    at: ["records[].fields"]' \
  '  - kind: update' '    tools: [update_records]' '    at: ["records[].fields"]' \
  'rules:' '  - field: Status' '    create: [draft]' '    update: [voided]'; }
B; parses 0 "bound_keys_only parses"
bind 'base_id: appXXXXXXXXXXXXXX' 'field_status: fldAAAAAAAAAAAAAA' 'field_lead: fldLLLLLLLLLLLLL1' 'field_lead: fldLLLLLLLLLLLLL2' 'field_name: fldNNNNNNNNNNNNNN'
run 0 "recorded IDs pass"            mcp__airtable__create_records '{"records":[{"fields":{"fldAAAAAAAAAAAAAA":"draft","fldNNNNNNNNNNNNNN":"Acme"}}]}' "" "$W/bindings.md"
run 0 "both IDs of a repeated name count" mcp__airtable__create_records '{"records":[{"fields":{"fldLLLLLLLLLLLLL1":["recA"]}},{"fields":{"fldLLLLLLLLLLLLL2":["recB"]}}]}' "" "$W/bindings.md"
run 0 "recorded ID matched ignoring case" mcp__airtable__create_records '{"records":[{"fields":{"FLDNNNNNNNNNNNNNN":"Acme"}}]}' "" "$W/bindings.md"
run 2 "unrecorded fld key blocked"   mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldZZZZZZZZZZZZZZ":"approved"}}]}' "fldZZZZZZZZZZZZZZ is not a recorded field ID" "$W/bindings.md"
run 2 "field name key blocked too"   mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"Status":"voided"}}]}' "Status is not a recorded field ID" "$W/bindings.md"
run 2 "rule still applies to a recorded ID" mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"approved"}}]}' "Status may only be written as voided" "$W/bindings.md"
bind 'field_status: fldS1SSSSSSSSSSSS' 'field_status: fldS2SSSSSSSSSSSS'
run 2 "a rule covers every ID recorded under its name" mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldS2SSSSSSSSSSSS":"sent"}}]}' "Status may only be written as voided" "$W/bindings.md"
bind 'base_id: appXXXXXXXXXXXXXX'
run 2 "no field_ lines: every write blocked" mcp__airtable__create_records '{"records":[{"fields":{"fldNNNNNNNNNNNNNN":"Acme"}}]}' "has not recorded any field IDs" "$W/bindings.md"
run 0 "no field_ lines: reads pass"  mcp__airtable__list_records '{}' "" "$W/bindings.md"
bind '- field_status: fldAAAAAAAAAAAAAA'
run 2 "bulleted line is not a binding" mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"voided"}}]}' "has not recorded any field IDs" "$W/bindings.md"
run 2 "no bindings file: writes blocked" mcp__airtable__create_records '{"records":[{"fields":{"fldNNNNNNNNNNNNNN":"Acme"}}]}' "has not recorded any field IDs"

echo "-- agent policy"
aparses() { # aparses <0|1> <label>
  local out rc; out=$(python3 "$E" --check --agent "$W/guard.yaml" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && ! printf '%s' "$out" | grep -q Traceback; then _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
arun() { # arun <rc> <label> <tool_name> [text]
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":{}}' "$3" | python3 "$E" --agent "$W/guard.yaml" "demo agent guard policy" 2>&1); rc=$?
  if [ "$rc" -eq "$1" ] && { [ -z "${4:-}" ] || printf '%s\n' "$out" | grep -qF -- "$4"; } && ! printf '%s' "$out" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$rc): $out"; fi
}
policy 'covers: [no_external_send]' 'deny: ["*send*", "*reply*"]'; aparses 0 "agent policy parses"
policy 'deny: ["*send*"]';                         aparses 0 "covers is optional"
policy 'covers: [no_external_send]';                        aparses 1 "deny is required"
policy 'deny: []';                                 aparses 1 "deny may not be empty"
policy 'deny: ["*send*"]' 'allow: [x]';            aparses 1 "allow is not an agent policy key"
policy 'deny: ["*send*"]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]'; aparses 1 "writes is not an agent policy key"
policy 'covers: [Bad]' 'deny: ["*send*"]';         aparses 1 "covers ids are snake_case"
: > "$W/guard.yaml";                               aparses 1 "empty agent policy"
policy 'covers: [no_external_send]' 'deny: ["*send*", "*reply*"]'
arun 2 "deny matches on any server" mcp__claude_ai_Slack__slack_send_message "Blocked by demo agent guard policy: slack_send_message is denied (*send*)"
arun 2 "deny matches a suffix after __ in the server" mcp__x__gmail__reply "denied (*reply*)"
arun 0 "replies is not reply" mcp__claude_ai_Attio__list-comment-replies
arun 0 "other tools pass" mcp__claude_ai_Gmail__create_draft
arun 2 "non-MCP name fails closed" Bash "cannot check this call"
out=$(printf '{not json' | python3 "$E" --agent "$W/guard.yaml" x 2>&1); rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && _report ok "agent: bad JSON blocks" || _report no "agent bad JSON (rc=$rc): $out"
out=$(printf '{}' | python3 "$E" --agent "$W/missing.yaml" x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "agent: missing policy blocks" || _report no "agent missing (rc=$rc): $out"
policy 'covers: [x]' 'allow: [a]' 'deny: ["*send*"]'
out=$(python3 "$E" --check "$W/guard.yaml" 2>&1); rc=$?
[ "$rc" -eq 0 ] && _report ok "plain --check still parses a tool policy" || _report no "plain --check (rc=$rc): $out"
out=$(python3 "$E" --check --agent "$W/guard.yaml" 2>&1); rc=$?
[ "$rc" -eq 1 ] && _report ok "a tool policy is not an agent policy" || _report no "tool as agent (rc=$rc): $out"

echo "-- fail closed"
policy 'covers: [x]' 'allow: [a'
run 2 "invalid policy blocks"        mcp__a__a '{}' "cannot check this call"
out=$(printf '{not json' | python3 "$E" "$W/guard.yaml" - x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "bad JSON blocks" || _report no "bad JSON (rc=$rc): $out"
out=$(printf '{}' | python3 "$E" "$W/missing.yaml" - x 2>&1); rc=$?
[ "$rc" -eq 2 ] && _report ok "missing policy blocks" || _report no "missing policy (rc=$rc): $out"
mkdir "$W/dirpolicy.yaml"
out=$(printf '{}' | python3 "$E" "$W/dirpolicy.yaml" - x 2>&1); rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q Traceback && _report ok "directory as policy blocks" || _report no "directory policy (rc=$rc): $out"
out=$(python3 "$E" --check "$W/dirpolicy.yaml" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL: IsADirectoryError' && ! printf '%s' "$out" | grep -q Traceback && _report ok "--check on a directory: FAIL, no traceback" || _report no "--check directory (rc=$rc): $out"
printf '\xff\xfe' > "$W/bin.yaml"
out=$(python3 "$E" --check "$W/bin.yaml" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ! printf '%s' "$out" | grep -q Traceback && _report ok "--check on binary junk: FAIL, no traceback" || _report no "--check junk (rc=$rc): $out"
[ -x "$E" ] && _report ok "engine executable" || _report no "engine not executable"

echo "-- writes"
policy 'covers: [x]' 'create_tools: [c]';             parses 1 "create_tools is an unknown key"
policy 'covers: [x]' 'writes:' '  - kind: delete' '    tools: [t]' '    at: [v]'; parses 1 "kind must be create or update"
policy 'covers: [x]' 'writes:' '  - kind: create' '    at: [v]';                    parses 1 "writes entry needs tools"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [t]' '    at: ["bad path!"]'; parses 1 "writes at must be a path"
policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [t]' '    at: [v]' '    extra: [y]'; parses 1 "unknown writes key"
policy 'covers: [x]' 'rules:' '  - field: s' '    any: [a]';                          parses 1 "rules need writes"

H() { policy 'covers: [draft_only, dnc_one_way]' 'allow: [manage_crm_objects, get_*]' 'deny: ["*delete*"]' \
  'writes:' '  - kind: create' '    tools: [manage_crm_objects]' '    at: ["createRequest.objects[].properties"]' \
  '  - kind: update' '    tools: [manage_crm_objects]' '    at: ["updateRequest.objects[].properties"]' \
  "unknown_writes: ${1:-block}" 'rules:' '  - field: sp_status' '    create: [draft]' '    update: [voided]' \
  '  - field: sp_do_not_contact' '    update: ["true"]'; }
T=mcp__claude_ai_HubSpot__manage_crm_objects
H; parses 0 "hubspot-shaped policy parses"
run 0 "create at draft allowed" $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"sp_status":"draft"}}]}}'
run 2 "create at sent blocked" $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"sp_status":"sent"}}]}}' "sp_status may only be written as draft on create"
run 0 "update to voided allowed" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"voided"}}]}}'
run 2 "update to approved blocked" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"approved"}}]}}' "on update"
run 2 "create draft is not an allowed update" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"draft"}}]}}'
run 2 "both kinds in one call: bad create next to harmless update blocks" $T '{"createRequest":{"objects":[{"objectType":"tasks","properties":{"sp_status":"approved"}}]},"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"properties":{"sp_status":"voided"}}]}}' "on create"
run 0 "dnc set to string true" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":"true"}}]}}'
run 0 "dnc set to boolean true" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":true}}]}}'
run 2 "dnc cleared (string) blocked" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":"false"}}]}}'
run 2 "dnc cleared (boolean) blocked" $T '{"updateRequest":{"objects":[{"objectType":"companies","objectId":1,"properties":{"sp_do_not_contact":false}}]}}'
run 0 "association-only update (no properties) allowed" $T '{"updateRequest":{"objects":[{"objectType":"tasks","objectId":1,"associations":[{"targetObjectId":2,"targetObjectType":"companies"}]}]}}'
run 2 "delete denied" mcp__claude_ai_HubSpot__delete_records '{}' "denied"
run 2 "unmatched tool writing at a listed path, unknown_writes: block" mcp__claude_ai_HubSpot__get_thing '{"createRequest":{"objects":[{"properties":{"sp_status":"draft"}}]}}' "not a known create or update tool"
H update
run 2 "unmatched tool at a listed path, unknown_writes: update checks as update" mcp__claude_ai_HubSpot__get_thing '{"createRequest":{"objects":[{"properties":{"sp_status":"draft"}}]}}' "on update"
H
run 0 "stated limit: matched tool, unlisted sibling path is not checked" $T '{"upsertRequest":{"objects":[{"properties":{"sp_status":"sent"}}]}}'

echo "-- writes: coverage gaps (fix round 1)"
G() { policy 'covers: [x]' 'writes:' '  - kind: create' '    tools: [m]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [w]' \
  "unknown_writes: ${1:-block}" 'rules:' '  - field: s' '    any: [a]'; }
G;        run 2 "matched tool writing at a path listed only by another entry: block" mcp__a__m '{"w":{"s":"approved"}}' "which no writes entry for this tool lists"
G update; run 2 "same, unknown_writes: update checks as update" mcp__a__m '{"w":{"s":"approved"}}' "s may only be written as a on update"
G update; run 0 "same, allowed value passes" mcp__a__m '{"w":{"s":"a"}}'
G;        run 0 "matched tool at its own path is fine" mcp__a__m '{"v":{"s":"a"}}'
G;        run 0 "matched tool at a path no entry lists is unchecked" mcp__a__m '{"z":{"s":"approved"}}'
G;        run 2 "matched tool with tool_input not an object" mcp__a__m '[1]' "cannot check this call"

echo "-- forbid"
F() { policy 'covers: [draft_only]' 'writes:' '  - kind: create' '    tools: [c]' '    at: [v]' '  - kind: update' '    tools: [u]' '    at: [v]' 'rules:' '  - field: hs_pipeline_stage' "$@" '  - field: hs_task_status' '    create: [NOT_STARTED]' '    update: [COMPLETED]'; }
F '    forbid: true';                   parses 0 "forbid: true parses"
F '    forbid: yes';                    parses 1 "forbid: yes fails"
F '    forbid: false';                  parses 1 "forbid: false fails"
F '    forbid: [true]';                 parses 1 "forbid as a list fails"
F '    forbid: true' '    create: [x]'; parses 1 "forbid combined with create fails"
F '    forbid: true' '    update: [x]'; parses 1 "forbid combined with update fails"
F '    forbid: true' '    any: [x]';    parses 1 "forbid combined with any fails"
F '    forbid: true'
run 2 "forbidden field blocked on create" mcp__a__c '{"v":{"hs_pipeline_stage":"done","hs_task_status":"NOT_STARTED"}}' "hs_pipeline_stage may not be written"
run 2 "forbidden field blocked on update" mcp__a__u '{"v":{"hs_pipeline_stage":"done"}}' "hs_pipeline_stage may not be written"
run 2 "forbidden field blocked with a differently cased key" mcp__a__u '{"v":{"HS_Pipeline_Stage":"done"}}' "hs_pipeline_stage may not be written"
run 2 "forbidden field blocked with a spaced key" mcp__a__u '{"v":{"hs pipeline-stage":"x"}}' "hs_pipeline_stage may not be written"
run 2 "forbidden field blocked even when empty" mcp__a__u '{"v":{"hs_pipeline_stage":""}}' "hs_pipeline_stage may not be written"
run 0 "other fields in the same map still allowed (create)" mcp__a__c '{"v":{"hs_task_status":"NOT_STARTED","hs_task_subject":"x"}}'
run 0 "other fields in the same map still allowed (update)" mcp__a__u '{"v":{"hs_task_status":"COMPLETED"}}'
run 2 "other rules still apply next to a forbid rule" mcp__a__c '{"v":{"hs_task_status":"COMPLETED"}}' "hs_task_status may only be written as NOT_STARTED on create"
F '    forbid: true' '    binding_id: required'; parses 1 "binding_id is an unknown rule key"
F '    forbid: true'
printf '%s\n' 'field_hs_pipeline_stage: stageprop1' > "$W/fb.md"
run 2 "forbid blocks a bound ID" mcp__a__u '{"v":{"stageprop1":"x"}}' "hs_pipeline_stage may not be written" "$W/fb.md"
F '    forbid: update';                 parses 0 "forbid: update parses"
F '    forbid: update' '    create: [x]'; parses 1 "forbid: update combined with create fails"
F '    forbid: update'
run 0 "forbid: update allows the field on create" mcp__a__c '{"v":{"hs_pipeline_stage":"done","hs_task_status":"NOT_STARTED"}}'
run 2 "forbid: update blocks the field on update" mcp__a__u '{"v":{"hs_pipeline_stage":"done"}}' "hs_pipeline_stage may not be changed after create"
run 2 "forbid: update blocks on an unknown write checked as update" mcp__a__other '{"v":{"hs_pipeline_stage":"done"}}' "may not be changed after create"
run 2 "forbid: update blocks a bound ID on update" mcp__a__u '{"v":{"stageprop1":"x"}}' "may not be changed after create" "$W/fb.md"

echo "-- recipients"
policy 'covers: [owner_only_send]' 'allow: [send-email, list-domains]' \
  'recipients:' '  - tools: [send-email]' '    at: [to, cc, bcc]' '    bound: recipient_email' \
  '  - tools: [send-email]' '    at: [from]' '    bound: sender_email'
parses 0 "recipients block parses"
printf '%s\n' 'recipient_email: owner@acme.com' 'recipient_email: `ops@acme.com`' "sender_email: 'no-reply@acme.com'" > "$W/b.md"
run 0 "pinned to and from" mcp__resend__send-email '{"to":["owner@acme.com"],"from":"no-reply@acme.com"}' "" "$W/b.md"
run 0 "case and spaces ignored" mcp__resend__send-email '{"to":[" Owner@ACME.com "],"from":"no-reply@acme.com"}' "" "$W/b.md"
run 0 "string to, not a list" mcp__resend__send-email '{"to":"ops@acme.com","from":"no-reply@acme.com"}' "" "$W/b.md"
run 0 "null cc counts as absent" mcp__resend__send-email '{"to":["owner@acme.com"],"cc":null,"from":"no-reply@acme.com"}' "" "$W/b.md"
run 0 "backtick-quoted binding matches" mcp__resend__send-email '{"to":["ops@acme.com"],"from":"no-reply@acme.com"}' "" "$W/b.md"
run 2 "other recipient blocked" mcp__resend__send-email '{"to":["lead@prospect.com"],"from":"no-reply@acme.com"}' "lead@prospect.com is not a pinned value (recipient_email)" "$W/b.md"
run 2 "extra bcc blocked" mcp__resend__send-email '{"to":["owner@acme.com"],"bcc":["lead@prospect.com"],"from":"no-reply@acme.com"}' "is not a pinned value" "$W/b.md"
run 2 "display-name form blocked" mcp__resend__send-email '{"to":["Owner <owner@acme.com>"],"from":"no-reply@acme.com"}' "is not a pinned value" "$W/b.md"
run 2 "other sender blocked" mcp__resend__send-email '{"to":["owner@acme.com"],"from":"me@acme.com"}' "me@acme.com is not a pinned value (sender_email)" "$W/b.md"
run 2 "no recipient blocked" mcp__resend__send-email '{"from":"no-reply@acme.com"}' "send-email names no pinned value at to, cc, bcc" "$W/b.md"
run 2 "object recipient blocked" mcp__resend__send-email '{"to":{"email":"owner@acme.com"},"from":"no-reply@acme.com"}' "cannot check this call" "$W/b.md"
run 2 "no binding line blocks" mcp__resend__send-email '{"to":["owner@acme.com"],"from":"no-reply@acme.com"}' "no recipient_email line in bindings" -
printf '%s\n' 'recipient_email: Owner <owner@acme.com>' 'sender_email: no-reply@acme.com' > "$W/b2.md"
run 2 "non-bare binding blocks" mcp__resend__send-email '{"to":["owner@acme.com"],"from":"no-reply@acme.com"}' "recipient_email must be a bare value" "$W/b2.md"
run 0 "a tool outside recipients tools is not checked" mcp__resend__list-domains '{}' "" "$W/b.md"
policy 'covers: [x]' 'recipients:' '  - tools: [s]' '    at: [to]';                         parses 1 "recipients entry without bound"
policy 'covers: [x]' 'recipients:' '  - tools: [s]' '    at: [to]' '    bound: Bad-Key';    parses 1 "bound not snake_case"
policy 'covers: [x]' 'recipients:' '  - at: [to]' '    bound: r';                          parses 1 "recipients entry without tools"
policy 'covers: [x]' 'recipients:' '  - tools: [s]' '    at: ["bad path!"]' '    bound: r'; parses 1 "recipients bad path"
policy 'covers: [x]' 'recipients:' '  - tools: [s]' '    at: [to]' '    bound: r' '    kind: create'; parses 1 "unknown recipients key"
printf '%s\n' 'field_status: fldAAAAAAAAAAAAAA' 'field_status: "fldBBBBBBBBBBBBBB"' > "$W/f.md"
policy 'covers: [x]' 'writes:' '  - kind: update' '    tools: [u]' '    at: [values]' 'rules:' '  - field: status' '    forbid: update'
run 2 "repeated field_ lines still both match" mcp__crm__u '{"values":{"fldBBBBBBBBBBBBBB":"x"}}' "may not be changed after create" "$W/f.md"

echo "-- refuse_args"
policy 'covers: [owner_only_send]' 'allow: [send_message]' 'refuse_args: [draftId, replyThreadId]' \
  'recipients:' '  - tools: [send_message]' '    at: [to]' '    bound: recipient_email'
parses 0 "refuse_args parses"
printf '%s\n' 'recipient_email: owner@acme.com' > "$W/r.md"
run 2 "draftId refused even with a pinned to" mcp__gmail__send_message '{"draftId":"r-1","to":["owner@acme.com"]}' "send_message may not use draftId" "$W/r.md"
run 2 "draftId alone refused" mcp__gmail__send_message '{"draftId":"r-1"}' "may not use draftId" "$W/r.md"
run 0 "null refused arg passes" mcp__gmail__send_message '{"draftId":null,"to":["owner@acme.com"]}' "" "$W/r.md"
run 0 "empty refused arg passes" mcp__gmail__send_message '{"replyThreadId":"","to":["owner@acme.com"]}' "" "$W/r.md"
run 2 "snake_case draft_id refused" mcp__gmail__send_message '{"draft_id":"r-1","to":["owner@acme.com"]}' "send_message may not use draft_id" "$W/r.md"
run 2 "lowercase draftid refused" mcp__gmail__send_message '{"draftid":"r-1","to":["owner@acme.com"]}' "send_message may not use draftid" "$W/r.md"
run 2 "upper-case dashed DRAFT-ID refused" mcp__gmail__send_message '{"DRAFT-ID":"r-1","to":["owner@acme.com"]}' "send_message may not use DRAFT-ID" "$W/r.md"
run 2 "snake_case reply_thread_id refused" mcp__gmail__send_message '{"reply_thread_id":"t-1","to":["owner@acme.com"]}' "send_message may not use reply_thread_id" "$W/r.md"
run 0 "snake_case draft_id null passes" mcp__gmail__send_message '{"draft_id":null,"to":["owner@acme.com"]}' "" "$W/r.md"
run 2 "numeric zero refused arg blocked" mcp__gmail__send_message '{"draftId":0,"to":["owner@acme.com"]}' "send_message may not use draftId" "$W/r.md"
run 2 "boolean false refused arg blocked" mcp__gmail__send_message '{"draftId":false,"to":["owner@acme.com"]}' "send_message may not use draftId" "$W/r.md"
policy 'covers: [x]' 'refuse_args: []';        parses 1 "empty refuse_args"
policy 'covers: [x]' 'refuse_args: [a.b]';     parses 0 "refuse_args entry may be a dotted path"
policy 'covers: [x]' 'refuse_args: ["a[].b"]';  parses 0 "refuse_args entry may be a list path"
policy 'covers: [x]' 'refuse_args: ["bad path!"]'; parses 1 "refuse_args entry is neither a name nor a path"
policy 'covers: [x]' 'refuse_args: ["a..b"]';   parses 1 "refuse_args path with an empty segment"
policy 'covers: [x]' 'refuse_args: ["a.[]"]';   parses 1 "refuse_args path with a bare []"
policy 'covers: [x]' 'refuse_args: draftId';   parses 1 "refuse_args given a scalar"

echo "-- nested refuse_args, limits and only_keys"
policy 'covers: [pinned_inputs]' 'allow: [crawl, list-actors]' 'refuse_args: ["startUrls[].payload", "startUrls[].method", proxyConfig]' \
  'limits:' '  - tools: [crawl]' '    at: [startUrls]' '    bound: max_sites' '    kind: count'
parses 0 "nested refuse_args and limits parse"
LB2="$W/lim.md"; printf '%s\n' 'max_sites: 2' > "$LB2"
C=mcp__apify__crawl
HUGE=$(python3 -c 'print("9"*400)')
run 0 "one plain URL passes" $C '{"startUrls":[{"url":"https://a.test"}]}' "" "$LB2"
run 2 "method refused" $C '{"startUrls":[{"url":"https://a.test","method":"POST"}]}' "crawl may not use startUrls[].method" "$LB2"
run 2 "payload refused" $C '{"startUrls":[{"url":"https://a.test","payload":"x"}]}' "crawl may not use startUrls[].payload" "$LB2"
run 0 "empty payload passes" $C '{"startUrls":[{"url":"https://a.test","payload":""}]}' "" "$LB2"
run 0 "null payload passes" $C '{"startUrls":[{"url":"https://a.test","payload":null}]}' "" "$LB2"
run 2 "payload on the second item refused" $C '{"startUrls":[{"url":"https://a.test"},{"url":"https://b.test","payload":"x"}]}' "may not use startUrls[].payload" "$LB2"
run 2 "segment case folded" $C '{"startUrls":[{"url":"https://a.test","Method":"GET"}]}' "may not use startUrls[].method" "$LB2"
run 2 "segment case and snake folded" $C '{"start_urls":[{"url":"https://a.test","PAYLOAD":"x"}]}' "may not use startUrls[].payload" "$LB2"
run 2 "false payload refused" $C '{"startUrls":[{"url":"https://a.test","payload":false}]}' "may not use startUrls[].payload" "$LB2"
run 2 "proxyConfig object refused" $C '{"proxyConfig":{"useApifyProxy":true}}' "crawl may not use proxyConfig" "$LB2"
run 0 "null proxyConfig passes" $C '{"proxyConfig":null}' "" "$LB2"
run 2 "scalar where the list is expected blocks" $C '{"startUrls":"https://a.test"}' "startUrls[].payload: unexpected shape" "$LB2"
run 2 "scalar item under a nested refuse path blocks" $C '{"startUrls":["https://a.test"]}' "startUrls[].payload: unexpected shape" "$LB2"
run 0 "null startUrls passes" $C '{"startUrls":null}' "" "$LB2"
run 0 "no startUrls passes" $C '{}' "" "$LB2"
run 2 "three URLs exceed the bound" $C '{"startUrls":[{"url":"a"},{"url":"b"},{"url":"c"}]}' "crawl exceeds max_sites at startUrls (3 > 2)" "$LB2"
run 0 "two URLs pass" $C '{"startUrls":[{"url":"a"},{"url":"b"}]}' "" "$LB2"
run 2 "count path folds the name" $C '{"start_urls":[{"url":"a"},{"url":"b"},{"url":"c"}]}' "exceeds max_sites at startUrls (3 > 2)" "$LB2"
run 2 "count: a nested list blocks" $C '{"startUrls":[[{"url":"a"},{"url":"b"},{"url":"c"}]]}' "startUrls: a counted list may not contain lists" "$LB2"
run 2 "count: an object blocks" $C '{"startUrls":{"url":"a"}}' "startUrls: expected a list" "$LB2"
run 2 "count: a string blocks" $C '{"startUrls":"abc"}' "startUrls: expected a list" "$LB2"
run 2 "no max_sites line blocks" $C '{"startUrls":[{"url":"a"}]}' "no max_sites line in bindings" -
printf '%s\n' 'max_sites: 2' 'max_sites: 3' > "$W/lim2.md"
run 2 "two different max_sites values block" $C '{"startUrls":[{"url":"a"}]}' "max_sites must be one number" "$W/lim2.md"
printf '%s\n' 'max_sites: 2' 'max_sites: 2.0' > "$W/lim3.md"
run 0 "two equal max_sites values pass" $C '{"startUrls":[{"url":"a"}]}' "" "$W/lim3.md"
printf '%s\n' 'max_sites: two' > "$W/lim4.md"
run 2 "a non-numeric max_sites blocks" $C '{"startUrls":[{"url":"a"}]}' "max_sites must be one number" "$W/lim4.md"
run 2 "a bad bound blocks even without the path" $C '{}' "max_sites must be one number" "$W/lim4.md"
run 0 "a tool outside the limits entry is not capped" mcp__apify__list-actors '{"startUrls":[{"url":"a"},{"url":"b"},{"url":"c"}]}' "" "$LB2"
policy 'covers: [pinned_inputs]' 'allow: [run]' 'limits:' '  - tools: [run]' '    at: [n]' '    bound: max_n' '    kind: max'
printf '%s\n' 'max_n: 5' > "$W/n.md"
run 0 "max equal to the bound passes" mcp__apify__run '{"n":5}' "" "$W/n.md"
run 0 "max of 1 passes" mcp__apify__run '{"n":1}' "" "$W/n.md"
run 2 "max over the bound blocks" mcp__apify__run '{"n":6}' "run exceeds max_n at n (6 > 5)" "$W/n.md"
run 2 "max: zero blocks" mcp__apify__run '{"n":0}' "n: must be at least 1" "$W/n.md"
run 2 "max: negative blocks" mcp__apify__run '{"n":-1}' "n: must be at least 1" "$W/n.md"
run 2 "max: negative string blocks" mcp__apify__run '{"n":"-3"}' "n: must be at least 1" "$W/n.md"
run 2 "max: a one-item list blocks" mcp__apify__run '{"n":[100]}' "n: expected a number" "$W/n.md"
run 2 "max: an object blocks" mcp__apify__run '{"n":{"v":3}}' "n: expected a number" "$W/n.md"
run 2 "max: boolean blocks" mcp__apify__run '{"n":true}' "n: expected a number" "$W/n.md"
run 0 "max: numeric string passes" mcp__apify__run '{"n":"5"}' "" "$W/n.md"
run 2 "max: numeric string over the bound blocks" mcp__apify__run '{"n":"6"}' "(6 > 5)" "$W/n.md"
run 2 "max: scientific string blocks" mcp__apify__run '{"n":"6e0"}' "n: expected a number" "$W/n.md"
run 2 "max: NaN blocks" mcp__apify__run '{"n":NaN}' "n: expected a number" "$W/n.md"
run 2 "max: Infinity blocks" mcp__apify__run '{"n":Infinity}' "n: expected a number" "$W/n.md"
run 2 "max: huge integer blocks" mcp__apify__run "{\"n\":$HUGE}" "exceeds max_n at n" "$W/n.md"
run 0 "max: null passes" mcp__apify__run '{"n":null}' "" "$W/n.md"
run 0 "max: absent value passes" mcp__apify__run '{}' "" "$W/n.md"
run 2 "tool_input that is not an object blocks" mcp__apify__run '[1]' "cannot check this call" "$W/n.md"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: count'; parses 0 "limits kind count"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: max';   parses 0 "limits kind max"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m';                    parses 1 "limits entry without kind"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: min';   parses 1 "limits kind other than count or max"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    kind: max';                   parses 1 "limits entry without bound"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: Bad-Key' '    kind: max'; parses 1 "limits bound not snake_case"
policy 'covers: [x]' 'limits:' '  - at: [n]' '    bound: m' '    kind: max';                     parses 1 "limits entry without tools"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: ["bad path!"]' '    bound: m' '    kind: max'; parses 1 "limits bad path"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: max' '    extra: 1'; parses 1 "unknown limits key"
policy 'covers: [x]' 'limits:';                                                                    parses 1 "empty limits"
policy 'covers: [x]' 'limits: [a]';                                                                parses 1 "limits given a list"
policy 'covers: [x]' 'recipients:' '  - tools: [s]' '    at: [to]' '    bound: r' '    kind: max'; parses 1 "recipients entry has no kind"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: max' '    required: true'; parses 0 "limits required: true"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: max' '    required: yes'; parses 1 "limits required: yes"
policy 'covers: [x]' 'limits:' '  - tools: [s]' '    at: [n]' '    bound: m' '    kind: max' '    required: false'; parses 1 "limits required: false"
policy 'covers: [x]' 'recipients:' '  - tools: [s]' '    at: [to]' '    bound: r' '    required: true'; parses 1 "recipients has no required"
policy 'covers: [pinned_inputs]' 'allow: [crawl]' 'limits:' '  - tools: [crawl]' '    at: [startUrls]' '    bound: max_sites' '    kind: count' '    required: true'
run 2 "required: an absent path blocks" $C '{}' "crawl names no startUrls" "$LB2"
run 2 "required: a null path blocks" $C '{"startUrls":null}' "crawl names no startUrls" "$LB2"
run 0 "required: a present path passes" $C '{"startUrls":[{"url":"a"}]}' "" "$LB2"
run 0 "required: an empty list is present" $C '{"startUrls":[]}' "" "$LB2"
run 2 "required: a variant spelling counts as the path" $C '{"start_urls":[{"url":"a"},{"url":"b"},{"url":"c"}]}' "exceeds max_sites at startUrls (3 > 2)" "$LB2"
run 2 "required: an over-bound list still blocks" $C '{"startUrls":[{"url":"a"},{"url":"b"},{"url":"c"}]}' "exceeds max_sites" "$LB2"
policy 'covers: [x]' 'limits:' '  - tools: [crawl]' '    at: [a, b]' '    bound: max_sites' '    kind: max' '    required: true'
run 2 "required: every path is required" $C '{"a":1}' "crawl names no b" "$LB2"
policy 'covers: [x]' 'refuse_args: ["a.b"]'
run 2 "tool_input that is not an object blocks a nested refuse path" mcp__apify__run '[1]' "cannot check this call" -

echo "-- only_keys"
policy 'covers: [pinned_inputs]' 'allow: [crawl, list-actors]' 'only_keys:' '  - tools: [crawl]' '    at: ["$"]' '    keys: [startUrls, maxRequests]' \
  '  - tools: [crawl]' '    at: ["startUrls[]"]' '    keys: [url]'
parses 0 "only_keys parses"
run 0 "root keys allowed" $C '{"startUrls":[],"maxRequests":3}' "" -
run 2 "root key not listed" $C '{"startUrls":[],"proxyConfig":{}}' "crawl may not use proxyConfig" -
run 2 "root keys are exact: other case blocks" $C '{"StartUrls":[]}' "crawl may not use StartUrls" -
run 2 "root keys are exact: snake case blocks" $C '{"start_urls":[]}' "crawl may not use start_urls" -
run 2 "root keys are exact: snake maxRequests blocks" $C '{"max_requests":3}' "crawl may not use max_requests" -
run 0 "root key spelled exactly passes" $C '{"startUrls":[]}' "" -
run 0 "empty input passes" $C '{}' "" -
run 2 "root key with a null value is still not listed" $C '{"proxyConfig":null}' "may not use proxyConfig" -
run 2 "tool_input that is not an object blocks" $C '[1]' "cannot check this call" -
run 0 "item keys allowed" $C '{"startUrls":[{"url":"a"}]}' "" -
run 2 "item keys are exact: other case blocks" $C '{"startUrls":[{"URL":"a"}]}' "crawl may not use startUrls[].URL" -
run 2 "requestsFromUrl refused" $C '{"startUrls":[{"url":"a","requestsFromUrl":"b"}]}' "crawl may not use startUrls[].requestsFromUrl" -
run 2 "headers refused" $C '{"startUrls":[{"url":"a","headers":{}}]}' "crawl may not use startUrls[].headers" -
run 2 "userData null still refused" $C '{"startUrls":[{"url":"a","userData":null}]}' "may not use startUrls[].userData" -
run 2 "bad second item refused" $C '{"startUrls":[{"url":"a"},{"url":"b","method":"POST"}]}' "may not use startUrls[].method" -
run 2 "scalar item is not an object" $C '{"startUrls":["a"]}' "startUrls[]: expected an object" -
run 2 "string where the list is expected" $C '{"startUrls":"a"}' "startUrls[]: unexpected shape" -
run 0 "null startUrls passes" $C '{"startUrls":null}' "" -
run 0 "a tool outside the entry is not checked" mcp__apify__list-actors '{"proxyConfig":{}}' "" -
policy 'covers: [x]' 'allow: [crawl]' 'only_keys:' '  - tools: [crawl]' '    at: [opts]' '    keys: [inner]' '  - tools: [crawl]' '    at: [opts.inner]' '    keys: [k]'
run 0 "exact dotted path passes" $C '{"opts":{"inner":{"k":1}}}' "" -
run 2 "exact dotted path: a variant parent key blocks" $C '{"opts":{"Inner":{"zzz":1}}}' "crawl may not use opts.Inner" -
run 2 "exact dotted path: a bad inner key blocks" $C '{"opts":{"inner":{"zzz":1}}}' "crawl may not use opts.inner.zzz" -
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    at: [a.b]' '    keys: [k]'; parses 0 "only_keys dotted path"
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    at: [a]';                      parses 1 "only_keys without keys"
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    keys: [k]';                    parses 1 "only_keys without at"
policy 'covers: [x]' 'only_keys:' '  - at: [a]' '    keys: [k]';                      parses 1 "only_keys without tools"
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    at: ["bad path!"]' '    keys: [k]'; parses 1 "only_keys bad path"
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    at: [a]' '    keys: [a.b]';  parses 1 "only_keys key that is not a plain name"
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    at: [a]' '    keys: []';     parses 1 "only_keys empty keys"
policy 'covers: [x]' 'only_keys:' '  - tools: [s]' '    at: [a]' '    keys: [k]' '    bound: b'; parses 1 "only_keys has no bound"
policy 'covers: [x]' 'only_keys:';                                                    parses 1 "empty only_keys"

echo "-- agent exempt"
policy 'covers: [no_external_send]' 'deny: ["*send*"]' 'exempt: [owner_notify]'; aparses 0 "exempt parses"
policy 'covers: [no_external_send]' 'deny: ["*send*"]' 'exempt: [Owner-Notify]'; aparses 1 "exempt not snake_case"
policy 'covers: [no_external_send]' 'deny: ["*send*"]' 'exempt: []'; aparses 1 "empty exempt"
policy 'covers: [no_external_send]' 'deny: ["*send*"]' 'exempt: [owner_notify]'
arun() { # arun <rc> <label> <tool_name> [exempt server_match...]
  local rc out want="$1" lbl="$2" t="$3"; shift 3
  local extra=(); for m in "$@"; do extra+=(--exempt "$m"); done
  out=$(printf '{"tool_name":"%s","tool_input":{}}' "$t" | python3 "$E" --agent "$W/guard.yaml" "demo agent guard policy" ${extra[@]+"${extra[@]}"} 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && ! printf '%s' "$out" | grep -q Traceback; then _report ok "$lbl"; else _report no "$lbl (rc=$rc): $out"; fi
}
arun 2 "send denied without exemption" mcp__claude_ai_Resend__send-email
arun 0 "send on exempt server skips deny" mcp__claude_ai_Resend__send-email resend
arun 2 "exemption is per server" mcp__claude_ai_Slack__slack_send_message resend
arun 2 "exempt match in another server's tool name is still denied" mcp__claude_ai_Slack__resend_message resend
arun 0 "exempt match in a server segment containing __" mcp__x__Resend__send resend
arun 2 "bad exempt value blocks" mcp__claude_ai_Resend__send-email 'Re send'
out=$(python3 "$E" --exempt-caps "$W/guard.yaml"); [ "$out" = owner_notify ] && _report ok "--exempt-caps lists capabilities" || _report no "--exempt-caps: $out"
policy 'covers: [owner_only_send, other]' 'allow: [a]'
out=$(python3 "$E" --covers "$W/guard.yaml" | tr '\n' ' '); [ "$out" = "owner_only_send other " ] && _report ok "--covers lists covers" || _report no "--covers: $out"
policy 'deny: ['
python3 "$E" --exempt-caps "$W/guard.yaml" >/dev/null 2>&1 && _report no "--exempt-caps bad policy should fail" || _report ok "--exempt-caps bad policy exits non-zero"
python3 "$E" --covers "$W/guard.yaml" >/dev/null 2>&1 && _report no "--covers bad policy should fail" || _report ok "--covers bad policy exits non-zero"

echo "-- ledger (airtable)"
cp _ledger/tools/airtable/guard.yaml "$W/guard.yaml"
parses 0 "ledger guard parses"
LB="$W/ledger.md"
printf '%s\n' 'base_id: appAAAAAAAAAAAAAA' 'field_at: fldAT000000000000' 'field_run_id: fldRUN00000000000' \
  'field_seq: fldSEQ00000000000' 'field_event: fldEVT00000000000' 'field_cell: fldCEL00000000000' > "$LB"
A=mcp__claude_ai_Airtable__; R='"baseId":"appAAAAAAAAAAAAAA","tableId":"tblE0000000000000"'
run 0 "append an event" ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"fldAT000000000000\":\"2026-10-19T14:02:00Z\",\"fldRUN00000000000\":\"prospect-20261019T1400Z\",\"fldSEQ00000000000\":1,\"fldEVT00000000000\":\"run_started\"}}]}" "" "$LB" airtable
run 2 "edit an event" ${A}update_records_for_table "{$R,\"records\":[{\"id\":\"recA0000000000000\",\"fields\":{\"fldEVT00000000000\":\"error\"}}]}" "Event may not be changed after create" "$LB" airtable
run 2 "upsert into Events" ${A}update_records_for_table "{$R,\"performUpsert\":{\"fieldIdsToMergeOn\":[\"fldRUN00000000000\"]},\"records\":[{\"fields\":{\"fldRUN00000000000\":\"x\"}}]}" "Run ID may not be changed after create" "$LB" airtable
run 0 "upsert an agent-table row" ${A}update_records_for_table "{$R,\"performUpsert\":{\"fieldIdsToMergeOn\":[\"fldCEL00000000000\"]},\"records\":[{\"fields\":{\"fldCEL00000000000\":\"Oakland|hvac\"}}]}" "" "$LB" airtable
run 2 "typecast false" ${A}create_records_for_table "{$R,\"typecast\":false,\"records\":[{\"fields\":{\"fldEVT00000000000\":\"step\"}}]}" "may not use typecast" "$LB" airtable
run 2 "interfaceContext" ${A}create_records_for_table "{$R,\"interfaceContext\":{\"interfaceId\":\"pbdAAAAAAAAAAAAAA\"},\"records\":[{\"fields\":{\"fldEVT00000000000\":\"step\"}}]}" "may not use interfaceContext" "$LB" airtable
run 2 "unrecorded field ID" ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"fldOTHER000000000\":\"x\"}}]}" "is not a recorded field ID" "$LB" airtable
run 2 "field by name, not ID" ${A}create_records_for_table "{$R,\"records\":[{\"fields\":{\"Event\":\"step\"}}]}" "is not a recorded field ID" "$LB" airtable
for t in delete_records_for_table create_field update_field create_table update_table create_base create_automation revert_action create_record_comment submit_form publish_interface; do
  run 2 "denied or not allowed: $t" ${A}$t "{$R}" "" "$LB" airtable
done
run 0 "read records" ${A}list_records_for_table "{$R}" "" "$LB" airtable
run 0 "read schema" ${A}list_tables_for_base '{"baseId":"appAAAAAAAAAAAAAA"}' "" "$LB" airtable

echo "-- pinned values (numbers)"
policy 'covers: [pinned_inputs]' 'allow: [run-maps]' 'recipients:' '  - tools: [run-maps]' '    at: [maxPlaces]' '    bound: max_places'
PB="$W/pins.md"; printf '%s\n' 'max_places: 60' > "$PB"
run 0 "number equal to binding"   mcp__apify__run-maps '{"maxPlaces":60}'    "" "$PB"
run 0 "float equal to binding"    mcp__apify__run-maps '{"maxPlaces":60.0}'  "" "$PB"
run 0 "numeric string"            mcp__apify__run-maps '{"maxPlaces":"60"}'  "" "$PB"
run 0 "numeric string, spaces"    mcp__apify__run-maps '{"maxPlaces":" 60 "}' "" "$PB"
run 2 "larger number blocks"      mcp__apify__run-maps '{"maxPlaces":5000}'  "5000 is not a pinned value (max_places)" "$PB"
run 2 "boolean blocks"            mcp__apify__run-maps '{"maxPlaces":true}'  "a pinned value must be a string, a number, or a list of them" "$PB"
printf '%s\n' 'max_places: 1' > "$W/pins1.md"
run 2 "true never equals 1"       mcp__apify__run-maps '{"maxPlaces":true}'  "a pinned value must be a string, a number, or a list of them" "$W/pins1.md"
run 2 "object blocks"             mcp__apify__run-maps '{"maxPlaces":{"n":60}}' "a pinned value must be a string, a number, or a list of them" "$PB"
run 2 "nested list blocks"        mcp__apify__run-maps '{"maxPlaces":[[60]]}' "a pinned value must be a string, a number, or a list of them" "$PB"
run 0 "list of equal numbers"     mcp__apify__run-maps '{"maxPlaces":[60, 60.0]}' "" "$PB"
run 2 "missing argument blocks"   mcp__apify__run-maps '{}'                  "run-maps names no pinned value at maxPlaces" "$PB"
printf '%s\n' 'max_places: sixty' > "$W/pinsx.md"
run 2 "non-numeric binding never equals a number" mcp__apify__run-maps '{"maxPlaces":60}' "60 is not a pinned value (max_places)" "$W/pinsx.md"
run 2 "scientific string blocks"  mcp__apify__run-maps '{"maxPlaces":"6e1"}' "6e1 is not a pinned value (max_places)" "$PB"
run 2 "underscore string blocks"  mcp__apify__run-maps '{"maxPlaces":"6_0"}' "6_0 is not a pinned value (max_places)" "$PB"
run 0 "signed string passes"      mcp__apify__run-maps '{"maxPlaces":"+60"}' "" "$PB"
run 2 "Arabic-Indic digits block" mcp__apify__run-maps '{"maxPlaces":"٦٠"}'  "is not a pinned value (max_places)" "$PB"
run 2 "list with a larger number blocks" mcp__apify__run-maps '{"maxPlaces":[60, 5000]}' "5000 is not a pinned value" "$PB"
run 2 "NaN blocks"                mcp__apify__run-maps '{"maxPlaces":NaN}'   "is not a pinned value (max_places)" "$PB"
run 2 "Infinity blocks"           mcp__apify__run-maps '{"maxPlaces":Infinity}' "is not a pinned value (max_places)" "$PB"
printf '%s\n' 'max_places: 9007199254740992' > "$W/pinsbig.md"
run 2 "distinct large integers stay distinct" mcp__apify__run-maps '{"maxPlaces":9007199254740993}' "9007199254740993 is not a pinned value" "$W/pinsbig.md"
run 0 "equal large integer passes" mcp__apify__run-maps '{"maxPlaces":9007199254740992}' "" "$W/pinsbig.md"
HUGE=$(python3 -c 'print("9"*400)')
run 2 "400-digit integer blocks"  mcp__apify__run-maps "{\"maxPlaces\":$HUGE}" "is not a pinned value (max_places)" "$PB"
echo "-- --pins"
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); [ "$OUT" = "max_places" ] && _report ok "--pins prints the bound key" || _report no "--pins: $OUT"
policy 'covers: [x]' 'deny: ["*a*"]'
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); rc=$?; [ "$rc" -eq 0 ] && [ -z "$OUT" ] && _report ok "--pins prints nothing without recipients" || _report no "--pins empty (rc=$rc): $OUT"
policy 'covers: [x]' 'recipients:' '  - tools: [a]' '    at: [p]' '    bound: max_places' '  - tools: [b]' '    at: [q]' '    bound: max_places'
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); [ "$OUT" = "max_places" ] && _report ok "--pins prints a shared bound key once" || _report no "--pins shared: $OUT"
policy 'covers: [x]' 'limits:' '  - tools: [b]' '    at: [q]' '    bound: max_sites' '    kind: count' '  - tools: [c]' '    at: [r]' '    bound: max_places' '    kind: max' 'recipients:' '  - tools: [a]' '    at: [p]' '    bound: max_places'
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); [ "$OUT" = $'max_places\nmax_sites' ] && _report ok "--pins prints recipients keys then limits keys, once each" || _report no "--pins limits: $OUT"
printf 'covers: [x\n' > "$W/guard.yaml"
OUT=$(python3 -B "$E" --pins "$W/guard.yaml" 2>&1); rc=$?; [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q '^FAIL:' && _report ok "--pins on a bad policy fails" || _report no "--pins bad (rc=$rc): $OUT"

finish
