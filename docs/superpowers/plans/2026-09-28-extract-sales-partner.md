# Extract Sales Partner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `sales-partner/` out of `webspenser/agent-builder` into a new public repo `webspenser/sales-partner` (history kept), make it a Standard 1.0 agent at version 0.9.0 with CI, and leave the builder holding no agents.

**Architecture:** `git subtree split` produces a branch whose root is the agent folder; that branch seeds the new repo. New files (manifests, tests, docs, CI, README) are added on top. The builder repo then deletes the agent and repoints its links.

**Tech Stack:** git (subtree split), GitHub CLI (`gh`), bash tests, GitHub Actions, the builder's `bin/validate-agent.sh` and `webspenser/agent-builder/validate@v1`.

**Spec:** `docs/superpowers/specs/2026-09-28-extract-sales-partner-design.md` (in the builder repo)

## Global Constraints

- Builder checkout (source): `/Users/hochoy/Work/Webspenser/agent-library` (repo `webspenser/agent-builder`), branch `feat/extract-sales-partner`.
- New repo checkout: `/Users/hochoy/Work/Webspenser/sales-partner` (repo `webspenser/sales-partner`, public, default branch `main`).
- `agent.yaml`: `name: sales-partner`, `version: 0.9.0`, `description: Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM`, `standard: "1.0"`.
- Claude `agents` (exact order): `./subagents/approacher.md`, `./subagents/follow-up.md`, `./subagents/preparer.md`, `./subagents/prospector.md`, `./subagents/sales-call-specialist.md`. Marketplace `owner.name`: `Webspenser`.
- License Apache-2.0. "Template repository" enabled on the new repo.
- No agent file content changes beyond what this plan names; the agent's `AGENT.md`, skills, contracts, context, evals stay byte-identical.
- Validation: `/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh <path>` must print `OK:` with no `WARN:`.
- Tests capture command output before grepping (scripts run under `set -uo pipefail`). Test scripts are 100755.
- Commits end with: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **History actually carried** — `git log -- AGENT.md` in the new repo shows the builder-era commits, not one initial commit. Pinned in Task 1.
2. **Content test still pointed at real files** — with `SP=.` every assertion must read an existing file; a wrong prefix passes nothing and fails everything, or (worse) an `assert_not_contains` on a missing file silently passes. Pinned in Task 3 with a sanity check that every path the test reads exists.
3. **CI bump check on PRs only** — pushes to `main` must not require a bump; PRs must. Pinned in Task 4 by the throwaway PR.
4. **Dangling links** — relative links in moved docs that pointed at builder-only specs must become absolute URLs, and builder docs must not keep relative links to moved files. Pinned in Tasks 3 and 5 with a link check.
5. **Builder left with no agent references** — besides README's link, nothing in the builder (outside `docs/` history files) still names `sales-partner/`. Pinned in Task 5.

---

### Task 1: Create the repo with the agent's history

**Files:** none in the builder tree (creates a branch and a new repo).

- [ ] **Step 1: Split** (in the builder checkout, on `feat/extract-sales-partner`)

```bash
cd /Users/hochoy/Work/Webspenser/agent-library
git subtree split --prefix=sales-partner -b sales-partner-split
git log --oneline sales-partner-split | wc -l
```

Expected: a count greater than 1.

- [ ] **Step 2: Create the GitHub repo and push the split as `main`**

```bash
gh repo create webspenser/sales-partner --public \
  --description "Interviews a business, then runs a five-stage lead pipeline over a CRM — an Agent Standard agent"
git push https://github.com/webspenser/sales-partner.git sales-partner-split:main
```

- [ ] **Step 3: Clone it**

```bash
git clone https://github.com/webspenser/sales-partner.git /Users/hochoy/Work/Webspenser/sales-partner
cd /Users/hochoy/Work/Webspenser/sales-partner
ls; git log --oneline -- AGENT.md | head -5
```

Expected: `AGENT.md`, `skills/`, `subagents/` … at the root; several commits in the log.

- [ ] **Step 4: Confirm it is a pre-1.0 agent (baseline)**

Run: `/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .`
Expected: `WARN: . has no agent.yaml — checked as pre-1.0` and `OK: . conforms`.

- [ ] **Step 5: Clean up the split branch in the builder**

```bash
git -C /Users/hochoy/Work/Webspenser/agent-library branch -D sales-partner-split
```

