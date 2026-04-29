# Migration Notice — Org Transfer

This repository has moved from `cbeaulieu-gt/github-actions` to `glitchwerks/github-actions`.

## What you need to do

Update every `uses:` reference in your caller workflows:

```yaml
# Before
uses: cbeaulieu-gt/github-actions/.github/workflows/claude-pr-review.yml@v2

# After
uses: glitchwerks/github-actions/.github/workflows/claude-pr-review.yml@v2
```

GitHub installs an HTTP redirect for the old URL, but `uses:` redirect resolution is best-effort and not contractual. Update your callers explicitly.

## Tags

Existing `v1`, `v1.8.0`, `v2`, `v2.0.0` tags transferred unchanged. A new `v2.0.1` tag will follow this migration with the updated internal references.

<!-- final smoke-test: org-level secrets only, repo-level deleted (refs #148) — 2026-04-29 -->
