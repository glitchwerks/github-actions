# Phase 3 Overlays — Inquisitor Pass 3

**Plan under review:** `docs/superpowers/plans/phase-3-overlays.md` (post-Pass-2 revision, 744 lines)
**Reviewer charge:** find regressions introduced by Pass 2's revisions, with specific focus on (a) the `$defs/overlay_scope` schema split, (b) defense-in-depth marker validation asymmetry, (c) clone-SHA pinning across parallel jobs, (d) `BASE_DIGEST` length check correctness, (e) Task 7 reordering and renormalize, (f) spec-amendment internal consistency, (g) cross-section drift after two passes of revisions.
**Date:** 2026-05-02

The plan author was right that revisions converge — most of Pass 2's hardening landed cleanly. But Pass 2 also introduced one new check that is **provably wrong by inspection** and one defense pair that is **asymmetric in a way that defeats the "two defenses" claim**. Pass 3 finds two CRITICAL items, two HIGH-PRIORITY items, two MEDIUM items, and one OOS. The CRITICAL items are not class-of-bug surprises like Pass 2's `subtract_from_shared` failure modes — they are direct contradictions inside Pass 2's own remediation snippets. They will fail STAGE 3 on the very first run if shipped as-written.

---

## CRITICAL (BLOCKING)

### CHARGE 1 — `BASE_DIGEST` length-and-charset check is wrong; STAGE 3 hard-fails on every run

**Quotes:**

Plan Task 9.3 (line 635):
> ```bash
> [ "${#BASE_DIGEST}" -eq 64 ] && [ -z "${BASE_DIGEST//[0-9a-f]/}" ] || { echo "ERROR base_digest_invalid value=$BASE_DIGEST" >&2; exit 1; }
> ```

Plan Task 9.2 (line 621):
> ```
> BASE_DIGEST=${{ needs.stage-2.outputs.base_digest }}
> ```

Phase-2 workflow `runtime-build.yml:139` (verified live on the branch):
> ```yaml
> outputs:
>   base_digest: ${{ steps.build.outputs.digest }}
> ```

`docker/build-push-action@v7`'s `digest` output is documented as the image content-addressable identifier, format `sha256:<64-hex>` — **71 characters total, with the `sha256:` prefix**. Phase 2's workflow stores it raw, no stripping.

**The problem:** When STAGE 3 reads `BASE_DIGEST` from the upstream job output, the value is `sha256:abcdef…` (71 chars). The Pass-2-Charge-8 sanity check then evaluates:

- `${#BASE_DIGEST}` → 71, not 64. First clause `-eq 64` is **false**.
- `${BASE_DIGEST//[0-9a-f]/}` → `sha256:` (the `:` and the letters `s`/`h` are non-hex; `s` and `h` are not in `[0-9a-f]`). Result: non-empty string. Second clause `-z` is **false**.

**Both clauses are false on every well-formed digest.** STAGE 3 cells fail every cell with `ERROR base_digest_invalid value=sha256:abc...` immediately, before any image is built. The "defense-in-depth backstop" is a footgun pointing at the runtime.

There is a deeper inconsistency: the same `BASE_DIGEST` is interpolated into the `FROM` line as `claude-runtime-base@sha256:${BASE_DIGEST}` (Task 4.1) and into the `docker pull ghcr.io/...@sha256:${{ needs.stage-2.outputs.base_digest }}` command (Task 9.2 line 605). If `BASE_DIGEST` carries the `sha256:` prefix, those references become `@sha256:sha256:abc...` — invalid digest references that fail at pull time. So the rest of the plan implicitly assumes BARE hex, while the upstream workflow output it consumes carries the prefix. **Two parts of the plan disagree on the format of the same variable.**

**Why it matters:** This is the highest-impact finding of any pass so far. Shipped as-written, no overlay image is ever built. The check Pass 2 introduced is the first blocker; the prefix mismatch in the FROM line and `docker pull` is the second.

**The question that must be answered:** Is `${{ needs.stage-2.outputs.base_digest }}` `sha256:<hex>` (with prefix) or bare hex? If the former, where does the prefix get stripped? If the latter, what gets done to Phase 2's existing workflow to make it strip?

**Remediation:** Pick one path:
- (a) Strip the prefix at the consumer side. Add a step in STAGE 3 cells (and in Task 4.0): `BASE_DIGEST="${BASE_DIGEST#sha256:}"` before any use. Then the `[ "${#BASE_DIGEST}" -eq 64 ]` check becomes correct.
- (b) Strip the prefix at the producer side. Modify Phase 2's `stage-2.outputs.base_digest` to write `${{ steps.build.outputs.digest }}` with `sha256:` stripped. This is a Phase 2 workflow edit and would land via this PR or a precursor.

