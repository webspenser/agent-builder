# Agent Standard 3.0: tools, not adapters — design

Status: approved in conversation on 2026-09-29. Sub-project 7, part 1 of 2.
Part 2, the HubSpot CRM tool for sales-partner, gets its own spec after
this ships.

## Goal

Name every file by its single purpose, and give clients and authors one
dedicated skill for adding a tool.

Today two files in each tool folder share the name "adapter" and differ
only in format:
- `adapter.yaml` holds identity for the hooks;
- `adapter.md` holds the model's playbook.

The top-level host folder is also called `adapters/`. In 3.0 the word
"adapter" leaves the standard.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Tool folder = `identity.yaml` + `guard.yaml` (optional) + `usage.md` + `bootstrap.py` (optional), under `capabilities/<cap>/tools/<tool>/` | Each file has one reader and one purpose, and its name says which. The rules keep their own file so they can be reviewed or swapped alone. |
| 2 | Host shims move from `adapters/` to `hosts/` | Named for what they hold, and removes the last use of "adapter". |
| 3 | Instance `custom-adapters/<cap>/` becomes `custom-tools/<cap>/`; still one custom tool per capability | A binding picks one tool, so more than one per capability is YAGNI. |
| 4 | New template skill `add-tool` in every agent, with two targets: a client instance or the agent's own package | One way to add a tool for clients and authors alike. The HubSpot build (part 2) uses it, which tests it. |
| 5 | New reference hook `hooks/tool_check.py`, the single checker for a tool folder, used by the validator, `add-tool` and `schedule_check.py` | Custom tools get checked today only by `guard_policy.py --check`. One checker means the package and instance rules cannot drift. |
| 6 | Standard 3.0 (major); builder 3.0.0, sales-partner 3.0.0; new action tag `validate@v3`; `v2` stays frozen at 2.1 | The layout change breaks every agent. With a new tag, agents opt in by editing one line and no tag is force-moved. |
| 7 | No backward compatibility (dev-phase policy). Old layouts fail validation with a message naming the new layout. sales-partner ships a migration note for instances. | Policy: one clean current standard. The migration mechanism already exists, so the note costs nothing. |

Unchanged:
- `bind_<cap>: <tool>` and `bind_<cap>: custom`;
- `bindings/<cap>.md`;
- the guard policy format and engine behavior;
- contracts;
- `schedules.yaml`;
- activities;
- the scheduled prompt.

## Agent Standard 3.0 layout

Package:

```
agent.yaml                  standard: "3.0"
hosts/CLAUDE.md GEMINI.md AGENTS.md          (was adapters/)
capabilities/<cap>/
  contract.md
  tools/<tool>/                               (was adapters/<tool>/)
    identity.yaml    capability, provider, server_match   (was adapter.yaml)
    usage.md         maps every operation; has ## Probe   (was adapter.md)
    guard.yaml       optional; required when the contract has no_send
    bootstrap.py     optional
hooks/
  hooks.json session-start.sh guard.sh guard_policy.py schedule_check.py
  tool_check.py                               (new)
skills/add-tool/SKILL.md                      (new; required when capabilities exist)
```

Instance:

```
custom-tools/<cap>/          (was custom-adapters/<cap>/)
  identity.yaml              provider: custom
  usage.md
  guard.yaml                 optional
```

`identity.yaml` keys are unchanged from `adapter.yaml`:
- `capability` must be the folder's capability.
- `provider` must be the folder's tool name, or `custom` in an instance.
- `server_match` must match `[a-z0-9_-]+`.

No other keys are allowed.

The builder's `_capability-template/` becomes
`_capability-template/tools/example-provider/` with the three renamed
files. `install.sh` (template and agents) reads `hosts/`.

## `hooks/tool_check.py`

This is a reference hook: identical in every agent and executable. Like
the other hooks, it follows the fail-closed and no-traceback rules.

CLI: `tool_check.py <tool-folder> <contract.md> [--custom]`. It prints one
`FAIL: <message>` line per problem and exits:
- 0 when the folder is a valid tool;
- 1 when there are FAIL lines;
- 2 on ERROR (unreadable input).

Checks:
1. `identity.yaml` exists.
   - Its keys are exactly `capability`, `provider` and `server_match`, as flat scalars.
   - `capability` equals the capability folder name.
   - `provider` equals the tool folder name, or is `custom` with `--custom`.
   - `server_match` matches `[a-z0-9_-]+`.
