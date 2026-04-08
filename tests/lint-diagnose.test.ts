// tests/lint-diagnose.test.ts

const realFs = jest.requireActual('fs') as typeof import('fs');

async function runLintDiagnose(
  env: Record<string, string>,
  mockSetup?: (mocks: {
    github: Record<string, jest.Mock>;
    prompts: Record<string, jest.Mock>;
    fsMock: { writeFileSync: jest.Mock; readFileSync: jest.Mock; existsSync: jest.Mock };
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
        jest.mock('@actions/github');
        jest.mock('../src/lib/github');
        jest.mock('../src/lib/prompts');
        jest.mock('fs', () => {
          const actual = jest.requireActual('fs') as typeof import('fs');
          return {
            ...actual,
            writeFileSync: jest.fn(),
            readFileSync: jest.fn().mockImplementation(
              (path: string, ...args: unknown[]) => actual.readFileSync(path, ...args as [any])
            ),
            existsSync: jest.fn().mockReturnValue(false),
          };
        });

        coreMock = jest.requireMock('@actions/core');
        const githubMock = jest.requireMock('../src/lib/github');
        const promptsMock = jest.requireMock('../src/lib/prompts');
        const fsMock = jest.requireMock('fs');

        // Defaults
        githubMock.fetchRunLogsSafe = jest.fn().mockResolvedValue('lint output');
        githubMock.fetchPrDiffJson = jest.fn().mockResolvedValue([{ filename: 'a.ts', patch: 'diff' }]);
        promptsMock.buildLintDiagnosisPrompt = jest.fn().mockReturnValue('the prompt');

        if (mockSetup) {
          mockSetup({ github: githubMock, prompts: promptsMock, fsMock });
        }

        try {
          require('../src/lint-diagnose/index');
        } catch (e) {
          reject(e);
        }
        setTimeout(resolve, 50);
      });
    });
  } finally {
    process.env = originalEnv;
  }

  return { coreMock };
}

describe('lint-diagnose entry point', () => {
  describe('STEP=fetch-logs', () => {
    it('fetches logs and writes output file', async () => {
      const { coreMock } = await runLintDiagnose({
        STEP: 'fetch-logs',
        RUN_ID: '12345',
        GITHUB_TOKEN: 'ghs_fake',
        GITHUB_REPOSITORY: 'owner/repo',
      });

      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.setOutput).toHaveBeenCalledWith('log_url', expect.stringContaining('12345'));
    });
  });

  describe('STEP=fetch-diff', () => {
    it('fetches diff and writes output file', async () => {
      const { coreMock } = await runLintDiagnose({
        STEP: 'fetch-diff',
        PR_NUMBER: '42',
        GITHUB_TOKEN: 'ghs_fake',
        GITHUB_REPOSITORY: 'owner/repo',
      });

      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.info).toHaveBeenCalledWith(expect.stringContaining('1 files'));
    });
  });

  describe('STEP=build-prompt', () => {
    it('builds prompt and sets output', async () => {
      const { coreMock } = await runLintDiagnose({
        STEP: 'build-prompt',
        PR_NUMBER: '42',
        GITHUB_REPOSITORY: 'owner/repo',
        LOG_URL: 'https://example.com/logs',
        AUTO_APPLY: 'false',
      });

      expect(coreMock.setFailed).not.toHaveBeenCalled();
      expect(coreMock.setOutput).toHaveBeenCalledWith('prompt', 'the prompt');
    });
  });

  describe('STEP=read-outputs', () => {
    it('reads confidence and has_patch when files exist', async () => {
      const { coreMock } = await runLintDiagnose(
        { STEP: 'read-outputs' },
        ({ fsMock }) => {
          fsMock.existsSync.mockImplementation((p: string) =>
            p === '/tmp/confidence.txt' || p === '/tmp/lintfix.patch'
          );
          fsMock.readFileSync.mockImplementation((p: string) => {
            if (p === '/tmp/confidence.txt') return '  high  \n';
            if (p === '/tmp/lintfix.patch') return 'diff --git ...';
            return realFs.readFileSync(p);
          });
        }
      );

      expect(coreMock.setOutput).toHaveBeenCalledWith('confidence', 'high');
      expect(coreMock.setOutput).toHaveBeenCalledWith('has_patch', 'true');
    });

    it('outputs empty confidence and false when files missing', async () => {
      const { coreMock } = await runLintDiagnose({ STEP: 'read-outputs' });

      expect(coreMock.setOutput).toHaveBeenCalledWith('confidence', '');
      expect(coreMock.setOutput).toHaveBeenCalledWith('has_patch', 'false');
    });
  });

  describe('unknown STEP', () => {
    it('calls setFailed', async () => {
      const { coreMock } = await runLintDiagnose({ STEP: 'bogus' });
      expect(coreMock.setFailed).toHaveBeenCalledWith(expect.stringContaining('Unknown STEP'));
    });
  });
});