Either choice must be made explicit. Path (a) is contained inside Phase 3 and lower risk. Either way, the plan must show the strip explicitly — not assume it.

---

### CHARGE 2 — Defense-in-depth for marker names is asymmetric: Dockerfile accepts inputs that the extractor rejects

**Quote (Task 5.5 Dockerfile snippet, lines 459–466):**
> ```
> case "$plugin" in
>   ''|*/*|.|..) echo "FATAL invalid subtract marker basename: '$plugin'" >&2; exit 1;;
> esac;
> case "$plugin" in
>   [a-z0-9]*) :;;
>   *) echo "FATAL subtract marker basename '$plugin' does not match plugin charset" >&2; exit 1;;
> esac;
> ```

**Quote (Task 5.1 Phase B step 3, line 425):**
> assert `name` matches `^[a-z0-9][a-z0-9-]*$` (letters, digits, hyphens; no spaces, slashes, dots, or special characters)

**The problem:** The two defenses are **not equivalent** and the asymmetry runs in the wrong direction.

Verified empirically (test run in this pass):
- Marker name `name.with.dots` → `case ... in ''|*/*|.|..)` is FALSE (no slash, not exactly `.` or `..`), `case ... in [a-z0-9]*)` is TRUE (starts with `n`). **Dockerfile accepts.** Extractor regex `^[a-z0-9][a-z0-9-]*$` rejects (the `.` is not in `[a-z0-9-]`).
- Marker name `name with space` → No slash, not `.`/`..`, starts with `n` → **Dockerfile accepts.** Extractor rejects.
- Marker name `abc;rm /tmp/foo` → No slash, not `.`/`..`, starts with `a` → **Dockerfile accepts.** Extractor rejects.

The shell glob `[a-z0-9]*` only checks the FIRST CHARACTER. Everything after the first character is `*` — match any sequence of any characters, including spaces, dots, semicolons, newlines, etc. The plan's commentary ("plugin charset") implies the check enforces a charset across the whole string — it does not. Glob `*` is not regex `.*` with a constraint; it is unconstrained.

The plan acknowledges defense layering: "Either defense alone is insufficient — the schema validator runs at STAGE 1; the Dockerfile RUN runs at STAGE 3; a malformed marker between those stages must not be trusted." The intent is right. The execution is wrong: layer 2's check is strictly weaker than layer 1's. A marker file written between STAGE 1 and STAGE 3 (the threat model the plan names) with name `evil.name` or `evil name` slips through layer 2 entirely. `rm -rf "/opt/claude/.claude/plugins/evil name"` then runs — it's a no-op since the plugin doesn't exist, but the **principle** that layer 2 catches what slipped past layer 1 is broken.

A second issue, narrower but real: `[a-z0-9]*` matches a zero-length tail, so `a` (single char) passes — fine. But consider `0` or `9-foo`: starts with `[a-z0-9]`, no slash, not dot/dotdot — Dockerfile accepts. Extractor's `^[a-z0-9][a-z0-9-]*$` accepts `9-foo`, accepts `0`. So that case is symmetric. The asymmetry is only in the trailing-character constraint: extractor restricts to `[a-z0-9-]`; Dockerfile permits **any character**.

**Why it matters:** Pass 2 Charge 2 was explicitly about preventing the Dockerfile from trusting an unvalidated marker filename. The remediation Pass 2 wrote does not actually achieve charset equivalence. Future Pass 4 (or a real attacker) can write a marker file that bypasses the second-layer defense the plan claims to provide. The class-of-bug Pass 2 was trying to close (regression-of-revision; new mechanism's failure mode unchecked) is not closed; it has been moved to a less obvious location.

**The question that must be answered:** Is the Dockerfile's `case "$plugin" in [a-z0-9]*)` a charset enforcement (matching the extractor's regex) or only a first-character check? If the latter, the plan's "second defense" claim is inaccurate.

**Remediation:** Replace the second `case` with a check that enforces the full charset across the whole string. Bash extglob is one path; a pattern like `[!a-z0-9-]*` (negated bracket — fail if ANY non-conforming character appears anywhere) is portable POSIX. The simplest correct check uses two cases inverted:

```
case "$plugin" in
  *[!a-z0-9-]*) echo "FATAL bad charset" >&2; exit 1;;
esac
case "$plugin" in
  [!a-z0-9]*) echo "FATAL must start with [a-z0-9]" >&2; exit 1;;
esac
```

