---
name: validate-agent
description: Use when checking whether an agent folder conforms to the Agent Standard, before a commit or a release, or when a validator FAIL line needs explaining.
---

Checks one agent folder against the Agent Standard (`STANDARD.md` in
this plugin) and explains every problem in plain language.

## Procedure

1. Pick the folder: the one the user names, otherwise the current
   folder. If it has no `AGENT.md`, say it is not an agent folder and
   stop.
2. Locate the validator: `bin/validate-agent.sh` in this plugin's root
   (`${CLAUDE_PLUGIN_ROOT}/bin/validate-agent.sh` on Claude Code; on
   other hosts, the `bin/` folder beside this `skills/` folder).
3. Run it: `bash <validator> <folder>`. If the user is preparing a
   release, add `--require-bump <ref>` with the ref they compare
   against (usually `origin/main`).
4. Report the result:
   - `OK: … conforms` — say so in one line; mention a `WARN:` line if
     present (a pre-1.0 agent: suggest adding `agent.yaml` and the four
     host manifests from `_template/`).
   - Each `FAIL:` line — restate it plainly, name the file, and give
     the exact fix (the key to add, the value to change, the heading to
     move). Group fixes by file.
5. Offer to apply the fixes. Apply only after the user agrees, then run
   the validator again and report the new result.

If no shell is available, perform the same checks by reading the files
against `STANDARD.md` and report in the same `OK` / `FAIL:` form.

## Failure modes

- **Fixing silently.** Never change files before the user agrees.
- **Declaring success without the validator.** When a shell exists,
  only the validator's `OK` line counts as conforming.
