import * as exec from '@actions/exec';
import * as github from '@actions/github';

jest.mock('@actions/exec');
jest.mock('@actions/github');
const mockGetExecOutput = exec.getExecOutput as jest.MockedFunction<typeof exec.getExecOutput>;

import { fetchRunLogsSafe, fetchPrDiffJson } from '../../src/lib/github';

describe('fetchRunLogsSafe', () => {
  beforeEach(() => {
    jest.resetAllMocks();
  });

  it('downloads logs and truncates to maxBytes', async () => {
    const longOutput = 'x'.repeat(20000);
    mockGetExecOutput.mockResolvedValue({
      exitCode: 0,
      stdout: longOutput,
      stderr: '',
    });

    const result = await fetchRunLogsSafe('ghs_token', '12345', 16000);

    expect(mockGetExecOutput).toHaveBeenCalledWith(
      'gh',
      ['run', 'view', '12345', '--log-failed'],
      expect.objectContaining({
        env: expect.objectContaining({ GH_TOKEN: 'ghs_token' }),
      })
    );
    expect(result.length).toBeLessThanOrEqual(16000);
    expect(result).toBe('x'.repeat(16000));
  });

  it('returns full output when under maxBytes', async () => {
    mockGetExecOutput.mockResolvedValue({
      exitCode: 0,
      stdout: 'short log',
      stderr: '',
    });

    const result = await fetchRunLogsSafe('ghs_token', '99', 16000);
    expect(result).toBe('short log');
  });

  it('throws with a clear error when gh run view fails', async () => {
    mockGetExecOutput.mockResolvedValue({
      exitCode: 1,
      stdout: '',
      stderr: 'run 99999 not found',
    });

    await expect(fetchRunLogsSafe('ghs_token', '99999', 16000)).rejects.toThrow(
      /Failed to download lint logs.*run 99999 not found/
    );
  });

  it('tolerates non-zero exit with empty stderr (SIGPIPE-like)', async () => {
    mockGetExecOutput.mockResolvedValue({
      exitCode: 141,
      stdout: 'partial output',
      stderr: '',
    });

    const result = await fetchRunLogsSafe('ghs_token', '12345', 16000);
    expect(result).toBe('partial output');
  });
});

describe('fetchPrDiffJson', () => {
  it('returns file objects sliced to maxFiles', async () => {
    const files = Array.from({ length: 50 }, (_, i) => ({
      filename: `file${i}.ts`,
      patch: `@@ -1 +1 @@\n-old${i}\n+new${i}`,
      status: 'modified',
      sha: 'abc',
    }));

    (github.getOctokit as jest.Mock).mockReturnValue({
      rest: { pulls: { listFiles: jest.fn().mockResolvedValue({ data: files }) } },
    });

    const result = await fetchPrDiffJson('token', 'owner', 'repo', 42, 30);

    expect(result).toHaveLength(30);
    expect(result[0]).toEqual({ filename: 'file0.ts', patch: expect.any(String) });
  });

  it('returns all files when under maxFiles', async () => {
    const files = [{ filename: 'a.ts', patch: '@@ diff', status: 'modified' }];

    (github.getOctokit as jest.Mock).mockReturnValue({
      rest: { pulls: { listFiles: jest.fn().mockResolvedValue({ data: files }) } },
    });

    const result = await fetchPrDiffJson('token', 'owner', 'repo', 42, 30);
    expect(result).toHaveLength(1);
    expect(result[0]).toEqual({ filename: 'a.ts', patch: '@@ diff' });
  });

  it('strips extra fields — returns only filename and patch', async () => {
    const files = [{ filename: 'a.ts', patch: 'diff', status: 'modified', sha: 'abc', additions: 5 }];

    (github.getOctokit as jest.Mock).mockReturnValue({
      rest: { pulls: { listFiles: jest.fn().mockResolvedValue({ data: files }) } },
    });

    const result = await fetchPrDiffJson('token', 'owner', 'repo', 42, 30);
    expect(Object.keys(result[0])).toEqual(['filename', 'patch']);
  });

  it('throws when the API call fails', async () => {
    (github.getOctokit as jest.Mock).mockReturnValue({
      rest: { pulls: { listFiles: jest.fn().mockRejectedValue(new Error('Not Found')) } },
    });

    await expect(fetchPrDiffJson('token', 'owner', 'repo', 999, 30)).rejects.toThrow('Not Found');
  });
});
