# Phase 4 Router — Inquisitor Pass 2

**Reviewer:** inquisitor (adversarial)
**Subject:** `docs/superpowers/plans/phase-4-router.md` (post-Pass-1 revisions)
**Date:** 2026-05-02
**Verdict (TL;DR):** Not ready. **2 Critical**, **2 High-Priority**, **3 Medium**, **1 OOS**. Pass 1 closed its 14 findings cleanly, but the revisions introduced two new defects that pass-1 could not have predicted because the fix surface didn't exist yet — exactly the Phase 3 pass-2 pattern. C1: Pass-1 H6's truncation rule plus the new "first-verb-wins ACROSS mentions" loop directly contradicts spec §8.1.1 step 8 ("subsequent verb tokens, including from a second `@claude` mention, are ignored"). C2: the tokenizer (`read -ra` with default IFS) does not split on `\r`, so a CRLF-line-ended comment body produces token `"review\r"` which fails exact-match against the verb allowlist — empirically reproduced; verb is silently mis-resolved. Pass 3 is warranted.

---

## Critical

---

**CHARGE C1: Multi-mention loop in Task 3.3 step (e) directly contradicts spec §8.1.1 step 8 — Pass 1 invented a behavior the spec explicitly forbids.**

**The problem:** Task 3.3 step (e) implements an iterative "first-verb-wins ACROSS ALL MENTIONS" loop (lines 209–243): when the first `@claude` mention's tokens contain no verb, advance to the second mention and re-scan. The empirical run against the pseudocode confirms this behavior — `parse_comment $'@claude foo\n@claude review'` returns `review|ok|apply`.

Spec §8.1.1 step 8 (line 520) reads, verbatim:

> **First-verb-wins:** scanning stops at the first known-verb match. Subsequent verb tokens (including from a second `@claude` mention) are ignored.

The plan's commentary at the top of the charge calls this sentence "ambiguous" and reads it as "only verb tokens AFTER the first match are ignored, so a second mention's verb counts if the first mention has no verb." This reading is **not defensible** — the parenthetical "including from a second `@claude` mention" exists precisely to foreclose the cross-mention reading. The spec authors anticipated exactly this question and answered it.

Furthermore, spec step 7 (line 519) reads:

> If the scan exhausts all tokens after `@claude` without matching a known verb, `status=unknown_verb` and the router posts a supported-verbs rejection.

"After `@claude`" is singular. There is no language anywhere in §8.1.1 about advancing to subsequent mentions. The §8.3 error-surface table lists `unknown verb` and `malformed` as the only "@claude was found but verb unresolved" outcomes — no row for "first mention had no verb, second did."

**Why it matters:** Two compounding consequences:

1. The plan ships an algorithm that emits different outputs than the spec mandates. Corpus row `multi-line-two-mentions-first-wins` (`@claude review\n@claude fix` → `review`) HAPPENS to land on the right answer for that specific input because the first mention has the verb — but the plan's algorithm ALSO emits `review` for `@claude foo\n@claude review`, which the spec says should be `unknown_verb`. The corpus does not include this discriminating case, so the test passes a wrong implementation.

2. Spec amendment is implied (Task 12) but not specified. Task 12 amends step 5 (filler_words) and adds a "mode field semantics" paragraph; it does NOT amend step 8. If the implementer follows the plan, the spec and code disagree and the spec is the contract.

**The question that must be answered:** Pick one and write it in the plan: (a) implement spec step 8 literally — single-mention scan, `unknown_verb` if first mention has no verb regardless of what follows, drop the multi-mention loop entirely; OR (b) keep the multi-mention loop and add a Task 12 spec amendment that rewrites step 8 to read "scanning stops at the first known-verb match across all `@claude` mentions; verb tokens after the first match are ignored." Document the change in Deviation #7. The current state — plan implements (b), spec mandates (a), neither acknowledges the conflict — is unshippable.

---

**CHARGE C2: `read -ra` tokenizer does not split on `\r` — CRLF-line-ended comment bodies silently mis-tokenize the verb.**

**The problem:** Pass 1's H6 resolution relies on the regex `[[:space:]]` class to anchor `@claude<whitespace>` (regex matches `\r`), and on `read -ra tokens <<< "$tail"` to tokenize the post-mention text. `[[:space:]]` includes `\r`; bash's default `IFS` is `$' \t\n'` and does NOT include `\r`. The two diverge silently.

