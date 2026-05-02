# syntax=docker/dockerfile:1.7
# Phase 3 fix overlay — built FROM the digest-pinned base image.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §3.1, §3.4 layer 2
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 4.2
#
# Carries the debugger + code-writer agents per overlays.fix.imports_from_private.
# No overlay-specific plugins; no subtract_from_shared (skill-creator stays from base).
# See review/Dockerfile for full input/build-context documentation — this differs only
# in ARG OVERLAY=fix and the verb-specific build context populated by STAGE 3.

ARG BASE_DIGEST
FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}

ARG OVERLAY=fix
ARG PRIVATE_REF
ARG PRIVATE_SHA
ARG MARKETPLACE_SHA
ARG PUB_SHA
ARG CLI_VERSION

COPY overlay-tree/ /opt/claude/.claude/

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

COPY CLAUDE.md /opt/claude/.claude/CLAUDE.md
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
