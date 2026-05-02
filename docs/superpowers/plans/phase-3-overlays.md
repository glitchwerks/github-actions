# Phase 3 Overlays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, push, and smoke-test the three overlay images (`claude-runtime-review`, `claude-runtime-fix`, `claude-runtime-explain`) on top of the Phase 2 base image — establishing the `expected.yaml` inventory contract, the `EXPECTED_FILE` matcher (specified in Phase 2's smoke-test.sh comment block, implemented here), and STAGE 3 of `runtime-build.yml`. End-state: three overlay images at `ghcr.io/glitchwerks/claude-runtime-<verb>@sha256:<digest>` whose smoke runs enumerate the verb-scoped persona files as a non-root UID, and whose `expected.yaml` rejects deliberate "different eyes" violations (e.g. importing `code-writer` into the `review` overlay).

**Architecture:** Three overlay Dockerfiles, each `FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}` — the digest is captured by Phase 2's STAGE 2 job output. Each overlay extends the base by:

1. Materializing its `overlays.<verb>.imports_from_private` agents from the private repo (already cloned in STAGE 1; re-cloned in STAGE 3 because new job → new runner).
2. Materializing its `overlays.<verb>.plugins` from the marketplace (review only — fix/explain inherit base).
3. Copying the verb-specific `runtime/overlays/<verb>/CLAUDE.md` into `/opt/claude/.claude/CLAUDE.md`, **replacing** the base's shared CLAUDE.md (per §3.4 layer 2 — overlay CLAUDE.md is the active persona at job time; consumer-repo CLAUDE.md from `actions/checkout` is layer 3).

STAGE 3 is a parallel matrix job (`max-parallel: 3`, `continue-on-error: false` per §9.1) keyed off `overlay: [review, fix, explain]`. Each cell builds, pushes `:pending-<pubsha>`, and runs STAGE 4 with `EXPECTED_FILE` = the overlay's `expected.yaml`. The matcher (`runtime/scripts/inventory-match.sh`) consumes the JSON enumeration produced by the overlay smoke and the `expected.yaml` and emits per-violation error lines.

**Source of enumeration:** Phase 2 deliberately abandoned `claude --json-schema` model-output enumeration (CI run 25230756010 lesson — the model emits empty arrays satisfying the schema while concealing whether the persona is actually present). Overlay smoke uses the same filesystem structural check Phase 2 introduced: `find /opt/claude/.claude -type f`, then `grep`/parse the listing into `agents`/`skills`/`plugins` arrays and compare against `expected.yaml`. The matcher operates on filesystem ground truth, not model output.

**Tech Stack:** Same as Phase 2 — Docker BuildKit (`docker/build-push-action@v7`), GHCR push (`docker/login-action@v4`), `mikefarah/yq` v4.44.3 (parsing `expected.yaml`), `jq` (preinstalled — only used inside the matcher for kind-array intersection), `find`/`grep`/`awk` for the enumeration, Bash helpers run on `ubuntu-latest`. **No new runner dependencies** beyond what Phase 2 introduced.