The first rejects any string containing a character outside `[a-z0-9-]`; the second rejects strings that start with `-` (which the regex `^[a-z0-9][a-z0-9-]*$` also forbids). Together this matches the extractor regex.

---

## HIGH-PRIORITY (MAJOR)

### CHARGE 3 — Clone-SHA pinning gap: STAGE 2's clone is never compared against STAGE 1c-determinism's clone

**Quote (Task 9.2 lines 599–600):**
> ```bash
> [ "$PRIVATE_HEAD"     = "${{ needs.stage-1c-determinism.outputs.private_head }}" ] || ...
> [ "$MARKETPLACE_HEAD" = "${{ needs.stage-1c-determinism.outputs.marketplace_head }}" ] || ...
> ```

**Workflow ordering** (verified on `runtime-build.yml`):
- `stage-2: needs: stage-1` (line 132)
- `stage-1c-determinism: needs: stage-1` (plan Task 9.1)
- `stage-3: needs: [stage-2, stage-1c-fixture, stage-1c-determinism]` (plan Task 9.2)

**The problem:** STAGE 2 and STAGE 1c-determinism both clone the private + marketplace repos in parallel after STAGE 1, on different runners. The plan asserts equality between STAGE 1c-determinism's clone SHA and STAGE 3's clone SHA. **It does NOT assert equality between STAGE 2's clone SHA and STAGE 1c-determinism's clone SHA.** STAGE 2 is the job that produces `base_digest` — i.e., the base image that the overlay's `FROM` line references. If STAGE 2 cloned at a different SHA than STAGE 1c-determinism (because a force-push landed in the window between STAGE 1's completion and STAGE 2's clone, AFTER STAGE 1c-determinism's clone), then the determinism replay validated tree A and STAGE 2 baked tree B into the base image, and STAGE 3 then asserts STAGE 1c-determinism = STAGE 3 (which can both be A) while STAGE 2 was B. The check passes; the inputs disagree.

The risk window is narrow — STAGE 1c-determinism and STAGE 2 both `needs: stage-1` so they start in parallel; their clones happen within seconds of each other. A force-push landing in that window is unlikely but not impossible (the spec accepts marketplace pin can move; private tag can be moved). The Pass 2 remediation closed the STAGE 1c-determinism vs STAGE 3 gap; it did not close the STAGE 2 vs STAGE 1c-determinism gap.

The deeper question is what the assertion is FOR. If the goal is "the tree the determinism replay validated is the tree we built into the overlay," then STAGE 2's clone must match too — because STAGE 2's clone is what produced the `shared/` content baked into the base, and the overlay's tree includes `shared/` content via inheritance. If the goal is only "STAGE 1c-determinism replayed the same overlay-tree STAGE 3 used," then the current pairwise check is sufficient. The plan does not state which.

**Why it matters:** This is a Pass-2 regression-of-revision: Pass 2 added the clone-drift check between two of three relevant points (1c-d ↔ 3) and missed the third (1c-d ↔ 2). The check is not wrong — it just doesn't cover what the rationale claims it covers ("input-immutability across stages"). One more line of the assertion closes the gap.

**The question that must be answered:** Should STAGE 2 also publish its clone SHAs to job outputs and have STAGE 3 assert equality against both STAGE 1c-determinism AND STAGE 2?

**Remediation:** Modify STAGE 2 to capture and publish `private_head` and `marketplace_head` as job outputs (Phase 2 workflow already captures `PRIVATE_SHA` to `$GITHUB_ENV` — promote to job output). Modify the Task 9.2 assertion to compare STAGE 3 against BOTH:

```
[ "$PRIVATE_HEAD" = "${{ needs.stage-1c-determinism.outputs.private_head }}" ] && \
[ "$PRIVATE_HEAD" = "${{ needs.stage-2.outputs.private_head }}" ] || ...
```

If all three are equal, the determinism story is airtight.

---

### CHARGE 4 — Recovery procedure for clone-drift error is undocumented

**Quote (Task 9.2 line 599):**
> ```
> echo "ERROR clone_drift_between_stages repo=private stage1c=$X stage3=$Y" >&2; exit 1;
> ```

**Quote (Task 9.2 line 602):**
> Mismatch means: marketplace SHA was re-pinned in mid-flight, or private tag was force-moved. Either is a STOP-and-investigate event — the determinism replay validated one tree, STAGE 3 would build another. Fail loudly.

