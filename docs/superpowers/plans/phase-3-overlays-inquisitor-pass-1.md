# Phase 3 Overlays — Inquisitor Pass 1

**Plan under review:** `docs/superpowers/plans/phase-3-overlays.md`
**Reviewer mode:** adversarial; goal is to find ways the matcher silently passes when it shouldn't, ways CI ships a broken image, and ways the rollback story breaks under the rules as written.
**Date:** 2026-05-02

The plan is internally consistent and most of the matcher charges the author wrote are well-targeted. It is also riddled with gaps — the matcher contract is under-specified, the cache key is *visibly* wrong on at least one of the eight charges, the deliberate-regression test design demonstrably tests the wrong thing, and several of the `expected.yaml` contents in Task 7 will fail STAGE 4 on first run for reasons the plan has already half-acknowledged but not corrected.

---

## CRITICAL (BLOCKING)

### CHARGE 1 — Cache-key tuple in Task 9.3 is missing both the script that writes the image and the smoke contract — image cannot be safely promoted from a stale cache

**Quote (Task 9.3):**
> **`SMOKE_HASH` and `INVENTORY_MATCH_HASH` excluded** — those scripts run *against* the image during STAGE 4, not *into* the image during build. Cache busts on smoke contract changes are not needed at the image-build cache layer; STAGE 4 always runs against the freshly-built image.

This is half-right and half-wrong, and the wrong half is dangerous. STAGE 4 *does* re-run, so excluding `SMOKE_HASH` from the build cache is fine. But:

- **`enumerate-persona.sh` is also excluded** from the tuple. The plan does not list it. `enumerate-persona.sh` runs against the image at smoke time but its output is the load-bearing input to `inventory-match.sh`. If the enumeration rules change (e.g. to fix the skill-detection bug — see Charge 4) but the image is cache-hit on a stale build, the *image* doesn't change but the *interpretation* of the image does. That's actually correct — we want behaviour change to come from the matcher side. Acceptable.
- **`runtime/base/Dockerfile` is excluded.** Stage 2's cache key already covers it, but Phase 2's `DOCKERFILE_HASH` covers the *base* Dockerfile, not the overlay Dockerfile. The Phase 3 tuple lists `OVERLAY_DOCKERFILE_HASH` only — fine.
- **The `BASE_DIGEST` is in the tuple.** Charge 6 in the author's mandate is about whether base-changes-but-overlay-tree-doesn't bust the cache. Yes, `BASE_DIGEST` is in the cache key, so a new base digest produces a new cache scope. **But the cache key is computed at the start of STAGE 3 from `needs.stage-2.outputs.base_digest`** — which means the *cache scope* changes when the base changes. That is the right answer for charge 6. **However**, the plan never specifies how Buildx itself sees the FROM line: `FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}` is a build-arg interpolation. **Build args do not invalidate Buildx layer cache by default for `FROM` lines.** Even with `cache-to: type=gha,mode=max,scope=...`, if the FROM resolves the same image, Buildx may consider the underlying layers unchanged. The cache scope key prevents *cross-base reuse*, but a single `cache-to` write at a stale base digest is reusable on subsequent builds at the *correct* digest because the manifest layers are content-addressed. This is probably OK in practice. **Verify** by running the dry-run with `docker buildx du --verbose` after each cell, or just accept that the cache scope is the safety net.

**Why it matters:** Charge 6 is one of the named eight. The plan handwaves through it with "Cache-key tuple should prevent — verify." It does prevent it, but only because the cache *scope* string contains the digest. That answer needs to be in the plan, not handed off to the inquisitor.

**The question that must be answered:** Does the `cache-from`/`cache-to` `scope=overlay-${{ matrix.overlay }}-${{ key }}` string contain `BASE_DIGEST` either directly or transitively via `key`? If yes, name it explicitly. If no, name the failure mode.

**Remediation:** Add to Task 9.3:

> The Buildx cache scope MUST be `overlay-${OVERLAY}-${KEY}`, where `${KEY}` includes `BASE_DIGEST:0:12`. This ensures a base digest change starts a fresh cache scope. The FROM line's `@sha256:${BASE_DIGEST}` build-arg interpolation is NOT a sufficient cache-buster on its own — Buildx layer-content addressing means a cache write under one digest may be reused under another if the layers happen to match. Cache-scope isolation per base digest is the only reliable mechanism.

---

### CHARGE 2 — Task 11.4 deliberate-regression test is structurally broken — it cannot pass for the reason claimed

**Quote (Task 11.4):**
> **Second deliberate regression**: edit `runtime/overlays/fix/expected.yaml` to remove `inquisitor` from `must_not_contain.agents`, then edit `extract-overlay.sh` to also import `inquisitor` for the fix overlay. Push. Confirm STAGE 4-overlay `fix` cell fails with `ERROR inventory_must_not_contain_present kind=agents name=inquisitor`. Revert both.

