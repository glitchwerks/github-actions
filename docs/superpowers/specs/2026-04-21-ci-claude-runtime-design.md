# CI Claude Runtime — Design Spec

**Epic:** [#130](https://github.com/cbeaulieu-gt/github-actions/issues/130)
**Milestone:** #7
**Status:** Design complete, pending user review
**Date:** 2026-04-21
**Author:** Claude (on behalf of @cbeaulieu-gt)
**Version:** 1.0

---

## 1. Context

The `cbeaulieu-gt/github-actions` library provides reusable Claude-powered automation actions. Today each action invokes `anthropics/claude-code-action@v1` on a stock `ubuntu-latest` runner, which means the model runs with whatever stock persona and toolset that action brings — no curated skills, agents, plugins, or memory are available.

The user maintains a rich local Claude Code setup (~22 plugins, a personal skill/agent library, accumulated feedback memory). We want CI to benefit from a **curated subset** of that setup, delivered via a purpose-built container image, so that automated PR reviews, fix applications, lint diagnoses, and tag-responses all execute against a persona that understands this family of repos — while remaining **intentionally differentiated** from the user's local persona so CI acts as "a different set of eyes."

The personal config library lives in a private repo (`cbeaulieu-gt/claude_personal_configs`). Duplicating it into this public repo is unacceptable; pulling blindly from `main` is also unacceptable because the private repo iterates rapidly and frequently holds in-progress material. This design addresses both.

## 2. Goals and non-goals

### Goals

1. **Context correctness (PRIMARY)** — each CI action runs with the minimal correct Claude context for its job, with no drift or persona bleed between actions.
2. **Deterministic, shared-base behavior** — all overlays derive from a common base so every reviewer starts from the same foundation, with project-specific knowledge layered on from the consumer repo.
3. **Reproducibility** — a given workflow release produces the same result when re-run, within the limits of a non-deterministic model.
4. **Single source of truth** — no duplication between public (`github-actions`) and private (`claude_personal_configs`). Public imports from private via an explicit manifest.
5. **Pull-based update flow** — the public repo decides when to pull a new snapshot of private. The private repo never triggers a CI rebuild.
6. **Consumer simplicity** — consumers call a reusable workflow with one `uses:` line and a secret. Container images, env vars, and internal plumbing are not part of the consumer surface.

### Non-goals (v1)

- **Local-persona parity.** CI is a different set of eyes, not a clone.
- **Agent memory / learned feedback.** Ephemeral runners cannot accumulate memory; v1 leaves memory out entirely. Feedback signal comes from transcript review.
- **Startup latency optimization.** Pulled images are typically < 2 GB; cold pull cost is acceptable.
- **Self-hosted runners.** Public GHA runners only, for sandboxing.
- **External-consumer compatibility matrix.** Deferred until at least one external consumer exists.
- **Operational cost, storage, rate limiting.** GHCR storage (5 images × tags × ~1–2 GB each), Claude API usage, and rate-limit handling are monitored post-launch rather than specified here.

### Priority ordering

Per brainstorming sign-off:

| Priority | Concern |
|---|---|
| **A (primary)** | Context correctness — each unit has minimal correct context |
| **B** | Deterministic behavior — shared base + repo-specific project knowledge |
| **C** | Reproducibility / maintenance — declarative manifest, version pinning |
| **D (lowest)** | Startup time |

## 3. Architecture overview

### 3.1 Image hierarchy

We ship **one base image + one overlay per action verb**:

```
ghcr.io/cbeaulieu-gt/claude-runtime-base              # shared foundation
├── claude-runtime-review                             # PR review
├── claude-runtime-fix                                # apply-fix + lint-apply
├── claude-runtime-explain                            # tag-respond default / @claude explain
└── claude-runtime-diagnose                           # lint-failure + ci-failure
```

The base carries: Claude Code CLI binary, Node.js 20, a curated plugin set (context7, github, microsoft-docs, typescript-lsp, skill-creator, security-guidance), shared skills imported from private (e.g. `git`, `python`), shared agents (`ops`), a shared `CLAUDE.md`, and the `software-standards.md` reference.

Each overlay carries: verb-specific agents, verb-specific plugins (e.g. `pr-review-toolkit` in the review overlay — a full install that *replaces* the personal `code-reviewer` persona), a verb-specific `CLAUDE.md` that scopes behavior to that action.

### 3.2 Why shared base + overlays (not monolith, not fully isolated)

Three options were evaluated:

| Option | Choice | Why |
|---|---|---|
| **Monolithic single image with all context** | Rejected | Context bleed — every action has every agent available, leading to persona drift. Mechanism-dependent isolation (rely on CLAUDE.md to "please only use these agents") is not enforceable. |
| **Fully isolated per-action images, no shared layer** | Rejected | Drift between overlays: the base context every reviewer should agree on has no single definition. Maintenance cost grows linearly with actions. |
| **Shared base + per-action overlays (chosen)** | ✅ | Physical isolation of verb-specific context (cannot bleed: it's not in the image). Shared base guarantees consistent foundation. Docker layer caching amortizes size cost. |

Physical isolation > mechanism-dependent isolation. When a review runs, it is literally impossible for `code-writer` to be invoked — the agent file is not on disk.

### 3.3 Consumer context composition (runtime)

At job time, three context layers compose:

1. **Base CLAUDE.md** (in base image, from `runtime/shared/CLAUDE-ci.md`)
2. **Overlay CLAUDE.md** (in overlay image, from `runtime/overlays/<verb>/CLAUDE.md`)
3. **Consumer repo CLAUDE.md** (mounted via `actions/checkout@v4` — project-specific knowledge)

Layer 3 is the "project-specific knowledge from the actual repo" that makes a generic review overlay useful for *this specific codebase*.

## 4. Source-of-truth model

### 4.1 ELT with public as authoritative

The public repo (`cbeaulieu-gt/github-actions`) is authoritative for CI configuration. It **imports from** the private repo (`cbeaulieu-gt/claude_personal_configs`) as a declarative dependency.

```
┌─────────────────────────────────────────┐
│ cbeaulieu-gt/github-actions (public)    │  ← authoritative for CI
│                                         │
│   runtime/ci-manifest.yaml              │  ← declares what to import
│   runtime/shared/CLAUDE-ci.md           │  ← CI-specific, local
│   runtime/overlays/*/CLAUDE.md          │  ← CI-specific, local
│   runtime/base/Dockerfile               │
│   runtime/overlays/*/Dockerfile         │
│                                         │
│   imports ───────────────────────────────────→  cbeaulieu-gt/claude_personal_configs
│                                         │      (private, pinned by semver tag)
└─────────────────────────────────────────┘
```

### 4.2 Merge policy

When a path appears in both public (local) and private (imported), **public wins** with a WARN log line in the build output. Collisions are not errors — they are an intentional override mechanism for cases where CI needs a different version of a shared artifact.

Log format (one line per collision):

```
WARN merge_collision path=skills/git/SKILL.md
  source_public=runtime/shared/skills/git/SKILL.md (sha=abc123)
  source_private=claude_personal_configs/skills/git/SKILL.md (sha=def456, ref=ci-v1.2.3)
  resolution=public_wins
```

Aggregate count is appended to the GHA job summary: `Merge collisions: 3 (all resolved public_wins)`.

### 4.3 Version pinning

- **Private ref** is pinned in the manifest to a semver tag `ci-v<semver>` (e.g. `ci-v1.2.3`). The private repo is responsible for cutting these tags when content is CI-ready. **No default to `main`** — the manifest schema requires an explicit tag; builds fail fast if the tag is missing or malformed.
- **Marketplace ref** is pinned to a full commit SHA. Current pin: `f01d614cb6ac4079ec042afe79177802defc3ba7` (2026-04-21).
- **Public ref** (i.e. this repo's state during the build) is naturally pinned to the commit SHA that triggered the build.

All three refs are recorded as OCI labels on every built image:

```
org.opencontainers.image.source     = github.com/cbeaulieu-gt/github-actions@<pubsha>
dev.cbeaulieu-gt.ci.private_ref      = ci-v1.2.3
dev.cbeaulieu-gt.ci.private_sha      = <commit-sha-of-private-tag>
dev.cbeaulieu-gt.ci.marketplace_sha  = f01d614cb6ac4079ec042afe79177802defc3ba7
```

Any promoted image can be reproduced from its labels alone.

## 5. The manifest

### 5.1 Shape

`runtime/ci-manifest.yaml`:

```yaml
sources:
  private:
    repo: cbeaulieu-gt/claude_personal_configs
    ref: ci-v1.2.3                    # required; no default
  marketplace:
    repo: anthropics/claude-plugins-official
    ref: f01d614cb6ac4079ec042afe79177802defc3ba7

shared:
  imports_from_private:
    skills: [git, python]
    agents: [ops]
    claude_md: CLAUDE.md
    standards: standards/software-standards.md
  local:
    claude_md: runtime/shared/CLAUDE-ci.md
  plugins:
    install:
      - context7
      - github
      - microsoft-docs
      - typescript-lsp
      - skill-creator
    cherry_pick:
      security-guidance:
        paths:
          - hooks/hooks.json
          - hooks/security_reminder_hook.py

overlays:
  review:
    plugins:
      install: [pr-review-toolkit]            # P1: full install, replaces personal code-reviewer
    imports_from_private:
      agents: [inquisitor]                    # NOTE: code-reviewer comes from pr-review-toolkit, NOT imported from personal config — the "different eyes" principle is preserved
    local:
      claude_md: runtime/overlays/review/CLAUDE.md

  fix:
    imports_from_private:
      agents: [debugger, code-writer, refactor]
    local:
      claude_md: runtime/overlays/fix/CLAUDE.md

  explain:
    imports_from_private: {}
    local:
      claude_md: runtime/overlays/explain/CLAUDE.md

  diagnose:
    imports_from_private:
      agents: [debugger]
    local:
      claude_md: runtime/overlays/diagnose/CLAUDE.md

merge_policy:
  on_conflict: public_wins                    # or "error"
```

### 5.2 Schema (JSON Schema at `runtime/ci-manifest.schema.json`)

Asserted at build time (STAGE 1):

- `sources.private.ref` matches `^ci-v\d+\.\d+\.\d+$`
- `sources.marketplace.ref` matches `^[a-f0-9]{40}$`
- `overlays` keys ⊆ `{review, fix, explain, diagnose}`
- `merge_policy.on_conflict` ∈ `{public_wins, error}`
- `*.imports_from_private.agents` items ⊆ known-agent enum (typo-catcher)

### 5.3 Plugin install mechanisms

- **P1 — full install via marketplace**: entire plugin directory is copied into the image and registered as installed. Used when we want the plugin's persona to *replace* personal variants (e.g. `pr-review-toolkit` replaces the personal `code-reviewer` in the review overlay).
- **P2 — cherry-pick files**: copy specific files from a plugin directory. Used when only part of a plugin is needed. Example: the base image cherry-picks `security-guidance`'s `hooks/hooks.json` + `hooks/security_reminder_hook.py` (the PreToolUse hook targeting `.github/workflows/` injection) without installing the full plugin surface.

The manifest uses `plugins.install: [...]` for P1 and `plugins.cherry_pick: {...}` for P2.

## 6. Build pipeline

### 6.1 Trigger surface

- **`workflow_dispatch`** with inputs: `images` (`all` | `base` | `review` | `fix` | `explain` | `diagnose`), `private_ref_override`, `marketplace_ref_override` — for manual rebuilds, tested rebuilds, or emergencies
- **`push` to `main`** filtered by `dorny/paths-filter` on `runtime/**` — automatic rebuild when runtime sources change
- **NOT** triggered by the private repo. No `repository_dispatch` in either direction.

### 6.2 Stages

```
STAGE 1: CLONE SOURCES (parallel)
  ├── git clone github-actions @ pubsha
  ├── git clone claude_personal_configs @ ci-v1.2.3  (via GH_PAT)
  └── git clone claude-plugins-official @ <sha>
  + manifest schema validation (ajv)
  + import-path existence check

STAGE 2: BUILD BASE (sequential)
  ├── extract-shared.sh  (materializes shared/ tree per manifest, applies merge_policy)
  ├── docker build runtime/base --build-context=... --label=...
  └── push ghcr.io/.../claude-runtime-base:pending-<pubsha>
      capture base digest

STAGE 3: BUILD OVERLAYS (parallel matrix)
  for each overlay in (review, fix, explain, diagnose):
    ├── filtered by change detection (skip unchanged overlays)
    ├── docker build runtime/overlays/<name> --build-arg BASE_DIGEST=<digest>
    └── push ghcr.io/.../claude-runtime-<name>:pending-<pubsha>

STAGE 4: SMOKE TEST (parallel)
  for each image:
    ├── docker run --rm <image> claude -p "list agents + skills; exit"
    ├── assert counts non-zero
    └── inventory check against runtime/overlays/<name>/expected.yaml
        (must_contain + must_not_contain)

STAGE 5: PROMOTE
  for each image that passed smoke:
    ├── move :v1 tag to :pending-<pubsha>  (atomic)
    ├── also push immutable :<pubsha> tag
    └── open PR updating digest pin in .github/workflows/claude-*.yml
```

Pending tags (`pending-<pubsha>`) are retained 30 days for post-mortem. Immutable `:<pubsha>` tags are never pruned and serve as rollback targets.

### 6.3 Secrets

| Secret | Used by | Purpose |
|---|---|---|
| `GH_PAT` | STAGE 1 | Clone private repo |
| `GHCR_PUSH_TOKEN` | STAGE 2–5 | Push images to ghcr.io (or fallback to `GITHUB_TOKEN` with `packages: write`) |
| `CLAUDE_CODE_OAUTH_TOKEN` | STAGE 4 | Smoke test runs `claude` with a live token |

**Token permissions:** `GHCR_PUSH_TOKEN` should be a PAT or GitHub App token with `packages: write` scope. Use `GITHUB_TOKEN` as fallback when the build runs on the main branch where `GITHUB_TOKEN` has sufficient package permissions via `permissions: { packages: write }` in the workflow.

**Secret rotation** is an operational concern outside this spec — expired tokens cause hard failures with descriptive error annotations (see §9.1).

## 7. Consumer experience

### 7.1 Default path — reusable workflow

Consumer workflow:

```yaml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    uses: cbeaulieu-gt/github-actions/.github/workflows/claude-pr-review.yml@v2
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

That is the **entire** consumer surface. No `container:`, no `env:`, no image references, no path configuration.

### 7.2 Reusable workflow internals (hidden from consumer)

```yaml
# .github/workflows/claude-pr-review.yml  (in this repo)
on:
  workflow_call:
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN:
        required: true

jobs:
  review:
    runs-on: ubuntu-latest
    container: ghcr.io/cbeaulieu-gt/claude-runtime-review@sha256:<digest>  # Option B: digest pinned
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: ./pr-review
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

The container reference is pinned by digest (Option B). Every successful build opens a PR bumping these digests across the five reusable workflows, then a workflow release cut from that PR ships the new image to consumers. Consumers pinned to `@v2.x.y` get exactly the image digest that was in the repo at tag time — no silent drift.

### 7.3 Image ENV (hidden from consumer)

Base Dockerfile sets:

```dockerfile
ENV PATH_TO_CLAUDE_CODE_EXECUTABLE=/opt/claude/bin/claude \
    HOME=/opt/claude
```

These are inherited by every overlay and every process the container runs. Consumer workflows do not set them.

### 7.4 Form table (updated)

| Form | Location | Contains | Use when |
|---|---|---|---|
| Reusable workflow | `.github/workflows/claude-*.yml` | `container:` pin + permissions + concurrency + calls composite | Default consumer path — one `uses:` line |
| Composite action | `<name>/action.yml` | Pure logic, assumes `PATH_TO_CLAUDE_CODE_EXECUTABLE` and `HOME` are set via ENV | Consumer is managing their own container and embeds our action |

Composite actions remain container-agnostic — they assume only that `PATH_TO_CLAUDE_CODE_EXECUTABLE` and `HOME` are correctly set in the environment.

### 7.5 Workflow → overlay mapping

| Reusable workflow | Overlay image | Notes |
|---|---|---|
| `claude-pr-review.yml` | `review` | Direct consumer path for PR reviews |
| `claude-apply-fix.yml` | `fix` | Manual fix application |
| `claude-lint-failure.yml` (diagnose path) | `diagnose` | Lint failure → diagnosis comment |
| `claude-lint-failure.yml` (auto_apply path) | `fix` | Lint failure → diagnosis + auto-fix; the action internally switches containers or uses a multi-job composition (details in implementation plan) |
| `claude-ci-failure.yml` | `diagnose` | CI failure analysis; may optionally dispatch a `fix` job downstream |
| `claude-tag-respond.yml` | *(routed)* | Router dispatches to `review`, `fix`, `explain`, or `diagnose` overlay based on the verb in the comment |

Implementation note: the split path in `claude-lint-failure.yml` (diagnose vs auto-apply needing different overlays) is a concrete design detail that the implementation plan must resolve — either via two jobs with different `container:` values chained by `needs:`, or by using the `fix` overlay for both (since `fix` is a superset of `diagnose`'s diagnose-only needs). Tracked in Section 13 open questions.

## 8. The tag-respond router

The current `tag-claude/` action is a catch-all generalist. For the runtime-image world it becomes a **verb router**.

### 8.1 Router composite action

`claude-command-router/action.yml`:

- Parses the first verb after `@claude` in the triggering comment body
- Validates verb ∈ `{review, fix, explain, diagnose}`
- Outputs `overlay` (the matched verb) and `status` (`ok` | `unknown_verb` | `malformed` | `unauthorized`)
- Delegates authorization to the existing `check-auth/` action before dispatching
- First-verb-wins on ambiguous input (`@claude review and fix` → `review`)

The router lives in a composite action (not inline in the calling workflow) because the user's preference is to keep logic in actions — actions are composable, testable, and don't bloat workflows.

### 8.1.1 Parsing rules

The router applies the following rules to the triggering comment body:

- **Pattern:** `/@claude\s+(\w+)/i` — matches `@claude`, one or more whitespace characters, then captures the next word characters (letters, digits, underscore).
- **Case-insensitivity:** `@claude REVIEW`, `@claude Review`, and `@claude review` all match identically. The captured word is normalized to lowercase before verb-enum lookup.
- **Delimiter requirement:** `@claude-review` does NOT match — the pattern requires at least one whitespace character between `@claude` and the verb.
- **Whitespace tolerance:** `@claude   review` (multiple spaces, tabs) matches; the `\s+` quantifier is greedy.
- **First-match-wins:** If the comment contains multiple recognized verbs (e.g. `@claude review and also @claude fix`), the first capture is used.
- **Unknown verb:** If the captured word is not in `{review, fix, explain, diagnose}`, `status=unknown_verb` and the router posts a supported-verbs rejection.
- **No match:** If no `@claude` mention is present or no word follows it, `status=malformed`.

The bats test file at `claude-command-router/tests/router.bats` is the executable specification for these rules.

### 8.2 Caller workflow

`.github/workflows/claude-tag-respond.yml` is a thin caller:

```yaml
jobs:
  route:
    if: contains(github.event.comment.body, '@claude')
    runs-on: ubuntu-latest
    outputs:
      overlay: ${{ steps.r.outputs.overlay }}
      status:  ${{ steps.r.outputs.status }}
    steps:
      - uses: actions/checkout@v4
      - id: r
        uses: ./claude-command-router
        with:
          comment_body: ${{ github.event.comment.body }}
          authorized_users: ${{ inputs.authorized_users }}

  dispatch:
    needs: route
    if: needs.route.outputs.status == 'ok'
    runs-on: ubuntu-latest
    container: ghcr.io/cbeaulieu-gt/claude-runtime-${{ needs.route.outputs.overlay }}@sha256:<digest>
    # ... rest of dispatch
```

**Relative path note:** The router is invoked as `./claude-command-router` (relative) rather than the absolute `cbeaulieu-gt/github-actions/claude-command-router@v2` pattern used elsewhere. This is intentional — the router is only ever called from reusable workflows *within this library* after `actions/checkout@v4` has already checked out the library's own code, so the relative path resolves correctly. External consumers never reference the router directly; they go through `claude-tag-respond.yml`. The absolute-ref convention in CLAUDE.md applies to actions exposed to external consumers; internal-only plumbing can safely use relative paths.

(See Section 13 open question #2 regarding `container:` expression support at job level.)

### 8.3 Router error surface

| Input | Response |
|---|---|
| Unknown verb (`@claude cook me a pizza`) | Reply: `I don't recognize that command. Supported: review, fix, explain, diagnose.` Exit 0. |
| Malformed (bare `@claude`) | Reply with verb list. Exit 0. |
| Unauthorized caller | Polite rejection via `check-auth/`. Exit 0. |
| Ambiguous (`@claude review and fix`) | First-verb-wins. Documented behavior. |
| Valid verb but overlay image fails to pull | GHA-level failure on dispatch job — not the router's concern. |

## 9. Error handling and failure modes

### 9.1 Pre-promotion (safe to fail loudly — nothing consumed yet)

| Failure | Detection | Behavior |
|---|---|---|
| Missing private tag | STAGE 1 `git clone --branch` 404 | Hard fail: `Private ref 'ci-v1.2.3' not found — check claude_personal_configs tags`. |
| Manifest parse/schema error | STAGE 1 ajv | Hard fail with line/column. |
| Missing imported file | STAGE 1 path-existence check | Hard fail listing every missing path. Never silently skip. |
| Docker build error | Non-zero exit | Hard fail. Matrix default `continue-on-error: false` — one overlay failing blocks ALL promotion (never ship a partial set). |
| Smoke or inventory test failure | STAGE 4 | Hard fail. `pending-<pubsha>` retained 30 days; `:v1` not moved. |
| `GH_PAT` expired/revoked | STAGE 1 401/403 | Hard fail with distinct annotation: `GH_PAT authentication failed — rotate secret`. |

### 9.2 Post-promotion (blast radius = all consumers)

| Failure | Mitigation |
|---|---|
| Container pull fails | GHA-level; consumer workflows should set `timeout-minutes`. |
| `/opt/claude/bin/claude` missing | Caught by smoke test — should never reach promotion. If it does: rollback. |
| `HOME` drops config | Smoke test asserts non-zero skill/agent counts. **Highest-risk silent failure** — "image works but persona is empty, reviews come back generic." Inventory check must verify counts, not just existence. |
| Plugin load failure | Smoke test enumerates expected agents. If an expected agent is missing post-promotion: rollback. |
| `PATH_TO_CLAUDE_CODE_EXECUTABLE` mispointed in consumer | Only possible if consumer *explicitly overrides* the container ENV. Document: "Do not set these unless you know why." |
| Consumer git hook fails (pre-commit, commit-msg) | Expected — the `fix` overlay respects consumer hooks and never uses `--no-verify`. If a hook rejects, the commit is not created (same as local behavior). Overlay `CLAUDE.md` documents: "Never skip hooks." |

### 9.3 Rollback

`runtime/rollback.yml` (`workflow_dispatch`, inputs: `image`, `target_sha`):

```bash
crane tag ghcr.io/cbeaulieu-gt/claude-runtime-<image>:<target_sha> v1
```

No rebuild. `:<target_sha>` is immutable and already pushed. Rollback is atomic per-image.

### 9.4 Orphaned pending tag cleanup

`runtime/prune-pending.yml` (`schedule: '0 2 * * *'`):

- Lists all `pending-<sha>` tags older than 30 days
- Deletes any not currently aliased by `:v1`
- Never prunes `:<pubsha>` (rollback targets)

### 9.5 Merge-policy collisions

`WARN merge_collision` lines emitted during build (not failures — collisions are intentional). Aggregated count appears in the GHA job summary for visibility.

## 10. Testing strategy

### 10.1 v1 test layers

| Layer | What it tests | Where it runs | Blocking? |
|---|---|---|---|
| **T1 — Manifest schema** | YAML parses, required keys present, enums valid | STAGE 1 | Yes |
| **T2 — Import-path existence** | Every `imports_from_private` path exists at the pinned ref | STAGE 1 | Yes |
| **T3 — Smoke test** | Claude binary runs, `HOME` resolves, skill/agent counts non-zero | STAGE 4 | Yes |
| **T4 — Inventory assertions** | Each overlay contains `must_contain`, does NOT contain `must_not_contain` | STAGE 4 | Yes |
| **T5 — Router unit tests** | `bats` tests for verb parsing: happy path, unknown, malformed, ambiguous | `test.yml` | Yes |
| **T6 — Dogfood (free)** | Each reusable workflow runs on this repo's PRs via existing triggers | Automatic | Observable, not gating |
| **T7 — Actionlint** | New workflow files in `.github/workflows/` pass `actionlint` validation | `lint.yml` workflow | Yes |

### 10.2 Inventory expected files

For each overlay, `runtime/overlays/<name>/expected.yaml`:

```yaml
# runtime/overlays/review/expected.yaml
must_contain:
  agents: [inquisitor, comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier]
  skills: [git]
  plugins: [context7, github, microsoft-docs, typescript-lsp, security-guidance, pr-review-toolkit]
must_not_contain:
  agents: [code-writer, debugger, refactor]
  plugins: [skill-creator]
```

Negative assertions mechanically enforce the "different set of eyes" design principle. A future edit that accidentally imports `code-writer` into the review overlay fails the build.

### 10.3 Router unit tests (`bats`)

`claude-command-router/tests/router.bats`:

- `review` → overlay=review, status=ok
- `cook me a pizza` → status=unknown_verb
- `@claude` (bare) → status=malformed
- `review and fix` → overlay=review (first-verb-wins)

Runs in `test.yml` via `bats` — sub-second, no container needed.

### 10.4 Deferred to v2

- External minimal-consumer fixture repo
- Rollback rehearsal cron
- Image-build reproducibility check (byte-for-byte)
- Consumer compatibility matrix

### 10.5 Feedback signal (not testing)

90-day GHA artifact retention on session transcripts (per Section 2 decision O1). Used for:

- Consumer reports a bad review → pull transcript for that PR
- Pre-bump drift check → sample recent transcripts
- Post-incident review → rollback + transcript

## 11. Versioning

### 11.1 This repo

| Ref | Meaning |
|---|---|
| `v2.0.0` | Pinned tag, reproducible |
| `v2` | Floating, points to latest `v2.x.x` |
| `v2.x.y` | Every release; consumer opts in to which one |

Image digests in `.github/workflows/claude-*.yml` are pinned per release. A `v2.x.y` tag captures exactly the image digests that were live in the repo at tag time.

### 11.2 Private repo

| Ref | Meaning |
|---|---|
| `ci-v<semver>` | CI-ready release tag. Required by the manifest. |
| `main` | Not CI-consumable — iterates too rapidly. |

### 11.3 Container images

| Tag | Meaning | Lifecycle |
|---|---|---|
| `@sha256:<digest>` | Immutable content address | Referenced by workflow files |
| `:<pubsha>` | Immutable, per-build, serves as rollback target | Never pruned |
| `:pending-<pubsha>` | Pre-promotion staging | 30-day retention |
| `:v1` | Floating, always points to current production | Moved atomically on promote/rollback |

## 12. Migration plan (high-level)

Drafted here to bound scope; detailed plan will be produced by `superpowers:writing-plans`.

1. **Phase 1 — scaffolding:** `runtime/` tree, manifest schema, base Dockerfile, build workflow (no promotion yet)
2. **Phase 2 — base image:** base image builds + pushes + smoke tests
3. **Phase 3 — overlays:** four overlays build + push + smoke + inventory
4. **Phase 4 — router:** `claude-command-router/` composite action + bats tests
5. **Phase 5 — reusable workflow wiring:** point `claude-pr-review.yml`, `claude-lint-failure.yml`, `claude-apply-fix.yml`, `claude-ci-failure.yml`, `claude-tag-respond.yml` at the new images via digest pins
6. **Phase 6 — promotion + rollback tooling:** tag move scripts, `rollback.yml`, `prune-pending.yml`, digest-bump-PR automation
7. **Phase 7 — deprecate v1 action path:** once dogfooded on this repo's PRs for at least one release cycle, cut `v2.x.y` and update `v2` floating tag

## 13. Open questions / to-verify

1. **`HOME=/opt/claude` vs `/root`.** Claude Code config discovery currently assumes `$HOME/.claude`. Need to verify the CLI honors `HOME` override, or adjust Dockerfile to place config at `/root/.claude`.
2. **`container:` expression support.** Whether `container: ghcr.io/.../claude-runtime-${{ needs.route.outputs.overlay }}@sha256:<digest>` works at workflow level. If not, router emits discrete `dispatch-<verb>` jobs with hard-coded containers (functionally equivalent, slightly more YAML).
3. **`claude-code-action` input schema.** Whether the action has or will add an explicit `executable_path` input. If so, our wrapper should prefer that over the env var for clarity. Pull latest docs before implementation.
4. **GHCR push from a forked PR.** Whether forked PRs need a different auth path. Not critical for v1 (builds are triggered from main or workflow_dispatch, not from forks).
5. **Marketplace sha bump cadence.** When do we bump the pinned marketplace sha? Proposal: manually, on observed value. Document the decision.
6. **`claude-lint-failure.yml` overlay split.** Whether the diagnose-only and auto-apply paths live in separate jobs with distinct `container:` values (clean but more YAML) or share the `fix` overlay (simpler, but diagnose-only runs carry a slightly heavier image). Resolve in implementation plan.

## 14. Appendix A — decisions made during brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Image architecture | Shared base + per-action overlays | Physical isolation of persona, shared foundation, manageable size |
| Source of truth | Public authoritative, imports from private | Avoid duplication; public is where CI lives |
| Merge policy | `public_wins` with WARN log | Intentional override mechanism, not a failure |
| Private repo triggering | None — build is public-initiated only | User controls when new content enters CI |
| Private ref default | None — required semver tag | Prevent WIP content from leaking into CI |
| Private ref format | `ci-v<semver>` | Explicit "CI-ready" marker in the private repo |
| Agent memory in v1 | None | Ephemeral runners + project-specific memory don't fit CI |
| Feedback signal | 90-day transcript artifacts | Model-level quality can't be unit-tested; transcripts are the observable |
| Plugin mechanism | P1 (full install) preferred where personas *should* differ | `pr-review-toolkit` replaces personal `code-reviewer` deliberately |
| Smoke test scope for v1 | Basic: binary + agent count + manifest hash echo | "Enough for v1"; inventory assertions carry the bulk of the load |
| Pending tag retention | 30 days | Enough for post-mortem, keeps registry tidy |
| Router location | Composite action (`claude-command-router/`) | User preference: logic in actions, not workflows |
| PAT secret name | `GH_PAT` | User's standard across all repos |
| Container tag strategy | Digest pinning in workflow file (Option B) | Matches the reproducibility stance taken everywhere else in the design |
| Consumer surface | One `uses:` line, no container/env | Hide implementation details behind the reusable workflow seam |

## 15. Appendix B — plugin catalog (v1)

### Base image

| Plugin | Mechanism | Purpose |
|---|---|---|
| `context7` | P1 | Live library docs for code tasks |
| `github` | P1 | GitHub API via MCP (consumer repo interaction) |
| `microsoft-docs` | P1 | MS/Azure docs lookup |
| `typescript-lsp` | P1 | TS language server (this repo is TS) |
| `skill-creator` | P1 | Enables in-image skill construction |
| `security-guidance` | P1 | PreToolUse hook targeting `.github/workflows/` command injection — directly relevant |

### Review overlay

| Plugin | Mechanism | Purpose |
|---|---|---|
| `pr-review-toolkit` | P1 (full) | Replaces personal `code-reviewer`. Provides comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier, plus `/review-pr` command |

### Fix / Explain / Diagnose overlays

No additional plugins in v1 beyond the base set.

## 16. Appendix C — references

- Epic: [#130](https://github.com/cbeaulieu-gt/github-actions/issues/130)
- Milestone: #7
- Prior audit comments on #130: 4289668386 (travel list finalized), 4290268951 (CI-only plugin addendum)
- Private repo: `cbeaulieu-gt/claude_personal_configs`
- Marketplace (pinned): `anthropics/claude-plugins-official@f01d614cb6ac4079ec042afe79177802defc3ba7`
- Plugin install record: `~/.claude/plugins/installed_plugins.json` (22 plugins, user's local setup)
