---
name: start
description: Use when this agent's instructions did not load at the start of a session, or the user asks to start the agent — loads AGENT.md by hand.
---

1. Read `AGENT.md` from this agent's package folder
   (`${CLAUDE_PLUGIN_ROOT}/AGENT.md` on Claude Code; on other hosts, the
   `AGENT.md` beside this `skills/` folder).
2. Find the instance: the nearest folder at or above the current one
   holding an `instance.yaml` whose `agent` is this agent. If there is
   none, say so and offer the `setup` skill.
3. Follow `AGENT.md` from here on. `context/` means the instance's
   `context/`; `templates/`, `samples/`, `skills/`, `subagents/`, and
   `migrations/` mean the package's. Write only into the instance.
