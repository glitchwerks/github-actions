# Phase 2 Base Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, push, and smoke-test the `claude-runtime-base` image — establishing `extract-shared.sh` determinism, the cache-key tuple, non-root smoke execution, `HOME=/tmp/smoke-home` isolation, secret-hygiene scan, and the `pending-<pubsha>` staging pattern. End-state: a base image at `ghcr.io/glitchwerks/claude-runtime-base@sha256:<digest>` whose smoke run enumerates a non-zero count of agents/skills/plugins as a non-root UID, and whose `:<pubsha>` immutable tag is reachable for Phase 3 to `FROM`.

**Architecture:** A multi-arch base image (linux/amd64 only for v1 — GHA runners are amd64) built on `node:20-slim` pinned by digest. Bash helpers (`extract-shared.sh`, `capture-runner-uid.sh`, `smoke-test.sh`) plus a Dockerfile, all wired into two new stages of the existing `runtime-build.yml`: STAGE 1b (determinism check, appended to STAGE 1), STAGE 2 (build + push pending tag), STAGE 4 (smoke + secret scan). STAGE 3 (overlays) and STAGE 5 (promote) are explicitly NOT in this phase — they belong to Phases 3 and 6 respectively.

**Tech Stack:** Docker BuildKit (via `docker/build-push-action@v7`), GHCR push (via `docker/login-action@v4`), Claude Code CLI pinned to `@anthropic-ai/claude-code@2.1.118` (npm `stable` dist-tag as of 2026-05-01), Bash helpers (POSIX-ish, run on `ubuntu-latest`), `mikefarah/yq` v4 (already pinned in Phase 1 to v4.44.3), `jq` (preinstalled), `find`/`tar`/`sha256sum` for determinism, `claude -p --output-format json --json-schema` for structured smoke output (no grep-against-LLM).

