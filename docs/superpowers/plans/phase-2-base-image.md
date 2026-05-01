# Phase 2 Base Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, push, and smoke-test the `claude-runtime-base` image — establishing `extract-shared.sh` determinism, the cache-key tuple, non-root smoke execution, `HOME=/tmp/smoke-home` isolation, secret-hygiene scan, and the `pending-<pubsha>` staging pattern. End-state: a base image at `ghcr.io/glitchwerks/claude-runtime-base@sha256:<digest>` whose smoke run enumerates a non-zero count of agents/skills/plugins as a non-root UID, and whose `:<pubsha>` immutable tag is reachable for Phase 3 to `FROM`.

**Architecture:** A multi-arch base image (linux/amd64 only for v1 — GHA runners are amd64) built on `node:20-slim` pinned by digest. Bash helpers (`extract-shared.sh`, `capture-runner-uid.sh`, `smoke-test.sh`) plus a Dockerfile, all wired into two new stages of the existing `runtime-build.yml`: STAGE 1b (determinism check, appended to STAGE 1), STAGE 2 (build + push pending tag), STAGE 4 (smoke + secret scan). STAGE 3 (overlays) and STAGE 5 (promote) are explicitly NOT in this phase — they belong to Phases 3 and 6 respectively.

**Tech Stack:** Docker BuildKit (via `docker/build-push-action@v7`), GHCR push (via `docker/login-action@v4`), Bash helpers (POSIX-ish, run on `ubuntu-latest`), `mikefarah/yq` v4 (already pinned in Phase 1 to v4.44.3), `jq` (preinstalled), `find`/`tar`/`sha256sum` for determinism.

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

2. **`node:20-slim` pinned by digest, not just tag.** The master plan does not specify base-image pinning. This plan pins `node:20-slim` to the **multi-arch index digest** verified live on 2026-05-01 (see Task 4). Pinning by tag would let Docker Hub re-tag the underlying digest (which it does on every Node patch release) and silently change the cache-key denominator. Digest pin makes the cache key honest.

3. **GHCR_ALLOW_MISSING_PACKAGES removal is its own task (Task 9), not a sub-step of the wiring task.** Bundling it with workflow edits would let a reviewer accidentally land it without verifying the four GHCR packages exist + immutability is on. Splitting it forces the verification gate (Task 8) to land first.

4. **Phase 0 #138 C3 closure happens here.** The Phase 1 plan documented the bootstrap-bridge as the kill trigger for #138 C3. This plan executes that closure — see "Phase 0 #138 C3 closure" subsection below — with explicit ordering: packages exist → immutability toggled → bootstrap bridge removed → preflight runs strict → #138 C3 closed.

5. **Smoke as `actions/runner` UID 1001, not "dynamic capture, then use".** The master plan's task 2.5 specifies a `capture-runner-uid.sh` helper that prints `id -u`. This plan keeps the helper for diagnostic/log purposes but **also** asserts the captured UID equals `1001` in CI. GitHub-hosted Ubuntu runners use `runner` UID 1001; if that ever changes, the assertion fails loud rather than silently smoke-testing under a different UID. Source: §13 Q10 ("either pin or dynamically capture" — this plan does both: capture + assert against the pin).

The Tasks 1–10 below are the merged-state truth.

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
| Base image | `node:20-slim@sha256:3d0f05455dea2c82e2f76e7e2543964c30f6b7d673fc1a83286736d44fe4c41c` (linux/amd64) | `docker manifest inspect --verbose node:20-slim` — extracted amd64 platform digest |
| `docker/build-push-action` | `@v7` (release v7.1.0, SHA `bcafcacb16a39f128d818304e6c9c0c18556b85f`) | `gh api repos/docker/build-push-action/git/refs/tags/v7` |
| `docker/login-action` | `@v4` (release v4.1.0, SHA via `gh api`) | `gh api repos/docker/login-action/releases/latest` |
| `docker/setup-buildx-action` | `@v4` (release v4.0.0, SHA via `gh api`) | `gh api repos/docker/setup-buildx-action/releases/latest` |
| `actions/checkout` | `@v5` (Phase 1 pin, unchanged) | (Phase 1 evidence) |
| `mikefarah/yq` | `v4.44.3` (Phase 1 pin, unchanged) | (Phase 1 evidence) |
| Marketplace SHA | `0742692199b49af5c6c33cd68ee674fb2e679d50` (Phase 1 deviation, unchanged) | (Phase 1 evidence) |
| Private ref | `ci-v0.1.0` (Phase 1 pin, unchanged) | (Phase 1 evidence) |

