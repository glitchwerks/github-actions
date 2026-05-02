#!/usr/bin/env bash
# Overlay-aware smoke test wrapper for Phase 3.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §6.2 STAGE 4, §10.1 T3+T3b+T4
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 3.1
#
# Wraps Phase 2's smoke-test.sh (base smoke — CLI binary, persona file counts,
# label completeness, R3 perms, secret hygiene) with overlay-specific additions:
#   1. Inventory enumeration (enumerate-persona.sh)
#   2. Inventory match against the overlay's expected.yaml (inventory-match.sh)
#   3. R6 in-image expected.yaml hash assertion
#
# Usage:
#   overlay-smoke.sh <image-ref> <overlay-name>
#
# Required env:
#   CLAUDE_CODE_OAUTH_TOKEN   — passed through to base smoke
#   EXPECTED_FILE             — path to the overlay's expected.yaml
#
# Optional env:
#   SMOKE_UID                 — UID for `docker run --user`. Default: $(id -u).
#                               (passed through to both base smoke and enumerator)
#
# Exit: non-zero on any sub-step failure; zero on overall pass.

set -uo pipefail

IMAGE="${1:?image ref required}"
OVERLAY="${2:?overlay name required (review|fix|explain)}"

case "$OVERLAY" in
  review|fix|explain) ;;
  *) echo "ERROR overlay_smoke_unknown_overlay overlay=$OVERLAY (must be review|fix|explain)" >&2; exit 1;;
esac

: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN must be set (passed through to base smoke)}"
: "${EXPECTED_FILE:?EXPECTED_FILE must point at runtime/overlays/<verb>/expected.yaml}"

[ -f "$EXPECTED_FILE" ] || { echo "ERROR overlay_smoke_expected_file_not_found file=$EXPECTED_FILE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "overlay-smoke: image=$IMAGE overlay=$OVERLAY expected=$EXPECTED_FILE"

# ---- (1) Phase 2 base smoke against the overlay image ----------------------
# Base smoke runs CLI binary check, filesystem persona counts, R3 perms,
# label completeness, secret hygiene. All apply equally to overlay images
# (they're built FROM the base; perms + labels propagate). Calling it here
# gives Phase 3 secret-hygiene coverage of overlay-specific state for free.
echo "overlay-smoke: --- (1/3) base smoke ---"
if ! bash "$SCRIPT_DIR/smoke-test.sh" "$IMAGE" "$OVERLAY"; then
  echo "ERROR overlay_smoke_base_failed image=$IMAGE overlay=$OVERLAY" >&2
  exit 1
fi

# ---- (2) Inventory enumeration + match -------------------------------------
echo "overlay-smoke: --- (2/3) inventory match ---"
ENUM_OUT=$(mktemp)
cleanup() { rm -f "$ENUM_OUT"; }
trap cleanup EXIT

if ! IMAGE_REF="$IMAGE" bash "$SCRIPT_DIR/enumerate-persona.sh" "$ENUM_OUT"; then
  echo "ERROR overlay_smoke_enumeration_failed image=$IMAGE overlay=$OVERLAY" >&2
  exit 1
fi

if ! bash "$SCRIPT_DIR/inventory-match.sh" "$ENUM_OUT" "$EXPECTED_FILE"; then
  match_rc=$?
  echo "ERROR overlay_smoke_inventory_mismatch image=$IMAGE overlay=$OVERLAY exit_code=$match_rc" >&2
  exit "$match_rc"
fi

# ---- (3) R6 in-image expected.yaml hash assertion --------------------------
# The overlay's expected.yaml is COPY'd into the image at /opt/claude/.expected.yaml
# during STAGE 3 build (per Task 4.1's Dockerfile snippet). Forensic verification
# in Phase 6 reads the in-image file; the hash here proves the build did not
# corrupt or substitute the contract artifact.
echo "overlay-smoke: --- (3/3) R6 expected.yaml hash ---"
SOURCE_HASH=$(sha256sum "$EXPECTED_FILE" | awk '{print $1}')
IMAGE_HASH=$(docker run --rm --entrypoint /bin/sh "$IMAGE" \
  -c 'sha256sum /opt/claude/.expected.yaml' 2>/dev/null | awk '{print $1}')

if [ -z "$IMAGE_HASH" ]; then
  echo "ERROR overlay_smoke_expected_yaml_missing_in_image image=$IMAGE overlay=$OVERLAY" >&2
  echo "       /opt/claude/.expected.yaml not present or unreadable" >&2
  exit 1
fi

if [ "$SOURCE_HASH" != "$IMAGE_HASH" ]; then
  echo "ERROR expected_yaml_in_image_mismatch overlay=$OVERLAY" >&2
  echo "       source_hash=$SOURCE_HASH (file=$EXPECTED_FILE)" >&2
  echo "       image_hash=$IMAGE_HASH  (image=$IMAGE)" >&2
  exit 1
fi

echo "overlay-smoke: $OVERLAY clean (image=$IMAGE expected_hash=$SOURCE_HASH)"
exit 0