Read this carefully. The test:

1. Removes `inquisitor` from `must_not_contain.agents`
2. Adds `inquisitor` to the fix overlay's actual contents
3. Expects the matcher to fail with `ERROR inventory_must_not_contain_present kind=agents name=inquisitor`

But step 1 *removed* `inquisitor` from `must_not_contain` — so the matcher will not check for it, and will not emit that error. The matcher will pass clean. The test is broken: it tests the opposite of what it claims to test.

The author mandate's charge 8 is literally "Is the deliberate-regression test (Task 11.3) actually testing what it claims, or could it pass for the wrong reason?" — the author asked for this scrutiny on 11.3 but missed it on 11.4.

**Why it matters:** Acceptance criterion 3 ("each `expected.yaml` negative assertion catches at least one intentional regression") is verified by Task 11.4. As written, Task 11.4 cannot exercise the negative assertion. The acceptance criterion will appear to pass because STAGE 4 will go green, but it will go green silently — exactly the failure mode the assertion is supposed to prevent.

**The question that must be answered:** What two file edits, performed simultaneously, will cause `inventory-match.sh` to print `ERROR inventory_must_not_contain_present kind=agents name=inquisitor` and exit 1?

**Remediation:** Replace Task 11.4 with:

> Edit `runtime/scripts/extract-overlay.sh` so that the `fix` overlay also imports `inquisitor` from private. Do NOT edit `expected.yaml`. Push. Confirm STAGE 4-overlay `fix` cell fails with `ERROR inventory_must_not_contain_present kind=agents name=inquisitor`. Revert.

The matcher catches the regression because `inquisitor` is in `must_not_contain.agents` AND now appears in the enumeration. That's the path the test must exercise.

Then add a separate Task 11.4b that exercises the *symmetric* failure for `explain` (which currently has no Task 11 coverage at all): edit explain's `expected.yaml` to add a name to `must_contain.agents` that is not actually in the overlay tree, push, confirm `ERROR inventory_must_contain_missing kind=agents name=<x>`. Revert.

---

### CHARGE 3 — `expected.yaml` content in Tasks 7.B and 7.C is wrong against the manifest reality, will fail STAGE 4 on first run

**Quote (Task 7.B):**
> ```yaml
> must_contain:
>   agents: [debugger, code-writer]
>   skills: [git]
>   plugins: [context7, github, typescript-lsp, security-guidance]
> ```

**Manifest reality** (`runtime/ci-manifest.yaml`):
- `shared.plugins.skill-creator.paths: ["**"]` — `skill-creator` IS in the base. Its absence from `must_contain.plugins` for fix is acceptable (must_contain is a positive minimum, not a complete list), but its absence from `must_not_contain.plugins` for fix means **the fix overlay carries `skill-creator`**. That is fine for the matcher, but the plan should be explicit that fix inherits skill-creator from base.
- `shared.imports_from_private.agents: [ops]` — `ops` IS in base, therefore in fix. Fix's `must_contain.agents` lists only `[debugger, code-writer]`. Again, acceptable as a minimum, but Task 7.C explicitly says (Note on `must_contain.agents`) that explain should add `[ops]` after dry-run validation. **Why is fix not held to the same standard?** Inconsistency.
- **`security-guidance` is P2 (cherry-pick)** — its `paths` are `[hooks/hooks.json, hooks/security_reminder_hook.py]`, not `["**"]`. The materialized tree at `/opt/claude/.claude/plugins/security-guidance/` exists, but its directory contains only those two files. The proposed `enumerate-persona.sh` rule for plugins says: "any file under `/opt/claude/.claude/plugins/<name>/` → name is the directory name. Same dedup approach as skills." So security-guidance will appear in the plugins enumeration. OK, but the plan never validates this — the dry-run is the first place it would be discovered.
- **`skill-creator` is P1** in base → present in all three overlays. Explain's `must_not_contain.plugins: [pr-review-toolkit]` does NOT name skill-creator. That is fine (skill-creator is welcome on explain). But review's `must_not_contain.plugins: [skill-creator]` (from spec §10.2 verbatim) MEANS THE REVIEW OVERLAY MUST EXPLICITLY DROP skill-creator. The plan does not say where this drop happens. There is no step in `extract-overlay.sh` that subtracts a plugin that the base inherited. **The review overlay will inherit skill-creator from base via the FROM line, and inventory-match.sh will fail** with `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`.

