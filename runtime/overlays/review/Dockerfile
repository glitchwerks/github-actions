# syntax=docker/dockerfile:1.7
# Phase 3 review overlay — built FROM the digest-pinned base image.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §3.1, §3.4 layer 2
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 4.1
#
# Inputs (build args):
#   BASE_DIGEST       — bare 64-char hex; consumer side strips `sha256:` prefix
#                       per Pass-3 Charge 1 before passing to this Dockerfile.
#   PRIVATE_REF       — manifest's sources.private.ref (e.g. ci-v0.1.0)
#   PRIVATE_SHA       — git SHA of the cloned private tree
#   MARKETPLACE_SHA   — manifest's sources.marketplace.ref
#   PUB_SHA           — github.sha for this build
#   CLI_VERSION       — base image's claude CLI version (read from base label
#                       at STAGE 3 cell start; non-empty per R5)
#
# Build context (populated by STAGE 3 cell before invoking docker build):
#   overlay-tree/     — output of extract-overlay.sh for OVERLAY=review;
#                       contains additive imports (agents/inquisitor.md +
#                       plugins/pr-review-toolkit/) and any subtract markers.
#   CLAUDE.md         — review-scoped persona (replaces base shared CLAUDE.md
#                       at /opt/claude/.claude/CLAUDE.md per §3.4 layer 2)
#   expected.yaml     — inventory contract; landed at /opt/claude/.expected.yaml
#                       for R6 forensic verification.

ARG BASE_DIGEST
FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}

ARG OVERLAY=review
ARG PRIVATE_REF
ARG PRIVATE_SHA
ARG MARKETPLACE_SHA
ARG PUB_SHA
ARG CLI_VERSION

# (1) Materialized overlay tree (additive imports + subtract markers from extract-overlay.sh).
COPY overlay-tree/ /opt/claude/.claude/

# (2) Honor subtract_from_shared.plugins markers.
# MUST run between COPY overlay-tree/ and the final chmod (per Pass-2 Charge 3 / Pass-3 Charge 2).
# Charset checks are full-string negated brackets — see Task 5.5 for rationale.
RUN if [ -d /opt/claude/.claude/.subtract/plugins ]; then \
      for marker in /opt/claude/.claude/.subtract/plugins/*; do \
        [ -e "$marker" ] || continue; \
        plugin=$(basename "$marker"); \
        case "$plugin" in ''|*/*|.|..) echo "FATAL invalid subtract marker: '$plugin'" >&2; exit 1;; esac; \
        case "$plugin" in *[!a-z0-9-]*) echo "FATAL subtract marker '$plugin' contains forbidden char" >&2; exit 1;; esac; \
        case "$plugin" in [!a-z0-9]*) echo "FATAL subtract marker '$plugin' must start with [a-z0-9]" >&2; exit 1;; esac; \
        echo "subtracting plugin: $plugin"; \
        rm -rf "/opt/claude/.claude/plugins/$plugin"; \
      done; \
      rm -rf /opt/claude/.claude/.subtract; \
    fi

# (3) Overlay-scoped CLAUDE.md replaces base's shared CLAUDE.md (§3.4 layer 2 active persona).
COPY CLAUDE.md /opt/claude/.claude/CLAUDE.md

# (4) Inventory contract on-disk for forensic verification (R6).
COPY expected.yaml /opt/claude/.expected.yaml

# (5) chmod LAST so it operates on post-subtraction tree (R3 perms apply to what ships).
RUN chmod -R a+rX /opt/claude/.claude/ \
 && chmod 0644 /opt/claude/.expected.yaml

# OCI labels — six base labels (mirroring Phase 2's Dockerfile) + new dev.glitchwerks.ci.overlay.
# cli_version carries the BASE image's CLI version (per Deviation #11 / Pass-1 Charge 11);
# overlay does not re-install the binary, so the value is inherited.
LABEL org.opencontainers.image.source="https://github.com/glitchwerks/github-actions" \
      org.opencontainers.image.revision="${PUB_SHA}" \
      dev.glitchwerks.ci.private_ref="${PRIVATE_REF}" \
      dev.glitchwerks.ci.private_sha="${PRIVATE_SHA}" \
      dev.glitchwerks.ci.marketplace_sha="${MARKETPLACE_SHA}" \
      dev.glitchwerks.ci.cli_version="${CLI_VERSION}" \
      dev.glitchwerks.ci.overlay="${OVERLAY}"