**Spec source of truth:** `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §3.1 image hierarchy, §3.4 layer 2 overlay CLAUDE.md, §5.1 `overlays.*` manifest fields, §6.2 STAGE 3 build pipeline, §9.1 pre-promotion failure (`continue-on-error: false`), §10.1 T4 inventory assertions, §10.2 expected.yaml shape and ownership separation. Master plan: `docs/superpowers/plans/2026-04-22-ci-claude-runtime.md` §Phase 3, tasks 3.1–3.12 (3.12 deferred to #137).

**Consumer requirements** (what Phase 5 expects of these overlay images — see "Consumer Requirements" section below):

- **R1** — `FROM ghcr.io/glitchwerks/claude-runtime-<verb>@sha256:${OVERLAY_DIGEST}` works with the digest captured by Phase 3's STAGE 3 matrix job output (one digest per verb).
- **R2** — Each overlay sets `/opt/claude/.claude/CLAUDE.md` to its verb-specific persona, replacing the base shared CLAUDE.md. Base's persona content is layered semantically through the consumer-repo CLAUDE.md compose (§3.4); the on-disk CLAUDE.md the CLI loads is the overlay's.
- **R3** — `/opt/claude/.claude/` tree is world-readable (dirs `0755`, files `0644`) — same R3 as Phase 2; preserved through overlay layers (mechanically asserted by the smoke).
- **R4** — Each overlay carries the manifest's declared `imports_from_private` + `plugins` for that verb. `review` adds `agents/inquisitor` + `plugins/pr-review-toolkit`; `fix` adds `agents/debugger` + `agents/code-writer`; `explain` adds nothing beyond the base.
- **R5** — Image labels per Phase 2 §4.3 are preserved + extended with one new label `dev.glitchwerks.ci.overlay` ∈ `{review, fix, explain}` so Phase 6 rollback can distinguish overlays from base by inspection alone (not just by repo name).
- **R6** — Each overlay's `expected.yaml` is on-disk in the image at `/opt/claude/.expected.yaml` (read-only) for forensic post-promotion verification. (See Deviations #6 — this is a Phase-3-introduced contract not in the master plan; rationale below.)

How Phase 3 satisfies these is producer-side latitude — Phase 5 only consumes the contract.

**Issue:** [#141](https://github.com/glitchwerks/github-actions/issues/141). **Branch:** `phase-3-overlays` (off `main` @ `46bffd3`). **Worktree:** `I:/github-actions/.worktrees/phase-3-overlays`.

---

## Inquisitor passes (gate Tasks 4+)

Per `feedback_inquisitor_twice_for_large_design.md`: this is a large-design plan; two adversarial passes against the plan document MUST complete before any implementation work begins. Findings either resolved inline or explicitly accepted as out-of-scope in this document.

- **Pass 1:** complete. Report at `docs/superpowers/plans/phase-3-overlays-inquisitor-pass-1.md` (15 charges across 4 severity tiers). All 15 addressed inline below — see "Pass 1 findings addressed" subsection following Deviations.
- **Pass 2:** pending. Will run after Pass 1 revisions land in this file. Charge: re-read for *new* gaps introduced by Pass 1's changes (Phase 2 pass 2 caught the `--entrypoint` silent-false-pass; pass 2 specializes in regression-of-revision class bugs).

**Hard checkpoint:** Tasks 4+ (Dockerfile authoring, persona content, expected.yaml authoring, CI wiring) DO NOT begin until Pass 2 completes and findings are addressed. Tasks 1–3 (read Phase 2 contracts, author matcher + enumerator + wrapper) MAY begin in parallel with Pass 2 because their outputs are testable in isolation against the existing fixture and changes from Pass 2 would localize to those scripts.

---

## Plugin truth table (per Charge 9)

This table is authoritative. `expected.yaml` content in Tasks 7.A/B/C must agree with it exactly.

| Overlay | Plugins on disk after build | `must_contain.plugins` (positive minimum) | `must_not_contain.plugins` (forbidden) |
|---|---|---|---|
| review  | context7, github, typescript-lsp, security-guidance, pr-review-toolkit  | context7, github, typescript-lsp, security-guidance, pr-review-toolkit | skill-creator |
| fix     | context7, github, typescript-lsp, security-guidance, skill-creator      | context7, github, typescript-lsp, security-guidance | pr-review-toolkit |
| explain | context7, github, typescript-lsp, security-guidance, skill-creator      | context7, github, typescript-lsp, security-guidance | pr-review-toolkit |

**Note 1** — `microsoft-docs` is absent across the board (Phase 2 dropped it from the manifest; the spec §10.2 example is doc-out-of-date and amended in this PR per Task 12).

**Note 2** — `skill-creator` is present in base (`shared.plugins.skill-creator.paths: ["**"]`) and inherited by every overlay via the `FROM` line. The review overlay's `must_not_contain.plugins: [skill-creator]` is satisfied by an **explicit subtraction** at overlay build time — see Deviation #10 below and Task 5 (extract-overlay.sh manifest extension).

**Note 3** — `must_contain.skills` and `must_contain.agents` for overlays declare only **overlay-introduced minima**. Base-image inherited content (`skills.git`, `skills.python`, `agents.ops`) is asserted by base smoke (Phase 2's `smoke-test.sh:96-114`) and does not need to be re-asserted in overlay `expected.yaml`. Overlay `must_not_contain` declares verb-specific subtractions and forbidden inheritances.

---

## Deviations from master plan (recorded as the plan is authored)

Items shifted versus master-plan §Phase 3. Each is minimal, self-contained, and has a kill criterion or follow-up trigger. None of these are "discovered during implementation" — they are the merged-state truth at plan-write time.

1. **Matcher script is its own file** (`runtime/scripts/inventory-match.sh`), not inlined into `smoke-test.sh`. The master plan implicitly bundles inventory matching into Task 3.10 (STAGE 3 append). Pulling it into a standalone script is non-negotiable because:
   - The Phase 2 fixture (`runtime/scripts/tests/expected-matcher-fixture/`) was authored to be exercised against a standalone matcher binary — it produces JSON inputs and expects exit codes + stderr lines. An inline matcher couldn't run the fixture as a CI step without invoking the whole smoke pipeline.
   - The matcher's logic is independently testable (pure function: `(json, yaml) → exit_code + stderr`) and gets its own STAGE 1c fixture-replay step before any image is built. This catches matcher bugs before they mask inventory bugs.
   - **Trade-off:** one more script to maintain. Acceptable — the file is < 80 lines and the test fixture pins its behavior contractually.

2. **Overlay CLAUDE.md content is the load-bearing change in this PR — Dockerfiles are mechanical.** The master plan lists each overlay's Dockerfile as task 3.1/3.4/3.7 and CLAUDE.md as 3.2/3.5/3.8 with similar weight. In practice the Dockerfiles are nearly identical (parameterized by verb name, base digest, and which agents/plugins to copy in). The CLAUDE.md content is where most reviewer-time should land — it's the actual persona scope, the load-bearing artifact. The plan reflects this by giving each CLAUDE.md its own "content outline" subsection (per overlay) below.

3. **`pr-review-toolkit` install path verified at plan-write time.** The master plan task 3.1 says "install `pr-review-toolkit` plugin (P1 from marketplace clone at pinned SHA)" but does not specify the install path. Phase 2's `extract-shared.sh` materializes plugins to `/opt/claude/.claude/plugins/<plugin-name>/`. STAGE 3 must continue using the same path so the smoke's filesystem enumeration works without overlay-specific path overrides. Verified: marketplace SHA `0742692199b49af5c6c33cd68ee674fb2e679d50` contains a `pr-review-toolkit/` directory at the repo root (or under `plugins/` per §5.3 — to be confirmed at Task 3.0; if missing, this is a STOP-and-pin event, not a silent skip).

4. **`fix` overlay does NOT carry `inquisitor`.** Master plan §10.2 fix `expected.yaml` lists `must_not_contain.agents: [inquisitor, code-reviewer, comment-analyzer, pr-test-analyzer]`. This plan reproduces that. The fix overlay scope is "write/fix/refactor on consumer's branch" (§3.4 layer 2 fix CLAUDE.md). Adversarial critique is review-overlay-only — co-locating it on the fix overlay would let the fix overlay self-review code it just wrote, which is the same-author-both-sides anti-pattern §10.2 explicitly forbids.

5. **`explain` overlay imports nothing — but still has a CLAUDE.md and `expected.yaml`.** Per `overlays.explain.imports_from_private: {}` in the manifest. Tempting to skip the overlay entirely and have Phase 5 use the base image directly. **Rejected** — the overlay's value is the CLAUDE.md persona scope (read-only, never write files), which the base CLAUDE.md does not carry. Layering it as an overlay also means the on-disk CLAUDE.md is the explain-scoped one, so the CLI's job-time persona is correct without consumer-side env tricks.

6. **`/opt/claude/.expected.yaml` shipped in the image** (R6 above). Master plan does not specify in-image expected.yaml. Rationale: Phase 6 rollback / forensic post-promotion verification needs to verify that an arbitrary `:<pubsha>` image's contents match its declared inventory **without** going back to the source git tree at the matching SHA. Shipping `expected.yaml` in the image makes this self-contained: `docker run --entrypoint /bin/sh <image> -c 'cat /opt/claude/.expected.yaml'` retrieves the contract; matcher runs against the image's own listing. Costs ~200 bytes per image. **Trade-off:** if the file diverges from source tree at `runtime/overlays/<verb>/expected.yaml` (e.g. STAGE 3 copies the wrong file), forensic verification is silently wrong. Mitigation: STAGE 3 build-time hash-asserts the in-image file matches the source-tree file (Task 5).

7. **CLI version label inheritance is the cache-key contract** (not redundant). Phase 2's cache-key tuple includes `CLI_VERSION` because the npm `stable` tarball can be re-published within 72 hours. Phase 3 overlays do **not** re-install Claude Code CLI — they inherit the binary from the base via `FROM ...@sha256`. So `CLI_VERSION` does NOT appear in the Phase 3 overlay cache-key tuple. The base image digest in the FROM line covers it (a CLI re-publish that triggered a new base build → new base digest → new overlay build). **Trade-off:** if someone manually edits the overlay Dockerfile to include a `RUN npm install` of a different CLI version, the overlay cache won't bust on CLI version because it's not in the key. Mitigation: add a Dockerfile lint step in STAGE 1 that rejects `npm install @anthropic-ai/claude-code` outside of the base Dockerfile. Tracked as a follow-up task; see "Items deferred" below.

8. **`dorny/paths-filter` is OPTIONAL — not in v1.** Master plan task 3.10 says "use `dorny/paths-filter` to skip overlays whose `runtime/overlays/<name>/**` tree is unchanged AND whose base digest hasn't changed." Skipping unchanged overlays is a perf win, not correctness — and gets complicated when the base digest changes (every overlay must rebuild even if its tree is identical). **Decision:** v1 builds all three overlays every time STAGE 3 runs. CI minutes cost: ~3 minutes extra per run with cache hits, ~12 minutes without. Acceptable; revisit in Phase 6 perf pass.

9. **STAGE 3 matrix uses `fail-fast: false` AND `continue-on-error: false`.** These look contradictory. They're not: `continue-on-error: false` means a failed cell fails the job (not "ignore the failure"); `fail-fast: false` means **other** matrix cells continue running when one cell fails. We want both: if `review` fails its smoke, don't auto-cancel `fix` and `explain` (we want to see all three failure modes in one run), but still fail the overall STAGE 3 job so STAGE 5 promote never runs. §9.1 requires "one overlay failing blocks ALL promotion" — that's enforced by the job-level fail, not by cell-level fail-fast. **Empirical sanity check:** Task 11.6 inspects a real failure run to confirm the gating works as claimed (per Charge 8 of pass 1).

10. **Manifest extended with `overlays.<verb>.subtract_from_shared.plugins`** (per Charge 3 of pass 1). The base ships `skill-creator: ["**"]` per `shared.plugins`; every overlay inherits it via `FROM`. The review overlay's `must_not_contain.plugins: [skill-creator]` (spec §10.2 verbatim) cannot be honored by inheritance alone — there must be a mechanism to *subtract* a base-inherited plugin at overlay build time. Two paths were considered:
   - (a) Amend §10.2 to remove `skill-creator` from review's `must_not_contain.plugins`, accepting that skill-creator is on-disk in review but the persona forbids invoking it (mechanism-dependent isolation).
   - (b) Extend `extract-overlay.sh` to honor a new manifest field `overlays.<verb>.subtract_from_shared.plugins: [<plugin-name>, ...]` which `rm -rf`s the named plugin directories from the inherited tree at overlay build time (physical isolation).
   - **Choice: (b).** Path (a) violates §3.3's stated principle that "physical isolation > mechanism-dependent isolation." Path (b) costs one new manifest field, schema validation extension, and ~10 lines in `extract-overlay.sh`. The schema change is small and documented; trade-off accepted. Task 5 implements; Task 5b updates the schema.

11. **`cli_version` label is propagated to overlays via build-arg, not set empty** (reversal of an initial draft choice — per Charge 11 of pass 1). The base image's `dev.glitchwerks.ci.cli_version` label is the source of truth; STAGE 3 reads it via `docker inspect ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST} --format '{{ index .Config.Labels "dev.glitchwerks.ci.cli_version" }}'` and passes the value through `--build-arg CLI_VERSION=...`. The overlay's Dockerfile sets `dev.glitchwerks.ci.cli_version` to that value. R5 (all labels present **and non-empty**) is preserved without exception. Cost: one `docker inspect` per cell (~200ms). Initial draft set the label empty and "documented" the divergence — that path is rejected because (i) Phase 2's smoke `[ -z "$v" ]` check fails on an empty label, requiring helper-extension special-casing that obscures the contract; (ii) honest label-completeness is a Phase 6 rollback dependency.

12. **Determinism replay (STAGE 1c-determinism) is mandatory, not optional** (per Charge 12 of pass 1). The initial draft had this as "consider whether worth the CI minutes." Reversed: STAGE 1c runs `extract-overlay.sh` twice for each overlay and asserts byte-identical output via `sha256sum`. Cost is trivial (~10s × 3 overlays = 30s total) and the value is the same as Phase 2's STAGE 1b: non-deterministic output means cache misses on identical inputs, defeating reproducibility. Task 9.1 specifies.

Items deferred (with explicit triggers):

- **Dockerfile lint step rejecting `npm install @anthropic-ai/claude-code` outside base/Dockerfile.** Rationale: Deviation #7 above. Trigger: someone proposes an overlay Dockerfile that re-installs the CLI; lint rejects it. Tracked as a follow-up issue to file in Phase 3 PR body if not already present.
- **CODEOWNERS demonstration of "different eyes" ownership split** — task 3.12 in master plan, deferred to issue [#137](https://github.com/glitchwerks/github-actions/issues/137) per master plan. Phase 3 PR body must reference the deferral. Inventory assertions still provide post-merge mechanical enforcement; pre-merge enforcement follows #137.
- **Marketplace bump review containment automation** — §10.2 requires every PR that bumps `sources.marketplace.ref` to include a `git diff` summary of plugin directories. Currently a manual reviewer expectation. Tracked as a Phase 6 / Phase 7 automation; not Phase 3.
- **Multi-arch overlays** — same deferral as Phase 2 base. Builds linux/amd64 only.
- **STAGE 1 → STAGE 3 artifact handoff** to avoid double-cloning private + marketplace — same deferral as Phase 2 STAGE 2.

---

## Pass 1 findings addressed (15/15)

Each finding from `phase-3-overlays-inquisitor-pass-1.md` is enumerated below with the resolution path. All BLOCKING and HIGH-PRIORITY findings are resolved inline in this revision; medium/lower-priority findings are resolved as noted.

**BLOCKING:**

- **Charge 1 — cache-key spec.** Resolved in Task 9.3: cache scope is `overlay-${OVERLAY}-${KEY}` where `${KEY}` includes `BASE_DIGEST:0:12` as a leading component. Buildx FROM-line interpolation is documented as insufficient; cache-scope isolation is the load-bearing mechanism.
- **Charge 2 — Task 11.4 inverted logic.** Resolved: Task 11.4 rewritten to edit `extract-overlay.sh` (add inquisitor to fix imports) WITHOUT touching `expected.yaml`. The matcher then catches the regression because `inquisitor` is in `must_not_contain.agents` AND now in the enumeration. New Task 11.4b added for the `must_contain_missing` symmetric exercise on explain.
- **Charge 3 — `skill-creator` subtraction.** Resolved via Deviation #10 above: manifest extended with `overlays.<verb>.subtract_from_shared.plugins`, schema updated (Task 5b), `extract-overlay.sh` `rm -rf`s the named plugin from the inherited tree (Task 5.1 amended).
- **Charge 4 — `enumerate-persona.sh` empty-output guard.** Resolved in Task 2.1: explicit `enumeration_empty` and `enumeration_no_persona` errors with exit 1, mirroring Phase 2's empty-persona guard. Name-extraction regexes are now stated explicitly.

**HIGH-PRIORITY:**

- **Charge 5 — empty/malformed `expected.yaml`.** Resolved in Task 2.2: matcher exits 1 with `expected_yaml_empty` when neither top-level key is present; exits 1 with `expected_yaml_no_assertions` when both are present but every kind-array is empty (sum == 0); exits 2 with `expected_yaml_parse_failed` on `yq` non-zero. Two new fixture cases added (Task 2.4-fixture).
- **Charge 6 — `set -e` + process substitution + counter.** Resolved in Task 2.2: header is `set -uo pipefail` (NOT `set -e`); `yq` and `jq` invocations are pre-validated outside loop bodies before any `done < <(...)` consumer reads from their output. Pattern follows Phase 2's `extract-shared.sh` `errs` accumulator.
- **Charge 7 — R6 hash CRLF/trailing-newline drift.** Resolved in Task 7.D and Task 5.2: commit a `.gitattributes` rule pinning `runtime/overlays/*/expected.yaml text eol=lf`. STAGE 3 build adds an explicit `file ... | grep -q CRLF` reject step before COPY.
- **Charge 8 — fail-fast/continue-on-error gating.** Resolved in Task 11.6: empirical sanity check on the deliberate-regression run inspects matrix cell completion + job-level result + downstream-needs evaluation. Captures evidence before Phase 6 wires gating.
- **Charge 9 — plugin reconciliation incomplete.** Resolved by the Plugin Truth Table preamble. Tasks 7.A/B/C `expected.yaml` content amended to match the table verbatim.

**MEDIUM:**

- **Charge 10 — inquisitor passes wired post-implementation.** Resolved by the "Inquisitor passes (gate Tasks 4+)" section above. Tasks 4–12 do not begin until Pass 2 lands. Task 13.x renumbered: PR-time bot review (`pr-review` workflow) is task 13, separate from the plan-time passes.
- **Charge 11 — empty `cli_version` label.** Resolved via Deviation #11 above. Task 4.1 amended.
- **Charge 12 — determinism replay deferred.** Resolved via Deviation #12 above. Task 9.1 amended.
- **Charge 13 — `must_contain.skills` redundancy with base smoke.** Resolved via Plugin Truth Table Note 3 (the convention is now stated explicitly). Task 7.C's note about adding `[ops]` to explain's `must_contain.agents` is removed.

**OUT-OF-SCOPE:**

- **Charge 14 — CODEOWNERS deferral.** Resolved via "Pre-#137 risk acceptance" preamble (added below).
- **Charge 15 — secret/token audit.** Resolved in Task 3.1 (overlay-smoke.sh): explicit statement that base smoke runs against the overlay image, so Phase 2's secret-hygiene scan covers overlay state.

---

## Pre-#137 risk acceptance (per Charge 14)

Until issue [#137](https://github.com/glitchwerks/github-actions/issues/137) lands a CODEOWNERS split for `runtime/overlays/*/` vs `runtime/overlays/*/expected.yaml`, a single author can write both an overlay change and its `expected.yaml` in one PR. The matcher mechanically enforces *consistency* (the two files agree) but cannot enforce *adversarial review* (a second pair of eyes per spec §10.2). This is a known and accepted gap for the duration of #137. Risk is mitigated by:

- (a) Public PR review process (humans review the diff)
- (b) `claude-pr-review/quality-gate` automated review (catches Critical/MAJOR findings; PR #179 / Issue #176, released as `v2.1.0`)
- (c) The matcher's deliberate-regression tests in Task 11 (mechanical CI evidence that the matcher works at all)

The matcher contract is necessary but not sufficient for the "different eyes" guarantee. CODEOWNERS in #137 closes the gap.

---

## Consumer Requirements (Phase 5 contract)

Phase 5 (`Phase 5: digest-pin reusable workflows + tag-respond caller + mapping table`) consumes Phase 3's overlay digests. The producer-side latitude is everything inside `runtime/overlays/<verb>/`; the consumer-side contract is:

| ID | Contract | Verified by |
|---|---|---|
| **R1** | Each overlay digest is captured at STAGE 3 matrix-cell-output `digest_<verb>` and surfaced as STAGE 3 job output. | Task 9 — STAGE 3 matrix output wiring + Task 11 dry-run digest capture |
| **R2** | `/opt/claude/.claude/CLAUDE.md` exists and contains the overlay-specific persona content (not the base's shared CLAUDE.md content). | Task 6 (build) + Task 8 smoke (asserts file SHA matches source-tree SHA) |
| **R3** | All entries under `/opt/claude/.claude/` are mode 0755 (dirs) / 0644 (files). | Smoke test (Phase 2 helper, exercised on each overlay) |
| **R4** | `must_contain.<kind>` entries are present in the filesystem enumeration; `must_not_contain.<kind>` entries are absent. | Task 8 smoke + Task 11 dry-run regression (deliberately add `code-writer` to review's `must_contain`, confirm STAGE 3 fails) |
| **R5** | Six base labels + one new `dev.glitchwerks.ci.overlay` label = seven labels. All present + non-empty. | Smoke label-completeness check (Phase 2 helper extended in Task 7) |
| **R6** | `/opt/claude/.expected.yaml` exists in the image and is byte-identical to `runtime/overlays/<verb>/expected.yaml` at the build's source SHA. | Build-time hash assertion (Task 5) + smoke read-back assertion (Task 8) |

How Phase 3 satisfies these is producer-side latitude — Phase 5 only consumes the contract.

---

## File Structure

Paths relative to repo root. All created/modified on the `phase-3-overlays` worktree.

```
runtime/
  overlays/
    review/
      Dockerfile                                # Task 4 — build review overlay FROM base@digest
      CLAUDE.md                                 # Task 6 — full review-scoped persona (replaces Phase 1 stub)
      expected.yaml                             # Task 7 — must_contain + must_not_contain
    fix/
      Dockerfile                                # Task 4 — build fix overlay FROM base@digest
      CLAUDE.md                                 # Task 6 — full fix-scoped persona (replaces Phase 1 stub)
      expected.yaml                             # Task 7 — must_contain + must_not_contain
    explain/
      Dockerfile                                # Task 4 — build explain overlay FROM base@digest
      CLAUDE.md                                 # Task 6 — full explain-scoped persona (replaces Phase 1 stub)
      expected.yaml                             # Task 7 — must_contain + must_not_contain
  scripts/
    inventory-match.sh                          # Task 2 — pure matcher (json + yaml → exit code + stderr)
    overlay-smoke.sh                            # Task 3 — overlay-aware wrapper around smoke-test.sh
                                                #          (calls smoke-test.sh, then inventory-match.sh)
    tests/
      expected-matcher-fixture/                 # (Phase 2; unchanged — fixture is the executable contract)

