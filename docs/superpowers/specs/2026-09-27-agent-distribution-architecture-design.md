# Agent Distribution Architecture — Design

**Date:** 2026-09-27
**Status:** Approved in conversation, pending spec review
**Amends:** [Portable Agent Specification Format](./2026-09-01-portable-agent-spec-design.md) — reopens its out-of-scope items "any runtime … or hosted execution" and "distribution … beyond copying the folder"
**Scope:** umbrella architecture. Each sub-project below gets its own spec and plan when it starts.

## Purpose

Turn the agent library from one repository that holds a standard and
its agents into a small ecosystem:

- a **builder** anyone can install to create their own agent following
  Webspenser's standard,
- **agents** Webspenser publishes (sales-partner first), each in its own
  repository, installable on Claude Code, Gemini CLI, and Codex,
- **instances** — each user's own working copy of an agent, holding
  their data and connections, which they own and version themselves.

The standard stays what it is today: one neutral source of truth per
agent, thin host adapters, plain markdown, no build step.

## Audiences

| Audience | What they want | How they consume an agent |
|---|---|---|
| Business users and Webspenser clients | An agent that works without touching its internals | Install from a catalog, run `setup` in an empty folder |
| Developers | To read, change, and own an agent's logic | Create their own repo from the agent repo ("Use this template") |
| Contributors | To improve a shared agent | Fork and send a pull request |
| Anyone building a new agent | A guided path from idea to working agent | Install the builder, run the `new-agent` wizard |

Webspenser also sets agents up for clients as a service (white-glove);
see Access below.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Repository split | Builder, each agent, and each instance live in separate repos | Independent versioning; one repo is one installable package on every host |
| Package artifact | The agent repo itself, plus static host manifests | No build step, no second copy to drift |
| Instance location | A folder the user owns — its own repo, or a subfolder of a workspace repo | User data and commits never touch the publisher's repo |
| Plugin-mode customization | Context, bindings, and custom adapters only — never skills or logic | Updates stay safe; anyone who needs to change logic uses source mode |
| Tools | Neutral capability contracts in the package; adapters per provider; bindings in the instance | "Create a record" is the same act on Attio, HubSpot, or Airtable |
| Credentials | Only in the host (connectors, MCP config, plugin secure settings, environment, CI secrets) | Never in any repo |
| First runtime | Claude Code routines on the instance repo | Least to operate for clients |
| Host-neutral runtime | GitHub Actions running a headless CLI on the instance repo | No Webspenser server to run; later sub-project |
| Wizard | A skill inside the host (`new-agent`) | Works on every host; no extra software |
| Licensing | Builder and standard: Apache-2.0. Each agent: chosen per repo | Open-source posture; client data never lives in published repos |
| Private agents | A private catalog repo alongside the public one | Same packaging; visibility controlled by GitHub access |

