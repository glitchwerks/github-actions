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

There are no other build steps, tests, or package managers — this is a pure GitHub Actions project.

## Architecture

Every capability ships in two forms:

| Form | Location | Use when |
|---|---|---|
| Reusable workflow | `.github/workflows/claude-*.yml` | Simplest consumer experience — one `uses:` line |
| Composite action | `<name>/action.yml` | Embed as a step inside a larger job |

The reusable workflows are thin wrappers that delegate to the composite actions (same pattern as `apply-fix.yml` → `./apply-fix`). Logic lives in the composite action; the workflow just provides the trigger context, permissions, and concurrency blocks.

**Why absolute refs, not relative paths:** Reusable workflows reference composite actions via `glitchwerks/github-actions/<action>@v2` (not `./action`). Relative `./` paths break for external consumers because `actions/checkout@v4` replaces the runner workspace with the consumer's repo — `./tag-claude` then points into the consumer's repo, not this library. Absolute refs let GitHub resolve the action directly from this repo's tree without a local checkout.

**Dogfooding limitation:** GitHub Actions does not support expressions in `uses:` values, so a conditional `@main` vs `@v2` reference is not possible. PRs opened against this repo will test composite actions at the released `@v2` tag, not the local branch's composite action changes. To validate a composite action change before release, test it in an external consumer repo pointing at the branch.

### Actions