2. `usage.md` exists, maps every contract operation (each `` `operation` ``
   from the contract's Operations table appears in it), and has a
   `## Probe` section.
3. If `guard.yaml` exists:
   - it parses (via `guard_policy.py`, imported like `schedule_check.py` does);
   - `covers` names only contract invariants.
4. If the contract has `no_send`, `guard.yaml` must exist and cover it.
5. The old names (`adapter.yaml`, `adapter.md`) in the folder are a FAIL:
   `<file> is the Agent Standard 2 name; 3.0 uses identity.yaml / usage.md`.

These checks move out of `bin/lib/check_manifests.py` `check_adapter`
into `tool_check.py`. The validator calls `tool_check.py` for each shipped
tool, the way it already loads the guard engine from `_template/hooks/`.

`schedule_check.py` imports `tool_check.py` to read identity, replacing
its own `adapter()` reader. It adds one rule: a bound tool that fails
`tool_check` FAILs its activities.

`guard.sh` stays a shell script. It changes paths only: `tools/<tool>/`,
`identity.yaml`, and `custom-tools/<cap>/`.

## Validator (Standard 3.0)

- `standard` must be `"3.0"`.
- `hosts/` replaces `adapters/` in the structure checks:
  - the same three files;
  - the same maximum line count;
  - each must point at `AGENT.md`.
- A top-level `adapters/` directory, or any `capabilities/<cap>/adapters/`,
  is a FAIL naming the 3.0 location.
- `capabilities/<cap>/` needs at least one tool in `tools/`. Each tool
  passes `tool_check.py`.
- The hook reference copies now include `tool_check.py`.
- `skills/add-tool/SKILL.md` is required when `agent.yaml` lists
  capabilities, byte-identical to the template.
- The 2.1 activity, manifest, runtime and release-rule checks are
  unchanged.

## The `add-tool` skill

`_template/skills/add-tool/SKILL.md` is copied exactly into every agent,
e.g. `/sales-partner:add-tool`. The frontmatter description starts
"Use when adding a tool for one of this agent's capabilities…".

1. **Target.**
   - A folder holding `instance.yaml` with `mode: plugin` for this agent
     is **instance** → `custom-tools/<cap>/`.
   - The agent's own package (holding its `agent.yaml`) is **package** →
     `capabilities/<cap>/tools/<tool>/`.
   - Anything else: stop and say where to run it.
   - A source-mode instance is its own package copy: treat it as
     **package**.
2. **Capability.** List the agent's capabilities and ask which one. Read
   its contract's operations and invariants.
3. **Tool.** Ask which system it is.
   - Package target: take a kebab-case tool name and refuse one that
     already exists.
   - Instance target: if `custom-tools/<cap>/` already exists, offer to
     replace it.

   Then find this session's tools whose name contains a candidate
   `server_match` after `mcp__`, ignoring case. Confirm the match with the
   user. If there are none, explain how to connect the system in the host
   (the user enters any login there) and stop.
4. **`identity.yaml`.** Write the three keys.
5. **`usage.md`.** For each contract operation, write the exact tool calls,
   field names, filters and views, taken from the connected tool's real
   tool list and schema. The session reads them with read-only calls. Add
   a `## Probe` section of read-only calls, and say what they record in
   `bindings/<cap>.md` (IDs the guard needs, workspace, etc.).
6. **`guard.yaml`.** For each invariant, propose:
   - allow and deny lists;
   - create and update tools;
   - field rules, with `binding_id: required` when the tool writes fields
     by ID.

   List the enforced invariants in `covers`. Tell the user which
   invariants stay instruction-only. If the contract has `no_send`, do not
   continue until it is covered.
7. **Check.** Run `tool_check.py` (with `--custom` for the instance
   target) until it passes. Package target: also run the validator if the
   Agent Builder is available, otherwise say to run it in CI.
8. **Bind (instance target only).**
   - Run the probe calls and write `bindings/<cap>.md` (plain
     `field_<name>: <id>` lines).
   - Set `bind_<cap>: custom` in `instance.yaml`, replacing any earlier
     line.
   - Report each invariant as covered or instruction-only, and whether
     the capability is unattended-safe.
   - If `schedules.yaml` has entries, offer to run the `schedule` skill.
9. **Share (instance target, optional).** Explain that a custom tool
   others could use becomes a shipped tool: run `add-tool` in the agent's
   package repository and open a pull request.

Never write credentials to any file.

**Setup's tools step** keeps these parts: probe shipped tools, the
`no_send` refusal, the unattended-safe report, and the source-mode hook
merge. The custom path becomes one line: "If none fits, run the
`add-tool` skill."

## sales-partner 3.0.0

- `git mv` each `capabilities/*/adapters/<tool>/` to `tools/<tool>/`, and
  rename:
  - `adapter.yaml` to `identity.yaml`;
  - `adapter.md` to `usage.md`.
- Move `adapters/` to `hosts/`.
- Update every reference:
  - contract text;
  - skills (setup, send-digest);
  - `operating-config.md`;
  - evals;
  - tests;
  - the Attio `bootstrap.py` docstring.
- Copy the five hooks and the `schedule`, `setup` and `add-tool` skills
  from the builder.
- `migrations/3.0.0.md`: if the instance has `custom-adapters/`, move
  each `<cap>/` to `custom-tools/<cap>/`, and inside rename
  `adapter.yaml` → `identity.yaml` and `adapter.md` → `usage.md`. Nothing
  else changes for instances.
- CI uses `validate@v3`. Version 3.0.0 in `agent.yaml` and the four host
  manifests.

## Docs

Update each of these for 3.0 in the same PR:
- `STANDARD.md`, with the vocabulary "tool" replacing "adapter";
- the `new-agent` wizard;
- `docs/writing-an-agent.md`;
- `docs/how-it-works.md` (text and diagrams);
- the README (`validate@v3`);
- the catalog README (both agents at 3.0).

## Release order

1. Merge the builder PR.
2. The user creates tag `v3` at the merge. This is a new tag, not a
   force-push.
3. The sales-partner PR (CI on `@v3`) goes green; merge it.
4. Merge the catalog PR.

## Acceptance

1. **Instance migration.** Take a throwaway 3.0 instance (local only):
   - use sales-partner's scheduled-digest configuration with Attio and
     Gmail bound;
   - `schedule_check.py check` PASSes.
2. **Guard.** The real `guard.sh` from sales-partner 3.0 blocks an Attio
   `status: approved` write in that instance.
3. **Custom tool.** Run `add-tool` in instance mode against a real
   connected CRM. HubSpot works if it is connected; otherwise use
   Airtable as `custom`. It must produce a `custom-tools/crm/` that passes
   `tool_check.py --custom`, and the guard must enforce it. Discard it
   afterwards.
4. **Old layout.** The 2.1 sales-partner fails the 3.0 validator with
   messages naming `tools/`, `identity.yaml`, `usage.md` and `hosts/`.

## Review focus

The inputs most likely to bite a user that no task's tests would
otherwise exercise:

1. **A leftover 2.x file next to a new one.** `adapter.yaml` beside
   `identity.yaml`: the checker must FAIL, not silently read one of them.
2. **Custom tool without `guard.yaml` for a `no_send` capability.**
   `add-tool` and `tool_check --custom` must refuse. `guard.sh` must
   still guard any shipped policy.
3. **Instance still on `custom-adapters/` after upgrade.** Today `guard.sh`
   only logs a note and allows the call when a bound tool has no identity
   file. For a custom binding that means unguarded calls, so in 3.0 it
   must fail closed. When `bind_<cap>: custom` has no
   `custom-tools/<cap>/identity.yaml`, `guard.sh` blocks every call. The
   message tells the user to apply the 3.0 migration when
   `custom-adapters/<cap>/` exists, and to run `add-tool` otherwise. The
   schedule gate FAILs the same way.
4. **`add-tool` run outside any instance or package.** It must stop with
   directions, not write files into the current folder.
5. **`server_match` chosen from a connector name with spaces or
   capitals** (e.g. "HubSpot CRM"). The skill must normalize it to the
   lowercase MCP form and confirm that it matches the session's real tool
   names.

## Out of scope

- The HubSpot tool (part 2).
- More than one custom tool per capability.
- A run-time re-gate for scheduled runs.
- Converting schedule times to the user's time zone.
- Compliance work.
