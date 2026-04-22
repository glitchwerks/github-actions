# CI Claude Runtime — Implementation Plan

> **For agentic workers:** This plan is a **phase decomposition** targeting sub-issues under Milestone #7, not an atomic step-by-step execution plan. When opening a sub-issue for any phase below, invoke `superpowers:writing-plans` again inside that sub-issue's worktree to produce a line-by-line detailed plan (the detailed plan lives at `docs/superpowers/plans/<phase-slug>.md` on the sub-issue's branch). Steps here use checkbox (`- [ ]`) syntax for tracking completion at the sub-issue level.

**Goal:** Ship a 4-image containerized Claude runtime (base + review + fix + explain) with a verb-routed tag-respond path, pinned into reusable workflows by digest, so that every Claude-powered CI action runs with the minimal correct persona — replacing today's direct `anthropics/claude-code-action@v1` invocations on stock `ubuntu-latest`.

**Architecture:** Shared base image (Claude Code CLI, Node.js 20, curated plugin set, shared skills/agents/CLAUDE.md imported from `cbeaulieu-gt/claude_personal_configs` at a pinned `ci-v<semver>` tag) plus three action-verb overlays (`review`, `fix`, `explain`) that layer verb-specific agents + CLAUDE.md on top. Reusable workflows `container:` into an overlay image pinned by SHA256 digest; promotion is a single atomic git commit bumping all four digests simultaneously; rollback is a `git revert` of that commit.

**Tech Stack:** Docker multi-stage builds, GitHub Actions YAML (`workflow_call`, `workflow_dispatch`, `workflow_run`), Bash + POSIX utilities for `extract-shared.sh`/validators, AJV (npx) for JSON Schema validation, declarative JSON corpus run via `bash` + `jq` for router unit tests (no new runner dependencies), GHCR for image hosting, `dorny/paths-filter` for change-scoped matrix triggers.

