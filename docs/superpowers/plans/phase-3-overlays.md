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

9. **STAGE 3 matrix uses `fail-fast: false` AND `continue-on-error: false`.** These look contradictory. They're not: `continue-on-error: false` means a failed cell fails the job (not "ignore the failure"); `fail-fast: false` means **other** matrix cells continue running when one cell fails. We want both: if `review` fails its smoke, don't auto-cancel `fix` and `explain` (we want to see all three failure modes in one run), but still fail the overall STAGE 3 job so STAGE 5 promote never runs. §9.1 requires "one overlay failing blocks ALL promotion" — that's enforced by the job-level fail, not by cell-level fail-fast.

Items deferred (with explicit triggers):

- **Dockerfile lint step rejecting `npm install @anthropic-ai/claude-code` outside base/Dockerfile.** Rationale: Deviation #7 above. Trigger: someone proposes an overlay Dockerfile that re-installs the CLI; lint rejects it. Tracked as a follow-up issue to file in Phase 3 PR body if not already present.
- **CODEOWNERS demonstration of "different eyes" ownership split** — task 3.12 in master plan, deferred to issue [#137](https://github.com/glitchwerks/github-actions/issues/137) per master plan. Phase 3 PR body must reference the deferral. Inventory assertions still provide post-merge mechanical enforcement; pre-merge enforcement follows #137.
- **Marketplace bump review containment automation** — §10.2 requires every PR that bumps `sources.marketplace.ref` to include a `git diff` summary of plugin directories. Currently a manual reviewer expectation. Tracked as a Phase 6 / Phase 7 automation; not Phase 3.
- **Multi-arch overlays** — same deferral as Phase 2 base. Builds linux/amd64 only.
- **STAGE 1 → STAGE 3 artifact handoff** to avoid double-cloning private + marketplace — same deferral as Phase 2 STAGE 2.

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
  - **Name extraction rules:**
    - `agents`: any file matching `/opt/claude/.claude/agents/<name>.md` → name is the basename without `.md`. Subdirectories under `agents/` are not v1.
    - `skills`: any directory matching `/opt/claude/.claude/skills/<name>/` (detected by ≥1 file under it) → name is the directory name. Skills are directories of files (`SKILL.md` + helpers); enumerating by listing all directories with at least one file under them avoids duplicating skill names.
    - `plugins`: any file under `/opt/claude/.claude/plugins/<name>/` → name is the directory name. Same dedup approach as skills.
  - Names are sorted (LC_ALL=C lexicographic) and deduplicated. Exit 0 on success; exit 1 with stderr line `ERROR enumeration_failed image=<ref>` if `docker run` fails.
- [ ] **2.2** Author `runtime/scripts/inventory-match.sh`:
  - Inputs: `JSON_FILE` (positional 1; output of `enumerate-persona.sh`), `EXPECTED_FILE` (positional 2; an `expected.yaml`).
  - Dependencies: `jq`, `yq` (v4 — already on runner from Phase 2's STAGE 2).
  - Behavior:
    1. Parse `expected.yaml` into four arrays: `must_contain.{agents,skills,plugins}` and `must_not_contain.{agents,plugins}`. Missing keys default to empty arrays. (No `must_not_contain.skills` in v1 — §10.2 spec; reject with a hard error if the file specifies one.)
    2. For each name in `must_contain.<kind>`: assert `name` is in the JSON's `<kind>` array. Missing → emit `ERROR inventory_must_contain_missing kind=<kind> name=<name>` to stderr.
    3. For each name in `must_not_contain.<kind>`: assert `name` is NOT in the JSON's `<kind>` array. Present → emit `ERROR inventory_must_not_contain_present kind=<kind> name=<name>` to stderr.
    4. **Report ALL violations before exiting** (do not short-circuit). Per the matcher contract in `smoke-test.sh:144`.
    5. Exit 0 if no violations; exit 1 if any.
  - **Comparison semantics:** exact-match string equality. No glob, no regex, no case-folding.
  - **Schema-of-expected check:** if `expected.yaml` has any top-level key other than `must_contain` and `must_not_contain`, fail with `ERROR expected_yaml_unknown_top_level_key key=<key>`. If `must_contain.skills` exists but is not an array, fail with `ERROR expected_yaml_invalid_type ...`. Be strict — a malformed expected.yaml is a Phase 3 owner bug, not silently-tolerable input.
- [ ] **2.3** Replay the Phase 2 fixture against the new matcher to verify contract conformance:
  - `bash runtime/scripts/inventory-match.sh runtime/scripts/tests/expected-matcher-fixture/enumeration-pass.json runtime/scripts/tests/expected-matcher-fixture/expected.yaml` → expect exit 0, no stderr.
  - `bash runtime/scripts/inventory-match.sh runtime/scripts/tests/expected-matcher-fixture/enumeration-fail.json runtime/scripts/tests/expected-matcher-fixture/expected.yaml` → expect exit 1, exactly two stderr lines:
    - `ERROR inventory_must_not_contain_present kind=agents name=code-writer`
    - `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`
  - If the matcher produces different output, the matcher is non-conforming. Fix before proceeding.
- [ ] **2.4** Add the fixture replay as a CI step (deferred to Task 9 STAGE 1c — listed here for traceability).
- [ ] **2.5** Commit. Message: `feat(runtime): add inventory-match.sh + enumerate-persona.sh per spec §10.2 (refs #141)`.

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

- [ ] **4.0** Capture the base digest. Run `gh api /users/glitchwerks/packages/container/claude-runtime-base/versions --paginate | jq -r '.[] | select(.metadata.container.tags[] | startswith("46bffd3")) | .name' | head -1` (or the latest `main` SHA at execution time). Record it as the literal `BASE_DIGEST` to use in the Dockerfiles. **Verify** the digest pulls cleanly: `docker pull ghcr.io/glitchwerks/claude-runtime-base@sha256:<digest>` — if `manifest unknown`, the digest was GC'd or wrong; STOP.
- [ ] **4.1** Author `runtime/overlays/review/Dockerfile`:
  ```dockerfile
  ARG BASE_DIGEST
  FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}

  ARG OVERLAY=review
  ARG PRIVATE_REF
  ARG PRIVATE_SHA
  ARG MARKETPLACE_SHA
  ARG PUB_SHA

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
        dev.glitchwerks.ci.cli_version="" \
        dev.glitchwerks.ci.overlay="${OVERLAY}"
  ```
  Note: `cli_version` is empty in the overlay's labels because the binary is inherited from the base — the base's label is the source of truth; querying the overlay for the CLI version requires reading the base via `docker history` or tracing the FROM. **Decision:** keep the label, set it empty, document that "to learn the CLI version, read the base image's `dev.glitchwerks.ci.cli_version` label." Alternative (set to base's value, requires extra build-arg) deferred — empty is honest.
- [ ] **4.2** Author `runtime/overlays/fix/Dockerfile` — same as review except `ARG OVERLAY=fix`. No `pr-review-toolkit` (manifest's `overlays.fix.imports_from_private` carries `[debugger, code-writer]`; no overlay-specific plugins).
- [ ] **4.3** Author `runtime/overlays/explain/Dockerfile` — same as review except `ARG OVERLAY=explain`. No agent imports, no plugin imports (manifest's `overlays.explain.imports_from_private: {}`). The `COPY overlay-tree/` step copies an essentially empty (or only-CLAUDE.md) tree — that is fine; the overlay's value is the CLAUDE.md scope.
- [ ] **4.4** Commit. Message: `feat(runtime): add overlay Dockerfiles for review/fix/explain (refs #141)`.

### Task 5 — Author `extract-overlay.sh` (the per-overlay analog of Phase 2's extract-shared.sh)

- [ ] **5.1** Author `runtime/scripts/extract-overlay.sh`:
  - Inputs: env `MANIFEST` (path to `runtime/ci-manifest.yaml`), `OVERLAY` (`review|fix|explain`), `PRIVATE_TREE` (cloned private repo path), `MARKETPLACE_TREE` (cloned marketplace path), `OUT_DIR` (where to write the materialized overlay-tree).
  - Behavior: read `overlays.<OVERLAY>.imports_from_private.agents` and copy each named `<name>.md` from `${PRIVATE_TREE}/agents/` into `${OUT_DIR}/agents/`. Read `overlays.<OVERLAY>.plugins.<plugin>.paths` and copy matching files from `${MARKETPLACE_TREE}/plugins/<plugin>/` (or `external_plugins/<plugin>/` per Phase 2 fix in `extract-shared.sh`) into `${OUT_DIR}/plugins/<plugin>/`.
  - **Determinism:** same rules as `extract-shared.sh` — `LC_ALL=C` sort, `umask 022`, `touch -d @0` on every output file, no embedded timestamps. STAGE 1c can include a determinism replay analogous to Phase 2's STAGE 1b (consider whether worth the CI minutes — see Deviations #1 trade-off).
  - **Empty-overlay edge case:** when `overlays.<OVERLAY>.imports_from_private` is empty (e.g. `explain`), `OUT_DIR` is created empty (just the directory). Dockerfile's `COPY overlay-tree/ /opt/claude/.claude/` succeeds with a no-op effect. Verify: an empty `OUT_DIR` produces a valid `COPY` source.
- [ ] **5.2** **In-image expected.yaml hash assertion** (R6 build-time check). The `extract-overlay.sh` script does NOT copy `expected.yaml` (that's the Dockerfile's job). The hash assertion happens in STAGE 3 between build and push: after build, run a one-shot `docker run --rm --entrypoint /bin/sh "$STAGED_IMAGE" -c 'sha256sum /opt/claude/.expected.yaml'` and compare to `sha256sum runtime/overlays/<verb>/expected.yaml`. Mismatch → fail STAGE 3 cell with `ERROR expected_yaml_image_hash_mismatch overlay=<verb>`.
- [ ] **5.3** Commit. Message: `feat(runtime): add extract-overlay.sh for verb-scoped overlay tree (refs #141)`.

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

### Task 7 — Author overlay `expected.yaml` files

- [ ] **7.A** Author `runtime/overlays/review/expected.yaml` — verbatim from §10.2:
  ```yaml
  must_contain:
    agents: [inquisitor, comment-analyzer, pr-test-analyzer, silent-failure-hunter, type-design-analyzer, code-reviewer, code-simplifier]
    skills: [git]
    plugins: [context7, github, microsoft-docs, typescript-lsp, security-guidance, pr-review-toolkit]
  must_not_contain:
    agents: [code-writer, debugger]
    plugins: [skill-creator]
  ```
  **Note** on `microsoft-docs`: Phase 2 dropped `microsoft-docs` from the manifest because it does not exist in the marketplace SHA. Verify: is `microsoft-docs` listed in §10.2's example because the spec was authored before Phase 2's drop? **Decision required:** if `microsoft-docs` is genuinely absent from base + review materialized trees, the spec's example `must_contain.plugins` line is wrong. Three options:
  - (a) Remove `microsoft-docs` from the review `expected.yaml` and amend the spec.
  - (b) Add `microsoft-docs` back to the manifest if it's been re-added to a newer marketplace SHA.
  - (c) Ship `expected.yaml` with `microsoft-docs` and accept STAGE 4 failing on review smoke until reconciled.
  - **Pre-decision:** option (a) — reflect the post-Phase-2 reality. Spec amendment is a doc-only follow-up. Verify at Task 11 dry-run that the rest of `must_contain.plugins` resolves.
- [ ] **7.B** Author `runtime/overlays/fix/expected.yaml`:
  ```yaml
  must_contain:
    agents: [debugger, code-writer]
    skills: [git]
    plugins: [context7, github, typescript-lsp, security-guidance]   # base set, minus microsoft-docs (per 7.A); minus skill-creator (review-only must_not_contain says skill-creator absent — confirm at dry-run that it's absent from BASE's materialized tree as well)
  must_not_contain:
    agents: [inquisitor, code-reviewer, comment-analyzer, pr-test-analyzer]
    plugins: [pr-review-toolkit]
  ```
- [ ] **7.C** Author `runtime/overlays/explain/expected.yaml`:
  ```yaml
  must_contain:
    skills: [git]
    plugins: [context7, github, typescript-lsp, security-guidance]   # base set inherited; no overlay agents (manifest has imports_from_private: {})
  must_not_contain:
    agents: [code-writer, debugger, inquisitor, code-reviewer]
    plugins: [pr-review-toolkit]
  ```
  **Note** on `must_contain.agents`: `explain` does not import any agents from private (`imports_from_private: {}`), and the base is also `agents: [ops]`. Confirm: does the explain overlay carry `ops`? Yes — agents in base materialized tree are inherited by the FROM. Add `must_contain.agents: [ops]` if dry-run confirms. (Pre-decision: add `[ops]` to `must_contain.agents` after dry-run validates.)
- [ ] **7.D** Commit all three. Message: `feat(runtime): add overlay expected.yaml inventory contracts per §10.2 (refs #141)`.

### Task 8 — STAGE 4 overlay smoke wiring

- [ ] **8.1** Decision: keep Phase 2's `stage-4` job (renamed to `stage-4-base`) for base smoke; add a new `stage-4-overlay` job with a matrix on `overlay: [review, fix, explain]`. **Why two jobs, not one:** base smoke has no `expected.yaml`; overlay smoke does. Bundling them into one matrix with conditional `if` gates obscures the contract. Two jobs is more explicit and matches §6.2's STAGE 4 description ("for each image" — base + three overlays).
- [ ] **8.2** Each `stage-4-overlay` matrix cell:
  - `needs: stage-3` (which produces per-overlay digest outputs).
  - Pulls `ghcr.io/glitchwerks/claude-runtime-${{ matrix.overlay }}:pending-${{ github.sha }}`.
  - Calls `bash runtime/scripts/overlay-smoke.sh "$IMAGE" "${{ matrix.overlay }}"` with `EXPECTED_FILE=runtime/overlays/${{ matrix.overlay }}/expected.yaml`.
  - `continue-on-error: false` per §9.1.
  - `fail-fast: false` per Deviations #9 (let all three failures surface in one run).
- [ ] **8.3** STAGE 4-overlay job-level output: pass through each cell's exit code. STAGE 5 (Phase 6 territory) gates on STAGE 4-overlay AND STAGE 4-base.

### Task 9 — Append STAGE 1c (matcher fixture replay) + STAGE 3 (build matrix) to `runtime-build.yml`

- [ ] **9.1** STAGE 1c — matcher fixture replay (lightweight; no Docker needed).
  - New job: `stage-1c`, `needs: stage-1`, `runs-on: ubuntu-latest`, timeout 5m.
  - Single step: replay both fixture cases (Task 2.3). Use `bash` exit codes.
  - **Why STAGE 1c, not folded into STAGE 1:** the matcher tests are independent of clones and manifest validation; keeping STAGE 1 focused on "can we build the materialized trees" makes failures easier to triage. STAGE 1c is fast (~5s) so the parallelism cost is trivial.
- [ ] **9.2** STAGE 3 — overlay build matrix.
  - Job: `stage-3`, `needs: stage-2`, `runs-on: ubuntu-latest`, timeout 20m per cell.
  - Matrix: `overlay: [review, fix, explain]`, `max-parallel: 3`, `fail-fast: false` (Deviations #9), implicit `continue-on-error: false`.
  - Steps per cell:
    - Checkout (depth 1).
    - Re-clone private + marketplace (same as STAGE 2 — new job, new runner).
    - Install yq.
    - Run `extract-overlay.sh` with `OVERLAY=${{ matrix.overlay }}`, `OUT_DIR=${{ runner.temp }}/build-context/overlay-tree`.
    - Copy overlay-specific Dockerfile + CLAUDE.md + expected.yaml into the build context.
    - Compute cache key (overlay-specific tuple — see 9.3).
    - Login to GHCR.
    - `docker/build-push-action@v7` with `--build-arg BASE_DIGEST=${{ needs.stage-2.outputs.base_digest }}`, push tags `:pending-<pubsha>` and `:<pubsha>`.
    - **Build-time R6 hash assertion** (Task 5.2): pull the just-pushed image, exec into it, sha256 the in-image expected.yaml, compare to source-tree expected.yaml. Mismatch → fail cell.
    - Echo digest to job output.
  - Job-level outputs: `digest_review`, `digest_fix`, `digest_explain` — captured from each cell's `steps.build.outputs.digest`.
- [ ] **9.3** STAGE 3 cache-key tuple per overlay (analog of Phase 2's STAGE 2 tuple, scoped to overlay):
  - `MANIFEST_HASH` (same as STAGE 2)
  - `PRIVATE_SHA` (same)
  - `MARKETPLACE_SHA` (same)
  - `EXTRACT_OVERLAY_HASH` = sha256 of `runtime/scripts/extract-overlay.sh`
  - `OVERLAY_DOCKERFILE_HASH` = sha256 of `runtime/overlays/<overlay>/Dockerfile`
  - `OVERLAY_CLAUDE_MD_HASH` = sha256 of `runtime/overlays/<overlay>/CLAUDE.md`
  - `OVERLAY_EXPECTED_HASH` = sha256 of `runtime/overlays/<overlay>/expected.yaml`
  - `BASE_DIGEST` = the base image digest from STAGE 2 (`needs.stage-2.outputs.base_digest`)
  - **`SMOKE_HASH` and `INVENTORY_MATCH_HASH` excluded** — those scripts run *against* the image during STAGE 4, not *into* the image during build. Cache busts on smoke contract changes are not needed at the image-build cache layer; STAGE 4 always runs against the freshly-built image.
- [ ] **9.4** Append STAGE 4-overlay job after STAGE 3. Wire matrix per Task 8.
- [ ] **9.5** Commit. Message: `ci(runtime): append STAGE 1c + STAGE 3 + STAGE 4-overlay (refs #141)`.

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
- [ ] **11.3** **Deliberate regression**: edit `runtime/overlays/review/expected.yaml` to add `code-writer` to `must_contain.agents`. Push. Confirm STAGE 4-overlay `review` cell fails with `ERROR inventory_must_contain_missing kind=agents name=code-writer`. Revert.
- [ ] **11.4** **Second deliberate regression**: edit `runtime/overlays/fix/expected.yaml` to remove `inquisitor` from `must_not_contain.agents`, then edit `extract-overlay.sh` to also import `inquisitor` for the fix overlay. Push. Confirm STAGE 4-overlay `fix` cell fails with `ERROR inventory_must_not_contain_present kind=agents name=inquisitor`. Revert both.
- [ ] **11.5** Confirm `must_not_contain` negative assertions catch ≥1 intentional regression in dry-run (acceptance criterion 3 from issue body).

### Task 12 — Docs (CLAUDE.md + README.md)

- [ ] **12.1** Update root `CLAUDE.md` "CI Runtime (Phase 1+)" section: add a bullet describing the three overlay images, their digest-pin reference shape, and the inventory assertions contract. Reference Issue #141.
- [ ] **12.2** Update `README.md` (root) — note that `runtime/overlays/` is part of the build surface and that the three overlays each have a verb-scoped persona.
- [ ] **12.3** **Do NOT** add anything to the consumer-facing `pr-review/README.md` etc. — Phase 5 is when consumers see the overlays. Phase 3 is producer-side only.
- [ ] **12.4** Commit. Message: `docs: note Phase 3 overlay images in CLAUDE.md + README (refs #141)`.

### Task 13 — PR open + dogfood pass

- [ ] **13.1** Open PR against `main` from `phase-3-overlays`. Title: `Phase 3: review/fix/explain overlay images + expected.yaml + STAGE 3 (closes #141)`. **Body must include:**
  - Closing keyword `Closes #141` on its own line (CLAUDE.md "PRs" section — squash-merge requires the keyword in PR body, not just commit messages).
  - Reference to deferred task 3.12 → #137.
  - Reference to spec §10.2 amendment for `microsoft-docs` (if Task 7.A took option a).
  - Test plan: dry-run results from Task 11, deliberate-regression evidence.
- [ ] **13.2** Wait for the dogfood `pr-review` workflow + the new `claude-pr-review/quality-gate` status (PR #179 / Issue #176 — released as `v2.1.0`). The quality gate will fail if the bot review surfaces Critical/MAJOR markers; address per `gh-pr-review-address` skill.
- [ ] **13.3** **Inquisitor pass 1** — invoke `inquisitor` agent against this plan + the implementation. Address findings on-branch.
- [ ] **13.4** **Inquisitor pass 2** — second adversarial pass after pass 1's revisions land. Per `feedback_inquisitor_twice_for_large_design.md` — pass 2 has historically caught a critical bug pass 1 missed (Phase 2 envelope-shape bug). Address findings.
- [ ] **13.5** Final pre-merge ritual per `feedback_check_pr_feedback_before_merge.md`: re-fetch live PR state, verify all checks green on the actual commit being merged, address any new feedback. Merge.

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

## Inquisitor mandate (passes 1 + 2)

Per `feedback_inquisitor_twice_for_large_design.md`: this plan crosses the "large design" threshold by virtue of (a) introducing a new STAGE (3) with a parallel matrix, (b) introducing a new contract artifact (`expected.yaml` + matcher) consumed by Phase 5, and (c) shipping three new images each with its own verb-scoped persona that downstream callers depend on.

**Pass 1 charge:** read the plan as a hostile adversary who wants to find ways the matcher silently passes when it shouldn't. Specifically check:

1. Does the matcher exit 0 on an empty `expected.yaml`? (Should it? Document.)
2. Can a malformed YAML in `expected.yaml` produce a silent no-op match instead of an explicit error?
3. Does the enumeration script handle the case where `find` succeeds but produces zero output (e.g. mounted volume issue)? Does it fail loudly or pass silently?
4. Is the R6 in-image hash assertion susceptible to the LF/CRLF or trailing-newline drift that has historically caused similar checks to flap?
5. Does STAGE 3 cache invalidate correctly on a `runtime/overlays/<verb>/CLAUDE.md` edit only? (I.e. is `OVERLAY_CLAUDE_MD_HASH` actually distinct per verb in the cache scope?)
6. Is there a sequence of merges where the base digest changes but STAGE 3 doesn't rebuild because the overlay tree files haven't changed? (Cache-key tuple should prevent — verify.)
7. Does the fix overlay's `must_not_contain` actually catch all four "wrong agent" cases, or just the named four?
8. Is the deliberate-regression test (Task 11.3) actually testing what it claims, or could it pass for the wrong reason?

**Pass 2 charge:** post-pass-1, read the revised plan looking for *new* gaps introduced by pass 1's revisions. Especially: did adding a new step or check create a new silent-failure mode? (Phase 2 pass 2 caught the `--entrypoint` silent-false-pass; this is the kind of class-of-bug pass 2 specializes in.)

After pass 2's revisions land in this file, this plan is greenlit for execution. Until both passes are recorded as complete (with findings either addressed or explicitly accepted as out-of-scope) in this document, no Task 4+ work begins.
