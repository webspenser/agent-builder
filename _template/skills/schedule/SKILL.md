---
name: schedule
description: Use when setting up, checking, or changing this agent's scheduled runs — turns schedules.yaml into Claude cloud routines that run unattended, only for activities whose capabilities are all covered by guard policies.
---

Scheduled runs happen in Claude cloud routines: each run clones this
instance's GitHub repository, loads the agent from the cloud
environment's setup script, and runs one activity with no one watching.
This skill checks that it is safe, tells the user exactly what to
create, and verifies what they created. It never creates or deletes
routines itself.

The checker is `hooks/schedule_check.py` in the package
(`${CLAUDE_PLUGIN_ROOT}/hooks/schedule_check.py` on Claude Code; in
source mode, `hooks/schedule_check.py` in this folder). Run it with
`python3`. Below, `<checker>` means that command and `<repo>` means the
instance's GitHub repository as `owner/name`.

1. **Instance.** Work in the instance folder (the one holding this
   agent's `instance.yaml`). If `schedules.yaml` is missing or has no
   `schedule_<activity>` line, stop: the interview writes it — offer to
   run the interview's scheduling questions.
2. **Repository.** Run `git remote get-url origin` and `git status
   --porcelain`. The instance folder must be the root of its git
   repository (the guard finds `instance.yaml` by walking up from the
   cloned repository), and `origin` must be on GitHub, with nothing
   uncommitted and nothing unpushed, and with `instance.yaml`,
   `schedules.yaml`, `context/`, and `bindings/` committed (the guard
   needs `bindings/` in the cloud). If not, say exactly what to do
   (create a private GitHub repository, commit, push) and stop until it
   is done. Take `<repo>` from the remote.
3. **Gate.** Run `<checker> check . --repo <repo>`. Each entry prints
   `PASS` or `FAIL`. A `FAIL` names every capability that is unbound or
   whose contract invariants the bound adapter's guard policy does not
   cover: tell the user, and that the fix is to bind an adapter whose
   `guard.yaml` covers them (setup's tools step). Continue only with
   `PASS` entries. Never offer to schedule a failing entry.
4. **Environment.** Show the "Cloud environment setup script" lines the
   checker printed. Tell the user: in claude.ai/code, create (once) or
   open a cloud environment — suggested name `webspenser-agents` — and
   put these lines in its setup script, merged with any other agents'
   lines. Every time this agent is updated, change the version comment
   so the environment reinstalls it. Every routine for this agent uses
   that environment.
5. **Routines.** For each `PASS` entry, give the user the values to
   create one routine at claude.ai/code/routines (New routine → Cloud):
   - name: the entry's routine name, e.g. `sales-partner: prospect (acme-sales)`;
   - repository: `<repo>`;
   - environment: the one from step 4;
   - connectors: attach, for each listed provider, the connector whose
     name contains its `matches` text — no others;
   - schedule: the entry's day and time in the instance's timezone;
     the checker also prints the UTC cron for forms that ask in UTC;
     say that a UTC schedule shifts by an hour when daylight saving
     changes;
   - prompt: the entry's prompt, copied exactly.
6. **Verify.** When the user says a routine is created, find it with
   the routines API (`RemoteTrigger` action `list`, then `get` with its
   id). Write the JSON the API returned to a temporary file outside the
   repository, then run `<checker> verify . <activity> <file> --repo
   <repo>`. Report every `MISMATCH` line and what to change; re-verify
   after the user fixes it. On `OK`, add `routine_<activity>: <id>` to
   `schedules.yaml` and tell the user to commit and push. If the
   routines API is not available, give the user the step 5 values as a
   checklist to compare by hand instead.
7. **Smoke run (optional).** Offer to run a verified routine once now
   (`RemoteTrigger` action `run`). Say first that it does the activity's
   real work in the connected systems. Afterwards read its log
   (`list_runs`, then `get_run_log`) and report: whether the agent's
   entry context loaded (a line starting `# Agent: <name>`), whether
   the plugin's hooks ran, any line starting `Blocked by`, and the
   run's final result. If the agent did not load, the environment's
   setup script is missing or stale — back to step 4.
8. **Changes.** Re-run this skill after changing `schedules.yaml`,
   bindings, or the agent version. It re-checks every entry. It cannot
   delete routines: when an entry was removed or now fails the gate,
   tell the user which routine to disable or delete in the web UI, and
   remove its `routine_<activity>` line.

Never put credentials in any file. Never schedule an entry the checker
failed.
