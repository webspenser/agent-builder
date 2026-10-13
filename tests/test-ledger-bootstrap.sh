#!/usr/bin/env bash
# _ledger/tools/airtable/bootstrap.py, offline: the network call is faked.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
B=_ledger/tools/airtable/bootstrap.py
py() { OUT=$(python3 -B -c "import importlib.util, sys
spec = importlib.util.spec_from_file_location('b', '$B'); b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
$1" 2>&1); RC=$?; }
expect() { # expect <rc> <label> [text]
  if [ "$RC" -eq "$1" ] && { [ -z "${3:-}" ] || printf '%s\n' "$OUT" | grep -qF -- "$3"; } && ! printf '%s' "$OUT" | grep -q Traceback; then
    _report ok "$2"; else _report no "$2 (rc=$RC): $OUT"; fi
}

echo "-- field specs"
py "print(b.field_spec('Event', 'singleSelect', ('run_started', 'step')))";    expect 0 "select choices" "'choices': [{'name': 'run_started'}, {'name': 'step'}]"
py "print(b.field_spec('Key', 'formula', ('{Run ID} & \"#\" & {Seq}',)))";       expect 0 "formula" "'formula': '{Run ID} & \"#\" & {Seq}'"
py "print(b.field_spec('Seq', 'number', ()))";                                expect 0 "number precision 0" "'precision': 0"
py "print(b.field_spec('Cost USD', 'currency', ()))";                         expect 0 "currency" "'symbol': '\$'"
py "print(b.field_spec('At', 'dateTime', ()))";                               expect 0 "dateTime UTC" "'timeZone': 'utc'"
py "print(b.field_spec('Recorded At', 'createdTime', ()))";                   expect 0 "createdTime has no options" "{'name': 'Recorded At', 'type': 'createdTime'}"
py "print(b.field_spec('Recorded At', 'createdTime', ()))";                   printf '%s' "$OUT" | grep -q options && _report no "createdTime sends options" || _report ok "createdTime sends no options key"

echo "-- plan"
py "w = b.wanted('.', events_only=True); a, e = b.plan({}, w)
first = a[0]; names = [f['name'] for f in first[2]]
plain = not any(f['type'] in ('formula', 'createdTime') for f in first[2])
print(first[0], first[1], names[0], plain, [(k, t, p['name']) for k, t, p in a[1:]]); print(e)"
expect 0 "empty base: create Events, Run ID primary, computed after" "create_table Events Run ID True [('create_field', 'Events', 'Key'), ('create_field', 'Events', 'Recorded At')]"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS if n not in ('Run ID', 'Seq', 'Key')}}}
a, e = b.plan(ex, w); print([p['name'] for k, t, p in a])"
expect 0 "existing table: plain fields before computed ones" "['Run ID', 'Seq', 'Key']"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS}}}
a, e = b.plan(ex, w); print(len(a), len(e))"
expect 0 "complete base: no actions" "0 0"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS if n != 'Detail'}}}
a, e = b.plan(ex, w); print(a)"
expect 0 "missing field: create it" "('create_field', 'Events', {'name': 'Detail', 'type': 'multilineText'})"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': 'number' if n == 'Subject' else t, 'choices': list(o) if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS}}}
a, e = b.plan(ex, w); print(e)"
expect 0 "type mismatch is an error" "Events.Subject is number, the ledger needs singleLineText"
py "w = b.wanted('.', events_only=True)
ex = {'Events': {'id': 'tbl1', 'fields': {n: {'type': t, 'choices': [c for c in o if c != 'dry_run'] if t == 'singleSelect' else []} for n, t, o in b.tool_check.LEDGER_EVENTS}}}
a, e = b.plan(ex, w); print(e)"
expect 0 "missing select option is an error" "Events.Outcome lacks option dry_run"

echo "-- tables.md"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/capabilities/ledger"
printf '%s\n' 'ledger_schema: 2' '## Cells' 'key: Cell' '| Cell | singleLineText | |' '| Runs | number | |' > "$T/capabilities/ledger/tables.md"
py "w = b.wanted('$T'); print([t for t, _ in w])";                             expect 0 "agent tables follow Events" "['Events', 'Cells']"
printf '%s\n' 'ledger_schema: 0' > "$T/capabilities/ledger/tables.md"
py "w = b.wanted('$T')";                                                       expect 1 "invalid tables.md stops" "ledger_schema must be a positive integer"

