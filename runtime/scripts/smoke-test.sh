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

# Pre-pull so docker-run pull progress doesn't pollute the JSON capture.
# (CI run 25229881683 failure: pull progress lines before the JSON
# envelope caused jq parse error at column 7.)
echo "smoke-test: pulling image..." >&2
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR docker_pull_failed image=$IMAGE" >&2
  exit 1
fi

# Run smoke. stdout captures the JSON envelope; stderr goes to the GHA
# log for debug visibility but does NOT contaminate $SMOKE_OUT.
SMOKE_STDERR=$(mktemp)
trap 'rm -f "$SMOKE_OUT" "$SMOKE_STDERR" 2>/dev/null' EXIT

if ! docker run --rm \
  --user "$SMOKE_UID" \
  -e HOME=/tmp/smoke-home \
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  "$IMAGE" \
  claude --print --output-format json --json-schema "$SCHEMA" \
    "Enumerate every agent, skill, and plugin available in this environment. Return a single JSON object with keys 'agents', 'skills', 'plugins', each an array of names." \
  > "$SMOKE_OUT" 2> "$SMOKE_STDERR"
then
  rc=$?
  echo "ERROR smoke_run_failed image=$IMAGE exit=$rc" >&2
  echo "--- smoke stderr ---" >&2
  cat "$SMOKE_STDERR" >&2
  echo "--- smoke stdout ---" >&2
  cat "$SMOKE_OUT" >&2
  exit 1
fi

# Surface stderr to GHA logs (helpful for debugging non-fatal warnings)
if [ -s "$SMOKE_STDERR" ]; then
  echo "--- smoke stderr (non-fatal) ---" >&2
  cat "$SMOKE_STDERR" >&2
fi

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
PERMS_STDERR=$(mktemp); trap 'rm -f "$SMOKE_OUT" "$SMOKE_STDERR" "$PERMS_STDERR" 2>/dev/null' EXIT
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
