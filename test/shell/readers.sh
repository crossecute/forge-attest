#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$ROOT/test/fixtures"
NORMALIZE="$ROOT/lib/normalize.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAILED=0
GREEN= RED= BOLD= RESET=
source "$ROOT/test/shell/assertions.sh"
source "$ROOT/test/shell/reader-support.sh"
for suite in "$ROOT"/test/shell/readers-*.sh; do source "$suite"; done
printf '\nReader checks: %s passed, %s failed\n' "$PASS" "$FAILED"
[[ "$FAILED" == 0 ]]
