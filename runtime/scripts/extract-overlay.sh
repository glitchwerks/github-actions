#!/usr/bin/env bash
# Materialize a per-overlay tree from the manifest into an output directory.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §3.4 layer 2, §5.1, §6.2 STAGE 3
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 5.1
#
# Companion to extract-shared.sh (Phase 2). Reads overlays.<verb>.* from the
# manifest and emits the additive tree (agents + plugins) plus subtract-marker
# files for plugins that should be removed from the base-inherited tree at
# Dockerfile build time.
#
# Inputs (env vars):
#   MANIFEST          — path to ci-manifest.yaml (default: runtime/ci-manifest.yaml)
#   OVERLAY           — verb name: review | fix | explain (required)
#   PRIVATE_TREE      — cloned glitchwerks/claude-configs at the pinned tag (required)
#   MARKETPLACE_TREE  — cloned anthropics/claude-plugins-official at the pinned SHA (required)
#   OUT_DIR           — destination dir; created if missing, must be empty (required)
#
# Output layout under OUT_DIR (mirrors what ends up at /opt/claude/.claude/ in image):
#   agents/<name>.md                   from overlays.<verb>.imports_from_private.agents
#   plugins/<name>/...                 from overlays.<verb>.plugins (P1 full or P2 cherry-pick)
#   .subtract/plugins/<name>           empty marker per overlays.<verb>.subtract_from_shared.plugins
#                                      (Dockerfile RUN consumes these to rm -rf inherited plugins)
#
# Determinism contract (same as extract-shared.sh):
#   - LC_ALL=C, umask 022, touch -d @0 on every output, no embedded timestamps.
#
# Subtract marker name validation (per Plan Task 5.1 Phase B / Pass-1 Charge 3 / Pass-2 Charge 2):
#   Every name in subtract_from_shared.plugins MUST match ^[a-z0-9][a-z0-9-]*$.
#   This is defense layer 1; the Dockerfile RUN snippet is defense layer 2 (Pass-3 Charge 2).

set -uo pipefail
export LC_ALL=C
umask 022

MANIFEST="${MANIFEST:-runtime/ci-manifest.yaml}"
OVERLAY="${OVERLAY:?OVERLAY must be set (review|fix|explain)}"
PRIVATE_TREE="${PRIVATE_TREE:?PRIVATE_TREE must be set}"
MARKETPLACE_TREE="${MARKETPLACE_TREE:?MARKETPLACE_TREE must be set}"
OUT_DIR="${OUT_DIR:?OUT_DIR must be set}"

case "$OVERLAY" in
  review|fix|explain) ;;
  *) echo "FATAL extract-overlay: invalid OVERLAY=$OVERLAY (must be review|fix|explain)" >&2; exit 2;;
esac

command -v yq >/dev/null || { echo "FATAL yq not on PATH" >&2; exit 2; }
[ -f "$MANIFEST" ]            || { echo "FATAL manifest not found: $MANIFEST" >&2; exit 2; }
[ -d "$PRIVATE_TREE" ]        || { echo "FATAL PRIVATE_TREE not a dir: $PRIVATE_TREE" >&2; exit 2; }
[ -d "$MARKETPLACE_TREE" ]    || { echo "FATAL MARKETPLACE_TREE not a dir: $MARKETPLACE_TREE" >&2; exit 2; }

if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  echo "FATAL OUT_DIR not empty: $OUT_DIR" >&2
  exit 2
fi
mkdir -p "$OUT_DIR"

errs=0
err() { printf 'ERROR %s\n' "$*" >&2; errs=$((errs + 1)); }

emit_file() {
  local src="$1" dst="$2"
  install -D -m 0644 "$src" "$dst" || { err "copy_failed src=$src dst=$dst"; return 1; }
  touch -d @0 "$dst"
}

emit_tree() {
  local src="$1" dst="$2"
  if [ ! -d "$src" ]; then
    err "tree_missing src=$src"; return 1
  fi
  mkdir -p "$dst"
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    install -D -m 0644 "$f" "$dst/$rel" || err "copy_failed src=$f dst=$dst/$rel"
    touch -d @0 "$dst/$rel"
  done < <(find "$src" -type f | sort)
  find "$dst" -type d -exec touch -d @0 {} +
}

