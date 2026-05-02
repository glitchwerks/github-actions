#!/usr/bin/env bash
# Enumerate the agents/skills/plugins materialized inside a CI runtime image.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §10.1 T3, §10.2
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 2.1
#
# Produces JSON of shape:
#   { "agents": [<name>, ...], "skills": [<name>, ...], "plugins": [<name>, ...] }
# Names sorted (LC_ALL=C) and deduplicated. Empty arrays are produced for kinds
# with zero matches; the script fails loudly when the WHOLE listing is empty
# or when no persona surface yields any names (mirrors Phase 2 smoke-test.sh:88
# empty_persona guard, but at the enumerator layer for the matcher's benefit).
#
# Usage:
#   enumerate-persona.sh <out-file>
#
# Required env:
#   IMAGE_REF      — Docker image reference (digest or tag)
#
# Optional env:
#   SMOKE_UID      — UID for `docker run --user`. Default: $(id -u).
#                    (NOT asserted equal to 1001 — same convention as Phase 2.)
#
# Exit codes:
#   0 — success; OUT_FILE written
#   1 — usage error / find failure / empty listing / no-persona
#   2 — unused (reserved for parity with inventory-match.sh)
#
# Name extraction rules (per Plan Task 2.1, Pass-1 Charge 4 explicit regexes):
#   agents:  ^/opt/claude/\.claude/agents/([^/]+)\.md$
#            (subdirectories under agents/ are silently ignored — agents are flat .md files in v1)
#   skills:  ^/opt/claude/\.claude/skills/([^/]+)/
#            (first path component after skills/; nested files inside still yield the top dir name)
#   plugins: ^/opt/claude/\.claude/plugins/([^/]+)/
#            (same first-component rule as skills)
#
# Comparison semantics: exact-match string equality. No glob, no regex. Names sorted, deduped.

set -uo pipefail

OUT_FILE="${1:?usage: enumerate-persona.sh <out-file>}"
: "${IMAGE_REF:?IMAGE_REF must be set}"

SMOKE_UID="${SMOKE_UID:-$(id -u)}"

# Capture the file listing under /opt/claude/.claude as the running UID (exec as
# the same non-root UID the consumer workflow uses; see Phase 2 §13 Q10 rationale).
# Use --entrypoint /bin/sh so the base image's claude binary doesn't intercept the
# `find` argv (Phase 2 lesson — feedback_docker_run_entrypoint_override.md).
LISTING=$(mktemp)
LISTING_ERR=$(mktemp)
cleanup() { rm -f "$LISTING" "$LISTING_ERR"; }
trap cleanup EXIT

if ! docker run --rm --user "$SMOKE_UID" --entrypoint /bin/sh "$IMAGE_REF" \
    -c 'find /opt/claude/.claude -type f' > "$LISTING" 2> "$LISTING_ERR"; then
  echo "ERROR enumeration_failed image=$IMAGE_REF" >&2
  if [ -s "$LISTING_ERR" ]; then
    echo "       --- stderr from find ---" >&2
    cat "$LISTING_ERR" >&2
  fi
  exit 1
fi

# Empty-listing guard (Pass-1 Charge 4). `find` exits 0 even when the tree is
# missing or empty — silent green is exactly what we want to prevent.
if [ ! -s "$LISTING" ]; then
  echo "ERROR enumeration_empty image=$IMAGE_REF" >&2
  echo "       /opt/claude/.claude produced zero file listing — tree missing or unreadable" >&2
  exit 1
fi

# Extract sorted+deduped names per kind. LC_ALL=C for byte-stable sort.
extract_names() {
  local pattern="$1"
  # sed picks the captured group, then sort -u. Empty input → empty output.
  LC_ALL=C sed -nE "s|${pattern}|\\1|p" "$LISTING" | LC_ALL=C sort -u
}

AGENTS_RAW=$(extract_names '^/opt/claude/\.claude/agents/([^/]+)\.md$')
SKILLS_RAW=$(extract_names '^/opt/claude/\.claude/skills/([^/]+)/.*$')
PLUGINS_RAW=$(extract_names '^/opt/claude/\.claude/plugins/([^/]+)/.*$')

# Count for the no-persona guard + summary line.
agents_count=$( [ -z "$AGENTS_RAW"  ] && echo 0 || echo "$AGENTS_RAW"  | wc -l | tr -d ' ')
skills_count=$( [ -z "$SKILLS_RAW"  ] && echo 0 || echo "$SKILLS_RAW"  | wc -l | tr -d ' ')
plugins_count=$([ -z "$PLUGINS_RAW" ] && echo 0 || echo "$PLUGINS_RAW" | wc -l | tr -d ' ')

# Zero-persona guard (Pass-1 Charge 4): non-empty listing but all three kinds
# empty means the tree exists but contains only CLAUDE.md / standards / etc.
# That's a load-bearing failure mode — fail loudly so the matcher doesn't get
# fed garbage and produce N misleading must_contain_missing errors.
if [ "$agents_count" = "0" ] && [ "$skills_count" = "0" ] && [ "$plugins_count" = "0" ]; then
  echo "ERROR enumeration_no_persona image=$IMAGE_REF agents=0 skills=0 plugins=0" >&2
  echo "       --- /opt/claude/.claude listing (debug) ---" >&2
  cat "$LISTING" >&2
  exit 1
fi

# Emit JSON. Use jq to handle quoting/escaping of names safely. Empty arrays
# are valid JSON; jq -R . | jq -s . converts a newline-separated list to a
# JSON array of strings; empty input yields [].
to_json_array() {
  if [ -z "$1" ]; then
    echo '[]'
  else
    printf '%s\n' "$1" | jq -R . | jq -sc .
  fi
}

AGENTS_JSON=$(to_json_array "$AGENTS_RAW")
SKILLS_JSON=$(to_json_array "$SKILLS_RAW")
PLUGINS_JSON=$(to_json_array "$PLUGINS_RAW")

jq -n \
  --argjson agents  "$AGENTS_JSON" \
  --argjson skills  "$SKILLS_JSON" \
  --argjson plugins "$PLUGINS_JSON" \
  '{agents: $agents, skills: $skills, plugins: $plugins}' > "$OUT_FILE"

echo "enumerate-persona: image=$IMAGE_REF agents=$agents_count skills=$skills_count plugins=$plugins_count out=$OUT_FILE"
exit 0
