#!/usr/bin/env bash
# Match a CI runtime image's persona enumeration against an expected.yaml contract.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §10.2
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 2.2
# Contract: runtime/scripts/smoke-test.sh:124-151 EXPECTED_FILE matcher block
#
# Usage:
#   inventory-match.sh <enumeration.json> <expected.yaml>
#
# Inputs:
#   <enumeration.json>  — output of enumerate-persona.sh: {agents:[], skills:[], plugins:[]}
#   <expected.yaml>     — must_contain.{agents,skills,plugins} + must_not_contain.{agents,plugins}
#
# Behavior:
#   - Pre-validate both inputs (yq/jq parse OK) — Charge 6 of pass-1 fix.
#   - Reject empty / no-assertions / unknown-key / unsupported-field expected.yaml — Charge 5.
#   - For each must_contain.<kind> name: assert present in enumeration.<kind> array.
#     Missing → emit `ERROR inventory_must_contain_missing kind=<kind> name=<name>`.
#   - For each must_not_contain.<kind> name: assert absent from enumeration.<kind> array.
#     Present → emit `ERROR inventory_must_not_contain_present kind=<kind> name=<name>`.
#   - Report ALL violations before exiting (do NOT short-circuit). Per smoke-test.sh:144.
#
# Comparison semantics: exact-match string equality. No glob, no regex, no case-folding.
#
# Exit codes:
#   0 — clean
#   1 — at least one violation OR empty/no-assertions expected.yaml
#   2 — malformed input (parse failure, unknown top-level key, invalid type, unsupported field)
#
# Header: set -uo pipefail (NOT set -e). The all-violations-before-exit contract
# is incompatible with -e: a single failing comparison would short-circuit the loop.
# Errors are accumulated via an `errs` counter (same pattern as Phase 2 extract-shared.sh).

set -uo pipefail

JSON_FILE="${1:?usage: inventory-match.sh <enumeration.json> <expected.yaml>}"
EXPECTED_FILE="${2:?usage: inventory-match.sh <enumeration.json> <expected.yaml>}"

[ -f "$JSON_FILE" ]     || { echo "ERROR enumeration_json_not_found file=$JSON_FILE"     >&2; exit 2; }
[ -f "$EXPECTED_FILE" ] || { echo "ERROR expected_yaml_not_found file=$EXPECTED_FILE" >&2; exit 2; }

# ---- Pre-validation (Pass-1 Charge 6 — yq/jq must succeed BEFORE any iteration loop) ----
# yq's empty-file behavior: yq '.' on a zero-byte file emits "null\n" with exit 0.
# We treat null + parse-fail differently: parse-fail is exit 2, null/{} is "empty"
# (caught by the empty-assertions guard below).
if ! yq eval '.' "$EXPECTED_FILE" >/dev/null 2>&1; then
  echo "ERROR expected_yaml_parse_failed file=$EXPECTED_FILE" >&2
  exit 2
fi

if ! jq -e . "$JSON_FILE" >/dev/null 2>&1; then
  echo "ERROR enumeration_json_parse_failed file=$JSON_FILE" >&2
  exit 2
fi

# ---- Schema-of-expected checks ----------------------------------------------
# Detect unknown top-level keys. yq emits one key per line with `keys | .[]`.
# Allowed: must_contain, must_not_contain. Anything else → exit 2.
TOP_KEYS=$(yq eval -o=json '.' "$EXPECTED_FILE" | jq -r 'if type == "object" then keys[] else empty end' 2>/dev/null)

unknown_key_seen=0
while IFS= read -r key; do
  [ -z "$key" ] && continue
  case "$key" in
    must_contain|must_not_contain) ;;
    *)
      echo "ERROR expected_yaml_unknown_top_level_key key=$key file=$EXPECTED_FILE" >&2
      unknown_key_seen=1
      ;;
  esac
done <<< "$TOP_KEYS"
[ "$unknown_key_seen" = "0" ] || exit 2

# Detect unsupported fields. v1 spec §10.2 supports must_not_contain.{agents,plugins};
# must_not_contain.skills is reserved for future and rejected today.
mnc_skills_present=$(yq eval -o=json '.' "$EXPECTED_FILE" \
  | jq -r 'if type == "object" and (.must_not_contain // {} | has("skills")) then "y" else "n" end' 2>/dev/null)
