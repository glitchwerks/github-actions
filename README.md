# github-actions

Reusable GitHub Actions for Claude-powered automation. This repository provides two actions — one for automated PR reviews and one for responding to `@claude` mentions in comments — built on top of [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).

All actions authenticate using a `CLAUDE_CODE_OAUTH_TOKEN` secret.

## Actions

| Action | Description | Usage pattern |
|---|---|---|
| `pr-review` | Claude reviews a PR for code quality, security, performance, test coverage, and docs | Composite action or reusable workflow |
| `tag-claude` | Claude responds to `@claude` mentions in issue and PR comments | Composite action or reusable workflow |
| `lint-failure` | Claude diagnoses lint failures on a PR and optionally commits a fix | Composite action or reusable workflow |

---

## Permissions Reference

> **Critical:** GitHub ignores `permissions:` declared at the job level when a job calls a reusable workflow (`uses:`). You **must** declare permissions at the **workflow level** (top-level `permissions:` key, outside of `jobs:`). Job-level permissions are silently ignored in this context, which can cause cryptic 403 errors or missing write access at runtime.

The table below shows the minimum required permissions for each consumer workflow file. Copy the exact block shown into the top level of your workflow (after `on:`, before `jobs:`).

| Workflow | Trigger | Required `permissions:` block |
|---|---|---|
| PR Review | `pull_request` | `contents: read`<br>`pull-requests: write` |
| Tag Claude | `issue_comment` + `pull_request_review_comment` | `contents: write`<br>`issues: write`<br>`pull-requests: write` |
| Claude Lint Fix | `pull_request` (via `needs: [lint]`, `if: failure()`) | `contents: write`<br>`pull-requests: write`<br>`actions: read` |
| CI Failure Diagnosis | `workflow_run` | `contents: write`<br>`pull-requests: write` |

---

## Quick Start

The easiest way to consume these actions is via the **reusable workflow** pattern. Add one file to your repo and you're done.

### PR Review

```yaml
# .github/workflows/pr-review.yml
name: PR Review

on:
  pull_request:
    types: [opened, synchronize, reopened]

# Permissions must be declared at workflow level (not job level) when calling
# reusable workflows. pull_request events default to pull-requests: none.
permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    uses: glitchwerks/github-actions/.github/workflows/claude-pr-review.yml@v2
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Optional inputs:

```yaml
    with:
      model: claude-opus-4-5   # default: claude-sonnet-4-5
      max_turns: '20'          # default: 15
```

### Tag Claude

```yaml
# .github/workflows/tag-claude.yml
name: Tag Claude

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

# Permissions must be declared at workflow level when calling reusable workflows.
# contents: write is safe here — issue_comment always runs in the base repo context.
permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  respond:
    uses: glitchwerks/github-actions/.github/workflows/claude-tag-respond.yml@v2
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      app_id: ${{ secrets.APP_ID }}
      app_private_key: ${{ secrets.APP_PRIVATE_KEY }}
```

Optional inputs:

```yaml
    with:
      trigger_phrase: '@bot'         # default: @claude
      require_association: false     # default: true — set false to allow all commenters
      authorized_users: 'alice,bob'  # default: '' — when set, only these users can trigger Claude
```

### Required secrets

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates `claude-code-action` |
| `APP_ID` | (**Required**) GitHub App ID — used to generate a short-lived token for git push and API calls |
| `APP_PRIVATE_KEY` | (**Required**) GitHub App private key (PEM format) |

### Security

By default, only commenters with an `author_association` of `OWNER`, `MEMBER`, or `COLLABORATOR` can trigger Claude. This prevents arbitrary GitHub users from consuming your Claude quota.

| Scenario | Configuration |
|---|---|
| Default — org members and collaborators only | _(no extra config needed)_ |
| Open to all commenters | `require_association: false` |
| Explicit allowlist (overrides association check) | `authorized_users: 'alice,bob'` |

**`require_association`** (boolean, default `true`) — when `true`, only `OWNER`, `MEMBER`, and `COLLABORATOR` associations are allowed. Set to `false` to let anyone trigger Claude regardless of their relationship to the repository.

**`authorized_users`** (string, default `''`) — comma-separated list of GitHub usernames (case-insensitive). When non-empty, _only_ the listed users can trigger Claude and the `require_association` check is skipped entirely.

**Concurrency** — the reusable workflow enforces per-user concurrency automatically. If the same user triggers Claude a second time while a run is already in progress, the in-progress run is cancelled and the new one proceeds. This prevents queued pile-ups from rapid `@claude` mentions. When using the composite action directly, add the equivalent `concurrency` block to your job:

```yaml
jobs:
  respond:
    concurrency:
      group: claude-tag-${{ github.repository }}-${{ github.event.comment.user.login }}
      cancel-in-progress: true
