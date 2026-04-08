// tests/lib/git-push.test.ts
import * as exec from '@actions/exec';

jest.mock('@actions/exec');
const mockExec = exec.exec as jest.MockedFunction<typeof exec.exec>;

import { pushToBranch } from '../../src/lib/git';

describe('pushToBranch', () => {
  beforeEach(() => {
    jest.resetAllMocks();
  });

  it('calls git push with the correct remote ref', async () => {
    mockExec.mockResolvedValue(0);

    await pushToBranch('feature/my-fix');

    expect(mockExec).toHaveBeenCalledWith(
      'git',
      ['push', 'origin', 'HEAD:feature/my-fix'],
      expect.any(Object)
    );
  });

  it('throws when git push fails', async () => {
    mockExec.mockRejectedValue(new Error('push rejected'));

    await expect(pushToBranch('feature/my-fix')).rejects.toThrow('push rejected');
  });
});