**Why it matters:** Task 11 dry-run will fail on review. The plan calls this out indirectly in Task 11.2 ("the most likely failure modes... `microsoft-docs` absence") but does not call out the skill-creator inheritance problem at all. Either the spec §10.2 example is wrong about skill-creator-on-review, or the implementation needs a way to subtract a base plugin in an overlay. There is no third option.

**The question that must be answered:** How does the review overlay end up *without* skill-creator on `/opt/claude/.claude/plugins/skill-creator/` when its base image has it baked in? Does `extract-overlay.sh` `rm -rf` it? Is the spec wrong? Document the choice.

**Remediation:** Add to Task 5 (`extract-overlay.sh`):

> The script MUST also process an `overlays.<verb>.subtract_from_shared.plugins` field (manifest extension required) which lists plugin names to `rm -rf` from the inherited base tree at overlay build time. The review overlay MUST list `skill-creator` here per §10.2's `must_not_contain`.

OR amend Task 7.A to remove `skill-creator` from review's `must_not_contain.plugins` (and document the spec amendment). Either is acceptable — silently shipping a review image with `skill-creator` while the spec says it shouldn't have one is not.

---

### CHARGE 4 — `enumerate-persona.sh` skill-detection rule is fragile against zero-file directories and silently empty plugin trees

**Quote (Task 2.1):**
> `skills`: any directory matching `/opt/claude/.claude/skills/<name>/` (detected by ≥1 file under it) → name is the directory name. Skills are directories of files (`SKILL.md` + helpers); enumerating by listing all directories with at least one file under them avoids duplicating skill names.
> `plugins`: any file under `/opt/claude/.claude/plugins/<name>/` → name is the directory name.

The rule "enumerate by `find -type f` then derive the parent directory" has two failure modes:

1. **Zero-file skill/plugin directories.** A skill's tree could legitimately have only subdirectories (e.g. `skills/foo/templates/...` with all real files in subdirs but no top-level file). The rule "≥1 file under it" via `find -type f` does include those — `find /opt/claude/.claude/skills -type f` returns deep paths and the parent extraction needs to walk back to the level-1 directory. The plan does not specify the parent-walking logic. If the rule is "first path component after `skills/`", a deeply nested skill `skills/foo/bar/baz.md` correctly yields `foo`. But the plan never states this rule.

