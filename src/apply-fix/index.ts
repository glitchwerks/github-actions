// src/apply-fix/index.ts
import * as core from '@actions/core';
import * as exec from '@actions/exec';
import { applyPatchSafe, validateNoGithubPaths, pushToBranch } from '../lib/git';
import { fetchPrBranchName } from '../lib/github';

const step = process.env.STEP ?? '';
const diffContent = process.env.DIFF_CONTENT ?? '';
const fixDesc = process.env.FIX_DESC ?? '';
const prNumber = process.env.PR_NUMBER ?? '';
const token = process.env.GITHUB_TOKEN ?? '';
const repository = process.env.GITHUB_REPOSITORY ?? '';

async function run(): Promise<void> {
  switch (step) {
    case 'apply': {
      await applyPatchSafe(diffContent);
      await validateNoGithubPaths();

      await exec.exec('git', [
        'commit',
        '-m',
        `Claude auto-fix: ${fixDesc}\n\nApplied automatically via apply-fix composite action.\nPR: #${prNumber}`,
      ]);
      core.info(`Applied and committed fix for PR #${prNumber}`);
      break;
    }

    case 'push': {
      const [owner, repo] = repository.split('/');
      const branch = await fetchPrBranchName(
        token,
        owner,
        repo,
        parseInt(prNumber, 10)
      );
      await pushToBranch(branch);
      core.info(`Pushed fix to ${branch}`);
      break;
    }

    default:
      core.setFailed(`Unknown STEP: '${step}'. Expected 'apply' or 'push'.`);
  }
}

run().catch((err) => {
  core.setFailed(err instanceof Error ? err.message : String(err));
});