```

---

## Composite Actions

If you need more control (e.g., embed the review step inside a larger job), use the composite actions directly instead of the reusable workflows.

- [`pr-review/`](./pr-review/README.md) — composite action docs and examples
- [`tag-claude/`](./tag-claude/README.md) — composite action docs and examples

---

## Migrating from v1 to v2

### Breaking changes

- **All `uses:` references must change from `@v1` to `@v2`.** Every workflow or composite action call that pins to `@v1` must be updated.
- **`gh_pat` input has been removed.** The deprecated `gh_pat` input is no longer accepted by any action. `app_id` + `app_private_key` are now required for all write-capable actions (`tag-claude`, `lint-failure`, `ci-failure`, `apply-fix`).
- **`tag-claude` no longer falls back to `github.token`.** An App token is mandatory — omitting `app_id` and `app_private_key` will cause the action to fail at the token resolution step.
- **All write-capable actions now post under the GitHub App's bot identity** (e.g., `my-app[bot]`) rather than under `github-actions[bot]` or a PAT's user identity.

### Migration steps

1. Update every `uses: glitchwerks/github-actions/...@v1` line (and `uses: .github/workflows/...@v1`) to `@v2`.
2. If you were passing `gh_pat`, create a GitHub App and add `APP_ID` + `APP_PRIVATE_KEY` as repository secrets. See the GitHub App setup section for instructions.
3. For `tag-claude` consumers: ensure your caller workflow passes `app_id` and `app_private_key` secrets.

### Before and after

**v1 — using the deprecated `gh_pat` input:**

```yaml
jobs:
  respond:
    uses: glitchwerks/github-actions/.github/workflows/claude-tag-respond.yml@v1
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      gh_pat: ${{ secrets.GH_PAT }}
```

**v2 — using App token:**

```yaml
jobs:
  respond:
    uses: glitchwerks/github-actions/.github/workflows/claude-tag-respond.yml@v2
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      app_id: ${{ secrets.APP_ID }}
      app_private_key: ${{ secrets.APP_PRIVATE_KEY }}
```

---

## Versioning

| Ref | Meaning |
|---|---|
| `@v2` | Stable floating tag — points to the latest `v2.x.x` release. Use this in production. |
| `@v2.0.0` | Pinned tag for reproducible builds. |
| `@v1` / `@v1.8.0` | Still available for consumers who have not yet migrated. No further updates. |
| `@main` | Latest development commit. May include breaking changes. |

When a new major version is released (e.g., v3), a new floating tag will be created. The `@v2` tag will continue to point to the last `v2.x.x` release for backwards compatibility.


---

## CI runtime

### CI runtime — base image (Phase 2)

`runtime/base/Dockerfile` produces the shared foundation image consumed by every Claude-powered CI overlay. Built and pushed by `.github/workflows/runtime-build.yml` STAGE 2 to `ghcr.io/glitchwerks/claude-runtime-base`. Smoke-tested by STAGE 4-base as a non-root UID. See `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §3 for architecture and `docs/superpowers/plans/phase-2-base-image.md` for the implementation plan.

### CI runtime — overlay images (Phase 3)

`runtime/overlays/{review,fix,explain}/` produce the three verb-scoped overlay images consumed by Phase 5's reusable workflows. Each overlay is built `FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:<digest>` and adds verb-specific agents/plugins per `runtime/ci-manifest.yaml`. Built and pushed by `.github/workflows/runtime-build.yml` STAGE 3 (parallel matrix; one cell per verb); smoke-tested by STAGE 4-overlay against per-overlay `expected.yaml` inventory contracts. The matcher (`runtime/scripts/inventory-match.sh`) enforces "different eyes" guarantees mechanically — a future edit that imports `code-writer` into review fails the build.

The overlay layer also introduces `overlays.<verb>.subtract_from_shared.plugins`, which removes a base-inherited plugin from a specific overlay at build time (review subtracts `skill-creator` for §10.2 compliance). See spec §4.2 / §5.1 amendments for the relationship to `merge_policy.overrides` (no interaction). Implementation plan: `docs/superpowers/plans/phase-3-overlays.md`.

### CI runtime — reusable workflow wiring (Phase 5)

