# TODO

- [x] Initialize repository structure
- [x] Create `claude-pr-review` reusable workflow
- [x] Create `claude-tag-respond` reusable workflow
- [x] Create `pr-review` composite action
- [x] Create `tag-claude` composite action
- [x] Write root README
- [ ] Initialize git and push to GitHub (`cbeaulieu-gt/github-actions`)
- [ ] Cut `v1.0.0` tag and create floating `v1` pointer
- [x] Implement smart synchronize diff scoping in PR review workflow and composite action
- [ ] Test PR review action in a consuming repo
- [ ] Test tag-claude action in a consuming repo

## CI Failure + Apply Fix integration (#2–#7)

- [x] Fix CI log fetching to use plain text instead of binary gzip (#3)
- [x] Refactor `ci-failure.yaml` to use `anthropics/claude-code-action` (#2)
- [x] Add input validation to `apply-fix.yml` to block sensitive path diffs (#4)
- [x] Wrap `apply-fix` as a composite action at `apply-fix/action.yml` (#5)
- [x] Automate ci-failure → apply-fix pipeline on high-confidence diagnoses (#6)
- [x] Update README to document both new workflows and required secrets (#7)

## Static analysis (#9)

- [x] Add actionlint CI workflow to lint all workflow files on push and PR (#9)
