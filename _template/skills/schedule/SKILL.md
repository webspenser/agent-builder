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
2. **Repository.** Routines clone the repository's default branch, so
   that branch is what the gate must see. Run:
   - `git remote get-url origin` — must be on GitHub;
   - `git fetch origin`;
   - `git rev-parse --show-toplevel` — must equal the instance folder
     (the guard finds `instance.yaml` by walking up from the cloned
     repository);
   - `git status --porcelain` — must print nothing;
   - `git rev-list --count @{u}..HEAD` and `git rev-list --count
     HEAD..@{u}` — both must print `0` (nothing unpushed, nothing
     unpulled);
   - `git symbolic-ref --short refs/remotes/origin/HEAD` — must print
     `origin/<current branch>`. If that ref is missing, run `git remote
     set-head origin --auto` first, then run it again.

   `instance.yaml`, `schedules.yaml`, `context/`, and `bindings/` must
   be committed (the guard needs `bindings/` in the cloud). If any check
   fails, say exactly what to do (create a private GitHub repository,
   commit, push, pull, or switch to the default branch) and stop until
   it is done. Take `<repo>` from the remote.
3. **Gate.** Run `<checker> check . --repo <repo>`. If it prints
   `ERROR:` and exits 2, show the error and stop (typical causes: the
   timezone, a missing or empty `schedules.yaml`, an agent mismatch,
   control characters). Otherwise each entry prints `PASS` or `FAIL`.
   Report every `- ` problem line under a `FAIL` and fix what it names.
   For an unbound capability or an uncovered invariant, the fix is to
   bind an adapter whose `guard.yaml` covers it (setup's tools step).
   Continue only with `PASS` entries. Never offer to schedule a failing
   entry.
4. **Environment.** Show the "Cloud environment setup script" lines the
   checker printed. Tell the user: in claude.ai/code, create (once) or
   open a cloud environment — suggested name `webspenser-agents` — and
   put these lines in its setup script (stop if any printed install
   line has an empty value), merged with any other agents'
   lines. Every time this agent is updated, change the version comment
   so the environment reinstalls it. Every routine for this agent uses
   that environment.
   In source mode (`mode: source` in `instance.yaml`) the instance
   already carries the agent and its guard as a repository-level hook
   (setup's tools step), so routine runs load both from the cloned
   repository and the setup script needs no plugin install lines for
   this agent; ignore the two install lines the checker prints.
5. **Routines.** For each `PASS` entry, give the user the values to
   create one routine at claude.ai/code/routines (New routine → Cloud):
   - name: the entry's routine name, e.g. `sales-partner: prospect (acme-sales)`;
   - repository: `<repo>`;
   - environment: the one from step 4. Any other environment does not
     load this agent or its guard: the routine would run unguarded;
   - connectors: attach, for each listed provider, the connector whose
     name contains its `matches` text — no others. `verify` refuses any
     extra connector, because nothing guards it;
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
   after the user fixes it. If it reports `schedules.yaml records no
   environment`:
   1. show the user the environment id it names;
   2. ask them to confirm it is the environment from step 4;
   3. on yes, add `environment: <id>` to `schedules.yaml`, then commit
      and push;
   4. re-verify.

   On `OK`, add `routine_<activity>: <id>` to `schedules.yaml` and tell
   the user to commit and push. If the
   routines API is not available, give the user the step 5 values as a
   checklist to compare by hand instead.
7. **Smoke run (optional).** Offer to run a verified routine once now
   (`RemoteTrigger` action `run`). Say first that it does the activity's
   real work in the connected systems. Afterwards read its log
   (`list_runs`, then `get_run_log`) and report: whether the agent's
   entry context loaded, whether the plugin's hooks ran, any line
   starting `Blocked by`, and the run's final result. In plugin mode the
   entry hook prints `# Agent: <name> <version>`; compare the name and
   version with `name` and `version` in the package's `agent.yaml`. If
   the line is missing or either differs, the environment's setup
   script is missing or stale — back to step 4. A source-mode instance
   prints no such line (its agent loads through the repository's own
   `CLAUDE.md`); check instead that the run followed the activity's
   instructions.
8. **Changes.** Re-run this skill after changing `schedules.yaml`,
   bindings, the agent version, or the environment. The gate runs only
   when this skill runs. It re-checks every entry. It cannot delete
   routines: when an entry was removed or now fails the gate, tell the
   user which routine to disable or delete in the web UI, and remove
   its `routine_<activity>` line. The checker fails every
   `routine_<activity>` line left without a `schedule_<activity>` and
   names the routine to disable or delete.

Never put credentials in any file. Never schedule an entry the checker
failed.
