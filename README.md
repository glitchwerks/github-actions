# github-actions

Reusable GitHub Actions for Claude-powered automation. This repository provides two actions — one for automated PR reviews and one for responding to `@claude` mentions in comments — built on top of [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).

All actions authenticate using a `CLAUDE_CODE_OAUTH_TOKEN` secret.

## Actions

| Action | Description | Usage pattern |
|---|---|---|
| `pr-review` | Claude reviews a PR for code quality, security, performance, test coverage, and docs | Composite action or reusable workflow |
| `tag-claude` | Claude responds to `@claude` mentions in issue and PR comments | Composite action or reusable workflow |

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

jobs:
  review:
    uses: cbeaulieu-gt/github-actions/.github/workflows/claude-pr-review.yml@v1
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Optional inputs:

```yaml
    with:
      model: claude-opus-4-5   # default: claude-sonnet-4-5
      max_turns: '20'          # default: 10
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

jobs:
  respond:
    uses: cbeaulieu-gt/github-actions/.github/workflows/claude-tag-respond.yml@v1
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Optional inputs:

```yaml
    with:
      trigger_phrase: '@bot'   # default: @claude
```

---

## Composite Actions

If you need more control (e.g., embed the review step inside a larger job), use the composite actions directly instead of the reusable workflows.

- [`pr-review/`](./pr-review/README.md) — composite action docs and examples
- [`tag-claude/`](./tag-claude/README.md) — composite action docs and examples

---

## Versioning

| Ref | Meaning |
|---|---|
| `@v1` | Stable floating tag — points to the latest `v1.x.x` release. Use this in production. |
| `@main` | Latest development commit. May include breaking changes. |

When a new major version is released, a new `@v2` tag will be created. The `@v1` tag will continue to point to the last `v1.x.x` release for backwards compatibility.

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
| `GH_PAT` | GitHub personal access token with `repo` scope for API calls and pushing to PR branches |

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

jobs:
  diagnose:
    uses: cbeaulieu-gt/github-actions/.github/workflows/ci-failure.yaml@v1
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      gh_pat: ${{ secrets.GH_PAT }}
```

Optional inputs:

```yaml
    with:
      model: claude-opus-4-5   # default: claude-sonnet-4-5
      max_turns: '20'          # default: 15
      auto_apply: false        # default: true — set false to diagnose only
```

---

## Apply Fix

The `apply-fix` workflow (and its backing composite action at `apply-fix/`) checks out a PR branch, validates a unified diff against protected paths, applies it, commits, and pushes. It is invoked automatically by the CI Failure Diagnosis workflow when `auto_apply` is `true` and confidence is `high`, but can also be triggered manually.

### Required secrets

| Secret | Purpose |
|---|---|
| `GH_PAT` | GitHub personal access token with `repo` scope |

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
- uses: cbeaulieu-gt/github-actions/apply-fix@v1
  with:
    pr_number: '42'
    fix_diff: ${{ steps.diagnosis.outputs.fix_diff }}
    fix_description: 'Fix missing null check'
    github_token: ${{ secrets.GH_PAT }}
```

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
- A `GH_PAT` secret is required for the CI Failure Diagnosis and Apply Fix workflows. Create a fine-grained personal access token with **Contents: read and write** and **Pull requests: read** permissions on the target repository.
