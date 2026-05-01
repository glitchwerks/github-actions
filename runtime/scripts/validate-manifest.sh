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
