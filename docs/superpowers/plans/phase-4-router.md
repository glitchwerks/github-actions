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

## Inquisitor passes (gate Tasks 4+)

Per `feedback_inquisitor_twice_for_large_design.md`: this is **not** a large-design plan. Phase 4's surface is small (one composite action + one bash function + one JSON corpus + one test workflow). The architectural decisions are committed in spec §8 and master plan §Phase 4 — including the §13 Q9 `mode` naming decision (keep `apply | read-only` for v1; rename to `commit_policy` deferred until a second orthogonal flag arrives). One inquisitor pass against the plan is sufficient; pass 2 is conditional on pass 1 introducing new mechanisms with their own failure modes.

- **Pass 1:** runs after this plan is committed; resolves architectural gaps before any code.
- **Pass 2:** conditional; only if pass 1 introduces mechanisms whose failure modes are unchecked (the Phase 2/3 pattern). For string-parsing logic this is unlikely.

**Hard checkpoint:** Tasks 1–7 do not begin until Pass 1 findings are addressed in this file.

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

- [ ] **3.1** Author `parse.sh` exposing a single function `parse_comment()`. Header: `set -uo pipefail` (NOT `-e`; we want the function to return non-zero codes the caller can read, not abort the shell). Treat the script as sourceable: `source parse.sh; parse_comment "<comment-body>"`.
- [ ] **3.2** Function signature: `parse_comment <comment-body>` reads positional arg 1 (the body), echoes pipe-delimited `<overlay>|<status>|<mode>` to stdout, returns 0 always. The status field is the source of truth for "did parsing succeed"; the function never returns non-zero (the caller reads the tuple, not the exit code).
- [ ] **3.3** Algorithm (per spec §8.1.1):
  1. Locate the first occurrence of `@claude` followed by at least one whitespace character (case-insensitive). Use a bash regex: `[[ "$body" =~ (^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]] ]]` to anchor on word boundary; fall back to a simpler `grep -iE` if regex is too brittle. **Decision:** use `awk` for stable cross-platform regex behavior — bash's `[[ =~ ]]` ERE differs subtly between versions. `awk 'match(...)'` is portable and emits the offset reliably.
  2. If no match: emit `||malformed|`. Wait — that's 3 fields with the wrong delimiter count. Correct shape: `overlay|status|mode` → empty fields are still empty strings between pipes. Emit `||malformed||` — wait, that's 4 pipes. Actually: 3 fields → 2 pipes → `<overlay>|<status>|<mode>` → empty becomes `||malformed||` — no, it's `<empty>|malformed|<empty>` = `|malformed|`. Three fields, two delimiters. Use `printf '%s|%s|%s\n' "$overlay" "$status" "$mode"` to be unambiguous. **Use printf, not echo.**
  3. After locating the `@claude<whitespace>` boundary, capture the substring from that position to the NEXT `@claude<whitespace>` boundary or end of body. Tokenize on whitespace (`read -ra tokens <<< "$tail"`).
  4. Scan tokens left-to-right. Lowercase each (`token_lc="${token,,}"`). Compare to verb allowlist `{review, fix, explain}`. First match wins → set `overlay=$token_lc`, `status=ok`, advance to step 5. If scan exhausts without match → `printf '|unknown_verb|apply\n'` and return 0.
  5. After verb resolution, continue scanning remaining tokens in the SAME `@claude` mention. If any token equals `--read-only` literally (case-sensitive — flags are conventionally lowercase) AND `overlay=fix`, set `mode=read-only`. Otherwise `mode=apply`.
  6. Emit `printf '%s|%s|%s\n' "$overlay" ok "$mode"`.
