# syntax=docker/dockerfile:1.7
# Phase 3 explain overlay — built FROM the digest-pinned base image.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §3.1, §3.4 layer 2
# Plan: docs/superpowers/plans/phase-3-overlays.md Task 4.3
#
# imports_from_private: {} per the manifest — explain carries no overlay-specific
# agents or plugins. Its value is the read-only-scoped CLAUDE.md persona. The
# overlay-tree/ COPY succeeds with an essentially empty tree (just the directory).
# See review/Dockerfile for full input/build-context documentation.

ARG BASE_DIGEST
FROM ghcr.io/glitchwerks/claude-runtime-base@sha256:${BASE_DIGEST}

ARG OVERLAY=explain
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
