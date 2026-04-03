# Tag Claude — Composite Action

Responds to `@claude` mentions (or a custom trigger phrase) in issue comments and pull request review comments. When a user tags Claude in a comment, Claude reads the comment, understands the context, and replies in the same thread.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `claude_code_oauth_token` | Yes | — | Claude Code OAuth token (use a repository or organization secret) |
| `trigger_phrase` | No | `@claude` | The phrase that activates Claude; change this to use a different mention style |

## Usage

Create a workflow in your consuming repository that listens for comment events and calls this action. Both `issue_comment` and `pull_request_review_comment` triggers are needed to cover comments on issues and PR review threads respectively.

```yaml
# .github/workflows/tag-claude.yml
name: Tag Claude

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

# Permissions must be declared at workflow level (not job level).
# contents: write is required so Claude can push commits when asked.
permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  claude-respond:
    runs-on: ubuntu-latest
    steps:
      - uses: cbeaulieu-gt/github-actions/tag-claude@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### With a custom trigger phrase

```yaml
      - uses: cbeaulieu-gt/github-actions/tag-claude@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          trigger_phrase: '@bot'
```

## Notes

- The action only runs when the comment body contains the trigger phrase. Comments without it are a no-op.
- Prefer the [reusable workflow](../.github/workflows/claude-tag-respond.yml) variant if you want to avoid managing the job definition yourself.
