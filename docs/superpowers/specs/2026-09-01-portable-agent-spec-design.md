# Portable Agent Specification Format — Design

**Date:** 2026-09-01
**Status:** Approved (scaffold); agent-specific content pending
**Location:** `/Users/hochoy/Work/Webspenser/agent-library/`

## Purpose

Define a directory format that holds a complete agent specification —
identity, skills, sub-agent roles, templates, and reference material —
in a single provider-neutral source of truth that Claude Code, Gemini
CLI, Codex, Cursor, and comparable hosts can all load without
duplication.

The format must also survive leaving this repository: a specification
directory can be copied elsewhere or handed to a client and still work.

## Scope

This document specifies the **container format and conventions**, plus
a reusable `_template/` skeleton. It does not specify the behavior of
any particular agent. The first concrete agent is designed separately
and will be built by copying `_template/`.

`<agent-name>` throughout is a schema variable filled in per agent, not
an unresolved decision.

Agents get their own spec files alongside this one. The first is
[Sales Partner](https://github.com/webspenser/sales-partner/blob/main/docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Portability mechanism | Neutral core + thin adapters | One file on disk per fact; drift is structurally impossible; no build step |
| Deliverable | Template plus first agent | Every later agent becomes copy-and-fill |
| Sub-agent representation | Provider-neutral role contracts, Claude adapter on top | Hosts without dispatch run the same contract inline |
| Runtime coupling | Self-contained, portable out of repo | Folder can be copied or handed to a client |
| Skill file format | Anthropic `SKILL.md` frontmatter | Only widely adopted convention; degrades to plain markdown everywhere |

Rejected: generated per-provider trees (adds a build step that will be
forgotten), duplicated trees (guaranteed drift), specification-only
document (never runs natively anywhere).

## Directory Layout

```
agent-library/
  README.md                 # what this folder is, how to use a spec
  CONVENTIONS.md            # the portable-agent standard, one page
  _template/                # empty skeleton, copy to start an agent
  <agent-name>/
    AGENT.md                # single source of truth
    install.sh              # links adapters into host-expected locations
    adapters/
      CLAUDE.md             # pointer file, no behavior
      GEMINI.md             # pointer file, no behavior
      AGENTS.md             # pointer file, no behavior (Codex, Cursor, Amp, Copilot)
    skills/
      <skill-name>/
        SKILL.md            # frontmatter + procedure
        references/         # optional deep-dive files, loaded on demand
    subagents/
      <role-name>.md        # role contract
    templates/              # blank fill-in artifacts the agent PRODUCES
    samples/                # filled-in gold-standard examples
    context/                # inputs the agent CONSUMES
    evals/
      cases.md              # given-X-expect-Y checks
```

`templates/`, `samples/`, and `context/` stay separate on purpose.
Models copy structure from templates and voice from samples; merging
them causes placeholder text to appear in output. Keeping `context/`
apart prevents reference material from being emitted as a deliverable.

## File Contracts

### `AGENT.md`

Fixed headings, in this order, so every agent parses identically:

- `Identity` — who the agent is, in two or three sentences
- `Mission` — the outcome it exists to produce
- `Inputs` — what it needs before it can start
- `Outputs` — what it produces, with the exact artifact shapes
- `Operating rules` — how it works, numbered
- `Workflow` — ordered steps, each tagged with its required capability tier
- `Sub-agents` — table: role, when to use, where the contract lives
- `Skills` — table: skill, trigger condition
- `Guardrails / never do` — hard prohibitions
- `Escalate to human when` — explicit stop-and-ask conditions

### `skills/<name>/SKILL.md`

```
---
name: kebab-case-name
description: Use when <trigger condition> — <what it does>
---
```

Body: numbered procedure, one worked example, known failure modes.
Deep material goes in `references/` and is read on demand rather than
inlined, keeping the always-loaded surface small.

### `subagents/<role>.md`

Provider-neutral role contract with these sections:

- `Purpose`
- `Trigger`
- `Inputs` — exact
- `Outputs` — exact shape
- `Tools allowed`
- `Stop conditions`
- `Handoff` — which role or step consumes the output
- `Inline fallback` — how to run this contract as a sequential phase
  when the host has no sub-agent dispatch

### `evals/cases.md`

Five to ten cases in `given <input> → expect <observable behavior>`
form. This is the only artifact that reveals when a prompt edit broke
existing behavior.

## Portability

### Adapters

Adapter files are pointers and carry no behavior. Any rule placed in an
adapter causes provider divergence, which is the failure the format
exists to prevent.

```markdown
<!-- adapters/GEMINI.md -->
# <Agent Name>

Read `AGENT.md` in this directory. It is the full specification —
identity, rules, workflow, guardrails. Follow it exactly.

Skills: read `skills/<name>/SKILL.md` when its trigger matches.
Sub-agents: `subagents/*.md` are role contracts. This host has no
dispatch — run each contract inline as a sequential phase.
```

`adapters/CLAUDE.md` is identical except for the sub-agent line, which
points at native dispatch through `.claude/agents/`.

### `install.sh`

Symlinks adapters into the locations each host looks for. Symlink is
the default because it keeps exactly one copy of every fact on disk.
`--copy` produces independent copies and is reserved for handing the
folder to a client or for hosts that refuse to follow links.

| Host | Looks for | Action |
|---|---|---|
| Claude Code | `CLAUDE.md`, `.claude/skills/`, `.claude/agents/` | link all three |
| Gemini CLI | `GEMINI.md` | link one |
| Codex, Cursor, Amp, Copilot | `AGENTS.md` | link one |
| Other | — | point the operator at `AGENT.md` |

### Capability Tiers

Each workflow step in `AGENT.md` declares the tier it needs:

1. **Full** — sub-agent dispatch plus skill autoloading (Claude Code)
2. **Reduced** — no dispatch; sub-agent contracts run inline as phases,
   skills loaded manually by name
3. **Minimum** — single context; `AGENT.md` alone, skills pasted in

**Constraint:** no step on the critical path may require tier 1. Tier 1
buys parallelism and context isolation, never correctness.

## Testing

The format is verified, not unit-tested:

1. `install.sh` runs clean in an empty directory and produces working
   links for all three host families.
2. `install.sh --copy` produces a directory that functions with the
   original moved away.
3. The agent's `evals/cases.md` passes under Claude Code (tier 1) and
   under at least one tier 2 host, confirming graceful degradation.

## Out of Scope

- Behavior, domain, and tooling of the first concrete agent
- Any runtime, orchestration service, or hosted execution
- Versioning or distribution of specification directories beyond
  copying the folder
