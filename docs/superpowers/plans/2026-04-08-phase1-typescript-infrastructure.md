# Phase 1: TypeScript + Jest Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up a complete TypeScript + Jest toolchain with CI pipelines so that all subsequent phases can extract action logic into tested TypeScript. Zero behavior change — no action YAML is modified.

**Architecture:** Per-action bundling with `@vercel/ncc` dispatched by `STEP` env var. Phase 1 creates the build skeleton with no entry points yet — type-checking only. Each subsequent phase adds an entry point and its `dist/` bundle. Library code lives in `src/lib/`, entry points in `src/<action-name>/index.ts`, bundles in `<action-name>/dist/`.

**Tech Stack:** TypeScript 5.x, Node 20, Jest + ts-jest, @vercel/ncc, @actions/core, @actions/github, @actions/exec

**Tracks:** Issue #98

---

## File Map

| File | Purpose |
|---|---|
| `package.json` | Dependencies, scripts (`build`, `test`, `build:check`) |
| `tsconfig.json` | TypeScript config — Node 20, strict mode, no emit (ncc handles bundling) |
| `jest.config.ts` | Jest config with ts-jest preset |
| `.gitattributes` | Mark `*/dist/**` as linguist-generated |
| `src/lib/tokens.ts` | `resolveWriteToken()` — shared token resolution (used by 5 actions) |
| `tests/lib/tokens.test.ts` | Unit tests for token resolution |
| `tests/fixtures/*.json` | JSON stubs for future phases |
| `tests/fixtures/*.patch` | Patch file stubs for future phases |
| `.github/workflows/test.yml` | CI: `npm test` on push + PR |
| `.github/workflows/build-check.yml` | CI: fail if `dist/` is stale after `npm run build` |
| `.github/workflows/release.yml` | Manual: rebuild `dist/`, commit, tag |

---

### Task 1: Initialize Toolchain

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `jest.config.ts`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "github-actions",
  "version": "2.0.0",
  "private": true,
  "description": "Shared GitHub Actions library — TypeScript layer for testable action logic",
  "scripts": {
    "build": "tsc --noEmit",
    "test": "jest",
    "build:check": "npm run build && git diff --exit-code -- '*/dist'"
  },
  "engines": {
    "node": ">=20"
  },
  "devDependencies": {
    "@types/jest": "^29.5.0",
    "@types/tmp": "^0.2.6",
    "@vercel/ncc": "^0.38.0",
    "jest": "^29.7.0",
    "ts-jest": "^29.2.0",
    "typescript": "^5.6.0"
  },
  "dependencies": {
    "@actions/core": "^1.11.0",
    "@actions/exec": "^1.1.1",
    "@actions/github": "^6.0.0",
    "tmp": "^0.2.3"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "outDir": "./build",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "build", "*/dist", "tests"]
}
```

- [ ] **Step 3: Create `jest.config.ts`**

```typescript
import type { Config } from 'jest';

const config: Config = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/tests'],
  testMatch: ['**/*.test.ts'],
  collectCoverageFrom: ['src/**/*.ts', '!src/**/index.ts'],
  coverageDirectory: 'coverage',
  verbose: true,
};

export default config;
```

- [ ] **Step 4: Install dependencies**

Run: `npm install`

Expected: `node_modules/` created, `package-lock.json` generated. Verify with:

Run: `npx tsc --version`

Expected: `Version 5.x.x`

- [ ] **Step 5: Add `node_modules/` and `build/` to `.gitignore`**

Append to the existing `.gitignore`:

```
node_modules/
build/
coverage/
```

- [ ] **Step 6: Verify type-check runs clean**

Run: `npm run build`

Expected: Exit 0, no output (no source files yet, but the config is valid)

- [ ] **Step 7: Commit toolchain setup**

```
git add package.json package-lock.json tsconfig.json jest.config.ts .gitignore
git commit -m "chore: initialize TypeScript + Jest toolchain

