#!/usr/bin/env bash
# Print the current process UID. Used by STAGE 4 to pin the smoke-test UID
# to the GitHub-hosted runner UID dynamically (§13 Q10).
#
# Output: a single line with the integer UID.

set -euo pipefail
id -u