**Spec source of truth:** `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §3.4 layer 1, §4.3 OCI labels, §6.2 STAGE 2 + STAGE 3 read-side notes, §6.2 STAGE 4 secret scan, §6.3 secrets, §13 Q1 HOME, §13 Q10 non-root UID. Master plan: `docs/superpowers/plans/2026-04-22-ci-claude-runtime.md` §Phase 2.

**Consumer requirements** (what Phase 3 overlays expect of this image — see "Consumer Requirements" section below):

- **R1** — `FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}` works with the digest captured by Phase 2's STAGE 2 job output.
- **R2** — `HOME` and `PATH_TO_CLAUDE_CODE_EXECUTABLE` env vars are set in the image such that `claude -p "list agents"` works without any overlay-side env overrides.
- **R3** — `/opt/claude/.claude/` tree is world-readable (dirs `0755`, files `0644`) so non-root overlay processes can load agents/hooks/CLAUDE.md.
- **R4** — Image carries the full `shared.*` materialized tree per manifest (skills `git`+`python`, agent `ops`, base `CLAUDE.md`, `standards/software-standards.md`, plus the six base plugins).
- **R5** — Image labels per §4.3 are set, sufficient to reproduce the build from labels alone.

How Phase 2 satisfies these is producer-side latitude — Phase 3 only consumes the contract.

**Issue:** [#140](https://github.com/glitchwerks/github-actions/issues/140). **Branch:** `phase-2-base-image` (off `main` @ `5882127`). **Worktree:** `I:/github-actions/.worktrees/phase-2-base-image`.

---

## Deviations from master plan (recorded as the plan is authored)

Items shifted versus master-plan §Phase 2. Each is minimal, self-contained, and has a kill criterion or follow-up trigger.

1. **`docker/build-push-action` v7, not v5.** The master plan does not name a docker action version; this plan pins to `docker/build-push-action@v7` (latest stable major as of 2026-05-01, release v7.1.0). Same for `docker/login-action@v4` (v4.1.0) and `docker/setup-buildx-action@v4` (v4.0.0). All three follow the Phase 1 convention of pinning by major-version tag (e.g. `actions/checkout@v5`), not full SHA. **Trade-off:** tag pins are slightly less reproducible than SHA pins but match the existing repo style; if a future tag-rewrite incident occurs, swap to SHA. SHAs are recorded in this plan for one-shot pinning if desired.

2. **`node:20-slim` pinned by digest, not just tag.** The master plan does not specify base-image pinning. This plan pins `node:20-slim` to a verified live digest on 2026-05-01 (see Task 4). Pinning by tag would let Docker Hub re-tag the underlying digest (which it does on every Node patch release) and silently change the cache-key denominator. **Multi-arch scope:** v1 builds linux/amd64 only (GHA hosted runners are amd64). The pin is the multi-arch index digest, not just amd64 — a future arm64 build can pull from the same index. The Dockerfile's `--platform linux/amd64` flag is set explicitly so the build is unambiguous when the runner is amd64.

3. **GHCR_ALLOW_MISSING_PACKAGES removal is its own task (Task 9), not a sub-step of the wiring task.** Bundling it with workflow edits would let a reviewer accidentally land it without verifying the four GHCR packages exist + immutability is on. Splitting it forces the verification gate (Task 8) to land first.

4. **Phase 0 #138 C3 stays open through Phase 2.** The Phase 1 plan documented the bootstrap-bridge as the kill trigger for #138 C3. After inquisitor pass 1 (recorded in PR #171 thread): "partial closure" is not a valid GitHub state and obscures the gap. Revised approach: leave #138 OPEN with a comment listing the closed slot (`claude-runtime-base`) and pointing at Phase 3 for full closure when the remaining three packages are created and immutability-toggled. Closure of #138 happens in Phase 3, not here. See "Phase 0 #138 C3 progress" subsection below (renamed from "closure").

5. **`SMOKE_UID` is captured + logged, not asserted equal to 1001.** Inquisitor pass 1 finding: hard-asserting `SMOKE_UID == 1001` makes the smoke fail closed if GitHub bumps the runner image. UID 1001 is implementation detail of the GitHub runner image, not a documented contract. Revised: capture the UID dynamically per §13 Q10, log it with each run, and use it as `--user $UID` in `docker run` — but do NOT assert against a literal `1001`. If the UID changes, the smoke continues; the change becomes visible in run logs and we adjust on observation rather than failing closed across every PR.

6. **Inquisitor-driven revisions (pass 1) — additional items folded into the plan:**
   - **Cache-key tuple expanded** (Task 7) from 4 components to 7: adds `runtime/base/Dockerfile` content hash, `runtime/scripts/smoke-test.sh` content hash, and the resolved `node:20-slim` index digest as a literal string. Rationale: previously a Dockerfile-only edit (e.g. a new `RUN` step that flips perms back to 0700) would hit the cache and ship a stale layer.
   - **Claude Code CLI pinned** (Task 4) at `@anthropic-ai/claude-code@2.1.118` (the npm `stable` dist-tag as of 2026-05-01). Version is captured in a sixth OCI label `dev.glitchwerks.ci.cli_version` and added to the cache-key tuple. Rationale: without a pin, two builds 24 hours apart with byte-identical manifest+private+marketplace+extract-shared.sh produce different images, and the labels lie.
   - **Smoke output format moves from grep-against-LLM to `claude -p --output-format json --json-schema`** (Task 3). Verified live: `claude --help` shows both `--output-format json` and `--json-schema <schema>` as documented flags on the installed CLI version (2.1.126 locally; the pinned version 2.1.118 is older and the schema flag MUST be re-verified on it before commit — see Task 3 Step 2.3.1a). Smoke now sends a schema-constrained prompt and asserts `jq -r '.agents | length > 0'` rather than `grep -c '^\[agent\]'`.
   - **§13 Q1 verification gate enumerates three CLI resolution paths explicitly** (Task 5): (a) `HOME` env honored; (b) hard-coded `/root/.claude`; (c) `pwd.getpwuid(uid).pw_dir` for UID 1001 (which has no passwd entry in `node:20-slim`). The Dockerfile additionally creates a passwd entry for UID 1001 with `pw_dir=/opt/claude` via `RUN useradd -u 1001 -d /opt/claude -s /bin/bash runner` so the third path is satisfied unambiguously. Each path is independently verified in Task 5; non-empty enumeration on path (a) is necessary but not sufficient.
   - **Smoke now asserts label completeness** (Task 3): `docker inspect --format` extracts all six expected `org.opencontainers.image.*` and `dev.glitchwerks.ci.*` labels and asserts all are present + non-empty. Catches "implementer dropped a label" before Phase 6 rollback breaks silently.
   - **Smoke now asserts R3 perms regression** (Task 3): `docker run --user 1001 ... find /opt/claude/.claude \( -type d -not -perm 0755 -o -type f -not -perm 0644 \)` and asserts the output is empty. Catches "future RUN step flipped perms to 0700" mechanically.
   - **`provenance: false` removed** (Task 7): the previous draft disabled BuildKit SLSA provenance attestations without justification. Default is `true`; keep the default. Phase 6 rollback benefits from provenance being available.
   - **`EXPECTED_FILE` matcher contract specified** (Task 3): even though Phase 2 base smoke does not use it, the matcher format (`must_contain.{agents,skills,plugins}` and `must_not_contain.{agents,skills,plugins}` against the JSON enumeration) is specified now so Phase 3 cannot deviate silently.
   - **TODO retarget reframed honestly** (Task 9): the `TODO(phase-2)` → `TODO(phase-3)` change is named for what it is — an amendment correcting the original Phase 1 plan's incorrect assumption that Phase 2 would create all four packages. Phase 1's plan section "Deviations from master plan" should also be amended retroactively in a follow-up PR (out of scope for this branch).

Items deferred (with explicit triggers):

- **Shellcheck for new bash scripts** — `actionlint` covers `.github/workflows/*.yml`. Add a separate `shellcheck` step for `runtime/scripts/*.sh` in a follow-up PR or in Phase 6 cleanup. Tracked as a discoverable tech-debt comment in `runtime/scripts/extract-shared.sh`.
- **STAGE 1 → STAGE 2 artifact handoff** (avoid double-clone) — optimization, not correctness. STAGE 2 currently re-clones private + marketplace because runner state isn't shared. `actions/upload-artifact`/`download-artifact` would skip this. Defer to Phase 6 perf pass.
- **Multi-arch (linux/arm64) support** — defer until GHA introduces an arm64 hosted runner GA. Tracked under master-plan §Phase 2 acceptance criteria as out-of-scope.
- **GHCR package-creation race** — between Task 8 Step 2.8.2 (push creates package) and Step 2.8.3 (operator toggles immutability ON), a second `workflow_dispatch` could push to a still-mutable `:pending-<sha>` because §6.1.1 concurrency keys on `github.sha`. Operational mitigation only: operator should toggle immutability in a quiet window. Documented in Task 8.

The Tasks 1–10 below are the merged-state truth (post-pass-1 revisions).

---

## File Structure

Paths relative to repo root. All created/modified on the `phase-2-base-image` worktree.

```
runtime/
  base/
    Dockerfile                                # Task 4 — base image build
  scripts/
    extract-shared.sh                         # Task 1 — manifest → materialized shared/ tree
    capture-runner-uid.sh                     # Task 2 — prints `id -u` for STAGE 4 UID pinning
    smoke-test.sh                             # Task 3 — non-root smoke + secret scan
    tests/
      expected-matcher-fixture/               # Task 3 — EXPECTED_FILE matcher contract fixture (Phase 3 consumer)
        expected.yaml                         # sample expected.yaml exercising must_contain + must_not_contain
        enumeration-pass.json                 # JSON enumeration that should pass the fixture
        enumeration-fail.json                 # JSON enumeration that should fail with two specific errors
        README.md                             # contract description Phase 3 must implement against
    validate-manifest.sh                      # (Phase 1; unchanged)
    ghcr-immutability-preflight.sh            # (Phase 1; unchanged)
  shared/
    CLAUDE-ci.md                              # Task 6 — REPLACE Phase 1 stub with full base persona

.github/workflows/
  runtime-build.yml                           # Task 7 — APPEND STAGE 1b + STAGE 2 + STAGE 4 jobs
                                              # Task 9 — REMOVE GHCR_ALLOW_MISSING_PACKAGES env

CLAUDE.md                                     # Task 10 — extend "CI Runtime" section to mention base image
README.md                                     # Task 10 — note `runtime/base/` is part of build surface
```

Files NOT touched in Phase 2 (intentionally — they belong to Phases 3+):

- `runtime/overlays/{review,fix,explain}/Dockerfile` (Phase 3)
- `runtime/overlays/*/expected.yaml` (Phase 3)
- `runtime/overlays/*/CLAUDE.md` body content (Phase 3 — stubs from Phase 1 stay as stubs)
- `runtime/rollback.yml`, `runtime/check-private-freshness.yml`, `runtime/prune-pending.yml` (Phase 6)
- `.github/workflows/claude-*.yml` consumer-facing reusable workflows (Phase 5)

---

## Pinned identifiers (verified live on 2026-05-01)

Per `agent-memory/general-purpose/feedback_verify_sha_pins_at_write_time.md`, every pin below was checked the moment it landed in this plan. Each entry includes the verification command so a future reviewer can re-run it.

| Pin | Value | Verification |
|---|---|---|
| Base image (amd64 platform digest) | `node:20-slim@sha256:3d0f05455dea2c82e2f76e7e2543964c30f6b7d673fc1a83286736d44fe4c41c` | `docker manifest inspect --verbose node:20-slim` — extracted amd64 platform digest |
| Claude Code CLI | `@anthropic-ai/claude-code@2.1.118` (npm `stable` dist-tag) | `npm view @anthropic-ai/claude-code dist-tags` → `{ stable: '2.1.118', next: '2.1.126', latest: '2.1.126' }` |
| `docker/build-push-action` | `@v7` (release v7.1.0, SHA `bcafcacb16a39f128d818304e6c9c0c18556b85f`) | `gh api repos/docker/build-push-action/git/refs/tags/v7` |
| `docker/login-action` | `@v4` (release v4.1.0, SHA via `gh api`) | `gh api repos/docker/login-action/releases/latest` |
| `docker/setup-buildx-action` | `@v4` (release v4.0.0, SHA via `gh api`) | `gh api repos/docker/setup-buildx-action/releases/latest` |
| `actions/checkout` | `@v5` (Phase 1 pin, unchanged) | (Phase 1 evidence) |
| `mikefarah/yq` | `v4.44.3` (Phase 1 pin, unchanged) | (Phase 1 evidence) |
| Marketplace SHA | `0742692199b49af5c6c33cd68ee674fb2e679d50` (Phase 1 deviation, unchanged) | (Phase 1 evidence) |
| Private ref | `ci-v0.1.0` (Phase 1 pin, unchanged) | (Phase 1 evidence) |

If any entry above no longer resolves at execution time (e.g. a tag was rewritten or the base image digest moved), STOP and re-pin before proceeding — do not execute Phase 2 against stale pins.

---

## Task 0: Pre-task pinned-identifier re-verification (NEW per C11)

**Purpose:** Inquisitor pass 2 noted that C11 ("pinned identifier table re-verified at execution time") was accepted-by-honor, not enforced. This Task makes it the literal first thing the implementer does — before any file-authoring work begins.

**Files:** none (verification commands only)

- [ ] **Step 2.0.1: Re-run every verification command from the "Pinned identifiers" table**

For each row, run the documented verification command. If any pin no longer resolves (404, tag rewrite, npm version yanked), STOP. Update the pin in this plan AND in any downstream Task that references it. Do NOT proceed to Task 1.

```bash
docker manifest inspect node:20-slim | grep -F '"digest": "sha256:3d0f0545'   # exits 0 if amd64 platform digest still matches
npm view @anthropic-ai/claude-code@2.1.118 version                              # exits 0 if version still published
gh api repos/docker/build-push-action/git/refs/tags/v7 --jq .object.sha         # confirms v7 tag still resolves
gh api repos/docker/login-action/git/refs/tags/v4 --jq .object.sha
gh api repos/docker/setup-buildx-action/git/refs/tags/v4 --jq .object.sha
gh api repos/glitchwerks/claude-configs/git/refs/tags/ci-v0.1.0 --jq .object.sha
gh api repos/anthropics/claude-plugins-official/commits/0742692199b49af5c6c33cd68ee674fb2e679d50 --jq .sha
```

All seven must exit 0. If a non-zero exit occurs, the plan's "Pinned identifiers" table is the authoritative location to update before continuing.

---

## Task 1: `extract-shared.sh` + STAGE 1b determinism check

**Purpose:** Materialize the `shared.*` tree from the manifest into a build context that the Dockerfile can `COPY`. Determinism is required because the script's content hash is one of the four cache-key components per §6.2 STAGE 2.

**Files:**
- Create: `runtime/scripts/extract-shared.sh`
- Modify: `.github/workflows/runtime-build.yml` (append a STAGE 1b step inside the existing `stage-1` job)

- [ ] **Step 2.1.1: Author `extract-shared.sh`**

`runtime/scripts/extract-shared.sh`:

```bash
#!/usr/bin/env bash
# Materialize the shared/* tree from the manifest into an output directory.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §3.4 layer 1, §4.2 merge policy, §6.2 STAGE 2
#
# Inputs (env vars):
#   MANIFEST       — path to ci-manifest.yaml (default: runtime/ci-manifest.yaml)
#   PRIVATE_TREE   — path to cloned glitchwerks/claude-configs at the pinned tag (required)
#   MARKETPLACE_TREE — path to cloned anthropics/claude-plugins-official at the pinned SHA (required)
#   SHARED_TREE    — path to this repo's working tree (default: $PWD); used for runtime/shared/ local sources
#   OUT_DIR        — destination directory (required); created if missing, must be empty
#
# Determinism contract (every run with identical inputs MUST produce byte-identical output):
#   - LC_ALL=C for stable sort ordering
#   - umask 022 set explicitly before any write
#   - Sorted file listings (find ... | sort) — never trust filesystem traversal order
#   - mtime stripped to epoch 0 on every emitted file (touch -d @0)
#   - No random temp paths leak into outputs

set -uo pipefail
export LC_ALL=C
umask 022

MANIFEST="${MANIFEST:-runtime/ci-manifest.yaml}"
PRIVATE_TREE="${PRIVATE_TREE:?PRIVATE_TREE must be set}"
MARKETPLACE_TREE="${MARKETPLACE_TREE:?MARKETPLACE_TREE must be set}"
SHARED_TREE="${SHARED_TREE:-$(pwd)}"
OUT_DIR="${OUT_DIR:?OUT_DIR must be set}"

command -v yq >/dev/null || { echo "FATAL yq not on PATH" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL manifest not found: $MANIFEST" >&2; exit 2; }
[ -d "$PRIVATE_TREE" ] || { echo "FATAL PRIVATE_TREE not a dir: $PRIVATE_TREE" >&2; exit 2; }
[ -d "$MARKETPLACE_TREE" ] || { echo "FATAL MARKETPLACE_TREE not a dir: $MARKETPLACE_TREE" >&2; exit 2; }

# OUT_DIR must be empty — non-empty would break determinism (stale files)
if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  echo "FATAL OUT_DIR not empty: $OUT_DIR" >&2
  exit 2
fi
mkdir -p "$OUT_DIR"

# Layout under OUT_DIR (mirrors what ends up at /opt/claude/.claude/ in the image):
#   skills/<name>/...
#   agents/<name>.md
#   plugins/<name>/...
#   CLAUDE.md             (from imports_from_private.claude_md, plus shared.local.claude_md appended)
#   standards/software-standards.md

errs=0
err() { printf 'ERROR %s\n' "$*" >&2; errs=$((errs + 1)); }

emit_file() {
  # emit_file <src> <dst> — copy then strip mtime
  local src="$1" dst="$2"
  install -D -m 0644 "$src" "$dst" || { err "copy_failed src=$src dst=$dst"; return 1; }
  touch -d @0 "$dst"
}

emit_tree() {
  # emit_tree <src_dir> <dst_dir> — recursively copy with sorted ordering
  local src="$1" dst="$2"
  if [ ! -d "$src" ]; then
    err "tree_missing src=$src"; return 1
  fi
  mkdir -p "$dst"
  # Find files only, sort for determinism, copy with preserved relative path
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    install -D -m 0644 "$f" "$dst/$rel" || err "copy_failed src=$f dst=$dst/$rel"
    touch -d @0 "$dst/$rel"
  done < <(find "$src" -type f | sort)
  # Also preserve directory structure mtimes deterministically
  find "$dst" -type d -exec touch -d @0 {} +
}

# ---- shared.imports_from_private.skills ----
while IFS= read -r skill; do
  [ -z "$skill" ] && continue
  emit_tree "$PRIVATE_TREE/skills/$skill" "$OUT_DIR/skills/$skill"
done < <(yq -r '.shared.imports_from_private.skills // [] | .[]' "$MANIFEST")

# ---- shared.imports_from_private.agents ----
while IFS= read -r agent; do
  [ -z "$agent" ] && continue
  emit_file "$PRIVATE_TREE/agents/$agent.md" "$OUT_DIR/agents/$agent.md"
done < <(yq -r '.shared.imports_from_private.agents // [] | .[]' "$MANIFEST")

# ---- shared.imports_from_private.claude_md (append shared.local.claude_md) ----
imp_cm=$(yq -r '.shared.imports_from_private.claude_md // ""' "$MANIFEST")
loc_cm=$(yq -r '.shared.local.claude_md // ""' "$MANIFEST")
if [ -n "$imp_cm" ] || [ -n "$loc_cm" ]; then
  : > "$OUT_DIR/CLAUDE.md"
  if [ -n "$imp_cm" ]; then
    [ -f "$PRIVATE_TREE/$imp_cm" ] || err "claude_md_missing private_path=$imp_cm"
    [ -f "$PRIVATE_TREE/$imp_cm" ] && cat "$PRIVATE_TREE/$imp_cm" >> "$OUT_DIR/CLAUDE.md"
  fi
  if [ -n "$loc_cm" ]; then
    [ -f "$SHARED_TREE/$loc_cm" ] || err "claude_md_missing local_path=$loc_cm"
    if [ -f "$SHARED_TREE/$loc_cm" ]; then
      printf '\n\n---\n\n' >> "$OUT_DIR/CLAUDE.md"  # separator between imported and local
      cat "$SHARED_TREE/$loc_cm" >> "$OUT_DIR/CLAUDE.md"
    fi
  fi
  touch -d @0 "$OUT_DIR/CLAUDE.md"
fi

# ---- shared.imports_from_private.standards ----
st=$(yq -r '.shared.imports_from_private.standards // ""' "$MANIFEST")
if [ -n "$st" ]; then
  emit_file "$PRIVATE_TREE/$st" "$OUT_DIR/$st"
fi

# ---- shared.plugins (P1 full vs P2 cherry-pick per paths value) ----
for plugin in $(yq -r '.shared.plugins // {} | keys | .[]' "$MANIFEST" | sort); do
  src="$MARKETPLACE_TREE/plugins/$plugin"
  if [ ! -d "$src" ]; then
    err "plugin_missing name=$plugin expected=$src"
    continue
  fi
  paths_count=$(yq -r ".shared.plugins.\"$plugin\".paths | length" "$MANIFEST")
  first_path=$(yq -r ".shared.plugins.\"$plugin\".paths[0]" "$MANIFEST")
  if [ "$paths_count" = "1" ] && [ "$first_path" = "**" ]; then
    # P1 — full install
    emit_tree "$src" "$OUT_DIR/plugins/$plugin"
  else
    # P2 — cherry-pick listed paths
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      emit_file "$src/$p" "$OUT_DIR/plugins/$plugin/$p"
    done < <(yq -r ".shared.plugins.\"$plugin\".paths | .[]" "$MANIFEST")
  fi
done

if [ "$errs" -gt 0 ]; then
  echo "extract-shared: $errs error(s)" >&2
  exit 1
fi

echo "extract-shared: clean ($(find "$OUT_DIR" -type f | wc -l) files)"
exit 0
```

- [ ] **Step 2.1.2: chmod and local smoke**

```bash
chmod +x runtime/scripts/extract-shared.sh

# Local smoke (requires GH_PAT for the private clone)
TMP=$(mktemp -d)
git clone --depth 1 --branch ci-v0.1.0 \
  "https://x-access-token:${GH_PAT}@github.com/glitchwerks/claude-configs" "$TMP/private"
git clone https://github.com/anthropics/claude-plugins-official "$TMP/marketplace"
git -C "$TMP/marketplace" checkout 0742692199b49af5c6c33cd68ee674fb2e679d50

PRIVATE_TREE="$TMP/private" \
MARKETPLACE_TREE="$TMP/marketplace" \
SHARED_TREE="$(pwd)" \
OUT_DIR="$TMP/out1" \
bash runtime/scripts/extract-shared.sh
```

Expected: `extract-shared: clean (N files)` where N > 0. Inspect `$TMP/out1` and confirm `skills/git/`, `skills/python/`, `agents/ops.md`, `CLAUDE.md`, `standards/software-standards.md`, and `plugins/{context7,github,microsoft-docs,typescript-lsp,skill-creator,security-guidance}/` are present.

- [ ] **Step 2.1.3: Determinism smoke**

```bash
PRIVATE_TREE="$TMP/private" \
MARKETPLACE_TREE="$TMP/marketplace" \
SHARED_TREE="$(pwd)" \
OUT_DIR="$TMP/out2" \
bash runtime/scripts/extract-shared.sh

diff -r "$TMP/out1" "$TMP/out2" && echo "DETERMINISTIC" || echo "NON-DETERMINISTIC"
```

Expected: `DETERMINISTIC`. If `diff -r` reports any difference, fix the script (most common cause: forgot `LC_ALL=C` or `touch -d @0` somewhere) before committing.

- [ ] **Step 2.1.4: Append STAGE 1b determinism check to `runtime-build.yml`**

Inside the existing `stage-1` job, after the "Semantic validation" step and before "GHCR tag-immutability preflight", add:

```yaml
      - name: STAGE 1b — extract-shared determinism
        env:
          MANIFEST: runtime/ci-manifest.yaml
          PRIVATE_TREE: /tmp/private
          MARKETPLACE_TREE: /tmp/marketplace
          SHARED_TREE: ${{ github.workspace }}
        run: |
          set -euo pipefail
          chmod +x runtime/scripts/extract-shared.sh
          OUT_DIR=/tmp/out1 bash runtime/scripts/extract-shared.sh
          OUT_DIR=/tmp/out2 bash runtime/scripts/extract-shared.sh
          diff -r /tmp/out1 /tmp/out2
          # Also produce a content-hash fingerprint that STAGE 2 will reuse as a cache-key component
          (cd /tmp/out1 && find . -type f | sort | xargs sha256sum) | sha256sum | awk '{print $1}' > /tmp/extract-shared.hash
          echo "extract-shared content hash: $(cat /tmp/extract-shared.hash)"
```

- [ ] **Step 2.1.5: Commit**

```bash
git add runtime/scripts/extract-shared.sh .github/workflows/runtime-build.yml
git commit -m "feat(ci-runtime): add extract-shared.sh + STAGE 1b determinism check (refs #140)"
```

---

## Task 2: `capture-runner-uid.sh`

**Purpose:** §13 Q10. Print `id -u` so STAGE 4 can dynamically pin the smoke UID. Tiny but separate so it's reusable from Phase 3 too.

**Files:**
- Create: `runtime/scripts/capture-runner-uid.sh`

- [ ] **Step 2.2.1: Author**

`runtime/scripts/capture-runner-uid.sh`:

```bash
#!/usr/bin/env bash
# Print the current process UID. Used by STAGE 4 to pin the smoke-test UID
# to the GitHub-hosted runner UID dynamically (§13 Q10).
#
# Output: a single line with the integer UID.

set -euo pipefail
id -u
```

- [ ] **Step 2.2.2: chmod + smoke**

```bash
chmod +x runtime/scripts/capture-runner-uid.sh
bash runtime/scripts/capture-runner-uid.sh
# Local: prints your local UID. CI: prints 1001 (runner UID on ubuntu-latest).
```

- [ ] **Step 2.2.3: Commit**

```bash
git add runtime/scripts/capture-runner-uid.sh
git commit -m "feat(ci-runtime): add capture-runner-uid.sh helper (refs #140)"
```

---

## Task 3: `smoke-test.sh`

**Purpose:** STAGE 4. Runs the image as a non-root UID with `HOME=/tmp/smoke-home`, asserts non-zero counts of agents/skills/plugins **using `claude --output-format json --json-schema` for a structured contract**, asserts label completeness, asserts R3 perms regression-check, runs the secret-hygiene scan per §6.2 STAGE 4. Designed so Phase 3 reuses it for overlay smoke without modification.

**Inquisitor pass 1 finding #3 mitigation:** the previous draft grep-parsed free-text from `claude -p`. That is grep-against-an-LLM and not a contract. The CLI exposes `--output-format json` and `--json-schema <schema>` for structured-output validation. We send a schema-constrained prompt; the CLI rejects model output that doesn't match. `jq` then parses deterministically.

**Inquisitor pass 1 finding #5 mitigation (CLI version pin):** the pinned CLI version (`2.1.118`) is the npm `stable` dist-tag. The `--json-schema` flag MUST be re-verified on `2.1.118` before commit (Step 2.3.1a) — the local check used 2.1.126. If `2.1.118` lacks the flag, bump the pin to the lowest version that has it AND record the bump in this section.

**Envelope shape — verified live on CLI 2.1.126 (probed during pass 2 review on 2026-05-01):**

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "<MODEL PROSE STRING — markdown, not JSON>",
  "structured_output": { "agents": [...], "skills": [...], "plugins": [...] },
  "session_id": "...",
  "total_cost_usd": 0.42,
  ...
}
```

**Critical:** `.result` is a STRING containing the model's prose. The schema-validated object lives at `.structured_output` at the envelope's top level. `jq -r '.result | fromjson'` will FAIL — the previous draft of this plan had that bug, and it would have broken every CI smoke run. The corrected parser uses `jq -r '.structured_output.agents | length'` directly. Inquisitor pass 2 caught this; the live probe confirmed.

Error detection: `jq -r '.is_error'` should be `false` and `.subtype` should be `"success"`. The smoke-test.sh script asserts both before parsing `.structured_output`.

**Files:**
- Create: `runtime/scripts/smoke-test.sh`

- [ ] **Step 2.3.1a: Re-verify `--json-schema` on the pinned CLI version**

```bash
docker run --rm node:20-slim bash -c \
  'npm install -g @anthropic-ai/claude-code@2.1.118 >/dev/null 2>&1 && claude --help' \
  | grep -E -- '--output-format|--json-schema'
```

Expected: both `--output-format <format>` and `--json-schema <schema>` lines appear. If either is missing, find the lowest published `@anthropic-ai/claude-code` version that has both via `npm view @anthropic-ai/claude-code@<version> --help` (or by reading the package's CHANGELOG) and update the pin everywhere in this plan + the manifest table.

- [ ] **Step 2.3.1b: Author smoke-test.sh**

`runtime/scripts/smoke-test.sh`:

```bash
#!/usr/bin/env bash
# Smoke-test a CI runtime image as a non-root UID and scan for auth secrets.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §6.2 STAGE 4, §10.1 T3+T3b
#
# Usage: smoke-test.sh <image-ref> <overlay-name-or-"base">
#
# Required env:
#   CLAUDE_CODE_OAUTH_TOKEN — live OAuth token for `claude` CLI smoke
#
# Optional env:
#   SMOKE_UID      — UID to run as (default: capture from `id -u` on host)
#                    (NOT asserted equal to 1001 — see "Deviations" #5 in the plan;
#                    GHA runner UID is implementation detail, captured-and-logged only)
#   EXPECTED_FILE  — path to expected.yaml (Phase 3+; absent for base smoke).
#                    Phase 3+ matcher contract specified below — see EXPECTED_FILE block.

set -euo pipefail

IMAGE="${1:?image ref required}"
OVERLAY="${2:?overlay name or 'base' required}"

: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN must be set}"

# Capture UID dynamically (§13 Q10). Log it but do not assert against a literal 1001.
SMOKE_UID="${SMOKE_UID:-$(bash "$(dirname "$0")/capture-runner-uid.sh")}"
echo "smoke-test: image=$IMAGE overlay=$OVERLAY uid=$SMOKE_UID"
if [ "$SMOKE_UID" != "1001" ]; then
  echo "smoke-test: NOTE — SMOKE_UID=$SMOKE_UID, expected GHA runner UID 1001. If this is a CI run, the runner image may have changed; verify before treating downstream failures as image bugs." >&2
fi

# ---- (a) Structured-output enumeration via --json-schema ------------------
SMOKE_OUT=$(mktemp)
trap 'rm -f "$SMOKE_OUT"' EXIT

# JSON Schema constraining the model's output to three string arrays.
# Built from a single-line variable (NOT a heredoc) to avoid the `read -r -d ''
# || true` antipattern flagged in pass 2 — a heredoc terminator typo silently
# truncates the schema and the CLI rejects every model output.
SCHEMA='{"type":"object","additionalProperties":false,"required":["agents","skills","plugins"],"properties":{"agents":{"type":"array","items":{"type":"string","minLength":1}},"skills":{"type":"array","items":{"type":"string","minLength":1}},"plugins":{"type":"array","items":{"type":"string","minLength":1}}}}'

docker run --rm \
  --user "$SMOKE_UID" \
  -e HOME=/tmp/smoke-home \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  "$IMAGE" \
  claude --print --output-format json --json-schema "$SCHEMA" \
    "Enumerate every agent, skill, and plugin available in this environment. Return a single JSON object with keys 'agents', 'skills', 'plugins', each an array of names." \
  > "$SMOKE_OUT" 2>&1 \
  || { echo "ERROR smoke_run_failed image=$IMAGE"; cat "$SMOKE_OUT"; exit 1; }

# Envelope shape (verified on CLI 2.1.126; re-verify on 2.1.118 in Step 2.3.1a):
#   .result            = STRING (model prose; not JSON — DO NOT fromjson it)
#   .structured_output = OBJECT (schema-validated; the actual payload)
#   .is_error          = bool
#   .subtype           = "success" | "error_*"
is_error=$(jq -r '.is_error // empty' "$SMOKE_OUT")
subtype=$(jq -r '.subtype // empty' "$SMOKE_OUT")
if [ "$is_error" != "false" ] || [ "$subtype" != "success" ]; then
  echo "ERROR smoke_envelope_error is_error=$is_error subtype=$subtype" >&2
  cat "$SMOKE_OUT" >&2
  exit 1
fi

agent_count=$(jq -r '.structured_output.agents  | length' "$SMOKE_OUT")
skill_count=$(jq -r '.structured_output.skills  | length' "$SMOKE_OUT")
plugin_count=$(jq -r '.structured_output.plugins | length' "$SMOKE_OUT")

echo "smoke-test: counts agents=$agent_count skills=$skill_count plugins=$plugin_count"

# §9.2 highest-risk silent failure: empty enumeration = "image works but persona is empty"
if [ "$agent_count" = "0" ] || [ "$skill_count" = "0" ] || [ "$plugin_count" = "0" ]; then
  echo "ERROR empty_enumeration agents=$agent_count skills=$skill_count plugins=$plugin_count" >&2
  echo "--- captured smoke envelope ---" >&2
  cat "$SMOKE_OUT" >&2
  exit 1
fi

# ---- (b) Inventory assertions (Phase 3+; skipped for base) -----------------
# EXPECTED_FILE matcher contract (specified in Phase 2; consumed in Phase 3+):
#
#   YAML shape:
#     must_contain:
#       agents:  [<name>, ...]
#       skills:  [<name>, ...]
#       plugins: [<name>, ...]
#     must_not_contain:
#       agents:  [<name>, ...]
#       plugins: [<name>, ...]
#
#   Semantics:
#     - For every name listed under must_contain.<kind>, that name MUST appear
#       in the JSON enumeration's <kind> array. Missing → fail with
#       ERROR inventory_must_contain_missing kind=<kind> name=<name>
#     - For every name listed under must_not_contain.<kind>, that name MUST NOT
#       appear in the JSON enumeration's <kind> array. Present → fail with
#       ERROR inventory_must_not_contain_present kind=<kind> name=<name>
#     - Comparisons are exact-match string equality (no glob, no regex).
#     - Reports ALL violations before exiting (do not short-circuit).
#
# Phase 2 base smoke has no expected.yaml — Phase 3 fix/review/explain overlays
# carry their own. The matcher itself lands in Phase 3 with the overlay smoke;
# this block is the contract Phase 3 must implement, not implementation today.
if [ -n "${EXPECTED_FILE:-}" ] && [ -f "${EXPECTED_FILE:-}" ]; then
  echo "smoke-test: EXPECTED_FILE matcher is Phase 3 scope — contract specified in this script's comments"
fi

# ---- (c) Secret hygiene scan (§6.2 STAGE 4) -------------------------------
SECRET_HITS=$(docker run --rm "$IMAGE" \
  find /opt/claude/.claude/ \
    \( -name '*.oauth' \
    -o -name '*.token' \
    -o -name 'credentials.json' \
    -o -name '.netrc' \
    -o -name 'auth.json' \) \
    -print 2>/dev/null || true)

if [ -n "$SECRET_HITS" ]; then
  echo "ERROR secret_hygiene_violation image=$IMAGE" >&2
  echo "       Files matching auth-artifact patterns found in /opt/claude/.claude/:" >&2
  printf '%s\n' "$SECRET_HITS" >&2
  echo "       Promotion blocked. Investigate why the smoke run wrote auth state into the image." >&2
  exit 1
fi

# ---- (d) Label completeness assertion (R5 + Phase 6 rollback dependency) ---
# Phase 6 rollback.yml reads OCI labels to resolve digests. Drop a label here
# and Phase 6 silently breaks. Assert the six expected labels are present and
# non-empty.
EXPECTED_LABELS=(
  "org.opencontainers.image.source"
  "org.opencontainers.image.revision"
  "dev.glitchwerks.ci.private_ref"
  "dev.glitchwerks.ci.private_sha"
  "dev.glitchwerks.ci.marketplace_sha"
  "dev.glitchwerks.ci.cli_version"
)
LABELS_JSON=$(docker inspect --format '{{json .Config.Labels}}' "$IMAGE")
for label in "${EXPECTED_LABELS[@]}"; do
  v=$(printf '%s' "$LABELS_JSON" | jq -r --arg k "$label" '.[$k] // empty')
  if [ -z "$v" ]; then
    echo "ERROR label_missing image=$IMAGE label=$label" >&2
    echo "       OCI label completeness is part of R5 — image must be reproducible from labels alone." >&2
    exit 1
  fi
done
echo "smoke-test: labels OK (${#EXPECTED_LABELS[@]} labels present)"

# ---- (e) R3 perms regression check ----------------------------------------
# R3 demands directories 0755, files 0644 under /opt/claude/.claude. A future
# Dockerfile RUN step could flip perms back; this catches it mechanically.
# Inquisitor pass 2 lower-priority concern: the previous draft used `2>/dev/null
# || true`, which masks "Permission denied" errors from `find` traversal —
# producing silent-green when a 0700 dir blocks recursion. Capture stderr and
# fail if find emitted anything to it.
PERMS_STDERR=$(mktemp); trap 'rm -f "$SMOKE_OUT" "$PERMS_STDERR"' EXIT
PERMS_HITS=$(docker run --rm --user "$SMOKE_UID" "$IMAGE" \
  find /opt/claude/.claude \
    \( -type d -not -perm 0755 \) -o \( -type f -not -perm 0644 \) \
    2>"$PERMS_STDERR" || true)

if [ -s "$PERMS_STDERR" ]; then
  echo "ERROR perms_check_traversal_failed image=$IMAGE" >&2
  echo "       find emitted to stderr — likely permission-denied during traversal:" >&2
  cat "$PERMS_STDERR" >&2
  exit 1
fi

if [ -n "$PERMS_HITS" ]; then
  echo "ERROR perms_regression image=$IMAGE" >&2
  echo "       /opt/claude/.claude entries do not match R3 (dirs 0755 / files 0644):" >&2
  printf '%s\n' "$PERMS_HITS" | head -20 >&2
  exit 1
fi

echo "smoke-test: clean (image=$IMAGE overlay=$OVERLAY uid=$SMOKE_UID)"
exit 0
```

- [ ] **Step 2.3.2: chmod**

```bash
chmod +x runtime/scripts/smoke-test.sh
```

- [ ] **Step 2.3.3: Author EXPECTED_FILE matcher test fixture (Charge 5 mitigation)**

Inquisitor pass 2 Charge 5: "comments are not an enforceable contract." Add a fixture that Phase 3 must implement against. The fixture lives in Phase 2 so it's authoritative when Phase 3 starts.

`runtime/scripts/tests/expected-matcher-fixture/expected.yaml`:

```yaml
# Sample expected.yaml that exercises the must_contain / must_not_contain matcher.
# This is the contract Phase 3's overlay smoke must implement against.
must_contain:
  agents:  [ops, alpha]
  skills:  [git, python]
  plugins: [context7]
must_not_contain:
  agents:  [code-writer]
  plugins: [skill-creator]
```

`runtime/scripts/tests/expected-matcher-fixture/enumeration-pass.json`:

```json
{
  "agents":  ["ops", "alpha", "beta"],
  "skills":  ["git", "python"],
  "plugins": ["context7", "github"]
}
```

`runtime/scripts/tests/expected-matcher-fixture/enumeration-fail.json`:

```json
{
  "agents":  ["ops", "code-writer"],
  "skills":  ["git", "python"],
  "plugins": ["context7", "skill-creator"]
}
```

`runtime/scripts/tests/expected-matcher-fixture/README.md`:

```markdown
# EXPECTED_FILE matcher fixture

Phase 3's overlay smoke test must implement the matcher described in
`runtime/scripts/smoke-test.sh` (the EXPECTED_FILE comment block) and pass these
two cases:

- `enumeration-pass.json` against `expected.yaml` → exit 0 (clean)
- `enumeration-fail.json` against `expected.yaml` → exit 1 with TWO error lines:
  - `ERROR inventory_must_not_contain_present kind=agents name=code-writer`
  - `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`

Phase 3's smoke test runner MUST include a CI step that runs this fixture
before promoting any overlay image. If the fixture cases do not produce the
exact outcomes above, the matcher is non-conforming.
```

This is plan-only in Phase 2 — the actual matcher implementation lands in Phase 3. The fixture's purpose is to make the contract testable when Phase 3 implements it.

- [ ] **Step 2.3.4: Commit**

```bash
git add runtime/scripts/smoke-test.sh runtime/scripts/tests/expected-matcher-fixture/
git commit -m "feat(ci-runtime): add smoke-test.sh + EXPECTED_FILE matcher test fixture (refs #140)"
```

---

## Task 4: `runtime/base/Dockerfile`

**Purpose:** The base image. `node:20-slim` digest-pinned, Claude Code CLI installed, manifest-defined plugin set installed, materialized shared tree at `/opt/claude/.claude/`, env vars set, OCI labels set per §4.3, world-readable mode bits applied.

**Files:**
- Create: `runtime/base/Dockerfile`

- [ ] **Step 2.4.1: Verify the `node:20-slim` digest is still live**

```bash
docker manifest inspect --verbose node:20-slim 2>&1 | grep -A3 '"architecture": "amd64"' | head -10
```

If the amd64 digest no longer matches `sha256:3d0f05455dea2c82e2f76e7e2543964c30f6b7d673fc1a83286736d44fe4c41c`, update the Dockerfile to the new amd64 digest BEFORE the build step. **Do not pin a digest you have not just verified.**

- [ ] **Step 2.4.2: Author the Dockerfile**

`runtime/base/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
# CI Claude Runtime — base image
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §3.4 layer 1, §4.3 OCI labels, §7.3 image ENV

# Pinned by digest, not tag. Verified live 2026-05-01.
# v1: linux/amd64 only (GHA hosted runners are amd64). The --platform flag below
# is explicit so the build is unambiguous regardless of buildx default platform.
# Re-verify before bumping: docker manifest inspect --verbose node:20-slim
FROM --platform=linux/amd64 node:20-slim@sha256:3d0f05455dea2c82e2f76e7e2543964c30f6b7d673fc1a83286736d44fe4c41c

# Build args populated by docker/build-push-action. ALL are required so the
# image's OCI labels can stand alone as a reproducibility manifest (§4.3).
ARG PRIVATE_REF
ARG PRIVATE_SHA
ARG MARKETPLACE_SHA
ARG PUB_SHA
# CLI_VERSION pin (inquisitor pass 1 finding #5 mitigation). Default is the npm
# `stable` dist-tag value verified on 2026-05-01. The build workflow passes the
# value explicitly so it's also captured in the cache-key tuple and labels.
ARG CLI_VERSION=2.1.118

# §4.3 OCI labels — every image carries the pinned refs as labels so any built
# image is reproducible from its labels alone. Six labels total (R5):
LABEL org.opencontainers.image.source="https://github.com/glitchwerks/github-actions" \
      org.opencontainers.image.revision="${PUB_SHA}" \
      dev.glitchwerks.ci.private_ref="${PRIVATE_REF}" \
      dev.glitchwerks.ci.private_sha="${PRIVATE_SHA}" \
      dev.glitchwerks.ci.marketplace_sha="${MARKETPLACE_SHA}" \
      dev.glitchwerks.ci.cli_version="${CLI_VERSION}"

# Minimum runtime deps. Combine RUN steps to shrink layer count.
# `git` and `curl` are needed by the Claude Code CLI install path; `ca-certificates`
# for HTTPS; `jq` is required by smoke-test.sh's structured-output parser.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
 && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI at the pinned version. The version flows from the
# manifest-table pin → CLI_VERSION ARG → this RUN → the cli_version OCI label.
# Reproducibility chain: a build with the same CLI_VERSION produces the same
# /usr/local/lib/node_modules/@anthropic-ai/claude-code tree (modulo npm's
# transient-dep pinning, which is captured by package-lock at npm registry side).
RUN npm install -g "@anthropic-ai/claude-code@${CLI_VERSION}"

# Layer order rationale (inquisitor pass 2 Charge 1 mitigation):
#   1. COPY shared/   — creates /opt/claude/.claude/ tree (root-owned by default)
#   2. chmod tree     — flatten dir/file modes to 0755/0644
#   3. useradd        — register passwd entry for UID 1001 with pw_dir=/opt/claude.
#                       /opt/claude EXISTS at this point (step 1 created it), so
#                       useradd has unambiguous semantics: create passwd entry
#                       only, do NOT auto-create the home dir or copy /etc/skel.
#   4. chown tree     — flip ownership of the now-existing tree to runner:runner.
#   5. symlink        — /root/.claude → /opt/claude/.claude (path-b satisfaction)
# Any future RUN inserted between (1) and (4) inherits root-ownership and breaks
# the perms-regression smoke check (R3) — that's the trip-wire.

# Materialized shared tree (built by extract-shared.sh) lands at /opt/claude/.claude/
# The build context's `shared/` directory is the OUT_DIR from the workflow's STAGE 2.
COPY --chmod=0755 shared/ /opt/claude/.claude/

# §6.2 STAGE 3 read-side note (applied here in base so overlays inherit):
# /opt/claude/.claude/ MUST be world-readable so a non-root consumer process can
# load agents, hooks, and CLAUDE.md. COPY --chmod=0755 sets directory mode;
# we still need to set file mode 0644.
RUN find /opt/claude/.claude -type f -exec chmod 0644 {} + \
 && find /opt/claude/.claude -type d -exec chmod 0755 {} +

# §13 Q1 mitigation (path c — passwd entry for UID 1001):
# `node:20-slim` does not have a passwd entry for UID 1001 by default. The
# entry is purely structural — code paths that call getpwuid(1001) get a
# valid struct passwd back with pw_dir=/opt/claude. The functional behavior
# is identical to path (a) because HOME=/opt/claude is set as ENV; we add
# the passwd entry so that any future code path resolving via passwd
# (rather than HOME env) does not silently fall back to a different root.
# `--no-create-home` is intentional: /opt/claude already exists from the COPY
# above; useradd should create the passwd entry only.
RUN useradd -u 1001 -d /opt/claude -s /bin/bash --no-create-home runner \
 && chown -R 1001:1001 /opt/claude

# §13 Q1 mitigation (path b — hard-coded /root/.claude): some Claude Code CLI
# versions resolve config from /root/.claude regardless of HOME. The symlink
# makes the same tree reachable from that path with no duplication.
RUN ln -s /opt/claude/.claude /root/.claude

# §7.3 image ENV — inherited by every overlay and every process the container runs.
# Consumer workflows must NOT override these; documented in §9.2.
ENV PATH_TO_CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude \
    HOME=/opt/claude

# §13 Q1 verification: Task 5 below proves all three CLI resolution paths
# (HOME env, /root/.claude, getpwuid(1001).pw_dir) reach the config tree.
# Each path is independently verified before the Dockerfile is committed.

# Default command is the claude binary. Smoke test overrides with `--print ...`.
ENTRYPOINT ["/usr/local/bin/claude"]
CMD ["--help"]
```

- [ ] **Step 2.4.3: Local-build smoke (optional, requires Docker on the dev machine)**

```bash
# From the worktree root, with the same OUT_DIR layout STAGE 2 will produce
TMP=$(mktemp -d)
# (assume Task 1 smoke already populated $TMP/out1 with extract-shared output)
mkdir -p "$TMP/build-context/shared"
cp -r "$TMP/out1/." "$TMP/build-context/shared/"
cp runtime/base/Dockerfile "$TMP/build-context/Dockerfile"

docker build \
  --build-arg PRIVATE_REF=ci-v0.1.0 \
  --build-arg PRIVATE_SHA=$(git -C "$TMP/private" rev-parse HEAD) \
  --build-arg MARKETPLACE_SHA=0742692199b49af5c6c33cd68ee674fb2e679d50 \
  --build-arg PUB_SHA=$(git rev-parse HEAD) \
  -t claude-runtime-base:local \
  "$TMP/build-context"
```

Expected: image builds without errors. Failures here are most often missing `shared/` files (re-run Task 1 with the correct env), or a stale `node:20-slim` digest (re-verify per Step 2.4.1).

- [ ] **Step 2.4.4: Commit**

```bash
git add runtime/base/Dockerfile
git commit -m "feat(ci-runtime): add base/Dockerfile pinned to node:20-slim@sha256:3d0f0... (refs #140)"
```

---

## Task 5: §13 Q1 — HOME resolution live verification (three paths)

**Purpose:** §13 Q1 has been pending since Phase 0. This task closes it by independently verifying that **all three Claude Code CLI config-resolution paths** reach `/opt/claude/.claude/`:

- **Path (a) — `HOME` env honored.** `HOME=/opt/claude` → CLI reads `$HOME/.claude` → `/opt/claude/.claude`
- **Path (b) — Hard-coded `/root/.claude`.** Some CLI versions read `/root/.claude` regardless of `HOME`. Symlink in Dockerfile makes this resolve to the same tree.
- **Path (c) — `pwd.getpwuid(uid).pw_dir` structural sanity check.** A subset of CLI/runtime config-loading code paths resolve `~` against the passwd database for the runtime UID. The Dockerfile creates a passwd entry mapping UID 1001 → `/opt/claude`. **Honest disclosure (inquisitor pass 2 Charge 4):** path (c) is functionally identical to path (a) when `HOME` env is also set — both resolve to `/opt/claude`. The verification below is a structural sanity check that the Dockerfile's `useradd` step produced the right passwd entry, not a behavioral test that the CLI takes path (c). The functional coverage comes from path (a). Path (c) verification exists to catch a future Dockerfile edit that drops or breaks the `useradd` step before that breaks something downstream.

**Inquisitor pass 1 finding #4 mitigation:** the previous draft assumed the symlink was sufficient. It is not — symlink only fixes path (b). Paths (a) and (c) are orthogonal. If the CLI takes path (c) for any reason (e.g. a plugin's hook resolves `os.path.expanduser('~')` directly), neither HOME nor the symlink saves it. The Dockerfile now addresses all three; this task proves all three work independently before any code lands.

This is a **gate** — Tasks 6, 7, 8 cannot proceed if any of the three paths fails. Empty enumeration on any path means the Dockerfile needs more work, not "good enough on one path."

**Files:**
- Modify: `runtime/base/Dockerfile` (only if a path-specific fix is needed beyond the three already in place)

- [ ] **Step 2.5.1: Local build**

```bash
docker build -t claude-runtime-base:q1-test \
  --build-arg PRIVATE_REF=ci-v0.1.0 \
  --build-arg PRIVATE_SHA=$(git -C "$TMP/private" rev-parse HEAD) \
  --build-arg MARKETPLACE_SHA=0742692199b49af5c6c33cd68ee674fb2e679d50 \
  --build-arg PUB_SHA=$(git rev-parse HEAD) \
  --build-arg CLI_VERSION=2.1.118 \
  "$TMP/build-context"
```

- [ ] **Step 2.5.2: Path (a) — HOME env honored**

```bash
SCHEMA='{"type":"object","required":["agents","skills","plugins"],"properties":{"agents":{"type":"array","items":{"type":"string"}},"skills":{"type":"array","items":{"type":"string"}},"plugins":{"type":"array","items":{"type":"string"}}}}'
docker run --rm \
  --user 1001 \
  -e HOME=/opt/claude \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  claude-runtime-base:q1-test \
  --print --output-format json --json-schema "$SCHEMA" \
  "Enumerate every agent, skill, and plugin available. Return a JSON object with keys agents, skills, plugins, each an array of names." \
  | tee /tmp/q1-path-a.json
```

Assertion: `jq -r '.is_error' /tmp/q1-path-a.json` is `false`, `jq -r '.subtype' /tmp/q1-path-a.json` is `success`, and `jq -r '.structured_output.agents | length' /tmp/q1-path-a.json` ≥ 1 (same for `.structured_output.skills`, `.structured_output.plugins`). Record counts. **Note:** payload lives at `.structured_output`, NOT `.result | fromjson` — see Task 3 envelope-shape verification.

- [ ] **Step 2.5.3: Path (b) — /root/.claude reachable (HOME unset, run as root)**

```bash
docker run --rm \
  --user 0 \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  --entrypoint /bin/sh \
  claude-runtime-base:q1-test \
  -c 'unset HOME; ls -la /root/.claude/agents/ops.md && /usr/local/bin/claude --print --output-format json "Output JSON with keys agents, skills, plugins each an array of names."' \
  | tee /tmp/q1-path-b.txt
```

Assertion: the `ls` succeeds (proves symlink target reachable) AND the `claude` invocation enumerates non-empty arrays. Record counts.

- [ ] **Step 2.5.4: Path (c) — getpwuid(1001).pw_dir resolves**

```bash
docker run --rm \
  --user 1001 \
  --entrypoint /bin/sh \
  claude-runtime-base:q1-test \
  -c 'getent passwd 1001 && python3 -c "import pwd; print(pwd.getpwuid(1001).pw_dir)"' \
  2>&1 | tee /tmp/q1-path-c.txt
```

Wait — `node:20-slim` does not have python by default. Adjust:

```bash
docker run --rm \
  --user 1001 \
  --entrypoint /bin/sh \
  claude-runtime-base:q1-test \
  -c 'getent passwd 1001'
```

Assertion: the `getent` output is `runner:x:1001:1001::/opt/claude:/bin/bash` (exact home directory `/opt/claude`). This proves path (c) resolves to the right tree without needing python. The functional confirmation that path (c) works at CLI level happens via path (a) (since HOME=/opt/claude is what `getpwuid(1001).pw_dir` returns), so path (c) is structurally identical to path (a) when HOME isn't set. Record the `getent` output as evidence.

- [ ] **Step 2.5.5: Record outcomes in Dockerfile + PR body**

Append a comment block to `runtime/base/Dockerfile` near the `ENV HOME=` line:

```dockerfile
# §13 Q1 verified on 2026-MM-DD against image @sha256:<build-digest>:
#   Path (a) HOME=/opt/claude → agents=N skills=M plugins=P (non-empty)
#   Path (b) /root/.claude symlink reachable as UID 0 → enumeration non-empty
#   Path (c) getent passwd 1001 → home=/opt/claude (matches HOME)
# All three paths converge on /opt/claude/.claude/. §13 Q1 closed.
```

Replace placeholders with values from Steps 2.5.2–2.5.4. Append the same outcome to the PR #171 body under a "§13 Q1 outcome" section.

- [ ] **Step 2.5.6: Decision tree if any path fails**

| Failing path | Likely cause | Fix |
|---|---|---|
| (a) HOME env | CLI hard-codes `/root/.claude` | Already mitigated by symlink (path b). If (a) still fails, the CLI is reading `~/.config/claude/` or similar XDG path — adjust Dockerfile to symlink that path too. Investigate via `strace -f -e openat -e stat docker run ... claude --print`. |
| (b) /root/.claude | Symlink target wrong | Verify `ls -la /root/.claude` resolves to `/opt/claude/.claude` inside the image. |
| (c) getent passwd | `useradd` step failed silently | Check Dockerfile build log. Try `RUN useradd -u 1001 ...` standalone. |

If a fix is required, edit the Dockerfile, re-build, re-run all three steps. Do NOT short-circuit — all three paths must pass before this task is checked off.

---

## Task 6: Replace `runtime/shared/CLAUDE-ci.md` stub with full base persona

**Purpose:** Phase 1 left this file as a stub (`> Stub. Full content in Phase 2.`). Phase 2 fills it in. Content scopes the base persona: lists the curated plugin surface, names the shared skills + `ops` agent as mandatory, documents the "different set of eyes" principle, references `standards/software-standards.md`.

**Files:**
- Modify: `runtime/shared/CLAUDE-ci.md`

- [ ] **Step 2.6.1: Author**

Replace the stub with content derived from §3.4 layer 1 + §14 brainstorming decisions + Appendix B plugin catalog. The exact prose is left as a writing task during execution but MUST cover:

1. **Identity:** "You are running inside the CI Claude Runtime — a containerized environment that powers automated GitHub Actions on this repository's PRs and issues. You are intentionally a different set of eyes from the user's local Claude Code."
2. **Available context:** lists `git` and `python` skills; `ops` agent; the six base plugins (`context7`, `github`, `microsoft-docs`, `typescript-lsp`, `skill-creator`, `security-guidance` cherry-pick).
3. **Standards reference:** `@standards/software-standards.md` (loaded into base via the manifest's `imports_from_private.standards`).
4. **Operational rules:** ephemeral runner — no persistent memory. Composes at runtime with the consumer repo's `CLAUDE.md` and any overlay `CLAUDE.md`.
5. **Forbidden:** writing to `/opt/claude/.claude/` at runtime (image is read-only mount in production); attempting to install plugins at runtime.

The target is ~80–150 lines, similar length to other CLAUDE.md authored under `claude-configs/`.

- [ ] **Step 2.6.2: Commit**

```bash
git add runtime/shared/CLAUDE-ci.md
git commit -m "feat(ci-runtime): replace CLAUDE-ci.md stub with base persona content (refs #140)"
```

---

## Task 7: Append STAGE 2 + STAGE 4 to `runtime-build.yml`

**Purpose:** Wire the build pipeline. STAGE 2 builds + pushes `:pending-<pubsha>` to GHCR. STAGE 4 calls `smoke-test.sh` against the pending tag. Both stages are sequential (STAGE 2 must finish before STAGE 4 can pull).

**Files:**
- Modify: `.github/workflows/runtime-build.yml`

- [ ] **Step 2.7.1: Append the new jobs**

After the existing `stage-1` job, add:

```yaml
  stage-2:
    name: STAGE 2 — build + push base
    needs: stage-1
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: read
      packages: write
    outputs:
      base_digest: ${{ steps.build.outputs.digest }}
      pending_tag: pending-${{ github.sha }}
    steps:
      - name: Checkout
        uses: actions/checkout@v5
        with:
          fetch-depth: 1

      - name: Restore source clones from STAGE 1
        # STAGE 1 cloned /tmp/private and /tmp/marketplace; jobs share runner
        # state ONLY when on the same job. New job = new runner. Re-clone here.
        env:
          GH_PAT: ${{ secrets.GH_PAT }}
        run: |
          set -euo pipefail
          PRIVATE_REF=$(yq -r '.sources.private.ref' runtime/ci-manifest.yaml)
          MARKETPLACE_SHA=$(yq -r '.sources.marketplace.ref' runtime/ci-manifest.yaml)
          git clone --depth 1 --branch "$PRIVATE_REF" \
            "https://x-access-token:${GH_PAT}@github.com/glitchwerks/claude-configs" \
            /tmp/private
          git clone https://github.com/anthropics/claude-plugins-official /tmp/marketplace
          git -C /tmp/marketplace checkout "$MARKETPLACE_SHA"
          echo "PRIVATE_REF=$PRIVATE_REF" >> "$GITHUB_ENV"
          echo "PRIVATE_SHA=$(git -C /tmp/private rev-parse HEAD)" >> "$GITHUB_ENV"
          echo "MARKETPLACE_SHA=$MARKETPLACE_SHA" >> "$GITHUB_ENV"

      - name: Install yq
        run: |
          set -euo pipefail
          sudo curl -fsSL -o /usr/local/bin/yq \
            https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq

      - name: Run extract-shared.sh into build context
        env:
          MANIFEST: runtime/ci-manifest.yaml
          PRIVATE_TREE: /tmp/private
          MARKETPLACE_TREE: /tmp/marketplace
          SHARED_TREE: ${{ github.workspace }}
          OUT_DIR: ${{ runner.temp }}/build-context/shared
        run: |
          set -euo pipefail
          chmod +x runtime/scripts/extract-shared.sh
          bash runtime/scripts/extract-shared.sh
          cp runtime/base/Dockerfile ${{ runner.temp }}/build-context/Dockerfile

      - name: Compute cache key
        id: cache-key
        run: |
          set -euo pipefail
          # §6.2 cache-key tuple, expanded after inquisitor pass 1 finding #1.
          # Original tuple was (manifest, private SHA, marketplace SHA, extract-shared.sh hash);
          # that did NOT bust the layer on Dockerfile or smoke-test contract changes,
          # producing stale layers when a Dockerfile-only edit landed. Expanded to 7:
          MANIFEST_HASH=$(sha256sum runtime/ci-manifest.yaml | awk '{print $1}')
          EXTRACT_HASH=$(sha256sum runtime/scripts/extract-shared.sh | awk '{print $1}')
          DOCKERFILE_HASH=$(sha256sum runtime/base/Dockerfile | awk '{print $1}')
          SMOKE_HASH=$(sha256sum runtime/scripts/smoke-test.sh | awk '{print $1}')
          # node:20-slim digest is part of the Dockerfile FROM line, so DOCKERFILE_HASH
          # already busts the cache when the digest changes. NOT redundantly included
          # in the tuple below (inquisitor pass 2 Charge 2). The npm-resolved CLI
          # tarball IS NOT covered by CLI_VERSION alone — npm permits re-publish within
          # a 72-hour window. Mitigation: capture the tarball SHA from `npm view` once
          # at build time and include it. That step is added to STAGE 1b (separate task).
          # CLI version (build-arg): captured here for cache-key isolation
          CLI_VERSION="2.1.118"
          KEY="${MANIFEST_HASH:0:12}-${PRIVATE_SHA:0:12}-${MARKETPLACE_SHA:0:12}-${EXTRACT_HASH:0:12}-${DOCKERFILE_HASH:0:12}-${SMOKE_HASH:0:12}-${CLI_VERSION}"
          echo "key=$KEY" >> "$GITHUB_OUTPUT"
          echo "cli_version=$CLI_VERSION" >> "$GITHUB_OUTPUT"
          echo "cache-key: $KEY"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4

      - name: Login to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build + push base image
        id: build
        uses: docker/build-push-action@v7
        with:
          context: ${{ runner.temp }}/build-context
          file: ${{ runner.temp }}/build-context/Dockerfile
          push: true
          platforms: linux/amd64
          tags: |
            ghcr.io/glitchwerks/claude-runtime-base:pending-${{ github.sha }}
            ghcr.io/glitchwerks/claude-runtime-base:${{ github.sha }}
          build-args: |
            PRIVATE_REF=${{ env.PRIVATE_REF }}
            PRIVATE_SHA=${{ env.PRIVATE_SHA }}
            MARKETPLACE_SHA=${{ env.MARKETPLACE_SHA }}
            PUB_SHA=${{ github.sha }}
            CLI_VERSION=${{ steps.cache-key.outputs.cli_version }}
          cache-from: type=gha,scope=base-${{ steps.cache-key.outputs.key }}
          cache-to: type=gha,mode=max,scope=base-${{ steps.cache-key.outputs.key }}
          # provenance defaults to true — keep BuildKit SLSA attestations on so
          # Phase 6 rollback / forensic investigations can prove image origin.
          # (inquisitor pass 1 lower-priority concern: removed the previous
          # `provenance: false` which silently disabled this without justification)

      - name: Echo digest
        run: echo "base digest = ${{ steps.build.outputs.digest }}"

  stage-4:
    name: STAGE 4 — smoke + secret scan (base)
    needs: stage-2
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      packages: read
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Login to GHCR (read)
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Capture runner UID
        id: uid
        run: echo "uid=$(bash runtime/scripts/capture-runner-uid.sh)" >> "$GITHUB_OUTPUT"

      - name: Smoke base
        env:
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          CI: "true"
          SMOKE_UID: ${{ steps.uid.outputs.uid }}
        run: |
          chmod +x runtime/scripts/smoke-test.sh
          bash runtime/scripts/smoke-test.sh \
            "ghcr.io/glitchwerks/claude-runtime-base:pending-${{ github.sha }}" \
            "base"
```

Note: the existing `stage-1` job already has the `concurrency` block — keep it unchanged. The `concurrency` group covers all jobs in the workflow run, so STAGE 2 and STAGE 4 inherit the §6.1.1 protection automatically.

- [ ] **Step 2.7.2: Required new secret — none, all already present**

`GH_PAT` (Phase 0), `GITHUB_TOKEN` (ambient), `CLAUDE_CODE_OAUTH_TOKEN` (existing, used by other workflows). No new secret provisioning.

- [ ] **Step 2.7.3: Commit**

```bash
git add .github/workflows/runtime-build.yml
git commit -m "feat(ci-runtime): append STAGE 2 + STAGE 4 to runtime-build.yml (refs #140)"
```

---

## Task 8: Live dry-run + GHCR package creation + immutability toggle

**Purpose:** First end-to-end run of STAGE 1→1b→2→4. The first STAGE 2 push to `ghcr.io/glitchwerks/claude-runtime-base` is what *creates* the GHCR package. Once it exists, the operator immediately enables "Prevent tag overwrites" so subsequent runs find the package immutability-on. **Phase 2 makes progress on Phase 0 #138 C3 by closing the `claude-runtime-base` slot — but Phase 0 #138 stays OPEN until Phase 3 closes the remaining three slots.**

**GHCR package-creation race (inquisitor pass 1 operational concern):** between Step 2.8.2 (push creates package, immutability OFF by default) and Step 2.8.3 (operator toggles immutability ON), there is a window where a second `workflow_dispatch` for a different commit SHA could push to a still-mutable `:pending-<sha>`. The §6.1.1 concurrency block keys on `github.sha`, so it does NOT serialize two dispatches on different SHAs against the same package. Operational mitigation: the operator running Step 2.8.3 must coordinate quietly — do NOT push additional commits to `phase-2-base-image` between Steps 2.8.2 and 2.8.3, and do NOT trigger a second dispatch from another branch. The window is short (seconds to minutes); risk is low but real. Documented here because the structural fix (atomic toggle-during-push) is not available in the GHCR API.

**Critical ordering:**
1. Push the branch + open the draft PR.
2. Run `workflow_dispatch(images=base)` against the branch.
3. STAGE 2 succeeds → GHCR package `claude-runtime-base` now exists (still mutable).
4. **Operator action (do not interleave with other dispatches):** navigate to `https://github.com/orgs/glitchwerks/packages/container/claude-runtime-base/settings` and toggle "Prevent tag overwrites" ON.
5. Run `workflow_dispatch(images=base)` again. The preflight (still in `GHCR_ALLOW_MISSING_PACKAGES=1` mode) now finds `claude-runtime-base` exists AND has immutability ON, and reports `verified=1, missing=3`.
6. STAGE 4 smoke completes green (structured-output enumeration + label completeness + perms regression all pass).

DO NOT remove `GHCR_ALLOW_MISSING_PACKAGES` in this task — that retarget is Task 9. The other three packages don't exist until Phase 3 creates them.

**Files:**
- None (this is a CI dry-run + GitHub UI ops)

- [ ] **Step 2.8.1: Push the branch + open draft PR**

```bash
git push -u origin phase-2-base-image
gh pr create --draft --title "feat(ci-runtime): Phase 2 base image + STAGE 2 & STAGE 4 pipeline" \
  --body "$(cat <<'EOF'
## Summary

Phase 2 of the CI Claude Runtime epic.

- Adds `runtime/base/Dockerfile` (pinned `node:20-slim@sha256:3d0f...`)
- Adds `extract-shared.sh` (deterministic; cache-key denominator)
- Adds `smoke-test.sh` + `capture-runner-uid.sh`
- Appends STAGE 1b (determinism check), STAGE 2 (build+push base), STAGE 4 (smoke+secret scan) to `runtime-build.yml`
- Replaces `runtime/shared/CLAUDE-ci.md` stub with full base persona
- Closes Phase 0 #138 C3 for the `claude-runtime-base` slot
- Removes `GHCR_ALLOW_MISSING_PACKAGES` bootstrap bridge (kill criterion from Phase 1)

## §13 Q1 outcome

(filled in after Task 5 completes)

## Test plan

- [ ] STAGE 1→1b→2→4 dispatch dry-run is green
- [ ] Determinism check passes
- [ ] Base image enumerates non-zero agents/skills/plugins as UID 1001
- [ ] Secret-hygiene scan finds nothing
- [ ] All four GHCR packages have "Prevent tag overwrites" enabled (verified by preflight)

Closes #140

🤖 *Generated by Claude Code on behalf of @cbeaulieu-gt*
EOF
)"
```

- [ ] **Step 2.8.2: First dispatch — expect `claude-runtime-base` package creation**

```bash
gh workflow run runtime-build.yml --ref phase-2-base-image -f images=base
gh run watch
```

Expected outcome at this step: STAGE 1 green (preflight reports `verified=0, missing=4` — all four packages still 404, bootstrap bridge active). STAGE 1b green (determinism). STAGE 2 green — and **`ghcr.io/glitchwerks/claude-runtime-base` now exists in the org's GHCR packages list**. STAGE 4 green.

If STAGE 2 fails before pushing (e.g. permission errors), check that the workflow's `permissions: { packages: write }` is set on the `stage-2` job. If STAGE 4 fails on enumeration, see Task 5 §13 Q1 fallback.

- [ ] **Step 2.8.3: Operator action — enable tag immutability on the new package**

Navigate to `https://github.com/orgs/glitchwerks/packages/container/claude-runtime-base/settings`. Under "Manage package", toggle **"Prevent tag overwrites"** ON. Capture a screenshot for the PR body.

- [ ] **Step 2.8.4: Second dispatch — verify preflight now reports verified=1**

```bash
gh workflow run runtime-build.yml --ref phase-2-base-image -f images=base
gh run watch
```

Expected: STAGE 1 preflight stdout includes `ghcr-immutability-preflight: 1 verified, 3 missing (bootstrap)`. The `claude-runtime-base` package is now both existing AND immutable. The other three (`review`, `fix`, `explain`) are still missing (created in Phase 3).

- [ ] **Step 2.8.5: Append §13 Q1 outcome + screenshot to PR body**

Per Task 5 Step 2.5.5 — record the verified-vs-fallback path, counts, and date. Append a screenshot of the GHCR package settings showing immutability ON.

---

## Task 9: Honestly retarget the `GHCR_ALLOW_MISSING_PACKAGES` TODO

**Purpose:** Phase 1's plan assumed Phase 2 would create all four GHCR packages and removed `GHCR_ALLOW_MISSING_PACKAGES` as the kill criterion for that assumption. **Phase 1's plan was wrong.** Phase 2 only creates `claude-runtime-base` — the other three packages don't exist until Phase 3's overlay matrix runs. The honest fix is to amend Phase 1's plan retroactively (out of scope for this branch — tracked as a follow-up task) and to retarget the `TODO(phase-2)` marker here so the operational state remains correct.

**This is not a "deferral" — it's an amendment.** Calling it a deferral would imply the original Phase 1 plan was correct and we chose to defer execution. That's not what happened: the plan was bug, the bug ships in `main` until Phase 1's plan is amended, and Task 9 is the operational fix that prevents Phase 3 reviewers from being confused about whose responsibility the removal was.

**Inquisitor pass 1 finding (lower-priority):** the previous draft of this task framed the retarget as "documentation only — no code edits." That undersold the change. Retargeting a TODO comment IS a code edit that changes operator behavior — the next reviewer reads "TODO(phase-3)" and looks for the closure in Phase 3's PR, not Phase 2's. Frame it correctly.

**Files:**
- Modify: `.github/workflows/runtime-build.yml` (comment retarget)

- [ ] **Step 2.9.1: Retarget the comment**

In `runtime-build.yml`, the existing comment block reads:

```yaml
          # TODO(phase-2): remove GHCR_ALLOW_MISSING_PACKAGES once the Phase 2
          # base image build creates the four GHCR packages. Until then, 404s
          # are expected ...
```

Update to:

```yaml
          # AMENDMENT(phase-3, 2026-05-01): the Phase 1 plan assumed Phase 2 would
          # create all four GHCR packages and remove this env var. That assumption
          # was wrong — Phase 2 creates claude-runtime-base only; the remaining
          # three packages (claude-runtime-{review,fix,explain}) are created by
          # Phase 3's overlay matrix. This env var stays in place through Phase 2
          # and is removed in Phase 3's PR alongside operator-toggling immutability
          # on the three new packages. Tracked: see "Open follow-ups" section of
          # docs/superpowers/plans/phase-2-base-image.md.
          GHCR_ALLOW_MISSING_PACKAGES: "1"
```

- [ ] **Step 2.9.2: Document Phase 1 plan amendment as an open follow-up**

Add a "Open follow-ups" section to this plan (next to Phase 0 progress section) noting:

- Amend `docs/superpowers/plans/phase-1-scaffold.md` "Deviations from master plan" section to correct the original kill-criterion claim. Trigger: open a follow-up PR after Phase 2 merges; this should NOT block Phase 2 because Phase 1 is already merged and the amendment is documentation hygiene.

- [ ] **Step 2.9.3: Commit**

```bash
git add .github/workflows/runtime-build.yml docs/superpowers/plans/phase-2-base-image.md
git commit -m "chore(ci-runtime): retarget GHCR_ALLOW_MISSING_PACKAGES TODO to phase-3, log Phase 1 plan amendment as follow-up (refs #140)"
```

---

## Task 10: Documentation updates

**Files:**
- Modify: `CLAUDE.md` (root)
- Modify: `README.md`

- [ ] **Step 2.10.1: Extend `CLAUDE.md` "CI Runtime" section**

Append to the existing "CI Runtime (Phase 1+)" section a paragraph naming the base image:

```markdown
**Phase 2 status (post-merge of this PR):** the base image at `ghcr.io/glitchwerks/claude-runtime-base@sha256:<digest>` is the foundation for all overlays in Phase 3. It is built from `node:20-slim` (digest-pinned) plus the materialized `shared.*` tree from `runtime/ci-manifest.yaml`. The smoke test asserts non-zero counts for agents/skills/plugins enumerated by Claude Code CLI as a non-root UID. Phase 0 #138 C3 closure: the `claude-runtime-base` package's "Prevent tag overwrites" toggle is now ON; the other three packages close in Phase 3.
```

- [ ] **Step 2.10.2: Update `README.md`**

Add (or extend an existing "CI runtime" section) with:

```markdown
### CI runtime — base image (Phase 2)

`runtime/base/Dockerfile` produces the shared foundation image consumed by every Claude-powered CI overlay. Built and pushed by `.github/workflows/runtime-build.yml` STAGE 2 to `ghcr.io/glitchwerks/claude-runtime-base`. Smoke-tested by STAGE 4 as a non-root UID. See `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §3 for architecture and `docs/superpowers/plans/phase-2-base-image.md` for the implementation plan.
```

- [ ] **Step 2.10.3: Mark PR ready**

```bash
git add CLAUDE.md README.md
git commit -m "docs(ci-runtime): document Phase 2 base image in CLAUDE.md + README (refs #140)"
git push
gh pr ready
```

---

## Phase 0 #138 C3 progress (NOT closure — issue stays OPEN)

Phase 0 acceptance criterion C3: enable "Prevent tag overwrites" on all four GHCR packages. Phase 2 makes progress on the first slot but **does NOT close #138**. Closure happens in Phase 3 when all four slots are done.

| Package | Created by | Immutability toggled by | Slot status after Phase 2 |
|---|---|---|---|
| `claude-runtime-base` | Phase 2, Task 8 Step 2.8.2 | Operator, Task 8 Step 2.8.3 | ✅ slot done |
| `claude-runtime-review` | Phase 3 (overlay matrix) | Operator, Phase 3 | not yet |
| `claude-runtime-fix` | Phase 3 | Operator, Phase 3 | not yet |
| `claude-runtime-explain` | Phase 3 | Operator, Phase 3 | not yet |

**Operator action when Phase 2 merges:** add a comment to issue #138 naming the closed slot (`claude-runtime-base`) and the operator who toggled it; explicitly note that #138 stays OPEN pending Phase 3. Do NOT close #138.

**Inquisitor pass 1 finding mitigation:** the previous draft labeled this "partial closure." That phrase is meaningless on GitHub — issues are open or closed, not partial. Reframed as "progress" with explicit OPEN status until all four slots are done.

---

## Open follow-ups (out of scope for Phase 2 PR, but tracked here)

These items surfaced during Phase 2 planning but do not block Phase 2 merge. Each has a clear trigger.

- **Amend `docs/superpowers/plans/phase-1-scaffold.md`** "Deviations from master plan" section to correct item #3 ("GHCR preflight bootstrap bridge"). Tracked as Issue [#172](https://github.com/glitchwerks/github-actions/issues/172). The kill criterion was originally documented as "Phase 2 removes the bridge" — that assumption was wrong (Phase 2 only creates the base package; the bridge removal happens in Phase 3 when all four packages exist). Trigger: open a documentation-only follow-up PR after Phase 2 merges. Single-file edit, no behavior change.
- **Add `shellcheck` step for `runtime/scripts/*.sh`** — Phase 1's centralized `lint.yml` runs `actionlint` on workflows but no static check exists for the new bash helpers. Trigger: Phase 6 cleanup PR or its own follow-up.
- **STAGE 1 → STAGE 2 artifact handoff** to skip the double-clone of `glitchwerks/claude-configs` and `anthropics/claude-plugins-official`. Optimization, not correctness. Trigger: Phase 6 perf pass.
- **Multi-arch (linux/arm64) base image** — defer until GHA introduces an arm64 hosted runner GA. Trigger: GitHub announcement.

---

## Consumer Requirements (cross-phase contract)

Phase 3 consumes the base image. To preserve producer-side latitude (per `agent-memory/general-purpose/feedback_consumer_requirements_framing.md`), this section states **what** Phase 3 needs from the base image, not **how** Phase 2 must implement it.

| ID | Requirement | Validated by |
|---|---|---|
| **R1** | `FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}` builds when `BASE_DIGEST` is the digest emitted by Phase 2's STAGE 2 job output. | Phase 3 Task 1 (overlay Dockerfile builds) |
| **R2** | `claude -p "<prompt>"` works inside the image without any overlay-level env overrides — `HOME` and `PATH_TO_CLAUDE_CODE_EXECUTABLE` are pre-set. | Phase 3 Task overlay smoke (`smoke-test.sh` reuse) |
| **R3** | `/opt/claude/.claude/` is world-readable: directories `0755`, files `0644`. A non-root overlay process can `find /opt/claude/.claude` and read every file. | Phase 3 smoke (`docker run --user 1001 ... find /opt/claude/.claude` returns no permission errors) |
| **R4** | The base carries the `shared.*` materialized tree per the manifest at the build's pinned `private` ref. Specifically present: `agents/ops.md`, `skills/git/`, `skills/python/`, `CLAUDE.md`, `standards/software-standards.md`, and the six base plugins under `plugins/`. | Phase 3 base smoke (re-run before overlay build) and Phase 3 inventory assertions when each overlay's `expected.yaml` lists base contents under `must_contain` |
| **R5** | OCI labels per §4.3 are set: `org.opencontainers.image.source`, `org.opencontainers.image.revision`, `dev.glitchwerks.ci.private_ref`, `dev.glitchwerks.ci.private_sha`, `dev.glitchwerks.ci.marketplace_sha`. The image is reproducible from labels alone. | Phase 6 `rollback.yml` reads these labels to resolve `:<target_pubsha>` digests |

If any requirement above changes during Phase 2 execution (e.g. R3 must relax to `0750` for some security reason), open a spec amendment PR before merging Phase 2 — the requirements above are the contract Phase 3 will pin against.

---

## Acceptance Criteria (from Issue #140 + inquisitor pass 1 mitigations)

- [ ] **C1** — Base image builds, pushes as `:pending-<pubsha>`, smoke-tests green on STAGE 4. Verify by observing the post-merge push run on `main` is green and `ghcr.io/glitchwerks/claude-runtime-base:pending-<pubsha>` exists.
- [ ] **C2** — `extract-shared.sh` is deterministic. Verify by the STAGE 1b `diff -r` step passing.
- [ ] **C3** — §13 Q1 (HOME resolution) verified across all THREE paths: (a) HOME env, (b) `/root/.claude` symlink, (c) `getent passwd 1001` → `/opt/claude`. Outcomes recorded in Dockerfile comment AND PR body. Empty enumeration on ANY path is a fail; non-empty on path (a) alone is NOT sufficient.
- [ ] **C4** — Smoke secret-hygiene scan finds no auth artifacts under `/opt/claude/.claude/`. Verify by STAGE 4 stdout including `smoke-test: clean`.
- [ ] **C5** — Base image enumerates non-zero agents/skills/plugins as the captured runner UID via `claude --print --output-format json --json-schema`. Structured output, not grep-against-LLM.
- [ ] **C6** — Cache key tuple is sound: bumping ANY of (manifest, private-ref SHA, marketplace SHA, `extract-shared.sh`, `runtime/base/Dockerfile`, `runtime/scripts/smoke-test.sh`, pinned `node:20-slim` digest, pinned `CLI_VERSION`) on a throwaway branch rebuilds the base layer (different cache scope). Verify by changing one component at a time and observing cache miss.
- [ ] **C7** — STAGE 4 label-completeness assertion passes: all six expected OCI labels (`org.opencontainers.image.{source,revision}`, `dev.glitchwerks.ci.{private_ref,private_sha,marketplace_sha,cli_version}`) are present and non-empty.
- [ ] **C8** — STAGE 4 R3 perms regression check passes: `/opt/claude/.claude/` directories are 0755, files are 0644 (no exceptions).
- [ ] **C9** — Phase 0 #138 C3 progress (NOT closure): `claude-runtime-base` slot is done, immutability ON; #138 issue **stays OPEN** with a comment naming the closed slot and pointing to Phase 3 for full closure.
- [ ] **C10** — `actionlint` (centralized via `lint.yml`) passes on the modified `runtime-build.yml`.
- [ ] **C11** — Pinned identifier table (Header → "Pinned identifiers" section) re-verified at execution time: every entry resolves with the documented `gh api` / `docker manifest inspect` / `npm view` command BEFORE Task 1 begins.
- [ ] **C12** — Claude Code CLI `--json-schema` flag verified working on the pinned version `2.1.118` (Step 2.3.1a). If absent, pin bumped to lowest version that supports it AND plan updated accordingly.

---

## Self-Review

**Spec coverage:** Master-plan §Phase 2 tasks 2.1–2.10 each map to a numbered Task in this plan:

- 2.1 → Task 1 (extract-shared.sh)
- 2.2 → Task 1 Step 2.1.4 (STAGE 1b in workflow)
- 2.3 → Task 4 (Dockerfile)
- 2.4 → Task 5 (§13 Q1 verification)
- 2.5 → Task 2 (capture-runner-uid.sh)
- 2.6 → Task 3 (smoke-test.sh)
- 2.7 → Task 7 (runtime-build.yml STAGE 2 + STAGE 4)
- 2.8 → Task 6 (CLAUDE-ci.md full content)
- 2.9 → Task 8 (live dry-run)
- 2.10 → Task 10 (README/CLAUDE.md docs)

Issue #140 acceptance criteria are mapped in the "Acceptance Criteria" section. The user's six hard requirements are addressed: (1) pinned identifiers verified at write-time and tabulated; (2) consumer-requirements framing in the "Consumer Requirements" section; (3) bridge-removal handled in Task 9 with a corrected ownership chain; (4) §13 Q1 explicit verification gate in Task 5; (5) "Deviations from master plan" section above with five entries; (6) "Phase 0 #138 C3 closure" subsection.

**Placeholder scan:** No "TBD"/"figure it out later"/"similar to Task N". The two judgment calls — `node:20-slim` digest re-verification at execution time (Task 4 Step 2.4.1) and the §13 Q1 fallback decision (Task 5 Step 2.5.4) — both have concrete decision trees with the patch instructions if the negative branch is taken.

**Type/name consistency:**
- Env var names match throughout: `MANIFEST`, `PRIVATE_TREE`, `MARKETPLACE_TREE`, `SHARED_TREE`, `OUT_DIR`, `GH_PAT`, `CLAUDE_CODE_OAUTH_TOKEN`, `SMOKE_UID`.
- File paths consistent: `runtime/scripts/{extract-shared,capture-runner-uid,smoke-test}.sh`, `runtime/base/Dockerfile`, `runtime/shared/CLAUDE-ci.md`.
- Image refs consistent: `ghcr.io/glitchwerks/claude-runtime-base:pending-<pubsha>` and `:<pubsha>` per §11.4.
- The marketplace SHA (`0742692199b49af5c6c33cd68ee674fb2e679d50`) and private ref (`ci-v0.1.0`) match the on-`main` Phase 1 manifest verbatim.
- `BASE_DIGEST` is the build-arg name in the consumer-requirements section AND the master-plan task 3.1; matches.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/phase-2-base-image.md` (in the worktree).** Two execution options:

**1. Subagent-Driven (recommended)** — Router dispatches a fresh sub-agent per Task (1–10), reviews between tasks, fast iteration. Strong fit because Tasks 1–7 are independent file authoring; Tasks 8–10 require live CI feedback + GitHub UI ops + PR-body curation and are best handled by the router directly.

**2. Inline Execution** — Execute all tasks in this session using `superpowers:executing-plans`, batched with checkpoints.

**Recommended:** option 1 for Tasks 1–7 (parallelizable file-authoring), then router handles Tasks 8–10 (CI dry-runs + GHCR settings + docs) inline.
