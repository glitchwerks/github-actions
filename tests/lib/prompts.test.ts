// tests/lib/prompts.test.ts
import { buildLintDiagnosisPrompt, LintDiagnosisParams } from '../../src/lib/prompts';

describe('buildLintDiagnosisPrompt', () => {
  const baseParams: LintDiagnosisParams = {
    prNumber: 42,
    repository: 'owner/repo',
    logUrl: 'https://github.com/owner/repo/actions/runs/12345',
    logsFile: '/tmp/lint_logs.txt',
    diffFile: '/tmp/pr_diff.json',
    autoApply: false,
  };

  it('produces a diagnosis-only prompt (auto-apply disabled)', () => {
    const prompt = buildLintDiagnosisPrompt(baseParams);
    expect(prompt).toMatchSnapshot();
  });

  it('produces a prompt with auto-apply instructions when enabled', () => {
    const prompt = buildLintDiagnosisPrompt({ ...baseParams, autoApply: true });
    expect(prompt).toMatchSnapshot();
  });

  it('includes the PR number in the prompt', () => {
    const prompt = buildLintDiagnosisPrompt(baseParams);
    expect(prompt).toContain('#42');
  });

  it('includes the repository name', () => {
    const prompt = buildLintDiagnosisPrompt(baseParams);
    expect(prompt).toContain('owner/repo');
  });

  it('includes the log URL in the confidence line', () => {
    const prompt = buildLintDiagnosisPrompt(baseParams);
    expect(prompt).toContain('https://github.com/owner/repo/actions/runs/12345');
  });

  it('includes the file paths for Claude to read', () => {
    const prompt = buildLintDiagnosisPrompt(baseParams);
    expect(prompt).toContain('/tmp/lint_logs.txt');
    expect(prompt).toContain('/tmp/pr_diff.json');
  });

  it('does not include apply instructions when autoApply is false', () => {
    const prompt = buildLintDiagnosisPrompt(baseParams);
    expect(prompt).not.toContain('git apply');
    expect(prompt).not.toContain('git commit');
    expect(prompt).not.toContain('git push');
  });

  it('includes apply instructions when autoApply is true', () => {
    const prompt = buildLintDiagnosisPrompt({ ...baseParams, autoApply: true });
    expect(prompt).toContain('git apply');
    expect(prompt).toContain('git commit');
    expect(prompt).toContain('git push');
  });

  it('includes .github/ path restriction in auto-apply mode', () => {
    const prompt = buildLintDiagnosisPrompt({ ...baseParams, autoApply: true });
    expect(prompt).toContain('.github/');
  });
});
