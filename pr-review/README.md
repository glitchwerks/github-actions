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

## Draft PRs

The reusable workflow at `.github/workflows/claude-pr-review.yml` skips review while a PR is in draft and auto-fires once when the PR transitions from draft to ready for review (the `ready_for_review` event type).

**Why:** iterative draft pushes accumulate redundant review runs that re-flag the same findings. Reviewing a draft on every push wastes API spend, generates duplicate comment noise, and obscures the merge-ready state when the PR is finally ready. Reviewing on the draft → ready transition (and on subsequent pushes once non-draft) gives you exactly one review per meaningful state change.

**For consumers using `workflow_call`:** the draft skip is built into the reusable workflow — you don't need to add it yourself. You DO need to add `ready_for_review` to your caller workflow's trigger types so the workflow runs on the draft → ready transition:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  review:
    uses: glitchwerks/github-actions/.github/workflows/claude-pr-review.yml@v2
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

The reusable workflow's `jobs.review.if: github.event.pull_request.draft == false` skip evaluates against your caller's PR event (`workflow_call` inherits the caller's `github.event` context), so a draft PR will not trigger a review even though your caller job is invoked.

(Optional: if you want to skip the `workflow_call` invocation entirely on drafts to avoid the small dispatch overhead, you can add `if: github.event.pull_request.draft == false` to your caller job too. Cosmetic improvement only — the actual `claude-code-action` invocation is already gated.)

**To force a review of a draft:** push a commit while the PR is non-draft, or temporarily mark it ready and back to draft (the `ready_for_review` event will fire).