The Phase 3 overlay images are wired into the consumer-facing reusable workflows via `container: ghcr.io/.../claude-runtime-<verb>@sha256:<digest>` at the job level. Every step in the job — including the embedded `claude-code-action@v1` invocation — runs inside the verb-specific overlay image, which bakes Claude CLI at `$PATH_TO_CLAUDE_CODE_EXECUTABLE` plus the verb's agent set. The interface to consumers is unchanged: a single `uses:` line plus the OAuth secret. See `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §7.5 for workflow → overlay assignments and `docs/superpowers/plans/2026-04-22-ci-claude-runtime.md` "Phase 5" for the implementation plan.

For the `claude-tag-respond.yml` flow, the `route` job invokes `claude-command-router/` (Phase 4) to parse the verb and emits a digest-pinned image URL that the `dispatch` job consumes via `container: ${{ needs.route.outputs.image }}`. Consumers don't see the routing — they just `uses:` the workflow as before.

**Migration note (Phase 5 → Phase 7):** `claude-lint-fix.yml`, `apply-fix.yml`, and `ci-failure.yaml` are kept until Phase 7 cutover. New consumers should reference `claude-lint-failure.yml`, `claude-apply-fix.yml`, and `claude-ci-failure.yml` respectively — all three are container-pinned to the fix overlay.

---

## CI Failure Diagnosis

The `ci-failure` workflow watches for failed runs of a workflow named `CI` and automatically diagnoses the failure using Claude. When confidence is high it can also apply the fix directly to the PR branch — no manual intervention needed.

### How it works

1. The `workflow_run` trigger fires whenever a `CI` workflow completes with a `failure` conclusion.
2. A bash step resolves the PR number from the failing commit SHA.
3. `gh run view --log-failed` fetches plain-text logs for failed steps only (up to 16 000 chars) into `/tmp/ci_logs.txt`.
4. The PR diff is fetched from the GitHub API into `/tmp/pr_diff.json`.
5. `anthropics/claude-code-action@v1` runs Claude, which reads both files, posts a structured diagnosis comment on the PR, and — when `auto_apply` is `true` and confidence is `high` — applies the fix, commits it, and pushes to the PR branch in the same turn.

### Required secrets

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates `claude-code-action` |
| `APP_ID` | GitHub App ID — used to generate a short-lived token for git push and API calls |
| `APP_PRIVATE_KEY` | GitHub App private key |

### GitHub App setup

1. Create a GitHub App (Settings → Developer settings → GitHub Apps → New GitHub App).
2. Grant it **Contents: read and write** and **Pull requests: read and write** permissions.
3. Install the App on your repository.
4. Note the **App ID** from the App's settings page.
5. Generate a **private key** (PEM format) from the App's settings page.
6. Add `APP_ID` and `APP_PRIVATE_KEY` as repository secrets.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `model` | string | `claude-sonnet-4-5` | Claude model to use |
| `max_turns` | string | `15` | Maximum Claude turns per run |
| `auto_apply` | boolean | `true` | When `true`, Claude applies a high-confidence fix automatically |

### Example — reusable workflow

```yaml
# .github/workflows/ci-failure.yml
name: CI Failure Diagnosis

on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]

permissions:
  contents: write
  pull-requests: write

jobs:
  diagnose:
    uses: glitchwerks/github-actions/.github/workflows/ci-failure.yaml@v2
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      app_id: ${{ secrets.APP_ID }}
      app_private_key: ${{ secrets.APP_PRIVATE_KEY }}
```

Optional inputs:

```yaml
    with:
      model: claude-opus-4-5   # default: claude-sonnet-4-5
      max_turns: '20'          # default: 15
      auto_apply: false        # default: true — set false to diagnose only
```

---

## Claude Lint Fix

The `claude-lint-fix` workflow lets consumers drop a single `notify-claude` job into their existing lint workflow. When linting fails on a PR, Claude fetches the failed step logs and the PR diff, posts a structured `## Claude Lint Diagnosis` comment, and — when `auto_apply` is `true` — commits a high-confidence fix directly to the PR branch.

### How it works

1. The consumer's `notify-claude` job depends on their `lint` job (`needs: [lint]`) and runs only on failure (`if: failure()`).
2. `gh run view --log-failed` fetches plain-text logs for failed lint steps only (up to 16 000 chars) into `/tmp/lint_logs.txt`.
3. The PR diff is fetched from the GitHub API into `/tmp/pr_diff.json`.
4. `anthropics/claude-code-action@v1` runs Claude, which reads both files, posts a structured diagnosis comment on the PR, and — when `auto_apply` is `true` and confidence is `high` — applies the fix, commits it, and pushes to the PR branch in the same turn.