If any entry above no longer resolves at execution time (e.g. a tag was rewritten or the base image digest moved), STOP and re-pin before proceeding — do not execute Phase 2 against stale pins.

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

**Purpose:** STAGE 4. Runs the image as a non-root UID with `HOME=/tmp/smoke-home`, asserts non-zero counts of agents/skills/plugins, runs the secret-hygiene scan per §6.2 STAGE 4. Designed so Phase 3 reuses it for overlay smoke without modification.

**Files:**
- Create: `runtime/scripts/smoke-test.sh`

- [ ] **Step 2.3.1: Author**

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
#   SMOKE_UID — UID to run as (default: capture from `id -u` on host; CI normally 1001)
#   EXPECTED_FILE — path to expected.yaml (Phase 3+; absent for base smoke)

set -euo pipefail

IMAGE="${1:?image ref required}"
OVERLAY="${2:?overlay name or 'base' required}"

: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN must be set}"

# UID pin (§13 Q10): default to host UID via the helper; assert == 1001 in CI
SMOKE_UID="${SMOKE_UID:-$(bash "$(dirname "$0")/capture-runner-uid.sh")}"
if [ -n "${CI:-}" ] && [ "$SMOKE_UID" != "1001" ]; then
  echo "ERROR smoke_uid_mismatch expected=1001 got=$SMOKE_UID" >&2
  echo "       GitHub-hosted ubuntu-latest runners use UID 1001. If this assertion fires," >&2
  echo "       the runner image has changed and Phase 2/3 smoke contracts need to be updated." >&2
  exit 1
fi
echo "smoke-test: image=$IMAGE overlay=$OVERLAY uid=$SMOKE_UID"

# ---- (a) Run claude inside the image, capture enumeration -----------------
SMOKE_OUT=$(mktemp)
trap 'rm -f "$SMOKE_OUT"' EXIT

docker run --rm \
  --user "$SMOKE_UID" \
  -e HOME=/tmp/smoke-home \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  "$IMAGE" \
  claude -p "List all available agents, skills, and plugins. Output one line per item, prefixed with [agent], [skill], or [plugin]. Then exit." \
  > "$SMOKE_OUT" 2>&1 \
  || { echo "ERROR smoke_run_failed image=$IMAGE"; cat "$SMOKE_OUT"; exit 1; }

agent_count=$(grep -c '^\[agent\]' "$SMOKE_OUT" || true)
skill_count=$(grep -c '^\[skill\]' "$SMOKE_OUT" || true)
plugin_count=$(grep -c '^\[plugin\]' "$SMOKE_OUT" || true)

echo "smoke-test: counts agents=$agent_count skills=$skill_count plugins=$plugin_count"

# §9.2 highest-risk silent failure: empty enumeration = "image works but persona is empty"
if [ "$agent_count" = "0" ] || [ "$skill_count" = "0" ] || [ "$plugin_count" = "0" ]; then
  echo "ERROR empty_enumeration agents=$agent_count skills=$skill_count plugins=$plugin_count" >&2
  echo "--- captured smoke output ---" >&2
  cat "$SMOKE_OUT" >&2
  exit 1
fi

# ---- (b) Inventory assertions (Phase 3+; skipped for base) -----------------
if [ -n "${EXPECTED_FILE:-}" ] && [ -f "${EXPECTED_FILE:-}" ]; then
  echo "smoke-test: running inventory assertions against $EXPECTED_FILE"
  # NOTE: Phase 3 will implement the must_contain/must_not_contain matcher here.
  # Phase 2 base smoke does not have an expected.yaml — skip cleanly.
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

echo "smoke-test: clean (image=$IMAGE overlay=$OVERLAY uid=$SMOKE_UID)"
exit 0
```

- [ ] **Step 2.3.2: chmod + commit (no local smoke yet — needs an image)**

```bash
chmod +x runtime/scripts/smoke-test.sh
git add runtime/scripts/smoke-test.sh
git commit -m "feat(ci-runtime): add smoke-test.sh harness for STAGE 4 (refs #140)"
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
# Re-verify before bumping: docker manifest inspect --verbose node:20-slim
FROM node:20-slim@sha256:3d0f05455dea2c82e2f76e7e2543964c30f6b7d673fc1a83286736d44fe4c41c

