---
name: start
description: Use when this agent's instructions did not load at the start of a session, or the user asks to start the agent — loads AGENT.md by hand.
---

1. Read `AGENT.md` from this agent's package folder
   (`${CLAUDE_PLUGIN_ROOT}/AGENT.md` on Claude Code; on other hosts, the
   `AGENT.md` beside this `skills/` folder). Read all of it.
2. Find the instance: the nearest `instance.yaml` at or above the
   current folder. If there is none, or it names another agent, there
   is no instance here — say so and offer the `setup` skill. An
   instance with `mode: source` normally loads `AGENT.md` through its
   own host files (`CLAUDE.md`, `GEMINI.md`, `AGENTS.md`), and the
   session-start hook stays silent there; this skill still works.
3. If the instance's `agent_version` is older than the package's
   `version` (compare the dot-separated fields as numbers; a
   non-numeric field counts as different), follow `migrations/` as the
   session-start hook would: show the diff, confirm with the user,
   then update `agent_version`. If `migrations/` has no note covering
   this change, just update `agent_version`. If the instance is newer,
   change nothing.
4. Follow `AGENT.md` from here on. `context/` means the instance's
   `context/`, except package-owned context files that `AGENT.md`
   says are read from the package; the user's own examples are in the
   instance's `context/samples/`. `templates/`, `samples/` (the
   examples the agent ships with), `skills/`, `subagents/`, and
   `migrations/` mean the package's. Write only into the instance.
