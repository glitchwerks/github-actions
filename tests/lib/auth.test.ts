import { checkAllowlist, checkAssociation } from '../../src/lib/auth';

describe('checkAllowlist', () => {
  it('returns true when actor is in the list (exact match)', () => {
    expect(checkAllowlist('alice', 'alice,bob')).toBe(true);
  });

  it('returns true when actor matches case-insensitively', () => {
    expect(checkAllowlist('Alice', 'alice,bob')).toBe(true);
  });

  it('returns true when list has spaces around commas', () => {
    expect(checkAllowlist('bob', 'alice, bob, charlie')).toBe(true);
  });

  it('returns false when actor is not in the list', () => {
    expect(checkAllowlist('eve', 'alice,bob')).toBe(false);
  });

  it('does not partial-match substrings', () => {
    expect(checkAllowlist('ali', 'alice,bob')).toBe(false);
  });

  it('returns false when list is empty string', () => {
    expect(checkAllowlist('alice', '')).toBe(false);
  });
});

describe('checkAssociation', () => {
  it('returns true for OWNER', () => {
    expect(checkAssociation('OWNER')).toBe(true);
  });

  it('returns true for MEMBER', () => {
    expect(checkAssociation('MEMBER')).toBe(true);
  });

  it('returns true for COLLABORATOR', () => {
    expect(checkAssociation('COLLABORATOR')).toBe(true);
  });

  it('returns false for CONTRIBUTOR', () => {
    expect(checkAssociation('CONTRIBUTOR')).toBe(false);
  });

  it('returns false for FIRST_TIME_CONTRIBUTOR', () => {
    expect(checkAssociation('FIRST_TIME_CONTRIBUTOR')).toBe(false);
  });

  it('returns false for NONE', () => {
    expect(checkAssociation('NONE')).toBe(false);
  });

  it('returns false for empty string', () => {
    expect(checkAssociation('')).toBe(false);
  });
});
