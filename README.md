# Agent Builder

Build your own AI agent on the **Webspenser Agent Standard** — a guided
wizard, a template, and a validator, packaged as a plugin.

An agent here is a folder of plain markdown: one `AGENT.md` that
defines who it is and how it works, skills for its repeated
procedures, optional sub-agent roles, the context it needs about your
world, and evals that say what it must never do. The same folder runs
on Claude Code, Gemini CLI, and Codex.

## Install

**Claude Code** (supported)

    /plugin marketplace add webspenser/agent-builder
    /plugin install agent-builder@agent-builder

**Gemini CLI** and **Codex** — manifests ship, not yet verified:

    gemini extensions install https://github.com/webspenser/agent-builder

## Build an agent

Open your host in the folder where the agent should live and run:

    /agent-builder:new-agent

It interviews you one question at a time — purpose, name, personal or
distributable, then the agent section by section — writes the files as
it goes, and finishes when the validator passes. Personal agents are
for you alone; distributable agents are ones others install.

## Validate

    /agent-builder:validate-agent            # inside the host
    bin/validate-agent.sh path/to/agent      # from a clone of this repo

In CI, from any agent repo:

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- uses: webspenser/agent-builder/validate@v1
  with:
    path: .
    require-bump-against: origin/main   # optional: enforce version bumps
```

## What's here

| Path | What it is |
|---|---|
| `STANDARD.md` | The Agent Standard 1.0 |
| `_template/` | The skeleton every agent starts from |
| `skills/` | `new-agent` (the wizard) and `validate-agent` |
| `bin/validate-agent.sh` | The validator |
| `validate/` | The GitHub Action |
| `docs/writing-an-agent.md` | How to write a good agent by hand |
| `sales-partner/` | The first agent; moving to its own repo |

## Developing the builder

    tests/run-all.sh     # must end ALL GREEN before any commit

## License

Apache-2.0.
