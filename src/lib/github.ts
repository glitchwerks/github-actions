import * as github from '@actions/github';

/**
 * Fetches the head branch name for a pull request via the GitHub API.
 *
 * @param token - GitHub token for API authentication
 * @param owner - Repository owner (e.g., 'cbeaulieu-gt')
 * @param repo - Repository name (e.g., 'github-actions')
 * @param prNumber - Pull request number
 * @returns The head branch ref string (e.g., 'feature/my-fix')
 */
export async function fetchPrBranchName(
  token: string,
  owner: string,
  repo: string,
  prNumber: number
): Promise<string> {
  const octokit = github.getOctokit(token);
  const { data } = await octokit.rest.pulls.get({
    owner,
    repo,
    pull_number: prNumber,
  });
  return data.head.ref;
}
