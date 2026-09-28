#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_pass validate/run.sh _template
assert_pass validate/run.sh _template ""
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/not-an-agent"
assert_fail validate/run.sh "$W/not-an-agent"
assert_contains validate/action.yml 'using: composite'
assert_contains validate/action.yml 'require-bump-against'
assert_contains validate/action.yml '$GITHUB_ACTION_PATH/run.sh'

# injection_lines <file> — prints every line holding `${{` that is not an env
# value line of the form `INPUT_*: ${{ inputs.* }}` (script-injection guard).
injection_lines() {
  local all
  all=$(grep -n '\${{' "$1" || true)
  printf '%s\n' "$all" \
    | grep -vE '^[0-9]+:[[:space:]]*INPUT_[A-Z0-9_]+:[[:space:]]*\$\{\{ inputs\.[A-Za-z0-9_-]+ \}\}[[:space:]]*$' \
    | grep -v '^$' || true
}

bad=$(injection_lines validate/action.yml)
if [ -z "$bad" ]; then _report ok "validate/action.yml: \${{ only on INPUT_* env lines"
else _report no "validate/action.yml has \${{ outside INPUT_* env lines: $bad"; fi

# The guard catches expressions anywhere, not only on a `run:` line.
printf '%s\n' 'runs:' '  steps:' '    - shell: bash' '      run: |' \
  '        echo "${{ inputs.path }}"' > "$W/multiline.yml"
[ -n "$(injection_lines "$W/multiline.yml")" ] \
  && _report ok "guard catches \${{ inside a run: | block" \
  || _report no "guard missed \${{ inside a run: | block"
printf '%s\n' '    env:' '      INPUT_PATH: ${{ inputs.path }} && echo ${{ github.token }}' > "$W/envtail.yml"
[ -n "$(injection_lines "$W/envtail.yml")" ] \
  && _report ok "guard rejects extra expressions on an env line" \
  || _report no "guard accepted extra expressions on an env line"

finish
