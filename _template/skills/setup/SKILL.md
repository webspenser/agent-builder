---
name: setup
description: Use when setting this agent up in a folder for the first time — creates the instance (instance.yaml, host files, your context) and runs the interview, if the agent has one.
---

Creates an instance: the folder that holds your data for this agent.
The agent's logic stays in its package. In plugin mode nothing is
written into the package. Read this agent's name, version, and
optional `catalog` / `catalog_repo` from `agent.yaml` in the package
folder.

**Welcome.** Before step 1, tell the user: "You'll connect each system
this agent uses to your host (Claude, Gemini, Codex …). Some systems need
fields created: you can create them yourself from a list, or run a script
with an API key in your own terminal."

1. **Existing instance.** First, before anything else: if this folder
   or any folder above it holds an `instance.yaml` for this agent,
   stop — offer to re-run the interview, the tools step (step 9), or
   both there. (This covers source mode too.)
2. **Mode.** Use source mode when the user or the new-agent wizard
   asks for it, or when the current folder holds this agent's
   `AGENT.md` and `agent.yaml` (you are inside the package itself).
   Otherwise use plugin mode, the default. In plugin mode never write
   inside the package folder (`${CLAUDE_PLUGIN_ROOT}` on Claude Code);
   if the chosen folder is inside it, ask for another location.

**Source mode** (the agent's own folder holds its logic — a personal
agent or a "Use this template" copy): use the package folder itself
(no subfolder proposal); write `instance.yaml` with `mode: source`;
skip step 5's host files if `CLAUDE.md`/`GEMINI.md`/`AGENTS.md`
already point at `AGENT.md` (they do after `install.sh`), otherwise
write "Read `AGENT.md` in this folder."; skip step 7 (settings), except
what step 9 writes, and skip step 8's copy — `context/` is already
here; still create `context/samples/` and run the `<interview-skill>`
skill, if this agent has one.

3. **Folder.** If the current folder is empty (dot files aside), use it.
   Otherwise propose `./<agent name>/` and confirm. If an
   `instance.yaml` for this agent already exists there, stop and offer
   to re-run the interview or the tools step. If an `instance.yaml` for
   a different agent exists there, stop and ask — never overwrite it.
   Every later step writes into this folder (the instance folder),
   not the current folder.
4. **Marker.** Write `instance.yaml`:
   `agent: <name>`, `mode: plugin`.
5. **Host files.** Write `CLAUDE.md`, `GEMINI.md`, and `AGENTS.md`, each:
   "This folder is an instance of <name>. Its instructions load from the
   <name> plugin; if they didn't, run the `start` skill." Do not
   overwrite an existing file — append the line instead, only if the
   file doesn't already contain it.
6. **.gitignore.** Create or extend it with: `.env`, `.env.*`,
   `**/credentials.json`, `**/*.key`, `.DS_Store`.
7. **Host settings.** If `catalog` and `catalog_repo` are set, create or
   merge `.claude/settings.json` so it contains
   `extraKnownMarketplaces.<catalog>` = `{"source": {"source": "github",
   "repo": "<catalog_repo>"}}` and `enabledPlugins."<name>@<catalog>"` =
   `true`. Keep every existing key; never replace the file.
8. **Context.** In the instance folder (the subfolder, if step 3
   created one), copy only the context files the interview fills from
   the package's `context/` into the instance's `context/`, skipping
   any that already exist: <context-files>. Other files in the
   package's `context/` stay in the package and are read from there.
   Create `context/samples/` in the instance: the user's own examples
   go there (the package's `samples/` holds only the examples the
   agent ships with). Then run the `<interview-skill>` skill, if this
   agent has one, to fill the copied files with the user. The interview
   also writes `schedules.yaml` at the instance root (timezone and
   `schedule_*` lines) when the agent declares activities.
9. **Tools.** Skip if `agent.yaml` lists no `capabilities`. For each
   capability listed there:
   1. List the shipped tools (`capabilities/<capability>/tools/`
      in the package) and ask which system the user uses. If none
      fits, run the `add-tool` skill for this capability. In plugin mode
      it binds the tool itself; continue with the next capability. In
      source mode it adds the tool to this copy of the package; continue
      at sub-step 2 with that new tool.
   2. Find the tools in this session whose name contains the tool's
      `server_match` after `mcp__`, ignoring case. If there are none,
      explain how to connect that system in the host (a connector or
      an MCP server), and that the user enters any key or login there
      themselves; leave the capability unbound and go on.
   3. Run the tool's `usage.md` `## Probe` calls. They only read. If they
      fail because fields or objects are missing and the tool's `usage.md`
      has a `## Setup` section, offer two choices:
      - **Create them yourself.** Show the `## Setup` list (each field with
        its object, type, and options) as plain steps in that system. When
        the user says it is done, run the probe again.
      - **Use an API key.** Only when the tool has a `bootstrap.py`. Show the
        exact command, `python3 <package>/capabilities/<capability>/tools/<tool>/bootstrap.py`,
        and the environment variable and key scopes from `## Setup`. Tell the
        user to run it in **their own terminal**, setting the key first with
        `read -rs <VAR> && export <VAR>` (it prompts without echoing and
        writes nothing to shell history), and never to paste the key into
        this conversation or any file. When they say it is done, run the
        probe again.

      Any other probe failure: say what failed and leave the capability
      unbound. Bind only after the probe passes. Write what the probe found
      to `bindings/<capability>.md` in the instance, including any
      `field_<name>: <id>` lines the probe records. Write each as a plain
      line, `field_<name>: <ID>`, with nothing else on it: no bullet, no
      backticks or quotes, no trailing note. Anything else blocks the
      guarded call.
   4. If the contract has a `no_send` invariant and the tool's
      `guard.yaml` does not list it in `covers`, refuse to bind it and
      say why. If the tool leaves an invariant uncovered that the
      contract marks `(acceptable)`, explain in plain words what the
      guard will not enforce and what could happen, and add it to
      `accept_instruction_only:` in `instance.yaml` only after the user
      agrees. Never add an invariant the contract does not mark.
   5. Add `bind_<capability>: <provider>` (or `custom`) to
      `instance.yaml`, replacing an earlier line for that capability.
   6. Source mode only: merge into `.claude/settings.json` a
      `PreToolUse` hook with matcher `mcp__.*` and command
      `"$CLAUDE_PROJECT_DIR/hooks/guard.sh"`, unless one is there
      already. Keep every existing key.
   7. Tell the user, for each capability, each contract invariant and
      whether the tool's guard policy covers it. A capability is
      **unattended-safe** when every invariant is covered. Scheduled
      runs may use only unattended-safe capabilities.
   8. If the agent declares activities (`activity_*` in `agent.yaml`)
      and the interview wrote `schedule_*` lines to `schedules.yaml`,
      offer to run the `schedule` skill next.
10. **Version control.** Offer `git init` and a first commit, in a
   private repository. Remind the user that credentials belong in the
   host (connectors, MCP settings, environment variables), never in
   these files.
11. **Open.** If step 3 created a subfolder, tell the user: "Open your
   host in <folder> — the agent loads there." The CRM and email guards
   apply only in sessions opened in the instance folder, so the user
   should open the host there before running the agent.

Never invent the user's facts; what they don't supply stays as the
package's bracketed prompt.
