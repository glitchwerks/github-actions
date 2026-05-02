# CI Claude Runtime — Design Spec

**Epic:** [#130](https://github.com/glitchwerks/github-actions/issues/130)
**Milestone:** #7
**Status:** Design complete, pending user review
**Date:** 2026-04-21
**Author:** Claude (on behalf of @cbeaulieu-gt)
**Version:** 1.0

---

## 1. Context

The `glitchwerks/github-actions` library provides reusable Claude-powered automation actions. Today each action invokes `anthropics/claude-code-action@v1` on a stock `ubuntu-latest` runner, which means the model runs with whatever stock persona and toolset that action brings — no curated skills, agents, plugins, or memory are available.

The user maintains a rich local Claude Code setup (~22 plugins, a personal skill/agent library, accumulated feedback memory). We want CI to benefit from a **curated subset** of that setup, delivered via a purpose-built container image, so that automated PR reviews, fix applications, lint diagnoses, and tag-responses all execute against a persona that understands this family of repos — while remaining **intentionally differentiated** from the user's local persona so CI acts as "a different set of eyes."

The personal config library lives in a private repo (`glitchwerks/claude-configs`). Duplicating it into this public repo is unacceptable; pulling blindly from `main` is also unacceptable because the private repo iterates rapidly and frequently holds in-progress material. This design addresses both.

## 2. Goals and non-goals

### Goals

1. **Context correctness (PRIMARY)** — each CI action runs with the minimal correct Claude context for its job, with no drift or persona bleed between actions.
2. **Deterministic, shared-base behavior** — all overlays derive from a common base so every reviewer starts from the same foundation, with project-specific knowledge layered on from the consumer repo.
3. **Reproducibility** — a given workflow release produces the same result when re-run, within the limits of a non-deterministic model.
4. **Single source of truth** — no duplication between public (`github-actions`) and private (`claude-configs`). Public imports from private via an explicit manifest.
5. **Pull-based update flow** — the public repo decides when to pull a new snapshot of private. The private repo never triggers a CI rebuild.
6. **Consumer simplicity** — consumers call a reusable workflow with one `uses:` line and a secret. Container images, env vars, and internal plumbing are not part of the consumer surface.

### Non-goals (v1)

- **Local-persona parity.** CI is a different set of eyes, not a clone.
- **Agent memory / learned feedback.** Ephemeral runners cannot accumulate memory; v1 leaves memory out entirely. Feedback signal comes from transcript review.
- **Startup latency optimization.** Pulled images are typically < 2 GB; cold pull cost is acceptable.
- **Self-hosted runners.** Public GHA runners only, for sandboxing.
- **External-consumer compatibility matrix.** Deferred until at least one external consumer exists.
- **Operational cost, storage, rate limiting.** GHCR storage (4 images × tags × ~1–2 GB each), Claude API usage, and rate-limit handling are monitored post-launch rather than specified here.

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

We ship **one base image + one overlay per action verb** — four images total:

```
ghcr.io/glitchwerks/claude-runtime-base              # shared foundation
├── claude-runtime-review                             # PR review
├── claude-runtime-fix                                # apply-fix + lint-apply + read-only diagnosis (--read-only)
└── claude-runtime-explain                            # tag-respond default / @claude explain
```

The base carries: Claude Code CLI binary, Node.js 20, a curated plugin set (context7, github, microsoft-docs, typescript-lsp, skill-creator, security-guidance), shared skills imported from private (e.g. `git`, `python`), shared agents (`ops`), a shared `CLAUDE.md`, and the `software-standards.md` reference.

Each overlay carries: verb-specific agents, verb-specific plugins (e.g. `pr-review-toolkit` in the review overlay), a verb-specific `CLAUDE.md` that scopes behavior to that action.

### 3.2 Provisional: overlay count

> **Provisional design:** This spec ships four images (`base` + `review` + `fix` + `explain`). The adversarial review surfaced that only `review` carries a distinct plugin surface (`pr-review-toolkit`); `fix` and `explain` differ from `base` only in CLAUDE.md and agent subset. We are shipping as four images provisionally, accepting the operational cost (4× smoke, 4× promote, 4× digest pin) for cleaner physical isolation of persona.
>
> **Trigger for collapse:** After one release cycle of operational data, if neither `fix` nor `explain` has developed a distinct plugin install or cherry-pick surface, collapse them into `base` with entrypoint-level CLAUDE.md selection. `review` remains a separate image. The decision will be recorded in a follow-up spec revision.

### 3.3 Why shared base + overlays (not monolith, not fully isolated)

Three options were evaluated:

| Option | Choice | Why |
|---|---|---|
| **Monolithic single image with all context** | Rejected | Context bleed — every action has every agent available, leading to persona drift. Mechanism-dependent isolation (rely on CLAUDE.md to "please only use these agents") is not enforceable. |
| **Fully isolated per-action images, no shared layer** | Rejected | Drift between overlays: the base context every reviewer should agree on has no single definition. Maintenance cost grows linearly with actions. |
| **Shared base + per-action overlays (chosen)** | ✅ | Physical isolation of verb-specific context (cannot bleed: it's not in the image). Shared base guarantees consistent foundation. Docker layer caching amortizes size cost. |

Physical isolation > mechanism-dependent isolation. When a review runs, it is literally impossible for `code-writer` to be invoked — the agent file is not on disk.

### 3.4 Consumer context composition (runtime)

At job time, three context layers compose:

1. **Base CLAUDE.md** (in base image, from `runtime/shared/CLAUDE-ci.md`)
2. **Overlay CLAUDE.md** (in overlay image, from `runtime/overlays/<verb>/CLAUDE.md`)
3. **Consumer repo CLAUDE.md** (mounted via `actions/checkout@v4` — project-specific knowledge)

Layer 3 is the "project-specific knowledge from the actual repo" that makes a generic review overlay useful for *this specific codebase*.

## 4. Source-of-truth model

### 4.1 ELT with public as authoritative

The public repo (`glitchwerks/github-actions`) is authoritative for CI configuration. It **imports from** the private repo (`glitchwerks/claude-configs`) as a declarative dependency.

```
┌─────────────────────────────────────────┐
│ glitchwerks/github-actions (public)    │  ← authoritative for CI
│                                         │
│   runtime/ci-manifest.yaml              │  ← declares what to import
│   runtime/shared/CLAUDE-ci.md           │  ← CI-specific, local
│   runtime/overlays/*/CLAUDE.md          │  ← CI-specific, local
│   runtime/base/Dockerfile               │
│   runtime/overlays/*/Dockerfile         │
│                                         │
│   imports ───────────────────────────────────→  glitchwerks/claude-configs
│                                         │      (private, pinned by semver tag)
└─────────────────────────────────────────┘
```

### 4.2 Merge policy

**Default behavior — fail on collision:** When a path appears in both a `shared/` source and the `imports_from_private` import list, the build **FAILS** with a descriptive error. Silent shadowing of authoritative imported artifacts is not permitted.

Example failure message:

```
ERROR merge_collision path=skills/git/SKILL.md
  source_public=runtime/shared/skills/git/SKILL.md (sha=abc123)
  source_private=claude-configs/skills/git/SKILL.md (sha=def456, ref=ci-v1.2.3)
  resolution=error (path not in merge_policy.overrides)
  action=BUILD HALTED — add path to merge_policy.overrides to permit this override explicitly
```

**Explicit override mechanism:** To intentionally allow a `shared/` path to shadow an imported private path, the path must be listed in `merge_policy.overrides`. This is a deliberate, reviewable line in the manifest — not a default behavior. An override entry is visible in code review and communicates that the deviation from the authoritative import is intentional.

Example: if `skills/git/SKILL.md` is legitimately overridden for CI purposes:

```yaml
merge_policy:
  on_conflict: error                        # default; explicit for clarity
  overrides:
    - skills/git/SKILL.md                  # permits public to shadow private for this path
```

Any path not listed in `overrides` that collides between `shared/` and `imports_from_private` halts the build. This guarantees that authoritative imported artifacts (`skills/git`, `agents/ops`, `CLAUDE.md`, `standards/software-standards.md`) cannot be silently replaced by a stale fork under `runtime/shared/`.

> **Spec amendment 2026-05-02 (PR for [#141](https://github.com/glitchwerks/github-actions/issues/141), Pass-2 Charge 1):** The `merge_policy.overrides` mechanism above governs path-level collisions between `shared/` source files and `imports_from_private`. It is **independent of** the new `overlays.<verb>.subtract_from_shared.plugins` field introduced in §5.1, which removes plugins inherited from `shared` via the FROM line at overlay build time. The two mechanisms do not interact: a plugin listed in `subtract_from_shared.plugins` need not (and cannot — different scope) appear in `merge_policy.overrides`. Use `subtract_from_shared.plugins` to remove a base-inherited plugin from a specific overlay; use `merge_policy.overrides` to allow a `shared/` source to shadow an `imports_from_private` path at base scope.

### 4.3 Version pinning

- **Private ref** is pinned in the manifest to a semver tag `ci-v<semver>` (e.g. `ci-v1.2.3`). The private repo is responsible for cutting these tags when content is CI-ready. **No default to `main`** — the manifest schema requires an explicit tag; builds fail fast if the tag is missing or malformed.
- **Marketplace ref** is pinned to a full commit SHA. Current pin: `f01d614cb6ac4079ec042afe79177802defc3ba7` (2026-04-21).
- **Public ref** (i.e. this repo's state during the build) is naturally pinned to the commit SHA that triggered the build.

All three refs are recorded as OCI labels on every built image:

```
org.opencontainers.image.source     = github.com/glitchwerks/github-actions@<pubsha>
dev.glitchwerks.ci.private_ref      = ci-v1.2.3
dev.glitchwerks.ci.private_sha      = <commit-sha-of-private-tag>
dev.glitchwerks.ci.marketplace_sha  = f01d614cb6ac4079ec042afe79177802defc3ba7
```

Any promoted image can be reproduced from its labels alone.

## 5. The manifest

### 5.1 Shape

`runtime/ci-manifest.yaml`:

```yaml
sources:
  private:
    repo: glitchwerks/claude-configs
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
    context7:
      paths: ["**"]                   # P1: full install
    github:
      paths: ["**"]
    microsoft-docs:
      paths: ["**"]
    typescript-lsp:
      paths: ["**"]
    skill-creator:
      paths: ["**"]
    security-guidance:
      paths:                          # P2: cherry-pick — only the PreToolUse hook
        - hooks/hooks.json
        - hooks/security_reminder_hook.py

overlays:
  review:
    plugins:
      pr-review-toolkit:
        paths: ["**"]                 # P1: full install, replaces personal code-reviewer
    imports_from_private:
      agents: [inquisitor]            # NOTE: code-reviewer comes from pr-review-toolkit, NOT imported from personal config — the "different eyes" principle is preserved
    local:
      claude_md: runtime/overlays/review/CLAUDE.md
    subtract_from_shared:             # NEW per spec amendment 2026-05-02 (PR for #141)
      plugins: [skill-creator]        # remove base-inherited plugins from this overlay at build time

  fix:
    imports_from_private:
      agents: [debugger, code-writer]
    local:
      claude_md: runtime/overlays/fix/CLAUDE.md

  explain:
    imports_from_private: {}
    local:
      claude_md: runtime/overlays/explain/CLAUDE.md

merge_policy:
  on_conflict: error                          # default; "public_wins" removed — use overrides instead
  overrides: []                              # explicit per-path allowlist where public may shadow an imported path
```

**Plugin collision guard:** A plugin name MUST NOT appear more than once in `plugins` within the same scope (base or any overlay), nor across scopes. The same plugin appearing in both the `shared` scope and any overlay scope is a schema error. Because the unified schema uses a single `plugins` mapping (keyed by plugin name), a duplicate key is detectable at YAML-parse time and is independently enforced by STAGE 1 schema validation (see §6.2).

**`subtract_from_shared.plugins`** *(spec amendment 2026-05-02 — PR for [#141](https://github.com/glitchwerks/github-actions/issues/141)):* Permitted only at overlay scope (`overlays.<verb>.subtract_from_shared.plugins`) — the schema's `$defs/overlay_scope` allows the field; `$defs/scope` (used for `shared`) does not. Each name MUST also be a key in `shared.plugins` (semantic check in `validate-manifest.sh`); each name MUST match `^[a-z0-9][a-z0-9-]*$` (structural check in JSON Schema). Mechanism: `extract-overlay.sh` writes a zero-byte marker per name to `${OUT_DIR}/.subtract/plugins/<name>`; the overlay's Dockerfile RUN step `rm -rf`s the corresponding `/opt/claude/.claude/plugins/<name>/` directory inherited from the FROM-line base, then deletes the `.subtract/` directory. This is the mechanism §10.2's `must_not_contain.plugins` for review depends on (e.g. `[skill-creator]`). See §4.2 for the relationship to `merge_policy.overrides` (no interaction).

### 5.2 Schema (JSON Schema at `runtime/ci-manifest.schema.json`)

Asserted at build time (STAGE 1):

Manifest validation runs in two distinct phases, both blocking in STAGE 1:

1. **Structural validation (JSON Schema / `ajv`)** — types, enums, required fields, syntax. Runs first; failures halt immediately.
2. **Semantic validation (custom script, STAGE 1)** — verifies: (a) every `imports_from_private.*` path exists in the cloned private repo tree; (b) every `merge_policy.overrides` path resolves to a real collision between a `shared/` source and an imported private path; (c) the plugin-collision guard from §5.1 (no plugin name appears twice across scopes). The semantic validator lives in `runtime/scripts/validate-manifest.*` (extension TBD during implementation).

Fields asserted by structural validation (JSON Schema / `ajv`):

- `sources.private.ref` matches `^ci-v\d+\.\d+\.\d+$`
- `sources.marketplace.ref` matches `^[a-f0-9]{40}$`
- `overlays` keys ⊆ `{review, fix, explain}`
- `merge_policy.on_conflict` ∈ `{error}` (only valid value; `public_wins` is removed) *(Single-value enum retained for structural clarity and forward extensibility — additional policies like `private_wins` or `manual_review` could be added here without a schema breaking change.)*
- `merge_policy.overrides` items: each path MUST exist in both a `shared/` source and the private import list — **note:** the structural validator checks only that each item is a non-empty string; the existence check is performed by the semantic validator in phase 2 (JSON Schema cannot validate file existence)
- `*.imports_from_private.agents` items ⊆ known-agent enum (typo-catcher)
- **Plugin collision guard:** Each `plugins` mapping key (plugin name) must be unique within its scope. Additionally, the validator cross-checks all scopes: if a plugin name appears in `shared.plugins` and also in any overlay's `plugins`, the build is rejected. Error message must name the plugin and both occurrence paths (e.g., `ERROR plugin_collision plugin=security-guidance paths=[shared.plugins.security-guidance, overlays.fix.plugins.security-guidance]`). A duplicate plugin key within a single YAML mapping is caught at parse time; cross-scope collision is caught by the schema validator.

### 5.3 Plugin install mechanisms

Both install modes share the same unified manifest schema:

```yaml
plugins:
  <name>:
    paths: [<glob>]   # "**" = full install (P1); explicit paths = cherry-pick (P2)
```

- **P1 — full install** (`paths: ["**"]`): entire plugin directory is copied into the image and registered as installed. Used when we want the plugin's persona to *replace* personal variants (e.g. `pr-review-toolkit` in the review overlay replaces the personal `code-reviewer`).
- **P2 — cherry-pick** (`paths: [<specific-paths>]`): copy only the listed files from a plugin directory. Used when only part of a plugin is needed. Example: the base image cherry-picks `security-guidance`'s `hooks/hooks.json` + `hooks/security_reminder_hook.py` (the PreToolUse hook targeting `.github/workflows/` injection) without installing the full plugin surface.

The P1/P2 shorthand is retained as prose — it is useful for communicating intent. The schema-level distinction is solely in the `paths` value: `["**"]` vs an explicit list. The formerly separate `plugins.install` and `plugins.cherry_pick` keys no longer exist in the schema.

## 6. Build pipeline

### 6.1 Trigger surface

- **`workflow_dispatch`** with inputs: `images` (`all` | `base` | `review` | `fix` | `explain`), `private_ref_override`, `marketplace_ref_override` — for manual rebuilds, tested rebuilds, or emergencies
- **`push` to `main`** filtered by `dorny/paths-filter` on `runtime/**` — automatic rebuild when runtime sources change
- **NOT** triggered by the private repo. No `repository_dispatch` in either direction.

#### 6.1.1 Concurrency

The build workflow MUST declare:

```yaml
concurrency:
  group: runtime-build-${{ github.sha }}
  cancel-in-progress: false
```

This prevents two builds for the same source SHA (e.g. a `workflow_dispatch` re-run racing a push-triggered build) from concurrently pushing to `ghcr.io/.../claude-runtime-*:pending-<pubsha>`. Without this, last-writer-wins at the registry can corrupt the immutable `:<pubsha>` tag and leave the rollback reference pointing to the wrong layer stack.

### 6.2 Stages

```
STAGE 1: CLONE SOURCES (parallel)
  ├── git clone github-actions @ pubsha
  ├── git clone claude-configs @ ci-v1.2.3  (via GH_PAT)
  └── git clone claude-plugins-official @ <sha>
  + manifest schema validation (ajv)
      - validates merge_policy.on_conflict is "error"
      - validates merge_policy.overrides: each listed path must exist in BOTH
        a shared/ source and the private import list (stray overrides = schema error)
      - validates plugin collision guard: no plugin name appears in plugins
        both in shared scope and any overlay scope. Error message must name
        the plugin and both occurrence paths.
  + import-path existence check
  + extract-shared.sh determinism check: run extract-shared.sh twice with
    identical inputs and assert byte-identical output (sha256sum comparison).
    Failure is a hard build fail — non-deterministic output means cache keys
    are unreliable and image reproducibility cannot be guaranteed.
  + GHCR immutability preflight: verify that the GHCR package for each image
    has tag immutability enabled via the GHCR API; fail the build if immutability
    is not set (without this, the "immutable rollback reference" guarantee is void)
    (see §6.3.1 for enablement instructions, verification endpoint, and failure message)

STAGE 2: BUILD BASE (sequential)
  [Concurrency declaration required — see §6.1.1]
  ├── extract-shared.sh  (materializes shared/ tree per manifest, applies merge_policy)
  │     Determinism requirements for extract-shared.sh:
  │       - Sorted file listings (no filesystem-order dependence)
  │       - No embedded timestamps in any output file
  │       - Stable file ordering inside archives/tarballs
  │       - Reproducible umask applied before any file write
  ├── docker build runtime/base --build-context=... --label=...
  │     Cache key for base layer: tuple of
  │       (manifest file hash, private-ref commit SHA,
  │        marketplace commit SHA, extract-shared.sh content hash)
  │     Any change to any component busts the layer.
  └── push ghcr.io/.../claude-runtime-base:pending-<pubsha>
      capture base digest

STAGE 3: BUILD OVERLAYS (parallel matrix)
  for each overlay in (review, fix, explain):
    ├── filtered by change detection (skip unchanged overlays)
    ├── docker build runtime/overlays/<name> --build-arg BASE_DIGEST=<digest>
    │     /opt/claude/.claude/ MUST be world-readable:
    │       directories: mode 755; files: mode 644
    │     HOME=/opt/claude alone is insufficient if the tree is mode 700
    │     owned by root — a non-root consumer process cannot load agents,
    │     hooks, or CLAUDE.md from an unreadable directory.
    └── push ghcr.io/.../claude-runtime-<name>:pending-<pubsha>

STAGE 4: SMOKE TEST (parallel)
  for each image:
    ├── docker run --rm --user <non-root-uid> \
    │       -e HOME=/tmp/smoke-home \          # not /opt/claude — prevent auth state leaking into image
    │       <image> claude -p "list agents + skills; exit"
    │   Smoke tests MUST exec as the same UID the consumer workflow runs as
    │   (non-root — GitHub Actions default runner is not root). Running smoke
    │   as root masks permission failures that will bite consumers.
    ├── assert counts non-zero (count zero = hard failure)
    ├── assert Claude process started as non-root successfully enumerates
    │   installed agents and plugins (count must match expected.yaml)
    ├── inventory check against runtime/overlays/<name>/expected.yaml
    │   (must_contain + must_not_contain)
    └── secret hygiene scan: scan /opt/claude/.claude/ for any file matching
        *.oauth, *.token, credentials.json, .netrc, or auth.json.
        If any match is found, fail promotion immediately.
        Rationale: if claude-code-action writes auth state into $HOME/.claude/
        during smoke test execution, that state must not layer into the
        promoted public-registry image.

STAGE 5: PROMOTE
  collect digests for all images that passed smoke (base + three overlays)
  open a single PR against .github/workflows/claude-*.yml that updates ALL
    four digest references atomically in one git commit
  ├── one commit = one atomic promote across all four images
  ├── no crane tag calls — there is no floating :v1 tag
  └── merging this PR IS the promote

There is no floating `:v1` tag. Consumers pull by immutable digest. Promotion
is a git commit to reusable workflow files. A partial promote (some images
promoted, others not) is structurally impossible: the digest-bump PR either
merges all four references or none.
```

Pending tags (`pending-<pubsha>`) are retained 30 days for post-mortem. Immutable `:<pubsha>` tags are never pruned and serve as rollback targets.

### 6.3 Secrets

| Secret | Used by | Purpose | Fallback |
|---|---|---|---|
| `GH_PAT` | STAGE 1 | Clone the *private* repo (`claude-configs`) at the pinned `ci-v*` tag | **None.** If expired/revoked, STAGE 1 fails with `GH_PAT authentication failed — rotate secret`. There is no fallback — private repo access requires an authorized token. |
| `GITHUB_TOKEN` (ambient) | STAGE 2–5 | Push images to GHCR packages in this repo's org. Granted via `permissions: { packages: write }` in the workflow — no extra secret needed. | **None.** This is the primary and only token for the GHCR push step. Multi-org push (to another org's GHCR) would require a separate PAT, but this design does not need that. |
| `CLAUDE_CODE_OAUTH_TOKEN` | STAGE 4 | Smoke test runs `claude` with a live token | None |

**`GH_PAT` vs `GITHUB_TOKEN` are independent roles — neither is a fallback for the other.** `GH_PAT` authenticates against the private repo; `GITHUB_TOKEN` authenticates against this repo's GHCR packages. They cannot substitute for each other. Multi-org GHCR push is out of scope for this design.

**Secret rotation** is an operational concern outside this spec — expired tokens cause hard failures with descriptive error annotations (see §9.1).

#### 6.3.1 GHCR tag immutability (one-time setup)

> **Spec amendment 2026-05-01: see Issue #173**

GitHub Container Registry does not currently support tag immutability. The "Prevent tag overwrites" toggle described in earlier drafts of this spec was never available in GHCR; the assumption was incorrect. The feature has been requested by the community ([discussion #181783](https://github.com/orgs/community/discussions/181783)) but has not been implemented as of this amendment date.

**Actual reproducibility mechanism:** Reusable workflows in this design pin container images by content-addressed digest (`@sha256:<digest>`) rather than by tag. A digest reference is inherently immutable — it resolves to exactly the content that produced that hash, and no registry operation can change what a given digest points to. This is the primary reproducibility guarantee and it holds regardless of whether GHCR supports tag immutability.

The `:<pubsha>` tag alias is cosmetic: it gives a human-readable label to the same layer stack. A subsequent `docker push` to an existing `:<pubsha>` tag would overwrite the tag, but no consumer in this design references images by tag — every reference in `.github/workflows/claude-*.yml` is a digest pin. Tag overwrite is therefore a cosmetic concern, not a functional one.

**Residual risk:** If an operator or automated process pushed a different image to a `:<pubsha>` tag, the tag would no longer identify the correct rollback target. The digest-pinned consumer references would remain correct; only the tag-based forensic convenience would be compromised. Mitigation: access-control the GHCR packages to prevent unintended pushes (organization-level package settings → "Who can push packages").

**`runtime/scripts/ghcr-immutability-preflight.sh` removed:** The preflight script that checked for the non-existent toggle has been deleted in PR #171 (Issue #173). The `GHCR_ALLOW_MISSING_PACKAGES` bootstrap bridge env var is also removed. STAGE 1 permissions reverted to `contents: read` only (`packages: read` was added solely for the preflight).

## 7. Consumer experience

### 7.1 Default path — reusable workflow

Consumer workflow:

```yaml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    uses: glitchwerks/github-actions/.github/workflows/claude-pr-review.yml@v2
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
    container: ghcr.io/glitchwerks/claude-runtime-review@sha256:<digest>  # Option B: digest pinned
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: ./pr-review
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

The container reference is pinned by digest (Option B). Every successful build opens a PR bumping these digests across every reusable workflow that pins a container image, then a workflow release cut from that PR ships the new image to consumers. Consumers pinned to `@v2.x.y` get exactly the image digest that was in the repo at tag time — no silent drift.

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
| `claude-lint-failure.yml` (read-only path) | `fix` | Lint failure → diagnosis comment; `fix` overlay invoked with `--read-only` flag, no commits produced |
| `claude-lint-failure.yml` (auto_apply path) | `fix` | Lint failure → diagnosis + auto-fix; same image, `--read-only` not set |
| `claude-ci-failure.yml` | `fix` | CI failure analysis using `fix` overlay with `--read-only`; may optionally dispatch a `fix` (applying) job downstream |
| `claude-tag-respond.yml` | *(routed)* | Router dispatches to `review`, `fix`, or `explain` overlay based on the verb in the comment |

Implementation note: `claude-lint-failure.yml` uses a single `fix` overlay for both the read-only diagnosis path and the auto-apply path. The `--read-only` flag controls whether commits are produced. This eliminates the formerly separate `diagnose` overlay; both paths use the same image, differing only in the flag passed at invocation.

## 8. The tag-respond router

The current `tag-claude/` action is a catch-all generalist. For the runtime-image world it becomes a **verb router**.

### 8.1 Router composite action

`claude-command-router/action.yml`:

- Parses the first verb after `@claude` in the triggering comment body
- Validates verb ∈ `{review, fix, explain}`
- Outputs three fields:
  ```yaml
  outputs:
    overlay: <review | fix | explain>
    status: <ok | unknown_verb | malformed | unauthorized>
    mode: <apply | read-only>  # default "apply"; "read-only" when "--read-only" appears as a whitespace-delimited token anywhere after the resolved verb within the same @claude mention; otherwise "apply". Only meaningful for overlay=fix.
  ```
  (`mode` lives in the router so dispatch decisions don't require the downstream workflow to re-parse the comment.)
- Delegates authorization to the existing `check-auth/` action before dispatching
- First-verb-wins on ambiguous input (`@claude review and fix` → `review`)

The router lives in a composite action (not inline in the calling workflow) because the user's preference is to keep logic in actions — actions are composable, testable, and don't bloat workflows.

### 8.1.1 Parsing rules

The router applies the following rules to the triggering comment body:

**Known-verb allowlist:** `review | fix | explain` (aligned with overlay names). Read-only invocations of `fix` are requested via `--read-only` appended after the verb (e.g., `@claude fix --read-only`). The `diagnose` verb has been collapsed into `fix --read-only`.

**Algorithm — verb scanning:**

1. Locate the first `@claude` mention in the comment body (case-insensitive).
2. If no `@claude` mention is found, `status=malformed`.
3. After `@claude`, tokenize the remaining text on whitespace delimiters.
4. Scan tokens left-to-right. For each token, lowercase it and test against the known-verb allowlist.
5. Any token that is not in the verb allowlist is skipped — this includes explicit filler words (`please`, `can`, `you`, `go`, `help`, `and`, `also`, `me`, `a`, `the`, etc.), domain words (`the`, `linter`, `ci`), and any other non-verb token. The scan continues until a verb is matched or all tokens are exhausted. A comment with `@claude` and no subsequent verb token emits `status=unknown_verb`.

   The `claude-command-router/lib/filler_words.txt` file documents frequently-seen filler tokens for implementer reference and reviewer convenience (one word per line, lowercased). The file is **documentation-only — the router does NOT load it at startup.** The algorithm skips ALL non-verb tokens regardless of whether they appear in this file. The JSON corpus in §10.3 validates the skip-all-non-verb property by including cases for both file-listed words (e.g. `please`, `can`) and unlisted domain words (e.g. `triage`, `cook`). When adding new entries to the file, also add at least one JSON case demonstrating the word is correctly skipped — not because the file is load-bearing, but because the corpus is the executable spec. _(Amended Phase 4 — see Phase 4 plan Task 12.1 + Pass-1 finding H5 + Deviation #9.)_
6. The **first token that matches a known verb** becomes the resolved verb; `status=ok`, `overlay=<verb>`.
7. If the scan exhausts all tokens after `@claude` without matching a known verb, `status=unknown_verb` and the router posts a supported-verbs rejection.
8. **First-verb-wins:** scanning stops at the first known-verb match. Subsequent verb tokens (including from a second `@claude` mention) are ignored.
9. **`--read-only` flag scan:** Once the verb is resolved, continue scanning remaining tokens in the same `@claude` mention. If `--read-only` appears as a whitespace-delimited token, emit `mode=read-only`. Otherwise emit `mode=apply`. Scan terminates at the next `@claude` mention or end of comment. Filler words and domain words between the verb and the flag are permitted. The flag is silently ignored for overlays other than `fix`.

**Parsing properties:**

- **Case-insensitivity:** `@claude REVIEW`, `@claude Review`, and `@claude review` all resolve to `verb=review`. Token comparison is done after lowercasing.
- **Delimiter requirement:** `@claude-review` does NOT match — the pattern requires at least one whitespace character between `@claude` and the token stream.
- **Whitespace tolerance:** `@claude   review` (multiple spaces, tabs) matches; whitespace between tokens is collapsed.

**Examples:**

| Input | `overlay` | `status` | `mode` |
|---|---|---|---|
| `@claude please review this` | `review` | `ok` | `apply` |
| `@claude can you fix the lint` | `fix` | `ok` | `apply` |
| `@claude fix --read-only` | `fix` | `ok` | `read-only` (no commits) |
| `@claude fix the linter --read-only` | `fix` | `ok` | `read-only` (filler/domain words between verb and flag are permitted) |
| `@claude fix --read-only the stale tests` | `fix` | `ok` | `read-only` (flag may appear before trailing tokens) |
| `@claude please fix --read-only` | `fix` | `ok` | `read-only` (filler before verb; flag after verb) |
| `@claude review --read-only` | `review` | `ok` | `apply` (`--read-only` is ignored for overlays other than `fix`; `mode` defaults to `apply`) |
| `@claude check this PR` | — | `unknown_verb` | `apply` (`check` is not a verb; scan exhausts; no match) |
| `@claude triage and fix the lint` | `fix` | `ok` | `apply` (`triage` is not a verb; skipped; `fix` wins) |
| `@claude review` | `review` | `ok` | `apply` (`mode` always emitted, default `apply`) |
| `@claude thanks!` | — | `unknown_verb` | `apply` (no known verb found; `mode` defaults to `apply` since input has a valid `@claude<whitespace>` mention) |
| `@claude review and also fix` | `review` | `ok` | `apply` (first-verb-wins; `fix` ignored) |
| `@claude review and also @claude fix` | `review` | `ok` | `apply` (first known verb in first mention wins) |
| `@claude` (bare) | — | `malformed` | — (no tokens after `@claude`) |
| `@claude-review` | — | `malformed` | — (no whitespace delimiter) |

**`mode` field semantics** _(amended Phase 4 — see Phase 4 plan Task 12.2 + Deviation #5):_ `mode` is always emitted as `apply`, `read-only`, or `""` (empty). The default is `apply` for any input that contains a valid `@claude<whitespace>` mention, regardless of whether the verb resolved (status ∈ {`ok`, `unknown_verb`}). `mode` is empty (`""`) ONLY when status is `malformed` — the input contained no parseable `@claude<whitespace>` mention (rows 13: bare `@claude`, 14: `@claude-review`).

The declarative JSON corpus at `claude-command-router/tests/cases.json` is the executable specification for these rules.

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
      mode:    ${{ steps.r.outputs.mode }}
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
    container: ghcr.io/glitchwerks/claude-runtime-${{ needs.route.outputs.overlay }}@sha256:<digest>
    # ... rest of dispatch
```

**Relative path note:** The router is invoked as `./claude-command-router` (relative) rather than the absolute `glitchwerks/github-actions/claude-command-router@v2` pattern used elsewhere. This is intentional — the router is only ever called from reusable workflows *within this library* after `actions/checkout@v4` has already checked out the library's own code, so the relative path resolves correctly. External consumers never reference the router directly; they go through `claude-tag-respond.yml`. The absolute-ref convention in CLAUDE.md applies to actions exposed to external consumers; internal-only plumbing can safely use relative paths.

(See Section 13 open question #2 regarding `container:` expression support at job level.)

### 8.3 Router error surface

| Input | Response |
|---|---|
| Unknown verb (`@claude cook me a pizza`) | Reply: `I don't recognize that command. Supported: review, fix, fix --read-only, explain.` Exit 0. |
| Malformed (bare `@claude`) | Reply with verb list. Exit 0. |
| Unauthorized caller | Polite rejection via `check-auth/`. Exit 0. |
| Ambiguous (`@claude review and fix`) | First-verb-wins. Documented behavior. |
| Valid verb but overlay image fails to pull | GHA-level failure on dispatch job — not the router's concern. |

## 9. Error handling and failure modes

### 9.1 Pre-promotion (safe to fail loudly — nothing consumed yet)

| Failure | Detection | Behavior |
|---|---|---|
| Missing private tag | STAGE 1 `git clone --branch` 404 | Hard fail: `Private ref 'ci-v1.2.3' not found — check claude-configs tags`. |
| Manifest parse/schema error | STAGE 1 ajv | Hard fail with line/column. |
| Missing imported file | STAGE 1 path-existence check | Hard fail listing every missing path. Never silently skip. |
| Docker build error | Non-zero exit | Hard fail. Matrix default `continue-on-error: false` — one overlay failing blocks ALL promotion (never ship a partial set). |
| Smoke or inventory test failure | STAGE 4 | Hard fail. `pending-<pubsha>` retained 30 days; digest-bump PR is not opened. |
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

Rollback is a **single atomic git operation** across all four images.

**Standard rollback — revert the digest-bump PR:**

```bash
git revert <digest-bump-merge-commit>
# creates a new commit restoring all four prior @sha256:<digest> references
git push origin main
```

One revert commit atomically restores all four image references to the prior set. No `crane tag`, no partial state, no split-brain window.

**Targeted rollback to an arbitrary prior pubsha:**

`runtime/rollback.yml` (`workflow_dispatch`, inputs: `target_pubsha`):

Opens a PR that replaces all four `@sha256:<digest>` values with the digests recorded in the OCI labels of `:<target_pubsha>` images. Merging that PR is the rollback. `:<target_pubsha>` is immutable — it is already in GHCR and was never overwritten. No rebuild required.

There is no `:v1` tag to move. Rollback scope is always all-four-images because promotion scope is always all-four-images.

### 9.4 Orphaned pending tag cleanup

`runtime/prune-pending.yml` (`schedule: '0 2 * * *'`):

- Lists all `pending-<sha>` tags older than 30 days
- Deletes them (they served their staging purpose and are past the post-mortem window)
- Never prunes `:<pubsha>` (immutable rollback targets)

### 9.5 Merge-policy collisions

`ERROR merge_collision` lines halt the build when a path appears in both a `shared/` source and the private import list and is not listed in `merge_policy.overrides`. There are no silent WARN-and-continue resolutions. The build either completes cleanly (no collisions, or all collisions are explicitly permitted via `overrides`) or it fails with a specific list of offending paths.

## 10. Testing strategy

### 10.1 v1 test layers

| Layer | What it tests | Where it runs | Blocking? |
|---|---|---|---|
| **T1 — Manifest schema** | YAML parses, required keys present, enums valid, plugin collision guard | STAGE 1 | Yes |
| **T2 — Import-path existence** | Every `imports_from_private` path exists at the pinned ref | STAGE 1 | Yes |
| **T2b — extract-shared.sh determinism** | Script produces byte-identical output on two runs with identical inputs | STAGE 1 | Yes |
| **T3 — Smoke test** | Claude binary runs as non-root UID, `HOME=/tmp/smoke-home`, skill/agent counts non-zero and match `expected.yaml` | STAGE 4 | Yes |
| **T3b — Secret hygiene scan** | `/opt/claude/.claude/` contains no `*.oauth`, `*.token`, `credentials.json`, `.netrc`, `auth.json` | STAGE 4 (post-smoke, pre-promote) | Yes |
| **T4 — Inventory assertions** | Each overlay contains `must_contain`, does NOT contain `must_not_contain` | STAGE 4 | Yes |
| **T5 — Router unit tests** | Declarative JSON corpus (bash + jq) for verb parsing: happy path, unknown, malformed, ambiguous, `--read-only` flag | `test.yml` | Yes |
| **T6 — Dogfood (free)** | Each reusable workflow runs on this repo's PRs via existing triggers | Automatic | Observable, not gating |
| **T7 — Actionlint** | New workflow files in `.github/workflows/` pass `actionlint` validation | `lint.yml` workflow | Yes |

### 10.2 Inventory expected files

For each overlay, `runtime/overlays/<name>/expected.yaml`:

```yaml
# runtime/overlays/review/expected.yaml
must_contain:
  agents: [inquisitor, comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier]
  plugins: [context7, github, typescript-lsp, security-guidance, pr-review-toolkit]
must_not_contain:
  agents: [code-writer, debugger]
  plugins: [skill-creator]
```

> **Spec amendment 2026-05-02 (PR for [#141](https://github.com/glitchwerks/github-actions/issues/141)):**
>
> 1. `microsoft-docs` was removed from `must_contain.plugins` because it does not exist at the manifest's pinned marketplace SHA (`0742692199b49af5c6c33cd68ee674fb2e679d50`). Phase 2 dropped it from the manifest in PR #171 (commit `b93b16d`); the example here is updated to reflect post-Phase-2 reality. Readers cross-checking against `runtime/overlays/review/expected.yaml` see the live truth.
> 2. `must_contain.skills: [git]` was removed because per the Plugin Truth Table (Phase 3 plan preamble), overlay `must_contain` declares only verb-specific minima — base-image inherited content (`skills/git`, `skills/python`, `agents/ops`) is asserted by base smoke (`smoke-test.sh:96-114`) and need not be re-asserted in overlay `expected.yaml`. Including `skills: [git]` is harmless but redundant; the Plugin Truth Table omits it for clarity.
> 3. The `must_not_contain.plugins: [skill-creator]` assertion is honored mechanically via `overlays.review.subtract_from_shared.plugins: [skill-creator]` (introduced in §5.1 amendment) — the base ships `skill-creator` and every overlay inherits it via FROM, so review must subtract it at build time. Without the subtract mechanism, the review overlay would inherit `skill-creator` and STAGE 4-overlay would fail with `inventory_must_not_contain_present`.

Negative assertions mechanically enforce the "different set of eyes" design principle. A future edit that accidentally imports `code-writer` into the review overlay fails the build.

#### Ownership separation

`runtime/overlays/*/expected.yaml` MUST be listed in `.github/CODEOWNERS` with a reviewer *different from the reviewer assigned to the overlay manifest itself*. Edits to an overlay and edits to its `expected.yaml` in the same PR require two distinct reviewers. Without this separation, the "different eyes" guarantee is not enforced by CI — it reduces to the same author writing both sides of the assertion. This must be enforced via branch protection or rulesets requiring CODEOWNERS review on protected paths.

Additionally, edits that touch **both** `runtime/shared/**` (source files that could shadow private imports) **and** `runtime/ci-manifest.yaml`'s `merge_policy.overrides` list in the same PR MUST require a second approver via CODEOWNERS. This closes the symmetric loophole where a single author could stage a new shadowing file and whitelist it in one commit. The manifest MAY be edited by a single owner when the edit does not touch `merge_policy.overrides`.

Example CODEOWNERS configuration:

```
# Overlay manifests — reviewed by overlay team lead
runtime/overlays/*/                @overlay-lead

# Inventory assertions — reviewed by a separate party
runtime/overlays/*/expected.yaml   @inventory-reviewer

# CI manifest (merge_policy.overrides edits require a second approver)
runtime/ci-manifest.yaml           @manifest-reviewer
runtime/shared/**                  @shared-reviewer
```

#### Marketplace bump review containment

Every PR that bumps `sources.marketplace.ref` in `runtime/ci-manifest.yaml` MUST include, in the PR body, a `git diff` summary between the old and new marketplace SHA *scoped to the plugin directories that appear in the manifest* (either via `paths: ["**"]` or via explicit path lists). No marketplace bump merges without this diff visible to reviewers.

Rationale: agent renames, hook schema changes, and plugin file moves can slip through inventory assertions when `expected.yaml` gets co-edited in the same PR. Visible diff of the actual installed surface is the containment. A PR template or CI automation step must enforce this requirement.

### 10.3 Router unit tests (declarative JSON corpus)

`claude-command-router/tests/cases.json` holds the executable spec as a JSON array; each object has the shape:

```json
{
  "name": "short human-readable case name",
  "input": "<verbatim comment body to feed the router>",
  "expect": { "overlay": "review|fix|explain|", "status": "ok|unknown_verb|malformed|unauthorized", "mode": "apply|read-only|" }
}
```

Minimum v1 coverage — every row of §8.1.1 appears as at least one case, plus:

- `review` → overlay=review, status=ok
- `fix` → overlay=fix, status=ok, mode=apply
- `fix --read-only` → overlay=fix, status=ok, mode=read-only
- `fix the linter --read-only` → filler/domain word between verb and flag does not break flag detection
- `please fix --read-only` → filler before verb + flag after verb
- `review --read-only` → `--read-only` is ignored for non-fix overlays; mode defaults to apply
- `triage and fix the lint` → skip-and-continue on unknown domain word; `fix` wins
- `cook me a pizza` → status=unknown_verb
- `@claude` (bare) → status=malformed
- `review and fix` → first-verb-wins

Runner: `claude-command-router/tests/run-cases.sh` — pure bash + jq. Reads `cases.json`, iterates, sources `claude-command-router/lib/parse.sh`, compares each emitted `{overlay, status, mode}` tuple to the `expect` object, fails on any mismatch. Runs in `.github/workflows/test.yml` on every PR. No container needed; runtime is bounded by the number of cases — trivial wall-clock cost at v1 scale.

**Testing-dependency policy (adopted 2026-04-22):** No new tool dependency beyond what is preinstalled on `ubuntu-latest` (`bash`, `jq`, `curl`, Node.js 20, standard POSIX utilities) may be introduced without a documented evaluation with alternatives considered. Installable-at-CI-time tools — `bats`, `yq`, language-specific test frameworks (Jest, pytest, etc.) — require an explicit proposal. Rationale: installable dependencies accrete and resist removal (see the TypeScript extraction rollback tracked in #126). The "preinstalled on ubuntu-latest" bar is practical, not principled: a tool already present in the runner image adds zero installation cost, zero version-pinning burden, and would require explicit removal to opt out; a new installable requires an `apt-get install` (or equivalent) step that accrues across workflows and resists removal. `jq` meets the bar on these mechanics, not on any intrinsic merit over `bats`. The existing slack-notify design spec (`docs/superpowers/specs/2026-04-08-slack-notify-design.md`) specifies `bats` and predates this policy; it will be revisited if/when slack-notify moves to implementation — the inconsistency is documented rather than silently accepted.

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

### 11.3 Staleness alarm

The pull-based model depends on someone cutting `ci-v*` tags in the private repo; without a freshness signal, stale CI is silent.

`runtime/check-private-freshness.yml` — scheduled weekly (`cron: '0 8 * * 1'`):

1. Reads the currently-pinned `ci-v*` tag from `runtime/ci-manifest.yaml`.
2. Queries the private repo's `main` HEAD commit date via the GitHub API (using `GH_PAT`).
3. If the gap between the pinned tag's commit date and `main` HEAD exceeds **14 days**, opens a GitHub Issue in this repo titled: `Stale private-ref: ci-v<version> is N days behind main`.
4. If an issue with that title already exists and is open, skips (no duplicate spam).

The 14-day threshold is a starting point — short enough to catch meaningful drift, long enough to avoid paging on every private-repo commit. Revisit after one release cycle of operational data.

### 11.4 Container images

| Tag | Meaning | Lifecycle |
|---|---|---|
| `@sha256:<digest>` | Immutable content address | Referenced by workflow files; updated via digest-bump PR |
| `:<pubsha>` | Immutable, per-build, serves as rollback target | Never pruned |
| `:pending-<pubsha>` | Pre-promotion staging | 30-day retention |

There is no floating `:v1` tag. A mutable floating tag would create split-brain during multi-image promotion (four `crane tag` operations are not atomic) and would shadow the digest pin in reusable workflow files (consumers pulling by tag would bypass the pinned digest). Promotion is exclusively via the digest-bump git commit; rollback is a git revert or a new digest-bump PR pinning a prior `:<pubsha>` set.

## 12. Migration plan (high-level)

Drafted here to bound scope; detailed plan will be produced by `superpowers:writing-plans`.

1. **Phase 1 — scaffolding:** `runtime/` tree, manifest schema, base Dockerfile, build workflow (no promotion yet)
2. **Phase 2 — base image:** base image builds + pushes + smoke tests
3. **Phase 3 — overlays:** three overlays (review, fix, explain) build + push + smoke + inventory
4. **Phase 4 — router:** `claude-command-router/` composite action + declarative JSON corpus
5. **Phase 5 — reusable workflow wiring:** point `claude-pr-review.yml`, `claude-lint-failure.yml`, `claude-apply-fix.yml`, `claude-ci-failure.yml`, `claude-tag-respond.yml` at the new images via digest pins
6. **Phase 6 — promotion + rollback tooling:** tag move scripts, `rollback.yml`, `prune-pending.yml`, digest-bump-PR automation
7. **Phase 7 — deprecate v1 action path:** once dogfooded on this repo's PRs for at least one release cycle, cut `v2.x.y` and update `v2` floating tag

## 13. Open questions / to-verify

1. **`HOME=/opt/claude` vs `/root`.** Claude Code config discovery currently assumes `$HOME/.claude`. Need to verify the CLI honors `HOME` override, or adjust Dockerfile to place config at `/root/.claude`.
2. **`container:` expression support.** Whether `container: ghcr.io/.../claude-runtime-${{ needs.route.outputs.overlay }}@sha256:<digest>` works at workflow level. If not, router emits discrete `dispatch-<verb>` jobs with hard-coded containers (functionally equivalent, slightly more YAML).
3. **`claude-code-action` input schema.** Whether the action has or will add an explicit `executable_path` input. If so, our wrapper should prefer that over the env var for clarity. Pull latest docs before implementation.
4. **GHCR push from a forked PR.** Whether forked PRs need a different auth path. Not critical for v1 (builds are triggered from main or workflow_dispatch, not from forks).
5. **Marketplace sha bump cadence.** When do we bump the pinned marketplace sha? Proposal: manually, on observed value. Document the decision.
6. ~~**`claude-lint-failure.yml` overlay split.**~~ **Resolved.** `claude-lint-failure.yml` uses a single `fix` overlay for both the read-only diagnosis path and the auto-apply path. The `--read-only` flag controls whether commits are produced. The formerly separate `diagnose` overlay is eliminated.
7. **Staleness alarm denominator.** The `check-private-freshness.yml` check (§11.3) currently compares calendar days between pinned-tag commit date and private `main` HEAD. This produces drift-fatigue when `main` sees heavy churn on paths not imported by CI, and silence when imported paths themselves diverge. Implementation should narrow the denominator to `git log` scoped to the paths in `imports_from_private.*`, and revisit the 14-day threshold once real drift data is available. Source: inquisitor pass 2.
8. **GHCR immutability preflight retry/backoff.** The preflight (§6.3.1) is described as "verified on every build" but has no retry or backoff specified. Transient GitHub API 5xx / rate-limit responses would fail the build closed on a read that is not itself load-bearing. Implementation should add exponential backoff (e.g., 3 attempts) and document an emergency skip flag for incident use. Source: inquisitor pass 2.
9. **Router `mode` output naming.** The third router output is currently named `mode` with a carve-out that it is "ignored for overlays other than `fix`". This conflates delivery-policy (commit-or-not) with a general verb dimension and may not scale when future verbs introduce orthogonal flags (`--draft`, etc.). Candidate rename: `commit_policy: <apply | read-only>` or a boolean `apply`. Implementation plan to evaluate whether to rename before shipping or defer until a second orthogonal flag appears. Source: inquisitor pass 2.
10. **Non-root smoke UID pin.** STAGE 4 smoke tests must run as the consumer-runner UID (§10.1). The spec currently uses `<non-root-uid>` as a placeholder. GitHub-hosted Ubuntu runners today use UID 1001 (`runner`), but this is an implementation detail of the runner image, not a documented contract. Implementation should either (a) pin the UID explicitly with a preflight that asserts `id -u` matches inside a live runner step, or (b) dynamically capture the runner UID in a pipeline step and pass it into the smoke invocation. Source: inquisitor pass 2.

## 14. Appendix A — decisions made during brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Image architecture | Shared base + per-action overlays | Physical isolation of persona, shared foundation, manageable size |
| Source of truth | Public authoritative, imports from private | Avoid duplication; public is where CI lives |
| Merge policy | `error` by default; explicit `overrides` list for intentional path-level exceptions | Prevents silent shadowing of authoritative imported artifacts; overrides are reviewable in code review |
| Private repo triggering | None — build is public-initiated only | User controls when new content enters CI |
| Private ref default | None — required semver tag | Prevent WIP content from leaking into CI |
| Private ref format | `ci-v<semver>` | Explicit "CI-ready" marker in the private repo |
| Agent memory in v1 | None | Ephemeral runners + project-specific memory don't fit CI |
| Feedback signal | 90-day transcript artifacts | Model-level quality can't be unit-tested; transcripts are the observable |
| Plugin mechanism | Unified schema `plugins: { <name>: { paths: [...] } }`; `"**"` = P1 full install, explicit list = P2 cherry-pick | Single schema key; P1/P2 are prose shorthand for the two path patterns. Formerly separate `install` and `cherry_pick` keys eliminated to simplify the schema and make the collision guard unambiguous. |
| Smoke test scope for v1 | Non-root UID, `HOME=/tmp/smoke-home`; binary + agent count + inventory match; post-smoke secret scan | Running as root masks permission failures; `HOME` isolation prevents auth state from leaking into promoted image |
| Pending tag retention | 30 days | Enough for post-mortem, keeps registry tidy |
| Router location | Composite action (`claude-command-router/`) | User preference: logic in actions, not workflows |
| PAT secret name | `GH_PAT` | User's standard across all repos |
| Container tag strategy | Digest pinning in workflow file (Option B); no floating `:v1` tag | Digest pin is the sole promotion mechanism; a mutable tag creates non-atomic multi-image state and shadows the pin |
| Consumer surface | One `uses:` line, no container/env | Hide implementation details behind the reusable workflow seam |
| `diagnose` verb | Collapsed into `fix --read-only` | `diagnose ⊂ fix` — read-only is a flag, not an orthogonal verb. Eliminates the fourth overlay; overlay count becomes three (review, fix, explain) plus base. |
| Overlay count (provisional) | Four images: base + review + fix + explain | Only `review` has a distinct plugin surface. `fix` and `explain` differ from base only in CLAUDE.md/agents. Provisional pending one release cycle; collapse trigger: if `fix`/`explain` develop no distinct plugin surface, merge into base with entrypoint-level CLAUDE.md selection. |
| Private-ref staleness alarm | `runtime/check-private-freshness.yml` weekly cron; opens issue if gap > 14 days | Pull-based model is silent when `ci-v*` tags go uncut. 14-day threshold: shorter pages too often; longer lets rot creep in. Revisit after first release cycle. |
| CODEOWNERS split on `expected.yaml` | `runtime/overlays/*/expected.yaml` requires a distinct reviewer from the overlay manifest | Same author writing both sides of the assertion defeats the "different eyes" guarantee. Enforced via branch protection/rulesets. |
| Smoke test UID | Non-root (same UID as consumer GHA runner) | Root smoke masks permission failures that will bite consumers at runtime. |
| Cache key for base layer | Tuple of (manifest hash, private-ref SHA, marketplace SHA, `extract-shared.sh` content hash) | Any component change busts the layer. `extract-shared.sh` must be deterministic (sorted listings, no timestamps, stable archive ordering, reproducible umask). Determinism tested in STAGE 1. |
| Marketplace bump review | PR body must include `git diff` of plugin dirs between old/new SHA | Agent renames and hook schema changes can slip through inventory assertions when `expected.yaml` is co-edited in the same PR. Visible diff is the containment. |
| Smoke secret hygiene | Post-smoke scan of `/opt/claude/.claude/` for auth artifacts; fail promotion on match | `claude-code-action` may write auth state into `$HOME/.claude/` during smoke; `HOME=/tmp/smoke-home` prevents this from reaching the image, but scan enforces it. |
| `GH_PAT` vs `GITHUB_TOKEN` | Independent roles; neither is a fallback for the other | `GH_PAT` clones the private repo; `GITHUB_TOKEN` pushes to GHCR. Multi-org GHCR push is out of scope. |
| `merge_policy.on_conflict` single-value enum | `{error}` is the only valid value; enum retained rather than hardcoded | Structural clarity: the enum signals that additional policies (`private_wins`, `manual_review`) are possible extension points without a schema breaking change. |
| `mode` as explicit router output | Router emits `mode` (`apply` \| `read-only`) alongside `overlay` and `status` | Dispatch decisions must not require the downstream workflow to re-parse the comment. All routing logic is centralized in the router. `mode` defaults to `apply`; set to `read-only` iff `--read-only` follows the verb (meaningful only for the `fix` overlay). |

## 15. Appendix B — plugin catalog (v1)

Plugins are declared under the unified manifest schema: `plugins: { <name>: { paths: [...] } }`. `paths: ["**"]` = P1 full install; explicit path list = P2 cherry-pick.

### Base image

| Plugin | `paths` | Mechanism | Purpose |
|---|---|---|---|
| `context7` | `["**"]` | P1 | Live library docs for code tasks |
| `github` | `["**"]` | P1 | GitHub API via MCP (consumer repo interaction) |
| `microsoft-docs` | `["**"]` | P1 | MS/Azure docs lookup |
| `typescript-lsp` | `["**"]` | P1 | TS language server (this repo is TS) |
| `skill-creator` | `["**"]` | P1 | Enables in-image skill construction |
| `security-guidance` | `["hooks/hooks.json", "hooks/security_reminder_hook.py"]` | P2 | PreToolUse hook targeting `.github/workflows/` command injection — only the hook files needed, not the full plugin surface |

### Review overlay

| Plugin | `paths` | Mechanism | Purpose |
|---|---|---|---|
| `pr-review-toolkit` | `["**"]` | P1 | Replaces personal `code-reviewer`. Provides comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier, plus `/review-pr` command |

### Fix / Explain overlays

No additional plugins in v1 beyond the base set.

## 16. Appendix C — references

- Epic: [#130](https://github.com/glitchwerks/github-actions/issues/130)
- Milestone: #7
- Prior audit comments on #130: 4289668386 (travel list finalized), 4290268951 (CI-only plugin addendum)
- Private repo: `glitchwerks/claude-configs`
- Marketplace (pinned): `anthropics/claude-plugins-official@f01d614cb6ac4079ec042afe79177802defc3ba7`
- Plugin install record: `~/.claude/plugins/installed_plugins.json` (22 plugins, user's local setup)
