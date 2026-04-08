// tests/lib/git.test.ts
import * as path from 'path';
import * as fs from 'fs';
import * as tmp from 'tmp';
import { execSync } from 'child_process';
import { applyPatchSafe, validateNoGithubPaths } from '../../src/lib/git';

tmp.setGracefulCleanup();

/** Create a temp git repo with an initial commit containing src/example.ts */
function createTempRepo(): string {
  const dir = tmp.dirSync({ unsafeCleanup: true }).name;
  execSync('git init', { cwd: dir });
  execSync('git config user.name "Test"', { cwd: dir });
  execSync('git config user.email "test@test.com"', { cwd: dir });
  // Disable autocrlf so patch context lines (LF) match the stored file bytes exactly.
  // Without this, Windows Git converts LF→CRLF on add, causing `git apply` to fail.
  execSync('git config core.autocrlf false', { cwd: dir });

  const srcDir = path.join(dir, 'src');
  fs.mkdirSync(srcDir, { recursive: true });
  fs.writeFileSync(
    path.join(srcDir, 'example.ts'),
    'export function example() {\n  return true;\n}\n'
  );

  execSync('git add -A', { cwd: dir });
  execSync('git commit -m "initial commit"', { cwd: dir });
  return dir;
}

describe('applyPatchSafe', () => {
  it('applies a valid patch and stages the changes', async () => {
    const repoDir = createTempRepo();
    const patch = fs.readFileSync(
      path.join(__dirname, '..', 'fixtures', 'valid.patch'),
      'utf-8'
    );

    await applyPatchSafe(patch, repoDir);

    const content = fs.readFileSync(
      path.join(repoDir, 'src', 'example.ts'),
      'utf-8'
    );
    expect(content).toContain("console.log('patched')");

    const staged = execSync('git diff --cached --name-only', { cwd: repoDir })
      .toString()
      .trim();
    expect(staged).toBe('src/example.ts');
  });

  it('throws on an invalid patch', async () => {
    const repoDir = createTempRepo();
    await expect(applyPatchSafe('not a real patch', repoDir)).rejects.toThrow();
  });
});

describe('validateNoGithubPaths', () => {
  it('passes when staged changes do not touch .github/', async () => {
    const repoDir = createTempRepo();
    const patch = fs.readFileSync(
      path.join(__dirname, '..', 'fixtures', 'valid.patch'),
      'utf-8'
    );

    await applyPatchSafe(patch, repoDir);
    await expect(validateNoGithubPaths(repoDir)).resolves.toBeUndefined();
  });

  it('throws when staged changes touch .github/ paths', async () => {
    const repoDir = createTempRepo();

    const ghDir = path.join(repoDir, '.github', 'workflows');
    fs.mkdirSync(ghDir, { recursive: true });
    fs.writeFileSync(path.join(ghDir, 'evil.yml'), 'name: Evil\n');
    execSync('git add .github/', { cwd: repoDir });

    await expect(validateNoGithubPaths(repoDir)).rejects.toThrow(
      /protected path.*\.github\//i
    );

    // Verify the index was reset (security cleanup)
    const staged = execSync('git diff --cached --name-only', { cwd: repoDir }).toString().trim();
    expect(staged).toBe('');
  });

  it('rejects the github-path.patch fixture via the full apply+validate flow', async () => {
    const repoDir = createTempRepo();
    const evilPatch = fs.readFileSync(
      path.join(__dirname, '..', 'fixtures', 'github-path.patch'),
      'utf-8'
    );

    await applyPatchSafe(evilPatch, repoDir);
    await expect(validateNoGithubPaths(repoDir)).rejects.toThrow(
      /protected path.*\.github\//i
    );

    // Verify the index was reset (security cleanup)
    const staged = execSync('git diff --cached --name-only', { cwd: repoDir }).toString().trim();
    expect(staged).toBe('');
  });
});
