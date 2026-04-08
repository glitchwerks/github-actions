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
//# sourceMappingURL=github.d.ts.map