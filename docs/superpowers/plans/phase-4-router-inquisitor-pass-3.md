# Phase 4 Router — Inquisitor Pass 3

**Reviewer:** inquisitor (adversarial)
**Subject:** `docs/superpowers/plans/phase-4-router.md` (post-Pass-2 revisions)
**Date:** 2026-05-02
**Verdict (TL;DR):** Acceptable to ship, with two Medium fix-the-plan items. **0 Critical**, **0 High-Priority**, **2 Medium**, **2 OOS**. Pass 2's revisions did NOT introduce a new generation of critical defects (unlike Phase 3's pass-2 → pass-3 trajectory). Empirical reproduction of the Task 3.3 pseudocode confirms it implements spec §8.1.1 step 8 correctly; CRLF normalization works as written; `local -` correctly scopes flags on bash 5.2.37 (the `ubuntu-latest` family); glob safety holds because `${var#*"$first_match"}` quotes the match literally; the `parse_rc=$?` capture is well-formed. Trajectory 14 → 7 → 2 confirms convergence; pass 4 is **not** warranted.

---

## Critical

*(none)*

---

## High-Priority

*(none)*

---

## Medium

---

**CHARGE M1: Spec §8.1.1 step 5 still asserts "the router loads this file at startup" — the source of truth disagrees with the plan.**

**The problem:** Live spec at `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` line 517 reads, verbatim:

> The `filler_words.txt` file documents frequently-seen skipped tokens for implementer reference and test coverage, but is not a gate — the algorithm skips all non-verb tokens regardless of whether they appear in this file. The authoritative filler-word list lives in `claude-command-router/lib/filler_words.txt` (one word per line, lowercased). **The router loads this file at startup;** the JSON corpus in §10.3 validates that the known-verb scan respects the current list.

The first half of the paragraph contradicts the second half — the spec ALREADY contains the doc-only language Task 12.1 proposes to add, but ALSO retains the "router loads this file at startup" claim. Task 12.1 says it will replace the entire paragraph, but it only quotes a fragment ("The authoritative filler-word list lives in...") that does not match the live text. An implementer running a `git diff` after Task 12.1 will produce a no-op or partial replacement because the search string in the plan does not appear verbatim in the spec.

**Why it matters:** The amendment ships clean only if the plan's "currently reads" quote matches the spec exactly. It doesn't. Result: either the amendment fails (`sed`/Edit string not found), or the implementer paraphrases and the contradictory "loads this file at startup" sentence survives the merge. The spec then continues to disagree with itself and the plan.

**The question that must be answered:** Update Task 12.1 "Currently reads" block to quote the actual current text (the full paragraph spanning lines 517) — not the paraphrased version. The replacement target must be byte-exact for the Edit tool to succeed.

---

**CHARGE M2: The corpus does not include `@claude review-thoroughly\n@claude fix` — a discriminating case for the Pass-2 multi-mention revert.**

**The problem:** Pass 2 reverted Pass 1's cross-mention loop. The corpus row `multi-line-first-no-verb-second-has-verb` (`@claude foo\n@claude review` → `unknown_verb|apply`) exercises this revert. But "foo" is a generic non-verb token; it does not exercise the verb-prefix-token rule (M1 of Pass 1) AND the multi-mention revert simultaneously. The discriminating case is `@claude review-thoroughly\n@claude fix`:

- Under Pass 1's loop: first mention has no exact-match verb (`review-thoroughly` ≠ `review`); loop advances to second mention; resolves `fix`. Output: `fix|ok|apply`.
- Under Pass 2's spec-compliant revert: first mention exhausts without verb; status=`unknown_verb`; second mention is unreachable. Output: `|unknown_verb|apply`.

Empirical reproduction against the Task 3.3 pseudocode (bash 5.2.37):

```
$ parse_comment "$(printf '@claude review-thoroughly\n@claude fix')"
|unknown_verb|apply
```

