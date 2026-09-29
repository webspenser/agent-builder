---
name: new-agent
description: Use when someone wants to create a new agent — interviews them and builds a complete agent folder on the Agent Standard, then validates it.
---

A conversation that turns "I want an agent that…" into a working agent
folder following `STANDARD.md` (in this plugin). Ask one question at a
time. Write each answer to its file before asking the next question, so
an interrupted run resumes by reading what already exists. Never invent
the user's domain facts — anything they haven't supplied stays as a
bracketed prompt.

The template lives at `_template/` in this plugin's root
(`${CLAUDE_PLUGIN_ROOT}/_template` on Claude Code; on other hosts, the
`_template/` folder beside this `skills/` folder). The capability
skeleton is `_capability-template/` in the same root. The validator is
`bin/validate-agent.sh` in the same root.

## Procedure

1. **Purpose.** Ask what job the agent does, for whom, and what a good
   week with it looks like. If the answer is "everything", ask for the
   one job it should do first. Summarize back in two sentences and get
   a yes.
2. **Name and place.** Propose a kebab-case name; ask where to create
   it (default `./<name>`). If the folder exists and has no
   `agent.yaml`, stop and ask. If it has an `agent.yaml` naming this
   agent, it is an interrupted run: read what exists and resume at the
   first unfinished step.
3. **Mode.** Ask: *personal* (only you use it; we fill your details in
   after building) or *distributable* (others install it; your details
   never go in it). Then ask: "Whose name or organization should appear
   as the publisher?" If the user gives none, stop and ask again — never
   fill it from git config, the host account, or a guess.
4. **Scaffold.** Copy the template with
   `cp -R "<template>/." "<target>/"` (the `/.` form also copies the
   hidden `.claude-plugin/` and `.codex-plugin/` folders). Set
   `agent.yaml`: `name`, `version: 0.1.0`, one-sentence `description`,
   `standard: "1.2"`. Set the same name, version, and description in
   `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
   (its `name` and its single entry), `gemini-extension.json`, and
   `.codex-plugin/plugin.json`; set the marketplace `owner.name` to the
   publisher the user named in step 3. Set the title in `AGENT.md` and the
   three `adapters/` files to the agent's display name.
   The template is Agent Standard 1.2: keep `hooks/` exactly as copied
   (the validator checks it byte for byte).
5. **Specification, section by section.** For each, ask, draft,
   confirm, write:
   - Identity and Mission — a role a person could hold; one outcome.
   - Inputs and Outputs — what must exist first; what it produces,
     with the shape of each artifact.
   - Context files — the facts about the user's world the agent needs
     (for a training coach: goals, schedule, current fitness). Write
     each as `context/<name>.md` with bracketed interview prompts, not
     answers.
   - Tools — which outside systems the agent reads or writes (a CRM,
     a mailbox). For each, pick a `snake_case` capability name, copy
     `_capability-template/` (beside `_template/`) to
     `capabilities/<name>/`, write the contract's operations and
     invariants, rename
     `adapters/example-provider/` to the first system's kebab-case
     name and fill its `adapter.md`, `## Probe`, and `adapter.yaml`
     (set `capability` and `provider` to the folder names). List the
     names in `agent.yaml` as `capabilities: a, b`. Skills and
     sub-agents name operations, never a system's tools. If the agent
     must never send messages, give the capability a `no_send`
     invariant and enforce it with `block: send`.
   - Operating rules — numbered, about how it works.
   - Workflow — ordered steps, each tagged T1, T2, or T3; no critical
     step may need T1.
   - Skills — for each repeated procedure: `skills/<name>/SKILL.md`
     with frontmatter `name` and a `description` starting "Use when",
     then a numbered procedure, one worked example, and failure modes.
   - Sub-agents — only where a step benefits from its own isolated
     context; each contract in `subagents/<role>.md` with the eight
     required headings (Purpose, Trigger, Inputs, Outputs, Tools
     allowed, Stop conditions, Handoff, Inline fallback) and
     frontmatter `name` and `description`.
   - Guardrails / never do, and Escalate to human when.
   - Interview — which skill gathers the user's context; replace
     `<interview-skill>` in `skills/setup/SKILL.md` with its name. If
     the agent has no interview skill, delete the `<interview-skill>`
     wording from setup (its step 8 and source mode) instead of
     leaving it. Replace `<context-files>` in setup's step 8 with the
     list of context files the interview fills (for example
     `context/athlete-profile.md`); package-owned context files the
     user never edits stay off that list and are read from the
     package. The user's own examples go in the instance's
     `context/samples/`; `samples/` in the package holds only the
     examples the agent ships with. The validator fails while either
     placeholder is left.
   Fill the Sub-agents and Skills tables in `AGENT.md` to match.
6. **Evals.** Write at least three cases in `evals/cases.md`, each a
   thing the agent must refuse or never do, in the form Given / Expect
   / Why it matters / How to run.
7. **Manifests.** Set `agents` in `.claude-plugin/plugin.json` to list
   every file in `subagents/` as `"./subagents/<role>.md"` (an empty
   list if none).
8. **Validate.** Run `bash <validator> <folder>`. Fix every `FAIL:`
   line and run it again until it prints `OK`.
9. **Finish.**
   - Personal: run the `setup` skill's source mode (writes
     `instance.yaml` with `mode: source` at the agent folder), then
     the interview fills `context/` in place.
   - Distributable: offer `git init` and a first commit; explain
     publishing — push to a GitHub repo, enable "Template repository" in
     its settings so others can copy it without forking, and list it in
     a catalog — Webspenser's is `webspenser/agent-library`; its README
     says how to add a plugin.
   - Catalog: if you publish to one, set both `catalog` and
     `catalog_repo` in `agent.yaml` as two flat keys, or neither.
   - Every later change bumps `version` in `agent.yaml` and all four
     host manifests.

## Worked example (abridged)

User: "I'm training for an Ironman and want something to keep my
training log and tell me what to adjust each week."
- Purpose confirmed: "A training coach that keeps your Ironman log and
  proposes next week's plan every Sunday."
- Name `ironman-coach`, folder `./ironman-coach`, mode personal.
- Context files: `context/athlete-profile.md` (race date, current
  volume, injuries — as prompts), `context/training-log.md`.
- Skills: `log-session`, `weekly-review`. No sub-agents.
- Evals: never prescribes training through a reported injury without
  flagging it; never invents a session that isn't in the log; never
  changes the race date.
- Validator prints `OK: ./ironman-coach conforms`; the user fills
  `athlete-profile.md` by interview.

## Failure modes

- **Writing the user's facts for them.** Race dates, prices, client
  names — only what the user said; everything else stays a prompt.
- **Skipping validation.** The agent is not done until the validator
  prints `OK`.
- **Sub-agents by default.** Add one only when a step needs isolation;
  most personal agents need none.
