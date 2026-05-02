# Phase 4 Router — Inquisitor Pass 1

**Reviewer:** inquisitor (adversarial)
**Subject:** `docs/superpowers/plans/phase-4-router.md`
**Date:** 2026-05-02
**Verdict (TL;DR):** Not ready. **3 Critical**, **6 High-Priority**, **5 Medium**, **3 OOS** findings. Pass 2 is warranted. The plan has the right shape but the algorithm pseudocode (Task 3.3) is a thinking-out-loud draft that contradicts itself, the auth wiring (Task 6.4) does not match the existing `check-auth/action.yml` outputs contract, and the env-var injection guard (Task 6.6) is incomplete — `${{ inputs.comment_body }}` still expands as a YAML-template expression before the env value is bound. Multiple corpus and runner gaps would let the parser silently pass on inputs that should fail.

---

## Critical

---

**CHARGE C1: Task 6.4 step 1 calls `./check-auth` without `id:` — `steps.authz.outputs.authorized` is unreachable.**

**The problem:** Step 1 of Task 6.4 reads `uses: ./check-auth with: authorized_users: ...`. There is no `id: authz` anywhere in the spelled-out steps, but every subsequent step gates on `if: steps.authz.outputs.authorized != 'true'` / `== 'true'`. Without `id:` on the auth step, the expression is permanently empty-string and **both** the unauthorized branch and the parse branch will skip — output keys never get written, and the composite action emits empty strings for `overlay`, `status`, `mode` no matter what the comment said.

Symmetric issue: Task 6.4 step 3 says "Use `id: parse` so the outputs at the top of the file resolve" — good — but step 2 ("Set unauthorized status") has no `id:` named either, and crucially must write to `$GITHUB_OUTPUT` keyed under the **same step** that the top-level `outputs:` block resolves from. The plan as written has THREE steps writing to `$GITHUB_OUTPUT`: the auth step (no), the unauthorized branch (no id), and the parse step (`id: parse`). The top-level outputs block resolves only `steps.parse.outputs.*`. When the unauthorized branch writes `status=unauthorized` to its own step's `$GITHUB_OUTPUT`, the top-level `outputs.status` (which resolves `steps.parse.outputs.status`) sees nothing — because the parse step was skipped by `if:`.

**Why it matters:** The router silently emits `status=""` (not `unauthorized`) when an unauthorized user comments. The downstream `dispatch` job's `if: needs.route.outputs.status == 'ok'` correctly rejects empty-string, so the right thing happens by accident — but the documented `status=unauthorized` contract is never honored, and any consumer that branches on `status == 'unauthorized'` (e.g. to post a polite rejection) will not fire. Spec §8.3 explicitly lists "unauthorized caller → polite rejection" as part of the error surface.

**The question that must be answered:** Either (a) put `id: authz` on the check-auth step AND have the unauthorized branch and the parse branch share `id: parse` (one writes the unauthorized tuple, the other writes the parsed tuple, mutually exclusive via `if:`), or (b) drop the unauthorized step entirely and have the parse step itself early-return when `steps.authz.outputs.authorized != 'true'` by writing the unauthorized tuple inside the same shell step. The plan must specify which.

---

**CHARGE C2: `${{ inputs.comment_body }}` in the `env:` block still undergoes YAML-template expansion — the env-var pass-through is not the injection guard the plan claims it is.**

**The problem:** Task 6.6 reads `env: COMMENT_BODY: ${{ inputs.comment_body }}` and asserts that "Using env: instead of inline expansion prevents GHA template injection." This is **half-correct**. The `env:` form does isolate the value from **shell parsing** — the bash interpreter sees `$COMMENT_BODY` as a literal string, so `$(rm -rf /)` inside the body never reaches `eval`. But the `${{ }}` substitution is still YAML-template-level: GitHub Actions expands `${{ inputs.comment_body }}` BEFORE the YAML is fed to the runner. If the comment body contains the literal four-character sequence `${{`...`}}` (which a malicious commenter can post), GHA does NOT recursively expand the substituted content — but it DOES embed the body verbatim into the YAML at expansion time, which means a body containing `\n      run: rm -rf /` could break out of the env-string context if the GHA YAML emitter does not properly quote.

GitHub's runner does correctly quote `${{ }}` substitutions for `env:` values (single-line scalar quoting), but the plan does not state this is being relied on, nor does it cite the relevant docs. The actual safe pattern (used by every battle-tested action) is: pass the body via `env:` AND add an explicit shellcheck-justified comment AND verify with a known-hostile fixture in the corpus (see C3 below).

