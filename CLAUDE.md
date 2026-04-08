# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A shared GitHub Actions library providing reusable Claude-powered automation. Consumers add a single caller workflow to their repo; this library handles the job logic.

## Linting

Workflow files are linted with `actionlint` on every push and PR via `.github/workflows/lint.yml`. Run locally before pushing:

```bash
brew install actionlint  # macOS
actionlint               # from repo root
```

## Development

This project uses TypeScript + Jest for testable action logic. Node.js 20+ required.

```bash
npm install          # install dependencies
npm test             # run Jest tests
npm run build        # type-check (tsc --noEmit)
npm run build:check  # type-check + verify dist/ is up to date
```

CI runs `test.yml` (npm test) and `build-check.yml` (dist/ staleness) on every push and PR.

## Architecture

Every capability ships in two forms:

| Form | Location | Use when |
|---|---|---|
| Reusable workflow | `.github/workflows/claude-*.yml` | Simplest consumer experience — one `uses:` line |
| Composite action | `<name>/action.yml` | Embed as a step inside a larger job |

The reusable workflows are thin wrappers that delegate to the composite actions (same pattern as `apply-fix.yml` → `./apply-fix`). Logic lives in the composite action; the workflow just provides the trigger context, permissions, and concurrency blocks.

**Why absolute refs, not relative paths:** Reusable workflows reference composite actions via `cbeaulieu-gt/github-actions/<action>@v2` (not `./action`). Relative `./` paths break for external consumers because `actions/checkout@v4` replaces the runner workspace with the consumer's repo — `./tag-claude` then points into the consumer's repo, not this library. Absolute refs let GitHub resolve the action directly from this repo's tree without a local checkout.

**Dogfooding limitation:** GitHub Actions does not support expressions in `uses:` values, so a conditional `@main` vs `@v2` reference is not possible. PRs opened against this repo will test composite actions at the released `@v2` tag, not the local branch's composite action changes. To validate a composite action change before release, test it in an external consumer repo pointing at the branch.

### Actions

- **`pr-review/`** — Reviews PRs via `anthropics/claude-code-action@v1`. On `synchronize` events, diffs only the new commits (`git diff before..after`) and escalates to a full review if foundational code is touched.
- **`tag-claude/`** — Responds to `@claude` mentions. Delegates to `./check-auth` first, then calls `claude-code-action` only if authorized.
- **`check-auth/`** — Authorization primitive. Outputs `authorized=true/false` based on an explicit `authorized_users` allowlist (takes precedence) or `github.event.comment.author_association` (OWNER/MEMBER/COLLABORATOR). Used by `tag-claude/`.
- **`apply-fix/`** — Validates a unified diff against protected paths (rejects anything touching `.github/`), applies it with `git apply`, commits, and pushes to the PR branch.
- **`lint-failure/`** — Diagnoses lint failures on a PR via `anthropics/claude-code-action@v1`. Fetches failed lint logs and PR diff, posts a structured `## Claude Lint Diagnosis` comment, and optionally commits a fix when `auto_apply: true`.

### CI automation workflows

- **`ci-failure.yaml`** — Triggered by `workflow_run` on CI failure. Fetches plain-text logs via `gh run view --log-failed`, writes them to `/tmp/ci_logs.txt`, calls `claude-code-action` to diagnose and optionally auto-apply a fix.
- **`apply-fix.yml`** — `workflow_dispatch` wrapper around `./apply-fix` for manual invocation.
- **`claude-lint-fix.yml`** — `workflow_call`-only wrapper around `./lint-failure`. Consumers add a `notify-claude` job (with `needs: [lint]` and `if: failure()`) to their lint workflow.

## Key conventions

**Permissions must be declared at the workflow level** (not job level) in caller workflows. GitHub ignores job-level permissions when calling reusable workflows. `pull_request` events default to `pull-requests: none` and `contents: read` — both must be explicitly granted.

**Token selection for `claude-code-action`:** Use `github_token: ${{ github.token }}` for read-only operations (PR review, which does not push commits). Use the resolved App token (`${{ steps.token.outputs.value }}`) when `claude-code-action` must push commits — tag responses, lint-diagnose, lint-failure, ci-failure, and apply-fix all pass the App token. GitHub suppresses `synchronize` events for pushes authenticated with `GITHUB_TOKEN`, so an App token is required to re-trigger downstream workflows like `pr-review`. App tokens are short-lived and show a distinct bot identity (e.g., `my-app[bot]`).

**Composite action inputs are always strings** — there is no `type` field. Boolean inputs like `require_association` arrive as the string `'true'`/`'false'` and must be compared with `[ "$VAR" = "true" ]`.

**Authorization step outputs gate downstream steps** — `exit 0` inside a composite action step does not prevent subsequent steps from running. Use a step output (`authorized=true/false` → `$GITHUB_OUTPUT`) and `if: steps.authz.outputs.authorized == 'true'` on each downstream step.

**`shellcheck disable=SC2016`** is required on `run:` blocks that contain `${{ }}` expressions inside single-quoted strings — shellcheck treats these as unintended non-expansion, but GitHub Actions pre-processes them before the shell sees the string.

## Versioning

- `v2.0.0` — pinned tag for reproducible builds
- `v2` — floating tag, always points to latest `v2.x.x`
- `v1.8.0` / `v1` — still available for consumers who have not yet migrated; no further updates

When changes are released: move both `v2` and the new `v2.x.x` tag to the latest main HEAD and force-push both tags. Create a GitHub release against `v2.x.x`.

## Required secrets

| Secret | Used by |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | All `claude-code-action` invocations |
| `APP_ID` | `ci-failure.yaml`, `apply-fix`, `lint-failure` — GitHub App ID for generating short-lived tokens for git push and API calls |
| `APP_PRIVATE_KEY` | Same as above — GitHub App private key (PEM format) |