# ---- Phase A — additive imports -------------------------------------------

# (A.1) overlays.<verb>.imports_from_private.agents
while IFS= read -r agent; do
  [ -z "$agent" ] && continue
  emit_file "$PRIVATE_TREE/agents/$agent.md" "$OUT_DIR/agents/$agent.md"
done < <(yq -r ".overlays.${OVERLAY}.imports_from_private.agents // [] | .[]" "$MANIFEST")

# (A.2) overlays.<verb>.plugins (P1 full vs P2 cherry-pick per paths value)
while IFS= read -r plugin; do
  [ -z "$plugin" ] && continue
  # Same plugins/ vs external_plugins/ fallback as extract-shared.sh (Phase 2 fix 4b120f7).
  ext_src="$MARKETPLACE_TREE/external_plugins/$plugin"
  if   [ -d "$MARKETPLACE_TREE/plugins/$plugin" ]; then src="$MARKETPLACE_TREE/plugins/$plugin"
  elif [ -d "$ext_src" ];                              then src="$ext_src"
  else
    err "plugin_missing name=$plugin tried=[$MARKETPLACE_TREE/plugins/$plugin, $ext_src]"
    continue
  fi
  paths_count=$(yq -r ".overlays.${OVERLAY}.plugins.\"$plugin\".paths | length" "$MANIFEST")
  first_path=$(yq -r ".overlays.${OVERLAY}.plugins.\"$plugin\".paths[0]" "$MANIFEST")
  if [ "$paths_count" = "1" ] && [ "$first_path" = "**" ]; then
    # P1 — full install
    emit_tree "$src" "$OUT_DIR/plugins/$plugin"
  else
    # P2 — cherry-pick listed paths
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      emit_file "$src/$p" "$OUT_DIR/plugins/$plugin/$p"
    done < <(yq -r ".overlays.${OVERLAY}.plugins.\"$plugin\".paths | .[]" "$MANIFEST")
  fi
done < <(yq -r ".overlays.${OVERLAY}.plugins // {} | keys | .[]" "$MANIFEST" | sort)

# ---- Phase B — subtractive removals (per Deviation #10 / Pass-1 Charge 3) ----
# For each plugin name in subtract_from_shared.plugins, validate the name and
# write a zero-byte marker file. The Dockerfile RUN step (Task 5.5) consumes
# these markers and rm -rf's the matching plugin from the base-inherited tree.
#
# Name validation (defense layer 1 of 2; Pass-2 Charge 2 / Pass-3 Charge 2):
# regex ^[a-z0-9][a-z0-9-]*$ — letters, digits, hyphens; first char alphanum.
while IFS= read -r plugin; do
  [ -z "$plugin" ] && continue
  # Reject anything that doesn't match the plugin-name charset. The bash regex
  # operator =~ uses ERE; the anchored regex below is the canonical check.
  if ! [[ "$plugin" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    err "subtract_marker_invalid_name overlay=$OVERLAY name=$plugin"
    continue
  fi
  mkdir -p "$OUT_DIR/.subtract/plugins"
  : > "$OUT_DIR/.subtract/plugins/$plugin"
  touch -d @0 "$OUT_DIR/.subtract/plugins/$plugin"
done < <(yq -r ".overlays.${OVERLAY}.subtract_from_shared.plugins // [] | .[]" "$MANIFEST")

# Stamp .subtract/ directory mtimes deterministically too (if we created it).
if [ -d "$OUT_DIR/.subtract" ]; then
  find "$OUT_DIR/.subtract" -type d -exec touch -d @0 {} +
fi

if [ "$errs" -gt 0 ]; then
  echo "extract-overlay: $errs error(s) for OVERLAY=$OVERLAY" >&2
  exit 1
fi

file_count=$(find "$OUT_DIR" -type f | wc -l | tr -d ' ')
echo "extract-overlay: clean OVERLAY=$OVERLAY files=$file_count out=$OUT_DIR"
exit 0
