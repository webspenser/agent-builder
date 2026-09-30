# [Agent Name]

Read `AGENT.md` in this directory. It is the full specification —
identity, rules, workflow, guardrails. Follow it exactly.

Skills: read `skills/<name>/SKILL.md` when its trigger matches.

Sub-agents: `subagents/*.md` are role contracts. Dispatch each through
the Agent tool using the definitions in `.claude/agents/`.
