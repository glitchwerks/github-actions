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
  # Marketplace has two plugin trees — first-party under plugins/ and
  # third-party under external_plugins/. Try first-party first; fall back.
  ext_src="$MARKETPLACE_TREE/external_plugins/$plugin"
  if [ -d "$MARKETPLACE_TREE/plugins/$plugin" ]; then
    src="$MARKETPLACE_TREE/plugins/$plugin"
  elif [ -d "$ext_src" ]; then
    src="$ext_src"
  else
    err "plugin_missing name=$plugin tried=[$MARKETPLACE_TREE/plugins/$plugin, $ext_src]"
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