- **`pr-review/`** — Reviews PRs via `anthropics/claude-code-action@v1`. On `synchronize` events, diffs only the new commits (`git diff before..after`) and escalates to a full review if foundational code is touched. Skips review while a PR is in draft; auto-fires once when the PR transitions to ready for review (per #174). Posts a `claude-pr-review/quality-gate` commit status (per #176) — `failure` when the latest review contains Critical/BLOCKING or High-Priority/MAJOR markers, `success` otherwise; intended to be required by branch protection rulesets.
- **`tag-claude/`** — Responds to `@claude` mentions. Delegates to `./check-auth` first, then calls `claude-code-action` only if authorized.
- **`claude-command-router/`** — Verb router (Phase 4). Parses `@claude <verb>` comment bodies into `{overlay, status, mode}` outputs for downstream dispatch. Pure string logic — no containers. Delegates auth to `check-auth/`. Wraps `lib/parse.sh` (a sourceable bash function — file scope sets no flags so callers' shells stay clean) plus a JSON test corpus at `tests/cases.json` exercised by `.github/workflows/test.yml` on every PR. Caller workflow `claude-tag-respond.yml` lands in Phase 5; eventual successor to `tag-claude/` (Phase 7). The Architecture list is ordered by responsibility, not alphabetically — this row is placed after `tag-claude/` (its successor) and before `check-auth/` (its dependency).
- **`check-auth/`** — Authorization primitive. Outputs `authorized=true/false` based on an explicit `authorized_users` allowlist (takes precedence) or `github.event.comment.author_association` (OWNER/MEMBER/COLLABORATOR). Used by `tag-claude/` and `claude-command-router/`.
- **`apply-fix/`** — Validates a unified diff against protected paths (rejects anything touching `.github/`), applies it with `git apply`, commits, and pushes to the PR branch.
- **`lint-failure/`** — Diagnoses lint failures on a PR via `anthropics/claude-code-action@v1`. Fetches failed lint logs and PR diff, posts a structured `## Claude Lint Diagnosis` comment, and optionally commits a fix when `auto_apply: true`.

### CI automation workflows

The `claude-*.yml` reusable workflows (everything except `ci-failure.yaml` and `apply-fix.yml`) are container-pinned to overlay images at SHA256 digest as of Phase 5 (#188). The job's `container:` field selects the runtime image, which bakes in Claude CLI plus a verb-specific agent set; the composite action's bash steps and embedded `claude-code-action@v1` invocation all run inside that container.

- **`ci-failure.yaml`** — Triggered by `workflow_run` on CI failure. Fetches plain-text logs via `gh run view --log-failed`, writes them to `/tmp/ci_logs.txt`, calls `claude-code-action` to diagnose and optionally auto-apply a fix. **Not container-pinned** — kept until Phase 7 cutover; consumers should migrate to `claude-ci-failure.yml`.
- **`apply-fix.yml`** — `workflow_dispatch` wrapper around `./apply-fix` for manual invocation. **Not container-pinned** — kept for the manual-trigger path.
- **`claude-pr-review.yml`** — Container-pinned to `claude-runtime-review`. Both `pull_request_target` (this repo's dogfood) and `workflow_call` (external consumers).
- **`claude-apply-fix.yml`** — `workflow_call`-only wrapper around `./apply-fix`, container-pinned to `claude-runtime-fix`. Phase 5 (#188) — consumer-facing reusable form of the manual-fix path.
- **`claude-lint-failure.yml`** — `workflow_call`-only wrapper around `./lint-failure`, container-pinned to `claude-runtime-fix`. Per spec §7.5, both the read-only diagnosis path and the auto-apply path use the same overlay; behavior is gated by the `auto_apply` input.
- **`claude-lint-fix.yml`** — Legacy two-job (`./lint-diagnose` + `./lint-apply`) form, NOT container-pinned. Kept until Phase 7 cutover; consumers should migrate to `claude-lint-failure.yml`.
- **`claude-ci-failure.yml`** — `workflow_call`-only CI-failure diagnosis form, container-pinned to `claude-runtime-fix`. Phase 5 (#188) — consumer-facing reusable form alongside the existing `ci-failure.yaml`.
- **`claude-tag-respond.yml`** — Two-job (`route` → `dispatch`) flow. The `route` job invokes `glitchwerks/github-actions/claude-command-router@v2` (Phase 4), maps the resolved overlay to its digest-pinned image URL, and emits the URL as a job output. The `dispatch` job pins `container:` to that URL and runs `claude-code-action@v1` inside the verb-specific overlay (review / fix / explain). The `READ_ONLY_MODE` env var is forwarded into `dispatch` so the fix overlay's persona can decline commits when the router emitted `mode=read-only`. Phase 5 (#188) — successor to the v2 `tag-claude/`-backed implementation.

## Key conventions

**Permissions must be declared at the workflow level** (not job level) in caller workflows. GitHub ignores job-level permissions when calling reusable workflows. `pull_request` events default to `pull-requests: none` and `contents: read` — both must be explicitly granted.

**Token selection for `claude-code-action`:** Use `github_token: ${{ github.token }}` for read-only operations (PR review, which does not push commits). Use the resolved App token (`${{ steps.token.outputs.value }}`) when `claude-code-action` must push commits — tag responses, lint-diagnose, lint-failure, ci-failure, and apply-fix all pass the App token. GitHub suppresses `synchronize` events for pushes authenticated with `GITHUB_TOKEN`, so an App token is required to re-trigger downstream workflows like `pr-review`. App tokens are short-lived and show a distinct bot identity (e.g., `my-app[bot]`).

**Composite action inputs are always strings** — there is no `type` field. Boolean inputs like `require_association` arrive as the string `'true'`/`'false'` and must be compared with `[ "$VAR" = "true" ]`.

**Authorization step outputs gate downstream steps** — `exit 0` inside a composite action step does not prevent subsequent steps from running. Use a step output (`authorized=true/false` → `$GITHUB_OUTPUT`) and `if: steps.authz.outputs.authorized == 'true'` on each downstream step.

**`shellcheck disable=SC2016`** is required on `run:` blocks that contain `${{ }}` expressions inside single-quoted strings — shellcheck treats these as unintended non-expansion, but GitHub Actions pre-processes them before the shell sees the string.

## CI Runtime (Phase 1+)

The `runtime/` tree is the authoritative source for the containerized CI Claude runtime (epic #130, [plan](docs/superpowers/plans/2026-04-22-ci-claude-runtime.md), [spec](docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md)):

- `runtime/ci-manifest.yaml` — single source of truth for what gets baked into each image
- `runtime/ci-manifest.schema.json` — structural rules (validated by `ajv` in STAGE 1)
- `runtime/scripts/validate-manifest.sh` — semantic rules (path existence, plugin collisions, override collisions)

The manifest's `sources.private.ref` MUST match `^ci-v\d+\.\d+\.\d+$` and resolve to a real tag in `glitchwerks/claude-configs`. Bumping that pin requires a manual review of the `git diff` between the old and new tag. The marketplace SHA pin (`sources.marketplace.ref`) follows the same manual-on-observed-value cadence (spec §13 Q5).

The build workflow `.github/workflows/runtime-build.yml` runs STAGE 1 on `pull_request` events touching `runtime/**` (validation gate before merge) and on `push` to `main` (post-merge re-verification). Phase 2 (image build) appends STAGE 2 to the same workflow.

**Phase 2 status:** the base image at `ghcr.io/glitchwerks/claude-runtime-base@sha256:<digest>` is the foundation for all overlays in Phase 3. It is built from `node:20-slim` (digest-pinned) plus the materialized `shared.*` tree from `runtime/ci-manifest.yaml`. The smoke test asserts non-zero counts for agents/skills/plugins enumerated by Claude Code CLI as a non-root UID. **Reproducibility model:** GHCR does not support tag immutability (per Issue [#173](https://github.com/glitchwerks/github-actions/issues/173)); reproducibility is enforced via digest pins (`@sha256:<digest>`) in reusable workflow files — content-addressed and inherently immutable. The `:<pubsha>` tag alias is cosmetic. Phase 0 [#138](https://github.com/glitchwerks/github-actions/issues/138) was closed; criterion C3 was superseded by the digest-pin pivot rather than satisfied.

**Phase 3 status (post-merge of this PR):** three overlay images at `ghcr.io/glitchwerks/claude-runtime-{review,fix,explain}@sha256:<digest>` build FROM the Phase 2 base. Each overlay carries verb-specific agents/plugins per `overlays.<verb>.imports_from_private` and a verb-scoped `runtime/overlays/<verb>/CLAUDE.md` that becomes the active persona at job time (replaces the base shared CLAUDE.md per §3.4 layer 2). Each overlay also declares an `expected.yaml` inventory contract that the matcher (`runtime/scripts/inventory-match.sh`) enforces in STAGE 4-overlay smoke. The "different eyes" guarantee (§3.1, §10.2) is enforced mechanically — a future edit that accidentally imports `code-writer` into review fails the build. Phase 3 also introduces `overlays.<verb>.subtract_from_shared.plugins` (manifest schema extension; see spec §4.2/§5.1 amendments) to remove base-inherited plugins from a specific overlay (review subtracts `skill-creator`). Issue [#141](https://github.com/glitchwerks/github-actions/issues/141).

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