No commit in this task (the pushed history is the deliverable).

---

### Task 2: Standard 1.0 manifests and license

**Repo:** `/Users/hochoy/Work/Webspenser/sales-partner`
**Files:** Create `agent.yaml`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`, `.codex-plugin/plugin.json`, `LICENSE`.

- [ ] **Step 1: Failing check** — `touch agent.yaml` then run the validator.
Run: `/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .`
Expected: FAIL lines (missing keys, missing manifests). Remove nothing yet.

- [ ] **Step 2: Write the files**

`agent.yaml`:

```yaml
name: sales-partner
version: 0.9.0
description: Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM
standard: "1.0"
```

`.claude-plugin/plugin.json`:

```json
{
  "name": "sales-partner",
  "version": "0.9.0",
  "description": "Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM",
  "author": { "name": "Webspenser" },
  "repository": "https://github.com/webspenser/sales-partner",
  "license": "Apache-2.0",
  "agents": [
    "./subagents/approacher.md",
    "./subagents/follow-up.md",
    "./subagents/preparer.md",
    "./subagents/prospector.md",
    "./subagents/sales-call-specialist.md"
  ]
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "sales-partner",
  "owner": { "name": "Webspenser" },
  "plugins": [
    { "name": "sales-partner", "source": "./", "description": "Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM" }
  ]
}
```

`gemini-extension.json`:

```json
{
  "name": "sales-partner",
  "version": "0.9.0",
  "description": "Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM",
  "contextFileName": "AGENT.md"
}
```

`.codex-plugin/plugin.json`:

```json
{
  "name": "sales-partner",
  "version": "0.9.0",
  "description": "Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM",
  "skills": "./skills/",
  "license": "Apache-2.0"
}
```

License: `gh api licenses/apache-2.0 --jq .body > LICENSE`

- [ ] **Step 3: Validate**
Run: `/Users/hochoy/Work/Webspenser/agent-library/bin/validate-agent.sh .`
Expected: `OK: . conforms`, no `WARN:` line.

- [ ] **Step 4: Commit and push**

```bash
git add agent.yaml .claude-plugin .codex-plugin gemini-extension.json LICENSE
git commit -m "feat: Agent Standard 1.0 manifests, version 0.9.0; Apache-2.0"
git push origin main
```

---

### Task 3: Tests, moved docs, README

**Repo:** `/Users/hochoy/Work/Webspenser/sales-partner`
**Files:** Create `tests/lib.sh` (copy), `tests/test-content.sh` (moved), `tests/run-all.sh`, `README.md`, and the three docs under `docs/superpowers/`.

- [ ] **Step 1: Bring the files over**

```bash
B=/Users/hochoy/Work/Webspenser/agent-library
mkdir -p tests docs/superpowers/specs docs/superpowers/plans
cp "$B/tests/lib.sh" tests/lib.sh
cp "$B/tests/test-sales-partner-content.sh" tests/test-content.sh
cp "$B/docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md" docs/superpowers/specs/
cp "$B/docs/superpowers/specs/2026-09-24-sales-partner-generalize-prospecting-design.md" docs/superpowers/specs/
cp "$B/docs/superpowers/plans/2026-09-24-sales-partner-generalize-prospecting.md" docs/superpowers/plans/
chmod 755 tests/test-content.sh
```

- [ ] **Step 2: Point the content test at the repo root**

In `tests/test-content.sh`: change the header comment's first line to `# Content checks for this agent: keys and rules that must stay consistent`, and change `SP=sales-partner` to `SP=.`. The `digest_schedule` sweep (`find "$SP" -name '*.md'`) must now skip the repo's non-agent files, because the moved design docs mention the retired key on purpose — change it to `find "$SP" -name '*.md' -not -path './docs/*' -not -path './tests/*' -not -path './.git/*' -not -name README.md`. Any assertion that names a builder-only path (for example a builder spec) and fails must be pointed at the moved copy under `docs/superpowers/` — record each such change in the report.

- [ ] **Step 3: Add the path sanity check (Review Focus 2)** — insert right after `SP=.`:

```bash
# Every file this suite reads must exist, or its assertions are meaningless.
missing=0
while IFS= read -r p; do
  f="${p/\$SP/$SP}"
  [ -e "$f" ] || { echo "  FAIL missing file referenced by tests: $f"; missing=1; }
done < <(grep -oE '"\$SP/[^"]+"' "$0" | tr -d '"' | sort -u)
[ "$missing" -eq 0 ] && _report ok "all referenced files exist" || _report no "referenced files missing"
```

