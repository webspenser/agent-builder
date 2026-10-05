# Writing an agent

What the `new-agent` wizard does, for anyone building by hand. The
rules are in `STANDARD.md`; this is the craft.

1. **One job.** An agent that "helps with everything" helps with
   nothing measurable. Name the one outcome in Mission.
2. **Identity as a role.** Write it as a job a person could hold —
   "a sales partner for one business" — not a description of software.
3. **Context is the user's world, not yours.** Every fact about the
   user lives in `context/`, written by an interview. Ship those files
   as bracketed prompts. Nothing in `AGENT.md` or a skill should be
   specific to one user.
4. **Rules about how, not what.** Operating rules describe how the
   agent works (read state before acting; cite a source for every
   claim). Facts belong in context.
5. **Skills for repeated procedures.** If the agent does it more than
   once, it's a skill: a trigger ("Use when…"), numbered steps, one
   worked example, and the ways it goes wrong.
6. **Sub-agents only for isolation.** A step earns a sub-agent when its
   work should not see the rest of the conversation. Every contract
   also runs inline on hosts without dispatch — write it that way.
7. **Guardrails as mechanisms.** A rule the agent can break is a
   request. Where a guarantee matters (never send, never delete), make
   the tool unable to do it rather than asking the model not to.
8. **Evals are refusals.** "Writes good emails" can't be checked.
   "Never drafts to an opted-out contact" can. Write at least three.
9. **Validate before you commit.** `bin/validate-agent.sh <folder>`
   must print `OK`.
10. **Version every release.** Bump `version` in `agent.yaml` and all
    four host manifests together.
11. **Your data lives in an instance.** Write `context/` paths as if
    they are the user's folder — the entry hook and `setup` make that
    true. Package paths are read-only in plugin mode; operator examples
    go in `context/samples/`.

## Tools

When the agent works through an outside system (a CRM, a mailbox),
describe it as a capability in two layers.

- The **contract** (`capabilities/<name>/contract.md`) lists the
  operations the agent thinks in and the invariants any system must
  uphold, such as `no_send`.
- A **tool** (one folder per system, `capabilities/<name>/tools/<tool>/`)
  maps each operation to that system's MCP tools. Its `usage.md` is
  the mapping the model reads, its `identity.yaml` is what the hooks
  read, and its `guard.yaml` is a guard policy: it names the
  tools the agent may call, the values it may write, and which
  invariants that enforces.

Skills name operations, not a system's own calls, so they work on any
system that has a tool folder. The `add-tool` skill (shipped in every
agent) writes and checks a tool folder, for a client's own system or
for a new one in the package.

A guard policy is a short file:

```yaml
covers: [no_send]
allow: [create_draft, list_drafts, get_draft, search_threads, get_thread]
deny: ["*send*", "*reply*", "*forward*"]
```

An invariant in `covers` is enforced by the guard before every call. One
left out is held only by the agent's instructions. A capability is
unattended-safe when every invariant is covered, and a `no_send`
invariant must always be covered. With `allow` present, every other tool
of that system is blocked, so a new tool stays blocked until you allow
it. Field rules can also limit the values a write may set: `writes`
entries say which tools create or update data (`kind`, `tools`) and
where the value maps sit in the call (`at`). If a tool needs fields
created in the system, its `usage.md` has a `## Setup` section listing
them; the section is required when the tool has a `bootstrap.py`, and
setup offers to create the fields by hand or with an API key in the
user's own terminal. Check a
tool folder with `python3 hooks/tool_check.py <tool folder> <contract.md>`.

If any capability has a `no_send` invariant, also ship a `guard.yaml` at
the package root: an agent guard policy with `covers: [no_send]` and a
`deny` list of send and publish globs (`*send*`, `*reply*`,
`*forward*`, `*publish*`, …). The guard applies it to every MCP call in
an instance, whatever the server. Check each glob against the read
tools of the connectors your users will have, so no read is denied.

Mark an invariant `(acceptable)` only when no guard can check it by
design (it depends on state in another system); an instance may then
accept it as instruction-only. If a system has no MCP server, wrap it in
an n8n workflow (`wrapper: n8n` and a `workflow.n8n.json`, see "Wrapped
tools" in the Agent Standard), and deny n8n's dispatcher tools in the
root `guard.yaml`.

The user binds each capability to their own system in `instance.yaml`
(`bind_crm: attio`) during setup. `STANDARD.md` has the details.

## Schedules

Some steps can run with nobody at the keyboard, such as a weekly
prospecting run. Declare each one in `agent.yaml` as
`activity_<name>: <capabilities or none>` and write its instructions so
it runs to its stop conditions under the scheduled prompt: no
questions, no edits to instance files, work recorded in connected
systems only, and a clear stop-and-report when an input is missing.

The user's schedule lives in the instance's `schedules.yaml`
(`timezone` and `schedule_<activity>` lines), written by the interview.
The `schedule` skill, shipped in the template, checks that every
capability an activity uses is covered by guard policies, then tells the
user what to create as Claude cloud routines and verifies the result.
Routines get the agent from a cloud environment's setup script, so the
user updates that script's version comment whenever the agent changes.