# Build args populated by docker/build-push-action. ALL are required so the
# image's OCI labels can stand alone as a reproducibility manifest (§4.3).
ARG PRIVATE_REF
ARG PRIVATE_SHA
ARG MARKETPLACE_SHA
ARG PUB_SHA

# §4.3 OCI labels — every image carries the three pinned refs as labels so
# any built image is reproducible from its labels alone.
LABEL org.opencontainers.image.source="https://github.com/glitchwerks/github-actions" \
      org.opencontainers.image.revision="${PUB_SHA}" \
      dev.glitchwerks.ci.private_ref="${PRIVATE_REF}" \
      dev.glitchwerks.ci.private_sha="${PRIVATE_SHA}" \
      dev.glitchwerks.ci.marketplace_sha="${MARKETPLACE_SHA}"

# Minimum runtime deps. Combine RUN steps to shrink layer count.
# `git` and `curl` are needed by the Claude Code CLI install path; `ca-certificates`
# for HTTPS; `jq` is convenient and used by smoke output parsers.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
 && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally. Pinned via npm; the resolved version is
# captured implicitly in the image layer hash.
# NOTE(phase-2): consider explicit version pin (e.g. @claude-ai/code@<x.y.z>) once
# a stable release line is identified. For now we install latest at build time.
RUN npm install -g @anthropic-ai/claude-code

# Materialized shared tree (built by extract-shared.sh) lands at /opt/claude/.claude/
# The build context's `shared/` directory is the OUT_DIR from the workflow's STAGE 2.
COPY --chmod=0755 shared/ /opt/claude/.claude/

# §6.2 STAGE 3 read-side note (applied here in base so overlays inherit):
# /opt/claude/.claude/ MUST be world-readable so a non-root consumer process can
# load agents, hooks, and CLAUDE.md.
# COPY --chmod=0755 sets directory mode; we still need to set file mode 0644.
RUN find /opt/claude/.claude -type f -exec chmod 0644 {} + \
 && find /opt/claude/.claude -type d -exec chmod 0755 {} +

# §7.3 image ENV — inherited by every overlay and every process the container runs.
# Consumer workflows must NOT override these; documented in §9.2.
ENV PATH_TO_CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude \
    HOME=/opt/claude

# §13 Q1 — HOME=/opt/claude is the design intent. Task 5 (next) verifies the
# Claude Code CLI honors HOME for config discovery. If not, see fallback in Task 5.

# Default command is the claude binary. Smoke test overrides this with `-p "<prompt>"`.
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

## Task 5: §13 Q1 — HOME resolution live verification

**Purpose:** §13 Q1 has been pending since Phase 0. This task makes it concrete: build the base image, run `claude -p` with `HOME=/opt/claude`, assert the agent/skill enumeration is non-empty. If empty, apply the documented fallback (symlink) before committing the Dockerfile.

This is a **gate** — Task 6 onward cannot proceed if §13 Q1 fails.

**Files:**
- Modify: `runtime/base/Dockerfile` (only if fallback is needed)

- [ ] **Step 2.5.1: Build locally (requires Task 4 smoke completed)**

```bash
docker build -t claude-runtime-base:q1-test \
  --build-arg PRIVATE_REF=ci-v0.1.0 \
  --build-arg PRIVATE_SHA=$(git -C "$TMP/private" rev-parse HEAD) \
  --build-arg MARKETPLACE_SHA=0742692199b49af5c6c33cd68ee674fb2e679d50 \
  --build-arg PUB_SHA=$(git rev-parse HEAD) \
  "$TMP/build-context"
```

- [ ] **Step 2.5.2: Run as UID 1001 with HOME=/opt/claude**

```bash
docker run --rm \
  --user 1001 \
  -e HOME=/opt/claude \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  claude-runtime-base:q1-test \
  -p "List all available agents and skills. Output one line per item." \
  | tee /tmp/q1-out.txt
```

Expected: non-empty enumeration listing at least the `ops` agent, `git` skill, `python` skill, and the six base plugins. Empty/zero output = §13 Q1 has failed and the fallback applies.

- [ ] **Step 2.5.3: If non-empty — record the outcome**

Append to `runtime/base/Dockerfile` near the `ENV HOME=` line:

```dockerfile
# §13 Q1 verified at base-image build time on 2026-MM-DD: Claude Code CLI
# honors HOME=/opt/claude for config discovery. Sample run as UID 1001
# enumerated <N> agents / <M> skills / <P> plugins. No fallback needed.
```

Replace the placeholders with the date and counts from your run. Commit.

- [ ] **Step 2.5.4: If empty — apply the symlink fallback**