Critically, the existing `check-auth/action.yml` (lines 26-29) interpolates `${{ github.event.comment.user.login }}` into shell **directly** — not via `env:`. The router is invoking this action. If a commenter sets their **GitHub username** to something containing shell metacharacters (which GitHub actually rejects, but `author_association` is also interpolated and is enum-valued), the existing action's pattern is the at-risk one — not the new router's. The plan does not call this out.

**Why it matters:** The plan promotes a security-affecting pattern as proven safe without proving it. A reviewer who reads "the env-var path isolates the body from any shell parsing" will believe injection is impossible and skip the corpus case. The corpus must include a row with literal `$(date)`, ``backticks``, `\n`, `${{ secrets.X }}`, and a literal `'; rm -rf /; '` to demonstrate end-to-end safety — see C3.

**The question that must be answered:** Cite the GHA docs section that guarantees `env:` value substitution is YAML-string-safe for arbitrary user content. Add a corpus case with a known-hostile body containing `$(date)`, backticks, `${{ }}` literal, and `; rm -rf /` — assert the parser returns `unknown_verb` and the action emits the expected output (no shell execution side effects). If the assertion is only "no runtime error," that is not enough.

---

**CHARGE C3: The corpus has zero cases for shell metacharacters, multi-line bodies, or literal `|` in the input — the runner's `IFS='|' read` will silently mis-tokenize.**

**The problem:** Task 5.2.3 (run-cases.sh) extracts `input` via `jq -r '.input'`, passes it to `parse_comment "$input"`, and parses output with `IFS='|' read -r got_overlay got_status got_mode <<< "$actual"`. There are TWO independent failure modes here that no listed corpus row exercises:

1. **Pipe in the body.** If a comment body contains a literal `|` character (legitimate: `@claude review the foo|bar branch`), `parse_comment` echoes `review|ok|apply` — but if the parser somehow let the body content into the output (e.g. an off-by-one in the substring extraction echoes the tail), the `IFS='|'` split mis-tokenizes silently. The plan's algorithm SHOULD only emit overlay+status+mode and never echo the body, but the corpus does not assert this defensively.

2. **Newlines in the body.** Spec §8.1.1 row 12 says `@claude review and also @claude fix` → first wins. But what about `@claude review\n@claude fix` (newline-separated)? The plan's regex at Task 3.3 step 1 — `[[ =~ (^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]] ]]` — uses `[[:space:]]`, which matches `\n` and `\t`. But the "scan tokens left-to-right" step 4 says `read -ra tokens <<< "$tail"`, and bash's `read -ra` with default IFS splits on space/tab/newline — so multi-line bodies tokenize correctly. However, `cases.json` has NO multi-line case, and the inquisitor-mandate item #3 explicitly raises `@claude fix\n@claude\n--read-only`. The plan acknowledges this in mandate #3 but does not add a corpus row for it.

   A subtler issue: `jq -r` preserves newlines in the extracted string, but a bash heredoc round-trip via `<<<` preserves newlines too. If the implementer instead does `actual=$(echo "$input" | parse_comment_via_stdin)`, command substitution strips trailing newlines but preserves internal — different behavior. The plan does not pin which.

3. **`@claude review --read-only` in a code fence.** A real-world body: ``Hi @claude, please run `@claude fix --read-only` against...`` — the inner ``@claude fix --read-only`` is inside a backtick-delimited code span. The parser doesn't (and shouldn't) understand markdown, so it should match the FIRST `@claude<space>` and resolve to the verb after it. With the example body, the first `@claude` is followed by `,` (not whitespace), so the regex requires the NEXT `@claude` mention. But `@claude<space>fix` inside backticks will then be parsed as verb=fix. Is that intended? The spec is silent. **Whatever the chosen behavior, a corpus case must pin it.**

