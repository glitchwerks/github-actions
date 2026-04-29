# Slack Notify Action — Design Spec

**Date:** 2026-04-08 (original) · revised 2026-04-22
**Status:** Approved — implementation architecture revised 2026-04-22

> **Revision note (2026-04-22):** The original spec targeted the repo's then-current TypeScript-plus-`ncc` composite-action pattern. PR [#128](https://github.com/glitchwerks/github-actions/pull/128) reverted that entire architecture, returning the repo to pure-bash composite actions with no `src/`, no `dist/`, no `package.json`. Sections §"Action Architecture" (formerly §"TypeScript Architecture"), §"Error Handling", and §"Testing Strategy" have been rewritten for the bash + `jq` pattern that matches the current `apply-fix/`, `check-auth/`, and `lint-failure/` actions. All design decisions above the implementation chapter (inputs, outputs, message layout, graceful degradation, non-blocking failure) are unchanged and remain approved.

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
| `repository` | `${{ github.repository }}` | Repository name in `owner/repo` format |
| `run_url` | `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}` | Link to the workflow run |
| `branch` | `${{ github.ref_name }}` | Branch name |
| `pr_number` | `''` | PR number, if applicable |
| `commit_sha` | `${{ github.sha }}` | Commit SHA |
| `actor` | `${{ github.actor }}` | Who triggered the workflow |
| `duration` | `''` | Workflow duration — any human-readable string; displayed as-is in the context block. Consumer calculates (e.g., `"2m 34s"`, `"3 minutes"`, `"00:02:34"`). |

### Optional Inputs — Claude Context

| Input | Description |
|---|---|
| `claude_summary` | Free-text summary of what Claude found/did |
| `confidence` | Claude's confidence level: `high`, `medium`, `low`, or empty |
| `action_taken` | What Claude did: `patch_applied`, `comment_posted`, `no_action`, or empty |

### Outputs

None in v1.

> **Note on threading replies.** Slack incoming webhooks return plain-text `ok` on success, not JSON with a `ts` / `message_ts` field. Message-timestamp outputs (which would enable threaded replies) require migrating the action to the Slack Web API (`chat.postMessage`, OAuth-token auth instead of webhook URL) — a different auth model with different consumer tradeoffs. If threading becomes a requirement, open a new spec discussion rather than bolting it on.

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

## Action Architecture

### File Structure

```
slack-notify/
├── action.yml                  # Composite action definition — declares inputs/outputs + orchestrates steps
├── lib/
│   └── build-payload.sh        # Builds Slack Block Kit JSON from env vars; emits to stdout
└── tests/
    └── build-payload.bats      # bats unit tests — asserts against the emitted JSON via jq
```

No `src/`, no `dist/`, no `package.json`, no Node.js source — this matches the current `apply-fix/`, `check-auth/`, and `lint-failure/` composite-action pattern and is consistent with the repo's CLAUDE.md declaration that this is a pure GitHub Actions project.

### Design Decisions

