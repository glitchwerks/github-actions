// src/lint-failure/index.ts
import * as core from '@actions/core';
import * as fs from 'fs';
import { fetchRunLogsSafe, fetchPrDiffJson } from '../lib/github';
import { buildLintDiagnosisPrompt } from '../lib/prompts';

const step = process.env.STEP ?? '';
const runId = process.env.RUN_ID ?? '';
const prNumber = process.env.PR_NUMBER ?? '';
const token = process.env.GITHUB_TOKEN ?? '';
const repository = process.env.GITHUB_REPOSITORY ?? '';
const logUrl = process.env.LOG_URL ?? '';
const autoApply = process.env.AUTO_APPLY ?? 'false';

async function run(): Promise<void> {
  const [owner, repo] = repository.split('/');

  switch (step) {
    case 'fetch-logs': {
      const logs = await fetchRunLogsSafe(token, runId, 16000);
      fs.writeFileSync('/tmp/lint_logs.txt', logs);

      const url = `https://github.com/${repository}/actions/runs/${runId}`;
      core.setOutput('log_url', url);
      core.info(`Fetched ${logs.length} bytes of lint logs`);
      break;
    }

    case 'fetch-diff': {
      const files = await fetchPrDiffJson(
        token,
        owner,
        repo,
        parseInt(prNumber, 10),
        30
      );
      fs.writeFileSync('/tmp/pr_diff.json', JSON.stringify(files, null, 2));
      core.info(`Fetched diff for ${files.length} files`);
      break;
    }

    case 'build-prompt': {
      const prompt = buildLintDiagnosisPrompt({
        prNumber: parseInt(prNumber, 10),
        repository,
        logUrl,
        logsFile: '/tmp/lint_logs.txt',
        diffFile: '/tmp/pr_diff.json',
        autoApply: autoApply === 'true',
      });
      core.setOutput('prompt', prompt);
      break;
    }

    default:
      core.setFailed(
        `Unknown STEP: '${step}'. Expected 'fetch-logs', 'fetch-diff', or 'build-prompt'.`
      );
  }
}

run().catch((err) => {
  core.setFailed(err instanceof Error ? err.message : String(err));
});