Corpus has `@claude review-thoroughly` (single mention) → `unknown_verb` AND `@claude foo\n@claude review` → `unknown_verb`. Neither row simultaneously stresses (a) the verb-prefix-skip property and (b) the no-cross-mention property. A future "fix" that re-adds Pass 1's cross-mention loop to "improve UX" would PASS the existing corpus — neither row catches it. The single-mention `review-thoroughly` row would still emit `unknown_verb` (no second mention to advance to); the `foo\n@claude review` row would flip to `review|ok|apply` — caught by that row. So the property IS protected by the existing `foo\n@claude review` case. The proposed `review-thoroughly\n@claude fix` is redundant for catching that specific regression.

**Why it matters:** The corpus is not actually broken — it does discriminate the multi-mention revert via the `foo\n@claude review` row. But the plan's narrative claims `review-thoroughly` cases test the verb-prefix property AND the multi-mention property. They don't — they test the verb-prefix property in single-mention contexts only. The case naming is misleading rather than incorrect. Add `multi-line-verb-prefix-then-real-verb` (`@claude review-thoroughly\n@claude fix` → `|unknown_verb|apply`) for redundant defense-in-depth, OR update the rationale comment in the existing `foo\n@claude review` row to explicitly state "this row protects spec §8.1.1 step 8's no-cross-mention rule; see also `verb-prefix-token` for the prefix-skip rule (different concern)."

**The question that must be answered:** Add the discriminating case OR explicitly document which corpus row defends the no-cross-mention property in its `name`/rationale field. The current corpus protects the property but does not advertise which row does so.

---

## Out of scope (note for the record)

---

**OOS-1: `local -` scopes ALL `set` flags including `pipefail` — verified empirically on bash 5.2.37.**

```
$ bash -c 'parse_test() { local -; set -uo pipefail; echo "inside: $-"; }; \
           set +u; echo "before: $-"; parse_test; echo "after: $-"'
before: hBc
inside: huBc
after: hBc
```

`local -` was added in bash 4.4 (CHANGES, 2016). `ubuntu-latest` ships bash 5.2.x. Plan's H3 resolution is correct as written. Pass-2 OOS verification stands.

---

**OOS-2: `${body_remaining#*"$first_match"}` is glob-safe because `$first_match` is double-quoted.**

Bash POSIX param expansion `${var#pattern}` treats `pattern` as a glob unless quoted. With `${var#*"$X"}`, the `*` is a glob wildcard, but `"$X"` is a literal substring match — bash's quote-removal happens AFTER pattern compilation, so any `*`, `?`, `[` characters inside `$first_match` are NOT interpreted as globs. Verified:

```
$ body="@claude review * stuff @claude fix"
$ [[ "$body" =~ $re ]]
$ first_match="${BASH_REMATCH[0]}"   # "@claude "
$ tail="${body#*"$first_match"}"
$ echo "[$tail]"
[review * stuff @claude fix]
```

The `*` in the body survives intact. No glob misinterpretation. Plan's algorithm is safe.

Note: `first_match` is constructed from `BASH_REMATCH[0]` of the regex, which is `(^|[^A-Za-z0-9])@[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]]` — at most 9 characters of constrained content (one optional non-alnum + literal `@claude` + one whitespace). Glob metacharacters CANNOT appear because the regex never matches them. Even if they could, the quote-protection would handle it.

---

## Verdict

This plan is **acceptable to ship**. Pass 2's revisions are correct: the multi-mention loop revert (Pass 2 C1) implements spec §8.1.1 step 8 verbatim and was empirically verified against the corpus' discriminating row; CRLF normalization at function entry (Pass 2 C2) handles all `\r` cases including bare-`\r` (legacy Mac line endings) without harming legitimate content; the empty-tokens malformed guard (Pass 2 H1) sits in the pseudocode at the correct position and produces the spec-mandated tuple for bare-`@claude` and `@claude<space>EOF` cases; the `parse_rc=$?` capture (Pass 2 H2) is well-formed because the step uses `set -uo` not `-e`. The two Medium findings are paperwork: M1 is a quote-the-spec-verbatim fix in Task 12.1; M2 is a corpus-rationale clarification, not a missing case (the property IS defended). Trajectory 14 → 7 → 2 confirms convergence. Pass 4 is **not** warranted. Begin Tasks 2–9.