- [ ] **3.4** Edge cases the implementation MUST handle (cross-reference spec §8.1.1 rows + Deviation #6, #7):
  - Bare `@claude` (no tokens after) → `||malformed|` (empty overlay, malformed status, empty mode). Per row 13.
  - `@claude-review` (no whitespace) → `||malformed|`. Per row 14.
  - `@claude<TAB>review` (tab as whitespace) → matches; resolves to `review`.
  - `@claude   review` (multiple spaces) → matches; whitespace collapsed by `read -ra`.
  - `@claude please review and also @claude fix` → first mention wins, scan tokens of first mention only; resolves to `review`. Per row 12.
  - `@claude review --read-only` → `review|ok|apply` (flag ignored for non-fix). Per row 7.
  - `@claude review and also fix` → `review|ok|apply` (first-verb-wins; `fix` not parsed). Per row 11.
- [ ] **3.5** Add a top-of-file comment block documenting: (a) the function signature; (b) output format (pipe-delimited); (c) cross-references to spec §8.1.1 + §10.3; (d) auth is NOT this script's job — `action.yml` handles it; (e) this script is sourceable for the test runner.
- [ ] **3.6** Commit. Message: `feat(router): parse.sh — pure verb-scanning function per §8.1.1 (refs #142)`.

### Task 4 — Author `claude-command-router/tests/cases.json`

- [ ] **4.1** Translate every row of spec §8.1.1 examples table (14 rows) into a JSON case. Each: `{name: "<short>", input: "<verbatim>", expect: {overlay, status, mode}}`. Use the row's verbatim input string. Resolve "—" cells to `""`.
- [ ] **4.2** Translate every entry of §10.3 minimum-coverage list (10 entries) that isn't already covered by step 4.1. After dedup, expect ~3–6 additional cases.
- [ ] **4.3** Add at least 2 cases that aren't in either source but stress-test the parser:
  - `@claude REVIEW THIS PLEASE` (uppercase verb) → `review|ok|apply` (case-insensitive).
  - `@claude\treview` (tab delimiter) → `review|ok|apply` (whitespace tolerance).
- [ ] **4.4** Verify the corpus is well-formed JSON (`jq . cases.json >/dev/null`). Each case has the three top-level keys + the three `expect` keys. No trailing commas, no shell-style comments. Use `// ` between cases by adding `name` keys that double as comments.
- [ ] **4.5** Commit. Message: `feat(router): cases.json — JSON test corpus from §8.1.1 + §10.3 (refs #142)`.

### Task 5 — Author `claude-command-router/tests/run-cases.sh`

- [ ] **5.1** Author the runner: pure bash + jq. Header: `set -uo pipefail`.
- [ ] **5.2** Behavior:
  1. Resolve repo root via `$(git rev-parse --show-toplevel)` (with a fallback to `dirname`-walking from the script's location for non-git execution contexts like a future container).
  2. Source `parse.sh` (`source "$REPO_ROOT/claude-command-router/lib/parse.sh"`).
  3. Read `cases.json`. Iterate via `jq -c '.[]'` (one case per line as compact JSON). For each case:
     - Extract `name`, `input`, `expect.overlay`, `expect.status`, `expect.mode` via `jq -r`.
     - Invoke `parse_comment "$input"` and capture stdout into `actual`.
     - Split `actual` on pipe: `IFS='|' read -r got_overlay got_status got_mode <<< "$actual"`.
     - Compare each field to expected. If any mismatch: print `FAIL: <name>` followed by `  expected overlay=<x> status=<y> mode=<z>; got overlay=<a> status=<b> mode=<c>`.
  4. Track pass/fail counts. After iteration: print `summary: <pass>/<total> passed`. Exit 1 if any fail; exit 0 otherwise.
- [ ] **5.3** Defensive checks before iteration:
  - Assert `command -v jq >/dev/null` (it is on `ubuntu-latest`; explicit check makes errors readable).
  - Assert `cases.json` exists, parses as JSON (`jq . >/dev/null`), and has at least 15 cases (`length >= 15`). Fail with descriptive message if not.
- [ ] **5.4** Commit. Message: `feat(router): run-cases.sh — bash+jq corpus runner (refs #142)`.

### Task 6 — Author `claude-command-router/action.yml`

- [ ] **6.1** Top-level: `name: 'Claude Command Router'`, `description: 'Parse @claude verb invocations into {overlay, status, mode} for downstream dispatch'`.
- [ ] **6.2** Inputs: `comment_body` (string, required, no default), `authorized_users` (string, optional, default `''`).
- [ ] **6.3** Outputs (per spec §8.1):
  ```yaml
  outputs:
    overlay:
      description: "Resolved overlay name: review | fix | explain | '' (empty when not resolved)"
      value: ${{ steps.parse.outputs.overlay }}
    status:
      description: "Parse status: ok | unknown_verb | malformed | unauthorized"
      value: ${{ steps.parse.outputs.status }}
    mode:
      description: "Commit policy: apply | read-only | '' (empty when input is malformed)"
      value: ${{ steps.parse.outputs.mode }}
  ```
- [ ] **6.4** Steps:
  1. **Authorization** — `uses: ./check-auth` with `authorized_users: ${{ inputs.authorized_users }}`. Capture its `authorized` output.
  2. **Set unauthorized status (early-exit semantics)** — `if: steps.authz.outputs.authorized != 'true'`, run a step that writes `overlay=`, `status=unauthorized`, `mode=` to `$GITHUB_OUTPUT` and skips the parse step.
  3. **Parse** — `if: steps.authz.outputs.authorized == 'true'`, run a `bash` step that sources `parse.sh`, calls `parse_comment "${{ inputs.comment_body }}"`, splits the pipe-delimited output on `|`, and writes each field to `$GITHUB_OUTPUT`. Use `id: parse` so the outputs at the top of the file resolve.
- [ ] **6.5** Add a `# TODO: §13 Q9` comment near the `mode` output declaration referencing the rename-to-`commit_policy` deferral (per master plan task 4.3).
- [ ] **6.6** **shellcheck SC2086 / SC2046** — when piping `${{ inputs.comment_body }}` into `parse_comment`, quote it. Comment bodies can contain shell metacharacters (backticks, `$VAR`, etc.). The `bash` step should pass the body via env var:
  ```yaml
  - id: parse
    shell: bash
    env:
      COMMENT_BODY: ${{ inputs.comment_body }}
    run: |
      set -uo pipefail
      source "${{ github.action_path }}/lib/parse.sh"
      tuple=$(parse_comment "$COMMENT_BODY")
      IFS='|' read -r overlay status mode <<< "$tuple"
      {
        echo "overlay=$overlay"
        echo "status=$status"
        echo "mode=$mode"
      } >> "$GITHUB_OUTPUT"
  ```
  Using `env:` instead of inline expansion prevents GHA template injection: a comment containing `$(rm -rf $HOME)` would be expanded by the shell parser if interpolated directly. The env-var path isolates the body from any shell parsing.
- [ ] **6.7** Commit. Message: `feat(router): action.yml — composite action wiring auth + parse (refs #142)`.

### Task 7 — Author `.github/workflows/test.yml`

- [ ] **7.1** Single job: `name: tests`, `runs-on: ubuntu-latest`, timeout 5m.
- [ ] **7.2** Triggers: `pull_request` (on any path) + `push: branches: [main]`. Path filters intentionally absent — the test corpus is small (~17 cases × <1ms each = <1s wall clock); always running it is cheaper than maintaining the path filter.
- [ ] **7.3** Steps:
  - `uses: actions/checkout@v5` (depth 1 sufficient).
  - `name: Run router tests`, `run: bash ./claude-command-router/tests/run-cases.sh`. No env, no installs.
- [ ] **7.4** Verify locally with `actionlint -shellcheck="-S info" .github/workflows/test.yml` before push.
- [ ] **7.5** Commit. Message: `ci(router): test.yml — runs run-cases.sh on every PR (refs #142)`.

### Task 8 — Update `CLAUDE.md` Architecture table

- [ ] **8.1** Add a row to the `### Actions` list under `## Architecture`:
  ```
  - **`claude-command-router/`** — Verb router. Parses `@claude <verb>` comment bodies into `{overlay, status, mode}` outputs for downstream dispatch. Pure string logic (no containers). Delegates auth to `check-auth/`. Caller workflow: `claude-tag-respond.yml` (Phase 5).
  ```
  Insert after `apply-fix/` and before `lint-failure/` to keep alphabetic-ish ordering.
- [ ] **8.2** Do NOT add a deprecation note for `tag-claude/` — that's Phase 7 scope.
- [ ] **8.3** Commit. Message: `docs: note claude-command-router/ in Architecture table (refs #142)`.

### Task 9 — Open PR + dry-run + Task 4.6 deliberate-flip test

- [ ] **9.1** Open PR against `main` from `phase-4-router`. Title: `Phase 4: claude-command-router/ + JSON test corpus (closes #142)`. **Body must include:**
  - Closing keyword `Closes #142` on its own line in plain text (CLAUDE.md "PRs" section).
  - Reference to spec §8.1–§8.3 and §10.3 as the source of the JSON corpus.
  - Reference to §13 Q9 deferral (keep `mode` for v1; rename to `commit_policy` deferred).
  - Test plan: dry-run results (test.yml green; deliberate-flip test).
  - Inquisitor pass status (1 pass complete; pass 2 conditional).

- [ ] **9.2** Open as **draft** so the bot review doesn't fire on every dry-run iteration. Mark ready after deliberate-flip test passes.

- [ ] **9.3** Wait for `test.yml` green on PR.

- [ ] **9.4** **Deliberate-flip test (Task 4.6 of master plan):** edit ONE `expect` field in `cases.json` (e.g. flip `mode: apply` → `mode: read-only` in a row that should produce `apply`). Push. Confirm `test.yml` fails with the expected mismatch error line for that case name. Revert the edit; confirm green re-run.

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

## Inquisitor mandate (Pass 1)

Charge: read the plan as a hostile adversary who wants to find ways the parser silently passes when it shouldn't, ways the corpus has gaps, and ways the action.yml interpolation introduces injection vectors. Specifically check:

1. **Injection in `inputs.comment_body`.** A user posts `@claude review $(rm -rf /)` as a PR comment. Does any path expand the body before the parser sees it? Does the env-var pass-through in Task 6.6 actually isolate the body, or do ${{ }} expressions in the YAML still expand?
2. **`@claude` regex anchoring.** Does the parser correctly reject `email@claude.example.com` as a non-mention? What about `prefix@claude review` (no space before)?
3. **`--read-only` flag scoping.** Does the flag scan terminate at the next `@claude` mention? What about `@claude fix\n@claude\n--read-only` (newline-separated, second mention has the flag)?
4. **First-verb-wins** — does the algorithm correctly handle `@claude review-thoroughly` (verb-like prefix, not in allowlist)? Should treat as a non-verb token, NOT split-and-resolve.
5. **JSON corpus `expect` shape.** Are empty strings (`""`) used consistently for unresolved fields? Does the runner's jq extraction handle empty strings the same way as missing keys?
6. **`run-cases.sh` exit code.** If the runner exits 1 on the first failure, subsequent cases aren't tested. Does the plan's iteration accumulate ALL failures before exiting (analog of Phase 3's matcher)? The plan should specify accumulate-then-exit, not short-circuit.
7. **`parse.sh` sourceable contract.** If the test runner sources parse.sh and parse.sh has `set -uo pipefail` at file scope, those flags pollute the calling shell. Should `parse.sh` be a function that sets flags only inside the function body (`local -`), or document that callers must save/restore?
8. **`mode` empty-vs-`apply` semantics** — Deviation #5 calls out the spec table inconsistency. Is the chosen interpretation (default `apply` always, empty only on truly malformed) defensible? Pass 1 should sanity-check or push back.
9. **CLAUDE.md ordering** — Task 8.1 says insert "after apply-fix/ and before lint-failure/". Is that actually alphabetic? `apply-fix < check-auth < claude-command-router < lint-failure < pr-review < tag-claude`. Yes. Confirm.
10. **`./check-auth` relative path** — works because `actions/checkout@v5` checks out the same repo. Document that `claude-command-router/` MUST live in the same repo as `check-auth/` for the relative path to resolve. External consumers don't reference the router directly (Phase 5's caller workflow handles that).

After Pass 1 findings are addressed in this file, this plan is greenlit for execution. If pass 1 surfaces architectural mechanisms with their own untested failure modes, queue Pass 2; otherwise proceed.
