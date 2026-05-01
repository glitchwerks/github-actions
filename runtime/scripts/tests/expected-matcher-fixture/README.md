# EXPECTED_FILE matcher fixture

Phase 3's overlay smoke test must implement the matcher described in
`runtime/scripts/smoke-test.sh` (the EXPECTED_FILE comment block) and pass these
two cases:

- `enumeration-pass.json` against `expected.yaml` → exit 0 (clean)
- `enumeration-fail.json` against `expected.yaml` → exit 1 with TWO error lines:
  - `ERROR inventory_must_not_contain_present kind=agents name=code-writer`
  - `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`

Phase 3's smoke test runner MUST include a CI step that runs this fixture
before promoting any overlay image. If the fixture cases do not produce the
exact outcomes above, the matcher is non-conforming.