.github/workflows/
  runtime-build.yml                             # Task 9 — APPEND STAGE 1c (matcher fixture replay)
                                                #          + STAGE 3 (build matrix) + STAGE 4 overlay smoke
                                                #          (rename current STAGE 4 → STAGE 4-base; add STAGE 4-overlay)

CLAUDE.md                                       # Task 12 — extend "CI Runtime" section to mention overlays
README.md                                       # Task 12 — note `runtime/overlays/` is part of build surface
```

Files NOT touched in Phase 3 (intentionally — they belong to other phases or are deferred):

- `claude-command-router/` (Phase 4)
- `runtime/rollback.yml`, `runtime/check-private-freshness.yml`, `runtime/prune-pending.yml` (Phase 6)
- `.github/workflows/claude-*.yml` consumer-facing reusable workflows (Phase 5)
- `.github/CODEOWNERS` (deferred to #137 — see Deviations)

---

## Pinned identifiers (verified live at plan-write time, 2026-05-02)

Per `agent-memory/general-purpose/feedback_verify_sha_pins_at_write_time.md`, every pin below is checked the moment it lands in this plan. Each entry includes the verification command so a future reviewer can re-run it.

| Pin | Value | Verification |
|---|---|---|
| Base image digest (consumed by every overlay's `FROM`) | TBD — captured at Task 4 from `gh api ... /packages/container/claude-runtime-base/versions` for the latest `:<main-pubsha>` tag | `gh api /users/glitchwerks/packages/container/claude-runtime-base/versions \| jq '.[] \| select(.metadata.container.tags[] \| contains("46bffd3")) \| .name'` (resolves to a digest) |
| Marketplace SHA | `0742692199b49af5c6c33cd68ee674fb2e679d50` (Phase 1 pin, unchanged) | (Phase 1 evidence; manifest authoritative) |
| Private ref | `ci-v0.1.0` (Phase 1 pin, unchanged) | (Phase 1 evidence; manifest authoritative) |
| `actions/checkout` | `@v5` (Phase 1 pin, unchanged) | (Phase 1 evidence) |
| `mikefarah/yq` | `v4.44.3` (Phase 1 pin, unchanged) | (Phase 1 evidence) |
| `docker/build-push-action` | `@v7` (Phase 2 pin, unchanged) | (Phase 2 evidence) |
| `docker/login-action` | `@v4` (Phase 2 pin, unchanged) | (Phase 2 evidence) |
| `docker/setup-buildx-action` | `@v4` (Phase 2 pin, unchanged) | (Phase 2 evidence) |

If any entry above no longer resolves at execution time (e.g. base digest is GC'd, marketplace SHA was rewritten), STOP and re-pin before proceeding. The base digest is the highest-risk item — it must be captured fresh at Task 4 from the most recent `main` build.

---

## Tasks

### Task 1 — Read & verify Phase 2 contract artifacts

- [ ] **1.1** Read `runtime/scripts/smoke-test.sh` lines 124–151 (the `EXPECTED_FILE` matcher contract block). Confirm the documented YAML shape matches §10.2 exactly: `must_contain.{agents,skills,plugins}`, `must_not_contain.{agents,plugins}` (no `skills` under `must_not_contain`).
- [ ] **1.2** Read `runtime/scripts/tests/expected-matcher-fixture/README.md` and `expected.yaml` + the two enumeration JSONs. Confirm:
  - `enumeration-pass.json` against `expected.yaml` should exit 0 with no stderr.
  - `enumeration-fail.json` against `expected.yaml` should exit 1 with TWO error lines:
    - `ERROR inventory_must_not_contain_present kind=agents name=code-writer`
    - `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`
- [ ] **1.3** Verify Phase 2's smoke-test.sh produces a JSON enumeration the matcher can consume. **Decision required here:** the smoke as committed produces filesystem listings (`find /opt/claude/.claude -type f`) and parses them inline into agent/skill/plugin counts. The matcher needs an explicit JSON enumeration of *names* (not just counts). Three options:
  - (a) Extend `smoke-test.sh` to emit a JSON file with `{agents: [], skills: [], plugins: []}` arrays as a side artifact → matcher reads that file.
  - (b) Have the matcher do its own `docker run ... find` + parse, duplicating Phase 2 logic.
  - (c) Have a separate `enumerate-persona.sh` that produces the JSON, called from both smoke and matcher.
  - **Choose (c)** — single source of truth for "image → enumeration", reusable across base smoke and overlay smoke and the matcher fixture replay. Task 2 implements `enumerate-persona.sh`; Task 3 wires `overlay-smoke.sh` to call it then call `inventory-match.sh`.
- [ ] **1.4** Confirm the base image at `ghcr.io/glitchwerks/claude-runtime-base` has at least one `:<pubsha>` tag from a green `main` build (i.e. Phase 2 actually pushed a usable base). If not, STOP — Phase 3 cannot proceed without a base digest. (Expected: yes, given Phase 2's `:2df97ff...` and subsequent main pushes.)

### Task 2 — Author `inventory-match.sh` + `enumerate-persona.sh`

- [ ] **2.1** Author `runtime/scripts/enumerate-persona.sh`:
  - Inputs: `IMAGE_REF` (env), `SMOKE_UID` (env, optional — defaults to `id -u`), `OUT_FILE` (positional; path to write JSON to).
  - Behavior: `docker run --rm --user "$SMOKE_UID" --entrypoint /bin/sh "$IMAGE_REF" -c 'find /opt/claude/.claude -type f'`, parse the listing, emit JSON of shape `{agents: [<names>], skills: [<names>], plugins: [<names>]}` to `$OUT_FILE`.
  - **Name extraction (explicit regexes — per Charge 4 of pass 1):**
    - `agents`: lines matching `^/opt/claude/\.claude/agents/([^/]+)\.md$` → captured group 1 is the agent name. Subdirectories under `agents/` are not v1; nested structure is silently ignored (an `agents/foo/bar.md` does not match and is omitted).
    - `skills`: lines matching `^/opt/claude/\.claude/skills/([^/]+)/` → captured group 1 is the skill name. The first path component after `skills/` is the skill name regardless of nesting depth (e.g. `skills/foo/templates/bar.md` yields `foo`).
    - `plugins`: lines matching `^/opt/claude/\.claude/plugins/([^/]+)/` → captured group 1 is the plugin name. Same first-component rule as skills.
  - Names are sorted (`LC_ALL=C`) and deduplicated (`sort -u`).
  - **Empty-output and zero-persona guards (per Charge 4 of pass 1):**
    - If `find` exits non-zero: exit 1 with stderr `ERROR enumeration_failed image=<ref>` (and forward `find`'s stderr).
    - If `find` exits 0 but produces zero output lines: exit 1 with stderr `ERROR enumeration_empty image=<ref>`. (Different from Phase 2's `empty_persona`: this catches the "tree doesn't exist or wasn't materialized" case before parsing names.)
    - If parsing yields zero agents AND zero skills AND zero plugins (but non-empty `find` output, e.g. only `CLAUDE.md` and `standards/` exist): exit 1 with stderr `ERROR enumeration_no_persona image=<ref> agents=0 skills=0 plugins=0`. Mirrors Phase 2's `smoke-test.sh:88-93` empty-persona guard but at the enumerator layer for the matcher's benefit.
  - Exit 0 on success; emit the JSON to `$OUT_FILE` and a one-line summary to stdout (`enumerate-persona: image=<ref> agents=N skills=M plugins=K`).
- [ ] **2.2** Author `runtime/scripts/inventory-match.sh`:
  - Inputs: `JSON_FILE` (positional 1; output of `enumerate-persona.sh`), `EXPECTED_FILE` (positional 2; an `expected.yaml`).
  - Dependencies: `jq`, `yq` (v4 — already on runner from Phase 2's STAGE 2).
  - **Script header (per Charge 6 of pass 1):** `set -uo pipefail` — NOT `set -e`. `set -e` is incompatible with the all-violations-before-exit contract; a single failing comparison would short-circuit the loop. Errors are accumulated via an `errs` counter (same pattern as Phase 2's `extract-shared.sh`).
  - **Pre-validation (per Charge 6 of pass 1):**
    - `yq eval '.' "$EXPECTED_FILE" >/dev/null 2>&1 || { echo "ERROR expected_yaml_parse_failed file=$EXPECTED_FILE" >&2; exit 2; }`
    - `jq -e . "$JSON_FILE" >/dev/null 2>&1 || { echo "ERROR enumeration_json_parse_failed file=$JSON_FILE" >&2; exit 2; }`
    - Exit code 2 (distinct from violation exit code 1) means "the inputs themselves are broken" — useful for upstream triage.
    - Both pre-validations run **before** any iteration loop reads from a process substitution; `yq`/`jq` failures inside `done < <(...)` are silently ignored under `set -uo pipefail`, hence the explicit pre-check.
  - **Empty/no-assertions guards (per Charge 5 of pass 1):**
    - If neither `must_contain` nor `must_not_contain` is a present top-level key (zero-byte file, `# only comments`, `{}`, `null`): exit 1 with `ERROR expected_yaml_empty file=<path>`.
    - If both are present but every kind-array within them is empty (sum of all lengths == 0): exit 1 with `ERROR expected_yaml_no_assertions file=<path>`. A silently empty expected.yaml is a Phase 3 owner bug, not a no-op.
  - **Schema check:**
    - If `expected.yaml` has any top-level key other than `must_contain` and `must_not_contain`: fail with `ERROR expected_yaml_unknown_top_level_key key=<key>` (exit 2).
    - If `must_contain.skills` exists but is not an array: fail with `ERROR expected_yaml_invalid_type kind=must_contain.skills` (exit 2).
    - `must_not_contain.skills` is **NOT supported in v1** per §10.2 — the spec example only declares `must_not_contain.{agents,plugins}`. If present, fail with `ERROR expected_yaml_unsupported_field field=must_not_contain.skills` (exit 2). Future spec revision can lift this.
  - **Behavior (after pre-validation passes):**
    1. Parse `expected.yaml` into four arrays: `must_contain.{agents,skills,plugins}` and `must_not_contain.{agents,plugins}`. Missing keys default to empty arrays.
    2. For each name in `must_contain.<kind>`: assert `name` is in the JSON's `<kind>` array. Missing → emit `ERROR inventory_must_contain_missing kind=<kind> name=<name>` to stderr; `((errs++))`.
    3. For each name in `must_not_contain.<kind>`: assert `name` is NOT in the JSON's `<kind>` array. Present → emit `ERROR inventory_must_not_contain_present kind=<kind> name=<name>` to stderr; `((errs++))`.
    4. **Report ALL violations before exiting** (do not short-circuit). Per the matcher contract in `smoke-test.sh:144` and the bash idiom in Charge 6.
    5. Exit 0 if `errs == 0`; exit 1 if `errs > 0`.
  - **Comparison semantics:** exact-match string equality. No glob, no regex, no case-folding.
  - **Exit code summary:** 0 = clean, 1 = violations or empty/no-assertions, 2 = malformed input or schema error.
