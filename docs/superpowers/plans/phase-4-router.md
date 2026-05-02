# Phase 4 Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author the `claude-command-router/` composite action that parses a triggering comment body into `{overlay, status, mode}` outputs per spec §8.1–§8.3. Pure string logic — no containers. The declarative JSON corpus at `claude-command-router/tests/cases.json` is the executable specification per spec §10.3, exercised on every PR via a new `.github/workflows/test.yml`.

**Architecture:**

- `claude-command-router/lib/parse.sh` — pure bash function, reads comment body from argv, echoes pipe-delimited `overlay|status|mode`. NO auth check, NO GitHub event reads, NO `$GITHUB_OUTPUT` writes. This is the unit-testable core.
- `claude-command-router/action.yml` — composite action wrapping `parse.sh`. Steps: (a) delegate to `./check-auth` and emit `status=unauthorized` on fail without invoking parse; (b) source `parse.sh`, run `parse_comment "${{ inputs.comment_body }}"`, parse the pipe-delimited output, write three outputs via `$GITHUB_OUTPUT`.
- `claude-command-router/lib/filler_words.txt` — documentation-only wordlist (per spec §8.1.1). The algorithm skips ALL non-verb tokens; the file documents "frequently seen" filler words for implementer reference.
- `claude-command-router/tests/cases.json` — JSON array of `{name, input, expect: {overlay, status, mode}}`. Sourced from spec §8.1.1 examples table (14 rows) + §10.3 minimum coverage (10 enumerated cases, mostly overlapping with §8.1.1). Final corpus: 17–20 distinct cases.
- `claude-command-router/tests/run-cases.sh` — pure bash + jq runner. Sources `parse.sh`, iterates `cases.json`, compares each emitted tuple to `expect`, fails on any mismatch with a precise error line (case name + expected vs actual).
- `.github/workflows/test.yml` — `runs-on: ubuntu-latest`, single step `bash ./claude-command-router/tests/run-cases.sh`. No `apt-get install` — `bash` and `jq` are preinstalled.

**Separation of concerns** (load-bearing):