**The problem:** The plan tells the maintainer `STOP-and-investigate` but does not say what investigation looks like, what restoration looks like, or whether the next run is expected to converge. The two SHAs in the error message are diagnostic, but a maintainer reading just `clone_drift_between_stages` doesn't know whether to:
- Re-run the workflow (the next run will probably converge — both clones will see the new SHA)
- Bump `sources.marketplace.ref` in the manifest to match the new SHA
- Roll back the marketplace SHA (if a force-push was inadvertent)
- Page someone (if the private tag was moved against policy)

This is partly an out-of-scope concern (operational runbook content), but the Phase 3 plan also documents recovery procedures for other errors (Task 4.0 STOP, Task 1.4 STOP, Task 1.5 STOP). The asymmetry is the issue: the most operationally complex error has the least documented recovery.

A second concern: `STAGE 2` is `needs: stage-1` and STAGE 1c-determinism is also `needs: stage-1`. If STAGE 2 already pushed a base image at the moment STAGE 3 detects clone drift, the base image is now in GHCR with one tree's content, and the manifest still names a different SHA. Without a documented procedure for that state, the next run can produce a base whose digest differs from the just-pushed one — confusing for forensic investigation.

**Why it matters:** Operational maturity. The plan says "fail loudly" but loudness without a runbook leads to slow recovery. Pass 6 will inherit this without context.

**The question that must be answered:** When a maintainer gets `ERROR clone_drift_between_stages`, what are they expected to do, and in what order?

**Remediation:** Add to Task 9.2 a short paragraph naming the recovery decision tree: (a) if `git -C /tmp/marketplace fetch && git rev-parse origin/HEAD` shows a SHA different from the manifest's pin → marketplace SHA was moved by Anthropic; bump manifest after manual review of the `git diff` between the old and new SHA (matches the spec §13 Q5 "manual cadence"). (b) If the private tag was moved → file an incident; private tags should be append-only by convention. (c) Re-run the workflow only after the manifest pins are reconciled. Until then, expect deterministic re-failure.

---

## MEDIUM

### CHARGE 5 — `[a-fA-F]` vs `[a-f]` charset check assumes `docker/build-push-action@v7` always lowercases

**Quote (Task 9.3 line 635):**
> ```bash
> [ "${#BASE_DIGEST}" -eq 64 ] && [ -z "${BASE_DIGEST//[0-9a-f]/}" ] || ...
> ```

**The problem:** Independent of CHARGE 1's prefix issue, the charset is `[0-9a-f]` (lowercase only). SHA-256 digests are conventionally lowercase, and `docker/build-push-action`'s current behavior produces lowercase. But the OCI spec and the Docker engine accept any case for hex in digest references. If a future Buildx version (or a different client in a hand-run scenario) capitalizes any character, the check rejects valid input.

This is a forward-compatibility concern, not a present bug. But once CHARGE 1 is fixed and the check actually runs, the strictness of the case check becomes load-bearing.

**Why it matters:** Defense-in-depth checks should err on the side of accepting all valid inputs. A strict-too-strict check transforms a backstop into a tripwire.

**The question that must be answered:** Is there a guarantee that `docker/build-push-action@v7` only outputs lowercase digest strings? If yes, cite the source. If no, widen the charset.

**Remediation:** Use `[0-9a-fA-F]` (case-insensitive hex) in the charset substitution. Zero cost; closes the seam.

---

### CHARGE 6 — Pass-2 findings list claims "8/8 actionable resolved" but Charge 9 of Pass 2 is incompletely resolved

**Quote (Pass 2 findings addressed, line 162):**
> **P2-Charge 9 — quality-gate mitigation overstated.** Resolved by qualifying language in Pre-#137 risk acceptance preamble: "(b) ... advisory unless required by branch protection." Verification of dogfood repo's branch protection rules deferred to PR review (Task 13.2).