**Why it matters:** The corpus is the executable spec. If it lacks adversarial cases, the parser will pass review while still being broken on common inputs — a body containing a pipe, a newline, or `@claude` inside backticks is not exotic. The plan claims (Deviation #1) "17–20 cases" with "higher coverage of edge cases" but the listed extras are uppercase verb + tab delimiter — neither of which exercises the harder cases.

**The question that must be answered:** Add at minimum these corpus rows: (a) body with literal `|` in a non-verb token; (b) body with `\n` between two `@claude` mentions; (c) body with `${{ secrets.X }}` literal; (d) body with backticks around an `@claude` mention; (e) body containing `$(rm -rf /)`. For each, document the expected `{overlay, status, mode}` and add a comment in the JSON `name` explaining the rationale.

---

## High-Priority

---

**CHARGE H1: Task 3.3 algorithm is internally inconsistent — the plan equivocates between bash regex and awk and never picks one.**

**The problem:** Task 3.3 step 1 reads:

> Use a bash regex: `[[ "$body" =~ (^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]] ]]` to anchor on word boundary; fall back to a simpler `grep -iE` if regex is too brittle. **Decision:** use `awk` for stable cross-platform regex behavior — bash's `[[ =~ ]]` ERE differs subtly between versions. `awk 'match(...)'` is portable and emits the offset reliably.

Three different regex engines named in three sentences, with "Decision: use awk" as a footnote. The rest of the algorithm (step 3: "Tokenize on whitespace `read -ra tokens <<< \"$tail\"`"; step 4: bash-native `${token,,}` lowercasing) is bash-specific and incompatible with an awk-based locator.

If the locator is bash regex, the version-skew concern is real (bash 5.0 vs 5.2 ERE differences exist) but the regex shown is simple enough to be portable — the `[[:space:]]` and `[^A-Za-z0-9]` classes are stable. If the locator is awk, the algorithm needs a clear awk script that emits the offset, then bash extracts the tail substring — the plan does not show this. If the locator is `grep -iE`, the offset is harder to recover (grep emits matching lines, not byte offsets).

**Why it matters:** The implementer reading this plan will guess. Different guesses produce different behaviors at the edges (e.g., awk's POSIX ERE vs bash's [[ =~ ]] BRE-or-ERE-depending-on-LC_ALL handle `[^A-Za-z0-9]` near non-ASCII identically, but Unicode word-character handling differs). The plan should commit to ONE engine and show the actual command.

**The question that must be answered:** Pick one. If bash regex: assert the minimum bash version (`ubuntu-latest` ships 5.2.x) and remove the awk hedge. If awk: replace step 1 with the actual awk invocation and show how the tail is extracted in bash.

---

**CHARGE H2: Task 3.3 step 2 is a stream-of-consciousness draft — the plan never says what `parse_comment` actually emits for the malformed case.**

**The problem:** Step 2 reads:

> If no match: emit `||malformed|`. Wait — that's 3 fields with the wrong delimiter count. Correct shape: `overlay|status|mode` → empty fields are still empty strings between pipes. Emit `||malformed||` — wait, that's 4 pipes. Actually: 3 fields → 2 pipes → `<overlay>|<status>|<mode>` → empty becomes `||malformed||` — no, it's `<empty>|malformed|<empty>` = `|malformed|`. Three fields, two delimiters. Use `printf '%s|%s|%s\n' "$overlay" "$status" "$mode"` to be unambiguous.

This is a draft document, not a plan. A code-writer agent reading this will either (a) be confused, (b) implement one of the wrong intermediate forms ("||malformed|" or "||malformed||"), or (c) pick the printf form by inference. Step 4 then says `printf '|unknown_verb|apply\n'` — which is consistent with the resolved 3-field 2-delimiter shape but contradicts step 2's earlier "||malformed|" attempts.

`run-cases.sh` (Task 5.2.3) does `IFS='|' read -r got_overlay got_status got_mode <<< "$actual"`. With input `|malformed|` the read produces `got_overlay=""`, `got_status="malformed"`, `got_mode=""`. With input `||malformed||` the read produces `got_overlay=""`, `got_status=""`, `got_mode="malformed"` — completely wrong. **The plan as written is one transcription error away from a corpus that all passes against a parser that emits the wrong tuple.**

**Why it matters:** Production code depends on a wire-format specification, not a discussion of what the wire format might be. The plan should state the wire format once, in pseudocode, with no scratch work.

**The question that must be answered:** Replace step 2 with a clean pseudocode block: "Emit `printf '%s|%s|%s\n' \"$overlay\" \"$status\" \"$mode\"` always, where unset fields are empty strings." Delete the working-out-loud paragraph.

---

**CHARGE H3: `parse.sh` having `set -uo pipefail` at file scope pollutes the test runner's shell.**

**The problem:** Task 3.1 says `parse.sh` starts with `set -uo pipefail` — and this is a **sourceable** script, sourced by `run-cases.sh` (Task 5.2.2). When you `source` a script, its `set` commands modify the calling shell's options. `run-cases.sh` (Task 5.1) ALSO has `set -uo pipefail` — fine, same flags — but a future caller that sources `parse.sh` for one-off use (a debugger, an interactive shell, a CI workflow that uses different flag conventions) will silently have `nounset` and `pipefail` flipped on. Mandate item #7 raises this.

Worse: `set -u` (nounset) inside `parse_comment` will abort on any reference to an unset variable. The function parses user input — a programmer error during development that references an unset variable will crash silently in CI with no useful diagnostic, because the function "returns 0 always" (Task 3.2) is contradicted by `set -u` causing immediate exit.

**Why it matters:** Sourceable scripts that mutate shell options are a well-known footgun. The plan acknowledges the issue in mandate #7 but does not commit to a remediation.

**The question that must be answered:** Either (a) move `set -uo pipefail` INSIDE the function body using `local -` (bash 4.4+, available on `ubuntu-latest`) — `local -` saves and restores all `set` flags scoped to the function — and document it in the file header; or (b) remove `set -u` entirely and use defensive `${VAR:-}` everywhere; or (c) explicitly document "this script must be sourced only inside scripts that already have `set -uo pipefail`." Option (a) is correct.

---

**CHARGE H4: `run-cases.sh` exit code is short-circuit, not accumulate-then-exit — first failure hides the rest.**

**The problem:** Task 5.2 step 4 says "Track pass/fail counts. After iteration: print `summary: <pass>/<total> passed`. Exit 1 if any fail; exit 0 otherwise." This is correct (accumulate-then-exit). But Task 5.1 declares `set -uo pipefail`, and the per-case logic in step 4 does **not** wrap `parse_comment` in a way that survives a non-zero return — `parse_comment` is documented as "returns 0 always" (Task 3.2), but if `set -u` triggers inside parse.sh (per H3), the entire script aborts on the first case that hits the bug. With pipefail off in the heredoc, the IFS read is safe, but mandate item #6 specifically asks "does the runner accumulate ALL failures before exiting" — the answer is "yes if parse.sh behaves, no otherwise."

**Why it matters:** The plan's Phase 3 had a near-identical issue with `if cmd; then; fi; rc=$?` exit-code capture (cited in the inquisitor mandate preamble). The plan did not learn from that — Task 5.2 does not include a defensive `actual=$(parse_comment "$input" || true)` or `actual=$(parse_comment "$input")` followed by an explicit `rc=$?` check.

**The question that must be answered:** Specify the exact invocation. Recommended: `actual=$(parse_comment "$input"); rc=$?` so a non-zero parse_comment exit becomes a test failure (printed as `FAIL: <name> — parse_comment exited rc=$rc`), not a runner abort.

---

**CHARGE H5: Filler-words file is documentation-only in the plan but the spec says it is loaded at startup — pick one.**

**The problem:** Plan Deviation note "**Architecture**" line 11 says `filler_words.txt` is "documentation-only wordlist (per spec §8.1.1). The algorithm skips ALL non-verb tokens; the file documents 'frequently seen' filler words for implementer reference."

Spec §8.1.1 step 5 reads: "The authoritative filler-word list lives in `claude-command-router/lib/filler_words.txt` (one word per line, lowercased). **The router loads this file at startup;** the JSON corpus in §10.3 validates that the known-verb scan respects the current list."

These contradict. If the router loads the file, the file is load-bearing — adding/removing a word changes parser behavior. If the algorithm skips ALL non-verb tokens regardless, the file is documentation. The spec opts for "load at startup AND skip all non-verb tokens" — the file is documented but not gating, but the parser still reads it (presumably to validate or echo as part of debug logging).

**Why it matters:** A corpus case for a word in the file vs not in the file should produce identical output if the algorithm skips all non-verb tokens. But spec §8.1.1 says "the JSON corpus in §10.3 validates that the known-verb scan respects the current list" — implying corpus cases ARE keyed on filler words. If the implementer writes the documentation-only version, the spec's validation claim is hollow. If they write the load-at-startup version, the plan does not specify when/how, and a malformed `filler_words.txt` will break parsing.

**The question that must be answered:** Either update the plan to match the spec (parse.sh loads `filler_words.txt` and uses it as a denylist or whitelist) and specify exactly how, OR update the spec to admit the file is documentation-only and remove the "loads this file at startup" claim. The plan cannot ship in its current state because the spec is the contract.

---

**CHARGE H6: `--read-only` flag scan termination is described in spec but not implemented in plan algorithm.**

**The problem:** Spec §8.1.1 step 9 reads: "Scan terminates at the next `@claude` mention or end of comment." The plan's Task 3.3 step 5 reads: "After verb resolution, continue scanning remaining tokens in the SAME `@claude` mention. If any token equals `--read-only` literally..." — but step 3 says the tail substring is captured "from that position to the NEXT `@claude<whitespace>` boundary or end of body." So the tail is already truncated at the next mention before tokenization — good.

However: spec §8.1.1 row 12 example is `@claude review and also @claude fix` → first wins (review). The flag-scan question is, given `@claude fix and also @claude --read-only` (flag in the SECOND mention), does `mode=apply` (correct, flag is in second mention which is ignored)? The plan handles this correctly via the truncation. But mandate item #3 raises `@claude fix\n@claude\n--read-only` — newline-separated. Does the regex `(^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]]` find the second `@claude\n`? Yes, `[[:space:]]` matches `\n`. Does the truncation correctly stop the first-mention's tail BEFORE the second `@claude`? The plan never specifies how the truncation finds "the NEXT `@claude<whitespace>`" — it would need to re-run the regex on the tail, or use awk's split-by-pattern. **The algorithm is silent on this and no corpus row exercises it.**

**Why it matters:** The spec says the flag scan terminates at the next `@claude`; the plan's algorithm relies on a tail-truncation step that is not spelled out. A naive implementation that does `tail="${body#*@[Cc][Ll][Aa][Uu][Dd][Ee] }"` (strip up to first `@claude<space>`) and then tokenizes the rest does NOT truncate at the second `@claude` — it tokenizes the entire remainder, and `@claude` appears as a token (no whitespace after it before `--read-only`). The first-verb-wins property still works for verb resolution (first known verb wins regardless), but the flag scan would see `--read-only` from the second mention and incorrectly emit `mode=read-only` for `overlay=fix`.

**The question that must be answered:** Show the exact bash code that extracts the first-mention tail. Add a corpus row for `@claude fix\n@claude --read-only` with expected `mode=apply`.

---

## Medium

---

**CHARGE M1: `@claude review-thoroughly` — the algorithm does not specify how a token containing a verb prefix is handled.**

**The problem:** Mandate item #4 raises `@claude review-thoroughly` (verb-like prefix, not in allowlist). The plan's Task 3.3 step 4 says "Compare to verb allowlist `{review, fix, explain}`. First match wins." Token comparison is exact-match after lowercasing — `review-thoroughly` is not in the allowlist, so it is skipped. Scan continues; if no other verb appears, `status=unknown_verb`. This is correct, BUT no corpus case asserts it, and a naive implementer might do `[[ "$token" == review* ]]` (prefix match) and silently match. Add a corpus row.

**The question that must be answered:** Add `@claude review-thoroughly` (no other tokens) → `status=unknown_verb` and `@claude review-thoroughly the changes` → also `unknown_verb` (no exact-match verb).

---

**CHARGE M2: The `email@claude.example.com` non-mention case is asserted in the regex but never tested.**

**The problem:** Mandate item #2 raises `email@claude.example.com` and `prefix@claude review` (no space before). The regex `(^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]]` correctly requires the char before `@` to be start-of-string or non-alphanumeric, so `email@claude.example.com` does not match (the `.` after `claude` is not whitespace, and the char before `@` is `l` — alphanumeric — so the leading anchor also fails). `prefix@claude review` similarly fails (the `x` before `@` is alphanumeric). Good.

But neither case is in the corpus. A future regex tweak could break this without any test catching it.

**The question that must be answered:** Add corpus rows: `email@claude.example.com please review` → `status=malformed` (no valid mention found); `prefix@claude review` → `status=malformed`.

---

**CHARGE M3: No JSON Schema for `cases.json` — typos in field names will silently pass.**

**The problem:** `cases.json` is hand-authored. A typo like `expect.statuss: "ok"` instead of `expect.status: "ok"` will be extracted as empty by `jq -r '.expect.status'` (jq returns `null` for missing keys, which `-r` renders as the string `"null"` — actually a different bug, see M4). The runner then compares `null` to whatever the parser produced — a mismatch, surfacing the typo as a real test failure. So this case is self-correcting.

But: a typo that produces a valid-but-wrong shape — e.g. `expect: { overlay: "review", status: "ok" }` (missing `mode`) — produces `null` for `mode`, `parse_comment` produces `apply`, and the test reports a mismatch attributed to the parser, not the corpus. The implementer "fixes" the parser to emit empty mode, breaking other cases. A schema check at runner startup (`jq` has limited schema support; `ajv` is not preinstalled but the runner could do `jq 'all(.[]; has("name") and has("input") and (.expect | has("overlay") and has("status") and has("mode"))) // halt_error'`) would catch this in 2 lines.

**Why it matters:** Phase 3 had a similar OOS finding (P2-OOS-2 about `expected.yaml`). The same lesson applies.

**The question that must be answered:** Add a startup assertion in `run-cases.sh` (Task 5.3): every case has top-level `name`, `input`, `expect` keys, and `expect` has `overlay`, `status`, `mode` keys. Use `jq` — no new dependency needed.

---

**CHARGE M4: `jq -r` of a missing key returns the literal string `"null"`, not empty — comparison logic must handle this.**

**The problem:** `jq -r '.expect.mode'` of `{"expect": {}}` outputs `null` (4 chars), not empty. If a case is missing the `mode` key (per M3), the runner extracts `expected_mode="null"`, and parse.sh emits `apply`. The mismatch message says `expected mode=null; got mode=apply` — confusing but not silently passing. However, if the parser ever emits the literal string `"null"` (it shouldn't, but consider a future bug), the comparison passes silently.

**The question that must be answered:** Either guard with `// ""` in the jq filter (`jq -r '.expect.mode // ""'`) so missing keys become empty strings, OR add the schema check from M3 so missing keys are caught at startup. Pick one.

---

**CHARGE M5: Task 9.4 deliberate-flip test only validates the runner detects ONE mismatch — does not validate accumulation.**

**The problem:** Task 9.4 says "edit ONE `expect` field in `cases.json`... Confirm `test.yml` fails with the expected mismatch error line for that case name." This validates that the runner detects a single mismatch — but does not validate H4 (accumulate-then-exit). To validate accumulation, the deliberate-flip test should flip TWO fields in TWO different cases and verify BOTH are reported in the failure output before exit.

**The question that must be answered:** Update Task 9.4 to flip two unrelated cases and assert both names appear in the failure output.

---

## Out of scope (note for the record)

---

**OOS-1: `mode` empty-vs-`apply` semantics (Deviation #5) is a defensible reading.**
The spec table is internally inconsistent (rows 8 vs 11 vs 13). The plan's Deviation #5 picks "always emit `apply` unless input is so malformed that no overlay is resolved AND `--read-only` was not seen." This is defensible. Sanity-check passes. The decision should be reflected in the spec via amendment, not just buried in a plan deviation, but that is a separate task.

**OOS-2: CLAUDE.md alphabetic ordering (Task 8.1) is correct.**
`apply-fix < check-auth < claude-command-router < lint-failure < pr-review < tag-claude` — confirmed. But the existing ordering in the live `CLAUDE.md` is NOT alphabetic — it is `pr-review, tag-claude, check-auth, apply-fix, lint-failure`. Task 8.1's "insert after apply-fix and before lint-failure" lands the new entry between apply-fix and lint-failure but does NOT make the overall list alphabetic. If the goal is alphabetic, fix the whole list. If the goal is "preserve existing pseudo-order, slot in the new entry," the current task is fine. Decide.

**OOS-3: `./check-auth` relative path is fine because the router is internal-only.**
Spec §8.2 explicitly notes the relative path works because the router is only called from this library's own reusable workflows after `actions/checkout`. Mandate #10 confirmed. No action needed in the plan; the constraint is documented in the spec.

---

## Verdict

This plan is **not ready to execute**. The architectural skeleton is correct — pure parse.sh + JSON corpus + runner is the right shape, and Deviations #1–#8 are mostly defensible. But the plan's Task 3.3 algorithm is a thinking-out-loud draft that contradicts itself on the wire format (H2) and equivocates between three regex engines (H1); Task 6.4's auth wiring is missing the step IDs needed to make the documented `status=unauthorized` output reachable (C1); Task 6.6's injection guard is half-correct and unproven (C2); the corpus has zero adversarial cases (C3); and the spec/plan disagree on whether `filler_words.txt` is load-bearing or documentation (H5). Three Critical findings exceed the "≤2 high-priority and 0 critical" greenlight threshold from the inquisitor mandate. **Pass 2 is warranted** after Critical and High-Priority items are addressed in the plan file. Do not begin Tasks 2–9 until C1–C3 and H1–H6 have explicit resolutions written into the plan.
