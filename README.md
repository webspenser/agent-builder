![Webspenser Agent Builder — defines the Agent Standard: contracts, tools, guards and scheduled activities, with a validator](assets/banner.png)

# Agent Builder

**AI agents that take real work off your plate, and that you can trust
to run on their own.**

An agent is a helper that does a repeating job in your business: finding
leads, keeping your CRM up to date, preparing reports. Agent Builder is
how Webspenser builds them, and how you can build your own. Every agent
built here follows the **Webspenser Agent Standard**, which means:

- **It works in the tools you already use.** Your CRM, your mailbox, your
  spreadsheets. Nothing to migrate.
- **It has rules it can't break.** Each agent spells out what it must
  never do (send an email, delete a record, contact someone who said
  no), and those rules are checked on every action, not just written in
  its instructions.
- **It only runs on its own when that's safe.** An agent can work on a
  schedule only when every rule it depends on is enforced. If one isn't,
  it waits for you.
- **Your data stays yours.** Your business details live in your own
  private folder, your records stay in your own systems, and passwords
  never go into the agent.
- **You can see what it does.** Everything it knows and every instruction
  it follows is plain text you can read and change.

**Want an agent built for your business?** [Webspenser](https://www.webspenser.com/lp/agent-builder)
designs, builds and sets up agents like these for small businesses, and
can run them for you as part of our AI managed services.

## For builders

Build your own AI agent on the **Webspenser Agent Standard** — a guided
wizard, a template, and a validator, packaged as a plugin.

An agent here is a folder of plain markdown: one `AGENT.md` that
defines who it is and how it works, skills for its repeated
procedures, optional sub-agent roles, the context it needs about your
world, and evals that say what it must never do. The same folder runs
on Claude Code, Gemini CLI, and Codex. Agents can declare tools
(capabilities) that users bind to their own CRM or mailbox, with guard
policies that enforce the agent's safety rules before every call. An
agent's activities can also run on a schedule, unattended, as Claude
cloud routines, but only when guard policies cover every rule they
depend on.

## Install

**Claude Code** (supported) — from the Webspenser catalog:

    /plugin marketplace add webspenser/agent-library
    /plugin install agent-builder@webspenser

or straight from this repo:

    /plugin marketplace add webspenser/agent-builder
    /plugin install agent-builder@agent-builder

**Gemini CLI** and **Codex** — manifests ship, not yet verified:

    gemini extensions install https://github.com/webspenser/agent-builder
    codex plugin marketplace add webspenser/agent-builder   # unverified

## Build an agent

Open your host in the folder where the agent should live and run:

    /agent-builder:new-agent

By default it creates the agent in a new `./<name>` folder there; it
asks before using any other place.

It interviews you one question at a time — purpose, name, personal or
distributable, then the agent section by section — writes the files as
it goes, and finishes when the validator passes. Personal agents are
for you alone; distributable agents are ones others install.

## Instances

Installed agents keep your data in your own folder, not in the agent.
Run `/<agent>:setup` in an empty folder; opening your host there loads
the agent.

## Validate

    /agent-builder:validate-agent            # inside the host
    bin/validate-agent.sh path/to/agent      # from a clone of this repo

In CI, from any agent repo:

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- uses: webspenser/agent-builder/validate@main
  with:
    path: .
    require-bump-against: origin/main   # optional: enforce version bumps
```

`@main` tracks the current standard while it is in development.

## What's here

| Path | What it is |
|---|---|
| `STANDARD.md` | The Agent Standard |
| `_template/` | The skeleton every agent starts from |
| `skills/` | `new-agent` (the wizard) and `validate-agent` |
| `bin/validate-agent.sh` | The validator |
| `validate/` | The GitHub Action |
| `docs/writing-an-agent.md` | How to write a good agent by hand |
| `docs/how-it-works.md` | Product overview: repositories, vocabulary, and every check (CI, runtime guard, scheduling), with diagrams |

## Agents built with this

- [Sales Partner](https://github.com/webspenser/sales-partner) — fresh, researched leads every week, each with its first touch ready for you to approve. It never sends.

## Developing the builder

    tests/run-all.sh     # must end ALL GREEN before any commit

## License

Apache-2.0.
