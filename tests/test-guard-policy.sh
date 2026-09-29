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
policy 'covers: [draft_only]' 'rules:' '  - field: status' '    create: [draft]' '    update: [voided]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]'; parses 0 "rules block"
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
policy 'covers: [x]' 'rules:' '  - field: status' '    create: [draft]'; parses 1 "rules without create_tools/update_tools/values_at"
policy 'covers: [x]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]' 'rules:' '  - field: status'; parses 1 "rule without a list"
policy 'covers: [x]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: ["bad path!"]' 'rules:' '  - field: s' '    any: [a]'; parses 1 "bad values_at path"
policy 'covers: [x]' 'rules:';                        parses 1 "empty rules"
policy 'covers:[a]';                                  parses 1 "top-level key without a space after the colon"
policy 'covers: [a]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]' 'rules:' '  - field: s' '    any:[a]'; parses 1 "rule key without a space after the colon"
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
policy 'covers: [x]' 'refuse_keys: [uuid]';           parses 1 "refuse_keys without values_at"
policy 'covers: [x]' 'refuse_keys: [uuid]' 'values_at: [v]'; parses 0 "refuse_keys with values_at"
: > "$W/guard.yaml"; parses 1 "empty file"

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
policy 'covers: [draft_only, dnc_one_way]' 'create_tools: [add-record-to-list]' 'update_tools: [update-entry]' \
  'values_at: [entry_values, values, "records[].fields"]' 'unwrap: [option, value]' 'refuse_keys: [uuid]' \
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
run 2 "list inside a list at values_at" mcp__a__update-entry '{"records":[[{"fields":{"status":"approved"}}]]}' "cannot check this call"
run 2 "non-object list item at values_at" mcp__a__update-entry '{"records":["x"]}' "cannot check this call"
run 0 "missing values_at key is skipped" mcp__a__update-entry '{"other":1}'
run 2 "zero-width space in a key"    mcp__a__update-entry $'{"values":{"status\u200b":"approved"}}' "invisible characters"
run 2 "attribute map not an object"  mcp__a__update-entry '{"entry_values":[1]}' "cannot check this call"
policy 'covers: [x]' 'create_tools: [c]' 'update_tools: [u]' 'values_at: [v]' 'unknown_writes: block' 'rules:' '  - field: s' '    any: [a]'
run 2 "unknown_writes: block"        mcp__a__other '{"v":{"s":"a"}}' "not a known create or update tool"

echo "-- field identity"
policy 'covers: [draft_only]' 'create_tools: [create_records]' 'update_tools: [update_records]' 'values_at: ["records[].fields"]' \
  'rules:' '  - field: Status' '    binding_id: required' '    create: [draft]' '    update: [voided]'
printf '%s\n' '# CRM binding — Airtable' 'base_id: appXXXXXXXXXXXXXX' 'field_status: fldAAAAAAAAAAAAAA' > "$W/bindings.md"
run 2 "status by field ID"           mcp__airtable__update_records '{"records":[{"id":"recX","fields":{"fldAAAAAAAAAAAAAA":"approved"}}]}' "Status may only be written as voided" "$W/bindings.md"
run 0 "draft by field ID on create"  mcp__airtable__create_records '{"records":[{"fields":{"fldAAAAAAAAAAAAAA":"draft","fldBBBBBBBBBBBBBB":"x"}}]}' "" "$W/bindings.md"
run 2 "required ID missing"          mcp__airtable__create_records '{"records":[{"fields":{"fldBBBBBBBBBBBBBB":"x"}}]}' "has not recorded field_status"
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
bind 'base_id: `appXXXXXXXXXXXXXX` (my base)' '- field_status: fldAAAAAAAAAAAAAA'
run 2 "bullet form ignored: not recorded" mcp__airtable__update_records "$VOID" "has not recorded field_status" "$W/bindings.md"

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

finish
