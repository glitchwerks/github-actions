# EXPECTED_FILE matcher fixture

This fixture is the **executable contract** for `runtime/scripts/inventory-match.sh`.
Phase 3's overlay smoke MUST produce the documented exit codes + stderr lines for
every case below. STAGE 1c-fixture (`.github/workflows/runtime-build.yml`) replays
the entire fixture before any overlay image is built; failures block STAGE 3.

The matcher contract is also documented inline in the comment block at
`runtime/scripts/smoke-test.sh:124-151` (Phase 2 author of the contract). The matcher
script implements that contract; this fixture verifies it.

## Exit-code conventions

| Code | Meaning |
|------|---------|
| 0 | clean — no violations |
| 1 | at least one violation, OR `expected.yaml` is empty / has no assertions |
| 2 | malformed input — parse failure, unknown top-level key, invalid type, unsupported field |

Exit 2 is distinct from exit 1 so upstream triage can distinguish "your YAML is broken"
from "your image diverges from the contract."

## Fixture cases

### Original (from Phase 2)

- **`enumeration-pass.json` against `expected.yaml`** → exit 0, no stderr.
- **`enumeration-fail.json` against `expected.yaml`** → exit 1, exactly two stderr lines:
  - `ERROR inventory_must_not_contain_present kind=agents name=code-writer`
  - `ERROR inventory_must_not_contain_present kind=plugins name=skill-creator`

### Empty / no-assertions (Pass-1 Charge 5; added Phase 3)

- **`expected-empty.yaml` against `enumeration-pass.json`** → exit 1 with stderr
  `ERROR expected_yaml_empty file=<path>`. Zero-byte file; no top-level keys.
- **`expected-no-assertions.yaml` against `enumeration-pass.json`** → exit 1 with stderr
  `ERROR expected_yaml_no_assertions file=<path>`. Both top-level keys present but every
  kind-array is empty.

### Malformed inputs (Pass-1 Charge 6; added Phase 3)

- **`expected-malformed.yaml` against `enumeration-pass.json`** → exit 2 with stderr
  `ERROR expected_yaml_parse_failed file=<path>`. yq parse fails on broken YAML.
- **`enumeration-malformed.json` against `expected.yaml`** → exit 2 with stderr
  `ERROR enumeration_json_parse_failed file=<path>`. jq parse fails on truncated JSON.

### Schema violations (Pass-1 Charge 5; added Phase 3)

- **`expected-unknown-key.yaml` against `enumeration-pass.json`** → exit 2 with stderr
  `ERROR expected_yaml_unknown_top_level_key key=bogus_section file=<path>`. Top-level
  key not in `{must_contain, must_not_contain}`.
- **`expected-mnc-skills.yaml` against `enumeration-pass.json`** → exit 2 with stderr
  `ERROR expected_yaml_unsupported_field field=must_not_contain.skills file=<path>`.
  `must_not_contain.skills` is reserved and not supported in v1 per §10.2.

## Running locally

```bash
bash runtime/scripts/inventory-match.sh \
  runtime/scripts/tests/expected-matcher-fixture/enumeration-pass.json \
  runtime/scripts/tests/expected-matcher-fixture/expected.yaml
```

Requires `yq` (mikefarah v4) and `jq` on `$PATH`. CI installs `yq` in STAGE 1c-fixture;
locally, install via `brew install yq` (macOS), `winget install MikeFarah.yq` (Windows),
or download a static binary from <https://github.com/mikefarah/yq/releases>.

## Conformance contract

If any of the cases above produces a different exit code or different stderr line, the
matcher is non-conforming. Treat as a STOP-and-fix event in Phase 3 dry-run.
