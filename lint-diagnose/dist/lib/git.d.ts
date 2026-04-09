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
export declare function applyPatchSafe(patchContent: string, cwd?: string): Promise<void>;
/**
 * Validates that no staged (cached) changes touch `.github/` paths.
 *
 * This is a security control: automated patches must not be able to modify
 * workflow files. Checks the authoritative git index, not raw diff text.
 *
 * @param cwd - The git working directory to check (defaults to process.cwd())
 * @throws Error listing the blocked paths if any `.github/` files are staged
 */
export declare function validateNoGithubPaths(cwd?: string): Promise<void>;
/**
 * Pushes HEAD to a named branch on the origin remote.
 *
 * @param branchName - The remote branch to push to (e.g., 'feature/my-fix')
 * @param cwd - The git working directory (defaults to process.cwd())
 * @throws Error if git push fails
 */
export declare function pushToBranch(branchName: string, cwd?: string): Promise<void>;
//# sourceMappingURL=git.d.ts.map