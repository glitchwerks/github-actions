# Claude PR Review — Composite Action

Runs an automated Claude code review on a pull request. Claude retrieves the diff, evaluates it across five dimensions (code quality, security, performance, test coverage, and documentation), posts a sticky summary comment, and adds inline review comments on specific lines where relevant.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `claude_code_oauth_token` | Yes | — | Claude Code OAuth token (use a repository or organization secret) |
| `model` | No | `claude-sonnet-4-5` | Claude model to use for the review |
| `max_turns` | No | `10` | Maximum number of agentic turns Claude may take |

## Usage

Create a workflow in your consuming repository that triggers on pull request events and calls this action:

```yaml
# .github/workflows/pr-review.yml
name: PR Review

on:
  pull_request:
    types: [opened, synchronize, reopened]

# Permissions must be declared at workflow level (not job level).
# pull_request events default to pull-requests: none — write must be explicit.
permissions:
  contents: read
  pull-requests: write

jobs:
  claude-review:
    runs-on: ubuntu-latest
    steps:
      - uses: glitchwerks/github-actions/pr-review@v2
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### With custom model and turn limit

```yaml
      - uses: glitchwerks/github-actions/pr-review@v2
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          model: claude-opus-4-5
          max_turns: '20'
```

## Notes

- The action uses `use_sticky_comment: true`, so repeated runs on the same PR update the existing comment rather than adding new ones.
- `fetch-depth: 0` is set automatically so Claude has full git history available.
- Prefer the [reusable workflow](../.github/workflows/claude-pr-review.yml) variant if you don't need to embed this in a more complex job.
