# Slack Notify Action — Design Spec

**Date:** 2026-04-08
**Status:** Approved (brainstorming complete)

## Overview

A general-purpose composite action (`slack-notify/`) that sends rich Slack notifications via incoming webhook when any CI workflow completes. Supports both plain CI status messages and Claude-enriched messages that surface diagnosis summaries, confidence levels, and actions taken.

Delivered as a **composite action only** (no reusable workflow wrapper). Consumers add a step to their existing jobs. Each consumer repo provides its own webhook URL pointing to the appropriate project Slack channel.

## Action Interface

### Required Inputs

| Input | Description |
|---|---|
| `webhook_url` | Slack incoming webhook URL (passed as a secret) |
| `status` | Workflow outcome: `success`, `failure`, or `cancelled` |

### Optional Inputs — CI Context

| Input | Default | Description |
|---|---|---|
| `workflow_name` | `${{ github.workflow }}` | Name of the workflow that ran |
| `run_url` | `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}` | Link to the workflow run |
| `branch` | `${{ github.ref_name }}` | Branch name |
| `pr_number` | `''` | PR number, if applicable |
| `commit_sha` | `${{ github.sha }}` | Commit SHA |
| `actor` | `${{ github.actor }}` | Who triggered the workflow |
| `duration` | `''` | Workflow duration string (e.g., `"2m 34s"`), consumer-calculated |

### Optional Inputs — Claude Context

| Input | Description |
|---|---|
| `claude_summary` | Free-text summary of what Claude found/did |
| `confidence` | Claude's confidence level: `high`, `medium`, `low`, or empty |
| `action_taken` | What Claude did: `patch_applied`, `comment_posted`, `no_action`, or empty |

### Outputs

| Output | Description |
|---|---|
| `message_ts` | Slack message timestamp (for threading replies) |

## Message Layout

Uses Slack Block Kit with adaptive sections based on provided inputs.

### Header Block (always)
Status emoji + workflow name + repo:
- `✅ build-and-test passed — myorg/myapp`
- `❌ lint failed — myorg/myapp`

### Context Block (always)
Compact single line with branch, commit SHA (short, linked), actor, duration (if provided), PR link (if provided):
- `main • a1b2c3d • @chris • 2m 34s • PR #42`

### Claude Block (only when `claude_summary` is provided)
- Section header with robot emoji, derived from `action_taken`:
  - `patch_applied` → `Claude Fix`
  - `comment_posted` → `Claude Diagnosis`
  - `no_action` or empty → `Claude Analysis`
- Summary text as body
- Confidence badge if provided: `🟢 high` / `🟡 medium` / `🔴 low`
- Action taken if provided: `Patch applied` / `Comment posted` / `No action`

### Action Button Block (always)
- "View Run" button linking to `run_url`
- "View PR" button (only when `pr_number` is provided)

### Color Coding
Slack attachment color bar: green for success, red for failure, grey for cancelled.

### Example — Failure with Claude Diagnosis

> 🔴 **lint failed — myorg/myapp**
> `main` • `a1b2c3d` • @chris • 1m 12s • PR #42
>
> 🤖 **Claude Lint Diagnosis** · 🟢 high · Patch applied
> Missing semicolons on lines 14, 28. Applied auto-fix and pushed.
>
> [View Run] [View PR #42]

### Example — Plain Success (No Claude Context)

> 🟢 **build-and-test passed — myorg/myapp**
> `feature-auth` • `f3e4d5c` • @chris • 3m 45s
>
> [View Run]

## TypeScript Architecture

### File Structure

```
src/slack-notify/
├── index.ts              # Entry point — reads inputs, calls buildPayload, posts to webhook
├── payload.ts            # Pure function: inputs → Slack Block Kit JSON
└── types.ts              # Input types and Slack Block Kit type definitions

src/__tests__/slack-notify/
├── payload.test.ts       # Unit tests for payload construction
└── index.test.ts         # Integration tests (mocked fetch + @actions/core)

slack-notify/
├── action.yml            # Composite action definition
└── dist/
    └── index.js          # ncc bundle (built, not hand-written)
```

### Design Decisions

- **`payload.ts` is pure** — takes a typed input object, returns a Slack payload object. No side effects, no I/O. All Block Kit construction and conditional logic lives here. Fully unit-testable.
- **`index.ts` is thin glue** — reads `@actions/core` inputs, calls `buildPayload()`, posts via `fetch()`, sets outputs. ~20 lines of orchestration.
- **No new dependencies** — uses native `fetch` (Node 20+) and `@actions/core` (already in repo). No Slack SDK needed; incoming webhooks are a simple POST with JSON.
- **Build integration** — new `ncc build` entry appended to `package.json`'s `build` script. `build-check.yml` CI already verifies `dist/` freshness.

## Error Handling

### Webhook Failures
- Non-2xx response from Slack → `core.warning()` with status code and response body. Does **not** fail the step or job.
- Network timeout → 10-second fetch timeout, same warning behavior.
- Rationale: notification failure should never break CI.

### Input Validation
- Missing `webhook_url` → `core.setFailed()`. Config error, fail fast.
- Missing `status` → `core.setFailed()`. Config error, fail fast.
- Invalid `status` value (not `success`/`failure`/`cancelled`) → treat as `failure` with `core.warning()`.
- Empty optional inputs → omit corresponding Block Kit sections. No "undefined" or blank fields.

### Payload Safety
- **Size limit:** Slack webhooks cap text fields at 3,000 characters. If `claude_summary` exceeds 2,500 characters, truncate with `…(truncated)` suffix.
- **Special characters:** Escape `&`, `<`, `>` in user-provided text (`claude_summary`, `workflow_name`) for Slack mrkdwn safety.

## Testing Strategy

### Unit Tests (`payload.test.ts`)
- Success/failure/cancelled messages — correct Block Kit structure, color, emoji
- With PR context — "View PR" button present, PR link in context block
- With Claude context — Claude block with summary, confidence badge, action taken
- Without Claude context — Claude block entirely absent
- Claude summary truncation — 3,000-char input truncated to 2,500 with suffix
- Special character escaping — `&`, `<`, `>` properly escaped
- Invalid status — treated as failure without crash
- All optional fields empty — clean minimal message

### Integration Tests (`index.test.ts`)
- Mock `@actions/core` (getInput/setOutput/setFailed/warning) and global `fetch`
- Happy path — valid inputs, 200 response → `message_ts` output set
- Webhook failure — 400 response → `core.warning()`, step does not fail
- Network error — fetch rejection → warning, no crash
- Missing required input — no webhook_url → `core.setFailed()`

### Not Tested
- Actual Slack delivery (consumer integration test)
- Block Kit rendering (Slack's responsibility)

## Consumer Integration

### Basic CI Notification

```yaml
- name: Notify Slack
  if: always()
  uses: cbeaulieu-gt/github-actions/slack-notify@v2
  with:
    webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
    status: ${{ job.status }}
```

### Claude-Enriched Notification

```yaml
- name: Notify Slack
  if: always()
  uses: cbeaulieu-gt/github-actions/slack-notify@v2
  with:
    webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
    status: ${{ job.status }}
    pr_number: ${{ github.event.pull_request.number }}
    claude_summary: ${{ steps.claude.outputs.summary }}
    confidence: ${{ steps.diagnose.outputs.confidence }}
    action_taken: ${{ steps.diagnose.outputs.action_taken }}
```

### Notes
- `if: always()` is the consumer's choice — the action always fires when invoked
- Claude-specific inputs gracefully degrade when omitted
- No changes required to existing actions — this is additive
