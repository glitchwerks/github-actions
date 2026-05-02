# Phase 3 Overlays — Inquisitor Pass 2

**Plan under review:** `docs/superpowers/plans/phase-3-overlays.md` (revised post-Pass-1, 645 lines)
**Reviewer charge:** find *new* gaps introduced by Pass 1's revisions — the class-of-bug analog of Phase 2 pass 2's `--entrypoint` silent-false-pass catch.
**Date:** 2026-05-02

The Pass 1 revisions did real work — the matcher contract is now defensible, the cache-scope spec names the load-bearing isolation mechanism, the deliberate-regression tests now exercise the assertion class they claim to. But the new mechanisms ship with new seams: `subtract_from_shared.plugins` is wired across four files (manifest, schema, extractor, Dockerfiles) and the consistency story across them is not airtight. The CRLF reject step has an order-of-operations bug. Task 11.4's rewrite reveals an ordering problem the plan does not name. There is at least one charge that, if not addressed, repeats the Pass 1 Charge 3 failure mode (silent-pass-where-fail-was-claimed) under different cover.

---

## CRITICAL (BLOCKING)

### CHARGE 1 — `subtract_from_shared.plugins` defeats `additionalProperties: false` AND collides with §4.2 `merge_policy.overrides`

**Quote (Deviation #10, Task 5.3):**
> Schema update — extend `runtime/ci-manifest.schema.json` to add the `overlays.<verb>.subtract_from_shared.plugins` field … Each name MUST be a key in `shared.plugins` (validated by `validate-manifest.sh` semantic check…)

**The problem:** The current schema (verified at `runtime/ci-manifest.schema.json:65-111`) declares `$defs/scope` with `"additionalProperties": false` AND lists exactly `imports_from_private`, `local`, `plugins` under `properties`. Adding `subtract_from_shared` as a fifth top-level key inside `$defs/scope` is straightforward — but `$defs/scope` is **shared between `shared` and `overlays.<verb>`**. The plan does not say whether `subtract_from_shared` is permitted on `shared` (it should not be — `shared` has nothing to subtract from). The schema as proposed is silent on this.

Worse: §4.2 of the spec defines a *separate* mechanism for path-level shadowing — `merge_policy.overrides`. The spec says (line 142): "Any path not listed in `overrides` that collides between `shared/` and `imports_from_private` halts the build." Subtraction is semantically a kind of override (an overlay declaring "I do not want what `shared` ships"), but the plan adds a parallel mechanism without reconciling it against `merge_policy.overrides`. If a future maintainer removes `skill-creator` from `shared.plugins` entirely, the review overlay's `subtract_from_shared.plugins: [skill-creator]` becomes a stale subtraction pointing at nothing. The schema validation Task 5.3 names ("each name MUST be a key in `shared.plugins`") catches that — but only at validate-manifest time, and only if the validator is actually wired. The plan does not show `validate-manifest.sh` being extended to call this check; it asserts the check should exist.

**Why it matters:** Two failure modes:
1. **Silent schema-acceptance on `shared.subtract_from_shared.plugins: [...]`** — a typo or copy-paste error puts the field at the wrong scope. `additionalProperties: false` rejects it only if `subtract_from_shared` is restricted to overlay scopes. The plan's "extend the schema" instruction does not specify this.
2. **`merge_policy.overrides` and `subtract_from_shared` interact ambiguously** — the spec says collisions between `shared/` and `imports_from_private` halt the build unless listed in `overrides`. Subtraction does not collide (the plugin is removed, not shadowed), but a reviewer reading the manifest will see two different mechanisms for "this overlay diverges from base" without a written rule for which to use when. The plan introduces the new field without amending §4.2 to say "subtraction is not a merge_policy concept."

**The question that must be answered:** (a) Is `subtract_from_shared` permitted at `shared` scope or only overlay scope? Schema must enforce the answer, not document it. (b) What is the documented relationship between `subtract_from_shared.plugins` and `merge_policy.overrides`? Spec §4.2 amendment is required, not just §5.1 (Task 12.5 only amends §5.1).

**Remediation:** Restructure Task 5.3 to introduce `$defs/overlay_scope` (extends `$defs/scope` with `subtract_from_shared`) and use it only for `overlays.<verb>` properties. Keep `shared` on the bare `$defs/scope`. Extend Task 12.5 to amend §4.2 with one paragraph: "Subtraction (`overlays.<verb>.subtract_from_shared.plugins`) operates on plugins inherited from `shared` via the FROM line; it is unrelated to `merge_policy.overrides`, which governs path-level collisions between `shared/` source files and `imports_from_private`. The two mechanisms do not interact."

---

### CHARGE 2 — Task 5.5 Dockerfile RUN step nukes a directory whose name came from an unvalidated marker filename

**Quote (Task 5.5):**
> ```dockerfile
> RUN if [ -d /opt/claude/.claude/.subtract/plugins ]; then \
>       for marker in /opt/claude/.claude/.subtract/plugins/*; do \
>         [ -e "$marker" ] || continue; \
>         plugin=$(basename "$marker"); \
>         echo "subtracting plugin: $plugin"; \
>         rm -rf "/opt/claude/.claude/plugins/$plugin"; \
>       done; \
>       rm -rf /opt/claude/.claude/.subtract; \
>     fi
> ```

**The problem:** The marker file is created by `extract-overlay.sh` (Task 5.1 Phase B step 3: "write a sentinel marker to `${OUT_DIR}/.subtract/plugins/<name>`"). The marker's filename IS the plugin name. The Dockerfile then derives the plugin name via `basename "$marker"` and `rm -rf`s `/opt/claude/.claude/plugins/$plugin`. There is no validation that `$plugin` is a sane plugin name. If a marker file slips through with name `..` or contains a slash, the resulting `rm -rf "/opt/claude/.claude/plugins/.."` walks above the intended scope. `basename` strips trailing slashes but does not reject `..`.

The defense the plan offers (Task 5.3 schema check: "Each name MUST be a key in `shared.plugins`") catches typos, but the schema validator runs at STAGE 1; the Dockerfile RUN step runs at STAGE 3. If a malicious or buggy `extract-overlay.sh` writes a marker with a name not in the manifest (e.g. someone hand-edits the script), the Dockerfile will trust it. This is not theoretical — the plan in Task 5.1 says "for each plugin name, write a sentinel marker" but never says **the script MUST reject names containing `/`, `..`, or whitespace** before writing markers.

A second issue: if `$plugin` ever becomes the empty string (e.g. a marker file named with only whitespace, or the glob expansion edge case), `rm -rf "/opt/claude/.claude/plugins/"` deletes ALL plugins. The `[ -e "$marker" ] || continue` does NOT guard against this — it guards only against the unexpanded glob `/opt/claude/.claude/.subtract/plugins/*` itself, not against a real marker file with a degenerate basename.

**Why it matters:** Phase 2 pass 2 caught the `--entrypoint` silent-false-pass — a class-of-bug born in Pass 1 revisions where the new mechanism's failure mode was unchecked. This is the same class. The marker-file design is sound; the Dockerfile's trust in the marker's filename is not. A `rm -rf /opt/claude/.claude/plugins/` from a degenerate marker would silently delete the entire plugins tree and STAGE 4 would fail with "all plugins missing" — but the root cause would be impossible to diagnose from the smoke logs alone.

**The question that must be answered:** What guarantees that `$plugin` derived from `basename "$marker"` is a non-empty string matching `^[a-z0-9-]+$` (or whatever the legal plugin-name charset is) before it's interpolated into `rm -rf`?

**Remediation:** Two defenses, both required:
1. In `extract-overlay.sh` Task 5.1 Phase B step 3, **before** writing each marker, validate the plugin name against `^[a-z0-9][a-z0-9-]*$` (mirroring marketplace plugin name conventions). Fail with `ERROR subtract_marker_invalid_name name=<x>` on mismatch.
2. In the Dockerfile RUN step, add an explicit defensive check: `case "$plugin" in ''|*/*|.|..) echo "FATAL invalid subtract marker: $plugin" >&2; exit 1;; esac` before the `rm -rf`. The Dockerfile MUST NOT trust the marker filename — it is a build-time input that could be malformed.

---

### CHARGE 3 — Task 5.5 Dockerfile RUN step ordering is unstated; layer position determines whether subtraction works at all

**Quote (Task 4.1, Task 5.5):**
> ```dockerfile
> # Materialized overlay tree (built by extract-overlay.sh in STAGE 3 — see Task 5)
> COPY overlay-tree/ /opt/claude/.claude/
>
> # Overlay-scoped CLAUDE.md replaces base shared CLAUDE.md (§3.4 layer 2)
> COPY CLAUDE.md /opt/claude/.claude/CLAUDE.md
>
> # Inventory contract on-disk for forensic verification (R6)
> COPY expected.yaml /opt/claude/.expected.yaml
>
> RUN chmod -R a+rX /opt/claude/.claude/ \
>  && chmod 0644 /opt/claude/.expected.yaml
> ```
> Task 5.5: amend each overlay Dockerfile … to include after the `COPY overlay-tree/` step:
> ```
> RUN if [ -d /opt/claude/.claude/.subtract/plugins ]; then ... fi
> ```

**The problem:** Task 5.5 says "after the `COPY overlay-tree/` step" but does not say **before or after the chmod RUN**. The order matters in two ways:

1. **Layer ordering for cache hits:** the chmod RUN currently runs once at the end and produces a single layer. If the subtract RUN is inserted between the COPY and the chmod, the chmod runs over a tree that includes `.subtract/` markers (which then get chmod'd, then the subtract RUN deletes the `.subtract` dir). If the subtract RUN runs after chmod, the deletion creates a layer that just removes files — harmless, but produces a different layer hash than the inverse order.

2. **R3 perms verification:** the chmod step is the mechanism that asserts R3 (`/opt/claude/.claude/` world-readable, dirs 0755 / files 0644). If subtract runs *after* chmod, the `rm -rf` doesn't add or remove any permission state, so R3 holds. If subtract runs *before* chmod, the `rm -rf` removes the `.subtract` dir which was just chmod'd — but the surviving plugin tree is then chmod'd. Either order yields the same on-disk state for the surviving files — but only because chmod is the LAST RUN. **If a future Phase reorders, the assumption breaks silently.**

3. **`.subtract` cleanup:** the Dockerfile RUN ends with `rm -rf /opt/claude/.claude/.subtract`. If chmod -R has already run on this directory, no harm. If chmod has not yet run, the `.subtract` directory exists in the image as an intermediate-layer artifact. Buildx layer-content addressing means that intermediate state is part of the layer hash even though the final image does not show it. This affects determinism replay (Task 9.1 STAGE 1c-determinism): two runs with identical inputs that produce identical *final* trees can produce different *intermediate-layer hashes* if the chmod-vs-subtract order is non-deterministic across the Dockerfile rewrite.

**Why it matters:** The plan does not pin the order. A code-writer implementing Task 4 + Task 5.5 has to guess. Two reasonable readings of "after the `COPY overlay-tree/` step" are: (a) immediately after the COPY, before the next COPY, or (b) anywhere in the Dockerfile after the COPY but before the final chmod, or (c) after the final chmod. Each yields different cache behavior and different intermediate-layer hashes.

**The question that must be answered:** Is the subtract RUN step before or after the `chmod -R a+rX` RUN? Specify exactly.

**Remediation:** Amend Task 4.1's Dockerfile snippet to inline the subtract RUN at a specific position. The correct position is **between `COPY overlay-tree/` and `chmod -R a+rX`** — this lets the chmod operate on the post-subtraction tree, ensuring R3 perms are asserted on what actually ships. Update Tasks 4.2 and 4.3 identically.

---

## HIGH-PRIORITY (MAJOR)

### CHARGE 4 — Task 11.4 deliberate-regression cannot run before Task 5 commits, but the plan has no ordering guard

**Quote (Task 11.4):**
> edit ONLY `runtime/scripts/extract-overlay.sh` to add `inquisitor` to fix's imports — i.e. when `OVERLAY=fix`, also copy `${PRIVATE_TREE}/agents/inquisitor.md` into the fix overlay tree. Do NOT edit `expected.yaml`. Push.

**The problem:** `extract-overlay.sh` does not exist until Task 5 lands. Task 11.4 is part of Task 11 (dry-run + deliberate regression), which the plan implicitly orders after Task 5 (the script is committed). But the **"Inquisitor passes (gate Tasks 4+)"** section near the top says "Tasks 1–3 (read Phase 2 contracts, author matcher + enumerator + wrapper) MAY begin in parallel with Pass 2." Task 5 is *not* in 1-3 and is gated by Pass 2. Fine in principle.

But Pass 1's rewrite of Task 11.4 introduces an additional dependency the plan does not name: **Task 11.4 requires `extract-overlay.sh` to be aware of an `OVERLAY=fix` branch with an `inquisitor` import**. Task 5.1 Phase A says the script reads `overlays.<OVERLAY>.imports_from_private.agents`. The deliberate-regression test edits the script, not the manifest. The plan implies the test edits the script's logic to short-circuit the manifest read. **That's a load-bearing assumption** — if a code-writer reading Task 11.4 interprets it as "edit the manifest's `overlays.fix.imports_from_private.agents` to add `inquisitor`," that's a different test that exercises the same matcher path but produces a different commit-revert pattern. The plan should specify which.

A second issue: Task 11.4's "Push" step assumes the dry-run pipeline triggers on push to the branch. If the runtime-build workflow's path filter is `runtime/**`, a push that only edits `extract-overlay.sh` triggers the build — fine. But if the plan ever extends the trigger to require `runtime/overlays/**`, the deliberate-regression edit to the script (in `runtime/scripts/`) would no longer trigger. The plan is silent on the trigger.

**Why it matters:** Pass 1's Charge 2 fix replaced an inverted-logic test with the correct one — but the rewrite trades one ambiguity (logic inversion) for another (which file does "edit `extract-overlay.sh`" actually mean: the manifest read or the script logic?). A code-writer following the plan literally will produce inconsistent attempts.

**The question that must be answered:** Does Task 11.4 edit (a) `extract-overlay.sh` to hardcode an inquisitor copy when `OVERLAY=fix`, OR (b) `runtime/ci-manifest.yaml`'s `overlays.fix.imports_from_private.agents` to add `inquisitor`? Both work for the matcher but they revert differently and have different review semantics.

**Remediation:** Amend Task 11.4 to specify exactly: "Edit `runtime/ci-manifest.yaml` to add `inquisitor` to `overlays.fix.imports_from_private.agents`. (Do NOT edit `extract-overlay.sh` — the script is authoritative; the manifest edit triggers the regression by feeding bad input to a correct script.) Push. Confirm the matcher fails. Revert the manifest edit only." This is cleaner, narrower, and matches the spec's "manifest is the source of truth" principle.

---

### CHARGE 5 — STAGE 1c-determinism replay re-clones private + marketplace; non-deterministic ref tip resolution can produce false positives or false negatives

**Quote (Task 9.1):**
> **`stage-1c-determinism`** … Re-clone private + marketplace (new job, new runner) — yes, this duplicates STAGE 2's clone work; the cost is acceptable per the master plan's "STAGE 1→STAGE 2 artifact handoff" deferral. For each overlay … run `extract-overlay.sh` twice into two separate `OUT_DIR`s with identical inputs; assert byte-identical via `diff -r` AND `sha256sum -c` over the materialized tree.

**The problem:** "Re-clone private + marketplace" happens **once** in this job, then `extract-overlay.sh` is invoked **twice** against the *same* clone. Good — that pins the input. But STAGE 1c-determinism runs in a separate job from STAGE 3. STAGE 3 re-clones independently (Task 9.2: "Re-clone private + marketplace (same as STAGE 2 — new job, new runner)"). If between STAGE 1c-determinism's clone and STAGE 3's clone a force-push lands on the marketplace tag (or the private tag is moved — the spec acknowledges this is theoretically possible since marketplace pins are "manual cadence"), the determinism replay validates one tree state and STAGE 3 builds a different tree state. STAGE 1c passes; STAGE 3 builds an image that the determinism replay never actually validated.

The plan attempts to mitigate this with the SHA-pin requirement (`sources.marketplace.ref` matches `^[a-f0-9]{40}$`, and `sources.private.ref` matches `^ci-v\d+\.\d+\.\d+$`). SHA-pinned refs are immutable for marketplace; the private tag is a tag, which CAN be moved but is conventionally not. **Conventionally is not contractually.** The determinism job's value depends on the assumption that the clone tree is byte-identical between STAGE 1c-determinism and STAGE 3. The plan never asserts this contractually — there is no SHA-of-clone capture-and-compare step.

**Second issue with `diff -r` AND `sha256sum -c`:** The plan asserts both. `sha256sum -c` over a manifest of files catches byte-content drift. `diff -r` catches byte-content drift AND filesystem-attribute drift (mtime, perms — but `diff -r` does not check perms by default; `diff -rq` is also content-only). The two are not redundant *only if* the determinism contract includes content-only matching. The plan does not say what `diff -r` catches that `sha256sum -c` does not. If both catch the same things, the plan is wasting CI minutes on a duplicate check. If they catch different things, the plan owes a sentence on what each is for.

**Why it matters:** Pass 1 Charge 12 escalated determinism replay from optional to mandatory because non-determinism breaks reproducibility. But the replay's validity is itself contingent on input-immutability assumptions that the plan does not pin. The replay can pass while the actual STAGE 3 build is non-reproducible, and no one would notice.

**The question that must be answered:** (a) What guarantees that STAGE 1c-determinism's clone tree is byte-identical to STAGE 3's clone tree? (b) Why does the determinism check need both `diff -r` AND `sha256sum -c`?

**Remediation:** Two changes:
1. After cloning private + marketplace in STAGE 1c-determinism, capture `git rev-parse HEAD` for both repos and write to a job output. STAGE 3 captures the same after its own clone and asserts equality. Mismatch fails STAGE 3 with `ERROR clone_drift_between_stages` (and triggers re-pinning the manifest if marketplace SHA was moved, or alarms loudly if private tag was moved).
2. Drop `diff -r` from the determinism replay and keep only `sha256sum -c` over a sorted file manifest. State the contract: byte-identical content over identical filesystem layout. mtime is already pinned to epoch 0 by `extract-overlay.sh`'s determinism contract; perms are governed by `umask 022`. If those pre-conditions hold, content sha covers the contract.

---

### CHARGE 6 — Plugin Truth Table preamble claims `pr-review-toolkit` for review but Task 3.0 still has it as TBD

**Quote (Plugin Truth Table):**
> | review  | context7, github, typescript-lsp, security-guidance, pr-review-toolkit  | … |

**Quote (Deviation #3):**
> Verified: marketplace SHA `0742692199b49af5c6c33cd68ee674fb2e679d50` contains a `pr-review-toolkit/` directory at the repo root (or under `plugins/` per §5.3 — to be confirmed at Task 3.0; if missing, this is a STOP-and-pin event, not a silent skip).

**The problem:** The Plugin Truth Table is described as "authoritative" — Task 7.A's `expected.yaml` content is required to match it verbatim. But Deviation #3 admits that the existence of `pr-review-toolkit` at the marketplace SHA has not been confirmed; "to be confirmed at Task 3.0" is the actual status. **Task 3.0 does not exist in the task list** — Task 3 is "Author `overlay-smoke.sh` wrapper" with subtasks 3.1 and 3.2 only. There is no Task 3.0.

**Why it matters:** If `pr-review-toolkit` is not at the pinned marketplace SHA (or is at a different path than the materialization rules expect), Task 11.1 dry-run's review cell fails with `ERROR inventory_must_contain_missing kind=plugins name=pr-review-toolkit`. Pass 1 fixed Charge 3's `skill-creator` issue by adding the `subtract_from_shared` mechanism but did not similarly verify the *additive* claim that `pr-review-toolkit` actually exists. The truth table treats it as a fact; the plan body treats it as a TBD. These are inconsistent.

**The question that must be answered:** Has `pr-review-toolkit` at marketplace SHA `0742692199b49af5c6c33cd68ee674fb2e679d50` been verified to exist, and at what path? If yes, Deviation #3's "to be confirmed" language must be removed. If no, the truth table is asserting a fact not in evidence.

**Remediation:** Run the verification now (a single `git ls-tree` against the marketplace SHA): `gh api repos/anthropics/claude-plugins-official/contents/?ref=0742692199b49af5c6c33cd68ee674fb2e679d50 | jq '.[] | .name' | grep pr-review-toolkit`. Update Deviation #3 with the result. If the directory is at a non-root path (e.g. `plugins/pr-review-toolkit/`), document the path and confirm `extract-overlay.sh` Task 5.1 Phase A step 2 handles both `plugins/` and `external_plugins/` lookups.

---

### CHARGE 7 — `.gitattributes` rule applies on next checkout; existing committed expected.yaml files may already carry CRLF

**Quote (Task 7.D):**
> Author `.gitattributes` rule (per Charge 7 of pass 1) for line-ending pinning: If `.gitattributes` exists at repo root, append: `runtime/overlays/*/expected.yaml text eol=lf` … Verify: `git ls-files --eol runtime/overlays/*/expected.yaml` shows `i/lf w/lf attr/text=auto eol=lf` for each.

**The problem:** `.gitattributes` rules apply to new checkouts and to files modified after the rule lands. **They do not retroactively normalize already-committed files.** If `runtime/overlays/<verb>/expected.yaml` files are authored on a Windows machine (e.g. via a git-bash worktree) AND committed before `.gitattributes` lands AND the user has `core.autocrlf=true`, the committed bytes can be CRLF. The verify step `git ls-files --eol` reports the current state but does not retroactively rewrite the committed file. The author would need to `git rm --cached` and re-add (or `git add --renormalize`) for the rule to take effect on existing files.

The plan's verify command (`git ls-files --eol`) shows the index/worktree state — if the file was committed with CRLF, it shows `i/crlf` until renormalization. The plan does not specify the renormalization step. A reviewer reading the plan would assume the `.gitattributes` write is sufficient.

A second issue: Task 5.2's CRLF reject step in STAGE 3 (`file ... | grep -q CRLF`) is the run-time defense — if a CRLF expected.yaml ever lands in the source tree, STAGE 3 rejects it. Good. But the plan's "verify" step in 7.D uses `git ls-files --eol` which is a *static* check, not a *dynamic* one. **The static check passes** (because `git ls-files --eol` reports the worktree's current state, which is post-checkout-with-rule = LF) **even when the index is still CRLF**. The author then commits `.gitattributes` thinking the issue is solved, but the next checkout on a fresh clone may regenerate CRLF for the existing commits if autocrlf is on the cloner's side.

**Why it matters:** Pass 1 Charge 7 was about R6 hash drift. The rule lands but does not enforce retroactively. If the expected.yaml was authored on Windows and committed before the rule (which is the order Task 7.A → Task 7.D implies — author the YAML in 7.A/B/C, then the rule in 7.D), the bytes in git history are CRLF. STAGE 3's CRLF reject catches this only if the runner sees CRLF in the source tree, which depends on the clone's autocrlf setting. On `ubuntu-latest` with default git config, autocrlf is off and the CRLF persists into the build context, where the reject step catches it. On a developer's Windows machine running locally, autocrlf converts to LF, the local check passes, and the developer pushes a "passes locally" change — but the runner sees CRLF and fails opaquely.

**The question that must be answered:** What is the order of operations to guarantee that all existing and future `runtime/overlays/*/expected.yaml` files are LF on disk and LF in the git tree?

**Remediation:** Reorder Task 7: 7.D (write `.gitattributes`) MUST happen BEFORE 7.A/B/C (write the expected.yaml files). Then add a step 7.D.bis: `git add --renormalize runtime/overlays/*/expected.yaml` after 7.A/B/C (no-op if files were authored after the rule lands and have LF on disk; converts if not). Document the order explicitly.

---

## MEDIUM

### CHARGE 8 — Task 9.3 cache-scope string has empty-`BASE_DIGEST` ambiguity

**Quote (Task 9.3):**
> Cache-scope string: `cache-from`/`cache-to` use `scope=overlay-${OVERLAY}-${KEY}`. The `${OVERLAY}` prefix isolates per-verb caches … the `${KEY}` suffix isolates per-base-digest caches.

**The problem:** `${KEY}` is a 9-component join leading with `BASE_DIGEST:0:12`. If `BASE_DIGEST` is empty (Task 4.0 says STOP if empty, but if a future maintainer runs STAGE 3 manually without that gate), the resulting `${KEY}` starts with the empty string and a separator, producing `overlay-review--<rest>` (double hyphen). Buildx accepts this as a valid scope name; the cache lookup is unambiguous. **But it shares the scope with any other run that also has empty `BASE_DIGEST`.** That's a cross-build cache collision that defeats the load-bearing isolation Pass 1 Charge 1 named.

The Task 4.0 "STOP if empty" gate is upstream of STAGE 3's cell, so the empty-`BASE_DIGEST` case is unlikely in the standard pipeline. But Task 9.2 also has a per-cell `[ -n "$CLI_VERSION" ] || exit 1` check; there is no symmetric `[ -n "$BASE_DIGEST" ]` check at the cache-key construction step. Adding one is trivial and closes the seam.

**Why it matters:** Defense in depth. The Task 4.0 gate is the primary defense; the cache-key construction step has zero-cost room for a backstop.

**The question that must be answered:** Is there any code path where STAGE 3's cache-key construction step receives an empty `BASE_DIGEST`?

**Remediation:** Add to Task 9.3's spec: "Before constructing `${KEY}`, assert `BASE_DIGEST` is exactly 64 hex chars (post-truncation `:0:12` is 12 hex chars). Empty or short → fail STAGE 3 cell with `ERROR base_digest_invalid value=<x>`."

---

### CHARGE 9 — Pre-#137 risk acceptance overstates mitigation (b)

**Quote (Pre-#137 risk acceptance):**
> Risk is mitigated by:
> (a) Public PR review process (humans review the diff)
> (b) `claude-pr-review/quality-gate` automated review (catches Critical/MAJOR findings; PR #179 / Issue #176, released as `v2.1.0`)
> (c) The matcher's deliberate-regression tests in Task 11 (mechanical CI evidence that the matcher works at all)

**The problem:** Mitigation (b) describes a status check that is *available* but not necessarily *required*. The dogfood repo's branch protection on `main` may or may not list `claude-pr-review/quality-gate` as a required status. The plan asserts it as a mitigation without verifying it's enforced. (a) is a process control (humans), (c) is a CI mechanism — both are real. (b) is in a middle state: the gate exists, posts a status, but the status only blocks merge if branch protection requires it.

**Why it matters:** A reviewer reading the risk acceptance assumes (b) actively prevents bad merges. If the dogfood repo's branch protection rules do not require the gate, (b) is aspirational. The pre-#137 gap is then larger than stated.

**The question that must be answered:** Is `claude-pr-review/quality-gate` listed as a required status check in the dogfood repo's branch protection ruleset for `main`? If not, the mitigation language must be qualified.

**Remediation:** Verify via `gh api repos/glitchwerks/github-actions/branches/main/protection` and update the language. If required, leave as-is. If not required, change to: "(b) `claude-pr-review/quality-gate` automated review status (advisory; not currently a required status check on `main` — see #137 for the path to making it required)."

---

### CHARGE 10 — Task 11.6 gate sanity check observes from a test that may not surface (b) and (c) cleanly

**Quote (Task 11.6):**
> using the run from 11.3 (where `review` cell fails), inspect the run log for empirical evidence … (a) `fix` and `explain` cells DID run to completion … (b) STAGE 3 job-level `result` is `failure` … (c) Hypothetical downstream `needs: stage-4-overlay` job would NOT run by default. Evidence: GitHub's `needs:` evaluates to `failure` for the dependent job; default behavior skips.

**The problem:** Point (c) is "hypothetical." The plan does not propose actually wiring a downstream job that depends on `stage-4-overlay` to observe whether it would skip. The "evidence" is "GitHub's documented behavior is X" — which is a citation, not empirical evidence. The label "empirical sanity check" overstates what 11.6 produces.

This is not a fatal flaw — citing documented behavior is acceptable when the documentation is authoritative. But the plan claimed in Pass 1 Charge 8 to provide "empirical evidence before Phase 6 wires gating." Without an actual downstream dependent job in the test, there is no empirical evidence; only a documentation citation.

**Why it matters:** Pass 1 Charge 8 was about whether the gating contract works as described. The remediation path was to test it. The test as designed can be done cheaper (no downstream job needed, just observe the matrix), but then it is no longer empirical for (c) — which was the point.

**The question that must be answered:** Does Task 11.6 actually exercise a downstream-needs evaluation, or does it only observe the matrix?

**Remediation:** Either (a) accept that 11.6 observes (a) and (b) empirically and (c) by citation, and rename the task to reflect that — "Gate observation (a/b empirical, c by citation)"; or (b) add a throwaway downstream job to the test workflow that depends on `stage-4-overlay` and emits a marker line; observe the marker is absent in the failed run. Option (b) is cleaner if the CI minutes are available.

---

## OUT-OF-SCOPE

### OOS-1 — `enumerate-persona.sh` does not enumerate `standards/`, `CLAUDE.md`, or top-level files

The plan's regex extraction handles `agents/`, `skills/`, `plugins/` only. Files like `/opt/claude/.claude/CLAUDE.md` and `/opt/claude/.claude/standards/software-standards.md` are silently ignored. This is consistent with the matcher's `must_contain.{agents,skills,plugins}` shape (no `must_contain.claude_md` field). But the base smoke (`smoke-test.sh:96-99`) does check those files via `REQUIRED_FILES`. Phase 3's overlay smoke wraps base smoke, so coverage is preserved — the issue is that `enumerate-persona.sh` is named ambitiously ("enumerate persona") but enumerates only three of the five persona surfaces. Future-Phase risk if someone extends `must_contain` to include `claude_md` without remembering the enumerator's blind spot.

Out of scope for this plan (the matcher YAML shape is fixed by §10.2). Document as a follow-up.

### OOS-2 — `expected.yaml` has no schema enforcement (only matcher-side checks)

The matcher (Task 2.2) catches malformed YAML, unknown top-level keys, invalid types, and the unsupported `must_not_contain.skills`. But there is no JSON Schema for `expected.yaml` itself — Phase 3 does not extend `runtime/ci-manifest.schema.json` to cover overlay expected.yaml shape. A bad expected.yaml is caught only at STAGE 4 (after STAGE 3 has built and pushed images). Could be moved to STAGE 1 with a separate schema. Trade-off (no schema = less rigid, more matcher work; schema = stricter contract, more files to maintain). Consistent with the master plan's posture; out of scope.

---

## VERDICT

The plan is *closer* to ship-ready than it was at end-of-Pass-1, but not yet acceptable. The remaining critical findings are all class-of-bug issues born in Pass 1's revisions — exactly the regression-of-revision pattern Phase 2 pass 2 caught. **Three CRITICAL findings must be addressed before Tasks 4+ begin:** Charge 1 (subtract_from_shared schema scoping + spec §4.2 reconciliation), Charge 2 (Dockerfile RUN trust in marker filename — both extractor-side validation AND Dockerfile-side defensive check are required, not either/or), and Charge 3 (Dockerfile RUN step ordering must be pinned, not described as "after the COPY"). Charges 4–7 (high-priority) are all sneaky-but-fixable seams: deliberate-regression test-target ambiguity, determinism replay's input-immutability gap, the unverified `pr-review-toolkit` existence claim contradicting "authoritative" truth table language, and `.gitattributes` ordering vs renormalization. The medium-tier findings (8–10) are documentation-tightening — defense-in-depth for empty-`BASE_DIGEST`, honesty about whether the quality gate is actually required, and rebranding 11.6's "empirical" claim to match what it actually measures. None of the medium tier blocks shipping; the high-priority tier should be addressed but could conceivably be deferred with risk acceptance language; the critical tier must be closed before the gated tasks proceed.

Pass 2 found 7 critical/high-priority findings against Pass 1's 9 — meaningful reduction, in line with the expectation that pass 2 surfaces fewer but sneakier issues. The pattern of "Pass 1 added a mechanism, Pass 2 found the mechanism's failure mode is unchecked" repeats for `subtract_from_shared` (Charges 1, 2, 3) and for the determinism replay (Charge 5). Once those close, a Pass 3 is unlikely to find critical issues; the remaining surfaces are all instrumented.
