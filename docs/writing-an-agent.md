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
- An **adapter** (one folder per system) maps each operation to that
  system's tools. Its `guard.yaml` is a guard policy: it names the
  tools the agent may call, the values it may write, and which
  invariants that enforces.

Skills name operations, not tools, so they work on any system that has
an adapter.

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
it. Field rules can also limit the values a write may set. Check a
policy with `python3 hooks/guard_policy.py --check guard.yaml`.

The user binds each capability to their own system in `instance.yaml`
(`bind_crm: attio`) during setup. `STANDARD.md` has the details.