If the enumeration is empty, the CLI is reading `/root/.claude` (or `~/.claude` resolved against the runtime UID's home, which for UID 1001 is `/home/runner` and doesn't exist in this image). Add to the Dockerfile, just after the `chmod` block:

```dockerfile
# §13 Q1 fallback (applied on 2026-MM-DD after empty enumeration with HOME=/opt/claude):
# Some Claude Code CLI versions resolve config from /root/.claude regardless of HOME.
# Symlinks make /opt/claude/.claude reachable from the well-known root path AND from
# any UID's resolved home directory.
RUN mkdir -p /root && ln -s /opt/claude/.claude /root/.claude
```

Re-build, re-run Step 2.5.2, confirm enumeration is non-empty. Update the comment in the Dockerfile recording date + counts. Commit.

- [ ] **Step 2.5.5: Update PR body**

Once Task 8's draft PR exists (it will), append a "§13 Q1 outcome" section recording: (a) which path was taken (verified vs fallback), (b) the exact counts enumerated, (c) the date of verification. This is the on-record evidence that §13 Q1 is closed.

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
          MANIFEST_HASH=$(sha256sum runtime/ci-manifest.yaml | awk '{print $1}')
          EXTRACT_HASH=$(sha256sum runtime/scripts/extract-shared.sh | awk '{print $1}')
          # §6.2 cache-key tuple: (manifest, private-ref SHA, marketplace SHA, extract-shared.sh hash)
          KEY="${MANIFEST_HASH:0:12}-${PRIVATE_SHA:0:12}-${MARKETPLACE_SHA:0:12}-${EXTRACT_HASH:0:12}"
          echo "key=$KEY" >> "$GITHUB_OUTPUT"
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
          tags: |
            ghcr.io/glitchwerks/claude-runtime-base:pending-${{ github.sha }}
            ghcr.io/glitchwerks/claude-runtime-base:${{ github.sha }}
          build-args: |
            PRIVATE_REF=${{ env.PRIVATE_REF }}
            PRIVATE_SHA=${{ env.PRIVATE_SHA }}
            MARKETPLACE_SHA=${{ env.MARKETPLACE_SHA }}
            PUB_SHA=${{ github.sha }}
          cache-from: type=gha,scope=base-${{ steps.cache-key.outputs.key }}
          cache-to: type=gha,mode=max,scope=base-${{ steps.cache-key.outputs.key }}
          provenance: false

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

**Purpose:** First end-to-end run of STAGE 1→1b→2→4. The first STAGE 2 push to `ghcr.io/glitchwerks/claude-runtime-base` is what *creates* the GHCR package. Once it exists, the operator immediately enables "Prevent tag overwrites" so subsequent runs find the package immutability-on. **This task is the closure trigger for Phase 0 #138 C3 (`claude-runtime-base` slot only — the other three packages close in Phase 3).**

**Critical ordering:**
1. Push the branch + open the draft PR.
2. Run `workflow_dispatch(images=base)` against the branch.
3. STAGE 2 succeeds → GHCR package `claude-runtime-base` now exists.
4. **Operator action:** navigate to `https://github.com/orgs/glitchwerks/packages/container/claude-runtime-base/settings` and toggle "Prevent tag overwrites" ON.
5. Run `workflow_dispatch(images=base)` again. The preflight (still in `GHCR_ALLOW_MISSING_PACKAGES=1` mode) now finds `claude-runtime-base` exists AND has immutability ON, and reports `verified=1, missing=3`.
6. STAGE 4 smoke completes green.

DO NOT remove `GHCR_ALLOW_MISSING_PACKAGES` in this task — that is Task 9, after the green run is recorded.

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

## Task 9: Remove `GHCR_ALLOW_MISSING_PACKAGES` bootstrap bridge

**Purpose:** This is the Phase 1 kill criterion. The bridge was added to let Phase 1 ship before any GHCR packages existed. Now that `claude-runtime-base` exists, the bridge would mask future missing-package regressions for the other three slots — but Phase 2's scope is base only, so removing the bridge will make STAGE 1 fail on the three still-missing overlay packages.

**Decision for Phase 2:** **DO NOT remove the env var in this PR.** Move the removal to Phase 3's PR (which creates the other three packages in the same flow). The Phase 2 PR body documents this and the Phase 1→Phase 3 chain is honest: bridge added → bridge in use → bridge removed when all four packages exist.

This task therefore has no code edits in Phase 2 — just a documentation update.

