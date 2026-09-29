---
name: setup
description: Use when setting this agent up in a folder for the first time — creates the instance (instance.yaml, host files, your context) and runs the interview.
---

Creates an instance: the folder that holds your data for this agent.
The agent's logic stays in its package; nothing here is written there.
Read this agent's name, version, and optional `catalog` /
`catalog_repo` from `agent.yaml` in the package folder.

Plugin mode is the default (steps below as written).

**Source mode** (the agent's own folder holds its logic — a personal
agent or a "Use this template" copy): use the package folder itself
(no subfolder proposal); write `instance.yaml` with `mode: source`;
skip step 3's host files if `CLAUDE.md`/`GEMINI.md`/`AGENTS.md`
already point at `AGENT.md` (they do after `install.sh`), otherwise
write "Read `AGENT.md` in this folder."; skip step 5 (settings) and
step 6's copy — `context/` is already here; still run the interview.

1. **Folder.** If the current folder is empty (dot files aside), use it.
   Otherwise propose `./<agent name>/` and confirm. If an
   `instance.yaml` for this agent already exists there, stop and offer
   to re-run only the interview. If an `instance.yaml` for a
   different agent exists there, stop and ask — never overwrite it.
2. **Marker.** Write `instance.yaml`:
   `agent: <name>`, `agent_version: <version>`, `standard: "1.1"`,
   `mode: plugin`.
3. **Host files.** Write `CLAUDE.md`, `GEMINI.md`, and `AGENTS.md`, each:
   "This folder is an instance of <name>. Its instructions load from the
   <name> plugin; if they didn't, run the `start` skill." Do not
   overwrite an existing file — append the line instead, only if the
   file doesn't already contain it.
4. **.gitignore.** Create or extend it with: `.env`, `.env.*`,
   `**/credentials.json`, `**/*.key`, `.DS_Store`.
5. **Host settings.** If `catalog` and `catalog_repo` are set, create or
   merge `.claude/settings.json` so it contains
   `extraKnownMarketplaces.<catalog>` = `{"source": {"source": "github",
   "repo": "<catalog_repo>"}}` and `enabledPlugins."<name>@<catalog>"` =
   `true`. Keep every existing key; never replace the file.
6. **Context.** Copy each file in the package's `context/` into the
   instance's `context/` (skip any that already exist), then run the
   `<interview-skill>` skill to fill them with the user.
7. **Version control.** Offer `git init` and a first commit, in a
   private repository. Remind the user that credentials belong in the
   host (connectors, MCP settings, environment variables), never in
   these files.

Never invent the user's facts; what they don't supply stays as the
package's bracketed prompt.