- [ ] **Step 4: `tests/run-all.sh`** (executable)

```bash
#!/usr/bin/env bash
# Runs this agent's tests. Structure is checked by the builder's validator
# (CI: webspenser/agent-builder/validate@v1).
set -uo pipefail
cd "$(dirname "$0")/.."
STATUS=0
echo "== content"; tests/test-content.sh || STATUS=1
[ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit "$STATUS"
```

- [ ] **Step 5: Run, expect pass**
Run: `chmod 755 tests/run-all.sh && tests/run-all.sh`
Expected: `ALL GREEN`, including `ok   all referenced files exist`.

- [ ] **Step 6: Fix links in the moved docs (Review Focus 4)**
In the three moved docs, a relative link to a document that did not move (e.g. `./2026-09-01-portable-agent-spec-design.md`, `./2026-09-27-agent-distribution-architecture-design.md`) becomes `https://github.com/webspenser/agent-builder/blob/main/docs/superpowers/specs/<file>`. Links among the three moved docs stay relative. Then check:

```bash
grep -oE '\]\(\./[^)]+\)' docs/superpowers/specs/*.md docs/superpowers/plans/*.md | while IFS=: read -r src link; do
  t="$(dirname "$src")/${link#](./}"; t="${t%)}"; [ -e "$t" ] || echo "DANGLING: $src -> $link"
done
```

Expected: no `DANGLING` lines.

- [ ] **Step 7: `README.md`**

```markdown
# Sales Partner

A sales partner for one business. It interviews you to learn your
business and your ideal customer, then runs a five-stage lead pipeline —
prospect, research, approach, sales call, follow-up — over your CRM. It
researches on its own but never contacts anyone: every outbound
message, email, LinkedIn note, or call opener is a draft you approve.

Built on the [Agent Standard](https://github.com/webspenser/agent-builder/blob/main/STANDARD.md)
with [Agent Builder](https://github.com/webspenser/agent-builder).
Version 0.9.0.

## Use it today (source mode)

1. Click **Use this template** on GitHub to create your own private
   copy — not a fork, so your data and changes stay in your repo.
2. Clone it and open Claude Code (or another host) in the folder.
   Run `./install.sh` once to wire the host files.
3. The agent starts with its interview and fills `context/` with your
   business profile, ideal customer, and operating settings. Commit
   those files to your repo.

Plugin installs — the agent's logic from a catalog, your data in your
own folder — arrive with instance mode in version 1.0.0.

## Tools it needs

- A CRM. Today: Airtable, through `context/crm-airtable-adapter.md`;
  more adapters come later.
- Apify for scraping, web search, and Gmail in draft-only mode.

Connect these in your host (connectors or MCP servers). Credentials
never go in this repo.

## Scheduling

`context/operating-config.md` declares when each activity runs
(`schedules`); your host fires them — see "Running on a schedule" in that
file.

## Developing

    tests/run-all.sh                                   # content checks
    /path/to/agent-builder/bin/validate-agent.sh .     # structure

CI runs both on every push and pull request. Every pull request bumps
`version` in `agent.yaml` and the four host manifests.

## License

Apache-2.0.
```

- [ ] **Step 8: Commit and push**

```bash
git add tests docs README.md
git commit -m "feat: content tests, moved design docs, README"
git push origin main
```

---

### Task 4: CI and repository settings

**Repo:** `/Users/hochoy/Work/Webspenser/sales-partner`
**Files:** Create `.github/workflows/validate.yml`.

- [ ] **Step 1: Workflow**

```yaml
name: validate
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Agent Standard (release rule on pull requests)
        if: github.event_name == 'pull_request'
        uses: webspenser/agent-builder/validate@v1
        with:
          path: .
          require-bump-against: origin/${{ github.base_ref }}
      - name: Agent Standard
        if: github.event_name != 'pull_request'
        uses: webspenser/agent-builder/validate@v1
        with:
          path: .
      - name: Content tests
        run: tests/run-all.sh
```

- [ ] **Step 2: Commit, push, watch the run**