**Files:**
- Modify: `.github/workflows/runtime-build.yml` (comment update only)

- [ ] **Step 2.9.1: Update the `TODO(phase-2)` comment to `TODO(phase-3)`**

In `runtime-build.yml`, the existing comment block reads:

```yaml
          # TODO(phase-2): remove GHCR_ALLOW_MISSING_PACKAGES once the Phase 2
          # base image build creates the four GHCR packages. Until then, 404s
          # are expected ...
```

Update to:

```yaml
          # TODO(phase-3): remove GHCR_ALLOW_MISSING_PACKAGES once the Phase 3
          # overlay image builds create the remaining three GHCR packages
          # (claude-runtime-{review,fix,explain}). Phase 2 created
          # claude-runtime-base; the bridge keeps the other three 404s
          # non-fatal until Phase 3.
          GHCR_ALLOW_MISSING_PACKAGES: "1"
```

**Why this deviation matters:** The original Phase 1 plan assumed Phase 2 would create all four packages. It doesn't — only Phase 2's base build creates `claude-runtime-base`. The other three are pushed for the first time in Phase 3's overlay matrix. Documenting the corrected ownership here prevents a Phase 3 reviewer from assuming Phase 2 missed something.

- [ ] **Step 2.9.2: Document the chain in the PR body**

Append to the Phase 2 PR body, under a "Phase 0 #138 C3 closure (partial)" section:

> Phase 2 closes the `claude-runtime-base` slot of Phase 0 acceptance criterion C3 (GHCR tag-immutability for all four packages). The remaining three slots (`claude-runtime-{review,fix,explain}`) close in Phase 3 when the overlay matrix creates those packages and the operator toggles immutability on each. The `GHCR_ALLOW_MISSING_PACKAGES=1` bridge added in Phase 1 stays in place until then; its `TODO(phase-2)` marker is now `TODO(phase-3)`.

- [ ] **Step 2.9.3: Commit**

```bash
git add .github/workflows/runtime-build.yml
git commit -m "chore(ci-runtime): retarget GHCR_ALLOW_MISSING_PACKAGES TODO to phase-3 (refs #140)"
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

## Phase 0 #138 C3 closure (partial — `claude-runtime-base` only)

Phase 0 acceptance criterion C3: enable "Prevent tag overwrites" on all four GHCR packages. Phase 2 closes the **first** slot:

| Package | Created by | Immutability toggled by | Closure status after Phase 2 |
|---|---|---|---|
| `claude-runtime-base` | Phase 2, Task 8 Step 2.8.2 | Operator, Task 8 Step 2.8.3 | ✅ closed |
| `claude-runtime-review` | Phase 3 (overlay matrix) | Operator, Phase 3 | open |
| `claude-runtime-fix` | Phase 3 | Operator, Phase 3 | open |
| `claude-runtime-explain` | Phase 3 | Operator, Phase 3 | open |

Phase 0 #138 should NOT be closed at the end of Phase 2 — three slots remain open. Update the issue with a comment naming the closed slot and pointing to Phase 3 for the rest.

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

## Acceptance Criteria (from Issue #140)

- [ ] **C1** — Base image builds, pushes as `:pending-<pubsha>`, smoke-tests green on STAGE 4. Verify by observing the post-merge push run on `main` is green and `ghcr.io/glitchwerks/claude-runtime-base:pending-<pubsha>` exists.
- [ ] **C2** — `extract-shared.sh` is deterministic. Verify by the STAGE 1b `diff -r` step passing.
- [ ] **C3** — §13 Q1 (HOME resolution) outcome recorded in Dockerfile comment AND PR body. Either "verified, no fallback" or "fallback applied via /root/.claude symlink".
- [ ] **C4** — Smoke secret-hygiene scan finds no auth artifacts. Verify by STAGE 4 stdout including `smoke-test: clean`.
- [ ] **C5** — Base image runs as non-root UID 1001 without agent/skill enumeration errors. Verify by STAGE 4 counts being non-zero.
- [ ] **C6** — Cache key scheme verified. Bump `runtime/scripts/extract-shared.sh` (add a comment) on a throwaway branch — confirm the next STAGE 2 run rebuilds the base layer (different cache scope). Revert the bump.
- [ ] **C7** — Phase 0 #138 C3 closure status: `claude-runtime-base` slot is closed (immutability ON); the remaining three slots are documented as Phase 3 closure.
- [ ] **C8** — `actionlint` (centralized) passes on the modified `runtime-build.yml`.

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