### Consumer usage

```yaml
# .github/workflows/lint.yml
name: Lint

on:
  pull_request:
    types: [opened, synchronize, reopened]

# Permissions must be declared at workflow level (not job level) when calling
# reusable workflows. actions: read is required to fetch failed run logs.
permissions:
  contents: write
  pull-requests: write
  actions: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm run lint   # or whatever linter the repo uses

  notify-claude:
    needs: [lint]
    if: failure()
    uses: glitchwerks/github-actions/.github/workflows/claude-lint-fix.yml@v2
    with:
      pr_number: ${{ github.event.pull_request.number }}
      run_id: ${{ github.run_id }}
      # auto_apply: true   # opt-in to auto-fix
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      app_id: ${{ secrets.APP_ID }}
      app_private_key: ${{ secrets.APP_PRIVATE_KEY }}
```

### Required secrets

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates `claude-code-action` |
| `APP_ID` | GitHub App ID — used to generate a short-lived token for git push and API calls |
| `APP_PRIVATE_KEY` | GitHub App private key |

### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `pr_number` | string | yes | — | Pull request number — pass `${{ github.event.pull_request.number }}` |
| `run_id` | string | yes | — | Caller's workflow run ID — pass `${{ github.run_id }}` |
| `model` | string | no | `claude-sonnet-4-5` | Claude model to use |
| `max_turns` | string | no | `10` | Maximum Claude turns per run |
| `auto_apply` | boolean | no | `false` | When `true`, Claude applies a high-confidence fix automatically |

---

## Apply Fix

The `apply-fix` workflow (and its backing composite action at `apply-fix/`) checks out a PR branch, validates a unified diff against protected paths, applies it, commits, and pushes. It is invoked automatically by the CI Failure Diagnosis workflow when `auto_apply` is `true` and confidence is `high`, but can also be triggered manually.

### Required secrets

| Secret | Purpose |
|---|---|
| `APP_ID` | GitHub App ID — used to generate a short-lived token for git push |
| `APP_PRIVATE_KEY` | GitHub App private key |

### Inputs

| Input | Required | Description |
|---|---|---|
| `pr_number` | Yes | The PR number to apply the fix to |
| `fix_diff` | Yes | A unified diff string (output of `git diff` or similar) |
| `fix_description` | Yes | One-line description used as the commit message |

> **Protected paths** — the workflow will fail with a clear error if the diff targets any file under `.github/`. This prevents automated changes to workflow files.

### Example — manual trigger

```yaml
# Trigger via GitHub UI or gh CLI:
gh workflow run apply-fix.yml \
  -f pr_number=42 \
  -f fix_description="Fix missing null check in auth handler" \
  -f fix_diff="$(cat my.patch)"
```

### Composite action

The logic is encapsulated in `apply-fix/action.yml` so it can be embedded directly in a larger job without spawning a separate workflow:

```yaml
- uses: glitchwerks/github-actions/apply-fix@v2
  with:
    pr_number: '42'
    fix_diff: ${{ steps.diagnosis.outputs.fix_diff }}
    fix_description: 'Fix missing null check'
    app_id: ${{ secrets.APP_ID }}
    app_private_key: ${{ secrets.APP_PRIVATE_KEY }}
```

---

## Troubleshooting

**Q: What happens if I don't provide any token?**
The action will fail with a clear `::error::` message at the token resolution step rather than with a cryptic authentication failure downstream. `APP_ID` + `APP_PRIVATE_KEY` are required for all write-capable actions.

**Q: What happens when App token generation fails?**
If `actions/create-github-app-token` fails (e.g. wrong App ID, malformed private key), the "Resolve write token" step will immediately fail with an explicit error message directing you to the README. Check that `APP_ID` and `APP_PRIVATE_KEY` are correctly configured.

---

## Contributing

All pull requests are linted automatically with [actionlint](https://github.com/rhysd/actionlint), which validates workflow syntax, expression types, and shell scripts. Run it locally before pushing:

```bash
brew install actionlint   # macOS
actionlint               # from repo root
```

---

## Prerequisites

- A `CLAUDE_CODE_OAUTH_TOKEN` secret must be set on the consuming repository (or organization). Obtain this token from [claude.ai](https://claude.ai).
- A GitHub App (`APP_ID` + `APP_PRIVATE_KEY`) is required for write operations (git push, triggering downstream workflows). See the GitHub App setup section under CI Failure Diagnosis for instructions.
