#!/usr/bin/env bash

group "Reader harness failure propagation"
case_root="$TMP/harness-case"
mkdir -p "$case_root/test/shell"
cp "$ROOT/test/shell/"{readers.sh,assertions.sh,reader-support.sh} "$case_root/test/shell/"
cp "$ROOT/foundry.toml" "$case_root/foundry.toml"
cat >"$case_root/test/shell/readers-injected.sh" <<'SUITE'
false
printf 'CONTINUED_AFTER_FAILURE\n'
SUITE
if bash "$case_root/test/shell/readers.sh" >"$TMP/harness-failure.log" 2>&1; then
  fail "an unexpected suite error fails the reader harness"
else pass "an unexpected suite error fails the reader harness"; fi
if grep -q CONTINUED_AFTER_FAILURE "$TMP/harness-failure.log"; then
  fail "suite errors stop before later assertions"
else pass "suite errors stop before later assertions"; fi
cat >"$case_root/fail-normalize.sh" <<'STUB'
#!/usr/bin/env bash
printf 'injected normalization failure\n' >&2
exit 23
STUB
cat >"$case_root/test/shell/readers-injected.sh" <<'SUITE'
NORMALIZE="$ROOT/fail-normalize.sh"
jq() { printf 'JQ_AFTER_NORMALIZATION\n'; }
if reader_e2e missing.json auto ""; then exit 0; else exit 1; fi
SUITE
if bash "$case_root/test/shell/readers.sh" >"$TMP/harness-normalize.log" 2>&1; then
  fail "failed normalization fails the E2E helper"
else pass "failed normalization fails the E2E helper"; fi
if grep -q JQ_AFTER_NORMALIZATION "$TMP/harness-normalize.log"; then
  fail "failed normalization stops before derived fixtures or configuration"
else pass "failed normalization stops before derived fixtures or configuration"; fi
