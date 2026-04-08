import { resolveWriteToken } from '../../src/lib/tokens';

describe('resolveWriteToken', () => {
  describe('when App token is provided', () => {
    it('returns the token string', () => {
      const token = resolveWriteToken('ghs_abc123def456');
      expect(token).toBe('ghs_abc123def456');
    });
  });

  describe('when App token is empty string', () => {
    it('throws with a clear error message', () => {
      expect(() => resolveWriteToken('')).toThrow(
        'No authentication token provided'
      );
    });

    it('includes setup instructions in the error', () => {
      expect(() => resolveWriteToken('')).toThrow(
        'Set app_id + app_private_key inputs'
      );
    });
  });

  describe('when App token is undefined', () => {
    it('throws with a clear error message', () => {
      expect(() => resolveWriteToken(undefined)).toThrow(
        'No authentication token provided'
      );
    });
  });
});
