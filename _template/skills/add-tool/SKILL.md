---
name: add-tool
description: Use when adding a tool for one of this agent's capabilities — a client's own system in their instance (custom-tools/), or a new shipped tool in the agent's package (capabilities/<cap>/tools/) — and checking that it is guarded.
---

A tool connects one capability's contract to one system (a CRM, a
mailbox). This skill writes the tool's files, checks them with
`hooks/tool_check.py`, and, in a client's instance, binds it. Never write
credentials to any file: logins live in the host's connectors.

The checker is `${CLAUDE_PLUGIN_ROOT}/hooks/tool_check.py` on Claude Code
(in source mode, `hooks/tool_check.py` in the package folder). Run it
with `python3`.

1. **Target.** Look for this agent's files, starting in the current folder:
   - A folder holding `instance.yaml` whose `agent:` is this agent and whose
     `mode:` is `plugin`: the target is **instance**. Files go to
     `custom-tools/<cap>/`.
   - The agent's own package (a folder holding this agent's `agent.yaml`),
     or a source-mode instance (it is its own package copy): the target is
     **package**. Files go to `capabilities/<cap>/tools/<tool>/`.
   - Neither: stop. Say that this skill runs inside a set-up instance of
     this agent (run `setup` first) or inside the agent's package
     repository, and write nothing.
2. **Capability.** List the capabilities in `agent.yaml` and ask which one.
   Read `capabilities/<cap>/contract.md` in the package: its Operations
   and its Invariants.
3. **Tool.** Ask which system it is.
   - Package target: ask for a kebab-case tool name (e.g. `hubspot`), and
     refuse `custom` and any name that already exists in
     `capabilities/<cap>/tools/`.
   - Instance target: if `custom-tools/<cap>/` exists, show what is there
     and ask whether to replace it.

   Find this session's tools for that system: MCP tool names look like
   `mcp__<server>__<tool>`. Propose a `server_match`: the lowercase text,
   using only letters, digits, `_` or `-`, that appears after `mcp__` in
   every one of this system's tool names and in no other connector's.
   Never use a display name with spaces or capitals ("HubSpot CRM" → look
   for the tool names' own spelling, e.g. `hubspot`). Show the matching
   tool names and confirm with the user. If the system has no tools in
   this session, explain how to connect it in the host (a connector or an
   MCP server, where the user enters any login themselves), and stop.

   If the system has no MCP server at all, offer to wrap it in n8n (the
   Agent Standard's "Wrapped tools"): an n8n workflow whose MCP Server
   Trigger requires Bearer or Header auth and exposes one snake_case tool
   node per call `usage.md` needs, each a fixed call to the system (never
   a URL or method the caller sets). The system's key goes into an n8n
   credential, never into the agent or the instance. Save the workflow
   export as `workflow.n8n.json` in the tool folder, add `wrapper: n8n` to
   `identity.yaml`, and ask the user to connect the trigger's URL as a
   connector whose name contains `server_match`. Remind them that the
   agent's root `guard.yaml` must deny `*execute_workflow*`,
   `*create_workflow*`, `*update_workflow*`, `*archive_workflow*` and
   `*publish_workflow*`.
4. **`identity.yaml`.** Write three lines: `capability: <cap>`,
   `provider: <tool>` (or `provider: custom` for the instance target),
   and `server_match: <text>`; add `wrapper: n8n` for a wrapped tool.
5. **`usage.md`.** Write how the agent uses this system:
   - For every contract operation, name it in backticks (e.g.
     `` `create_lead` ``) and give the exact tool calls, object and field
     names, filters and views. Take these from the system's real tool list
     and schema, which you read now with read-only calls only.
   - Add a `## Probe` section: the read-only calls setup (or step 8) runs
     when binding, and what they record in `bindings/<cap>.md`, such as
     the workspace and any IDs the guard needs, as plain
     `field_<name>: <id>` lines.
6. **`guard.yaml`.** For each contract invariant, propose how to enforce it
   on this system's tool calls:
   - an `allow` list of the tools `usage.md` uses, and `deny` globs for
     anything destructive;
   - `writes` entries, each with a `kind` (`create` or `update`), the `tools`
     it covers and the argument paths `at` where the value maps sit;
   - field `rules`; when the system writes fields by ID rather than by
     name, add `bound_keys_only: true` and have the probe record every
     field's ID as a `field_<name>: <id>` line;
   - `forbid: update` on any field that must not change after create,
     such as an approved draft's body.

   Put every enforced invariant in `covers`. Tell the user plainly which
   invariants stay instruction-only (not in `covers`), and that a
   capability with any instruction-only invariant cannot run on a
   schedule. If the contract has `no_send`, do not continue until
   `guard.yaml` covers it. The policy format is in the Agent Standard
   ("Guard policy").
7. **Check.** Run `python3 <checker> <tool folder> <package>/capabilities/<cap>/contract.md`
   (add `--custom` for the instance target). Fix every `FAIL` line and run
   it again until it prints `OK`. For the package target, also run the
   Agent Builder's validator if it is installed; otherwise say that CI
   runs it on the pull request.
8. **Bind (instance target only).**
   1. Run the `## Probe` calls. On failure, say what failed and stop.
   2. Write what they found to `bindings/<cap>.md`, as plain lines.
   3. Set `bind_<cap>: custom` in `instance.yaml`, replacing any earlier
      `bind_<cap>:` line.
   4. For each invariant, say whether it is covered or instruction-only,
      and whether the capability is now unattended-safe.
   5. If `schedules.yaml` has `schedule_` lines, offer to run the
      `schedule` skill: bindings changed, so every schedule must be checked
      again.
9. **Share (instance target, optional).** If other businesses could use
   this tool, explain the path: run this skill in the agent's package
   repository (the package target) and open a pull request there.
