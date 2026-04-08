// tests/apply-fix.test.ts

async function runApplyFix(
  env: Record<string, string>,
  mockSetup?: (mocks: {
    git: { applyPatchSafe: jest.Mock; validateNoGithubPaths: jest.Mock; pushToBranch: jest.Mock };
    github: { fetchPrBranchName: jest.Mock };
    exec: { exec: jest.Mock };
  }) => void
): Promise<{
  coreMock: jest.MockedObject<typeof import('@actions/core')>;
}> {
  const originalEnv = { ...process.env };
  Object.assign(process.env, env);

  let coreMock!: jest.MockedObject<typeof import('@actions/core')>;

  try {
    await new Promise<void>((resolve, reject) => {
      jest.isolateModules(() => {
        jest.mock('@actions/core');
        jest.mock('@actions/exec');
        jest.mock('../src/lib/git');
        jest.mock('../src/lib/github');

        coreMock = jest.requireMock('@actions/core');
        const execMock = jest.requireMock('@actions/exec');
        const gitMock = jest.requireMock('../src/lib/git');
        const githubMock = jest.requireMock('../src/lib/github');

        // Default happy-path mocks
        gitMock.applyPatchSafe = jest.fn().mockResolvedValue(undefined);
        gitMock.validateNoGithubPaths = jest.fn().mockResolvedValue(undefined);
        gitMock.pushToBranch = jest.fn().mockResolvedValue(undefined);
        githubMock.fetchPrBranchName = jest.fn().mockResolvedValue('feature/test');
        execMock.exec = jest.fn().mockResolvedValue(0);

        // Allow caller to override before require
        if (mockSetup) {
          mockSetup({ git: gitMock, github: githubMock, exec: execMock });
        }

        try {
          require('../src/apply-fix/index');
        } catch (e) {
          reject(e);
        }

        // Let the async run() complete
        setTimeout(resolve, 50);
      });
    });
  } finally {
    process.env = originalEnv;
  }

  return { coreMock };
}

describe('apply-fix entry point', () => {
  describe('STEP=apply', () => {
    it('applies patch, validates paths, and commits', async () => {
      const { coreMock } = await runApplyFix({
        STEP: 'apply',
        DIFF_CONTENT: 'diff --git a/file.ts b/file.ts\n...',
        FIX_DESC: 'Fix the bug',
        PR_NUMBER: '42',
      });

      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.info).toHaveBeenCalledWith(
        expect.stringContaining('PR #42')
      );
    });

    it('calls setFailed when .github/ path is detected', async () => {
      const { coreMock } = await runApplyFix(
        {
          STEP: 'apply',
          DIFF_CONTENT: 'evil patch',
          FIX_DESC: 'Sneaky',
          PR_NUMBER: '42',
        },
        ({ git }) => {
          git.validateNoGithubPaths.mockRejectedValue(
            new Error('Diff targets protected path: .github/workflows/evil.yml')
          );
        }
      );

      expect(coreMock.setFailed).toHaveBeenCalledWith(
        expect.stringContaining('protected path')
      );
    });

    it('calls setFailed when patch application fails', async () => {
      const { coreMock } = await runApplyFix(
        {
          STEP: 'apply',
          DIFF_CONTENT: 'bad patch',
          FIX_DESC: 'Broken',
          PR_NUMBER: '42',
        },
        ({ git }) => {
          git.applyPatchSafe.mockRejectedValue(new Error('patch does not apply'));
        }
      );

      expect(coreMock.setFailed).toHaveBeenCalledWith(
        expect.stringContaining('patch does not apply')
      );
    });
  });

  describe('STEP=push', () => {
    it('fetches branch name and pushes', async () => {
      const { coreMock } = await runApplyFix({
        STEP: 'push',
        PR_NUMBER: '42',
        GITHUB_TOKEN: 'ghs_fake',
        GITHUB_REPOSITORY: 'owner/repo',
      });

      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.info).toHaveBeenCalledWith(
        expect.stringContaining('feature/test')
      );
    });
  });

  describe('unknown STEP', () => {
    it('calls setFailed for unknown step', async () => {
      const { coreMock } = await runApplyFix({
        STEP: 'invalid',
      });

      expect(coreMock.setFailed).toHaveBeenCalledWith(
        expect.stringContaining('Unknown STEP')
      );
    });

    it('calls setFailed when STEP is empty', async () => {
      const { coreMock } = await runApplyFix({});

      expect(coreMock.setFailed).toHaveBeenCalledWith(
        expect.stringContaining('Unknown STEP')
      );
    });
  });
});