Part of #98 — Phase 1 infrastructure. No action YAML modified."
```

---

### Task 2: Write Failing Tests for `resolveWriteToken`

**Files:**
- Create: `tests/lib/tokens.test.ts`

The token resolution pattern is duplicated across 5 actions (`apply-fix`, `lint-apply`, `lint-diagnose`, `lint-failure`, `tag-claude`). Each one:
1. Reads the App token from the `create-github-app-token` step output
2. If present → writes it to `$GITHUB_OUTPUT` as `value=<token>`
3. If absent → logs an error and exits 1

The TypeScript function takes the token as a parameter (pure logic, no side effects) and returns it or throws. The `@actions/core` integration (debug log, setOutput, setFailed) is the entry point's responsibility — not the library's.

- [ ] **Step 1: Create `tests/lib/` directory and test file**

```typescript
// tests/lib/tokens.test.ts
import { resolveWriteToken } from '../../src/lib/tokens';

describe('resolveWriteToken', () => {
  describe('when App token is provided', () => {
    it('returns the token string', () => {
      const token = resolveWriteToken('ghs_abc123def456');
      expect(token).toBe('ghs_abc123def456');
    });
  });

  describe('when App token is empty string', () => {
    it('throws with a clear error message', () => {
      expect(() => resolveWriteToken('')).toThrow(
        'No authentication token provided'
      );
    });

    it('includes setup instructions in the error', () => {
      expect(() => resolveWriteToken('')).toThrow(
        'Set app_id + app_private_key inputs'
      );
    });
  });

  describe('when App token is undefined', () => {
    it('throws with a clear error message', () => {
      expect(() => resolveWriteToken(undefined)).toThrow(
        'No authentication token provided'
      );
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx jest tests/lib/tokens.test.ts --verbose`

Expected: FAIL — `Cannot find module '../../src/lib/tokens'`

---

### Task 3: Implement `resolveWriteToken`

**Files:**
- Create: `src/lib/tokens.ts`

- [ ] **Step 1: Create `src/lib/` directory and implementation**

```typescript
// src/lib/tokens.ts

/**
 * Resolves the write token for git push operations.
 *
 * In v2, only GitHub App tokens are supported. The PAT fallback was removed.
 * This function is used by: apply-fix, lint-apply, lint-diagnose, lint-failure, tag-claude.
 *
 * @param appToken - The token from the create-github-app-token step (may be empty/undefined)
 * @returns The resolved token string
 * @throws Error if no token is available
 */
export function resolveWriteToken(appToken: string | undefined): string {
  if (appToken) {
    return appToken;
  }

  throw new Error(
    'No authentication token provided. Set app_id + app_private_key inputs. See README for GitHub App setup instructions.'
  );
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `npx jest tests/lib/tokens.test.ts --verbose`

Expected: 3 tests passing

- [ ] **Step 3: Run type-check**

Run: `npm run build`

Expected: Exit 0, no errors

- [ ] **Step 4: Commit**

```
git add src/lib/tokens.ts tests/lib/tokens.test.ts
git commit -m "feat: add resolveWriteToken shared library function

Extracts the App token resolution logic duplicated across 5 actions.
Pure function — takes token string, returns it or throws. Entry point
integration (core.setOutput, core.setFailed) deferred to Phase 2+.

Part of #98"
```

---

### Task 4: Create Test Fixtures

**Files:**
- Create: `tests/fixtures/commits-with-checkpoint.json`
- Create: `tests/fixtures/commits-no-checkpoint.json`
- Create: `tests/fixtures/pr-files-small.json`
- Create: `tests/fixtures/pr-files-large.json`
- Create: `tests/fixtures/comments-with-recent.json`
- Create: `tests/fixtures/comments-no-recent.json`
- Create: `tests/fixtures/valid.patch`
- Create: `tests/fixtures/github-path.patch`

These are stubs populated with realistic structure. Later phases fill in additional detail as needed.

- [ ] **Step 1: Create fixture directory and JSON stubs**

`tests/fixtures/commits-with-checkpoint.json` — PR commits where commit 2 has a `claude-pr-review:success` status:
```json
[
  { "sha": "aaa1111111111111111111111111111111111111" },
  { "sha": "bbb2222222222222222222222222222222222222" },
  { "sha": "ccc3333333333333333333333333333333333333" }
]
```

`tests/fixtures/commits-no-checkpoint.json` — PR commits with no checkpoint status:
```json
[
  { "sha": "ddd4444444444444444444444444444444444444" },
  { "sha": "eee5555555555555555555555555555555555555" }
]
```

`tests/fixtures/pr-files-small.json` — A 3-file PR (below size gate):
```json
{
  "files": [
    { "filename": "src/index.ts", "additions": 10, "deletions": 2, "patch": "@@ -1,5 +1,13 @@\n+import { foo } from './foo';" },
    { "filename": "src/foo.ts", "additions": 8, "deletions": 0, "patch": "@@ -0,0 +1,8 @@\n+export function foo() {}" },
    { "filename": "tests/foo.test.ts", "additions": 12, "deletions": 0, "patch": "@@ -0,0 +1,12 @@\n+describe('foo', () => {});" }
  ],
  "additions": 30,
  "deletions": 2
}
```

`tests/fixtures/pr-files-large.json` — A 55-file PR (above size gate):
```json
{
  "files": [
    { "filename": "src/file-01.ts", "additions": 100, "deletions": 50, "patch": "..." },
    { "filename": "src/file-02.ts", "additions": 100, "deletions": 50, "patch": "..." },
    { "filename": "src/file-03.ts", "additions": 100, "deletions": 50, "patch": "..." }
  ],
  "totalFiles": 55,
  "additions": 3200,
  "deletions": 1800
}
```

`tests/fixtures/comments-with-recent.json` — PR comments including a recent bot comment:
```json
{
  "comments": [
    {
      "author": { "login": "github-actions[bot]" },
      "createdAt": "2026-04-08T12:00:00Z",
      "body": "Claude review comment"
    },
    {
      "author": { "login": "some-user" },
      "createdAt": "2026-04-08T11:00:00Z",
      "body": "LGTM"
    }
  ]
}
```

`tests/fixtures/comments-no-recent.json` — PR comments with no recent bot comment:
```json
{
  "comments": [
    {
      "author": { "login": "some-user" },
      "createdAt": "2026-04-07T10:00:00Z",
      "body": "Please fix the linting errors"
    }
  ]
}
```

- [ ] **Step 2: Create patch file stubs**

`tests/fixtures/valid.patch` — A clean patch that touches only `src/`:
```diff
diff --git a/src/example.ts b/src/example.ts
index 1234567..abcdefg 100644
--- a/src/example.ts
+++ b/src/example.ts
@@ -1,3 +1,4 @@
 export function example() {
+  console.log('patched');
   return true;
 }
```

`tests/fixtures/github-path.patch` — A patch that touches `.github/` (should be rejected):
```diff
diff --git a/.github/workflows/evil.yml b/.github/workflows/evil.yml
new file mode 100644
index 0000000..abcdefg
--- /dev/null
+++ b/.github/workflows/evil.yml
@@ -0,0 +1,5 @@
+name: Evil Workflow
+on: push
+jobs:
+  evil:
+    runs-on: ubuntu-latest
```

- [ ] **Step 3: Commit**

```
git add tests/fixtures/
git commit -m "test: add fixture stubs for future phases

JSON stubs for PR commits, files, and comments. Patch files for
apply-fix integration tests (valid patch + .github/ rejection case).

Part of #98"
```

---

### Task 5: Create CI Workflows

**Files:**
- Create: `.github/workflows/test.yml`
- Create: `.github/workflows/build-check.yml`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create `test.yml`**

```yaml
name: Tests

on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'tests/**'
      - 'package.json'
      - 'tsconfig.json'
      - 'jest.config.ts'
  pull_request:
    paths:
      - 'src/**'
      - 'tests/**'
      - 'package.json'
      - 'tsconfig.json'
      - 'jest.config.ts'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm test
```

- [ ] **Step 2: Create `build-check.yml`**

```yaml
name: Build Check

on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'package.json'
      - 'tsconfig.json'
  pull_request:
    paths:
      - 'src/**'
      - 'package.json'
      - 'tsconfig.json'

jobs:
  build-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run build
      - name: Check dist/ is up to date
        run: |
          if [ -n "$(git diff --name-only -- '*/dist')" ]; then
            echo "::error::dist/ is stale. Run 'npm run build' and commit the result."
            git diff --stat -- '*/dist'
            exit 1
          fi
          echo "dist/ is up to date"
```

- [ ] **Step 3: Create `release.yml`**

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version tag (e.g. v2.1.0)'
        required: true
        type: string

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run build

      - name: Check for dist/ changes
        id: check
        run: |
          if [ -n "$(git diff --name-only -- '*/dist')" ]; then
            echo "changed=true" >> "$GITHUB_OUTPUT"
          else
            echo "changed=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Commit rebuilt dist/
        if: steps.check.outputs.changed == 'true'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add '*/dist'
          git commit -m "chore: rebuild dist/ for ${{ inputs.version }}"
          git push

      - name: Extract major version
        id: major
        run: |
          MAJOR=$(echo "${{ inputs.version }}" | grep -oP '^v\d+')
          echo "tag=$MAJOR" >> "$GITHUB_OUTPUT"

      - name: Create version tag
        run: |
          git tag -f "${{ inputs.version }}"
          git push origin "${{ inputs.version }}" --force

      - name: Move floating major tag
        run: |
          git tag -f "${{ steps.major.outputs.tag }}"
          git push origin "${{ steps.major.outputs.tag }}" --force
```

- [ ] **Step 4: Verify `actionlint` passes on new workflows**

Run: `actionlint .github/workflows/test.yml .github/workflows/build-check.yml .github/workflows/release.yml`

Expected: No errors. If `actionlint` is not installed locally, skip — CI will catch it.

- [ ] **Step 5: Commit**

```
git add .github/workflows/test.yml .github/workflows/build-check.yml .github/workflows/release.yml
git commit -m "ci: add test, build-check, and release workflows

- test.yml: runs npm test on push + PR when src/tests change
- build-check.yml: fails if dist/ is stale after npm run build
- release.yml: workflow_dispatch to rebuild dist/, tag, and move floating tag

Part of #98"
```

---

### Task 6: Add `.gitattributes`

**Files:**
- Create: `.gitattributes`

- [ ] **Step 1: Create `.gitattributes`**

```
# Collapse generated bundles in GitHub PR diffs
*/dist/** linguist-generated=true
```

- [ ] **Step 2: Commit**

```
git add .gitattributes
git commit -m "chore: mark dist/ as linguist-generated

Collapses ncc bundles in GitHub PR diffs.

Part of #98"
```

---

### Task 7: Local Smoke Test

Verify the full toolchain works end-to-end before pushing.

- [ ] **Step 1: Run tests**

Run: `npm test`

Expected: All 3 tests pass (tokens.test.ts)

- [ ] **Step 2: Run type-check**

Run: `npm run build`

Expected: Exit 0, no errors

- [ ] **Step 3: Run build:check**

Run: `npm run build:check`

Expected: Exit 0 — no `dist/` to be stale yet

- [ ] **Step 4: Verify .gitignore covers new artifacts**

Run: `git status`

Expected: No `node_modules/`, `build/`, or `coverage/` in untracked files

- [ ] **Step 5: Verify all tests run on Windows (if on Windows)**

Run: `npm test`

Expected: All tests pass — no Unix-specific path assumptions in test code

---

## Post-Completion

After all tasks pass locally:

1. Push the branch and open a PR against `main`
2. Verify `test.yml` and `build-check.yml` pass in CI
3. Verify `lint.yml` (actionlint) passes on the new workflow files
4. Merge and move to Phase 2 (#99: Extract check-auth)