- [ ] **2.3** Replay the Phase 2 fixture against the new matcher to verify contract conformance:
  - `bash runtime/scripts/inventory-match.sh runtime/scripts/tests/expected-matcher-fixture/enumeration-pass.json runtime/scripts/tests/expected-matcher-fixture/expected.yaml` → expect exit 0, no stderr.
  - `bash runtime/scripts/inventory-match.sh runtime/scripts/tests/expected-matcher-fixture/enumeration-fail.json runtime/scripts/tests/expected-matcher-fixture/expected.yaml` → expect exit 1, exactly two stderr lines:
    - `ERROR inventory_must_not_contain_present kind=agents name=code-writer`
    - `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`
  - If the matcher produces different output, the matcher is non-conforming. Fix before proceeding.
- [ ] **2.4** Extend the fixture with empty/malformed cases (per Charge 5 of pass 1). Add to `runtime/scripts/tests/expected-matcher-fixture/`:
  - `expected-empty.yaml` — zero bytes. Replay against `enumeration-pass.json` → expect exit 1 with stderr `ERROR expected_yaml_empty file=<path>`.
  - `expected-no-assertions.yaml` — contents: `must_contain: {}\nmust_not_contain: {}\n`. Replay → expect exit 1 with stderr `ERROR expected_yaml_no_assertions file=<path>`.
  - `expected-malformed.yaml` — contents: `must_contain:\n  agents:\n  - inquisitor\n    foo: [bar  # unclosed indent`. Replay → expect exit 2 with stderr `ERROR expected_yaml_parse_failed file=<path>`.
  - `enumeration-malformed.json` — contents: `{"agents": [...` (unterminated). Replay → expect exit 2 with stderr `ERROR enumeration_json_parse_failed file=<path>`.
  - `expected-unknown-key.yaml` — contents: `must_contain:\n  agents: [foo]\nbogus_section: 1\n`. Replay → expect exit 2 with stderr `ERROR expected_yaml_unknown_top_level_key key=bogus_section`.
  - Update `README.md` in the fixture dir with the expanded contract.