echo "-- main, faked network"
py "b.call = lambda *a, **k: (_ for _ in ()).throw(AssertionError('no call expected'))
import os; os.environ.pop('AIRTABLE_TOKEN', None); sys.exit(b.main(['--base', 'appAAAAAAAAAAAAAA']))"
expect 2 "no token: exit 2" "AIRTABLE_TOKEN is not set"
py "import os; os.environ['AIRTABLE_TOKEN'] = 'pat-canary-12345'
calls = []
def fake(method, path, body=None):
    calls.append((method, path)); return 200, {'tables': []}
b.call = fake; rc = b.main(['--base', 'appAAAAAAAAAAAAAA', '--dry-run']); print(calls); sys.exit(rc)"
expect 0 "dry run reads only" "[('GET', '/meta/bases/appAAAAAAAAAAAAAA/tables')]"
printf '%s' "$OUT" | grep -q 'pat-canary-12345' && _report no "printed the token" || _report ok "never prints the token"
py "import os; os.environ['AIRTABLE_TOKEN'] = 'pat-canary-12345'
def fake(method, path, body=None):
    return (500, {'error': 'boom'}) if method == 'POST' else (200, {'tables': []})
b.call = fake; sys.exit(b.main(['--base', 'appAAAAAAAAAAAAAA']))"
expect 1 "a failed write stops with exit 1" "create table Events failed (500)"
printf '%s' "$OUT" | grep -q 'pat-canary-12345' && _report no "printed the token on the error path" || _report ok "error path never prints the token"
WS_FAKE="import os; os.environ['AIRTABLE_TOKEN'] = 'pat-canary-12345'
calls = []
def fake(method, path, body=None):
    calls.append((method, path, body))
    if (method, path) == ('POST', '/meta/bases'):
        return 200, {'id': 'appBBBBBBBBBBBBBB'}
    if method == 'GET':
        fields = [b.field_spec(*f) for f in b.tool_check.LEDGER_EVENTS if f[1] not in ('formula', 'createdTime')]
        return 200, {'tables': [{'id': 'tblEvents', 'name': 'Events', 'fields': fields}]}
    return FIELD_STATUS, {'error': 'nope'} if FIELD_STATUS != 200 else {}
b.call = fake"
py "FIELD_STATUS = 200
$WS_FAKE
rc = b.main(['--workspace', 'wspAAAAAAAAAAAAAA'])
sent = [c[2] for c in calls if (c[0], c[1]) == ('POST', '/meta/bases')][0]['tables'][0]['fields']
print('bad types in create body:', [f['name'] for f in sent if f['type'] in ('formula', 'createdTime')]); sys.exit(rc)"
expect 0 "workspace: base then computed fields" "base_id: appBBBBBBBBBBBBBB"
for want in "created field Events.Key" "created field Events.Recorded At" "ledger_schema: 1 built" "bad types in create body: []"; do
  printf '%s\n' "$OUT" | grep -qF -- "$want" && _report ok "workspace output: $want" || _report no "workspace output lacks: $want: $OUT"
done
printf '%s' "$OUT" | grep -q 'pat-canary-12345' && _report no "workspace run printed the token" || _report ok "workspace run never prints the token"
py "FIELD_STATUS = 422
$WS_FAKE
sys.exit(b.main(['--workspace', 'wspAAAAAAAAAAAAAA']))"
expect 1 "workspace follow-up failure: exit 1, points at --base" "--base appBBBBBBBBBBBBBB"
py "b.call = lambda *a, **k: (_ for _ in ()).throw(AssertionError('no call expected'))
import os; os.environ.pop('AIRTABLE_TOKEN', None); sys.exit(b.main(['--workspace', 'wspAAAAAAAAAAAAAA', '--dry-run']))"
expect 0 "workspace dry run needs no token and makes no call" "would create a base"
py "sys.exit(b.main(['--base', 'not-a-base']))";                               expect 2 "bad base id" "not an Airtable base ID"
finish
