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

## Prerequisites

- A `CLAUDE_CODE_OAUTH_TOKEN` secret must be set on the consuming repository (or organization). Obtain this token from [claude.ai](https://claude.ai).