```bash
mkdir -p .github/workflows   # file from Step 1
git add .github/workflows/validate.yml
git commit -m "ci: validate against the Agent Standard and run content tests"
git push origin main
gh run watch --repo webspenser/sales-partner --exit-status "$(gh run list --repo webspenser/sales-partner --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: the run succeeds. If it fails, read `gh run view --log-failed` and fix before continuing.

- [ ] **Step 3: Template repository**

```bash
gh api -X PATCH repos/webspenser/sales-partner -F is_template=true --jq .is_template
```

Expected: `true`.

- [ ] **Step 4: Prove the release rule (Review Focus 3)** — a throwaway PR

```bash
git switch -c ci-bump-probe
echo "" >> README.md && git commit -qam "probe: change without bump"
git push -u origin ci-bump-probe
gh pr create --repo webspenser/sales-partner --title "CI probe (do not merge)" --body "Checks the release rule."
```

Watch the PR's run: it must fail on the release rule. Then bump and push:

```bash
for f in agent.yaml .claude-plugin/plugin.json gemini-extension.json .codex-plugin/plugin.json; do
  sed -i.bak 's/0\.9\.0/0.9.1/' "$f" && rm "$f.bak"
done
git commit -qam "probe: bump" && git push
```

Watch again: it must pass. Record both run URLs in the report, then:

```bash
gh pr close ci-bump-probe --repo webspenser/sales-partner --delete-branch
git switch main && git branch -D ci-bump-probe
```

---

### Task 5: Remove the agent from the builder

**Repo:** `/Users/hochoy/Work/Webspenser/agent-library`, branch `feat/extract-sales-partner`
**Files:** Delete `sales-partner/`, `tests/test-sales-partner-content.sh`, the three moved docs. Modify `tests/run-all.sh`, `README.md`, builder docs that link to moved files.

- [ ] **Step 1: Failing check (Review Focus 5)**

Run: `grep -rn "sales-partner/" --exclude-dir=.git --exclude-dir=docs --exclude-dir=.claude --exclude-dir=.superpowers . || echo none`
Expected now: many hits (the folder, run-all, README).

- [ ] **Step 2: Delete and edit**

```bash
git rm -rq sales-partner tests/test-sales-partner-content.sh \
  docs/superpowers/specs/2026-09-01-sales-partner-agent-design.md \
  docs/superpowers/specs/2026-09-24-sales-partner-generalize-prospecting-design.md \
  docs/superpowers/plans/2026-09-24-sales-partner-generalize-prospecting.md
```

- `tests/run-all.sh`: delete the line `echo "== sales-partner content"; tests/test-sales-partner-content.sh || STATUS=1`.
- `README.md`: delete the table row ``| `sales-partner/` | The first agent; moving to its own repo |`` and add before `## Developing the builder`:

```markdown
## Agents built with this

- [Sales Partner](https://github.com/webspenser/sales-partner) — interviews a business, then runs a five-stage lead pipeline over a CRM.
```

- Builder docs linking to a moved file (`docs/superpowers/specs/2026-09-01-portable-agent-spec-design.md`, `docs/superpowers/plans/2026-09-01-agent-library-bootstrap.md`, and any other hit of `grep -rln "sales-partner-agent-design\|generalize-prospecting" docs`): replace relative links with `https://github.com/webspenser/sales-partner/blob/main/docs/superpowers/<specs|plans>/<file>`. Leave plain-text mentions of history as they are.

- [ ] **Step 3: Checks pass**

```bash
tests/run-all.sh | tail -1
grep -rn "sales-partner/" --exclude-dir=.git --exclude-dir=docs --exclude-dir=.claude --exclude-dir=.superpowers . || echo none
grep -oE '\]\(\./[^)]+\)' docs/superpowers/specs/*.md docs/superpowers/plans/*.md | while IFS=: read -r src link; do
  t="$(dirname "$src")/${link#](./}"; t="${t%)}"; [ -e "$t" ] || echo "DANGLING: $src -> $link"
done
```

Expected: `ALL GREEN`; `none` (README uses a full URL, so `sales-partner/` with a slash does not appear); no `DANGLING` lines. Confirm `tests/run-all.sh` is still 100755 (`git ls-files -s tests/`).

- [ ] **Step 4: Commit and push the branch**

```bash
git add -A
git commit -m "refactor: sales-partner now lives in webspenser/sales-partner"
git push origin feat/extract-sales-partner
```

(The controller opens and merges the PR after the final review.)