- [ ] **2.5** Add the fixture replay as a CI step (implemented in Task 9.1 STAGE 1c — listed here for traceability).
- [ ] **2.6** Commit. Message: `feat(runtime): add inventory-match.sh + enumerate-persona.sh per spec §10.2 (refs #141)`.

### Task 3 — Author `overlay-smoke.sh` wrapper

- [ ] **3.1** Author `runtime/scripts/overlay-smoke.sh`:
  - Inputs: positional 1 = image ref, positional 2 = overlay name (`review|fix|explain`), env `CLAUDE_CODE_OAUTH_TOKEN` (passed through to base smoke), env `EXPECTED_FILE` (path to overlay's `expected.yaml`).
  - Behavior:
    1. Call `runtime/scripts/smoke-test.sh "$IMAGE" "$OVERLAY"` for the Phase-2-shared structural checks (CLI binary, persona file counts, R3 perms, label completeness, secret hygiene).
    2. After base smoke succeeds, call `runtime/scripts/enumerate-persona.sh "$IMAGE" /tmp/overlay-enumeration.json`.
    3. Call `runtime/scripts/inventory-match.sh /tmp/overlay-enumeration.json "$EXPECTED_FILE"`.
    4. Verify the in-image `/opt/claude/.expected.yaml` byte-matches the provided `$EXPECTED_FILE` (R6 verification): `docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'cat /opt/claude/.expected.yaml' | sha256sum -c <(sha256sum "$EXPECTED_FILE" | awk '{print $1"  -"}')`. Fail with `ERROR expected_yaml_in_image_mismatch overlay=<name>` on diff.
    5. Echo `overlay-smoke: $OVERLAY clean` on success; non-zero exit propagates.
  - **Why a wrapper:** keeps `smoke-test.sh` unchanged from Phase 2 (no risk of regressing base smoke); wraps the overlay-only steps in one place; called from STAGE 4-overlay matrix cell once per overlay.
- [ ] **3.2** Commit. Message: `feat(runtime): add overlay-smoke.sh wrapper for Phase 3 STAGE 4 (refs #141)`.

### Task 4 — Author overlay Dockerfiles (review, fix, explain)

- [ ] **4.0** Capture the base digest AND the base CLI version (per Deviation #11). Run:
  ```bash
  BASE_DIGEST=$(gh api /users/glitchwerks/packages/container/claude-runtime-base/versions --paginate \
    | jq -r '.[] | select(.metadata.container.tags[] | startswith("46bffd3")) | .name' | head -1)
  # Use the latest `main` SHA at execution time, not necessarily 46bffd3.
  docker pull "ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}"
  CLI_VERSION=$(docker inspect "ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}" \
    --format '{{ index .Config.Labels "dev.glitchwerks.ci.cli_version" }}')
  echo "BASE_DIGEST=$BASE_DIGEST CLI_VERSION=$CLI_VERSION"
  ```
  Both values are passed as `--build-arg` in STAGE 3 (Task 9.2). If `BASE_DIGEST` is empty (no tag matching the SHA) or `docker pull` fails (`manifest unknown`), STOP — the base build for this commit is not promoted to GHCR yet. If `CLI_VERSION` is empty, the base's label is broken — STOP and fix the base before continuing.
- [ ] **4.1** Author `runtime/overlays/review/Dockerfile`:
  ```dockerfile
  ARG BASE_DIGEST
  FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}

  ARG OVERLAY=review
  ARG PRIVATE_REF
  ARG PRIVATE_SHA
  ARG MARKETPLACE_SHA
  ARG PUB_SHA
  ARG CLI_VERSION                       # passed-through from base label per Deviation #11

  # Materialized overlay tree (built by extract-overlay.sh in STAGE 3 — see Task 5)
  COPY overlay-tree/ /opt/claude/.claude/

  # Overlay-scoped CLAUDE.md replaces base shared CLAUDE.md (§3.4 layer 2)
  COPY CLAUDE.md /opt/claude/.claude/CLAUDE.md

  # Inventory contract on-disk for forensic verification (R6)
  COPY expected.yaml /opt/claude/.expected.yaml

  RUN chmod -R a+rX /opt/claude/.claude/ \
   && chmod 0644 /opt/claude/.expected.yaml

  LABEL org.opencontainers.image.source="https://github.com/glitchwerks/github-actions" \
        org.opencontainers.image.revision="${PUB_SHA}" \
        dev.glitchwerks.ci.private_ref="${PRIVATE_REF}" \
        dev.glitchwerks.ci.private_sha="${PRIVATE_SHA}" \
        dev.glitchwerks.ci.marketplace_sha="${MARKETPLACE_SHA}" \
        dev.glitchwerks.ci.cli_version="${CLI_VERSION}" \
        dev.glitchwerks.ci.overlay="${OVERLAY}"
  ```
  Note: `cli_version` carries the **base image's CLI version** (read from base's label at STAGE 3 cell start, passed in via build-arg). R5 ("all labels present + non-empty") holds without exception, and Phase 6 forensic queries can read the overlay's label directly without `docker history` chase.
- [ ] **4.2** Author `runtime/overlays/fix/Dockerfile` — same as review except `ARG OVERLAY=fix`. No `pr-review-toolkit` (manifest's `overlays.fix.imports_from_private` carries `[debugger, code-writer]`; no overlay-specific plugins).
- [ ] **4.3** Author `runtime/overlays/explain/Dockerfile` — same as review except `ARG OVERLAY=explain`. No agent imports, no plugin imports (manifest's `overlays.explain.imports_from_private: {}`). The `COPY overlay-tree/` step copies an essentially empty (or only-CLAUDE.md) tree — that is fine; the overlay's value is the CLAUDE.md scope.
- [ ] **4.4** Commit. Message: `feat(runtime): add overlay Dockerfiles for review/fix/explain (refs #141)`.

### Task 5 — Author `extract-overlay.sh` + extend manifest schema (subtract_from_shared)

- [ ] **5.1** Author `runtime/scripts/extract-overlay.sh`:
  - Inputs: env `MANIFEST` (path to `runtime/ci-manifest.yaml`), `OVERLAY` (`review|fix|explain`), `PRIVATE_TREE` (cloned private repo path), `MARKETPLACE_TREE` (cloned marketplace path), `OUT_DIR` (where to write the materialized overlay-tree).
  - **Phase A — additive imports** (existing master-plan behavior):
    1. Read `overlays.<OVERLAY>.imports_from_private.agents`; copy each named `<name>.md` from `${PRIVATE_TREE}/agents/` into `${OUT_DIR}/agents/`.
    2. Read `overlays.<OVERLAY>.plugins.<plugin>.paths`; copy matching files from `${MARKETPLACE_TREE}/plugins/<plugin>/` (or `external_plugins/<plugin>/` per Phase 2 fix) into `${OUT_DIR}/plugins/<plugin>/`.
  - **Phase B — subtractive removals** (NEW per Deviation #10 / Charge 3 of pass 1):
    3. Read `overlays.<OVERLAY>.subtract_from_shared.plugins` (default empty list). For each plugin name, write a sentinel marker to `${OUT_DIR}/.subtract/plugins/<name>` (zero-byte file, just for Dockerfile to read). The actual `rm -rf` happens in the overlay's Dockerfile *after* the COPY step (because `OUT_DIR` is the *additive* tree; the inherited base tree from FROM is what we need to subtract from). See Task 5.4 for the Dockerfile RUN step that consumes the marker.
    - **Why a marker file, not a separate manifest read in the Dockerfile:** Dockerfiles can't read manifest YAML at build time; they can `RUN find /opt/claude/.claude/.subtract/plugins -type f`. Marker files keep the manifest as the single source of truth and the Dockerfile dumb.
  - **Determinism (per Deviation #12 / Charge 12 of pass 1):** same rules as `extract-shared.sh` — `LC_ALL=C` sort, `umask 022`, `touch -d @0` on every output file, no embedded timestamps. **Determinism replay is mandatory in STAGE 1c-determinism** (Task 9.1).
  - **Empty-overlay edge case:** when `overlays.<OVERLAY>.imports_from_private` is empty AND `subtract_from_shared` is empty (e.g. base-line `explain`), `OUT_DIR` contains only the directory itself. Dockerfile's `COPY overlay-tree/ /opt/claude/.claude/` succeeds; downstream `find /opt/claude/.claude/.subtract -type f` is empty; no subtraction happens. Verify: an empty `OUT_DIR` produces a valid `COPY` source.
- [ ] **5.2** **In-image expected.yaml hash assertion** (R6 build-time check, with CRLF guard per Charge 7 of pass 1):
  - Pre-COPY check: `file "runtime/overlays/<verb>/expected.yaml" | grep -q CRLF && { echo "ERROR expected_yaml_has_crlf file=<path>" >&2; exit 1; }`. CRLF in the source-tree file fails STAGE 3 immediately, not silently.
  - Post-build check: `docker run --rm --entrypoint /bin/sh "$STAGED_IMAGE" -c 'sha256sum /opt/claude/.expected.yaml'` → compare to `sha256sum runtime/overlays/<verb>/expected.yaml`. Mismatch → fail STAGE 3 cell with `ERROR expected_yaml_image_hash_mismatch overlay=<verb>`.
- [ ] **5.3** **Schema update** — extend `runtime/ci-manifest.schema.json` to add the `overlays.<verb>.subtract_from_shared.plugins` field (array of strings; default empty). Each name MUST be a key in `shared.plugins` (validated by `validate-manifest.sh` semantic check — fail `ERROR subtract_from_shared_unknown_plugin name=<name>` if not). This prevents typos like `subtract_from_shared.plugins: [skill_creator]` (underscore not hyphen) silently no-op'ing.
- [ ] **5.4** **Manifest update** — edit `runtime/ci-manifest.yaml` to add:
  ```yaml
  overlays:
    review:
      # ... existing fields ...
      subtract_from_shared:
        plugins: [skill-creator]      # §10.2 must_not_contain compliance
  ```
  Note: `fix` and `explain` overlays do NOT need `subtract_from_shared` — they accept skill-creator as part of base.
- [ ] **5.5** **Dockerfile RUN-step extension** — amend each overlay Dockerfile (Task 4.1/4.2/4.3) to include after the `COPY overlay-tree/` step:
  ```dockerfile
  # Honor subtract_from_shared.plugins markers (per Deviation #10)
  RUN if [ -d /opt/claude/.claude/.subtract/plugins ]; then \
        for marker in /opt/claude/.claude/.subtract/plugins/*; do \
          [ -e "$marker" ] || continue; \
          plugin=$(basename "$marker"); \
          echo "subtracting plugin: $plugin"; \
          rm -rf "/opt/claude/.claude/plugins/$plugin"; \
        done; \
        rm -rf /opt/claude/.claude/.subtract; \
      fi
  ```
  The `for marker in /opt/claude/.claude/.subtract/plugins/*` loop is no-op when the dir doesn't exist (the `[ -d ... ]` guard) AND no-op when it exists but is empty (the `[ -e "$marker" ] || continue` guard handles unexpanded glob). Adapt this snippet identically across all three overlay Dockerfiles.
- [ ] **5.6** Commit. Message: `feat(runtime): extract-overlay.sh + subtract_from_shared.plugins for §10.2 compliance (refs #141)`.

### Task 6 — Author overlay CLAUDE.md content

Each CLAUDE.md is the load-bearing artifact (Deviations #2). Per §3.4 layer 2, the overlay CLAUDE.md is the active persona at job time and must be self-contained for its verb scope.

#### 6.A `runtime/overlays/review/CLAUDE.md`

- [ ] **6.A.1** Content outline:
  - **Header:** "Review-scoped CLAUDE.md — code review only."
  - **Scope statement:** This overlay performs PR review only. It MUST NOT invoke `code-writer`, `debugger`, refactor agents, or apply-fix behaviors. The only code-reviewer agent on disk is the one shipped by `pr-review-toolkit` (P1 install) — explicitly NOT a code-reviewer imported from personal config. This is the "different eyes" guarantee per §3.1 and §10.2.
  - **Available agents** (verb-scoped): `inquisitor` (private import) for adversarial critique; `code-reviewer`, `code-simplifier`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer` (from `pr-review-toolkit`).
  - **Forbidden behaviors:** writing files, creating commits, pushing branches, opening PRs (this overlay reviews — it does not author). If a finding requires a fix, the reviewer recommends it; the `fix` overlay applies it in a separate run.
  - **Output contract:** review findings posted as PR review comments. Severity markers per the quality-gate contract (PR #179): `🔴 Critical`, `🟡 High-Priority`, etc. — these are mechanically scanned by the quality-gate workflow.
- [ ] **6.A.2** Write the file. Replace the Phase 1 stub. Approximate length: 80–120 lines.
- [ ] **6.A.3** Commit.

#### 6.B `runtime/overlays/fix/CLAUDE.md`

- [ ] **6.B.1** Content outline:
  - **Header:** "Fix-scoped CLAUDE.md — write, fix, refactor on the consumer's branch."
  - **Scope statement:** This overlay applies code changes to the consumer's branch. It commits and pushes. It MUST NOT invoke review-overlay agents (`inquisitor`, `code-reviewer`, `comment-analyzer`, `pr-test-analyzer`) — that's the "different eyes" guarantee.
  - **Available agents:** `debugger`, `code-writer` (private imports per `overlays.fix.imports_from_private`).
  - **`--read-only` mode contract:** when invoked with `--read-only` (Phase 4 router output `mode=read-only`), the overlay MUST produce NO commits. Diagnosis-only output goes to PR comments.
  - **`--no-verify` is forbidden:** never skip git hooks. If pre-commit rejects, let the commit fail; do not bypass. Per §9.2 — consumer hook compliance is non-negotiable.
  - **Apply-fix discipline:** validate diffs against protected paths (`.github/`, `runtime/`) before applying; reject anything touching the runtime config from a `fix` invocation. (Cross-references existing `apply-fix/action.yml` validation rules.)
- [ ] **6.B.2** Write the file. Replace the Phase 1 stub. Approximate length: 80–120 lines.
- [ ] **6.B.3** Commit.

#### 6.C `runtime/overlays/explain/CLAUDE.md`

- [ ] **6.C.1** Content outline:
  - **Header:** "Explain-scoped CLAUDE.md — read-only explanation."
  - **Scope statement:** This overlay explains code, errors, logs, or git history to the commenter. It MUST NOT write files, MUST NOT create commits, MUST NOT push.
  - **Available agents:** none beyond what the base provides (manifest's `overlays.explain.imports_from_private: {}`).
  - **Tool boundary:** even though the underlying CLI has `Edit`/`Write` tool capability, the persona explicitly forbids invoking them. This is mechanism-dependent (relies on the model honoring the persona). Defense-in-depth would require a tool-deny hook — tracked as a Phase 6 follow-up; v1 relies on persona scope.
- [ ] **6.C.2** Write the file. Replace the Phase 1 stub. Approximate length: 50–80 lines (smallest of the three — explain is read-only and has no agent surface to document).
- [ ] **6.C.3** Commit.

### Task 7 — Author overlay `expected.yaml` files (per Plugin Truth Table)

The contents below match the Plugin Truth Table preamble exactly. `microsoft-docs` is omitted (Phase 2 drop; spec §10.2 example is doc-out-of-date — amended in Task 12). `must_contain.skills` declares only verb-specific minima per Plugin Truth Table Note 3 (base skills `git`/`python` are asserted by base smoke).

- [ ] **7.A** Author `runtime/overlays/review/expected.yaml`:
  ```yaml
  must_contain:
    agents: [inquisitor, comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier]
    plugins: [context7, github, typescript-lsp, security-guidance, pr-review-toolkit]
  must_not_contain:
    agents: [code-writer, debugger]
    plugins: [skill-creator]
  ```
- [ ] **7.B** Author `runtime/overlays/fix/expected.yaml`:
  ```yaml
  must_contain:
    agents: [debugger, code-writer]
    plugins: [context7, github, typescript-lsp, security-guidance]
  must_not_contain:
    agents: [inquisitor, code-reviewer, comment-analyzer, pr-test-analyzer]
    plugins: [pr-review-toolkit]
  ```
- [ ] **7.C** Author `runtime/overlays/explain/expected.yaml`:
  ```yaml
  must_contain:
    plugins: [context7, github, typescript-lsp, security-guidance]
  must_not_contain:
    agents: [code-writer, debugger, inquisitor, code-reviewer]
    plugins: [pr-review-toolkit]
  ```
- [ ] **7.D** Author `.gitattributes` rule (per Charge 7 of pass 1) for line-ending pinning:
  - If `.gitattributes` exists at repo root, append: `runtime/overlays/*/expected.yaml text eol=lf`
  - If it does not exist, create it with the line above.
  - Verify: `git ls-files --eol runtime/overlays/*/expected.yaml` shows `i/lf w/lf attr/text=auto eol=lf` for each.
  - This guarantees R6 hash agreement across platforms (Phase 6 forensic readers on macOS/Linux/Windows all see the same bytes).
- [ ] **7.E** Commit all four. Message: `feat(runtime): add overlay expected.yaml + .gitattributes per Plugin Truth Table (refs #141)`.

### Task 8 — STAGE 4 overlay smoke wiring

- [ ] **8.1** Decision: keep Phase 2's `stage-4` job (renamed to `stage-4-base`) for base smoke; add a new `stage-4-overlay` job with a matrix on `overlay: [review, fix, explain]`. **Why two jobs, not one:** base smoke has no `expected.yaml`; overlay smoke does. Bundling them into one matrix with conditional `if` gates obscures the contract. Two jobs is more explicit and matches §6.2's STAGE 4 description ("for each image" — base + three overlays).
- [ ] **8.2** Each `stage-4-overlay` matrix cell:
  - `needs: stage-3` (which produces per-overlay digest outputs).
  - Pulls `ghcr.io/glitchwerks/claude-runtime-${{ matrix.overlay }}:pending-${{ github.sha }}`.
  - Calls `bash runtime/scripts/overlay-smoke.sh "$IMAGE" "${{ matrix.overlay }}"` with `EXPECTED_FILE=runtime/overlays/${{ matrix.overlay }}/expected.yaml`.
  - `continue-on-error: false` per §9.1.
  - `fail-fast: false` per Deviations #9 (let all three failures surface in one run).
- [ ] **8.3** STAGE 4-overlay job-level output: pass through each cell's exit code. STAGE 5 (Phase 6 territory) gates on STAGE 4-overlay AND STAGE 4-base.

### Task 9 — Append STAGE 1c (fixture replay + determinism) + STAGE 3 (build matrix) to `runtime-build.yml`

- [ ] **9.1** STAGE 1c — split into two parallel sub-jobs:
  - **`stage-1c-fixture`** (matcher fixture replay; ~10s):
    - `needs: stage-1`, `runs-on: ubuntu-latest`, timeout 5m.
    - Steps: replay all six fixture cases (the original two from Phase 2 + four added in Task 2.4).
  - **`stage-1c-determinism`** (per Deviation #12 / Charge 12 of pass 1; mandatory; ~30s):
    - `needs: stage-1`, `runs-on: ubuntu-latest`, timeout 5m.
    - Re-clone private + marketplace (new job, new runner) — yes, this duplicates STAGE 2's clone work; the cost is acceptable per the master plan's "STAGE 1→STAGE 2 artifact handoff" deferral.
    - For each overlay in `[review, fix, explain]`: run `extract-overlay.sh` twice into two separate `OUT_DIR`s with identical inputs; assert byte-identical via `diff -r` AND `sha256sum -c` over the materialized tree. Failure → fail STAGE 1c hard with `ERROR extract_overlay_nondeterministic overlay=<name>`.
  - **Why two sub-jobs not one:** parallelism — both ~30s; running serially would block STAGE 2 by an extra 30s. Naming `stage-1c-*` keeps the dashboard readable.
- [ ] **9.2** STAGE 3 — overlay build matrix.
  - Job: `stage-3`, `needs: [stage-2, stage-1c-fixture, stage-1c-determinism]`, `runs-on: ubuntu-latest`, timeout 20m per cell.
  - Matrix: `overlay: [review, fix, explain]`, `max-parallel: 3`, `fail-fast: false` (Deviations #9), implicit `continue-on-error: false`.
  - Per-cell BEFORE the build step, capture the base CLI version from base's labels (per Deviation #11 / Charge 11 of pass 1):
    ```bash
    docker pull "ghcr.io/glitchwerks/claude-runtime-base@sha256:${{ needs.stage-2.outputs.base_digest }}"
    CLI_VERSION=$(docker inspect "ghcr.io/glitchwerks/claude-runtime-base@sha256:${{ needs.stage-2.outputs.base_digest }}" \
      --format '{{ index .Config.Labels "dev.glitchwerks.ci.cli_version" }}')
    [ -n "$CLI_VERSION" ] || { echo "ERROR base_image_cli_version_label_empty digest=${{ needs.stage-2.outputs.base_digest }}" >&2; exit 1; }
    echo "CLI_VERSION=$CLI_VERSION" >> "$GITHUB_ENV"
    ```
  - Steps per cell:
    - Checkout (depth 1).
    - Re-clone private + marketplace (same as STAGE 2 — new job, new runner).
    - Install yq.
    - Run `extract-overlay.sh` with `OVERLAY=${{ matrix.overlay }}`, `OUT_DIR=${{ runner.temp }}/build-context/overlay-tree`.
    - Copy overlay-specific Dockerfile + CLAUDE.md + expected.yaml into the build context. Pre-COPY: run the CRLF-reject check from Task 5.2.
    - Compute cache key (overlay-specific tuple — see 9.3).
    - Login to GHCR.
    - `docker/build-push-action@v7` with build-args:
      ```
      BASE_DIGEST=${{ needs.stage-2.outputs.base_digest }}
      PRIVATE_REF=${{ env.PRIVATE_REF }}
      PRIVATE_SHA=${{ env.PRIVATE_SHA }}
      MARKETPLACE_SHA=${{ env.MARKETPLACE_SHA }}
      PUB_SHA=${{ github.sha }}
      CLI_VERSION=${{ env.CLI_VERSION }}
      ```
      Push tags `:pending-${{ github.sha }}` and `:${{ github.sha }}`. Cache: `cache-from: type=gha,scope=overlay-${{ matrix.overlay }}-${{ steps.cache-key.outputs.key }}`; `cache-to: type=gha,mode=max,scope=overlay-${{ matrix.overlay }}-${{ steps.cache-key.outputs.key }}`. Provenance default-on.
    - **Build-time R6 hash assertion** (Task 5.2): pull the just-pushed image, exec into it, sha256 the in-image expected.yaml, compare to source-tree expected.yaml. Mismatch → fail cell.
    - Echo digest to cell output.
  - Job-level outputs: `digest_review`, `digest_fix`, `digest_explain` — captured from each cell's `steps.build.outputs.digest` via the `${{ matrix.overlay }}` indirection. **GHA matrix output gotcha:** matrix-job outputs are not directly addressable by matrix-key — the canonical pattern is to write each cell's digest to a `runner.temp` file, upload as an artifact named `digest-${{ matrix.overlay }}`, and have a downstream `stage-3-collect` job download all three artifacts to expose `outputs.digest_<verb>`. Implement this collection pattern; do not invent a new mechanism.
- [ ] **9.3** STAGE 3 cache-key + cache-scope spec per overlay (per Charge 1 of pass 1):
  - **Cache-key tuple components** (truncated to 12 chars each, joined with `-`, in this order):
    - `BASE_DIGEST:0:12` — **leading position is critical:** any base-digest change starts a fresh cache scope, defeating the Buildx layer-content reuse risk Charge 1 names.
    - `MANIFEST_HASH:0:12` — manifest changes (e.g. new `subtract_from_shared.plugins` entry) bust cache.
    - `PRIVATE_SHA:0:12`
    - `MARKETPLACE_SHA:0:12`
    - `EXTRACT_OVERLAY_HASH:0:12` — `runtime/scripts/extract-overlay.sh` content hash.
    - `OVERLAY_DOCKERFILE_HASH:0:12` — `runtime/overlays/${OVERLAY}/Dockerfile`.
    - `OVERLAY_CLAUDE_MD_HASH:0:12` — `runtime/overlays/${OVERLAY}/CLAUDE.md`.
    - `OVERLAY_EXPECTED_HASH:0:12` — `runtime/overlays/${OVERLAY}/expected.yaml`.
    - `CLI_VERSION` — the literal version string captured from base label (NOT a hash; ~10 chars). The CLI version is the same across all three overlays because they inherit from the same base, so this is constant per STAGE 3 run; it is included for forensic clarity.
  - **Cache scope string:** `cache-from`/`cache-to` use `scope=overlay-${OVERLAY}-${KEY}`. The `${OVERLAY}` prefix isolates per-verb caches (so the review build cannot reuse a fix-overlay cache layer for the wrong RUN steps); the `${KEY}` suffix isolates per-base-digest caches (per Charge 1).
  - **Why FROM-line interpolation is not enough** (per Charge 1): Buildx layer-content addressing means a cache layer written under one base digest can be reused under another if the underlying content matches. The FROM-line `@sha256:${BASE_DIGEST}` interpolation invalidates *materially-different* layers but not *opportunistically-shared* layers. The `BASE_DIGEST:0:12` cache-scope component is the load-bearing isolation mechanism.
  - **Excluded** (deliberate, with rationale):
    - `SMOKE_HASH`, `INVENTORY_MATCH_HASH`, `ENUMERATE_PERSONA_HASH` — these run *against* the image during STAGE 4, not *into* the image during build. Smoke contract changes don't need to bust the image-build cache; STAGE 4 always runs against the freshly-built image.
    - Phase 2's base `Dockerfile` hash — covered by `BASE_DIGEST` (any base Dockerfile change → new base build → new digest → new cache scope).
- [ ] **9.4** Append STAGE 4-overlay job after STAGE 3. Wire matrix per Task 8. STAGE 4-overlay's `needs:` includes `stage-3-collect` (the artifact-collection job from Task 9.2) so it can address per-verb digests.
- [ ] **9.5** Commit. Message: `ci(runtime): append STAGE 1c-fixture + STAGE 1c-determinism + STAGE 3 + STAGE 4-overlay (refs #141)`.

### Task 10 — `actionlint` clean-up + lint-pass

- [ ] **10.1** Run `actionlint` locally (or rely on the `lint.yml` workflow on the PR — Phase 1 wires this).
- [ ] **10.2** Address any findings. SC2129 grouping (`>> $GITHUB_OUTPUT` redirects in a `{ } >> "$GITHUB_OUTPUT"` block) is the most common — same as Phase 2.
- [ ] **10.3** Commit. Message: `chore(runtime): actionlint clean-up for STAGE 3 (refs #141)`.

### Task 11 — Dry-run STAGE 1→2→3→4 + deliberate-regression test

- [ ] **11.1** Trigger `workflow_dispatch(images=all)` against the `phase-3-overlays` branch. Watch:
  - STAGE 1 + STAGE 1c green.
  - STAGE 2 green, base digest captured.
  - STAGE 3 cells: three pending tags land — `claude-runtime-{review,fix,explain}:pending-<sha>`.
  - STAGE 4-base green, STAGE 4-overlay matrix all three green.
- [ ] **11.2** Address any failures iteratively. The most likely failure modes (anticipated; not exhaustive):
  - Plugin path mismatch — `pr-review-toolkit` materialization path differs from base plugins. Diagnose via `enumerate-persona.sh` against the staged image; adjust `extract-overlay.sh`.
  - `microsoft-docs` absence — confirms Task 7.A pre-decision (option a). If still listed somewhere, remove.
  - `must_contain.skills: [git]` failing on `explain` — could be an enumerator bug (skill detection by directory presence); investigate via raw `find` listing.
  - R6 hash assertion failing — typically a CRLF-vs-LF issue if anyone edits expected.yaml on Windows. Fix encoding.
- [ ] **11.3** **Deliberate regression A — `must_contain_missing` on review**: edit `runtime/overlays/review/expected.yaml` to add `code-writer` to `must_contain.agents`. (Do NOT edit any source — code-writer is genuinely absent from review's tree.) Push. Confirm STAGE 4-overlay `review` cell fails with `ERROR inventory_must_contain_missing kind=agents name=code-writer`. Revert.
- [ ] **11.4** **Deliberate regression B — `must_not_contain_present` on fix** (rewritten per Charge 2 of pass 1; original logic was inverted): edit ONLY `runtime/scripts/extract-overlay.sh` to add `inquisitor` to fix's imports — i.e. when `OVERLAY=fix`, also copy `${PRIVATE_TREE}/agents/inquisitor.md` into the fix overlay tree. Do NOT edit `expected.yaml`. Push. Confirm STAGE 4-overlay `fix` cell fails with `ERROR inventory_must_not_contain_present kind=agents name=inquisitor`. The matcher catches it because `inquisitor` is in fix's `must_not_contain.agents` (already there) AND now appears in the fix overlay's enumeration. Revert the `extract-overlay.sh` edit.
- [ ] **11.4b** **Deliberate regression C — `must_contain_missing` on explain** (added per Charge 2 of pass 1): edit `runtime/overlays/explain/expected.yaml` to add `nonexistent-plugin-xyz` to `must_contain.plugins`. (No corresponding source edit — the plugin is absent.) Push. Confirm STAGE 4-overlay `explain` cell fails with `ERROR inventory_must_contain_missing kind=plugins name=nonexistent-plugin-xyz`. Revert. This closes coverage for explain (which had no Task 11 coverage in the pre-pass-1 plan).
- [ ] **11.5** Confirm acceptance criterion 3 from issue #141: each `expected.yaml` negative assertion (`must_not_contain`) catches ≥1 intentional regression. Coverage map:
  - `review.must_not_contain` — exercised by 11.3 (must_contain side) AND 11.4 (must_not_contain side via fix's fail to demonstrate the assertion class works) AND a separate optional regression: add `code-writer` to extract-overlay.sh review imports → expect `ERROR inventory_must_not_contain_present kind=agents name=code-writer` on review (skipped if 11.3+11.4 already satisfy issue acceptance, listed for thoroughness).
  - `fix.must_not_contain` — exercised by 11.4.
  - `explain.must_not_contain` — exercised by editing `extract-overlay.sh` to import `code-writer` for explain → expect `ERROR inventory_must_not_contain_present kind=agents name=code-writer` on explain. Revert. Add as Task 11.5b if dry-run time allows; document the result either way.
- [ ] **11.5b** **Deliberate regression D — `must_not_contain_present` on explain**: as described in 11.5 above. Edit `extract-overlay.sh` only (add `code-writer` to explain's `imports_from_private.agents` materialization). Push. Confirm `ERROR inventory_must_not_contain_present kind=agents name=code-writer`. Revert.
- [ ] **11.6** **Gate sanity check** (per Charge 8 of pass 1) — using the run from 11.3 (where `review` cell fails), inspect the run log for empirical evidence of the §9.1 gating contract:
  - (a) `fix` and `explain` cells DID run to completion (not cancelled by `fail-fast`). Evidence: both cells show `result: success` in the matrix summary.
  - (b) STAGE 3 job-level `result` is `failure` (matrix overall fails when any cell fails, regardless of `fail-fast: false`).
  - (c) Hypothetical downstream `needs: stage-4-overlay` job would NOT run by default. Evidence: GitHub's `needs:` evaluates to `failure` for the dependent job; default behavior skips. Capture the run URL and the matrix result panel as documented evidence in the PR body.
  - This validates Deviation #9 empirically before Phase 6 wires real promotion gating.

### Task 12 — Docs (CLAUDE.md + README.md + spec amendment)

- [ ] **12.1** Update root `CLAUDE.md` "CI Runtime (Phase 1+)" section: add a bullet describing the three overlay images, their digest-pin reference shape, and the inventory assertions contract. Reference Issue #141.
- [ ] **12.2** Update `README.md` (root) — note that `runtime/overlays/` is part of the build surface and that the three overlays each have a verb-scoped persona.
- [ ] **12.3** **Do NOT** add anything to the consumer-facing `pr-review/README.md` etc. — Phase 5 is when consumers see the overlays. Phase 3 is producer-side only.
- [ ] **12.4** **Spec amendment** — `docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md` §10.2 example for `runtime/overlays/review/expected.yaml`: remove `microsoft-docs` from `must_contain.plugins`. Add a footnote: "*Spec amendment 2026-05-02 (PR for #141): `microsoft-docs` was dropped from the manifest in Phase 2 (PR #171) because it does not exist in the marketplace SHA. The example is kept structurally accurate; readers cross-checking against `runtime/overlays/review/expected.yaml` will see the live truth.*"
- [ ] **12.5** **Spec amendment** — same file, §5.1 manifest shape: add `overlays.<verb>.subtract_from_shared.plugins` field documentation (per Deviation #10). Cross-reference Issue #141.
- [ ] **12.6** Commit. Message: `docs: note Phase 3 overlay images + amend §5.1, §10.2 spec (refs #141)`.

### Task 13 — PR open + dogfood pass (PR-time, NOT plan-time)

Plan-time inquisitor passes (the gate for Tasks 4+) are documented in the "Inquisitor passes" section near the top of this plan. The tasks below cover *PR-time* review only — the dogfood `pr-review` workflow firing on this PR + the new `claude-pr-review/quality-gate` status. These are necessary but not sufficient: the plan-time passes must complete first (their findings catch class-of-bugs that PR-time review tends to miss when buried in a large diff).

- [ ] **13.1** Open PR against `main` from `phase-3-overlays`. Title: `Phase 3: review/fix/explain overlay images + expected.yaml + STAGE 3 (closes #141)`. **Body must include:**
  - Closing keyword `Closes #141` on its own line (CLAUDE.md "PRs" section — squash-merge requires the keyword in PR body, not just commit messages).
  - Reference to deferred task 3.12 → #137 (CODEOWNERS).
  - Reference to spec §10.2 + §5.1 amendments (Task 12.4, 12.5).
  - Inquisitor passes section: link to `phase-3-overlays-inquisitor-pass-1.md` and the eventual pass-2 report; summarize that all findings are addressed.
  - Test plan: dry-run results from Task 11 (six runs total — 11.1, 11.3, 11.4, 11.4b, 11.5b, 11.6), deliberate-regression evidence including run URLs.
- [ ] **13.2** Wait for the dogfood `pr-review` workflow + the new `claude-pr-review/quality-gate` status (PR #179 / Issue #176 — released as `v2.1.0`). The quality gate will fail if the bot review surfaces Critical/MAJOR markers; address per `gh-pr-review-address` skill.
- [ ] **13.3** Final pre-merge ritual per `feedback_check_pr_feedback_before_merge.md`: re-fetch live PR state, verify all checks green on the actual commit being merged, address any new feedback. Merge.

---

## Verification / Acceptance

Per Issue #141 acceptance criteria:

- [ ] Three overlay images (`:pending-<pubsha>`) build, push, smoke-test green — exercised by Task 11.
- [ ] Inventory assertions reject a deliberate "import `code-writer` into review" edit — exercised by Task 11.3.
- [ ] Each `expected.yaml` negative assertion (`must_not_contain`) catches at least one intentional regression in dry-run — Task 11.4 exercises fix overlay; the symmetric exercise for review (already covered by 11.3) and explain (covered by adding `code-writer` to fix's `imports_from_private` and verifying explain's enumeration is unchanged) closes the criterion.
- [ ] `actionlint` passes — Task 10.

Plus this plan's own acceptance:

- [ ] R1–R6 (Phase 5 contract) verified.
- [ ] Phase 2 fixture (`expected-matcher-fixture/`) replays green against the new `inventory-match.sh` — Task 2.3.
- [ ] Two inquisitor passes complete with findings addressed — Task 13.3, 13.4.
- [ ] PR #179's quality-gate status posts `success` on the final commit — Task 13.5.
- [ ] No worktrees left behind (`commit-commands:clean_gone` after merge) — post-merge cleanup ritual.

---

## Inquisitor pass status

**Pass 1:** complete (2026-05-02). 15 findings across 4 severity tiers. Report at `phase-3-overlays-inquisitor-pass-1.md`. All resolved inline in this revision (see "Pass 1 findings addressed" section near the top of the plan).

**Pass 2:** pending. After this revision lands, dispatch a second adversarial pass with the explicit charge: "find *new* gaps introduced by Pass 1's revisions." Phase 2 pass 2 caught the `--entrypoint` silent-false-pass — a class-of-bug specifically born in pass-1 revisions. Likely candidates for pass 2 to scrutinize:

- The new `subtract_from_shared.plugins` mechanism (Deviation #10 / Task 5) — does the marker-file approach handle all edge cases? What if `subtract_from_shared.plugins: [name-with-dot.bar]` collides with a basename of an unrelated marker?
- The cache-scope construction (Task 9.3) — is `BASE_DIGEST:0:12` collision-resistant across simultaneous main builds? (12 chars of SHA-256 = 48 bits ≈ 1-in-281T collision; fine for our scale, but document.)
- The matcher's exit-code triage (0/1/2) — is any caller (e.g. STAGE 4-overlay) treating exit codes 1 and 2 identically when they should be distinguished?
- The R6 build-time hash assertion + CRLF-reject step (Task 5.2) — does a Windows-edited expected.yaml authored in a worktree on the build runner ever land with a CRLF the runner doesn't reject? (Should be "no" given `.gitattributes`, but verify the assertion order.)
- The STAGE 1c-determinism replay (Task 9.1 sub-job) — does it actually exercise the same input set as the real STAGE 3 build, or is there a divergent code path?
- The `enumeration_no_persona` guard (Task 2.1) — does it ever fire incorrectly on a legitimate explain overlay (which has very few persona files)?

**Hard checkpoint** (re-stated): Tasks 4+ DO NOT begin until Pass 2 completes and findings are addressed. Tasks 1–3 (matcher, enumerator, wrapper) MAY proceed in parallel with Pass 2 because their outputs are testable in isolation against the existing fixture and any Pass 2 changes localize to those scripts.
