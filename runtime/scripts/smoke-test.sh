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

# ---- (a) CLI binary works + persona files exist on disk --------------------
# Inquisitor pass / CI run 25230756010 lesson: asking the model to
# enumerate installed agents/skills/plugins via --json-schema is
# unreliable — `claude --print` does not surface the installed-item
# registry to the model in non-interactive mode, so the model emits
# empty arrays that satisfy the schema while concealing whether the
# image actually carries the persona.
#
# We instead test STRUCTURALLY: the CLI binary works and the
# materialized persona files are at the expected paths. This is the
# load-bearing contract for "image works but persona is empty"
# detection (§9.2).

# Pre-pull so docker-run pull progress doesn't pollute subsequent output.
# (CI run 25229881683 failure: pull progress lines before the JSON
# envelope caused jq parse error at column 7.)
echo "smoke-test: pulling image..." >&2
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR docker_pull_failed image=$IMAGE" >&2
  exit 1
fi

# A.1 — CLI binary smoke
if ! cli_version=$(docker run --rm --user "$SMOKE_UID" "$IMAGE" --version 2>&1); then
  echo "ERROR cli_binary_smoke_failed image=$IMAGE" >&2
  echo "$cli_version" >&2
  exit 1
fi
echo "smoke-test: claude $cli_version"

# A.2 — Filesystem structural check
FILES_OUT=$(mktemp)
SMOKE_OUT=$(mktemp)
SMOKE_STDERR=$(mktemp)
PERMS_STDERR=$(mktemp)
# Cumulative cleanup function — variables are interpolated at exit time, so
# adding more temp files later (SMOKE_STDERR, PERMS_STDERR) is automatically
# included as long as those vars are non-empty when the trap fires.
cleanup() {
  rm -f "$SMOKE_OUT" "${SMOKE_STDERR:-}" "${PERMS_STDERR:-}" "$FILES_OUT" 2>/dev/null
}
trap cleanup EXIT

if ! docker run --rm --user "$SMOKE_UID" --entrypoint /bin/sh "$IMAGE" \
    -c 'find /opt/claude/.claude -type f' > "$FILES_OUT" 2>&1; then
  echo "ERROR persona_listing_failed image=$IMAGE" >&2
  cat "$FILES_OUT" >&2
  exit 1
fi

agent_count=$(grep -c '^/opt/claude/\.claude/agents/'  "$FILES_OUT" || true)
skill_count=$(grep -c '^/opt/claude/\.claude/skills/'   "$FILES_OUT" || true)
plugin_count=$(grep -c '^/opt/claude/\.claude/plugins/' "$FILES_OUT" || true)

echo "smoke-test: persona file counts agents=$agent_count skills=$skill_count plugins=$plugin_count"

# §9.2 highest-risk silent failure: empty persona
if [ "$agent_count" = "0" ] || [ "$skill_count" = "0" ] || [ "$plugin_count" = "0" ]; then
  echo "ERROR empty_persona agents=$agent_count skills=$skill_count plugins=$plugin_count" >&2
  echo "--- /opt/claude/.claude file listing ---" >&2
  cat "$FILES_OUT" >&2
  exit 1
fi

# A.3 — Required canonical files present
REQUIRED_FILES=(
  "/opt/claude/.claude/agents/ops.md"
  "/opt/claude/.claude/CLAUDE.md"
  "/opt/claude/.claude/standards/software-standards.md"
)
missing=()
for f in "${REQUIRED_FILES[@]}"; do
  if ! grep -qFx "$f" "$FILES_OUT"; then
    missing+=("$f")
  fi
done

# Skill check is path-only since SKILL.md may live anywhere under skills/<name>/
if ! grep -q '^/opt/claude/\.claude/skills/git/' "$FILES_OUT"; then
  missing+=("/opt/claude/.claude/skills/git/<any file>")
fi
if ! grep -q '^/opt/claude/\.claude/skills/python/' "$FILES_OUT"; then
  missing+=("/opt/claude/.claude/skills/python/<any file>")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR persona_required_files_missing image=$IMAGE" >&2
  printf '       %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "smoke-test: persona structural check OK (agents=$agent_count, skills=$skill_count, plugins=$plugin_count, all required files present)"

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
SECRET_HITS=$(docker run --rm --entrypoint /bin/sh "$IMAGE" \
  -c 'find /opt/claude/.claude/ \( -name "*.oauth" -o -name "*.token" -o -name "credentials.json" -o -name ".netrc" -o -name "auth.json" \) -print' \
  2>/dev/null || true)

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
PERMS_HITS=$(docker run --rm --user "$SMOKE_UID" --entrypoint /bin/sh "$IMAGE" \
  -c 'find /opt/claude/.claude \( -type d -not -perm 0755 \) -o \( -type f -not -perm 0644 \)' \
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
