/**
 * Checks whether an actor is in a comma-separated allowlist (case-insensitive).
 *
 * The allowlist takes full precedence over association checks when non-empty.
 * Matches are exact per-entry — no substring matching.
 *
 * @param actor - The GitHub username to check
 * @param authorizedUsers - Comma-separated list of authorized usernames
 * @returns true if actor is in the list
 */
export declare function checkAllowlist(actor: string, authorizedUsers: string): boolean;
/**
 * Checks whether a GitHub author_association grants authorization.
 *
 * Only OWNER, MEMBER, and COLLABORATOR are considered authorized.
 *
 * @param association - The author_association value from the GitHub event
 * @returns true if the association grants access
 */
export declare function checkAssociation(association: string): boolean;
//# sourceMappingURL=auth.d.ts.map