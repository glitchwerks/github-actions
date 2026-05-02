# shellcheck shell=bash
# parse.sh — pure bash parser for @claude verb invocations.
#
# Exposes a single function:
#
#   parse_comment <comment-body>
#
# Reads positional arg 1 (the comment body) and echoes ONE line of
# pipe-delimited output to stdout in the form:
#
#   <overlay>|<status>|<mode>
#
# where:
#   - overlay ∈ { review, fix, explain, "" }
#   - status  ∈ { ok, unknown_verb, malformed }
#   - mode    ∈ { apply, read-only, "" }
#
# Wire format is ALWAYS three fields and two pipes. Unset fields are empty
# strings (e.g. malformed input emits `|malformed|`).
#
# Returns 0 always. Status is the canonical pass/fail signal — callers must
# read the tuple, not the exit code. Returning non-zero would conflate
# "parser bug" with "input was malformed", which the test runner needs to
# distinguish.
#
# Auth is NOT this script's concern — claude-command-router/action.yml runs
# the auth check before sourcing parse.sh and emits status=unauthorized
# without invoking parse_comment. See spec §8.1, §8.1.1, §8.3, §10.3.
#
# Sourceability: this file's TOP-LEVEL scope sets NO bash flags. All `set`
# changes happen inside parse_comment() and are scoped via `local -`
# (bash 4.4+; ubuntu-latest ships 5.2.x). Sourcing this script does not
# alter the caller's shell options. See Phase 4 plan Pass-1 finding H3.

parse_comment() {
  # `local -` saves all current `set` flags and restores them on function
  # return. This is what makes parse.sh safely sourceable: even though we
  # enable `-uo pipefail` below for safety inside the function body, the
  # caller's flags (or lack thereof) are untouched after we return.
  local -
  set -uo pipefail

  local body="${1:-}"
  local overlay="" status="" mode=""

  # (a0) Normalize CRLF → LF. `read -ra` with default IFS splits on
  # space/tab/newline but NOT carriage return; Windows clients (gh CLI on
  # Windows, browser submissions, copy-paste) produce CRLF. Without
  # normalization, the regex matches `\r` via `[[:space:]]` but the
  # tokenizer leaves trailing `\r` on each token, producing token
  # `"review\r"` which fails exact-match against `review`.
  # Per Phase 4 plan Pass-2 finding C2.
  body="${body//$'\r'/}"

  # (a) Locate first @claude<whitespace>. Anchor: start-of-string OR a
  # non-alphanumeric character before @, then literal "claude"
  # (case-insensitive), then at least one [[:space:]]. The leading anchor
  # rejects "email@claude.example.com" and "prefix@claude review".
  # The matched substring is captured in BASH_REMATCH[0].
  local re='(^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]]'
  if ! [[ "$body" =~ $re ]]; then
    printf '%s|%s|%s\n' "" "malformed" ""
    return 0
  fi

  # (b) Compute first-mention tail by stripping everything up to and
  # including the matched prefix. We use `${body#*<match>}` rather than
  # arithmetic offsets because BASH_REMATCH[0] is the actual matched
  # substring including the leading non-alnum (or empty for ^ anchor),
  # and `#*` correctly strips the shortest prefix ending in that match.
  local first_match="${BASH_REMATCH[0]}"
  local tail="${body#*"$first_match"}"

  # (c) Truncate the tail at the NEXT @claude<whitespace> mention. Per
  # spec §8.1.1 step 9: the --read-only flag scan terminates at the next
  # @claude mention. By truncating tokens here, BOTH the verb scan and
  # the flag scan operate on first-mention tokens only. Per spec
  # §8.1.1 step 8 (parenthetical): "subsequent verb tokens, including
  # from a second @claude mention, are ignored."
  if [[ "$tail" =~ $re ]]; then
    local next_match="${BASH_REMATCH[0]}"
    tail="${tail%%"$next_match"*}"
  fi

  # (d) Tokenize on whitespace. read -ra splits on $IFS (default:
  # space/tab/newline). CRLF was normalized in (a0).
  local -a tokens=()
  read -ra tokens <<< "$tail"

  # (f) Empty-tokens guard. If the first-mention tail is whitespace-only
  # (e.g. trailing `@claude ` with no payload), tokens is empty and the
  # verb scan would silently fall through. Spec §8.1.1 row 13 says this
  # is "malformed", not "unknown_verb". Per Pass-2 finding H1.
  if [ "${#tokens[@]}" -eq 0 ]; then
    printf '%s|%s|%s\n' "" "malformed" ""
    return 0
  fi

  # (e) Verb scan — first known verb wins. Comparison is case-insensitive
  # via lowercase coercion. Comparison is exact-match — "review-thoroughly"
  # does NOT match "review". Scan operates on first-mention tokens only;
  # second-mention verbs are unreachable (truncation at step c).
  local token token_lc
  for token in "${tokens[@]}"; do
    token_lc="${token,,}"
    case "$token_lc" in
      review|fix|explain)
        overlay="$token_lc"
        status="ok"
        break
        ;;
    esac
  done

  # (g) If first-mention scan exhausted without verb match: status is
  # unknown_verb. mode defaults to "apply" (per Phase 4 plan Deviation
  # #5 — mode is empty ONLY for malformed; otherwise apply).
  if [ -z "$status" ]; then
    printf '%s|%s|%s\n' "" "unknown_verb" "apply"
    return 0
  fi

  # (h) Flag scan — --read-only is meaningful ONLY for overlay=fix
  # (spec §8.1.1 row 7). For non-fix overlays the flag is silently
  # ignored. Flag matching is case-sensitive (CLI flags are
  # conventionally lowercase).
  mode="apply"
  if [ "$overlay" = "fix" ]; then
    for token in "${tokens[@]}"; do
      if [ "$token" = "--read-only" ]; then
        mode="read-only"
        break
      fi
    done
  fi

  printf '%s|%s|%s\n' "$overlay" "$status" "$mode"
  return 0
}
