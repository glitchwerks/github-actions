import * as github from '@actions/github';
import { fetchPrBranchName } from '../../src/lib/github';

jest.mock('@actions/github');

describe('fetchPrBranchName', () => {
  it('returns the head ref from the PR', async () => {
    const mockGet = jest.fn().mockResolvedValue({
      data: { head: { ref: 'feature/my-branch' } },
    });

    (github.getOctokit as jest.Mock).mockReturnValue({
      rest: {
        pulls: {
          get: mockGet,
        },
      },
    });

    const branch = await fetchPrBranchName('my-token', 'owner', 'repo', 42);

    expect(branch).toBe('feature/my-branch');
    expect(mockGet).toHaveBeenCalledWith({
      owner: 'owner',
      repo: 'repo',
      pull_number: 42,
    });
  });

  it('throws when the API call fails', async () => {
    (github.getOctokit as jest.Mock).mockReturnValue({
      rest: {
        pulls: {
          get: jest.fn().mockRejectedValue(new Error('Not Found')),
        },
      },
    });

    await expect(
      fetchPrBranchName('my-token', 'owner', 'repo', 999)
    ).rejects.toThrow('Not Found');
  });
});
