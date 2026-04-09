/**
 * Resolves the write token for git push operations.
 *
 * In v2, only GitHub App tokens are supported. The PAT fallback was removed.
 * This function is used by: apply-fix, lint-apply, lint-diagnose, lint-failure, tag-claude.
 *
 * @param appToken - The token from the create-github-app-token step (may be empty/undefined)
 * @returns The resolved token string
 * @throws Error if no token is available
 */
export declare function resolveWriteToken(appToken: string | undefined): string;
//# sourceMappingURL=tokens.d.ts.map