**Spec source of truth:** `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` on `main` (merged via PR #131, squash `93c7b8d`). Every design decision in this plan is cited back to a section of that spec. If the plan and the spec disagree, the spec wins — open a spec-amendment PR before deviating.

**Tracking:** Issue #133 (this plan), Milestone #7 (containerized Claude runtime), Epic #130.

---

## Discrepancies vs. Issue #133

Issue #133 referenced **6** Section 13 open questions. The spec as merged actually contains **10** numbered items, of which #6 (`claude-lint-failure.yml` overlay split) is already marked **Resolved** inline. That leaves **9 actually-open questions**, all addressed in §"Open questions mapping" below. This plan treats #6 as closed and covers the other 9.

---

## Deferred from v1 — CODEOWNERS "different eyes" enforcement

Spec §10.2 requires a separate reviewer for `runtime/overlays/*/expected.yaml` from the reviewer of the paired overlay manifest, enforced via CODEOWNERS + branch protection. The v1 plan **drops this enforcement** pending the outcome of issue **#137**.

**Rationale:** this is a personal repo with a single human maintainer. A second human reviewer is unlikely to appear. The realistic path to closing the "different eyes" gap is automated bot/AI review — e.g. `@claude inquisitor` as a required gate on sensitive path combinations, or a rule-based hard-gate that forces overlay + `expected.yaml` edits into separate PRs. That evaluation happens in #137, not here.

**What still protects v1 without CODEOWNERS:** the inventory assertions (`must_contain` / `must_not_contain`) in `runtime/overlays/*/expected.yaml` still run in STAGE 4 of the build pipeline and mechanically block `code-writer`-slipping-into-review-overlay regressions post-merge. The v1 gap is purely pre-merge — a compromised maintainer could still land both halves of a bad overlay change in one PR, which a bot gate (#137) would catch but the current v1 plan does not.

---

## File Structure

Every path below is relative to the repo root. "P<n>" marks the phase that introduces the file.

```
runtime/
  ci-manifest.yaml                          # P1 — authoritative manifest (§5.1)
  ci-manifest.schema.json                   # P1 — JSON Schema for AJV structural validation (§5.2)
  shared/
    CLAUDE-ci.md                            # P1 — base CLAUDE.md, CI-specific (§3.4 layer 1)
  overlays/
    review/
      Dockerfile                            # P3 — review overlay
      CLAUDE.md                             # P3 — review-scoped persona (§3.4 layer 2)
      expected.yaml                         # P3 — inventory assertion (§10.2)
    fix/
      Dockerfile                            # P3
      CLAUDE.md                             # P3
      expected.yaml                         # P3
    explain/
      Dockerfile                            # P3
      CLAUDE.md                             # P3
      expected.yaml                         # P3
  base/
    Dockerfile                              # P2 — base image
  scripts/
    extract-shared.sh                       # P2 — merges imports_from_private + local shared, enforces merge_policy (§6.2 STAGE 2)
    validate-manifest.sh                    # P1 — semantic validation (§5.2 phase 2)
    smoke-test.sh                           # P2 — smoke runner: non-root UID, HOME=/tmp/smoke-home, secret scan (§6.2 STAGE 4)
    ghcr-immutability-preflight.sh          # P1 — GHCR tag immutability check with backoff (§6.3.1, §13 Q8)
    capture-runner-uid.sh                   # P2 — prints the GHA runner's UID at pipeline time (§13 Q10)
  rollback.yml                              # P6 — workflow_dispatch rollback to a prior pubsha (§9.3)
  check-private-freshness.yml               # P6 — weekly staleness alarm with path-scoped denominator (§11.3, §13 Q7)
  prune-pending.yml                         # P6 — daily orphan pending-tag cleanup (§9.4)

.github/workflows/
  runtime-build.yml                         # P1/P2/P3 — the 5-stage build pipeline (§6.2). Grows across phases.
  claude-pr-review.yml                      # P5 — REPLACE existing content to `container:`-pin the review image
  claude-apply-fix.yml                      # P5 — REPLACE to pin fix image
  claude-lint-failure.yml                   # P5 — REPLACE to pin fix image (both paths share the fix overlay per §7.5)
  claude-ci-failure.yml                     # P5 — NEW reusable-workflow form of today's ci-failure.yaml, pins fix image
  claude-tag-respond.yml                    # P5 — NEW, replaces today's tag-claude entrypoint; dispatches per router output

claude-command-router/
  action.yml                                # P4 — verb parsing composite action (§8.1)
  lib/
    filler_words.txt                        # P4 — documented skip list (§8.1.1)
  tests/
    cases.json                              # P4 — declarative test corpus (§10.3)
    run-cases.sh                            # P4 — bash + jq test runner

# Deprecation targets (preserved until Phase 7)
tag-claude/                                 # P7 — delete after dogfooding one release cycle
ci-failure.yaml                             # P7 — remove once claude-ci-failure.yml consumers are migrated
apply-fix.yml                               # P7 — remove once claude-apply-fix.yml is the sole entrypoint
```

**Actionlint centralization:** `.github/workflows/lint.yml` already runs `actionlint` across the entire `.github/workflows/*.yml` tree on every push and PR. Every phase below that touches `.github/workflows/**` inherits this check automatically; individual phases do NOT install or re-run their own actionlint. The Phase 1 tasks mentioning `actionlint` are referencing this single centralized check, not a new one.

---

## Dependency Graph

```
Phase 0 (prerequisites: GH_PAT, ci-v* tag, GHCR immutability)
   ↓
Phase 1 (scaffold + schema + STAGE 1 pipeline)
   ├────────────────────────────────────────────┐
   ↓                                            ↓
Phase 2 (base image + STAGE 2 + STAGE 4 smoke)  Phase 4 (router composite + JSON corpus)
   ↓                                            │
Phase 3 (three overlays + STAGE 3 + inventory)  │
   ↓                                            │
Phase 5 (reusable-workflow wiring) ←────────────┘
   ↓
Phase 6 (promotion + rollback + freshness + prune)
   ↓
Phase 7 (deprecate v1 action path + cut v2.x.y)
```

**Parallelizable branch:** Phase 4 depends only on Phase 1's manifest schema being locked (so it knows what `overlay` values are legal). It does NOT depend on any image existing — router just emits strings. Run P4 in parallel with P2 + P3 to cut delivery time roughly in half.

**Concurrency constraint:** Phases 5, 6, 7 must be sequential — each modifies a reusable workflow file that the next phase also touches.

---

## Phase 0 — Prerequisites (one-time out-of-band setup)

**Suggested sub-issue title:** `Phase 0: one-time prerequisites for CI runtime (GH_PAT, private ci-v* tag, GHCR immutability)`
**Depends on:** nothing
**Blocks:** Phase 1 (no runtime code can land until all three are verifiably complete)

### Goal

One-time GitHub-UI and private-repo setup that must be complete before any runtime code lands. These steps are manual (they live in org/package settings pages and in the private repo's tag list — not in this repo's source tree), but they are tracked as a proper sub-issue so the completion state is auditable and so Phase 1's sub-issue opens against a known-ready environment.

### Tasks

- [ ] `GH_PAT` secret is set at the repo level with `repo:read` scope on `cbeaulieu-gt/claude_personal_configs`. Proof: screenshot or text listing of the secret's presence (not its value) attached as a comment to the Phase 0 sub-issue.
- [ ] `cbeaulieu-gt/claude_personal_configs` has at least one `ci-v<semver>` tag containing the artifacts the manifest imports (skills `git`, `python`; agents `ops`, `inquisitor`, `debugger`, `code-writer`, `refactor`; `CLAUDE.md`; `standards/software-standards.md`). Proof: tag name + commit SHA recorded in the Phase 0 sub-issue.
- [ ] "Prevent tag overwrites" manually enabled on all four GHCR packages: `claude-runtime-base`, `claude-runtime-review`, `claude-runtime-fix`, `claude-runtime-explain`. The packages must exist first — create an empty one-off push to each if GHCR hasn't auto-created them yet. Proof: screenshot of each package's settings page showing the toggle active.

### Acceptance criteria

- [ ] All three tasks verifiably complete with proof attached to the Phase 0 sub-issue
- [ ] Phase 1 sub-issue cannot open until Phase 0 sub-issue is closed — this is the dependency gate

---

## Phase 1 — Scaffolding and STAGE 1 pipeline

**Suggested sub-issue title:** `Phase 1: scaffold runtime/ tree + ci-manifest schema + STAGE 1 pipeline`
**Depends on:** Phase 0 (prerequisites must be verified before any runtime code lands)
**Blocks:** Phases 2, 3, 4

### Goal

Stand up `runtime/`, the manifest, the schema, the two-phase validator, the GHCR immutability preflight, and the workflow-level STAGE 1 pipeline that runs on `push` to `runtime/**`. No image builds yet — this phase ends when a hand-crafted manifest validates green against real `ci-v*` private content.

### Files

- Create: `runtime/ci-manifest.yaml` (matching §5.1 shape)
- Create: `runtime/ci-manifest.schema.json` (structural rules per §5.2)
- Create: `runtime/scripts/validate-manifest.sh` (semantic rules per §5.2 phase 2)
- Create: `runtime/scripts/ghcr-immutability-preflight.sh` (with exponential backoff per §13 Q8)
- Create: `runtime/shared/CLAUDE-ci.md` (minimal placeholder; full content lands in Phase 2)
- Create: `runtime/overlays/review/CLAUDE.md` (placeholder; full content lands in Phase 3)
- Create: `runtime/overlays/fix/CLAUDE.md` (placeholder)
- Create: `runtime/overlays/explain/CLAUDE.md` (placeholder)
- Create: `.github/workflows/runtime-build.yml` (STAGE 1 body only; STAGE 2+ land in later phases)

### Tasks

- [ ] **1.1** Bootstrap `runtime/` tree with stub CLAUDE.md files (empty heading + one-line purpose). Commit.
- [ ] **1.2** Author `runtime/ci-manifest.yaml` literally copying the §5.1 shape; pin `sources.private.ref` to the current `ci-v*` tag identified in prerequisites; pin `sources.marketplace.ref` to `f01d614cb6ac4079ec042afe79177802defc3ba7`. Leave `merge_policy.overrides: []`. Commit.
- [ ] **1.3** Author `runtime/ci-manifest.schema.json` covering the §5.2 structural assertions: private-ref regex `^ci-v\d+\.\d+\.\d+$`, marketplace-ref regex `^[a-f0-9]{40}$`, `overlays` key enum `{review, fix, explain}`, `merge_policy.on_conflict` single-value enum `{error}`, plugin name uniqueness per scope, cross-scope plugin collision check, `imports_from_private.agents` items against known-agent enum. Commit.
- [ ] **1.4** Author `runtime/scripts/validate-manifest.sh` implementing semantic rules: (a) every path in `imports_from_private` exists in the cloned private repo tree, (b) every `merge_policy.overrides` path resolves to a real collision between a `shared/` source and an imported private path, (c) cross-scope plugin collision detection. Script exits non-zero with a machine-parseable error listing all failures (never short-circuit on the first one — report them all). Commit.
- [ ] **1.5** Author `runtime/scripts/ghcr-immutability-preflight.sh`: calls `GET /orgs/{org}/packages/container/{package_name}` with a PAT, parses the tag-immutability field (confirm the exact field name against current GitHub REST API docs at implementation time), asserts true for all four packages, retries with exponential backoff on 5xx / 429 (3 attempts, base delay 2s, cap 10s) per §13 Q8. On final failure, print the §6.3.1 failure-message template naming the offending package. Support an emergency override env var `SKIP_GHCR_IMMUTABILITY=1` (documented for incident use; logs a `WARN SKIP` line). Commit.
- [ ] **1.6** Author `.github/workflows/runtime-build.yml` STAGE 1 body: `workflow_dispatch` with inputs (`images`, `private_ref_override`, `marketplace_ref_override`) + `push` filtered by `dorny/paths-filter` on `runtime/**` + the `concurrency` block per §6.1.1 (`group: runtime-build-${{ github.sha }}`, `cancel-in-progress: false`). Steps: clone public (implicit), clone private at pinned ref (use `GH_PAT`), clone marketplace, run `npx ajv validate -s runtime/ci-manifest.schema.json -d runtime/ci-manifest.yaml`, run `runtime/scripts/validate-manifest.sh`, run `runtime/scripts/ghcr-immutability-preflight.sh`, run `actionlint` on `.github/workflows/*.yml`. Each failure halts the job. Commit.
- [ ] **1.7** Dry-run STAGE 1 via `workflow_dispatch` with the real manifest → assert green. Then intentionally break the manifest three ways: (a) set `sources.private.ref: ci-v999.0.0` (non-existent tag), (b) add a plugin under both `shared.plugins` and `overlays.review.plugins`, (c) flip "Prevent tag overwrites" off on one package and re-run. Each intentional break must fail with the specific error surface from §5.2 / §6.3.1. Revert the breaks.
- [ ] **1.8** Update `CLAUDE.md` "Key conventions" section with a new bullet documenting the `runtime/` tree, the manifest contract, and the `ci-v*` private-ref requirement. Commit.

### Acceptance criteria

- [ ] `runtime/ci-manifest.yaml` + `.schema.json` + `validate-manifest.sh` + `ghcr-immutability-preflight.sh` all exist on `main`
- [ ] `.github/workflows/runtime-build.yml` runs STAGE 1 on `push` to `runtime/**` and completes green against the real manifest
- [ ] All three intentional-break dry runs fail with the specified error surface
- [ ] `actionlint` passes on the new workflow
- [ ] All four GHCR packages have "Prevent tag overwrites" enabled (verified by preflight step)

---

## Phase 2 — Base image

**Suggested sub-issue title:** `Phase 2: base image Dockerfile + extract-shared.sh + STAGE 2 & STAGE 4 pipeline`
**Depends on:** Phase 1 (the manifest + STAGE 1 pipeline must exist before a base image can clone + validate its inputs)
**Blocks:** Phase 3

### Goal

Build, push, and smoke-test the base image. This establishes: `extract-shared.sh` determinism, base Dockerfile authoring, the cache-key scheme, non-root smoke execution, `HOME=/tmp/smoke-home` isolation, secret hygiene scan, and the `pending-<pubsha>` staging pattern.

### Files

- Create: `runtime/base/Dockerfile`
- Create: `runtime/scripts/extract-shared.sh`
- Create: `runtime/scripts/smoke-test.sh`
- Create: `runtime/scripts/capture-runner-uid.sh`
- Modify: `runtime/shared/CLAUDE-ci.md` (replace stub with full CI-specific base content — see §3.4 layer 1 and Appendix A)
- Modify: `.github/workflows/runtime-build.yml` (append STAGE 2 + STAGE 4)

### Tasks

- [ ] **2.1** Author `runtime/scripts/extract-shared.sh`. Requirements: reads manifest, clones nothing (assumes STAGE 1 has already cloned private + marketplace into `/tmp/private` + `/tmp/marketplace`), emits a materialized `shared/` tree at a path passed in `$1`. Enforces §4.2 merge policy — fails with `ERROR merge_collision` formatted exactly as in §4.2 if a path collides without an override. **Determinism:** sorted file listings (`find | sort`), no embedded timestamps (strip with `touch -t 197001010000`), reproducible umask (`umask 022` at top), stable tar ordering (`tar --sort=name` for any archive output). Commit.
- [ ] **2.2** Append a STAGE 1b `extract-shared` determinism check to `runtime-build.yml`: run the script twice with identical inputs into two tmp dirs, `diff -r` them, assert empty; OR `sha256sum` the recursive file content of each and assert equal. Per §6.2 STAGE 1, non-deterministic output is a hard fail. Commit.
- [ ] **2.3** Author `runtime/base/Dockerfile`. Base: `node:20-slim`. Steps: install Claude Code CLI, install the curated plugin set per §5.1 (`context7`, `github`, `microsoft-docs`, `typescript-lsp`, `skill-creator` as P1; `security-guidance` as P2 cherry-pick — `hooks/hooks.json` + `hooks/security_reminder_hook.py` only), copy the extracted shared tree into `/opt/claude/.claude/`, `chmod -R a+rX /opt/claude/.claude/` (directories 755, files 644 per §6.2 STAGE 3 note — set here in base so overlays inherit), set `ENV PATH_TO_CLAUDE_CODE_EXECUTABLE=/opt/claude/bin/claude` + `ENV HOME=/opt/claude`, set all three OCI labels (`org.opencontainers.image.source`, `dev.cbeaulieu-gt.ci.private_ref`, `dev.cbeaulieu-gt.ci.private_sha`, `dev.cbeaulieu-gt.ci.marketplace_sha`) per §4.3 from `--label` build args. Commit.
- [ ] **2.4** **Verify §13 Q1 — HOME resolution.** Build the base image locally. Run `docker run --rm -u 1001 -e HOME=/opt/claude <base-image> claude -p "list skills" | tee out.txt`. Assert non-zero skill count. If Claude Code CLI does not honor `HOME` at this release, fall back to `/root/.claude` (keep config reachable for both common UID scenarios by placing config at both paths via a symlink) and document the fallback in the base Dockerfile comment. Commit.
- [ ] **2.5** Author `runtime/scripts/capture-runner-uid.sh`: prints `id -u` on one line. Used in STAGE 4 to pin the smoke UID dynamically per §13 Q10. Commit.
- [ ] **2.6** Author `runtime/scripts/smoke-test.sh`. Arguments: `<image-ref> <overlay-name-or-"base">`. Steps: (a) capture runner UID via the helper, (b) `docker run --rm --user $UID -e HOME=/tmp/smoke-home -e CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" <image> claude -p "list agents and skills; exit" > /tmp/smoke-out.txt`, (c) parse enumerated agents + skills + plugins, (d) assert all three counts are non-zero (hard fail on zero — see §9.2 "highest-risk silent failure"), (e) if `expected.yaml` exists for this overlay, run the `must_contain` + `must_not_contain` assertions. Post-smoke: run the §6.2 STAGE 4 secret hygiene scan — `find /opt/claude/.claude/ -name '*.oauth' -o -name '*.token' -o -name 'credentials.json' -o -name '.netrc' -o -name 'auth.json'` in a `docker run` inspection step, fail promotion if any match. Commit.
- [ ] **2.7** Append STAGE 2 + STAGE 4 to `runtime-build.yml`. STAGE 2 is sequential (base must finish before overlays can start): `docker buildx build runtime/base` with `--cache-from` + `--cache-to` keyed on the §6.2 tuple (`manifest_hash, private_ref_sha, marketplace_sha, extract_shared_sh_hash`); push `ghcr.io/cbeaulieu-gt/claude-runtime-base:pending-<pubsha>`; capture resulting digest to a job output. STAGE 4 (smoke) calls `smoke-test.sh` against `pending-<pubsha>`. Commit.
- [ ] **2.8** Replace `runtime/shared/CLAUDE-ci.md` stub with the full base CI persona content: lists the curated plugin surface, names the shared skills and the `ops` agent as mandatory imports, documents the "different set of eyes" principle (CI is not the user's local persona), references `standards/software-standards.md` for versioning + TDD rules. No file paths into private — the manifest is the source of truth for what gets imported. Commit.
- [ ] **2.9** Dry-run STAGE 1 → 2 → 4 for the base image via `workflow_dispatch(images=base)`. Assert pending-tag lands in GHCR, smoke passes, secret scan finds no matches. Remove the pending tag manually if needed to re-test.
- [ ] **2.10** Update `README.md` with a new section "CI runtime" pointing at `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` and noting that `runtime/base/` is now part of the library's build surface.

### Acceptance criteria

- [ ] Base image builds, pushes as `:pending-<pubsha>`, smoke-tests green on STAGE 4
- [ ] `extract-shared.sh` is deterministic (STAGE 1b check passes)
- [ ] §13 Q1 is either confirmed (HOME honored) or worked around (symlink) with the outcome recorded in the Dockerfile comment AND in the Phase 2 PR body
- [ ] Smoke secret-hygiene scan finds no auth artifacts in the promoted layer
- [ ] Base image runs as non-root UID without agent/skill enumeration errors
- [ ] Cache key scheme is correct — bump any one of (manifest, private ref, marketplace ref, `extract-shared.sh` content) and confirm the base layer rebuilds

---

## Phase 3 — Overlays (review, fix, explain)

**Suggested sub-issue title:** `Phase 3: review/fix/explain overlay images + expected.yaml inventory assertions + STAGE 3`
**Depends on:** Phase 2 (overlays are built `FROM claude-runtime-base@sha256:<digest>` — they layer onto the base by digest, not tag)
**Blocks:** Phase 5

### Goal

Three overlay images built from the base, each carrying only its verb-specific agents and CLAUDE.md. Inventory assertions lock the "different set of eyes" guarantee — a future edit that accidentally imports `code-writer` into the review overlay fails the build loudly.

### Files

- Create: `runtime/overlays/review/Dockerfile`
- Create: `runtime/overlays/review/expected.yaml`
- Create: `runtime/overlays/fix/Dockerfile`
- Create: `runtime/overlays/fix/expected.yaml`
- Create: `runtime/overlays/explain/Dockerfile`
- Create: `runtime/overlays/explain/expected.yaml`
- Modify: `runtime/overlays/review/CLAUDE.md` (full content — scopes the overlay to code review; explicitly forbids writing code)
- Modify: `runtime/overlays/fix/CLAUDE.md` (full content — scopes to fix/debug/refactor; documents `--read-only` flag semantics; "never skip hooks" per §9.2)
- Modify: `runtime/overlays/explain/CLAUDE.md` (full content — scopes to read-only explanation of code or errors)
- Modify: `.github/workflows/runtime-build.yml` (append STAGE 3 matrix)

### Tasks

- [ ] **3.1** Author `runtime/overlays/review/Dockerfile`. `FROM ghcr.io/cbeaulieu-gt/claude-runtime-base@sha256:${BASE_DIGEST}` (digest passed as `--build-arg BASE_DIGEST=<sha>` per §6.2 STAGE 3). Steps: install `pr-review-toolkit` plugin (P1 from marketplace clone at pinned SHA), copy `inquisitor` agent from private import, copy review overlay CLAUDE.md. `chmod -R a+rX /opt/claude/.claude/`. Commit.
- [ ] **3.2** Author `runtime/overlays/review/CLAUDE.md`. Scope: PR review only. Forbids invoking `code-writer`, `debugger`, `refactor`, `apply-fix` behaviors. References the inquisitor agent for adversarial critique. Explicitly notes that the only code-review agent on disk comes from `pr-review-toolkit` (not from personal config) per §3.1. Commit.
- [ ] **3.3** Author `runtime/overlays/review/expected.yaml` literally matching §10.2 example: `must_contain.agents: [inquisitor, comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier]`, `must_contain.skills: [git]`, `must_contain.plugins: [context7, github, microsoft-docs, typescript-lsp, security-guidance, pr-review-toolkit]`, `must_not_contain.agents: [code-writer, debugger, refactor]`, `must_not_contain.plugins: [skill-creator]`. Commit.
- [ ] **3.4** Author `runtime/overlays/fix/Dockerfile` mirroring the review Dockerfile but importing `debugger`, `code-writer`, `refactor` from private per §5.1 `overlays.fix.imports_from_private`. No `pr-review-toolkit`. Commit.
- [ ] **3.5** Author `runtime/overlays/fix/CLAUDE.md`. Scope: write/fix/refactor code on the consumer's branch. Documents the `--read-only` contract: when invoked with `--read-only`, the overlay must produce NO commits (diagnosis-only). Explicitly: "Never skip git hooks — see §9.2: if pre-commit rejects, let the commit fail; do not use `--no-verify`." Must name the `debugger`, `code-writer`, `refactor` agents as available. Commit.
- [ ] **3.6** Author `runtime/overlays/fix/expected.yaml`. `must_contain.agents: [debugger, code-writer, refactor]`, inherited base plugins, `must_not_contain.agents: [inquisitor, code-reviewer, comment-analyzer, pr-test-analyzer]`, `must_not_contain.plugins: [pr-review-toolkit]`. Commit.
- [ ] **3.7** Author `runtime/overlays/explain/Dockerfile`. `FROM ghcr.io/.../claude-runtime-base@sha256:${BASE_DIGEST}`. No agent imports (`overlays.explain.imports_from_private: {}` per §5.1). Copy explain overlay CLAUDE.md. Commit.
- [ ] **3.8** Author `runtime/overlays/explain/CLAUDE.md`. Scope: explain code, errors, logs, git history to the commenter. Read-only — never write files, never create commits, never push. Commit.
- [ ] **3.9** Author `runtime/overlays/explain/expected.yaml`. `must_contain.plugins` = the base plugin set (inherited). `must_not_contain.agents: [code-writer, debugger, refactor, inquisitor, code-reviewer]`. `must_not_contain.plugins: [pr-review-toolkit]`. Commit.
- [ ] **3.10** Append STAGE 3 to `runtime-build.yml`: `strategy.matrix.overlay: [review, fix, explain]` with `max-parallel: 3`, `continue-on-error: false` per §9.1. Use `dorny/paths-filter` to skip overlays whose `runtime/overlays/<name>/**` tree is unchanged AND whose base digest hasn't changed. Each job: `docker build` with `--build-arg BASE_DIGEST=${{ needs.stage2.outputs.base_digest }}`, push `:pending-<pubsha>`, then STAGE 4 smoke with the overlay's `expected.yaml`. Commit.
- [ ] **3.11** Dry-run STAGE 1→2→3→4 for all overlays via `workflow_dispatch(images=all)`. Assert three pending-tags land, all smoke tests pass, all inventory assertions pass. Then edit `runtime/overlays/review/expected.yaml` to include `code-writer` under `must_contain.agents` — re-run and confirm the review overlay STAGE 4 fails loudly (inventory mismatch). Revert.
- [ ] **3.12** **Deferred.** CODEOWNERS-based demonstration of the §10.2 ownership split is deferred to issue #137 ("Evaluate bot-based enforcement for §10.2 'different eyes' guarantee"). During Phase 3 execution, skip this task and note in the Phase 3 PR body that the inventory assertions (`must_contain` / `must_not_contain`) still provide post-merge mechanical enforcement; pre-merge "different eyes" enforcement follows the outcome of #137.

### Acceptance criteria

- [ ] Three overlay images (`:pending-<pubsha>`) build, push, smoke-test green
- [ ] Inventory assertions reject a deliberate "import `code-writer` into review" edit
- [ ] Each `expected.yaml` negative assertion (`must_not_contain`) catches at least one intentional regression in dry-run
- [ ] `actionlint` passes

---

## Phase 4 — Router composite action

**Suggested sub-issue title:** `Phase 4: claude-command-router/ composite action + declarative JSON test corpus`
**Depends on:** Phase 1 (for the manifest schema — the router's `overlays` output enum must match the manifest's known overlay names to survive schema validation)
**Blocks:** Phase 5 (tag-respond workflow)
**Parallelizable:** YES — can run concurrently with Phases 2 and 3.

### Goal

Replace the `tag-claude/` generalist with a verb-routing composite action that parses the comment body into `{overlay, status, mode}` outputs. This is pure string logic — no containers needed. Complete behavior is specified in §8.1–§8.3; the JSON corpus at `claude-command-router/tests/cases.json` (see spec §10.3) is the executable spec.

### Files

- Create: `claude-command-router/action.yml`
- Create: `claude-command-router/lib/parse.sh` — sourceable bash function implementing §8.1 verb-scan + --read-only logic (authored in task 4.4b)
- Create: `claude-command-router/lib/filler_words.txt`
- Create: `claude-command-router/tests/cases.json`
- Create: `claude-command-router/tests/run-cases.sh`
- Create: `.github/workflows/test.yml` (new CI workflow that runs `./claude-command-router/tests/run-cases.sh`; no apt-get install)

### Tasks

- [ ] **4.1** Author `claude-command-router/lib/filler_words.txt` with an initial lowercase word list: `please, can, you, go, help, and, also, me, a, the, linter, ci`. One word per line. Commit.
- [ ] **4.2** Author `claude-command-router/action.yml` as a composite action. Inputs: `comment_body` (string, required), `authorized_users` (string, optional). Steps: (a) delegate to `./check-auth` before any parsing — emit `status=unauthorized` on fail; (b) locate first `@claude` (case-insensitive), emit `status=malformed` if none; (c) tokenize tail on whitespace, scan for first known-verb match against `{review, fix, explain}`, skip any token (including filler words); emit `status=unknown_verb` if scan exhausts; (d) continue scanning for `--read-only` token — emit `mode=read-only` iff found AND `overlay=fix`, otherwise `mode=apply`; (e) emit `overlay`, `status`, `mode` as outputs per §8.1. Commit.
- [ ] **4.3** **§13 Q9 decision — `mode` output naming.** The inquisitor pass flagged `mode` as conflating commit-policy with a verb dimension. Decision for v1: **keep `mode: apply | read-only`** — renaming before shipping is premature without a second orthogonal flag in hand. Add a TODO comment in `action.yml` near the output definition referencing §13 Q9 and noting that the rename (candidate: `commit_policy`) will land when a second orthogonal flag (`--draft`, etc.) is introduced. Commit.
- [ ] **4.4** Author `claude-command-router/tests/cases.json`. Translate every row of the §8.1.1 Examples table plus every case in §10.3 into a JSON object of shape `{name, input, expect: {overlay, status, mode}}`. 15+ cases minimum. Commit.
- [ ] **4.4b** Author `claude-command-router/lib/parse.sh` — a sourceable bash function (e.g. `parse_comment()`) implementing §8.1 verb-scanning + `--read-only` scanning rules. Pure function: reads comment body from argv, echoes pipe-delimited `overlay|status|mode`. `action.yml` sources this file and writes the parsed fields to `$GITHUB_OUTPUT`. Commit.
- [ ] **4.5** Author (or append to) `.github/workflows/test.yml`: `runs-on: ubuntu-latest`, single job whose only step is `bash ./claude-command-router/tests/run-cases.sh`. Install nothing — jq and bash are preinstalled on `ubuntu-latest`. Commit.
- [ ] **4.6** Dry-run `test.yml` on the branch — must go green before merge. Then flip one `expect` field in `cases.json`, push, confirm the workflow fails; revert.
- [ ] **4.7** Update `CLAUDE.md` "Architecture → Actions" table: add a row for `claude-command-router/` with its responsibility. Deprecation note for `tag-claude/` goes in Phase 7, not here.

### Acceptance criteria

- [ ] `claude-command-router/action.yml` composite exists and is invokable via `uses: ./claude-command-router`
- [ ] `./claude-command-router/tests/run-cases.sh` passes on CI
- [ ] Every row of §8.1.1 Examples and §10.3 has at least one JSON case (15+ cases minimum)
- [ ] No new runner dependencies introduced (`bash` + `jq` only, both preinstalled on `ubuntu-latest`)
- [ ] §13 Q9 has a recorded decision (keep `mode` for v1) with a TODO pointer in `action.yml`
- [ ] `actionlint` passes on `test.yml`

---

## Phase 5 — Reusable workflow wiring

**Suggested sub-issue title:** `Phase 5: digest-pin reusable workflows + tag-respond caller + mapping table`
**Depends on:** Phase 3 (for the overlay images to `container:`-pin) and Phase 4 (for the router composite action that `claude-tag-respond.yml` invokes)
**Blocks:** Phase 6

### Goal

Every reusable workflow that calls Claude now `container:`s into the correct overlay image pinned by SHA256 digest. The `claude-tag-respond.yml` caller uses the router's output to dispatch to the matching overlay. This is the first phase that exposes the new runtime to consumers.

### Files

- Modify: `.github/workflows/claude-pr-review.yml` (REPLACE content with container-pinned form per §7.2)
- Modify: `.github/workflows/claude-apply-fix.yml` (REPLACE — pin fix overlay)
- Modify: `.github/workflows/claude-lint-failure.yml` (REPLACE — pin fix overlay, both paths per §7.5)
- Create: `.github/workflows/claude-ci-failure.yml` (NEW reusable-workflow form; the existing `ci-failure.yaml` stays until Phase 7)
- Create: `.github/workflows/claude-tag-respond.yml` (NEW; pattern per §8.2)

### Tasks

- [ ] **5.1** **Verify §13 Q2 — `container:` expression support.** Before authoring `claude-tag-respond.yml`, author a minimal no-op test workflow in a throwaway branch: `container: ghcr.io/.../claude-runtime-${{ needs.route.outputs.overlay }}@sha256:${{ needs.route.outputs.digest }}` with a `route` job that just emits the values. Run it. If expressions are supported, proceed to §5.3. If not, implement the §13 Q2 fallback: three discrete `dispatch-<verb>` jobs with hard-coded containers, gated on `if: needs.route.outputs.overlay == '<verb>'`. Record the outcome in the Phase 5 PR body. Commit or scrap the throwaway branch.
- [ ] **5.2** **Verify §13 Q3 — `claude-code-action` `executable_path`.** Pull the latest `anthropics/claude-code-action@v1` input schema (via `mcp__plugin_context7_context7__query-docs` or direct repo inspection). If `executable_path` is a documented input, prefer passing it explicitly over relying on `PATH_TO_CLAUDE_CODE_EXECUTABLE` env alone for clarity. If not, document the decision in the workflow comment. Record outcome in the Phase 5 PR body.
- [ ] **5.3** Replace `.github/workflows/claude-pr-review.yml` with the §7.2 shape: `on: workflow_call` with `CLAUDE_CODE_OAUTH_TOKEN` secret, `container: ghcr.io/cbeaulieu-gt/claude-runtime-review@sha256:<digest>` (the digest is whatever the most recent base + review promoted pair is), workflow-level `permissions: { contents: read, pull-requests: write }` per CLAUDE.md "Permissions must be declared at the workflow level", single job that `checkouts@v4` and invokes `./pr-review`. Commit.
- [ ] **5.4** Replace `.github/workflows/claude-apply-fix.yml` analogously — pins fix overlay digest, invokes `./apply-fix`, workflow-level `permissions: { contents: write, pull-requests: write }`. Commit.
- [ ] **5.5** Replace `.github/workflows/claude-lint-failure.yml` — pins fix overlay digest, invokes `./lint-failure` with the mode flag passed through so the same image handles both read-only and auto-apply paths per §7.5. Commit.
- [ ] **5.6** Create `.github/workflows/claude-ci-failure.yml` — reusable-workflow form (`on: workflow_call`) pinning fix overlay digest; may optionally dispatch a downstream `fix` job per §7.5. The existing `ci-failure.yaml` stays intact until Phase 7. Commit.
- [ ] **5.7** Create `.github/workflows/claude-tag-respond.yml` per §8.2. Two jobs: `route` (uses `./claude-command-router`) and `dispatch` (conditional on `needs.route.outputs.status == 'ok'`, `container:` pinned per the §5.1 verification outcome, calls the appropriate verb action). Per §5.1 fallback path, dispatch may need to be three jobs instead of one. Commit.
- [ ] **5.8** Wire the digest values. Manually read the digest labels from the most recent `:pending-<pubsha>` set pushed by Phase 3's dry-run (the eventual Phase 6 digest-bump-PR automation replaces this step). Pin each workflow. **After pinning but before committing**, verify every pinned digest resolves to a real pushed image: `docker pull ghcr.io/cbeaulieu-gt/claude-runtime-review@sha256:<pinned-digest>` for the review digest, and the same for fix and explain. If any digest fails to pull (e.g. `manifest unknown` or `unauthorized`), the copy-paste from STAGE 2/3 job outputs is wrong — **do not commit** until every digest resolves cleanly. This catches the most common Phase 5 failure mode (wrong image, wrong arch, or a digest that was GC'd) before the wire-up hits CI. Commit.
- [ ] **5.9** **Dogfooding validation.** Merge the Phase 5 PR into `main`. The next PR opened against this repo automatically exercises `claude-pr-review.yml` against the new review overlay. Observe: is the review output qualitatively different from the v1 action output? Capture one transcript for Section 2 feedback signal (§10.5). If output degrades noticeably, block Phase 6 and open an issue.
- [ ] **5.10** Update `README.md` "Required secrets" and any consumer-facing docs to reflect that the runtime is now container-backed. Emphasize to consumers that the interface has not changed — one `uses:` line + the OAuth secret.

### Acceptance criteria

- [ ] All five reusable workflows (`claude-pr-review`, `claude-apply-fix`, `claude-lint-failure`, `claude-ci-failure`, `claude-tag-respond`) are container-pinned by digest
- [ ] §13 Q2 outcome recorded; workflow uses either expression-in-`container:` or the discrete-jobs fallback
- [ ] §13 Q3 outcome recorded; `executable_path` is used explicitly if supported, env-only otherwise
- [ ] This repo's own PRs trigger `claude-pr-review.yml` against the new review overlay image; one sample transcript captured for feedback review
- [ ] `actionlint` passes on all modified workflows

---

## Phase 6 — Promotion, rollback, freshness alarm, prune

**Suggested sub-issue title:** `Phase 6: digest-bump-PR automation + rollback.yml + freshness alarm + prune-pending.yml`
**Depends on:** Phase 5 (the digest-bump-PR automation replaces the manual Phase 5 digest wiring — automating it before the wiring exists is backwards)
**Blocks:** Phase 7

### Goal

Automate the promotion step (collect digests → open a single PR bumping all four `@sha256:<digest>` references atomically), plus provide the operational safety net: targeted rollback, orphan-tag cleanup, and the weekly staleness alarm for the pinned private ref.

### Files

- Create: `runtime/rollback.yml`
- Create: `runtime/check-private-freshness.yml`
- Create: `runtime/prune-pending.yml`
- Modify: `.github/workflows/runtime-build.yml` (append STAGE 5 — digest-bump PR)

### Tasks

- [ ] **6.1** Append STAGE 5 to `runtime-build.yml` per §6.2 STAGE 5. After all STAGE 4 smokes pass, collect the four digests from STAGE 2 + STAGE 3 outputs. Use `peter-evans/create-pull-request@v5` (pin by SHA) to open a PR against `main` titled `promote: runtime images @<pubsha>` whose diff updates the `@sha256:<digest>` references in ALL five reusable workflows (one digest per image; note `claude-lint-failure.yml`, `claude-apply-fix.yml`, `claude-ci-failure.yml` all reference the same fix digest). Single commit per §6.2 STAGE 5. PR body: lists the four images + digests + the OCI labels pulled from each. Commit.
- [ ] **6.2** Verify STAGE 5 on a dry-run build: `workflow_dispatch(images=all)` completes through STAGE 5, a digest-bump PR appears, the diff is exactly the expected digest updates. Close the PR without merging for now (merge happens during Phase 7 cutover).
- [ ] **6.3** Author `runtime/rollback.yml`. `on: workflow_dispatch` with input `target_pubsha`. Steps: for each image, call GHCR API to read the `:<target_pubsha>` digest (or parse OCI labels), then open a PR reverting all four `@sha256:<digest>` references to the old set — same single-commit pattern as STAGE 5 but in reverse. PR body names the prior digest-bump PR being rolled back from. Commit.
- [ ] **6.4** Dry-run rollback: assume Phase 5 wired digest set A. Manually promote a no-op second digest set B by running the build + merging the digest-bump PR. Then run `rollback.yml(target_pubsha=<A pubsha>)`. A new PR appears that reverts to set A. Merge → assert consumer workflows now pull set A images. Re-promote back to B to restore head state.
- [ ] **6.5** Author `runtime/check-private-freshness.yml` per §11.3. `on: schedule: '0 8 * * 1'` (Monday 08:00 UTC). Steps: parse current pinned `ci-v*` from `runtime/ci-manifest.yaml`, query `cbeaulieu-gt/claude_personal_configs` via REST for that tag's commit SHA + date + `main` HEAD SHA + date. **§13 Q7 — narrow the denominator:** compute `git log --oneline <pinned-sha>..<main-head-sha> -- <imports_from_private paths joined>`. If the resulting log is non-empty AND the calendar gap exceeds 14 days, open a `Stale private-ref: ci-v<version> is N days behind main on imported paths` issue via `gh issue create`. Dedupe by title. Commit.
- [ ] **6.6** Author `runtime/prune-pending.yml` per §9.4. `on: schedule: '0 2 * * *'`. For each of the four GHCR packages, list `pending-*` tags, delete those older than 30 days. Never touches `:<pubsha>` or `@sha256:` refs. Commit.
- [ ] **6.7** **Address §13 Q5 — marketplace SHA bump cadence.** Document the decision in a new section of `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` (via amendment PR — small follow-up) or as a comment block near `sources.marketplace.ref` in `ci-manifest.yaml`: "Manually bumped on observed value; every bump requires the `git diff` review artifact per §10.2 `Marketplace bump review containment`." Do NOT automate — deliberate manual process. Commit.
- [ ] **6.8** **Address §13 Q4 — GHCR push from forked PR.** Document in the Phase 6 PR body: "Deferred — builds are triggered from `main` or `workflow_dispatch`, never from forked PRs; no auth path needed for v1. Revisit when the first external fork attempts to contribute runtime content." No workflow changes needed. Note the deferral as an item in the Phase 7 wrap-up checklist.
- [ ] **6.9** **One-time rollback rehearsal before Phase 7 cutover.** Before any v2.x.y release, exercise the rollback path deliberately: (a) run `workflow_dispatch(images=all)` to produce a throwaway second digest set; (b) merge the resulting STAGE 5 digest-bump PR so consumer workflows now pin the new set; (c) observe one `claude-pr-review.yml` run on this repo to confirm the new digest boots; (d) run `rollback.yml(target_pubsha=<previous pubsha>)`; (e) merge the resulting revert PR; (f) observe the next `claude-pr-review.yml` run uses the prior digest set. Capture the timing, any surprises, and the exact digest transitions in a write-up appended to the Phase 6 PR body. Rollback is critical-path, and a rehearsal done before the first real incident is the only evidence that the documented procedure works as specified.

### Acceptance criteria

- [ ] STAGE 5 dry-run produces a clean digest-bump PR against `main`
- [ ] `rollback.yml` dry-run successfully reverts from set B to set A and back
- [ ] `check-private-freshness.yml` scheduled; first run produces no issue (ref is fresh); simulated stale-ref input produces one issue with the expected title
- [ ] `prune-pending.yml` scheduled; dry-run deletes no tags (none older than 30 days yet) but logs the candidates it would delete
- [ ] §13 Q5 recorded as manual; §13 Q7 implemented with path-scoped denominator; §13 Q4 recorded as deferred
- [ ] Rollback rehearsal completed end-to-end; write-up included in the Phase 6 PR body or linked from it
- [ ] `actionlint` passes on all new workflow files

---

## Phase 7 — Deprecate v1 action path + cut v2.x.y

**Suggested sub-issue title:** `Phase 7: dogfood, delete legacy tag-claude/ + ci-failure.yaml, cut v2.x.y, update v2 floating tag`
**Depends on:** Phase 6 (rollback tooling must exist AND be rehearsed before production cutover — see task 6.9)
**Blocks:** nothing (terminal phase)

### Goal

Confirm the runtime behaves correctly on this repo's own PRs across at least one full release cycle, delete the v1 action entrypoints, cut a `v2.x.y` tag capturing the now-wired reusable workflows with their digest pins, move `v2` floating tag to the new HEAD.

### Files

- Delete: `tag-claude/` (entire directory — replaced by `claude-command-router/` + `claude-tag-respond.yml`)
- Delete: `ci-failure.yaml` (replaced by `claude-ci-failure.yml` reusable workflow)
- Delete: `apply-fix.yml` (replaced by `claude-apply-fix.yml` reusable workflow) — only if no consumer still calls it; grep-verify first
- Modify: `README.md` (update architecture table; remove v1 action references; note the runtime is the default)
- Modify: `CLAUDE.md` (update "Architecture → Actions" table to remove deprecated entries)

### Tasks

- [ ] **7.1** Run dogfooding for one release cycle — both conditions must be met: (a) **at least two weeks of calendar time** for drift and staleness windows to exercise the `check-private-freshness.yml` alarm and for any latent reproducibility issues to surface, AND (b) **at least one prod merge that touches `pr-review/`, `apply-fix/`, or `lint-failure/`** so the runtime has been exercised on a realistic code path, not just idle dogfooding. If neither condition is met, extend the window; if only one is met, wait for the other before cutting v2.x.y. Sample 5 PR review transcripts via the §10.5 artifact retention. Qualitative check: reviews land at expected verbosity, catch inquisitor-level architectural concerns (per review overlay persona), never invoke forbidden agents (per `must_not_contain` assertions). If a transcript shows drift, open a Phase-6a bug-fix sub-issue and defer Phase 7 cutover.
- [ ] **7.2** Re-run the full STAGE 1→5 pipeline on `main` HEAD. Confirm the merged digest-bump PR from Phase 6 is still accurate.
- [ ] **7.3** `grep -r "uses:.*tag-claude"` in this repo and any known consumers to confirm no callers remain. Same for `ci-failure.yaml` and `apply-fix.yml`. If any caller exists, migrate it first in a preceding PR; don't skip this step.
- [ ] **7.4** Delete `tag-claude/`, `ci-failure.yaml`, `apply-fix.yml` (if grep clean). Commit as a single deletion PR referencing this plan.
- [ ] **7.5** Update `CLAUDE.md` architecture table: remove `tag-claude/` row; ensure `claude-command-router/` + the reusable workflow list is accurate. Update `README.md` similarly. Remove the "v1.8.0 / v1" row from the versioning section OR move it to a "Legacy — no further updates" sub-section, whichever is more accurate to the planned support timeline.
- [ ] **7.6** Tag the HEAD: `git tag -a v2.1.0 -m "CI runtime v2.1.0"` (or whatever the next semver is) and move `v2` to the same HEAD. Force-push both tags per CLAUDE.md "Versioning" section. Create a GitHub release against `v2.1.0` with release notes summarizing the runtime delivery, linking to PR #131 (spec), this plan, and the key sub-issue PRs.
- [ ] **7.7** Close Milestone #7 (containerized Claude Code CI runtime) and Epic #130 with a summary comment linking to the v2.1.0 release and the top 3 follow-up items (collapse trigger per §3.2, marketplace bump cadence confirmation per §13 Q5, fork-PR auth per §13 Q4).

### Acceptance criteria

- [ ] Minimum two weeks of dogfooded `claude-pr-review.yml` runs on this repo's own PRs, transcripts reviewed
- [ ] `tag-claude/`, `ci-failure.yaml`, `apply-fix.yml` deleted with no broken consumers
- [ ] `v2.1.0` tag exists; `v2` floating tag moved to it; GitHub release published
- [ ] Milestone #7 closed; Epic #130 closed with a summary comment
- [ ] `actionlint` passes; all `@sha256:<digest>` pins remain valid

---

## Open questions mapping (Section 13 of the spec)

| # | Spec question | Plan phase | Type |
|---|---|---|---|
| 1 | `HOME=/opt/claude` vs `/root` Claude Code config discovery | Phase 2, task 2.4 | Verification (live CLI test) — fallback path specified |
| 2 | `container:` expression support at job level | Phase 5, task 5.1 | Verification (throwaway workflow test) — discrete-jobs fallback specified |
| 3 | `claude-code-action` `executable_path` input | Phase 5, task 5.2 | Verification (docs + schema check) — env-only fallback specified |
| 4 | GHCR push from a forked PR | Phase 6, task 6.8 | **Deferred** — no forks expected in v1; revisit when first external fork arrives |
| 5 | Marketplace SHA bump cadence | Phase 6, task 6.7 | Decision recorded: **manual on observed value**; `git diff` review artifact required per §10.2 |
| ~~6~~ | ~~`claude-lint-failure.yml` overlay split~~ | — | **Resolved in spec** — single `fix` overlay with `--read-only` flag (§7.5) |
| 7 | Staleness alarm denominator | Phase 6, task 6.5 | Implemented: `git log` scoped to `imports_from_private.*` paths |
| 8 | GHCR immutability preflight retry/backoff | Phase 1, task 1.5 | Implemented: 3 attempts exponential backoff, `SKIP_GHCR_IMMUTABILITY` emergency flag |
| 9 | Router `mode` output naming | Phase 4, task 4.3 | Decision recorded: **keep `mode` for v1**; rename candidate (`commit_policy`) deferred to when a second orthogonal flag arrives; TODO pointer in `action.yml` |
| 10 | Non-root smoke UID pin | Phase 2, tasks 2.5 + 2.6 | Implemented: dynamic UID capture via `capture-runner-uid.sh` used by `smoke-test.sh` |

Every actually-open question has either (a) a scheduled verification task with a fallback behavior already specified, or (b) an explicit deferral with a re-evaluation trigger. No question is left "to be decided later" without a named path forward.

---

## Start-here anchor

**First sub-issue to open under Milestone #7:** `Phase 1: scaffold runtime/ tree + ci-manifest schema + STAGE 1 pipeline`.

This is the critical-path entry point — every other phase depends on it. Phase 4 (router) can be opened in parallel as soon as Phase 1 locks the `overlays` enum list in the schema, but Phase 1 is the first commit of real runtime code in the repo.

---

## Self-review checklist (done by plan author before submission)

- [x] **Spec coverage** — all 16 spec sections are reflected in plan tasks: §1 Context → plan preamble; §2 Goals → plan goals; §3 Architecture → Phases 2 + 3 file structure; §4 Source-of-truth → Phase 1 manifest + Phase 2 `extract-shared.sh`; §5 Manifest → Phase 1 tasks 1.2–1.4; §6 Build pipeline → Phases 1 STAGE 1, 2 STAGE 2+4, 3 STAGE 3, 6 STAGE 5; §7 Consumer experience → Phase 5; §8 Router → Phase 4; §9 Error handling → Phase 6 rollback + §5 `continue-on-error: false`; §10 Testing → Phase 4 JSON corpus + Phase 3 inventory + Phase 1 actionlint; §11 Versioning → Phase 6 freshness + Phase 7 tagging; §12 Migration → this plan IS §12 expanded; §13 Open questions → §"Open questions mapping" above; §14–§16 Appendices → referenced by specific tasks.
- [x] **Placeholder scan** — no "TBD", no "figure it out later", no "similar to Task N", no unexplained decisions. The `.sh` vs `.py` choice for `validate-manifest` is left to implementation (§5.2 itself punts it with "extension TBD"); every other decision is concrete.
- [x] **Type/name consistency** — same env var names throughout (`PATH_TO_CLAUDE_CODE_EXECUTABLE`, `HOME`, `GH_PAT`, `CLAUDE_CODE_OAUTH_TOKEN`); same file paths (`runtime/ci-manifest.yaml`, `runtime/scripts/extract-shared.sh`); same image names (`claude-runtime-base|review|fix|explain`); `mode` output kept consistently throughout Phase 4 and Phase 5.
- [x] **Dependency graph** — explicit; Phase 4 parallelizability called out; no cycles.
- [x] **§13 coverage** — all 9 actually-open questions mapped to a phase/task OR an explicit deferral with trigger.

---

## Execution handoff

This plan is a **phase decomposition plan**, not an atomic execution plan. Recommended execution path:

1. **Merge this plan** into `main` via the companion PR for issue #133.
2. **Open 7 sub-issues** under Milestone #7, one per phase, each copying its phase section from this plan into its body as the starting scope. Link each to epic #130 via `Refs #130`.
3. **For each sub-issue at execution time**, the implementing engineer (or agent) creates a fresh branch/worktree and invokes `superpowers:writing-plans` inside it to produce a phase-specific line-by-line plan at `docs/superpowers/plans/<phase-slug>.md`. That sub-plan then feeds `superpowers:subagent-driven-development` or `superpowers:executing-plans` depending on whether the phase is going to be executed in many small subagent sessions or inline.
4. **Track spec amendments.** Any change surfaced during implementation that warrants a spec update — e.g. Phase 6 task 6.7 formally documenting marketplace-SHA bump cadence, or a Phase 2 task 2.4 outcome that changes the `HOME` discovery behavior — ships as a small follow-up PR against `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md`. Each amendment PR references the phase that surfaced the change and the sub-issue that closed that phase, so the spec remains the single source of truth rather than drifting behind a series of in-flight implementations.
5. **Track phase completion** by checking off the top-level `- [ ]` items in this master plan as each sub-issue's PR merges. Do not maintain a separate status document.

Two further-detail options exist for this specific plan PR if reviewers want more than phase-level depth before merging:

1. **Subagent-Driven expansion** — I dispatch a fresh subagent per phase to produce phase-specific sub-plans inline in this PR. Heavier review surface; slower to merge.
2. **Merge now, expand per sub-issue** — recommended. The plan decomposes correctly at this level; deeper expansion belongs in each sub-issue's own branch.

**Which approach?** Defaulting to option 2 unless the reviewer requests otherwise.
