# Phase 1 Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `runtime/` scaffolding, the manifest + JSON Schema, the two-phase validator, the GHCR immutability preflight, and STAGE 1 of the build workflow — proven green on the real `ci-v0.1.0` private content.

**Architecture:** Static files (yaml, json, bash, markdown) + one new GitHub Actions workflow. No Docker, no images. STAGE 1 clones three sources (this repo, `glitchwerks/claude-configs` at the pinned `ci-v*` tag, `anthropics/claude-plugins-official` at the pinned 40-hex SHA), runs `ajv` schema validation, runs the bash semantic validator, runs the GHCR immutability preflight, runs `actionlint`. Each step halts on failure; the job ends green only if all four pass.

**Tech Stack:** Bash (POSIX-ish, run on `ubuntu-latest`), AJV CLI via `npx`, `jq`, `yq` (mikefarah v4), GitHub Actions YAML (`workflow_dispatch` + `push` filtered by `dorny/paths-filter`), JSON Schema draft 2020-12.

**Spec source of truth:** `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §5.1, §5.2, §6.1, §6.2 STAGE 1, §6.3.1, §13 Q8. Master plan: `docs/superpowers/plans/2026-04-22-ci-claude-runtime.md` §Phase 1.

**Issue:** #139. **Branch:** `phase-1-scaffold` (off `main` @ `9eb2ac6`).

---

## Deviations from master plan (recorded during execution)

Four items shifted versus the version of this plan committed at `fe4ef3f`. Each is a minimal, self-contained change with a kill criterion or follow-up trigger.

1. **`pull_request:` trigger added to `runtime-build.yml`** — the master plan's `push: branches: [main]`-only filter made the workflow unreachable from feature branches (`workflow_dispatch` can't dispatch a workflow that isn't on the default branch yet). Added `pull_request: paths: [runtime/**, .github/workflows/runtime-build.yml]` so STAGE 1 validates each PR before merge — the correct gate position. Live in commit `508dbc8`.

2. **Marketplace SHA re-pinned** — the master plan's pinned SHA `f01d614cb6ac4079ec042afe79177802defc3ba7` does not exist in `anthropics/claude-plugins-official` (verified via `gh api` returning HTTP 422 "No commit found for SHA"). It was a placeholder that never got validated at plan-write time. Re-pinned to a real current main HEAD `0742692199b49af5c6c33cd68ee674fb2e679d50`. Live in commit `4556d1c`. **Lesson:** SHA-shaped strings in plans should get a one-line `gh api commits/<sha>` check at write time.

3. **GHCR preflight bootstrap bridge** — Phase 0 acceptance criterion C3 (enable "Prevent tag overwrites" on all four GHCR packages) was deferred to Phase 2 because the packages don't exist until Phase 2's image build creates them. But Phase 1's preflight returns 404 for every package, which fails the build. Resolution: the preflight script gained a semantic distinction — `GHCR_ALLOW_MISSING_PACKAGES=1` converts 404 into `WARN missing` instead of fatal. The workflow sets the env var with a `TODO(phase-2)` marker. Live in commit `6c76e2a`. **Amendment ([#172](https://github.com/glitchwerks/github-actions/issues/172), 2026-05-02):** the original kill-criterion claim ('Phase 2's PR removes the env var; the script strictly verifies immutability on the now-existing packages') was wrong — see Issue [#173](https://github.com/glitchwerks/github-actions/issues/173). Phase 2 implementation (PR [#171](https://github.com/glitchwerks/github-actions/pull/171), merge commit `2df97ff`) discovered that GHCR does not support tag immutability at all; the toggle the spec assumed exists is a community feature request that was never implemented. The actual Phase 2 outcome: the entire preflight script was deleted, `GHCR_ALLOW_MISSING_PACKAGES` was removed because the bridge was checking for a non-existent feature, spec §6.3.1 was amended honestly, and reproducibility is now enforced via digest pins (content-addressed, inherently immutable) rather than registry-side immutability. Phase 3 ([#141](https://github.com/glitchwerks/github-actions/issues/141)) inherits the digest-pin model unchanged.

4. **Break C reproduced as variant, not as specified** — the master plan's Break C (flip "Prevent tag overwrites" OFF on a real package) is structurally unreachable in Phase 1 because the four packages don't exist. Closest faithful equivalent: disable the bootstrap bridge (`GHCR_ALLOW_MISSING_PACKAGES=0`) so the preflight enters strict mode and fails on each 404 with `ERROR ghcr_package_not_found`. Same fatal code path (`errs++; ERROR; exit 1`), different trigger. Run `25196951539`. The original "toggle off" form will be exercisable in Phase 2 once packages exist.

The Tasks 1–8 step-by-step content below remains correct as the *original* execution plan; for the merged-state truth, read in conjunction with this Deviations section.

---

## File Structure

Paths relative to repo root. All created on `phase-1-scaffold` worktree.

```
runtime/
  ci-manifest.yaml                          # task 1.2 — authoritative manifest
  ci-manifest.schema.json                   # task 1.3 — JSON Schema (structural)
  shared/
    CLAUDE-ci.md                            # task 1.1 — stub
  overlays/
    review/CLAUDE.md                        # task 1.1 — stub
    fix/CLAUDE.md                           # task 1.1 — stub
    explain/CLAUDE.md                       # task 1.1 — stub
  scripts/
    validate-manifest.sh                    # task 1.4 — semantic validation
    ghcr-immutability-preflight.sh          # task 1.5 — GHCR tag-immutability check

.github/workflows/
  runtime-build.yml                         # task 1.6 — STAGE 1 only

CLAUDE.md                                   # task 1.8 — append "runtime/" convention bullet
```

---

## Task 1: Bootstrap stub tree

Stub markdown files keep `git mv`-style relocations honest later. Each stub: heading + one sentence stating that full content lands in a later phase.

**Files:**
- Create: `runtime/shared/CLAUDE-ci.md`
- Create: `runtime/overlays/review/CLAUDE.md`
- Create: `runtime/overlays/fix/CLAUDE.md`
- Create: `runtime/overlays/explain/CLAUDE.md`

- [ ] **Step 1.1.1: Create `runtime/shared/CLAUDE-ci.md`**

```markdown
# CLAUDE-ci (shared base)

> **Stub.** Full CI base persona content lands in Phase 2 per §3.4 layer 1 of the design spec. Do not edit beyond the stub until Phase 2.
```

- [ ] **Step 1.1.2: Create `runtime/overlays/review/CLAUDE.md`**

```markdown
# CLAUDE.md — review overlay

> **Stub.** Full review-scoped persona lands in Phase 3 per §3.4 layer 2 of the design spec.
```

- [ ] **Step 1.1.3: Create `runtime/overlays/fix/CLAUDE.md`**

```markdown
# CLAUDE.md — fix overlay

> **Stub.** Full fix-scoped persona lands in Phase 3 per §3.4 layer 2 of the design spec.
```

- [ ] **Step 1.1.4: Create `runtime/overlays/explain/CLAUDE.md`**

```markdown
# CLAUDE.md — explain overlay

> **Stub.** Full explain-scoped (read-only) persona lands in Phase 3 per §3.4 layer 2 of the design spec.
```

- [ ] **Step 1.1.5: Verify tree shape**

Run: `git -C "I:/github-actions/.worktrees/phase-1-scaffold" status --short`
Expected:
```
?? runtime/overlays/explain/CLAUDE.md
?? runtime/overlays/fix/CLAUDE.md
?? runtime/overlays/review/CLAUDE.md
?? runtime/shared/CLAUDE-ci.md
```

- [ ] **Step 1.1.6: Commit**

```bash
git -C "I:/github-actions/.worktrees/phase-1-scaffold" add runtime/
git -C "I:/github-actions/.worktrees/phase-1-scaffold" commit -m "chore(ci-runtime): scaffold runtime/ tree with CLAUDE.md stubs (refs #139)"
```

---

## Task 2: Author `runtime/ci-manifest.yaml`

Literally the §5.1 shape. Pin `sources.private.ref: ci-v0.1.0` (the tag landed in Phase 0). Pin `sources.marketplace.ref` to `f01d614cb6ac4079ec042afe79177802defc3ba7` per the master plan task 1.2. `merge_policy.overrides: []` — no shadowing today.

**Files:**
- Create: `runtime/ci-manifest.yaml`

- [ ] **Step 1.2.1: Write the manifest**

`runtime/ci-manifest.yaml`:

```yaml
# Authoritative CI Claude Runtime manifest.
# Schema: runtime/ci-manifest.schema.json
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §5.1

sources:
  private:
    repo: glitchwerks/claude-configs
    ref: ci-v0.1.0
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
      paths: ["**"]
    github:
      paths: ["**"]
    microsoft-docs:
      paths: ["**"]
    typescript-lsp:
      paths: ["**"]
    skill-creator:
      paths: ["**"]
    security-guidance:
      paths:
        - hooks/hooks.json
        - hooks/security_reminder_hook.py

overlays:
  review:
    plugins:
      pr-review-toolkit:
        paths: ["**"]
    imports_from_private:
      agents: [inquisitor]
    local:
      claude_md: runtime/overlays/review/CLAUDE.md

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
  on_conflict: error
  overrides: []
```

- [ ] **Step 1.2.2: Lint the YAML**

Run: `npx --yes yaml-lint runtime/ci-manifest.yaml` (or `python -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" runtime/ci-manifest.yaml`)
Expected: no output, exit 0.

- [ ] **Step 1.2.3: Commit**

```bash
git add runtime/ci-manifest.yaml
git commit -m "feat(ci-runtime): add ci-manifest.yaml pinned to ci-v0.1.0 (refs #139)"
```

---

## Task 3: Author `runtime/ci-manifest.schema.json`

JSON Schema draft 2020-12. Asserts every structural rule from §5.2:

- `sources.private.ref` regex `^ci-v\d+\.\d+\.\d+$`
- `sources.marketplace.ref` regex `^[a-f0-9]{40}$`
- `overlays` keys ⊆ `{review, fix, explain}` via `additionalProperties: false`
- `merge_policy.on_conflict` enum `["error"]` (single value)
- `merge_policy.overrides` items: non-empty strings (existence check is semantic, not structural)
- `*.imports_from_private.agents` items ⊆ known-agent enum
- Plugin name uniqueness within a scope (YAML parse catches dupes inside one mapping; schema catches across scopes via the semantic validator — but the schema enforces the *shape* here)

The JSON-Schema layer **cannot** verify file existence or cross-scope plugin collisions on its own — those are enforced by the bash semantic validator in Task 4. The schema is the structural floor.

**Files:**
- Create: `runtime/ci-manifest.schema.json`

- [ ] **Step 1.3.1: Write the schema**

`runtime/ci-manifest.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/glitchwerks/github-actions/runtime/ci-manifest.schema.json",
  "title": "CI Claude Runtime manifest",
  "type": "object",
  "additionalProperties": false,
  "required": ["sources", "shared", "overlays", "merge_policy"],
  "properties": {
    "sources": {
      "type": "object",
      "additionalProperties": false,
      "required": ["private", "marketplace"],
      "properties": {
        "private": {
          "type": "object",
          "additionalProperties": false,
          "required": ["repo", "ref"],
          "properties": {
            "repo": { "type": "string", "minLength": 1 },
            "ref": {
              "type": "string",
              "pattern": "^ci-v\\d+\\.\\d+\\.\\d+$"
            }
          }
        },
        "marketplace": {
          "type": "object",
          "additionalProperties": false,
          "required": ["repo", "ref"],
          "properties": {
            "repo": { "type": "string", "minLength": 1 },
            "ref": {
              "type": "string",
              "pattern": "^[a-f0-9]{40}$"
            }
          }
        }
      }
    },
    "shared": { "$ref": "#/$defs/scope" },
    "overlays": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "review":  { "$ref": "#/$defs/scope" },
        "fix":     { "$ref": "#/$defs/scope" },
        "explain": { "$ref": "#/$defs/scope" }
      }
    },
    "merge_policy": {
      "type": "object",
      "additionalProperties": false,
      "required": ["on_conflict", "overrides"],
      "properties": {
        "on_conflict": { "type": "string", "enum": ["error"] },
        "overrides": {
          "type": "array",
          "items": { "type": "string", "minLength": 1 }
        }
      }
    }
  },
  "$defs": {
    "scope": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "imports_from_private": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "skills": {
              "type": "array",
              "items": { "type": "string", "minLength": 1 },
              "uniqueItems": true
            },
            "agents": {
              "type": "array",
              "items": {
                "type": "string",
                "enum": ["ops", "inquisitor", "debugger", "code-writer"]
              },
              "uniqueItems": true
            },
            "claude_md": { "type": "string", "minLength": 1 },
            "standards": { "type": "string", "minLength": 1 }
          }
        },
        "local": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "claude_md": { "type": "string", "minLength": 1 }
          }
        },
        "plugins": {
          "type": "object",
          "additionalProperties": {
            "type": "object",
            "additionalProperties": false,
            "required": ["paths"],
            "properties": {
              "paths": {
                "type": "array",
                "items": { "type": "string", "minLength": 1 },
                "minItems": 1
              }
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 1.3.2: Validate the manifest against the schema locally**

Run:
```bash
npx --yes ajv-cli@5 validate \
  --spec=draft2020 \
  -s runtime/ci-manifest.schema.json \
  -d runtime/ci-manifest.yaml
```

Expected: `runtime/ci-manifest.yaml valid`.

(`ajv-cli` reads YAML when the file extension is `.yaml`. If it complains about YAML support, pre-convert: `npx --yes js-yaml runtime/ci-manifest.yaml > /tmp/m.json && npx --yes ajv-cli@5 validate --spec=draft2020 -s runtime/ci-manifest.schema.json -d /tmp/m.json`.)

- [ ] **Step 1.3.3: Negative test — break the private ref**

Temporarily edit `runtime/ci-manifest.yaml` `sources.private.ref` to `not-a-tag`. Re-run the ajv command. Expected: validation fails with a `pattern` error referencing `^ci-v\d+\.\d+\.\d+$`. Revert.

- [ ] **Step 1.3.4: Negative test — unknown overlay**

Temporarily add an `overlays.write:` block. Re-run ajv. Expected: failure on `additionalProperties` for `overlays`. Revert.

- [ ] **Step 1.3.5: Commit**

```bash
git add runtime/ci-manifest.schema.json
git commit -m "feat(ci-runtime): add ci-manifest.schema.json (structural validation, refs #139)"
```

---

## Task 4: Author `runtime/scripts/validate-manifest.sh`

Semantic validator. Bash, POSIX-ish. **Reads a manifest + cloned source trees from environment-supplied paths**, never clones anything itself (STAGE 1 has already cloned). Reports **all** failures (no early-exit on first error) so the operator sees the full picture.

The script enforces:

- **(a)** Every path in `imports_from_private` (`skills/<name>`, `agents/<name>.md`, `claude_md`, `standards`) exists in `$PRIVATE_TREE`.
- **(b)** Every entry in `merge_policy.overrides` resolves to a real collision: the path exists in both an imported private path AND a `shared/` local source. (For Phase 1, `overrides: []`, so this loop simply runs zero iterations — but the code path must exist for Phase 2.)
- **(c)** Cross-scope plugin collision: no plugin name appears in `shared.plugins` AND any `overlays.<v>.plugins`.

Exit non-zero with one `ERROR <code> <details>` line per failure. Exit zero on success.

**Files:**
- Create: `runtime/scripts/validate-manifest.sh`

- [ ] **Step 1.4.1: Write the validator**

`runtime/scripts/validate-manifest.sh`:

```bash
#!/usr/bin/env bash
# Semantic validation for runtime/ci-manifest.yaml.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §5.2 phase 2
#
# Inputs (env vars):
#   MANIFEST       — path to ci-manifest.yaml (default: runtime/ci-manifest.yaml)
#   PRIVATE_TREE   — path to cloned glitchwerks/claude-configs at the pinned tag (required)
#   SHARED_TREE    — path to cloned local repo (this one) (default: repo root)
#
# Reports ALL failures, never short-circuits. Exit 0 = clean, 1 = at least one ERROR emitted.

set -uo pipefail

MANIFEST="${MANIFEST:-runtime/ci-manifest.yaml}"
PRIVATE_TREE="${PRIVATE_TREE:?PRIVATE_TREE must be set to the cloned claude-configs root}"
SHARED_TREE="${SHARED_TREE:-$(pwd)}"

errs=0
err() { printf 'ERROR %s\n' "$*" >&2; errs=$((errs + 1)); }

# yq is required (mikefarah v4 — the Go one). Do NOT use the python yq.
command -v yq >/dev/null || { echo "FATAL yq (mikefarah v4) not on PATH" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL manifest not found: $MANIFEST" >&2; exit 2; }
[ -d "$PRIVATE_TREE" ] || { echo "FATAL PRIVATE_TREE is not a directory: $PRIVATE_TREE" >&2; exit 2; }

# ---- (a) imports_from_private path-existence checks ----------------------
# Iterate every scope: shared + each overlay.
scopes=$(yq -r '
  ["shared"] + (.overlays // {} | keys)
  | .[]
' "$MANIFEST")

for scope in $scopes; do
  if [ "$scope" = "shared" ]; then
    sel='.shared'
  else
    sel=".overlays.\"$scope\""
  fi

  # skills
  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    p="$PRIVATE_TREE/skills/$skill"
    if [ ! -d "$p" ] && [ ! -f "$p/SKILL.md" ]; then
      err "private_path_missing scope=$scope kind=skill name=$skill expected=$p"
    fi
  done < <(yq -r "$sel.imports_from_private.skills // [] | .[]" "$MANIFEST")

  # agents
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    p="$PRIVATE_TREE/agents/$agent.md"
    [ -f "$p" ] || err "private_path_missing scope=$scope kind=agent name=$agent expected=$p"
  done < <(yq -r "$sel.imports_from_private.agents // [] | .[]" "$MANIFEST")

  # claude_md (single string, optional)
  cm=$(yq -r "$sel.imports_from_private.claude_md // \"\"" "$MANIFEST")
  if [ -n "$cm" ]; then
    p="$PRIVATE_TREE/$cm"
    [ -f "$p" ] || err "private_path_missing scope=$scope kind=claude_md path=$cm expected=$p"
  fi

  # standards (single string, optional)
  st=$(yq -r "$sel.imports_from_private.standards // \"\"" "$MANIFEST")
  if [ -n "$st" ]; then
    p="$PRIVATE_TREE/$st"
    [ -f "$p" ] || err "private_path_missing scope=$scope kind=standards path=$st expected=$p"
  fi
done

# ---- (b) merge_policy.overrides resolves to a real collision -------------
# For Phase 1 this list is empty, but the code path is exercised.
while IFS= read -r ov; do
  [ -z "$ov" ] && continue
  in_private=0
  in_shared=0
  # An override path is named relative to the imported tree root. Check both sides.
  [ -e "$PRIVATE_TREE/$ov" ] && in_private=1
  [ -e "$SHARED_TREE/runtime/shared/$ov" ] && in_shared=1
  if [ "$in_private" = 0 ] || [ "$in_shared" = 0 ]; then
    err "override_no_collision path=$ov in_private=$in_private in_shared=$in_shared"
  fi
done < <(yq -r '.merge_policy.overrides // [] | .[]' "$MANIFEST")

# ---- (c) cross-scope plugin collision ------------------------------------
shared_plugins=$(yq -r '.shared.plugins // {} | keys | .[]' "$MANIFEST" | sort -u)

for scope in $(yq -r '.overlays // {} | keys | .[]' "$MANIFEST"); do
  overlay_plugins=$(yq -r ".overlays.\"$scope\".plugins // {} | keys | .[]" "$MANIFEST" | sort -u)
  collisions=$(comm -12 <(printf '%s\n' "$shared_plugins") <(printf '%s\n' "$overlay_plugins") || true)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    err "plugin_collision plugin=$p paths=[shared.plugins.$p, overlays.$scope.plugins.$p]"
  done <<< "$collisions"
done

if [ "$errs" -gt 0 ]; then
  echo "validate-manifest: $errs error(s)" >&2
  exit 1
fi

echo "validate-manifest: clean"
exit 0
```

- [ ] **Step 1.4.2: Make executable**

Run: `chmod +x runtime/scripts/validate-manifest.sh`

- [ ] **Step 1.4.3: Local smoke — clone the private tag and validate**

```bash
TMP=$(mktemp -d)
git clone --depth 1 --branch ci-v0.1.0 https://x-access-token:${GH_PAT}@github.com/glitchwerks/claude-configs "$TMP/private"
PRIVATE_TREE="$TMP/private" SHARED_TREE="$(pwd)" bash runtime/scripts/validate-manifest.sh
```

Expected stdout: `validate-manifest: clean`. Exit 0.

(If you don't have `GH_PAT` exported locally, run this step in CI via `workflow_dispatch` instead — Task 6's pipeline does exactly this.)

- [ ] **Step 1.4.4: Negative test — missing private path**

Temporarily edit `runtime/ci-manifest.yaml` `shared.imports_from_private.skills` to `[git, python, nonexistent-skill]`. Re-run. Expected: `ERROR private_path_missing scope=shared kind=skill name=nonexistent-skill expected=...`. Revert.

- [ ] **Step 1.4.5: Negative test — induced plugin collision**

Temporarily add `pr-review-toolkit:` (with `paths: ["**"]`) under `shared.plugins`. Re-run. Expected: `ERROR plugin_collision plugin=pr-review-toolkit paths=[shared.plugins.pr-review-toolkit, overlays.review.plugins.pr-review-toolkit]`. Revert.

- [ ] **Step 1.4.6: Commit**

```bash
git add runtime/scripts/validate-manifest.sh
git commit -m "feat(ci-runtime): add validate-manifest.sh semantic validator (refs #139)"
```

---

## Task 5: Author `runtime/scripts/ghcr-immutability-preflight.sh`

Calls the GitHub Container Registry packages API for each of the four runtime packages and asserts tag-immutability is enabled. Exponential backoff on 5xx/429 (3 attempts, base 2s, cap 10s) per §13 Q8. Honors `SKIP_GHCR_IMMUTABILITY=1` for incident override (logs `WARN SKIP`).

**Important — verify the API field name at implementation time.** As of writing, the GHCR packages API exposes immutability via the `tag_immutability` field on the package object (`GET /orgs/{org}/packages/container/{package_name}`), but GitHub has been iterating on this surface. Before final commit, hit the live API once with a known-immutable package and confirm the field name + truthy value. Patch the script if the field has moved.

**Files:**
- Create: `runtime/scripts/ghcr-immutability-preflight.sh`

- [ ] **Step 1.5.1: Write the preflight**

`runtime/scripts/ghcr-immutability-preflight.sh`:

```bash
#!/usr/bin/env bash
# GHCR tag-immutability preflight.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §6.3.1, §13 Q8
#
# Required env:
#   GH_PAT   — token with `read:packages` on the org
#   GH_ORG   — org name (default: glitchwerks)
#
# Optional env:
#   SKIP_GHCR_IMMUTABILITY=1   — emergency override; logs WARN SKIP and exits 0

set -uo pipefail

GH_ORG="${GH_ORG:-glitchwerks}"
PACKAGES=(claude-runtime-base claude-runtime-review claude-runtime-fix claude-runtime-explain)

if [ "${SKIP_GHCR_IMMUTABILITY:-0}" = "1" ]; then
  echo "WARN SKIP ghcr-immutability-preflight bypassed via SKIP_GHCR_IMMUTABILITY=1" >&2
  exit 0
fi

: "${GH_PAT:?GH_PAT must be set}"
command -v jq >/dev/null || { echo "FATAL jq not on PATH" >&2; exit 2; }
command -v curl >/dev/null || { echo "FATAL curl not on PATH" >&2; exit 2; }

# Three attempts, exponential backoff capped at 10s.
fetch_with_backoff() {
  local url="$1"
  local attempt=0
  local delay=2
  local response http_code body
  while [ "$attempt" -lt 3 ]; do
    response=$(curl -sS -w '\n%{http_code}' \
      -H "Authorization: Bearer $GH_PAT" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" || true)
    http_code=$(printf '%s\n' "$response" | tail -n1)
    body=$(printf '%s\n' "$response" | sed '$d')
    case "$http_code" in
      2??) printf '%s' "$body"; return 0 ;;
      429|5??)
        attempt=$((attempt + 1))
        if [ "$attempt" -lt 3 ]; then
          sleep "$delay"
          delay=$(( delay * 2 ))
          [ "$delay" -gt 10 ] && delay=10
        fi
        ;;
      *)  echo "ERROR ghcr_api_unexpected http_code=$http_code body=$body" >&2; return 1 ;;
    esac
  done
  echo "ERROR ghcr_api_retries_exhausted http_code=$http_code body=$body" >&2
  return 1
}

errs=0
for pkg in "${PACKAGES[@]}"; do
  url="https://api.github.com/orgs/$GH_ORG/packages/container/$pkg"
  body=$(fetch_with_backoff "$url") || { errs=$((errs + 1)); continue; }

  # Field name verified at implementation time. Update here if GitHub has renamed it.
  immutable=$(printf '%s' "$body" | jq -r '.tag_immutability // .immutable // empty')

  if [ "$immutable" != "true" ]; then
    cat >&2 <<EOF
ERROR ghcr_tag_immutability_disabled package=$pkg org=$GH_ORG
       Visit https://github.com/orgs/$GH_ORG/packages/container/package/$pkg/settings
       and toggle "Prevent tag overwrites" ON. Re-run this preflight.
EOF
    errs=$((errs + 1))
  fi
done

if [ "$errs" -gt 0 ]; then
  echo "ghcr-immutability-preflight: $errs package(s) failed" >&2
  exit 1
fi

echo "ghcr-immutability-preflight: all 4 packages immutable"
exit 0
```

- [ ] **Step 1.5.2: Make executable**

Run: `chmod +x runtime/scripts/ghcr-immutability-preflight.sh`

- [ ] **Step 1.5.3: API field-name verification**

Hit the live API once for `claude-runtime-base` (with a PAT that has `read:packages`) and dump the JSON. Confirm which field carries the immutability boolean. Update the `jq` selector in the script if needed.

```bash
curl -sS -H "Authorization: Bearer $GH_PAT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/orgs/glitchwerks/packages/container/claude-runtime-base \
  | jq '. | {tag_immutability, immutable, repository, name}'
```

If the immutability field has a different name on the live response, edit the `jq -r '.tag_immutability // .immutable // empty'` line accordingly.

- [ ] **Step 1.5.4: Local positive smoke (optional — needs PAT)**

```bash
GH_PAT="$GH_PAT" bash runtime/scripts/ghcr-immutability-preflight.sh
```

Expected: `ghcr-immutability-preflight: all 4 packages immutable`. (Or fails loudly with the specific package whose toggle is off — which is itself diagnostic, not a script bug.)

- [ ] **Step 1.5.5: Override smoke**

```bash
SKIP_GHCR_IMMUTABILITY=1 bash runtime/scripts/ghcr-immutability-preflight.sh
```

Expected stderr: `WARN SKIP ghcr-immutability-preflight bypassed via SKIP_GHCR_IMMUTABILITY=1`. Exit 0.

- [ ] **Step 1.5.6: Commit**

```bash
git add runtime/scripts/ghcr-immutability-preflight.sh
git commit -m "feat(ci-runtime): add ghcr-immutability-preflight.sh with backoff (refs #139)"
```

---

## Task 6: Author `.github/workflows/runtime-build.yml` (STAGE 1)

Workflow runs on:

- `workflow_dispatch` with inputs `images`, `private_ref_override`, `marketplace_ref_override`
- `push` filtered by `dorny/paths-filter` on `runtime/**`

Concurrency group `runtime-build-${{ github.sha }}`, `cancel-in-progress: false` per §6.1.1.

Jobs:

1. `paths` — runs `dorny/paths-filter@v3` to decide whether `runtime/**` changed. Push events use this; `workflow_dispatch` bypasses the filter.
2. `stage-1` — runs unconditionally on `workflow_dispatch`, conditionally on `push` (only if filter says runtime changed). Steps:
   - checkout this repo
   - clone `glitchwerks/claude-configs` at the pinned ref into `/tmp/private`
   - clone `anthropics/claude-plugins-official` at the pinned SHA into `/tmp/marketplace`
   - install `yq` (mikefarah v4) and `jq`
   - `npx ajv-cli@5 validate ...` (structural)
   - `bash runtime/scripts/validate-manifest.sh` (semantic)
   - `bash runtime/scripts/ghcr-immutability-preflight.sh` (immutability)
   - actionlint runs centrally via `.github/workflows/lint.yml` — not re-invoked here per the master plan note.

**Files:**
- Create: `.github/workflows/runtime-build.yml`

- [ ] **Step 1.6.1: Write the workflow**

`.github/workflows/runtime-build.yml`:

```yaml
name: runtime-build

on:
  workflow_dispatch:
    inputs:
      images:
        description: "Which images to (eventually) build"
        required: false
        default: all
        type: choice
        options: [all, base, review, fix, explain]
      private_ref_override:
        description: "Override sources.private.ref (debugging only; manifest pin still authoritative)"
        required: false
        default: ""
        type: string
      marketplace_ref_override:
        description: "Override sources.marketplace.ref (debugging only)"
        required: false
        default: ""
        type: string
  push:
    branches: [main]
    paths:
      - "runtime/**"
      - ".github/workflows/runtime-build.yml"

concurrency:
  group: runtime-build-${{ github.sha }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  stage-1:
    name: STAGE 1 — clone + validate
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Checkout this repo
        uses: actions/checkout@v5
        with:
          fetch-depth: 1

      - name: Read manifest pins
        id: pins
        run: |
          set -euo pipefail
          PRIVATE_REF="${{ inputs.private_ref_override }}"
          MARKETPLACE_REF="${{ inputs.marketplace_ref_override }}"
          if [ -z "$PRIVATE_REF" ]; then
            PRIVATE_REF=$(yq -r '.sources.private.ref' runtime/ci-manifest.yaml)
          fi
          if [ -z "$MARKETPLACE_REF" ]; then
            MARKETPLACE_REF=$(yq -r '.sources.marketplace.ref' runtime/ci-manifest.yaml)
          fi
          echo "private_ref=$PRIVATE_REF" >> "$GITHUB_OUTPUT"
          echo "marketplace_ref=$MARKETPLACE_REF" >> "$GITHUB_OUTPUT"

      - name: Clone glitchwerks/claude-configs at pinned ref
        env:
          GH_PAT: ${{ secrets.GH_PAT }}
        run: |
          set -euo pipefail
          : "${GH_PAT:?GH_PAT not set — Phase 0 prerequisite}"
          REF="${{ steps.pins.outputs.private_ref }}"
          git clone --depth 1 --branch "$REF" \
            "https://x-access-token:${GH_PAT}@github.com/glitchwerks/claude-configs" \
            /tmp/private

      - name: Clone anthropics/claude-plugins-official at pinned SHA
        run: |
          set -euo pipefail
          SHA="${{ steps.pins.outputs.marketplace_ref }}"
          git clone https://github.com/anthropics/claude-plugins-official /tmp/marketplace
          git -C /tmp/marketplace checkout "$SHA"

      - name: Install jq + yq
        run: |
          set -euo pipefail
          # jq is preinstalled on ubuntu-latest; yq (mikefarah v4) is not.
          sudo curl -fsSL -o /usr/local/bin/yq \
            https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq
          yq --version
          jq --version

      - name: Structural validation (ajv)
        run: |
          set -euo pipefail
          # ajv-cli reads YAML when extension is .yaml.
          npx --yes ajv-cli@5 validate \
            --spec=draft2020 \
            -s runtime/ci-manifest.schema.json \
            -d runtime/ci-manifest.yaml

      - name: Semantic validation (validate-manifest.sh)
        env:
          MANIFEST: runtime/ci-manifest.yaml
          PRIVATE_TREE: /tmp/private
          SHARED_TREE: ${{ github.workspace }}
        run: bash runtime/scripts/validate-manifest.sh

      - name: GHCR tag-immutability preflight
        env:
          GH_PAT: ${{ secrets.GH_PAT }}
          GH_ORG: glitchwerks
        run: bash runtime/scripts/ghcr-immutability-preflight.sh
```

- [ ] **Step 1.6.2: actionlint locally (optional pre-CI smoke)**

Run: `actionlint .github/workflows/runtime-build.yml`
Expected: clean, exit 0. If `actionlint` is not installed, skip — the centralized `.github/workflows/lint.yml` will run it on push.

- [ ] **Step 1.6.3: Commit**

```bash
git add .github/workflows/runtime-build.yml
git commit -m "feat(ci-runtime): add runtime-build.yml STAGE 1 (clone + validate, refs #139)"
```

---

## Task 7: Dry-run + intentional breaks

The acceptance criterion requires three intentional-break dry runs that fail with the specific error surface. Each break is reverted before the next, and the final state of `main` (after merge) is the green run.

Note: dry-runs happen via `workflow_dispatch` against the **branch** `phase-1-scaffold` (not `main`), since the workflow's `push` trigger only fires on main.

- [ ] **Step 1.7.1: Push the branch**

```bash
git push -u origin phase-1-scaffold
```

- [ ] **Step 1.7.2: Open the PR (draft)**

```bash
gh pr create --draft --title "feat(ci-runtime): Phase 1 scaffold + STAGE 1 pipeline" \
  --body "$(cat <<'EOF'
## Summary
Phase 1 of the CI Claude Runtime epic.

- Scaffolds `runtime/` tree (manifest, schema, validators, stubs)
- Adds STAGE 1 workflow `runtime-build.yml`
- Wires GHCR tag-immutability preflight

## Test plan
- [ ] `workflow_dispatch` of `runtime-build.yml` against this branch passes
- [ ] Three intentional breaks fail with the specified error surfaces
- [ ] `actionlint` (centralized) passes on `runtime-build.yml`

Closes #139

🤖 _Generated by Claude Code on behalf of @cbeaulieu-gt_
EOF
)"
```

- [ ] **Step 1.7.3: Green dry-run**

Trigger: `gh workflow run runtime-build.yml --ref phase-1-scaffold`
Watch: `gh run watch` (most recent run)
Expected: all four steps green, job total < 2 min.

- [ ] **Step 1.7.4: Break A — stale private ref**

Edit `runtime/ci-manifest.yaml`: set `sources.private.ref: ci-v999.0.0`. Commit + push (do NOT merge).
Trigger workflow against the branch.
Expected failure surface: the **Clone glitchwerks/claude-configs** step fails with `fatal: Remote branch ci-v999.0.0 not found in upstream origin`. Job halts.
Revert the edit (`git revert HEAD` or `git reset --soft HEAD~1` followed by re-commit of original manifest), push.

- [ ] **Step 1.7.5: Break B — cross-scope plugin collision**

Edit `runtime/ci-manifest.yaml`: add `pr-review-toolkit: { paths: ["**"] }` under `shared.plugins`. Commit + push.
Trigger workflow.
Expected failure surface: the **Semantic validation** step exits 1 with `ERROR plugin_collision plugin=pr-review-toolkit paths=[shared.plugins.pr-review-toolkit, overlays.review.plugins.pr-review-toolkit]` on stderr. (Note: ajv structural validation passes — collision is a semantic check.)
Revert.

- [ ] **Step 1.7.6: Break C — flip GHCR immutability off on one package**

Manually toggle "Prevent tag overwrites" OFF on `claude-runtime-base` via the package settings UI. Trigger workflow.
Expected failure surface: the **GHCR tag-immutability preflight** step fails with the multi-line `ERROR ghcr_tag_immutability_disabled package=claude-runtime-base ...` message naming the offending package and the settings URL. Job halts.
Re-enable immutability. Re-trigger to confirm green.

- [ ] **Step 1.7.7: Capture the three break runs**

Append run URLs (or `gh run view --log` excerpts) to the PR body under a new "Intentional break evidence" section so the reviewer can verify each break produced its expected error surface.

---

## Task 8: Update root `CLAUDE.md`

Add a one-line bullet under "Key conventions" (or equivalent) that documents the runtime tree, the manifest contract, and the `ci-v*` private-ref requirement.

If the repo's `CLAUDE.md` doesn't have a "Key conventions" section yet, add a new section called "## CI Runtime" instead.

**Files:**
- Modify: `CLAUDE.md` (root)

- [ ] **Step 1.8.1: Read current CLAUDE.md**

Run: `head -100 CLAUDE.md` to find the right insertion point.

- [ ] **Step 1.8.2: Append the runtime convention**

Add a new section near the end (or under a "Key conventions" heading if present):

```markdown
## CI Runtime (Phase 1+)

The `runtime/` tree is the authoritative source for the containerized CI Claude runtime (epic #130, plan `docs/superpowers/plans/2026-04-22-ci-claude-runtime.md`):

- `runtime/ci-manifest.yaml` — single source of truth for what gets baked into each image
- `runtime/ci-manifest.schema.json` — structural rules (validated by `ajv`)
- `runtime/scripts/validate-manifest.sh` — semantic rules (path existence, plugin collisions)
- `runtime/scripts/ghcr-immutability-preflight.sh` — verifies all four GHCR packages have "Prevent tag overwrites" enabled

The manifest's `sources.private.ref` MUST match `^ci-v\d+\.\d+\.\d+$` and resolve to a real tag in `glitchwerks/claude-configs`. Bumping that pin requires a manual review of the `git diff` between the old and new tag.
```

- [ ] **Step 1.8.3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(ci-runtime): document runtime/ tree convention in CLAUDE.md (refs #139)"
git push
```

- [ ] **Step 1.8.4: Mark PR ready**

```bash
gh pr ready
```

---

## Acceptance Criteria (from Issue #139)

Each criterion is checkable against a specific artifact:

- [ ] **C1** — `runtime/ci-manifest.yaml` + `.schema.json` + `validate-manifest.sh` + `ghcr-immutability-preflight.sh` all exist on `main` after merge. Verify with `git ls-tree main -- runtime/ci-manifest.yaml runtime/ci-manifest.schema.json runtime/scripts/validate-manifest.sh runtime/scripts/ghcr-immutability-preflight.sh`.
- [ ] **C2** — `.github/workflows/runtime-build.yml` runs STAGE 1 on `push` to `runtime/**` and completes green. Verify by observing the post-merge push run on `main` is green.
- [ ] **C3** — Three intentional-break dry runs fail with the specified error surfaces. Evidence captured in PR body (Task 7).
- [ ] **C4** — `actionlint` passes on the new workflow. Verify by observing the centralized `.github/workflows/lint.yml` run is green on the PR.
- [ ] **C5** — All four GHCR packages have "Prevent tag overwrites" enabled (verified by preflight step). The green STAGE 1 run is the proof.

---

## Self-Review

**Spec coverage:** Every Phase 1 task in the master plan (1.1–1.8) maps to a numbered Task here:
- 1.1 → Task 1
- 1.2 → Task 2
- 1.3 → Task 3
- 1.4 → Task 4
- 1.5 → Task 5
- 1.6 → Task 6
- 1.7 → Task 7
- 1.8 → Task 8

Issue #139 acceptance criteria 1–5 are mapped in the "Acceptance Criteria" section above.

**Placeholder scan:** No "TBD"/"figure it out later"/"similar to Task N". The one judgment call (the GHCR API field name) has an explicit verification step (1.5.3) before commit, with concrete patch instructions if the field has moved.

**Type/name consistency:**
- `MANIFEST`, `PRIVATE_TREE`, `SHARED_TREE` env vars match between `validate-manifest.sh` and `runtime-build.yml`.
- `GH_PAT` env name matches between preflight and workflow.
- File paths consistent: `runtime/ci-manifest.yaml`, `runtime/ci-manifest.schema.json`, `runtime/scripts/validate-manifest.sh`, `runtime/scripts/ghcr-immutability-preflight.sh`, `runtime/shared/CLAUDE-ci.md`, `runtime/overlays/<v>/CLAUDE.md`.
- `ci-v0.1.0` is the manifest pin everywhere.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/phase-1-scaffold.md`.** Two execution options:

**1. Subagent-Driven (recommended)** — Router dispatches a fresh sub-agent per Task (1–8), reviews between tasks, fast iteration. Good fit because Tasks 1–6 are independent file authoring with clear success criteria; Task 7 needs CI feedback loops and is best done by the router directly.

**2. Inline Execution** — Execute all tasks in this session using `superpowers:executing-plans`, batch with checkpoints.

Recommended: option 1 for Tasks 1–6 (parallelizable file-authoring), then router handles Task 7 (CI dry-runs + intentional breaks) and Task 8 (CLAUDE.md doc edit) inline.