if [ "$mnc_skills_present" = "y" ]; then
  echo "ERROR expected_yaml_unsupported_field field=must_not_contain.skills file=$EXPECTED_FILE" >&2
  exit 2
fi

# Detect must_contain.skills present but not an array.
# Use yq to get the JSON type; if must_contain.skills exists and is not array, fail.
mc_skills_type=$(yq eval -o=json '.' "$EXPECTED_FILE" \
  | jq -r 'if type == "object" and (.must_contain // {} | has("skills"))
           then (.must_contain.skills | type) else "absent" end' 2>/dev/null)
case "$mc_skills_type" in
  absent|array) ;;
  *)
    echo "ERROR expected_yaml_invalid_type kind=must_contain.skills got=$mc_skills_type file=$EXPECTED_FILE" >&2
    exit 2
    ;;
esac

# ---- Empty / no-assertions guards (Pass-1 Charge 5) -------------------------
# (a) Neither must_contain nor must_not_contain present (zero-byte file, only
#     comments, {}, null) → exit 1 with expected_yaml_empty.
mc_present=$(yq eval -o=json '.' "$EXPECTED_FILE" | jq -r 'if type == "object" and has("must_contain")     then "y" else "n" end' 2>/dev/null)
mnc_present=$(yq eval -o=json '.' "$EXPECTED_FILE" | jq -r 'if type == "object" and has("must_not_contain") then "y" else "n" end' 2>/dev/null)
if [ "$mc_present" = "n" ] && [ "$mnc_present" = "n" ]; then
  echo "ERROR expected_yaml_empty file=$EXPECTED_FILE" >&2
  exit 1
fi

# (b) Both present but every kind-array is empty → expected_yaml_no_assertions.
total_assertions=$(yq eval -o=json '.' "$EXPECTED_FILE" | jq -r '
  ((.must_contain.agents     // []) | length) +
  ((.must_contain.skills     // []) | length) +
  ((.must_contain.plugins    // []) | length) +
  ((.must_not_contain.agents // []) | length) +
  ((.must_not_contain.plugins// []) | length)
' 2>/dev/null)
total_assertions="${total_assertions:-0}"
if [ "$total_assertions" -eq 0 ]; then
  echo "ERROR expected_yaml_no_assertions file=$EXPECTED_FILE" >&2
  exit 1
fi

# ---- Iteration: report ALL violations, accumulate counter -------------------
errs=0

# Helper: extract `expected.<dotpath>` as a newline-separated list of names.
expected_list() {
  local path="$1"
  yq eval -o=json '.' "$EXPECTED_FILE" | jq -r --arg p "$path" '
    ($p | split(".")) as $parts |
    getpath($parts) // [] | .[]
  ' 2>/dev/null
}

# Helper: check if a name is present in enumeration.<kind> array.
# Returns 0 if present, 1 if absent.
enumeration_has() {
  local kind="$1" name="$2"
  jq -e --arg k "$kind" --arg n "$name" '.[$k] // [] | index($n) // null | . != null' "$JSON_FILE" >/dev/null 2>&1
}

# must_contain checks
for kind in agents skills plugins; do
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! enumeration_has "$kind" "$name"; then
      echo "ERROR inventory_must_contain_missing kind=$kind name=$name" >&2
      errs=$((errs + 1))
    fi
  done < <(expected_list "must_contain.$kind")
done

# must_not_contain checks (only agents + plugins per §10.2)
for kind in agents plugins; do
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if enumeration_has "$kind" "$name"; then
      echo "ERROR inventory_must_not_contain_present kind=$kind name=$name" >&2
      errs=$((errs + 1))
    fi
  done < <(expected_list "must_not_contain.$kind")
done

if [ "$errs" -gt 0 ]; then
  echo "inventory-match: $errs violation(s) against $EXPECTED_FILE" >&2
  exit 1
fi

echo "inventory-match: clean ($EXPECTED_FILE matches $JSON_FILE)"
exit 0
