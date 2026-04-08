/** Parameters for building a lint diagnosis prompt. */
export interface LintDiagnosisParams {
    /** Pull request number */
    prNumber: number;
    /** Full repository name (e.g., 'owner/repo') */
    repository: string;
    /** URL to the failed lint run logs */
    logUrl: string;
    /** Path to the lint logs file on disk */
    logsFile: string;
    /** Path to the PR diff JSON file on disk */
    diffFile: string;
    /** Whether Claude should apply the fix automatically */
    autoApply: boolean;
}
/**
 * Builds the prompt string for Claude lint diagnosis.
 *
 * The prompt instructs Claude to read evidence files, post a structured
 * diagnosis comment, and optionally apply a fix if autoApply is enabled.
 *
 * @param params - The typed parameters for prompt interpolation
 * @returns The complete prompt string
 */
export declare function buildLintDiagnosisPrompt(params: LintDiagnosisParams): string;
//# sourceMappingURL=prompts.d.ts.map