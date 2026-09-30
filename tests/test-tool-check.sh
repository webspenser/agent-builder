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
expect 1 "unknown key" "unknown key 'block' (identity.yaml holds capability, provider, server_match)"
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
printf '%s\n' '# Email' '' '## Operations' '' '| `draft` | x |' '' '## Invariants' '' '- `no_send` — x' > "$E/contract.md"
printf '%s\n' 'capability: email' 'provider: mail' 'server_match: mail' > "$E/tools/mail/identity.yaml"
printf '%s\n' '`draft`' '## Probe' 'x' > "$E/tools/mail/usage.md"
run "$E/tools/mail" "$E/contract.md";                    expect 1 "no_send needs guard.yaml" "the contract has no_send, so guard.yaml must cover it"
printf '%s\n' 'covers: []' > "$E/tools/mail/guard.yaml"; run "$E/tools/mail" "$E/contract.md"
expect 1 "no_send must be covered" "covers must include no_send"
CE="$W/inst/custom-tools/email"; mkdir -p "$CE"
printf '%s\n' 'capability: email' 'provider: custom' 'server_match: mail' > "$CE/identity.yaml"; cp "$E/tools/mail/usage.md" "$CE/"
run "$CE" "$E/contract.md" --custom;                     expect 1 "custom no_send without guard refused" "must cover it"

echo "-- 2.x names"
fresh; cp "$T/identity.yaml" "$T/adapter.yaml"; run "$T" "$C/contract.md"
expect 1 "adapter.yaml beside identity.yaml refused" "adapter.yaml is the Agent Standard 2 name; 3.0 uses identity.yaml"
fresh; cp "$T/usage.md" "$T/adapter.md"; run "$T" "$C/contract.md"
expect 1 "adapter.md refused" "adapter.md is the Agent Standard 2 name; 3.0 uses usage.md"
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
finish
