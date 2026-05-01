#!/usr/bin/env bash
# GHCR tag-immutability preflight.
# Spec: docs/superpowers/specs/2026-04-21-ci-claude-runtime-design.md §6.3.1, §13 Q8
#
# Required env:
#   GH_PAT   — token with `read:packages` on the org
#   GH_ORG   — org name (default: glitchwerks)
#
# Optional env:
#   SKIP_GHCR_IMMUTABILITY=1         — emergency override; logs WARN SKIP and exits 0
#   GHCR_ALLOW_MISSING_PACKAGES=1    — Phase 1 bootstrap bridge: 404 "Package not found"
#                                      becomes WARN missing instead of fatal. Removed in
#                                      Phase 2 once image builds create the packages.

set -uo pipefail

GH_ORG="${GH_ORG:-glitchwerks}"
PACKAGES=(claude-runtime-base claude-runtime-review claude-runtime-fix claude-runtime-explain)

if [ "${SKIP_GHCR_IMMUTABILITY:-0}" = "1" ]; then
  echo "WARN SKIP ghcr-immutability-preflight bypassed via SKIP_GHCR_IMMUTABILITY=1" >&2
  exit 0
fi

: "${GH_PAT:?GH_PAT must be set}"
command -v jq >/dev/null || { echo "FATAL jq not on PATH" >&2; exit 2; }
command -v curl >/dev/null || { echo "FATAL curl not on PATH" >&2; exit 2; }

# Three attempts, exponential backoff capped at 10s.
fetch_with_backoff() {
  local url="$1"
  local attempt=0
  local delay=2
  local response http_code body
  while [ "$attempt" -lt 3 ]; do
    response=$(curl -sS -w '\n%{http_code}' \
      -H "Authorization: Bearer $GH_PAT" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" || true)
    http_code=$(printf '%s\n' "$response" | tail -n1)
    body=$(printf '%s\n' "$response" | sed '$d')
    case "$http_code" in
      2??) printf '%s' "$body"; return 0 ;;
      404) printf 'NOT_FOUND'; return 0 ;;
      429|5??)
        attempt=$((attempt + 1))
        if [ "$attempt" -lt 3 ]; then
          sleep "$delay"
          delay=$(( delay * 2 ))
          [ "$delay" -gt 10 ] && delay=10
        fi
        ;;
      *)  echo "ERROR ghcr_api_unexpected http_code=$http_code body=$body" >&2; return 1 ;;
    esac
  done
  echo "ERROR ghcr_api_retries_exhausted http_code=$http_code body=$body" >&2
  return 1
}

errs=0
missing=0
verified=0
for pkg in "${PACKAGES[@]}"; do
  url="https://api.github.com/orgs/$GH_ORG/packages/container/$pkg"
  body=$(fetch_with_backoff "$url") || { errs=$((errs + 1)); continue; }

  if [ "$body" = "NOT_FOUND" ]; then
    if [ "${GHCR_ALLOW_MISSING_PACKAGES:-0}" = "1" ]; then
      echo "WARN missing package=$pkg (Phase 1 bootstrap; will be created by Phase 2 image build)" >&2
      missing=$((missing + 1))
      continue
    else
      echo "ERROR ghcr_package_not_found package=$pkg org=$GH_ORG" >&2
      errs=$((errs + 1))
      continue
    fi
  fi

  # Field name verified at implementation time. Update here if GitHub has renamed it.
  immutable=$(printf '%s' "$body" | jq -r '.tag_immutability // .immutable // empty')

  if [ "$immutable" != "true" ]; then
    cat >&2 <<EOF
ERROR ghcr_tag_immutability_disabled package=$pkg org=$GH_ORG
       Visit https://github.com/orgs/$GH_ORG/packages/container/package/$pkg/settings
       and toggle "Prevent tag overwrites" ON. Re-run this preflight.
EOF
    errs=$((errs + 1))
  else
    verified=$((verified + 1))
  fi
done

if [ "$errs" -gt 0 ]; then
  echo "ghcr-immutability-preflight: $errs package(s) failed (verified=$verified, missing=$missing)" >&2
  exit 1
fi

echo "ghcr-immutability-preflight: $verified verified, $missing missing (bootstrap)"
exit 0
