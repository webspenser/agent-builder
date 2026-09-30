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
3. Follow `AGENT.md` from here on. `context/` means the instance's
   `context/`, except package-owned context files that `AGENT.md`
   says are read from the package; the user's own examples are in the
   instance's `context/samples/`. `templates/`, `samples/` (the
   examples the agent ships with), `skills/`, and `subagents/` mean the package's. Write only into the instance.