- **`action.yml` orchestrates** — declares the composite action using `using: composite` (see `apply-fix/action.yml` for reference); its shell steps pass inputs into env vars, invoke `lib/build-payload.sh` to produce the payload, and `curl`-POST to the webhook. Per the repo convention, any `${{ }}` expression that ends up inside a single-quoted shell string must carry a `shellcheck disable=SC2016` comment.
- **`lib/build-payload.sh` is the unit-testable seam** — reads all inputs from env vars (`STATUS`, `WORKFLOW_NAME`, `CLAUDE_SUMMARY`, etc.), constructs the Block Kit JSON via `jq`, and prints it to stdout. Pure function in the bash sense — no network, no side effects, exit code 0 on success. This is what `bats` tests pin.
- **`jq` builds the JSON** — `jq -n` with `--arg` for each user-provided input constructs the Block Kit structure declaratively. This is safer than string-concatenating JSON and gives correct escaping of `"`, `\`, newlines, and control characters for free. Conditional blocks (e.g. the Claude section) are composed via `jq` conditionals (`if $summary != "" then … else empty end`).
- **`curl` posts the webhook** — one POST with `Content-Type: application/json`, a 10-second `--max-time`, and `--fail-with-body` so HTTP 2xx is distinguishable from non-2xx. No Slack SDK needed; incoming webhooks accept a bare JSON payload.
- **URL construction** — the commit-SHA link is built as `${{ github.server_url }}/${{ github.repository }}/commit/<commit_sha>`; the PR link as `${{ github.server_url }}/${{ github.repository }}/pull/<pr_number>`. Both values enter `action.yml` as env vars and are passed into `jq` via `--arg` bindings, never interpolated into the `jq` expression string — same injection-safety pattern as all other user-provided fields.
- **No new dependencies** — `bash`, `jq`, and `curl` are pre-installed on every GitHub-hosted `ubuntu-latest` runner. `bats` runs in CI but does not ship as part of the action.
- **No build step** — the repo has no `package.json`, no `ncc`, no `dist/check` workflow (the `build-check.yml` referenced in the pre-revert original is gone). An addition of this action should not re-introduce any of those. If a future feature genuinely needs TypeScript, it opens a new spec discussion — the default is no.

## Error Handling

### Webhook Failures
- Non-2xx response from Slack → emit `::warning::Slack webhook returned HTTP <code>: <body>` via GitHub workflow commands (echo to stdout). Step exits 0 — notification failure never breaks CI.
- Network timeout → `curl --max-time 10` exits non-zero; the shell step traps the exit code, emits a `::warning::` with the curl error, and exits 0.
- Rationale: notification failure should never break CI. The only way this action fails the job is an input-validation error (see below).

### Input Validation
- Missing `webhook_url` → `echo "::error::webhook_url is required"` + `exit 1`. Config error, fail fast.
- Missing `status` → `echo "::error::status is required (expected: success|failure|cancelled)"` + `exit 1`. Config error, fail fast.
- Invalid `status` value (not `success`/`failure`/`cancelled`) → treat as `failure` and emit `::warning::unknown status '<value>' — treating as failure`. Does not fail the step.
- Empty optional inputs → `jq` conditionals omit the corresponding Block Kit sections (`if $summary != "" then … else empty end`). No "undefined" or blank fields.

### Payload Safety
- **Size limit:** Slack webhooks cap text fields at 3,000 characters. Before calling `jq`, truncate `$CLAUDE_SUMMARY` to 2,500 chars and append `…(truncated)` if the input exceeded the limit. Implementation: a short bash test using `${#CLAUDE_SUMMARY}` + parameter expansion.
- **Special characters & injection safety:** All user-provided text (`claude_summary`, `workflow_name`, `branch`, etc.) is passed into `jq` via `--arg` bindings — never interpolated into the `jq` expression string. This gives correct JSON escaping for free (quotes, backslashes, newlines, control chars) and is immune to template-injection tricks in comment bodies or input values. Slack mrkdwn-specific escaping (`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`) is applied inside `jq` via `gsub` before emitting text fields.

## Testing Strategy

### Unit Tests (`tests/build-payload.bats`)

The testable seam is `lib/build-payload.sh` — it reads env vars, emits JSON to stdout, and has no network or filesystem side effects. Each bats test sets up the env, runs the script, and asserts against the emitted JSON via `jq`. No mocks needed — the script *is* the pure function.

- **Success/failure/cancelled** — assert color bar (`jq '.attachments[0].color'`), header emoji + status text, no Claude block.
- **With PR context** — assert the "View PR" button block is present and its URL matches the expected `pr_number`.
- **Without PR context** — assert the action buttons block has only one button (View Run, no View PR).
- **With Claude context (all fields)** — assert the Claude block exists with expected header text, summary body, confidence badge, and action-taken line.
- **With Claude context (partial — summary only)** — assert the Claude block exists, confidence + action-taken lines absent.
- **Without Claude context** — assert the Claude block is completely absent from the JSON (no empty placeholder).
- **Claude summary truncation** — input of 3,000 chars produces a summary field of exactly 2,500 chars + `…(truncated)` suffix (assert via `jq -r '.attachments[0].blocks[n].text.text | length'`).
- **Special character escaping** — input `Bug & <script>` produces `Bug &amp; &lt;script&gt;` in the Slack mrkdwn text field.
- **JSON injection attempt** — input containing `","malicious":"1` (trying to break out of the JSON string) is safely escaped by `jq --arg` and appears literally in the `text` field; the output JSON structure is not corrupted (validate with `jq` parsing — any corruption fails the parse).
- **Invalid status** — `status=broken` produces a failure-colored message (`red`) with a warning printed to stderr; exit code is 0.
- **All optional fields empty** — minimal payload: header + context + one action button; no Claude block; no PR-related fields in context block.

Bats runs via a new `slack-notify-bats` job — either added to the existing `lint.yml` workflow (which already runs on every push/PR and owns `actionlint`) or to a new `test.yml` created alongside. The implementer picks whichever fits cleanest when the implementation lands; spec is pattern-level, not workflow-file-level. `shellcheck` also runs against `slack-notify/lib/*.sh` and the action.yml's embedded shell blocks.

### Integration Tests

The action is end-to-end-testable only against a real Slack webhook. Dogfooding path: wire a `slack-notify` step behind a non-blocking `if: github.repository == 'glitchwerks/github-actions'` guard in one of this repo's own workflows, pointing at a maintainer-owned test channel webhook stored as a repo secret. Observe real deliveries; failures appear as `::warning::` annotations in the run log without breaking the job. This is the v1 integration test — more formal mocking infrastructure is out of scope.

### Not Tested
- Actual Slack delivery (dogfooded on this repo's workflows against a test channel)
- Block Kit rendering inside the Slack app (Slack's responsibility)

## Consumer Integration

### Basic CI Notification

```yaml
- name: Notify Slack
  if: always()
  uses: glitchwerks/github-actions/slack-notify@v2
  with:
    webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
    status: ${{ job.status }}
```

### Claude-Enriched Notification

```yaml
- name: Notify Slack
  if: always()
  uses: glitchwerks/github-actions/slack-notify@v2
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
