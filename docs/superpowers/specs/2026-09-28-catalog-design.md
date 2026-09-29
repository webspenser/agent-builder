# Catalog — Design (sub-project 6)

**Date:** 2026-09-28
**Status:** Approved in conversation, pending spec review
**Implements:** sub-project 6 of [Agent Distribution Architecture](./2026-09-27-agent-distribution-architecture-design.md)
**Repo:** new public `webspenser/agent-library`

## Purpose

One place to find and install everything Webspenser publishes. A user
adds the catalog once and installs any listed plugin by name.

    /plugin marketplace add webspenser/agent-library
    /plugin install agent-builder@webspenser
    /plugin install sales-partner@webspenser

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Marketplace name | `webspenser` | Users type it after `@`; the brand reads better than the repo name |
| Hosts | Claude marketplace only; Gemini listed as install-by-URL, unverified; Codex later | Codex marketplace format untested here |
| Entry sources | Each plugin sourced from its own GitHub repo, default branch | Agent releases (version bumps) reach users with no catalog change |
| Visibility / license | Public, Apache-2.0 | Umbrella decisions |
| Private catalog | Not now | No private agents yet |

## Repo contents

```
agent-library/
  .claude-plugin/marketplace.json
  README.md
  LICENSE
  tests/check-catalog.py
  .github/workflows/check.yml
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "webspenser",
  "owner": { "name": "Webspenser" },
  "plugins": [
    {
      "name": "agent-builder",
      "source": { "source": "github", "repo": "webspenser/agent-builder" },
      "description": "Build your own AI agent on the Webspenser Agent Standard — a guided wizard, a template, and a validator."
    },
    {
      "name": "sales-partner",
      "source": { "source": "github", "repo": "webspenser/sales-partner" },
      "description": "Interviews a business, then runs a five-stage lead pipeline — prospect, research, approach, sales call, follow-up — over a CRM"
    }
  ]
}
```

`tests/check-catalog.py` (Python standard library, network read-only):

- The file is valid JSON; `name` is `webspenser`; `owner.name` is set.
- Every entry has a kebab-case `name`, a non-empty `description`, and a
  `source` of `{"source": "github", "repo": "<owner>/<repo>"}`.
- Names are unique.
- For each entry, `https://raw.githubusercontent.com/<repo>/HEAD/.claude-plugin/plugin.json`
  exists, parses, and its `name` equals the entry's `name`.
- Prints one `FAIL:` line per problem; exits 0 only when there are none.

`.github/workflows/check.yml`: on push to `main`, pull requests, and a
weekly schedule (to catch a listed repo that disappears or renames its
plugin), run `python3 tests/check-catalog.py`.

`README.md`: what the catalog is; the install lines above; a table of
plugins (name, what it does, repo link, status — sales-partner notes
"source mode today; plugin install becomes useful with 1.0.0"); Gemini
install-by-URL lines marked unverified; "Adding a plugin" — the plugin
passes `webspenser/agent-builder/validate@v1`, then one entry in
`marketplace.json` and one README row, in a pull request.

## Builder repo updates

- `README.md` Install: the catalog becomes the primary Claude route
  (`/plugin marketplace add webspenser/agent-library`, then
  `/plugin install agent-builder@webspenser`); the direct route stays as
  an alternative.
- `skills/new-agent/SKILL.md` step 9 (distributable): "list it in a
  catalog" names `webspenser/agent-library` as Webspenser's catalog.
- Builder version bumps to `1.0.1` in its three versioned manifests
  (`.claude-plugin/plugin.json`, `gemini-extension.json`,
  `.codex-plugin/plugin.json`) (release rule).

## Verification

- `python3 tests/check-catalog.py` passes locally and in CI; it fails
  when an entry's repo is misspelled (checked once locally, not
  committed).
- From GitHub, not a local path: `claude plugin marketplace add
  webspenser/agent-library`; `claude plugin install agent-builder@webspenser`
  and `sales-partner@webspenser` succeed; `claude plugin details` shows
  the builder's two skills and sales-partner's skills and five agents;
  then both are uninstalled and the marketplace removed.

## Out of scope

- Codex and Gemini marketplace files; a private catalog; listing
  third-party agents.
