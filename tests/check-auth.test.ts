// Helper to run the entry point with specific env vars and return the core mock
async function runCheckAuth(env: Record<string, string>): Promise<jest.MockedObject<typeof import('@actions/core')>> {
  const originalEnv = { ...process.env };
  Object.assign(process.env, env);

  let coreMock!: jest.MockedObject<typeof import('@actions/core')>;

  try {
    await new Promise<void>((resolve, reject) => {
      jest.isolateModules(() => {
        jest.mock('@actions/core');
        // Capture the mock instance that the entry point will use
        coreMock = jest.requireMock('@actions/core');
        try {
          require('../src/check-auth/index');
          resolve();
        } catch (e) {
          reject(e);
        }
      });
    });
  } finally {
    process.env = originalEnv;
  }

  return coreMock;
}

describe('check-auth entry point', () => {
  describe('allowlist mode', () => {
    it('authorizes when actor is in allowlist (case-insensitive)', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'Alice',
        ASSOCIATION: 'NONE',
        AUTHORIZED_USERS: 'alice,bob',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'true');
    });

    it('rejects when actor is not in allowlist (ignores OWNER association)', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'eve',
        ASSOCIATION: 'OWNER',
        AUTHORIZED_USERS: 'alice,bob',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'false');
    });
  });

  describe('association mode (no allowlist)', () => {
    it('authorizes OWNER', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'someone',
        ASSOCIATION: 'OWNER',
        AUTHORIZED_USERS: '',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'true');
    });

    it('authorizes MEMBER', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'someone',
        ASSOCIATION: 'MEMBER',
        AUTHORIZED_USERS: '',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'true');
    });

    it('authorizes COLLABORATOR', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'someone',
        ASSOCIATION: 'COLLABORATOR',
        AUTHORIZED_USERS: '',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'true');
    });

    it('rejects FIRST_TIME_CONTRIBUTOR', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'newbie',
        ASSOCIATION: 'FIRST_TIME_CONTRIBUTOR',
        AUTHORIZED_USERS: '',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'false');
    });

    it('rejects NONE', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'stranger',
        ASSOCIATION: 'NONE',
        AUTHORIZED_USERS: '',
        REQUIRE_ASSOCIATION: 'true',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'false');
    });
  });

  describe('association disabled', () => {
    it('authorizes everyone when require_association is false and no allowlist', async () => {
      const coreMock = await runCheckAuth({
        ACTOR: 'anyone',
        ASSOCIATION: 'NONE',
        AUTHORIZED_USERS: '',
        REQUIRE_ASSOCIATION: 'false',
      });

      expect(coreMock.setOutput).toHaveBeenCalledWith('authorized', 'true');
    });
  });
});