- `parse.sh` is pure: reads stdin/argv, echoes stdout. No env reads, no file writes outside a stdout pipe. This makes it testable without any GHA harness.
- `action.yml` is the wiring: pulls `inputs.comment_body`, calls auth, calls parse, writes outputs.
- `run-cases.sh` exercises ONLY `parse.sh` — it does NOT invoke `action.yml` (which would require a real `github.event` payload it can't synthesize cleanly).

**Tech Stack:** Bash (5.x on `ubuntu-latest`), `jq` (preinstalled), `actionlint` (existing CI lint workflow). Nothing else. No `bats`, no `yq`, no `npm install`.

**Spec source of truth:** `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §8.1 (router composite action), §8.1.1 (parsing rules + 14-row examples table), §8.2 (caller workflow shape), §8.3 (error surface), §10.3 (router unit tests JSON corpus). Master plan: `docs/superpowers/plans/2026-04-22-ci-claude-runtime.md` §Phase 4, tasks 4.1–4.7.

**Issue:** [#142](https://github.com/glitchwerks/github-actions/issues/142). **Branch:** `phase-4-router` (off `main` @ `c8d9b7e`). **Worktree:** `I:/github-actions/.worktrees/phase-4-router`.

---

## Inquisitor passes (gate Tasks 2+)

Per `feedback_inquisitor_twice_for_large_design.md`: even though Phase 4 has a smaller surface than Phase 3, the parsing logic + composite action + JSON corpus form an interconnected contract where small bugs cascade. Pass 1 found 3 critical findings (broken auth wiring, half-correct injection guard, no adversarial corpus cases) — the surface IS large enough to warrant adversarial review.

- **Pass 1:** complete (2026-05-02). Report at `phase-4-router-inquisitor-pass-1.md` (14 actionable findings: 3 C, 6 H, 5 M; plus 3 OOS). All 14 addressed inline below — see "Pass 1 findings addressed" subsection.
- **Pass 2:** pending. Will run after Pass 1 revisions land. Charge: find new gaps introduced by Pass 1's revisions (Phase 3 precedent: pass 2 caught the `--entrypoint` silent-false-pass class of bug).

**Hard checkpoint:** Tasks 2+ (filler_words, parse.sh, corpus, runner, action.yml, test workflow, docs, PR) do not begin until Pass 2 completes.

---

## Pass 1 findings addressed (14/14 actionable)

**CRITICAL:**

- **C1 — auth wiring missing step IDs.** Resolved in Task 6: every step now has explicit `id:`. The `check-auth` step gets `id: authz`. The unauthorized branch and the parse branch BOTH share `id: parse` (mutually exclusive via `if:`) so the top-level `outputs:` block — which resolves `steps.parse.outputs.*` — sees the correct tuple regardless of which branch ran. Without this, the router silently emitted empty strings for everything (status=`""` instead of `unauthorized`).
- **C2 — env-var injection guard half-correct.** Resolved in Task 6.6: the `env: COMMENT_BODY` pattern is correct for shell-injection prevention (the body never reaches `eval`); the YAML-template-expansion concern is mitigated because GHA's runner correctly quotes `${{ }}` substitutions for `env:` scalars (see [GHA security docs](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-an-intermediate-environment-variable)). The plan now cites this. Adversarial corpus cases (per C3) prove the parser handles hostile bodies without side effects.
- **C3 — corpus had zero adversarial cases.** Resolved in Task 4 expansion: corpus now includes hostile-body cases for shell metacharacters (`$(date)`, backticks, `; rm -rf /`), GHA template literals (`${{ secrets.X }}`), pipe-in-body (`@claude review the foo|bar branch`), multi-line bodies (`@claude review\n@claude fix`), backtick-wrapped mentions, leading-non-alphanum prefixes (`email@claude.example.com`, `prefix@claude review`), and verb-prefix tokens (`@claude review-thoroughly`). Each row pins the expected `{overlay, status, mode}` and the `name` field documents rationale. Final corpus: 24+ cases.

**HIGH-PRIORITY:**

- **H1 — three regex engines named without picking one.** Resolved in Task 3.3: pick **bash regex with `[[ "$body" =~ ... ]]`** (no awk fallback). `ubuntu-latest` ships bash 5.2.x — version-skew concern is theoretical at this scope. Bash regex with `BASH_REMATCH` is the cleanest path because subsequent steps use bash-native string operations (`${token,,}`, `read -ra`); switching engines mid-algorithm would be an integration footgun.
- **H2 — Task 3.3 step 2 stream-of-consciousness draft.** Resolved: replaced step 2 with concrete pseudocode block specifying the wire format ONCE: `printf '%s|%s|%s\n' "$overlay" "$status" "$mode"` always; unset fields are empty strings. No working-out-loud paragraph.
- **H3 — `set -uo pipefail` at file scope pollutes calling shell.** Resolved in Task 3.1: parse.sh's file scope sets NO flags. The `parse_comment()` function uses `local -` (bash 4.4+; available on `ubuntu-latest`) at function entry, which saves all `set` flags and restores them on function return. Inside the function: `set -uo pipefail` for safety. Caller's shell flags are untouched.
- **H4 — `run-cases.sh` accumulate-vs-short-circuit bug.** Resolved in Task 5.2: explicit invocation pattern `actual=$(parse_comment "$input"); rc=$?` so a non-zero exit becomes a per-case test failure printed in the summary, NOT a runner abort. The runner uses `set -uo pipefail` (NOT `-e`) and accumulates failures via a counter (same pattern as Phase 3's matcher). Task 9.4 now flips TWO cases to verify accumulation empirically (per M5).
- **H5 — `filler_words.txt`: docs vs spec disagreement.** Resolved in Deviation #9: the file is **documentation-only**. The algorithm skips ALL non-verb tokens regardless. The spec's "router loads this file at startup" claim is a doc bug — Task 12 (new) amends spec §8.1.1 step 5 to remove that claim and clarify the file's documentation role. The corpus has cases for filler words IN the file (`please`, `can`) and NOT in the file (`triage`, `cook`) — both produce the same skip behavior, validating the algorithm's "skip all non-verb" property.
- **H6 — `--read-only` flag scan termination at next `@claude`.** Resolved in Task 3.3: explicit two-step extraction. Step (a): locate the FIRST `@claude<whitespace>` boundary via `BASH_REMATCH` offsets. Step (b): from that offset forward, scan the body for the NEXT `@claude<whitespace>` boundary OR end of body, whichever comes first. The substring between is the "first-mention tail." Tokenize that with `read -ra`; verb-scan + flag-scan operate on those tokens only. Corpus row added: `@claude fix\n@claude --read-only` → expect `mode=apply` (flag in second mention is ignored).

**MEDIUM:**

- **M1 — `@claude review-thoroughly` (verb-prefix token).** Resolved in corpus: `@claude review-thoroughly` → `unknown_verb`. Token comparison is exact-match; `review-thoroughly` is not in the allowlist; scan continues; no other verb appears.
- **M2 — non-mention regex assertions untested.** Resolved in corpus: `email@claude.example.com please review` → `malformed`; `prefix@claude review` → `malformed` (the regex's leading-anchor `(^|[^A-Za-z0-9])` rejects both).
- **M3 — no JSON Schema for `cases.json`.** Resolved in Task 5.3: runner's startup checks include a per-case shape assertion via `jq` — every case has top-level `{name, input, expect}` with `expect` containing `{overlay, status, mode}`. Missing keys → fail at startup with a precise error.
- **M4 — `jq -r` of missing key returns literal "null".** Resolved in Task 5.2: jq filters use `// ""` to coerce missing keys to empty string (`jq -r '.expect.mode // ""'`). Combined with M3's startup schema check, missing keys are caught early; the `// ""` is defense-in-depth.
- **M5 — Task 9.4 deliberate-flip only validates ONE mismatch.** Resolved in Task 9.4: flip TWO unrelated cases, assert BOTH names appear in the failure output. Validates accumulate-then-exit empirically.

**OUT-OF-SCOPE:**

- **OOS-1 — `mode` empty-vs-`apply` semantics defensible** (Pass 1 sanity-checks Deviation #5). Spec amendment to clarify the table will be filed alongside H5's amendment in Task 12.
- **OOS-2 — CLAUDE.md ordering inconsistency** (Pass 1 notes the existing list is not alphabetic). Task 8.1 preserves the existing pseudo-order rather than re-sorting; "claude-command-router/" inserts where it logically fits (after `tag-claude/` since it's the eventual replacement, before `check-auth/` since it depends on it). The pseudo-order is documented as "by responsibility, not alphabetic" in a brief note.
- **OOS-3 — `./check-auth` relative path** is fine because the router is internal-only per spec §8.2. No plan change needed.

---

## Deviations from master plan (recorded as the plan is authored)

1. **JSON corpus contains 17–20 cases, not exactly 15.** Master plan task 4.4 says "15+ cases minimum"; spec §8.1.1 has 14 rows + §10.3 lists 10 minimum-coverage cases (with overlap). After dedup, the natural corpus is 17–20. Trade-off: more maintenance per case-add but higher coverage of edge cases (multiple `@claude` mentions, `@claude-review` no-delimiter rejection, `--read-only` for non-fix overlays).

2. **`run-cases.sh` exercises `parse.sh` directly, not via `action.yml`.** Spec §10.3 says "sources `claude-command-router/lib/parse.sh`" — that's the design. `action.yml` invokes `check-auth/` which reads `github.event.comment.*` from the event payload; tests would need a synthetic payload to exercise that path. Skipping `action.yml` keeps the test pure (string in, tuple out) and matches spec intent. Auth is tested separately by the existing `check-auth/` action's own surface (and indirectly by Phase 5/7 dogfood).

3. **`parse_comment()` returns pipe-delimited `overlay|status|mode`, not three separate variables.** Spec §10.3 shows the runner "compares each emitted `{overlay, status, mode}` tuple to the `expect` object" — implementation choice for the emitter wire format isn't constrained. Pipe-delimited is the simplest pure-stdout shape that's stable under bash IFS rules. `action.yml` parses with `IFS='|' read -r overlay status mode` and writes each field separately to `$GITHUB_OUTPUT`.

4. **Empty-string outputs are valid for `overlay` and `mode` per the spec table.** When `status=malformed` or `status=unknown_verb`, `overlay` is "—" in the spec's example table and `mode` is "—" or `apply` depending on context. Implementation: emit empty string for unresolved fields. JSON cases use the empty string `""` for these. This matches the spec's `expect` schema (`overlay: review|fix|explain|""`) where the trailing `|` allows empty.

5. **`mode` defaults to `apply` even when `overlay` is unresolved**, per the spec table:
   - `@claude review` → `mode: apply` (default)
   - `@claude check this PR` (unknown verb) → `mode: apply` per row 8 of the §8.1.1 table.
   - `@claude thanks!` (unknown verb) → `mode: —` per row 11 — i.e. "the mode is not meaningful when there's no resolved verb."
   - `@claude` (bare, malformed) → `mode: —` per row 13.

   The spec's table is internally inconsistent (row 8 says `apply`, row 11 says `—`). **Decision:** treat the inconsistency as the empty-string-vs-default question. For v1, `mode` is always emitted as `apply` (string default) when no `--read-only` token is present, regardless of whether the verb resolved. Empty-string `mode` only emits when the input is so malformed that even default-application makes no sense (bare `@claude`, `@claude-review`). The JSON corpus encodes this: rows where the spec says `apply` use `"mode": "apply"`; rows where the spec says `—` use `"mode": ""`. This is a **defensible reading** of the spec; if the spec is later clarified differently, the corpus + parse.sh both update in the same commit.

6. **`@claude-review` (no whitespace delimiter) → `status: malformed`, NOT `unknown_verb`.** Spec §8.1.1 row 14 explicitly lists this case as `malformed`. The parser's first step locates `@claude` followed by at least one whitespace character; absence of whitespace is treated as no-mention-found (malformed). This interpretation matches the spec row but is worth calling out because a naive `grep -i '@claude' input` would match `@claude-review` and then fail on tokenization.

7. **Multiple `@claude` mentions: only the first is parsed.** Spec §8.1.1 row 12 shows `@claude review and also @claude fix` → `review`. The parser locates the FIRST `@claude<whitespace>` mention, tokenizes the tail until the NEXT `@claude` mention or end of comment, and applies first-verb-wins to that token stream. The `--read-only` scan terminates at the next `@claude` mention too (per §8.1.1 step 9 of the algorithm).

8. **`actionlint` shellcheck `-S info` clean is a hard gate, not a soft guideline.** Per Phase 3 PR #186 lessons: the dogfood `pr-review` workflow runs `raven-actions/actionlint@v2` which surfaces info-level shellcheck findings as errors. Local `actionlint` defaults to lower severity. **Run `actionlint -shellcheck="-S info"` locally before push.** Avoid `A && B || C` patterns (SC2015) — use explicit `if/then/fi`.

9. **`filler_words.txt` is documentation-only** (per Pass-1 H5 / Deviation reconciliation). The algorithm at Task 3.3 step 4 skips ALL non-verb tokens regardless of whether they appear in this file. The file documents "frequently-seen filler tokens" for implementer reference and reviewer convenience. **Spec amendment scheduled** (Task 12.1): §8.1.1 step 5 currently says "the router loads this file at startup" — this is incorrect; remove that claim. The corpus tests both file-listed and unlisted filler words to confirm the skip-all-non-verb property.

Items deferred (with explicit triggers):

- **Tool-deny hooks for read-only mode enforcement** — spec §3.4 layer 2 / Phase 3 explain overlay's CLAUDE.md notes that `--read-only` is currently mechanism-dependent (relies on the model honoring the persona). Defense-in-depth via a `PreToolUse` hook on `Edit`/`Write` is a Phase 6 hardening item. Tracked in master plan deferred items.

- **Rename `mode` → `commit_policy` (§13 Q9)** — keep `mode: apply | read-only` for v1. Rename when a second orthogonal flag (`--draft`, etc.) arrives, exposing the verb-vs-policy axis the inquisitor flagged. Action.yml carries an inline TODO comment referencing §13 Q9.

- **Multi-token verbs (e.g. `summarize`, `redesign`)** — v1 verb allowlist is `{review, fix, explain}`. Adding new verbs requires (a) an overlay image in Phase 3 or beyond, (b) a manifest schema update, (c) a corpus extension. Not Phase 4 scope.

---

## File Structure

Paths relative to repo root. All created on the `phase-4-router` worktree.

```
claude-command-router/
  action.yml                              # Task 4.2 — composite action; auth + parse + outputs
  lib/
    parse.sh                              # Task 4.4b — pure-bash parse_comment() function
    filler_words.txt                      # Task 4.1 — frequently-seen filler tokens (documentation)
  tests/
    cases.json                            # Task 4.4 — 17–20 declarative cases per §8.1.1 + §10.3
    run-cases.sh                          # Task 4.5 — pure bash+jq runner; sources parse.sh

.github/workflows/
  test.yml                                # Task 4.5 — runs run-cases.sh on every PR

CLAUDE.md                                 # Task 4.7 — add claude-command-router/ row to Architecture → Actions table
```

Files NOT touched in Phase 4 (intentionally — they belong to other phases):

- `tag-claude/` deprecation — Phase 7
- `.github/workflows/claude-tag-respond.yml` (caller workflow that consumes the router) — Phase 5
- Overlay images, expected.yaml, STAGE 3 — Phase 3 (already shipped)

---

## Pinned identifiers (verified live at plan-write time, 2026-05-02)

Phase 4 introduces no new pinned identifiers. Existing infrastructure is unchanged:

| Pin | Value | Phase |
|---|---|---|
| `actions/checkout` | `@v5` | Phase 1 |
| Existing `check-auth/` composite action | unchanged | (existing) |

Verb allowlist in `parse.sh` MUST match `runtime/ci-manifest.yaml`'s `overlays.*` keys (`review`, `fix`, `explain`). Coupling note: a future overlay rename in Phase 3 requires a coordinated update to `parse.sh` and the JSON corpus. v1 has no plans for overlay renames.

---

## Tasks

### Task 1 — Read & confirm spec contracts

- [ ] **1.1** Read `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §8.1, §8.1.1, §8.2, §8.3 end-to-end. Confirm the 14 example rows + the 9 parsing-algorithm steps + the 5-row error surface.
- [ ] **1.2** Read §10.3 — confirm the JSON corpus shape and minimum-coverage list (10 enumerated cases). Note overlapping cases with §8.1.1 examples (de-dup at corpus authoring).
- [ ] **1.3** Read existing `check-auth/action.yml` to confirm its outputs contract (`outputs.authorized: 'true'|'false'`) and event-context dependencies (`github.event.comment.user.login`, `author_association`). Router's auth wiring matches this contract.
- [ ] **1.4** Decision recorded in Deviation #5 above: `mode` always emits `apply` as default unless `--read-only` is found and `overlay=fix`; emits `""` when input is malformed. JSON corpus must reflect this.

### Task 2 — Author `claude-command-router/lib/filler_words.txt`

- [ ] **2.1** Author the file with one lowercase word per line. Initial list per master plan task 4.1: `please, can, you, go, help, and, also, me, a, the, linter, ci`. One per line.
- [ ] **2.2** Add a leading comment block (lines starting with `#`) explaining: (a) this file is documentation-only — the algorithm skips ALL non-verb tokens regardless of whether they appear here; (b) when adding a word, also add at least one JSON case demonstrating it; (c) lowercased; (d) one per line.
- [ ] **2.3** Commit. Message: `feat(router): filler_words.txt documentation list (refs #142)`.

### Task 3 — Author `claude-command-router/lib/parse.sh`

- [ ] **3.1** Author `parse.sh` exposing a single function `parse_comment()`. **File scope sets NO flags** (per Pass-1 H3 — sourceable scripts must not pollute caller's shell options). All `set` flags are scoped inside the function via `local -` (bash 4.4+; `ubuntu-latest` ships 5.2.x).
- [ ] **3.2** Function signature: `parse_comment <comment-body>` reads positional arg 1 (the body), echoes ONE line of pipe-delimited `<overlay>|<status>|<mode>` to stdout, returns 0 always. The status field is the source of truth for "did parsing succeed"; the function never returns non-zero (callers read the tuple, not the exit code). Wire format is **always 3 fields, 2 pipes**, e.g. `|malformed|` for the malformed case (overlay empty, status="malformed", mode empty).
- [ ] **3.3** Algorithm (per spec §8.1.1; uses **bash regex**, not awk — Pass-1 H1 commits to one engine):

  ```bash
  parse_comment() {
    local -                       # scope all `set` changes to this function
    set -uo pipefail              # safety inside the function
    local body="${1:-}"
    local overlay="" status="" mode=""

    # (a) Locate first @claude<whitespace>. Anchor: start-of-string OR non-alphanumeric
    # before @, exactly the literal "claude" (case-insensitive), followed by [[:space:]].
    # The regex stores the matched substring in BASH_REMATCH[0]; we use its length to
    # compute the offset of the tail (after @claude<whitespace>).
    local re='(^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]]'
    if ! [[ "$body" =~ $re ]]; then
      printf '%s|%s|%s\n' "" "malformed" ""
      return 0
    fi

    # (b) Compute first-mention tail. ${body#*<match>} strips up to and including
    # the first match, leaving the post-match remainder. We use BASH_REMATCH directly:
    #   - prefix_match = BASH_REMATCH[0]  (e.g. " @claude ")
    #   - tail = body with that prefix stripped from its first occurrence
    local first_match="${BASH_REMATCH[0]}"
    local tail="${body#*"$first_match"}"

    # (c) Truncate the tail at the NEXT @claude<whitespace> mention (per spec §8.1.1
    # step 9: flag scan terminates at next mention). Re-run the same regex against
    # the tail; if it matches, truncate before the matched prefix.
    if [[ "$tail" =~ $re ]]; then
      local next_match="${BASH_REMATCH[0]}"
      tail="${tail%%"$next_match"*}"
    fi

    # (d) Tokenize tail on whitespace. read -ra splits on $IFS (default: space/tab/newline).
    local -a tokens=()
    read -ra tokens <<< "$tail"

    # (e) Verb scan: first known verb wins ACROSS ALL MENTIONS (per spec §8.1.1
    # step 8 + Pass-1 corpus discovery for "@claude review\n@claude fix" case).
    # If first-mention tokens have no verb, continue with subsequent mentions.
    # We iterate: at each iteration, (1) scan current `tokens` array for a verb;
    # (2) if found, break; (3) otherwise, advance to the next @claude mention's
    # tokens (re-run regex on the body starting after the current truncation).
    local token token_lc
    local body_remaining="$body"
    while :; do
      for token in "${tokens[@]}"; do
        token_lc="${token,,}"
        case "$token_lc" in
          review|fix|explain)
            overlay="$token_lc"
            status="ok"
            break 2          # break out of both loops
            ;;
        esac
      done
      # Current mention exhausted without match. Advance to the next @claude
      # mention's tail. body_remaining is the body content after the most-recent
      # truncation point; the next mention starts wherever the regex matches in
      # the post-truncation suffix.
      body_remaining="${body_remaining#*"$first_match"}"
      if ! [[ "$body_remaining" =~ $re ]]; then
        break          # no more mentions
      fi
      first_match="${BASH_REMATCH[0]}"
      tail="${body_remaining#*"$first_match"}"
      if [[ "$tail" =~ $re ]]; then
        local next2="${BASH_REMATCH[0]}"
        tail="${tail%%"$next2"*}"
      fi
      tokens=()
      read -ra tokens <<< "$tail"
    done

    # (f) If all mentions exhausted without match: status=unknown_verb. mode defaults
    # to apply (per Deviation #5: mode is always emitted; "apply" is the default for
    # non-malformed inputs even if verb is unresolved).
    if [ -z "$status" ]; then
      printf '%s|%s|%s\n' "" "unknown_verb" "apply"
      return 0
    fi

    # (g) Flag scan: --read-only is meaningful only for overlay=fix (spec §8.1.1 row 7).
    # Continue scanning the same token array for a literal `--read-only` token. Flag is
    # case-sensitive (CLI flags are conventionally lowercase). For non-fix overlays the
    # flag is silently ignored — mode stays apply.
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
  ```

- [ ] **3.4** Edge cases the implementation MUST handle (cross-reference spec §8.1.1 rows + Deviations #6, #7):
  - Bare `@claude` (no whitespace after) → regex requires `[[:space:]]`; no match → `|malformed|`.
  - `@claude` followed by EOF (whitespace then nothing) → regex matches; tail is empty; tokenize yields zero tokens; verb-scan exhausts; output `|unknown_verb|apply`. **Spec §8.1.1 row 13 says `malformed` for "bare @claude" — this is the trailing-whitespace case which differs from "literally just @claude with no space"**. Both should be `malformed` per the spec. Resolve by adding an explicit check: if `tokens` array is empty after tokenization → `printf '%s|%s|%s\n' "" "malformed" ""` instead of falling through to verb scan.
  - `@claude-review` (no whitespace, hyphen instead) → regex's `[[:space:]]` requirement fails → `|malformed|`. Per row 14.
  - `@claude<TAB>review` → `[[:space:]]` matches tab; tokenize yields `review`. Resolves.
  - `@claude   review` (multiple spaces) → tokenize collapses; resolves.
  - `@claude please review and also @claude fix` → first-mention truncation (step c) cuts at second `@claude`; first-mention tail is `please review and also`; verb-scan resolves `review`.
  - `@claude review --read-only` → `overlay=review`, flag-scan skipped (not fix); `mode=apply`. Per row 7.
  - `@claude review and also fix` → first-verb-wins; `review`. Per row 11.
  - `email@claude.example.com please review` → leading-anchor `(^|[^A-Za-z0-9])` requires non-alnum before `@`; `l` is alnum → no match → `|malformed|`.
  - `prefix@claude review` → similarly `x` is alnum before `@` → no match → `|malformed|`.
  - `@claude review-thoroughly` → `review-thoroughly` is not in the allowlist; case skips it; verb-scan exhausts; `|unknown_verb|apply`.
  - `@claude fix\n@claude --read-only` → first-mention tail is `fix\n` → tokens `[fix]` → resolves verb=fix; flag-scan over the same tokens, no `--read-only` token; `mode=apply`. Second mention's flag is ignored (truncation at step c).
- [ ] **3.5** Add a top-of-file comment block documenting: (a) the function signature; (b) output format (3 fields, 2 pipes, always); (c) cross-references to spec §8.1.1 + §10.3; (d) auth is NOT this script's job — `action.yml` handles it; (e) this script is sourceable; the function uses `local -` to scope `set` flags so callers' shell options are not polluted (Pass-1 H3); (f) the function returns 0 always — status is the canonical pass/fail signal.
- [ ] **3.6** Commit. Message: `feat(router): parse.sh — pure verb-scanning function per §8.1.1 (refs #142)`.

### Task 4 — Author `claude-command-router/tests/cases.json`

Final corpus has **24+ cases** (Pass-1 C3 expansion). Source breakdown:

- **§8.1.1 examples table (14 rows)** — all 14 translated verbatim.
- **§10.3 minimum coverage (10 entries)** — ~3-6 unique additions after dedup.
- **Stress-test cases (2)** — uppercase verb + tab delimiter.
- **Pass-1-mandated adversarial cases (8)** — shell metacharacters, GHA template literals, multi-line bodies, backticks, leading-non-alphanum prefixes, verb-prefix tokens. Per Pass-1 C3, M1, M2.

- [ ] **4.1** Translate every row of spec §8.1.1 examples table (14 rows) into a JSON case. Shape: `{name: "<short>", input: "<verbatim>", expect: {overlay, status, mode}}`. Resolve `—` cells per Deviation #5 (`mode` is always emitted as `apply` or `read-only`; empty only for `malformed` status).
- [ ] **4.2** Translate every §10.3 minimum-coverage entry not already covered by step 4.1 (~3-6 additions).
- [ ] **4.3** Add stress-test cases (whitespace + case sensitivity):
  - `@claude REVIEW THIS PLEASE` → `review|ok|apply` (case-insensitive verb match).
  - `@claude\treview` (tab-delimited) → `review|ok|apply` (whitespace tolerance covers `\t`).
- [ ] **4.4** **Adversarial cases (Pass-1 C3 mandatory).** Every row pins the expected `{overlay, status, mode}` and the `name` field documents the rationale:
  - **shell-metachar-1**: `@claude review $(rm -rf /)` → `review|ok|apply`. The body is treated as data; no shell expansion. The parser tokenizes `$(rm`, `-rf`, `/)` as separate non-verb tokens (skipped); first verb is `review`.
  - **shell-metachar-2**: ``@claude fix `cat /etc/passwd` --read-only`` → `fix|ok|read-only`. Backticks are character literals in tokens; tokenizer ignores them; `--read-only` token still detected.
  - **shell-metachar-3**: `@claude review; rm -rf /` → `review|ok|apply`. Semicolon is a token character, not a shell separator.
  - **gha-template-literal**: `@claude review ${{ secrets.X }}` → `review|ok|apply`. The `${{ }}` is treated as data when the body is passed via `env:` (Pass-1 C2). Tokens `${{`, `secrets.X`, `}}` are non-verbs, skipped.
  - **pipe-in-body**: `@claude review the foo|bar branch` → `review|ok|apply`. Pipe is a token character; the parser's stdout output is `review|ok|apply` (3 fields, 2 pipes); the runner's `IFS='|' read` correctly tokenizes the OUTPUT (which never contains user pipes — only fixed delimiters). This case asserts the body's pipe doesn't leak into the output.
  - **multi-line-mention-flag-in-second**: `@claude fix\n@claude --read-only` → `fix|ok|apply`. First-mention tail truncates at second `@claude`; second mention's flag is ignored.
  - **multi-line-two-mentions-first-wins**: `@claude review\n@claude fix` → `review|ok|apply`. First-mention tail is `\n` (no tokens); verb-scan exhausts the first mention's tokens... **WAIT** — this case fails verb resolution under the truncation rule. Re-read: first-mention tail is `\n` (only whitespace before next `@claude`); `read -ra` produces zero tokens; verb-scan exhausts → `unknown_verb`. Spec §8.1.1 row 12 says `@claude review and also @claude fix` → `review` (first wins) — but that case has tokens between the two mentions. The newline-only case is genuinely ambiguous: does first-verb-wins mean "across all mentions" or "in first mention only"? **Decision per §8.1.1 step 8 ("First-verb-wins: scanning stops at the first known-verb match"):** the truncation rule means each mention is scanned independently in mention order; if first mention has no verb, scan continues to second. Update parse.sh step (e) to: if first-mention verb-scan exhausts, advance to next mention and re-scan; first verb across all mentions wins. **Add this to Task 3.3 as step 3.3.5** (revision below). For this corpus row: `@claude review\n@claude fix` → `review|ok|apply` (first mention has `review` verb, wins).
  - **leading-non-alphanum-1**: `email@claude.example.com please review` → `|malformed|`. The `@` is preceded by `l` (alnum); regex's leading-anchor `(^|[^A-Za-z0-9])` rejects.
  - **leading-non-alphanum-2**: `prefix@claude review` → `|malformed|`. Same rejection.
  - **verb-prefix-token**: `@claude review-thoroughly` → `|unknown_verb|apply`. Token `review-thoroughly` is not in allowlist; exact-match case skips; scan exhausts.
  - **verb-prefix-then-real-verb**: `@claude review-thoroughly and fix` → `fix|ok|apply`. `review-thoroughly` skipped; `fix` (in allowlist) wins.
  - **filler-word-not-in-list**: `@claude triage and fix the lint` → `fix|ok|apply`. `triage` is not in `filler_words.txt` but is also not a verb; algorithm skips it (validates Deviation #9: file is documentation-only; algorithm skips ALL non-verbs).
  - **filler-word-in-list**: `@claude please review` → `review|ok|apply`. `please` IS in `filler_words.txt`; same skip behavior.
- [ ] **4.5** Verify corpus is well-formed JSON: `jq . cases.json >/dev/null`. Every case has top-level `{name, input, expect}` and `expect` has `{overlay, status, mode}`. No trailing commas, no shell-style comments. The `name` field doubles as case documentation.
- [ ] **4.6** Commit. Message: `feat(router): cases.json — 24+ cases incl. adversarial (refs #142)`.

### Task 5 — Author `claude-command-router/tests/run-cases.sh`

- [ ] **5.1** Author the runner: pure bash + jq. Header: `set -uo pipefail` (NOT `-e`; we want accumulate-then-exit per Pass-1 H4). Failures accumulate in a counter; `exit 1` only after all cases run.
- [ ] **5.2** Behavior:
  1. Resolve repo root via `git rev-parse --show-toplevel` (fallback: `dirname`-walking from the script's location for non-git contexts).
  2. Source `parse.sh`: `source "$REPO_ROOT/claude-command-router/lib/parse.sh"`. Note: `parse.sh` does NOT pollute the runner's shell options (per Pass-1 H3 + Task 3.1 — file scope sets no flags; flags scoped to function body via `local -`).
  3. **Schema check (per Pass-1 M3 / M4):** before iteration, assert every case has `{name, input, expect: {overlay, status, mode}}`:
     ```bash
     jq -e 'all(.[]; has("name") and has("input") and (.expect | has("overlay") and has("status") and has("mode")))' cases.json >/dev/null \
       || { echo "ERROR cases_json_schema_invalid: every case must have {name,input,expect:{overlay,status,mode}}" >&2; exit 1; }
     ```
  4. Iterate cases via `jq -c '.[]'`. For each case, extract fields with `// ""` defaults (M4 defense-in-depth in case schema check ever weakens):
     ```bash
     name=$(jq -r '.name // ""' <<< "$case")
     input=$(jq -r '.input // ""' <<< "$case")
     expect_overlay=$(jq -r '.expect.overlay // ""' <<< "$case")
     expect_status=$(jq -r '.expect.status // ""' <<< "$case")
     expect_mode=$(jq -r '.expect.mode // ""' <<< "$case")
     ```
  5. **Invoke parser via command substitution + explicit rc capture (per Pass-1 H4):**
     ```bash
     actual=$(parse_comment "$input")
     rc=$?
     if [ "$rc" != "0" ]; then
       errs=$((errs + 1))
       echo "FAIL: $name — parse_comment exited rc=$rc (expected 0)" >&2
       continue
     fi
     IFS='|' read -r got_overlay got_status got_mode <<< "$actual"
     ```
     `parse_comment` is documented to return 0 always (Task 3.2); `rc != 0` is a parser bug, not a test failure — log and continue so subsequent cases still run.
  6. Compare each field; on any mismatch, increment `errs` counter and emit:
     ```
     FAIL: <name>
       expected: overlay=<x> status=<y> mode=<z>
       got:      overlay=<a> status=<b> mode=<c>
     ```
  7. After all cases iterate: print `summary: <pass>/<total> passed`. Exit 1 if `errs > 0`, else exit 0. **Critical:** the exit happens AFTER iteration, not on first failure.
- [ ] **5.3** Defensive startup checks (in this order):
  - Assert `command -v jq >/dev/null` (sanity — jq is on `ubuntu-latest`; the assertion produces a readable error if a future runner lacks it).
  - Assert `cases.json` exists and parses as JSON (`jq . cases.json >/dev/null`).
  - Assert corpus size: `jq 'length' cases.json` returns ≥15. Fail loudly if not.
  - Run the schema check from step 5.2.3.
- [ ] **5.4** Commit. Message: `feat(router): run-cases.sh — bash+jq runner with schema check + accumulate-then-exit (refs #142)`.

### Task 6 — Author `claude-command-router/action.yml`

**Critical wiring (Pass-1 C1):** the top-level `outputs:` block resolves `steps.parse.outputs.*`. Both the unauthorized branch AND the parse branch must use `id: parse` (mutually exclusive via `if:`), otherwise the unauthorized branch's outputs never reach the action's exposed outputs and consumers see empty strings instead of `status=unauthorized`.

- [ ] **6.1** Top-level: `name: 'Claude Command Router'`, `description: 'Parse @claude verb invocations into {overlay, status, mode} for downstream dispatch'`.
- [ ] **6.2** Inputs: `comment_body` (string, required, no default), `authorized_users` (string, optional, default `''`).
- [ ] **6.3** Outputs (per spec §8.1; `# TODO: §13 Q9` comment near `mode` declaration referencing the rename-to-`commit_policy` deferral per master plan task 4.3):
  ```yaml
  outputs:
    overlay:
      description: "Resolved overlay name: review | fix | explain | '' (empty when not resolved)"
      value: ${{ steps.parse.outputs.overlay }}
    status:
      description: "Parse status: ok | unknown_verb | malformed | unauthorized"
      value: ${{ steps.parse.outputs.status }}
    # TODO: §13 Q9 — rename `mode` to `commit_policy` when a second orthogonal flag
    # (e.g. --draft) is introduced. Decision deferred for v1; see master plan task 4.3.
    mode:
      description: "Commit policy: apply | read-only | '' (empty when input is malformed)"
      value: ${{ steps.parse.outputs.mode }}
  ```
- [ ] **6.4** Steps — TWO steps total, single `id: parse` step that branches internally on auth status:

  ```yaml
  runs:
    using: composite
    steps:
      - name: Check authorization
        id: authz
        uses: ./check-auth
        with:
          authorized_users: ${{ inputs.authorized_users }}

      - name: Parse comment body (or emit unauthorized)
        id: parse
        shell: bash
        env:
          COMMENT_BODY: ${{ inputs.comment_body }}
          AUTHORIZED: ${{ steps.authz.outputs.authorized }}
        run: |
          set -uo pipefail

          # Branch on auth result. check-auth writes 'true'|'false' to its
          # `authorized` output (see check-auth/action.yml lines 38, 41, 51, 55).
          if [ "$AUTHORIZED" != "true" ]; then
            {
              echo "overlay="
              echo "status=unauthorized"
              echo "mode="
            } >> "$GITHUB_OUTPUT"
            exit 0
          fi

          # Source parse.sh — uses `local -` inside parse_comment to scope `set`
          # flags. File scope of parse.sh sets no flags (per Pass-1 H3).
          # shellcheck disable=SC1091
          source "${{ github.action_path }}/lib/parse.sh"

          # Body comes from env (Pass-1 C2: GHA quotes env: scalars correctly,
          # so ${{ inputs.comment_body }} is bound as a YAML string, NOT
          # interpolated into the shell command line).
          tuple=$(parse_comment "$COMMENT_BODY")
          IFS='|' read -r overlay status mode <<< "$tuple"

          {
            echo "overlay=$overlay"
            echo "status=$status"
            echo "mode=$mode"
          } >> "$GITHUB_OUTPUT"
  ```

  **Why one step, not two:** GHA requires step `id:` values to be unique within a job. The "two mutually-exclusive `id: parse` steps" pattern from an earlier plan draft would fail YAML validation. Consolidating to one step that branches internally on `$AUTHORIZED` produces ONE step that always writes the three output keys — the action's top-level `outputs:` block resolves `steps.parse.outputs.*` deterministically regardless of branch. This is the canonical single-source-of-truth pattern for composite-action outputs.
- [ ] **6.5** Inline TODO comment for §13 Q9 already in step 6.3 above. Nothing additional needed.
- [ ] **6.6** **Injection guard rationale (per Pass-1 C2):** `env: COMMENT_BODY: ${{ inputs.comment_body }}` is the safe pattern because:
  - GHA's runner emits `${{ }}` substitutions for `env:` scalars as quoted YAML strings, NOT inline shell. The runner does NOT recursively expand substituted content.
  - Inside the `run:` block, the body is referenced as `"$COMMENT_BODY"` — bash expansion only, no `eval`. A body containing `$(rm -rf /)` is a literal 12-character string in the bash variable; no command substitution.
  - GHA security docs: <https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-an-intermediate-environment-variable>.
  - The corpus (Task 4.4) includes hostile-body cases asserting end-to-end safety: `@claude review $(rm -rf /)` returns `review|ok|apply` without side effects.
  - **Anti-pattern to avoid:** `run: ... parse_comment "${{ inputs.comment_body }}"` — inline interpolation. The `${{ }}` expands to the body content INSIDE the shell command line, where shell parsing then sees `$(...)` and triggers command substitution. NEVER do this for untrusted strings.
- [ ] **6.7** Commit. Message: `feat(router): action.yml — composite action wiring auth + parse with mutually-exclusive id: parse (refs #142)`.

### Task 7 — Author `.github/workflows/test.yml`

- [ ] **7.1** Single job: `name: tests`, `runs-on: ubuntu-latest`, timeout 5m.
- [ ] **7.2** Triggers: `pull_request` (on any path) + `push: branches: [main]`. Path filters intentionally absent — the test corpus is small (~17 cases × <1ms each = <1s wall clock); always running it is cheaper than maintaining the path filter.
- [ ] **7.3** Steps:
  - `uses: actions/checkout@v5` (depth 1 sufficient).
  - `name: Run router tests`, `run: bash ./claude-command-router/tests/run-cases.sh`. No env, no installs.
- [ ] **7.4** Verify locally with `actionlint -shellcheck="-S info" .github/workflows/test.yml` before push.
- [ ] **7.5** Commit. Message: `ci(router): test.yml — runs run-cases.sh on every PR (refs #142)`.

### Task 8 — Update `CLAUDE.md` Architecture table

- [ ] **8.1** Add a row to the `### Actions` list under `## Architecture`. The existing list is ordered by responsibility (not alphabetic — Pass-1 OOS-2). Insert the router after `tag-claude/` (its eventual successor) and before `check-auth/` (its dependency):
  ```
  - **`claude-command-router/`** — Verb router. Parses `@claude <verb>` comment bodies into `{overlay, status, mode}` outputs for downstream dispatch. Pure string logic — no containers. Delegates auth to `check-auth/`. The composite action wraps `lib/parse.sh` (a sourceable bash function) plus a JSON test corpus at `tests/cases.json` exercised by `.github/workflows/test.yml`. Caller workflow: `claude-tag-respond.yml` (Phase 5).
  ```
- [ ] **8.2** Do NOT add a deprecation note for `tag-claude/` — that's Phase 7 scope.
- [ ] **8.3** Commit. Message: `docs: note claude-command-router/ in Architecture table (refs #142)`.

### Task 12 — Spec amendment for `filler_words.txt` clarification

- [ ] **12.1** **Spec amendment (per Pass-1 H5 / Deviation #9):** edit `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §8.1.1 step 5. Currently reads:

  > The authoritative filler-word list lives in `claude-command-router/lib/filler_words.txt` (one word per line, lowercased). **The router loads this file at startup;** the JSON corpus in §10.3 validates that the known-verb scan respects the current list.

  Replace with:

  > The `claude-command-router/lib/filler_words.txt` file documents frequently-seen filler tokens for implementer reference and reviewer convenience (one word per line, lowercased). **The file is documentation-only — the router does NOT load it at startup.** The algorithm skips ALL non-verb tokens regardless of whether they appear in this file. The JSON corpus in §10.3 validates the skip-all-non-verb property by including cases for both file-listed words (e.g. `please`, `can`) and unlisted domain words (e.g. `triage`, `cook`).

- [ ] **12.2** **Spec amendment (Deviation #5 / Pass-1 OOS-1):** add a clarifying paragraph after the §8.1.1 examples table reconciling rows 8 (`apply`) vs 11 (`—`) vs 13 (`—`) for `mode`:

  > **`mode` field semantics.** `mode` is always emitted as `apply`, `read-only`, or `""` (empty). The default is `apply` for any non-malformed input, regardless of whether the verb resolved. `mode` is empty (`""`) only when the input is so malformed that no `@claude<whitespace>` mention was found at all (rows 13: bare `@claude`, 14: `@claude-review`). The example table's `—` cells in rows 11 (`@claude thanks!`, unknown_verb) and 13 (`@claude` bare) reflect this: row 11 `mode` = `apply` (default; non-malformed); row 13 `mode` = `""` (malformed).

  Cross-reference Issue #142 + Phase 4 plan Deviation #5.

- [ ] **12.3** Commit. Message: `docs: amend spec §8.1.1 — filler_words.txt is doc-only; mode default semantics (refs #142)`.

### Task 9 — Open PR + dry-run + Task 4.6 deliberate-flip test

- [ ] **9.1** Open PR against `main` from `phase-4-router`. Title: `Phase 4: claude-command-router/ + JSON test corpus (closes #142)`. **Body must include:**
  - Closing keyword `Closes #142` on its own line in plain text (CLAUDE.md "PRs" section).
  - Reference to spec §8.1–§8.3 and §10.3 as the source of the JSON corpus.
  - Reference to §13 Q9 deferral (keep `mode` for v1; rename to `commit_policy` deferred).
  - Test plan: dry-run results (test.yml green; deliberate-flip test).
  - Inquisitor pass status (1 pass complete; pass 2 conditional).

- [ ] **9.2** Open as **draft** so the bot review doesn't fire on every dry-run iteration. Mark ready after deliberate-flip test passes.

- [ ] **9.3** Wait for `test.yml` green on PR.

- [ ] **9.4** **Deliberate-flip test (Task 4.6 of master plan; Pass-1 M5 expansion):** edit TWO `expect` fields in TWO unrelated `cases.json` rows (e.g. flip `mode: apply` → `mode: read-only` in one row, and flip `status: ok` → `status: malformed` in another). Push. Confirm `test.yml` fails AND that BOTH case names appear in the failure output (validates accumulate-then-exit per Pass-1 H4 + M5; not just first-failure-short-circuit). Revert both edits; confirm green re-run.

- [ ] **9.5** Mark PR ready for review. Wait for dogfood `pr-review` workflow + `claude-pr-review/quality-gate` status. Address any Critical/MAJOR findings via `gh-pr-review-address` skill.

- [ ] **9.6** Final pre-merge ritual per `feedback_check_pr_feedback_before_merge.md`. Merge.

---

## Verification / Acceptance

Per Issue #142 acceptance criteria:

- [ ] `claude-command-router/action.yml` composite exists and is invokable via `uses: ./claude-command-router` — Task 6.
- [ ] `./claude-command-router/tests/run-cases.sh` passes on CI — Task 9.3.
- [ ] Every row of spec §8.1.1 + §10.3 has at least one JSON case (15+ minimum, target 17–20) — Task 4.
- [ ] §13 Q9 has a recorded decision (keep `mode` for v1) with a TODO pointer in `action.yml` — Task 6.5.
- [ ] `actionlint` passes on `test.yml` (info-severity included) — Task 7.4.
- [ ] No new runner dependencies introduced — Task 7.3.

Plus this plan's own acceptance:

- [ ] Pass 1 inquisitor complete with findings addressed.
- [ ] Deliberate-flip test demonstrates the runner detects mismatches — Task 9.4.
- [ ] Bot review approves with no Critical/MAJOR findings — Task 9.5.

---

## Inquisitor pass status

**Pass 1:** complete (2026-05-02). 14 actionable findings (3 C, 6 H, 5 M) + 3 OOS. Report at `phase-4-router-inquisitor-pass-1.md`. All 14 addressed inline (see "Pass 1 findings addressed" section near the top).

**Pass 2:** pending. Charge: find new gaps introduced by Pass 1's revisions. Specifically scrutinize:

- The multi-mention scan loop (Task 3.3 step e revision) — does the `body_remaining`/`first_match`/`tail` reassignment terminate correctly on all inputs? Are there infinite-loop traps?
- The single-step branching pattern in Task 6.4 — `id: parse` step that internally branches on auth. Does GHA correctly handle a step that exits 0 after writing partial outputs? What if `check-auth` fails (returns non-zero exit) — does the parse step still run?
- The `local -` flag scoping — does it actually preserve ALL set flags including `pipefail`? Bash 5.2's `local -` documentation should be cross-checked.
- The 24+ corpus cases — do any of them mutually contradict on the spec ambiguity? If two cases expect different outputs for "the same kind of input," at least one is wrong.
- The `# TODO: §13 Q9` YAML comment placement — does YAML allow comments inside the `outputs:` block, or only at top level?
- The `${{ github.action_path }}/lib/parse.sh` source path — does this resolve correctly when the action is invoked from outside its own repo (e.g., a caller workflow that checks out a consumer's repo first)? Spec §8.2 says the router is internal-only, but the path resolution should still be correct.
- Spec amendments (Task 12) — do the new §8.1.1 step 5 wording and the new "mode field semantics" paragraph mutually agree, or do they introduce a new conflict?

Pass 2 should converge if the answers are clean; otherwise queue Pass 3.
