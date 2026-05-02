#!/usr/bin/env bash
# run-cases.sh — JSON-driven test runner for parse.sh.
#
# Usage: bash run-cases.sh
#
# Sources claude-command-router/lib/parse.sh, iterates every case in
# claude-command-router/tests/cases.json, compares the emitted
# overlay|status|mode tuple to the case's `expect` object, and exits 0 if
# all cases pass or 1 if any case fails.
#
# Failures ACCUMULATE — every mismatched case is reported, then exit 1
# fires once at the end. This (a) lets a single CI run surface every
# regression in one shot rather than fix-one-rerun-find-next, and (b)
# is required by the plan's deliberate-flip test (Task 9.4) which flips
# TWO cases and asserts BOTH appear in the failure output.
#
# Header is `set -uo pipefail`, NOT `-e`, because `-e` would short-circuit
# accumulation. Per Phase 4 plan Pass-1 finding H4.

set -uo pipefail

# Resolve paths via the script's location so this works whether invoked
# from repo root, the tests/ directory, or any other cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARSE_SH="$ROUTER_DIR/lib/parse.sh"
CASES_JSON="$SCRIPT_DIR/cases.json"

# --- Defensive startup checks ------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR jq_not_found: jq is required (preinstalled on ubuntu-latest)" >&2
  exit 1
fi

if [ ! -f "$PARSE_SH" ]; then
  echo "ERROR parse_sh_missing: $PARSE_SH" >&2
  exit 1
fi

if [ ! -f "$CASES_JSON" ]; then
  echo "ERROR cases_json_missing: $CASES_JSON" >&2
  exit 1
fi

if ! jq . "$CASES_JSON" >/dev/null 2>&1; then
  echo "ERROR cases_json_invalid: $CASES_JSON is not valid JSON" >&2
  exit 1
fi

# Corpus size minimum (per acceptance criteria — spec §10.3 requires ≥15).
case_count=$(jq 'length' "$CASES_JSON")
if [ "$case_count" -lt 15 ]; then
  echo "ERROR cases_json_too_small: got $case_count cases, want >= 15" >&2
  exit 1
fi

# Schema check: every case has {name, input, expect:{overlay,status,mode}}.
# Per Phase 4 plan Pass-1 finding M3.
if ! jq -e 'all(.[]; has("name") and has("input") and (.expect | type == "object" and has("overlay") and has("status") and has("mode")))' "$CASES_JSON" >/dev/null; then
  echo "ERROR cases_json_schema_invalid: every case must have {name, input, expect: {overlay, status, mode}}" >&2
  exit 1
fi

# --- Source parser -----------------------------------------------------------

# parse.sh's TOP-LEVEL scope sets no flags (per parse.sh's H3-compliant
# design). The function `parse_comment` uses `local -` to scope its own
# `set -uo pipefail` so our `set -uo pipefail` above is preserved.
# shellcheck disable=SC1090
source "$PARSE_SH"

if ! declare -F parse_comment >/dev/null; then
  echo "ERROR parse_comment_undefined: sourcing $PARSE_SH did not define parse_comment" >&2
  exit 1
fi

# --- Iterate cases -----------------------------------------------------------

errs=0
total=0

# `jq -c` emits one compact JSON object per line. The `< <(...)` process
# substitution feeds it to `read` without spawning a subshell (which
# would scope $errs and $total locally and lose accumulation).
while IFS= read -r case; do
  total=$((total + 1))

  # `// ""` defends against missing keys (defense-in-depth alongside the
  # schema check above; per Pass-1 finding M4).
  name=$(jq -r '.name // ""' <<< "$case")
  input=$(jq -r '.input // ""' <<< "$case")
  expect_overlay=$(jq -r '.expect.overlay // ""' <<< "$case")
  expect_status=$(jq -r '.expect.status // ""' <<< "$case")
  expect_mode=$(jq -r '.expect.mode // ""' <<< "$case")

  # Capture rc explicitly so a parser bug (non-zero return) is reported
  # as a per-case failure rather than aborting the whole runner.
  # parse_comment is documented to return 0 always; rc != 0 is a defect.
  actual=$(parse_comment "$input")
  rc=$?
  if [ "$rc" != "0" ]; then
    errs=$((errs + 1))
    printf 'FAIL: %s\n  parse_comment exited rc=%s (expected 0)\n' "$name" "$rc" >&2
    continue
  fi

  # The wire format is always 3 fields, 2 pipes (per parse.sh contract).
  # IFS='|' read -r tokenizes the OUTPUT (which never contains user
  # pipes — those are inside tokens and consumed by the parser).
  IFS='|' read -r got_overlay got_status got_mode <<< "$actual"

  if [ "$got_overlay" != "$expect_overlay" ] \
     || [ "$got_status" != "$expect_status" ] \
     || [ "$got_mode" != "$expect_mode" ]; then
    errs=$((errs + 1))
    printf 'FAIL: %s\n  expected: overlay=[%s] status=[%s] mode=[%s]\n  got:      overlay=[%s] status=[%s] mode=[%s]\n' \
      "$name" "$expect_overlay" "$expect_status" "$expect_mode" \
      "$got_overlay" "$got_status" "$got_mode" >&2
  fi
done < <(jq -c '.[]' "$CASES_JSON")

# --- Summary -----------------------------------------------------------------

passed=$((total - errs))
printf 'summary: %d/%d passed\n' "$passed" "$total"

if [ "$errs" -gt 0 ]; then
  exit 1
fi
exit 0