Empirical reproduction (bash 5.2.37, ubuntu-latest's bash family):

```
$ body=$'@claude review\r\n@claude fix'
$ # regex matches; tail = $'review\r\n@claude fix'
$ # truncation at next @claude; tail = $'review\r'  (the \r is preserved)
$ read -ra tokens <<< "$tail"
$ printf '%s' "${tokens[0]}" | od -c
0000000   r   e   v   i   e   w  \r
```

The single token is `"review\r"` (7 bytes), not `"review"`. Lowercasing produces `"review\r"`. The case statement `case "$token_lc" in review|fix|explain) ...` does NOT match — pattern is exact-string. Verb-scan exhausts the first mention without a match. The new multi-mention loop (C1) then advances to the second mention and resolves `fix`. Output: `fix|ok|apply` for what the user typed as `@claude review`.

GitHub's REST API returns comment bodies with the line endings the user committed. Browser-submitted comments are typically `\n`-only, but copy-paste from Windows applications, gh CLI on Windows, or any GitHub client running on Windows can produce `\r\n`. This is not exotic.

**Why it matters:** Silent verb mis-resolution. The user types `@claude review`; the runner builds a `fix` overlay container and starts modifying code. The `pr-review` "different eyes" guarantee is violated, and downstream cost/security assumptions break.

**The question that must be answered:** Either (a) normalize the body before regex/tokenization — `body="${body//$'\r'/}"` at function entry; OR (b) explicitly set `IFS=$' \t\n\r'` before each `read -ra` call. Add a corpus row for `@claude review\r\n@claude fix` → `review|ok|apply` (CRLF round-trip). Without this, the test corpus cannot detect the regression.

---

## High-Priority

---

**CHARGE H1: Task 3.4's "empty-tokens → malformed" rule is in commentary but not in Task 3.3's pseudocode — bare `@claude<space>` falls through to `unknown_verb`.**

**The problem:** Task 3.4 third bullet (line 274) says:

> `@claude` followed by EOF (whitespace then nothing) → regex matches; tail is empty; tokenize yields zero tokens; verb-scan exhausts; output `|unknown_verb|apply`. **Spec §8.1.1 row 13 says `malformed` for "bare @claude"** ... Resolve by adding an explicit check: if `tokens` array is empty after tokenization → `printf '%s|%s|%s\n' "" "malformed" ""` instead of falling through to verb scan.

The pseudocode block in Task 3.3 (lines 173–270) does NOT include this check. Empirical reproduction:

```
$ parse_comment '@claude '
|unknown_verb|apply        # WRONG — spec says malformed
```

The empty-tokens-malformed rule lives only in commentary. An implementer who copies Task 3.3's pseudocode verbatim — which Pass 1's revisions explicitly produced as a "concrete pseudocode block" replacement for stream-of-consciousness drafting — produces a non-spec-compliant parser. The corpus row for bare-`@claude` (Pass 1's expansion) presumably expects `malformed`; the parser as written emits `unknown_verb`; CI fails. The implementer then has to reverse-engineer the fix from the test failure rather than read it from the plan.

**The question that must be answered:** Move the empty-tokens check from Task 3.4 commentary INTO Task 3.3 step (d) or (e) of the pseudocode. Specifically: after `read -ra tokens <<< "$tail"`, add `if [ ${#tokens[@]} -eq 0 ]; then printf '%s|%s|%s\n' "" "malformed" ""; return 0; fi`. The "always run 3 fields, 2 pipes" property still holds.

---

**CHARGE H2: `parse_comment` uses `set -u` inside `local -`; an unset-variable bug aborts mid-emit and the action.yml step writes silently incoherent outputs.**

**The problem:** Task 3.3's `parse_comment` opens with `local -; set -uo pipefail`. Pass 1's H3 commentary said "set -u inside parse_comment will abort on any reference to an unset variable... a programmer error during development will crash silently in CI with no useful diagnostic, because the function 'returns 0 always' is contradicted by set -u causing immediate exit." The H3 resolution chose `local -` scoping AND kept `set -u` inside the function. The interaction with action.yml's outer step has not been re-examined.

Action.yml step (Task 6.4 lines 403–432):

```bash
set -uo pipefail
# ... auth branch ...
source "${{ github.action_path }}/lib/parse.sh"
tuple=$(parse_comment "$COMMENT_BODY")
IFS='|' read -r overlay status mode <<< "$tuple"
```

Empirical demonstration:

```
$ buggy_parse() { local -; set -uo pipefail; echo -n "review|"; local x="$undefined"; echo "ok|apply"; }
$ result=$(buggy_parse 2>/dev/null)
$ echo "[$result]"
[review|]
$ IFS='|' read -r o s m <<< "$result"
$ echo "overlay=[$o] status=[$s] mode=[$m]"
overlay=[review] status=[] mode=[]
```

A typo inside `parse_comment` (e.g., referencing `$tail` after a refactor renames it) produces partial stdout before the `set -u` abort. The outer step's `IFS='|' read` consumes whatever was emitted; partial 1-field or 2-field output yields `overlay=review status= mode=`. `read` returns 1 (incomplete read) but the outer step does NOT check `read`'s return code, and `set -u` does not fire on `read` returning non-zero. The three `echo "$key=$val" >> "$GITHUB_OUTPUT"` lines then write `overlay=review`, `status=`, `mode=` — **a logically impossible state** (status is empty but overlay is set). Downstream `if needs.route.outputs.status == 'ok'` correctly rejects this, but `if status == 'unauthorized'` also doesn't fire — the polite-rejection path is lost.

The only signal of trouble is the captured `tuple`'s rc, which is discarded. `tuple=$(...)` does not propagate the inner abort; even with `set -e` in the outer, command substitution's exit code only matters if assigned-then-checked.

**Why it matters:** The parser is documented as "returns 0 always" (Task 3.2), and the action.yml's contract is "always writes 3 keys with semantically valid values." Both are violated by an interaction the plan does not address. The runner (`run-cases.sh`) catches this case via Pass-1 H4's explicit `rc=$?` check, but action.yml does not.

**The question that must be answered:** Mirror the runner's pattern in action.yml: capture `tuple=$(parse_comment "$COMMENT_BODY") || rc=$?` (or `set +e` around it), and on rc != 0 OR on `IFS='|' read -r ...` returning non-zero (incomplete), emit the malformed tuple `overlay=,status=malformed,mode=` and log a parser-bug warning. Without this, a typo in parse.sh produces silent state corruption in production.

---

## Medium

---

**CHARGE M1: Backtick-adjacent tokens are not handled — `@claude review` inside `\`...\`` produces token `"review\`"` which fails exact-match.**

**The problem:** A common comment pattern: ``Run `@claude review` to start.`` — backticks on both sides. Pass 1 added a corpus row for **backtick-wrapped MENTIONS** (`shell-metachar-2`: ``@claude fix `cat /etc/passwd` --read-only``), but did NOT add a row where the backtick directly abuts the verb (no whitespace between ` and `review` ` after `review`). Empirical:

```
$ parse_comment 'You can run `@claude review` to start a review.'
|unknown_verb|apply        # token is "review`" — not in allowlist
```

The corpus row `shell-metachar-2` has whitespace between `fix` and `` ` ``, so `fix` tokenizes cleanly. The no-whitespace case is ambiguous in the spec — but the corpus must pin SOME behavior, and a missing row means a future regex tweak (e.g., adding `[[:punct:]]` stripping) won't have a regression test.

**The question that must be answered:** Add at least one corpus row for the no-whitespace-around-backtick case: ``You can run `@claude review` to start.`` → `|unknown_verb|apply` (current behavior, defensible since the verb is inside a code span). Or: spec-amend to require a normalization pass that strips backticks adjacent to tokens.

---

**CHARGE M2: Pass-1 corpus row `multi-line-mention-flag-in-second` is correct only by coincidence — name claims "first-mention truncation" but the new loop changes the rationale.**

**The problem:** Corpus row (Task 4.4 line 308): `@claude fix\n@claude --read-only` → `fix|ok|apply`. Pass-1 rationale: "First-mention tail truncates at second `@claude`; second mention's flag is ignored."

Under Pass 1's revised algorithm: first mention's tokens are `[fix]`, verb resolves to `fix`, `break 2` exits the multi-mention loop, flag scan iterates over the SAME `tokens` array (which is `[fix]`, no `--read-only`), `mode=apply`. Correct outcome.

But: the comment's stated rationale ("first-mention truncation") and the actual algorithm differ. The flag never gets a chance to be in scope because the verb is found in the first-mention tokens and `break 2` halts iteration. If a future refactor moves the flag scan OUTSIDE the multi-mention loop or merges the two scans, the case still passes — but for a different reason. The case does not actually exercise the truncation.

**The question that must be answered:** Either (a) update the case `name` and `expect` rationale to reflect the actual algorithm (`break 2` halts after verb, flag scan operates on same `tokens` array), OR (b) add a discriminating corpus row that genuinely tests the truncation: `@claude fix\n@claude please --read-only` (second mention has `please` and `--read-only`; truncation must prevent the flag from being seen) → `fix|ok|apply`. The current corpus does not discriminate truncation from break-after-first-verb.

---

**CHARGE M3: Task 12.2 "mode field semantics" amendment contradicts the spec table for row 8.**

**The problem:** Task 12.2 proposes:

> `mode` is empty (`""`) only when the input is so malformed that no `@claude<whitespace>` mention was found at all (rows 13: bare `@claude`, 14: `@claude-review`).

Spec §8.1.1 examples table row 8 (line 540) is `@claude check this PR` → `mode: apply`. This is `unknown_verb`, not malformed. Per the new amendment, mode is `apply` for non-malformed → consistent. Good.

But the spec table line 543 (`@claude thanks!`) → mode `—`. This is also `unknown_verb`. Per the amendment, mode should be `apply`. The amendment's parenthetical "row 11 mode = apply (default; non-malformed)" matches. The amendment correctly resolves the apparent inconsistency.

However: line 546 (`@claude` bare) → `malformed`, mode `—`. Amendment says: empty mode for malformed. Consistent.

Line 547 (`@claude-review`) → `malformed`, mode `—`. Amendment says: empty mode for malformed. Consistent.

So the amendment is internally consistent — but the corpus must reflect the new rule. Pass 1's expansion claims rows 8 and 11 both produce `mode=apply`, but Deviation #5 (line 84–90) reads:

> `@claude thanks!` (unknown verb) → `mode: —` per row 11 — i.e. "the mode is not meaningful when there's no resolved verb."

Deviation #5 contradicts Task 12.2. Deviation #5 says `@claude thanks!` → mode empty; Task 12.2 says non-malformed → mode `apply`. These cannot both hold. The plan is internally inconsistent on the same input.

**The question that must be answered:** Pick one. Either (a) Deviation #5's stated reading was wrong and `@claude thanks!` produces `mode=apply` (consistent with Task 12.2 — recommended for parser simplicity); OR (b) Task 12.2 needs another carve-out: `mode` is empty for malformed AND for `unknown_verb`. Update both Deviation #5 and the corpus to agree with Task 12.2. The current "mode=apply default for unknown_verb" in Task 3.3 step (f) (line 249) implements (a); Deviation #5 reads (b); the spec amendment text reads (a). Reconcile.

---

## Out of scope (note for the record)

---

**OOS-1: GitHub Actions YAML allows comments inside the `outputs:` block.** The Pass-2 charge raised whether YAML allows comments inside `outputs:`. YAML allows `#` comments anywhere outside string scalars. Verified with `actionlint`-pattern action files in the repo. Non-issue — the `# TODO: §13 Q9` comment in Task 6.3 is fine.

**OOS-2: `${{ github.action_path }}/lib/parse.sh` resolves correctly.** GHA sets `github.action_path` to the action's checkout root. For `uses: ./claude-command-router`, the path is `<workspace>/claude-command-router`. Source resolution is correct in all caller contexts (same-repo, internal-only per spec §8.2). Non-issue.

**OOS-3: Adversarial corpus content is safe to commit.** Bodies containing `$(rm -rf /)` are JSON string literals. GitHub push-protection scans for credentials, not shell commands. No security tooling will reject the PR. Non-issue.

---

## Verdict

This plan is **not ready to execute**. C1 is the same class of finding Phase 3 pass-2 caught: pass 1's revisions invented a behavior (multi-mention loop) that the spec explicitly forbids, but pass 1 could not see the conflict because the loop didn't exist when pass 1 read the spec. C2 (CRLF tokenization gap) was empirically reproduced — bash's default IFS does not include `\r`, and Pass 1's `[[:space:]]` regex anchor masks the divergence at the regex layer while leaving the tokenizer broken. H1 (empty-tokens-malformed in commentary, not pseudocode) and H2 (parse_comment partial-emit on `set -u` abort, action.yml does not capture rc) are both fix-the-plan issues, not deep design problems. M1-M3 expose corpus-rationale drift and a Deviation/amendment internal inconsistency. **Do NOT begin Tasks 2-9 until C1 and C2 are resolved in the plan.** Pass 3 is warranted: C1 requires a spec-vs-plan reconciliation decision, and Pass 2's empirical CRLF reproduction is the kind of finding that begets adjacent ones (does jq round-trip preserve `\r`? does `bash <<<` heredoc add a trailing newline that interacts with truncation?). Convergence: pass 1 found 14 actionable, pass 2 finds 7 actionable. The trajectory is correct but pass 3 is needed to close C1+C2 and verify their resolutions don't introduce a third generation.
