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
export function buildLintDiagnosisPrompt(params: LintDiagnosisParams): string {
  const { prNumber, repository, logUrl, logsFile, diffFile, autoApply } = params;

  const step3 = autoApply
    ? `## Step 3 — Apply the fix

If your confidence is **high** AND you produced a non-empty fix diff:

1. Confirm the fix diff does not touch any path under \`.github/\`. If it does, skip the apply and note this in the comment.
2. Write the unified diff to \`/tmp/lintfix.patch\`.
3. Apply it: \`git apply --index /tmp/lintfix.patch\`
4. Commit: \`git commit -m "Claude lint-fix: <fix_description>\\n\\nApplied automatically by claude-lint-fix workflow.\\nPR: #${prNumber}"\`
5. Push to the PR branch: run \`gh api repos/${repository}/pulls/${prNumber} --jq '.head.ref'\` to get the branch name, then \`git push origin HEAD:<branch>\`.
6. Append a brief note to the PR comment confirming the fix was applied and the commit SHA.

If confidence is **medium** or **low**, or there is no fix diff, stop after posting the comment. Do not modify any files.`
    : `## Step 3 — Write outputs for the apply job

After posting the comment:
1. Write your confidence level (exactly one of: high, medium, low) to \`/tmp/confidence.txt\`
2. If your confidence is high AND you have a minimal fix diff:
   - Write the unified diff to \`/tmp/lintfix.patch\`
   - The diff must NOT touch any path under \`.github/\`
   - If the fix would touch \`.github/\`, write \`low\` to \`/tmp/confidence.txt\` instead

Do not perform any git operations.`;

  return `A linter has failed on pull request #${prNumber} in repository ${repository}.

Your job is to identify the specific lint violations and diagnose the root cause.

## Step 1 — Read the evidence

Read the following files written by prior workflow steps:
- \`${logsFile}\` — raw output from the failed lint steps (up to 16 000 chars)
- \`${diffFile}\` — files changed by the PR with their diffs (JSON array)

Also read \`CLAUDE.md\` if it exists in the repository root — it documents linting tools and conventions.

## Step 2 — Post a structured diagnosis comment

Post a comment on PR #${prNumber} using:
  gh pr comment ${prNumber} --body "..."

The comment must follow this exact structure:

    ## Claude Lint Diagnosis

    **Summary:** <one sentence — which linter failed and how many violations>

    **Violations:**
    <bullet list — each item: file path, line number, rule name, short description>

    **Suggested fix:** <one sentence describing the minimal change needed>

    \`\`\`diff
    <unified diff of the fix, or omit this block entirely if no code change is needed>
    \`\`\`

    **Confidence:** <high | medium | low> | [View lint logs](${logUrl})

    ---
    _This diagnosis was generated automatically by Claude. Review before applying any fix._

Only report violations that appear in the log output. Do not infer violations from the diff alone.

${step3}`;
}
