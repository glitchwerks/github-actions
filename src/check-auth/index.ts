import * as core from '@actions/core';
import { checkAllowlist, checkAssociation } from '../lib/auth';

const actor = process.env.ACTOR ?? '';
const association = process.env.ASSOCIATION ?? '';
const authorizedUsers = process.env.AUTHORIZED_USERS ?? '';
const requireAssociation = process.env.REQUIRE_ASSOCIATION ?? 'true';

let authorized = false;

if (authorizedUsers) {
  authorized = checkAllowlist(actor, authorizedUsers);
  if (authorized) {
    core.info(`Authorized via allowlist: ${actor}`);
  } else {
    core.info(`Not authorized: ${actor} is not in the authorized_users list. Skipping.`);
  }
} else if (requireAssociation === 'true') {
  authorized = checkAssociation(association);
  if (authorized) {
    core.info(`Authorized via association: ${actor} (${association})`);
  } else {
    core.info(`Not authorized: ${actor} has association '${association}'. Skipping.`);
  }
} else {
  authorized = true;
  core.info('Association check disabled — all commenters authorized.');
}

core.setOutput('authorized', authorized ? 'true' : 'false');