2. **The "find succeeded but produced zero output" case** (the author's charge 3) is genuinely silent. `find /opt/claude/.claude -type f` exits 0 with empty output if the tree is missing. `enumerate-persona.sh` would emit `{agents: [], skills: [], plugins: []}`. `inventory-match.sh` would then emit `ERROR inventory_must_contain_missing` for every `must_contain` entry — but only because the comparison fails. There is no separate check for "the enumeration is suspiciously empty." Compare to Phase 2's `smoke-test.sh:88-93` which explicitly checks `if [ "$agent_count" = "0" ] || ... ; then ERROR empty_persona`. **`enumerate-persona.sh` proposed in the plan does not include this guard.**

**Why it matters:** The whole point of the matcher is to refuse to ship a broken image. If `find` produces zero output (mounted-volume issue, image corruption, wrong path), the failure mode is "all `must_contain` entries report missing" — many error lines, all with the same root cause, masking the real bug. Better: explicit `enumeration_empty` error when total file count is zero.

**The question that must be answered:** What does `enumerate-persona.sh` do when `find /opt/claude/.claude -type f` produces zero lines? What does it do when the tree exists but `agents/`, `skills/`, and `plugins/` are all empty subdirs? Specify both behaviours.

**Remediation:** Add to Task 2.1:

> If the file listing from `find /opt/claude/.claude -type f` is empty (zero lines), emit `ERROR enumeration_empty image=<ref>` to stderr and exit 1. If the listing is non-empty but all three of `agents/`, `skills/`, `plugins/` produce zero names, emit `ERROR enumeration_no_persona image=<ref> agents=0 skills=0 plugins=0` and exit 1. Mirror smoke-test.sh's existing empty-persona guard.

> Skill name extraction: for every line matching `^/opt/claude/\.claude/skills/([^/]+)/`, the captured group is the skill name. Plugin name extraction: same shape against `plugins/`. Agent name extraction: lines matching `^/opt/claude/\.claude/agents/([^/]+)\.md$` → captured group. Sort | uniq. This is the exact regex contract — implement against it.

---

## HIGH-PRIORITY (MAJOR)

### CHARGE 5 — Empty `expected.yaml` and malformed-YAML behavior is hand-waved

**Author's mandate (charges 1, 2):**
> 1. Does the matcher exit 0 on an empty `expected.yaml`?
> 2. Can a malformed YAML in `expected.yaml` produce a silent no-op match instead of an explicit error?

**Quote (Task 2.2):**
> Parse `expected.yaml` into four arrays: `must_contain.{agents,skills,plugins}` and `must_not_contain.{agents,plugins}`. Missing keys default to empty arrays.

Under this rule, an empty `expected.yaml` (zero bytes, or just `# comment`, or `{}`) parses to all-empty arrays, the matcher iterates over zero entries on each, exits 0 with no stderr. **Silent green.** That is the worst possible behavior: it lets a Phase 3 owner ship an overlay whose inventory is unchecked.

The plan addresses malformed-YAML parsing partially: "if `expected.yaml` has any top-level key other than `must_contain` and `must_not_contain`, fail with `ERROR expected_yaml_unknown_top_level_key`." But:

- An empty file has no top-level keys at all — passes that check.
- `yq -r '.must_contain.agents // [] | .[]'` on an empty file produces empty output. No error.
- A truly malformed file (broken indentation, unclosed string) fails the `yq` invocation with a non-zero exit, which under `set -e` would crash the script — but `set -e` interactions with `<(yq ...)` process substitution are tricky (see Charge 6).

**Why it matters:** Acceptance criterion: an `expected.yaml` that is silently empty must not pass STAGE 4. Today's contract says it does.

**The question that must be answered:** What is the matcher's defined behaviour for: (a) zero-byte file, (b) `{}`, (c) `must_contain: {}`, (d) `must_contain: null`, (e) malformed YAML that fails `yq`? Specify each.

**Remediation:** Add to Task 2.2:

> The matcher MUST exit 1 with `ERROR expected_yaml_empty file=<path>` if neither `must_contain` nor `must_not_contain` is present as a top-level key. The matcher MUST exit 1 with `ERROR expected_yaml_no_assertions file=<path>` if both are present but every kind-array within them is empty (sum of all six array lengths == 0). The matcher MUST exit 2 (distinct from violation exit 1) with `ERROR expected_yaml_parse_failed file=<path>` if `yq` returns non-zero on the input.

Add a new fixture case `enumeration-empty-expected.yaml` (zero bytes) to `tests/expected-matcher-fixture/` and assert exit 1. Add `enumeration-malformed-expected.yaml` (broken syntax) and assert exit 2.

---

### CHARGE 6 — "Report all violations before exiting" + bash `set -e` + `while IFS= read -r` over `<(yq ...)` is a known footgun

**Quote (Task 2.2):**
> 4. **Report ALL violations before exiting** (do not short-circuit). Per the matcher contract in `smoke-test.sh:144`.

The contract is right; the implementation ergonomics are tricky in bash. Phase 2's `extract-shared.sh` already uses the pattern: an `errs` counter, an `err()` function that increments, and a final `if [ "$errs" -gt 0 ]; then exit 1; fi`. The plan does not specify this for `inventory-match.sh`. Subtleties:

- `set -e` (which Phase 2's extract-shared.sh deliberately omits — `set -uo pipefail` only) would short-circuit on the first violation if the violation path uses `[ "$x" = "$y" ] || err ...`. The plan says nothing about which `set -*` flags to use.
- `while read -r ...; do ... done < <(yq ...)` runs the loop body in the parent shell (good — variables persist) but if `yq` fails inside the process substitution, the consumer sees an empty stream and `set -e` does NOT trigger because process substitution exit codes are not propagated.
- Counting violations requires the body to *not* exit; the obvious mistake is `[ "$ok" = true ] || { echo ERROR...; exit 1; }` instead of `... || ((errs++))`.

**Why it matters:** Phase 2's two-pass inquisitor caught a similar class-of-bug in `smoke-test.sh` (`--entrypoint` silent-false-pass). Bash error-handling around process substitution and counters is exactly the surface where pass-1 misses things and pass-2 catches them.

**The question that must be answered:** What flags does `inventory-match.sh` set at the top? (`set -euo pipefail`? `set -uo pipefail`?) When `yq` fails on a corrupt expected.yaml inside `done < <(yq ...)`, what does the script do? When `jq` fails on a corrupt JSON enumeration, what does it do?

**Remediation:** Specify in Task 2.2:

> Script header: `set -uo pipefail` (NOT `set -e` — incompatible with the all-violations-before-exit contract). All `yq` and `jq` invocations that feed `done < <(...)` loops MUST be preceded by an explicit pre-validation step: `yq eval '.' "$EXPECTED_FILE" >/dev/null 2>&1 || { echo "ERROR expected_yaml_parse_failed file=$EXPECTED_FILE" >&2; exit 2; }`. Same for `jq -e . "$JSON_FILE" >/dev/null` on the enumeration JSON. Only after both pre-validations pass do the iteration loops run.

---

### CHARGE 7 — R6 hash assertion does not specify how `expected.yaml` is `COPY`d, so CRLF/LF and trailing-newline drift is real

**Quote (Task 5.2):**
> after build, run a one-shot `docker run --rm --entrypoint /bin/sh "$STAGED_IMAGE" -c 'sha256sum /opt/claude/.expected.yaml'` and compare to `sha256sum runtime/overlays/<verb>/expected.yaml`. Mismatch → fail STAGE 3 cell with `ERROR expected_yaml_image_hash_mismatch overlay=<verb>`.

**Quote (Task 11.2):**
> R6 hash assertion failing — typically a CRLF-vs-LF issue if anyone edits expected.yaml on Windows. Fix encoding.

The plan is aware of the CRLF risk and dismisses it as "typically... fix encoding." That is not a fix — that is a defect waiting to happen. The runner is Linux, the source files come from `actions/checkout` which honors `core.autocrlf` settings. If a Windows author commits with CRLF and the repo has `.gitattributes` enforcing LF, checkout normalizes to LF and hashes match. If the repo does NOT enforce LF on `.yaml`, the file lands with CRLF on a runner that wrote the in-image file via `COPY`, which preserves bytes — hashes match (both have CRLF). **Where the drift happens** is the R6 *consumer-side* read in Phase 6: a forensic operator on macOS/Linux who downloads `expected.yaml` to compare against on-disk source-tree contents will see a hash mismatch if the operator's git client has `core.autocrlf` on. That is the LF/CRLF defect the author is gesturing at, but it lives in Phase 6, not Phase 3. The Phase 3 build-time hash assertion is fine **if** the source-tree file and the COPY'd file have identical bytes — which Docker `COPY` guarantees on the same runner.

**However:** the plan does not specify a `.gitattributes` rule. Without one:

- A CRLF expected.yaml works fine in Phase 3 (matches itself).
- The R6 consumer in Phase 6 is bitten.
- **A trailing-newline drift** (vim adds final `\n`, VSCode-on-Windows might not) causes Phase 3 hash mismatch *only if* an editor without trailing-newline was used to author the file and the build context preserves it. Docker `COPY` preserves bytes, so the hash matches. But if a maintainer ever runs `dos2unix` or `git config core.autocrlf input` differently between author and verifier, drift appears.

**Why it matters:** The plan claims R6 enables "Phase 6 forensic post-promotion verification... without going back to the source git tree at the matching SHA" — but that whole value proposition assumes hashing the in-image file matches hashing the source-tree file. If the source-tree file has been re-checked-out under a different `core.autocrlf` setting, the hash differs and forensic verification is broken. The "trade-off" mitigation in Deviation #6 says "STAGE 3 build-time hash-asserts the in-image file matches the source-tree file" — but that hash assertion happens once, on the build runner. It does not cover the consumer-side read.

**The question that must be answered:** Is `runtime/overlays/*/expected.yaml` covered by a `.gitattributes` rule pinning line endings to LF? If not, what does Phase 6 do when the consumer's git client normalizes differently?

**Remediation:** Add to Task 7.D:

> Commit a `.gitattributes` rule: `runtime/overlays/*/expected.yaml text eol=lf` — pins line endings to LF for all consumers. This guarantees R6 hash agreement across platforms.

Also: in Task 5.2, before computing the hash, run `file "$EXPECTED_FILE" | grep -q CRLF && { echo "ERROR expected_yaml_has_crlf file=$EXPECTED_FILE" >&2; exit 1; }` so that a CRLF file fails the build at STAGE 3, not silently propagates.

---

### CHARGE 8 — `fail-fast: false + continue-on-error: false` does NOT do what Deviation #9 claims for STAGE 5 gating

**Quote (Deviation #9):**
> if `review` fails its smoke, don't auto-cancel `fix` and `explain` (we want to see all three failure modes in one run), but still fail the overall STAGE 3 job so STAGE 5 promote never runs. §9.1 requires "one overlay failing blocks ALL promotion" — that's enforced by the job-level fail, not by cell-level fail-fast.

This is correct *for STAGE 3 itself*. But the plan does not specify how STAGE 5 (Phase 6) consumes STAGE 3's outputs. The relevant question: **does STAGE 5 use `needs: [stage-4-overlay]` with no `if` clause, or does it use `if: needs.stage-4-overlay.result == 'success'`?** Default GHA behavior is that `needs: [job-name]` skips the dependent job if the upstream failed — so STAGE 5 would skip on review failure. Good. But:

- If STAGE 5 uses `if: always()` to (e.g.) post a comment with the failure list, and it has any side-effecting step in that block, "one overlay failing blocks ALL promotion" can be defeated by a misconfigured `if` clause. The plan does not specify Phase 6's `if` rules.
- More importantly: with `fail-fast: false` and a 3-cell matrix, GitHub reports the matrix as a single "stage-3-overlay" job with mixed status. Downstream `needs:` evaluates `needs.stage-3-overlay.result` — when one cell fails and two succeed, the result is `failure` (matrix overall fails if any cell fails). That's what the plan wants. So the gating works, *if* downstream uses `needs:`.

**Why it matters:** Charge 7 of the author's mandate is "Does the fix overlay's `must_not_contain` actually catch all four 'wrong agent' cases" — not relevant to this issue. But the gating issue is broader: §9.1 says "one overlay failing blocks ALL promotion." The plan asserts this is enforced. Without seeing Phase 6's `runtime/promote.yml` (which doesn't exist yet), we cannot verify the assertion. **Phase 3 needs a sentinel test that confirms the gating is real.**

**The question that must be answered:** When STAGE 4-overlay's `review` cell exits 1, what is the `result` of the `stage-4-overlay` matrix job? What is the `result` of any downstream `needs: stage-4-overlay` job? Add a CI sanity assertion that confirms this empirically *before* Phase 6 work begins.

**Remediation:** Add to Task 11:

> Task 11.6 — gate sanity check. After Task 11.3's deliberate-regression run (review fails), inspect the run log for: (a) `fix` and `explain` cells did run to completion (not cancelled), (b) STAGE 4-overlay job-level result is `failure`, (c) any downstream job with `needs: stage-4-overlay` and no `if: always()` did NOT run. Capture screenshots or log excerpts as evidence. This validates the §9.1 gating empirically.

---

### CHARGE 9 — `microsoft-docs` reconciliation is incomplete; fix's `must_contain.plugins` will fail for a different reason

**Quote (Task 7.A):**
> **Pre-decision:** option (a) — reflect the post-Phase-2 reality. Spec amendment is a doc-only follow-up.

Fine for review — the plan removes `microsoft-docs`. But:

**Quote (Task 7.B fix `expected.yaml`):**
> ```yaml
>   plugins: [context7, github, typescript-lsp, security-guidance]   # base set, minus microsoft-docs (per 7.A); minus skill-creator (review-only must_not_contain says skill-creator absent — confirm at dry-run that it's absent from BASE's materialized tree as well)
> ```

The inline comment is wrong on its face. `skill-creator` IS in the base materialized tree (`shared.plugins.skill-creator.paths: ["**"]`). The fix overlay inherits it. The `must_contain` list is the *minimum* — it is fine to omit skill-creator from `must_contain`. But the comment says `minus skill-creator (review-only must_not_contain says skill-creator absent — confirm at dry-run that it's absent from BASE's materialized tree as well)`. The comment is conflating two different things: (a) what fix's `must_contain` declares (a minimum), and (b) whether skill-creator is in the base. The comment's premise is wrong.

**Why it matters:** A maintainer reading this comment will be confused into thinking skill-creator is somehow excluded from base. It is not. The fix overlay carries it, and that's fine. But the spec §10.2 example for **review** says `must_not_contain.plugins: [skill-creator]` — and the plan does not address how review will be made compliant (see Charge 3).

**The question that must be answered:** State plainly: which plugins does each overlay carry, and which does each overlay's `expected.yaml` make claims about? A 3×4 table covering review, fix, explain × must_contain.plugins, must_not_contain.plugins.

**Remediation:** Add a "Plugin truth table" to the plan's preamble:

| Overlay | Plugins carried (post-build, on disk) | `must_contain.plugins` (positive minimum) | `must_not_contain.plugins` (forbidden) |
|---|---|---|---|
| review | context7, github, typescript-lsp, skill-creator¹, security-guidance, pr-review-toolkit | context7, github, typescript-lsp, security-guidance, pr-review-toolkit | skill-creator |
| fix | context7, github, typescript-lsp, skill-creator, security-guidance | context7, github, typescript-lsp, security-guidance | pr-review-toolkit |
| explain | context7, github, typescript-lsp, skill-creator, security-guidance | context7, github, typescript-lsp, security-guidance | pr-review-toolkit |

¹ — review must drop skill-creator at overlay build time per Charge 3. Document the mechanism.

---

## MEDIUM / LOWER-PRIORITY

### CHARGE 10 — Task 13.3/13.4 inquisitor passes are wired in *after* the implementation lands

**Quote (Task 13.3, 13.4):**
> **Inquisitor pass 1** — invoke `inquisitor` agent against this plan + the implementation. Address findings on-branch.
> **Inquisitor pass 2** — second adversarial pass after pass 1's revisions land.

The bottom of the plan says: "After pass 2's revisions land in this file, this plan is greenlit for execution. Until both passes are recorded as complete (with findings either addressed or explicitly accepted as out-of-scope) in this document, no Task 4+ work begins."

Two contradictory statements. The bottom says pass-2 gates Task 4+. Task 13.3 places pass-1 *after* implementation has shipped. Which is it? The `feedback_inquisitor_twice_for_large_design.md` rule (per the prompt context) says two passes BEFORE implementation. The plan inverts this for tasks 1–12.

**Why it matters:** The whole point of inquisitor-twice-for-large-design is to find class-of-bug findings (like the ones in this report) before code is written. If the passes happen at PR review time, you've burned a week of implementation on a flawed plan.

**Remediation:** Insert a hard checkpoint: "Tasks 1–12 do not begin until pass 1 and pass 2 findings are addressed in this file." Move 13.3 and 13.4 to between Task 0 and Task 1, label them "pass 1 (this document)" and "pass 2 (this document, post-pass-1 revisions)". Keep PR-time review separate as task 13.5/13.6 if desired.

---

### CHARGE 11 — `dev.glitchwerks.ci.cli_version=""` empty-string label is silently degraded R5

**Quote (Task 4.1):**
> `cli_version` is empty in the overlay's labels because the binary is inherited from the base — the base's label is the source of truth... **Decision:** keep the label, set it empty, document that "to learn the CLI version, read the base image's `dev.glitchwerks.ci.cli_version` label."

Phase 2's `smoke-test.sh:181` checks for empty labels:
```
v=$(printf '%s' "$LABELS_JSON" | jq -r --arg k "$label" '.[$k] // empty')
if [ -z "$v" ]; then
  echo "ERROR label_missing image=$IMAGE label=$label" >&2
```

The smoke test will fail on overlay images because `cli_version` is empty. The plan says (Task 8.1) "label-completeness check (Phase 2 helper extended in Task 7)" — so the helper has to be extended to either skip `cli_version` for overlays or accept empty-string as valid for that one label. Neither is documented in the plan.

**Why it matters:** Smoke fails on first run. R5 says "All present + non-empty." If we set cli_version empty, R5 is violated. Either fix R5's wording or set the label to base's value via build-arg.

**Remediation:** Pass `CLI_VERSION` as a build-arg to the overlay Dockerfiles (resolvable from the base image's labels via `docker inspect ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST} --format '{{ index .Config.Labels "dev.glitchwerks.ci.cli_version" }}'` in STAGE 3). Set the overlay label to that value. R5 is preserved without exception. The "alternative deferred" path the plan rejected is actually the correct path; the cost is one `docker inspect` per cell.

---

### CHARGE 12 — Determinism replay (STAGE 1c analog of STAGE 1b) is left as "consider"

**Quote (Task 5.1):**
> **Determinism:** same rules as `extract-shared.sh` — `LC_ALL=C` sort, `umask 022`, `touch -d @0` on every output file, no embedded timestamps. STAGE 1c can include a determinism replay analogous to Phase 2's STAGE 1b (consider whether worth the CI minutes — see Deviations #1 trade-off).

"Consider" is the wrong verb. The whole reason Phase 2 added STAGE 1b was that determinism is a cache-key prerequisite — non-deterministic output means cache misses on identical inputs, and worse, byte-for-byte reproducibility (a v2 goal in §10.4) is unprovable. Phase 3 adds three new overlay extractions, three new cache scopes, and pushes three images. Skipping determinism replay because of "CI minutes" is exactly the kind of polish-deferred decision that bites a year later when reproducibility is suddenly load-bearing for an audit.

**Remediation:** Make determinism replay mandatory in Task 9.1 STAGE 1c. Run `extract-overlay.sh` twice for each overlay, diff the trees. CI cost: ~10s per overlay × 3 overlays = trivial.

---

### CHARGE 13 — `must_contain.skills` for overlays does not cross-check that base actually carries them

**Quote (Tasks 7.A, 7.B, 7.C):**
> ```yaml
>   skills: [git]
> ```

All three overlays declare `must_contain.skills: [git]`. None declare `must_contain.skills: [python]` even though `python` is in `shared.imports_from_private.skills`. That is allowed — `must_contain` is a minimum. But it means a regression that drops `python` from the base would not be caught by any overlay's matcher. The base smoke (Phase 2's `smoke-test.sh:112`) does check for `python`:
```bash
if ! grep -q '^/opt/claude/\.claude/skills/python/' "$FILES_OUT"; then
  missing+=("/opt/claude/.claude/skills/python/<any file>")
```

So python regression is caught at base smoke. OK, not a bug — but the plan should make this redundancy explicit: "overlay `must_contain.skills` does not need to repeat base-smoke assertions; it asserts only overlay-introduced minima."

**Remediation:** Add to plan preamble:

> `expected.yaml` is the *overlay-specific* contract. Base-image content (e.g. `skills.python`, `agents.ops`) is mechanically asserted by `smoke-test.sh` against the base image and inherited by overlay images. Overlay `must_contain` declares only the verb-specific additions; overlay `must_not_contain` declares the verb-specific subtractions and forbidden inheritances.

Then revise Task 7.C's note about adding `[ops]` to explain's `must_contain.agents` — under the rule above, that addition is unnecessary noise. Remove it.

---

## OUT-OF-SCOPE BUT WORTH RECORDING

### CHARGE 14 — CODEOWNERS deferral is a critical assumption being absorbed without trade-off documentation

The plan acknowledges (Deferred items): "CODEOWNERS demonstration of 'different eyes' ownership split — task 3.12 in master plan, deferred to issue [#137](https://github.com/glitchwerks/github-actions/issues/137)." And in Deviation #4: "Inventory assertions still provide post-merge mechanical enforcement; pre-merge enforcement follows #137."

Spec §10.2 is unambiguous: "the 'different eyes' guarantee is not enforced by CI — it reduces to the same author writing both sides of the assertion. This must be enforced via branch protection or rulesets requiring CODEOWNERS review on protected paths." The spec's own wording calls the matcher-only mechanism a defeat-able guarantee. The plan ships the matcher and defers the CODEOWNERS rule, accepting the defeat-ability for an undefined window.

**The question that must be answered:** What is the timeline for #137? While #137 is open, what stops a single author from staging an overlay change + matching expected.yaml in one PR (the exact attack §10.2 names)?

**Remediation:** Add to plan preamble:

> **Pre-#137 risk acceptance:** Until issue #137 lands a CODEOWNERS split, a single author can write both an overlay change and its `expected.yaml`. The matcher mechanically enforces *consistency* (the two files agree) but cannot enforce *adversarial review* (a second pair of eyes). This is a known and accepted gap for the duration of #137; risk is mitigated by (a) the public PR review process, (b) `claude-pr-review/quality-gate` automated review, (c) the matcher's deliberate-regression tests in Task 11.

---

### CHARGE 15 — Token / secret usage in STAGE 4-overlay is not audited

The plan's STAGE 4-overlay (Task 8.2) calls `overlay-smoke.sh` which calls `smoke-test.sh` which requires `CLAUDE_CODE_OAUTH_TOKEN`. The smoke runs `claude --version` against the overlay image. **The OAuth token is presented to a model running with overlay-scoped persona.** For `review`, that includes inquisitor + pr-review-toolkit. The smoke is `--version` only, so the model doesn't actually do anything — but the secret still crosses the runtime boundary. The plan does not audit which overlays receive the token, nor scrub the secret-hygiene scan against state the overlay smoke might write.

Phase 2's smoke does the secret hygiene scan AFTER the CLI invocation — so if `claude --version` writes credentials anywhere under `/opt/claude/.claude/`, the scan catches it. But Phase 2's scan runs against the base image. Phase 3's overlay smoke needs the same scan, against the overlay image, after the CLI invocation. The plan implies this works because `overlay-smoke.sh` calls `smoke-test.sh` first — so the secret hygiene scan runs. But it runs on the *passed-in* image, which is the overlay. OK, this is actually fine. But it's not stated explicitly.

**Remediation:** Add to Task 3.1 (overlay-smoke.sh):

> The base smoke wrapper (step 1) executes `smoke-test.sh` against the overlay image (not against the base). This means Phase 2's secret-hygiene scan, R3 perms check, and label completeness check all execute against the overlay's filesystem state. No additional scan is needed in `overlay-smoke.sh`; the wrapper is purely an additive layer on top of base smoke.

---

## Verdict

This plan is **not ready for execution.** Charges 1–4 are blocking: the cache-key reasoning around base-digest invalidation is unspecified for the Buildx layer (Charge 1); Task 11.4 cannot fail in the way the plan claims and therefore does not satisfy acceptance criterion 3 (Charge 2); the review overlay's `must_not_contain.plugins: [skill-creator]` has no implementation path because nothing subtracts it from the base inheritance (Charge 3); and `enumerate-persona.sh` has no empty-output guard, recreating the exact "find succeeded but produced nothing" silent-pass class the author flagged in their own mandate (Charge 4). Charges 5–9 are major design flaws that will surface as red CI runs on the dry-run if the plan is executed as written. Charges 10–13 are correctness-affecting but recoverable. Address all blocking charges before any Task 4+ work; resolve majors before STAGE 4 is wired. The cli_version-empty-label collision (Charge 11) and the Task 11.4 logic inversion (Charge 2) in particular are visible from a careful re-read and should not have made it past the author's own self-review — flag this for pass 2 to confirm it doesn't recur in revisions.

🤖 _Generated by Claude Code on behalf of @cbeaulieu-gt_