Rejected: a standalone installer CLI (code to maintain; bypasses each
host's update path); Claude-only plugins (drops agent-agnostic);
copying the whole agent per client (improvements never reach existing
clients); skill overrides in instances (updates become unsafe).

## The three layers

| Layer | Repo | Holds | Never holds |
|---|---|---|---|
| **Builder** | `webspenser/agent-library` | The versioned standard, `_template/`, the `new-agent` wizard, the validator, best-practice docs | Agents, user data |
| **Package** | One per agent, e.g. `webspenser/sales-partner` | `agent.yaml`, `AGENT.md`, skills, sub-agent contracts, templates, samples, capability contracts, shipped adapters, blank `context/` defaults, host manifests | Any user's filled context, credentials |
| **Instance** | One per user and agent — its own repo, or a subfolder of the user's workspace repo | `instance.yaml`, filled `context/`, custom adapters, host pointer files and settings, optional schedule workflow | Agent logic (plugin mode), credentials |

In **personal mode** (a one-person agent built with the builder, such as
a training coach) package and instance are the same folder.

## Three ways to consume an agent

1. **Plugin mode** — the user adds a catalog, installs the agent, opens
   the host in any folder, and runs the agent's `setup` skill. Logic
   stays in the host's plugin cache and updates through the host
   (`/plugin update`, `gemini extensions update`, Codex equivalent).
   Setup writes only into the user's folder.
2. **Source mode** — the user creates their own repo from the agent
   repo with GitHub's "Use this template" (no upstream link, so their
   commits and PRs cannot land on the publisher's repo). Package and
   instance are one folder; the agent fills `context/` in place.
3. **Contributor mode** — a normal fork and pull request against the
   agent repo.

The agent behaves identically in plugin and source mode because of the
instance rules below.

## Layer contracts

### Instance marker

A folder is an instance if and only if it contains `instance.yaml`.
The agent's working context is always the nearest instance folder.

```yaml
# instance.yaml
agent: sales-partner
agent_version: 1.3.0          # version setup ran with; drives migrations
standard: "1.0"
mode: plugin                  # plugin | source
bindings:
  crm:          { adapter: attio }                    # shipped adapter
  scraper:      { adapter: apify }
  email_drafts: { adapter: gmail }
  # a custom adapter lives in the instance:
  # crm:        { adapter: ./adapters/crm-monday.md }
enforcement:                  # written by setup, per capability and invariant
  email_drafts: { no_send: host-deny }
  crm:          { draft_only: adapter, dnc_one_way: adapter, no_delete: host-deny }
```

### Context resolution

The agent reads `context/<file>` from the instance. If the instance does
not have that file, it reads the package's blank default and treats the
file as not yet set up — it runs the relevant setup or interview step
rather than acting on a blank.

### Write rule

Setup, interviews, and every skill write only into the instance. In
plugin mode nothing ever writes into the package. In source mode the
package folder *is* the instance, so the rule holds trivially.

### Host wiring written by setup

- `CLAUDE.md`, `GEMINI.md`, `AGENTS.md` pointer files that name the
  agent and point at its entry instructions (exact mechanism per host is
  spike S1/S2).
- `.claude/settings.json`: the catalog under `extraKnownMarketplaces`,
  the agent under `enabledPlugins` (so cloud sessions and routines load
  it), and `permissions.deny` rules from the enforcement step.
- A `.gitignore` covering anything a host writes locally.

### No build step

Everything remains plain markdown, YAML, and static JSON manifests.
Source mode needs nothing but a clone.

## Capabilities, adapters, bindings

The sales-partner's `context/crm-contract.md` and
`crm-airtable-adapter.md` already follow this split; the standard makes
it general.

- **Capability contract** (package): the neutral operations the agent
  thinks in, their arguments, and the invariants each must uphold —
  e.g. `crm` (the eleven operations), `scraper`, `web_research`,
  `email_drafts`. Skills and sub-agents call contract operations, never
  a provider's tools by name.
- **Adapter** (package, or instance for custom ones): one markdown file
  mapping every operation of one contract onto one provider's tools, and
  declaring for each invariant how it is enforced: `adapter` (the
  mapped tool cannot violate it), `host-deny` (setup writes a host deny
  rule for the violating tool), or `instruction` (the model is told
  not to).
- **Binding** (instance): which adapter serves each capability, in
  `instance.yaml`.
- **Credentials** (host only): connectors, MCP server config, plugin
  secure settings (`userConfig`), environment variables, CI secrets.

### Setup walk-through for tools

1. List the capabilities the agent declares in `agent.yaml`.
2. For each, ask which system the user uses. A shipped adapter is bound
   directly. Otherwise setup interviews the user and writes a custom
   adapter covering every operation of the contract; the validator
   checks coverage.
3. Probe each binding with a harmless read (whoami, list one record).
   If it fails, guide the user to connect the tool in the host; the
   user enters secrets there themselves.
4. Record bindings and enforcement in `instance.yaml`; write deny rules
   for every `host-deny` invariant.
5. Refuse to bind an adapter that cannot uphold the agent's no-send
   guarantee by `adapter` or `host-deny`.

## Unattended runs

A schedule runs with no approval prompts. An instance may schedule an
activity only if every capability that activity uses has each of its
invariants enforced by `adapter` or `host-deny` — none by
`instruction`. Setup refuses to create the schedule otherwise and says
which invariant blocks it.

## Updates and migrations

`instance.yaml` records the agent version setup ran with. Every agent
release that changes the shape of a context file ships a migration
note in the package (`migrations/<from>-<to>.md`: what changed, how to
convert). On the first run after an update, the agent notices the
version gap, shows the proposed change to the instance's files as a
diff, and applies it only after the user confirms; then it updates
`agent_version`.

## The standard and the builder

### Versioned standard

`CONVENTIONS.md` becomes the **Agent Standard**, versioned with semantic
versioning: minor for optional additions, major when an agent must
change to conform. The first versioned release is **1.0** and includes
`agent.yaml`, capability contracts and adapters, and the instance rules
in this document. The unversioned `CONVENTIONS.md` is pre-1.0.

### Agent manifest

```yaml
# agent.yaml
name: sales-partner
version: 1.3.0
description: Interviews a business, then runs a five-stage lead pipeline over a CRM
standard: "1.0"
capabilities: [crm, scraper, web_research, email_drafts]
adapters:
  crm: [airtable, attio, hubspot]
  scraper: [apify]
  email_drafts: [gmail]
```

Host manifests — `.claude-plugin/plugin.json`, `gemini-extension.json`,
`.codex-plugin/plugin.json` — are static and repeat name, version, and
description; the validator fails when any of the four disagree.

### Builder plugin

Installable on all three hosts from `webspenser/agent-library`:

- `new-agent` — the wizard. Asks what the agent is for, chooses
  personal or distributable mode, walks the template (identity and
  mission, context, capabilities, skills, sub-agent contracts, evals),
  writes `agent.yaml` and the host manifests, and runs the validator.
- `validate-agent` — runs the validator on any agent folder: structure,
  headings, frontmatter, manifest agreement, adapter coverage of each
  contract.
- `_template/` and best-practice docs (the standard, writing a
  capability contract, writing an adapter).
- A GitHub Action, `webspenser/agent-library/validate@v1`, so any agent
  repo can run the validator in CI.

Later: `upgrade-agent`, once a standard 2.0 exists.

## Catalogs

- **Public catalog** — a small repo (`webspenser/agents`) holding the
  Claude and Codex marketplace files that list the builder and every
  public agent, each sourced from its own repo. Gemini users install
  each repo by URL; the catalog's README lists them.
- **Private catalog** — the same shape in a private repo for
  client-specific agents; hosts use the user's own git access.

## Access for white-glove setup

The client owns the instance repo and every account and connector.
Webspenser is added as a collaborator on the instance repo only. Setup
runs with the client present so the client connects accounts and enters
secrets; Webspenser never holds client credentials.

## Host support

| Host | Plugin mode | Source mode | Scheduled runs |
|---|---|---|---|
| Claude Code | Supported | Supported | Routines (sub-project 5); GitHub Actions later |
| Gemini CLI | Supported | Supported | GitHub Actions only (later) |
| Codex | Supported | Supported | GitHub Actions only (later) |
| Others | — | Best effort via `AGENTS.md` | — |

Tests cover the supported hosts' manifests only.

## Sub-projects, in order

| # | Sub-project | Inputs | Outputs |
|---|---|---|---|
| 0 | **Spikes** (below) | This spec | Written findings; any design change they force goes back into this spec |
| 1 | **Builder** | Spikes; current `CONVENTIONS.md`, `_template/`, validator | Standard 1.0; `agent.yaml` schema; validator checks for manifests and adapter coverage; builder plugin on three hosts; `new-agent`, `validate-agent`; the validate Action |
| 2 | **Extract sales-partner** | PR #1 merged; builder | `webspenser/sales-partner` with history (`git subtree split`), `agent.yaml`, host manifests, blank `context/`, passes the validator |
| 3 | **Instance** | Sub-projects 1–2 | `instance.yaml` schema in the standard; context-resolution and write rules in the standard and in sales-partner; `setup` skill (interview, pointer files, settings); migration mechanism |
| 4 | **Tools and credentials** | Sub-project 3 | Capability-contract and adapter format in the standard; sales-partner contracts for `scraper`, `web_research`, `email_drafts`; Attio and HubSpot CRM adapters; setup's binding walk-through, probes, enforcement declarations, deny rules |
| 5 | **Runtime** | Sub-project 4 | `schedules` wired to Claude routines on the instance repo; the unattended-run rule enforced by setup; later, a GitHub Actions runner for all hosts |
| 6 | **Catalogs** | Sub-project 2 | Public `webspenser/agents` and a private catalog; install docs |

Sub-project 6 can run any time after 2.

## Spikes (sub-project 0)

- **S1 — Claude plugin mode entry point.** Plugins contribute skills,
  agents, hooks, and MCP servers; confirm how an instance folder makes
  Claude load the agent's `AGENT.md` from the plugin (an entry skill, a
  session-start hook, or a pointer resolvable across plugin versions).
- **S2 — Gemini and Codex.** Confirm each installs a whole repo as one
  extension or plugin, discovers `skills/`, and how its context file or
  entry instructions load from an instance folder.
- **S3 — Routines with a plugin.** Confirm a routine on an instance
  repo loads the plugin enabled in the repo's `.claude/settings.json`,
  reaches the bound connectors, and honors `permissions.deny` with no
  approval prompts.

## Risks

- A host changes its plugin format. Mitigation: the manifests are thin,
  static, and covered by the validator; source mode always works.
- An instruction-only guardrail slips through in an interactive run.
  Mitigation: deny rules wherever the host supports them, and the
  unattended-run rule for everything scheduled.
- Agents drift behind the standard. Mitigation: `standard` in
  `agent.yaml`, the validator, and later `upgrade-agent`.

## Out of scope

- Telemetry, a paid or commercial model, Windows support for the bash
  validator, and hosts beyond the three named.
- Any Webspenser-operated server or database.
- Automated dialing, sending, or any action the agents' own guardrails
  forbid.
