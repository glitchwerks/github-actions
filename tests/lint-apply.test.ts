// tests/lint-apply.test.ts
//
// Strategy for mocking fs.readFileSync:
// jest.mock('fs') breaks @actions/core and @actions/exec because they depend on
// real fs internals (fs.promises, fs.chmod, etc.). Instead, we use
// jest.mock('fs', factory) with a factory that spreads the real module and
// only overrides readFileSync — preserving all other properties.
//
// We capture readFileSyncMock from inside isolateModules so each test gets a
// clean instance. The default mock returns a safe patch string; individual
// tests override it via mockSetup when needed.

async function runLintApply(
  env: Record<string, string>,
  mockSetup?: (mocks: {
    git: { applyPatchSafe: jest.Mock; validateNoGithubPaths: jest.Mock; pushToBranch: jest.Mock };
    github: { fetchPrBranchName: jest.Mock };
    exec: { exec: jest.Mock; getExecOutput: jest.Mock };
    readFileSync: jest.Mock;
  }) => void
): Promise<{
  coreMock: jest.MockedObject<typeof import('@actions/core')>;
  readFileSync: jest.Mock;
}> {
  const originalEnv = { ...process.env };
  Object.assign(process.env, env);

  let coreMock!: jest.MockedObject<typeof import('@actions/core')>;
  let capturedReadFileSync!: jest.Mock;

  try {
    await new Promise<void>((resolve, reject) => {
      jest.isolateModules(() => {
        jest.mock('@actions/core');
        jest.mock('@actions/exec');
        jest.mock('../src/lib/git');
        jest.mock('../src/lib/github');

        // Mock only readFileSync; preserve the rest of the real fs module so
        // that @actions/core, @actions/exec, and @actions/io continue to work.
        const realFs = jest.requireActual<typeof import('fs')>('fs');
        const SAFE_PATCH = 'diff --git a/src/file.ts b/src/file.ts\n+fix';
        const readFileSyncMock = jest.fn().mockImplementation(
          (filePath: unknown, ...args: unknown[]) => {
            if (filePath === process.env['PATCH_FILE']) {
              return SAFE_PATCH;
            }
            return (realFs.readFileSync as (...a: unknown[]) => unknown)(filePath, ...args);
          }
        );
        capturedReadFileSync = readFileSyncMock;
        jest.mock('fs', () => ({
          ...realFs,
          readFileSync: readFileSyncMock,
        }));

        coreMock = jest.requireMock('@actions/core');
        const execMock = jest.requireMock('@actions/exec');
        const gitMock = jest.requireMock('../src/lib/git');
        const githubMock = jest.requireMock('../src/lib/github');

        // Default happy-path mocks
        gitMock.applyPatchSafe = jest.fn().mockResolvedValue(undefined);
        gitMock.validateNoGithubPaths = jest.fn().mockResolvedValue(undefined);
        gitMock.pushToBranch = jest.fn().mockResolvedValue(undefined);
        githubMock.fetchPrBranchName = jest.fn().mockResolvedValue('feature/lint-fix');
        execMock.exec = jest.fn().mockResolvedValue(0);
        execMock.getExecOutput = jest.fn().mockResolvedValue({
          exitCode: 0,
          stdout: 'abc1234\n',
          stderr: '',
        });

        if (mockSetup) {
          mockSetup({
            git: gitMock,
            github: githubMock,
            exec: execMock,
            readFileSync: readFileSyncMock,
          });
        }

        try {
          require('../src/lint-apply/index');
        } catch (e) {
          reject(e);
        }

        // Let the async run() settle
        setTimeout(resolve, 50);
      });
    });
  } finally {
    process.env = originalEnv;
  }

  return { coreMock, readFileSync: capturedReadFileSync };
}

describe('lint-apply entry point', () => {
  describe('STEP=apply', () => {
    it('reads patch file, applies, validates, and commits', async () => {
      const { coreMock, readFileSync } = await runLintApply({
        STEP: 'apply',
        PATCH_FILE: '/tmp/patch/lintfix.patch',
        PR_NUMBER: '42',
      });

      expect(readFileSync).toHaveBeenCalledWith('/tmp/patch/lintfix.patch', 'utf-8');
      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.info).toHaveBeenCalledWith(
        expect.stringContaining('PR #42')
      );
    });

    it('calls setFailed when patch contains .github/ paths (pre-check)', async () => {
      const { coreMock } = await runLintApply(
        {
          STEP: 'apply',
          PATCH_FILE: '/tmp/patch/lintfix.patch',
          PR_NUMBER: '42',
        },
        ({ readFileSync }) => {
          readFileSync.mockReturnValue(
            '--- a/.github/workflows/evil.yml\n+++ b/.github/workflows/evil.yml\n'
          );
        }
      );

      expect(coreMock.setFailed).toHaveBeenCalledWith(
        expect.stringContaining('.github/')
      );
    });

    it('calls setFailed when patch application fails', async () => {
      const { coreMock } = await runLintApply(
        {
          STEP: 'apply',
          PATCH_FILE: '/tmp/patch/lintfix.patch',
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
    it('fetches branch, pushes, and posts PR comment', async () => {
      const { coreMock } = await runLintApply({
        STEP: 'push',
        PR_NUMBER: '42',
        GITHUB_TOKEN: 'ghs_fake',
        GITHUB_REPOSITORY: 'owner/repo',
      });

      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.info).toHaveBeenCalledWith(
        expect.stringContaining('feature/lint-fix')
      );
    });
  });

  describe('unknown STEP', () => {
    it('calls setFailed for unknown step', async () => {
      const { coreMock } = await runLintApply({ STEP: 'bogus' });

      expect(coreMock.setFailed).toHaveBeenCalledWith(
        expect.stringContaining('Unknown STEP')
      );
    });
  });
});
