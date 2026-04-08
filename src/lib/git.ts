// src/lib/git.ts
import * as exec from '@actions/exec';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

/**
 * Writes patch content to a temp file and applies it with `git apply --index`.
 *
 * Uses --index so the changes are both applied to the working tree and staged
 * in the git index, ready for commit.
 *
 * @param patchContent - The unified diff string to apply
 * @param cwd - The git working directory to apply in (defaults to process.cwd())
 * @throws Error if git apply fails
 */
export async function applyPatchSafe(
  patchContent: string,
  cwd: string = process.cwd()
): Promise<void> {
  const tmpFile = path.join(os.tmpdir(), `patch-${Date.now()}.patch`);
  try {
    // Normalize CRLF → LF before writing: patches may arrive with Windows line
    // endings (e.g. checked-in fixture files), but `git apply` requires the
    // context lines to match the index byte-for-byte, which uses LF on all
    // platforms when core.autocrlf is false.
    const normalized = patchContent.replace(/\r\n/g, '\n');
    fs.writeFileSync(tmpFile, normalized);
    await exec.exec('git', ['apply', '--index', tmpFile], { cwd });
  } finally {
    if (fs.existsSync(tmpFile)) {
      fs.unlinkSync(tmpFile);
    }
  }
}

/**
 * Validates that no staged (cached) changes touch `.github/` paths.
 *
 * This is a security control: automated patches must not be able to modify
 * workflow files. Checks the authoritative git index, not raw diff text.
 *
 * @param cwd - The git working directory to check (defaults to process.cwd())
 * @throws Error listing the blocked paths if any `.github/` files are staged
 */
export async function validateNoGithubPaths(
  cwd: string = process.cwd()
): Promise<void> {
  let output = '';
  await exec.exec('git', ['diff', '--cached', '--name-only'], {
    cwd,
    listeners: {
      stdout: (data: Buffer) => {
        output += data.toString();
      },
    },
  });

  const blocked = output
    .trim()
    .split('\n')
    .filter((f) => f.startsWith('.github/'));

  if (blocked.length > 0) {
    await exec.exec('git', ['reset', 'HEAD'], { cwd, silent: true });
    throw new Error(
      `Diff targets protected path: ${blocked.join(', ')}. ` +
        'Patches must not modify .github/ files.'
    );
  }
}

/**
 * Pushes HEAD to a named branch on the origin remote.
 *
 * @param branchName - The remote branch to push to (e.g., 'feature/my-fix')
 * @param cwd - The git working directory (defaults to process.cwd())
 * @throws Error if git push fails
 */
export async function pushToBranch(
  branchName: string,
  cwd: string = process.cwd()
): Promise<void> {
  await exec.exec('git', ['push', 'origin', `HEAD:${branchName}`], { cwd });
}