**Quote (Pre-#137 risk acceptance, line 177):**
> (b) `claude-pr-review/quality-gate` automated review status (advisory unless required by branch protection — verify the dogfood repo's `main` ruleset at PR review time per Task 13.2; if not required, this mitigation is aspirational and #137 closure is more urgent)

**The problem:** Pass 2's Charge 9 asked whether the quality gate is actually a required status check. The plan's resolution defers the verification to PR review (Task 13.2). But Task 13.2 says only:
> Wait for the dogfood `pr-review` workflow + the new `claude-pr-review/quality-gate` status (PR #179 / Issue #176 — released as `v2.1.0`). The quality gate will fail if the bot review surfaces Critical/MAJOR markers; address per `gh-pr-review-address` skill.

Task 13.2 watches the gate fire — it does NOT verify the gate is in the branch protection ruleset. The resolution claim is "deferred to PR review," but PR review as defined doesn't include the verification. The mitigation is therefore not just qualified; it's unverified, and the verification step is unscoped.

**Why it matters:** Marking a finding "resolved" when the resolution is "we'll check later" without naming the check is documentation drift — exactly the over-claim the dispatch asks Pass 3 to look for. Either the check happens before merge (and is named), or the finding is not resolved.

**The question that must be answered:** Where in the plan does someone actually run `gh api repos/glitchwerks/github-actions/branches/main/protection` and act on the result?

**Remediation:** Add to Task 13.2 (or a new 13.2a): "Run `gh api repos/glitchwerks/github-actions/branches/main/protection --jq '.required_status_checks.checks[].context'` and confirm `claude-pr-review/quality-gate` is present. If absent, file a Phase 6 follow-up issue to require it; do NOT block this PR's merge on it (because adding required status checks is owner-only)." This converts "deferred to PR review" into a concrete step.

---

## OUT-OF-SCOPE

### OOS-1 — `needs:` skip-on-failure semantics binding to GHA documented behavior

**Quote (Task 11.6 (c)):**
> (c) **By citation, not empirical:** GitHub Actions documents that a downstream job with `needs: <upstream>` and no `if:` clause is **skipped** when `<upstream>.result == failure`...

The plan accepted documentation-citation as evidence for (c). GHA's `needs:` semantics are stable, and the citation is fine. The dispatch suggested adding a "verify on GHA changelog before Phase 6" todo. That's a reasonable hygiene item but does not block this plan; tracked as a Phase 6 input. No changes required to Phase 3.

---

## Cross-section consistency check

I read the full plan and looked for internal contradictions:

- **Plugin Truth Table vs Tasks 7.A/B/C:** Truth table says review's `must_contain.plugins` is `context7, github, typescript-lsp, security-guidance, pr-review-toolkit` (5 entries); Task 7.A's expected.yaml lists exactly those 5. Match.
- **Truth table's "skill-creator on disk" for fix/explain vs `must_not_contain.plugins: [pr-review-toolkit]`:** Truth table is consistent with Task 7.B/C content. Match.
- **Spec amendments §4.2, §5.1, §10.2:** Tasks 12.4, 12.5, 12.6 each scope to a different section; the §4.2 amendment text in Task 12.6 explicitly disclaims interaction with `subtract_from_shared`, which is exactly what §5.1 documents. Internally consistent.
- **§10.2 footnote in Task 12.4:** Removes `microsoft-docs` from the example. The dispatch asked whether other §10.2 examples would now be inconsistent. Task 12.4 only removes one example entry; the spec text around it is unaffected. The footnote is self-explanatory. Not a finding.
- **Pass-1 findings addressed list:** all 15 items name resolution paths in the current revision — no orphans.
- **Pass-2 findings addressed list:** 8/8 actionable claim is over-stated by half (CHARGE 6 above) but the other 7 are accurately resolved.

No additional contradictions found beyond the charges above.

---

## Verdict

The plan is NOT ship-ready. **Two CRITICAL items must be addressed before Tasks 4+ proceed.**

CHARGE 1 (`BASE_DIGEST` length check) is the highest-impact finding of any of the three passes — STAGE 3 hard-fails on every run as written, both because of the prefix mismatch in the validator and because the FROM line and `docker pull` consume the same variable as bare hex. CHARGE 2 (asymmetric Dockerfile charset glob) is a class-of-bug repeat: Pass 2 wrote a "second defense" that is strictly weaker than the "first defense" in a way that defeats the layered-defense rationale. Both are direct contradictions inside Pass 2's own remediation snippets.

CHARGES 3 and 4 are HIGH-PRIORITY: a clone-drift assertion gap (STAGE 2 ↔ STAGE 1c-determinism is not asserted) and an unscoped recovery procedure for the clone-drift error. CHARGE 5 (lowercase-only charset) and CHARGE 6 (Pass-2 finding marked resolved but the resolution is unscoped) are MEDIUM but easy.

The convergence the plan author predicted did not fully arrive. Pass 2 found 7 critical/high-priority items; Pass 3 finds 4. The slope is flatter but not flat. The encouraging signal: every CHARGE 1–6 item is mechanical to fix (one line of bash, one new job output, one clarifying paragraph). None require redesign. A Pass 4 is unlikely to find more critical items IF the two CRITICAL fixes are made cleanly and the high-priority items are addressed without introducing new asymmetries.
