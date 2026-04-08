// src/lint-apply/index.ts
import * as core from '@actions/core';
import * as exec from '@actions/exec';
import * as fs from 'fs';
import { applyPatchSafe, validateNoGithubPaths, pushToBranch } from '../lib/git';
import { fetchPrBranchName } from '../lib/github';

const step = process.env.STEP ?? '';
const patchFile = process.env.PATCH_FILE ?? '';
const prNumber = process.env.PR_NUMBER ?? '';
const token = process.env.GITHUB_TOKEN ?? '';
const repository = process.env.GITHUB_REPOSITORY ?? '';

async function run(): Promise<void> {
  switch (step) {
    case 'apply': {
      const patchContent = fs.readFileSync(patchFile, 'utf-8');

      // Defense-in-depth: pre-check patch text for .github/ paths before applying.
      // The diagnose step already validated, but the artifact on disk could
      // theoretically be tampered with between jobs.
      if (/^(---|\+\+\+) [ab]\/.github\//m.test(patchContent)) {
        core.setFailed('Patch contains changes to .github/ — aborting for safety');
        return;
      }

      await applyPatchSafe(patchContent);
      await validateNoGithubPaths();

      await exec.exec('git', [
        'commit',
        '-m',
        `Claude lint-fix: auto-applied high-confidence fix\n\nApplied automatically by claude-lint-fix workflow.\nPR: #${prNumber}`,
      ]);
      core.info(`Applied lint fix and committed for PR #${prNumber}`);
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

      // Capture the commit SHA to include in the PR comment
      const { stdout: sha } = await exec.getExecOutput('git', ['rev-parse', 'HEAD']);
      const commitSha = sha.trim();

      // Post a PR comment confirming the fix was applied
      await exec.exec(
        'gh',
        [
          'pr',
          'comment',
          prNumber,
          '--body',
          `:white_check_mark: **Claude lint-fix applied:** committed \`${commitSha}\` to \`${branch}\`.`,
        ],
        {
          env: {
            ...process.env,
            GH_TOKEN: token,
          },
        }
      );

      core.info(`Pushed lint fix to ${branch} and posted comment`);
      break;
    }

    default:
      core.setFailed(`Unknown STEP: '${step}'. Expected 'apply' or 'push'.`);
  }
}

run().catch((err) => {
  core.setFailed(err instanceof Error ? err.message : String(err));
});
