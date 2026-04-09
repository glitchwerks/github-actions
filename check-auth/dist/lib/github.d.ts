/**
 * Fetches the head branch name for a pull request via the GitHub API.
 *
 * @param token - GitHub token for API authentication
 * @param owner - Repository owner (e.g., 'cbeaulieu-gt')
 * @param repo - Repository name (e.g., 'github-actions')
 * @param prNumber - Pull request number
 * @returns The head branch ref string (e.g., 'feature/my-fix')
 */
export declare function fetchPrBranchName(token: string, owner: string, repo: string, prNumber: number): Promise<string>;
/**
 * Downloads failed run logs via `gh run view --log-failed` and truncates to maxBytes.
 *
 * Uses getExecOutput instead of piping through `head -c` to avoid SIGPIPE
 * false failures when the output exceeds the limit.
 *
 * @param token - GitHub token for gh CLI authentication
 * @param runId - Workflow run ID to fetch logs for
 * @param maxBytes - Maximum number of bytes to return (truncates from end)
 * @returns The (possibly truncated) log output string
 * @throws Error if gh run view fails with a non-empty stderr message
 */
export declare function fetchRunLogsSafe(token: string, runId: string, maxBytes: number): Promise<string>;
/** A single file entry from the PR diff — filename + unified diff patch. */
export interface PrDiffFile {
    filename: string;
    patch: string;
}
/**
 * Fetches the list of files changed in a PR via the GitHub API.
 *
 * Returns an array of {filename, patch} objects, sliced to maxFiles.
 * Extra fields from the API (status, sha, etc.) are stripped.
 *
 * @param token - GitHub token for API authentication
 * @param owner - Repository owner
 * @param repo - Repository name
 * @param prNumber - Pull request number
 * @param maxFiles - Maximum number of file entries to return
 * @returns Array of {filename, patch} objects
 */
export declare function fetchPrDiffJson(token: string, owner: string, repo: string, prNumber: number, maxFiles: number): Promise<PrDiffFile[]>;
//# sourceMappingURL=github.d.ts.map