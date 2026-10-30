# Code review instructions

These are for Copilot code review. They cover what a review should look for.

## What this repo is

A verifier that proves a queued Gnosis Safe transaction is exactly the output of a
pinned Forge script. `attest.sh` reads the claim through `lib/claims.sh` (one claim,
or several runs and claims), clones the producer at a pinned commit, re-runs its
script, folds the JSON into one canonical SafeTx (`lib/normalize.sh`), derives the
EIP-712 `safeTxHash` with `cast` (`lib/derive.sh`) and again in Solidity
(`test/Attest.t.sol`, `test/SafeTx.sol`), and compares it with the Safe Transaction
Service through the vendored `lib/safe_hashes.sh`. `lib/propose.sh` signs and submits
an attested transaction under `--propose`. `action.yml` wraps `attest.sh` as a GitHub
Action, and `skills/` is a Claude Code plugin.

Its output is a verdict that signers and CI gates trust. The worst bug here is a run
that says `ATTESTED` when it should not. Consumers pin claim hashes
(`expected_canonical_sha256`, `expected_safe_tx_hash`) and parse the `--json`
verdict, so a change to the canonical form or the verdict's fields breaks them.

Three inputs are untrusted: the claim file (a fork PR controls it in CI), the
producer's output, and every Safe Transaction Service response.

Every PR here gets a human review. Base the verdict on what you found: without a
Medium or higher finding, do not mark a PR as needing a closer look. Touching
security-sensitive code is not a reason, since most of the repo is. Neither is a
claim you could not check here; list it with the checks you did not reach.

## Budget

A review has a fixed budget and stops when it runs out. Spend it on `attest.sh`,
`lib/`, `action.yml` and `test/SafeTx.sol` first, in the order below, and stop a
pass when you have a finding or have cleared it. CI already runs `forge test` and
`test/shell/run.sh`, so do not repeat either. To check a test count or whether a
named test passes, read `out/copilot-forge-test.txt` and `out/copilot-shell-test.txt`,
which the setup steps wrote on the PR head. The shell suite prints one `✓` or `✗`
line per assertion and ends with its totals.

End every summary, whatever the PR touches, with the checks you did not reach,
named by their number or heading below, so the human reviewer knows what is left.
If you reached them all, say so.

## What to report

Report a finding only when you can name a concrete claim, producer output, service
response or environment, and the wrong verdict or effect. "Consider adding
validation" without a failing case is not a finding.

Post only Medium and higher findings as inline comments. Collect Low findings in one
list in the review summary.

Write a test only when you suspect a specific bug, not to confirm that code works.
For bash, add assertions to `test/shell/run.sh` using its `assert_eq` and
`assert_contains` helpers; for Solidity, run one with `forge test --match-test <name>`.
Include it in the comment. If you could not write or run one, say so.

## Checks, highest priority first

1. **Fail closed.** A check left out by the claim may warn and skip, as an unset
   optional pin or a live check without `--require-live` does, but a run with no
   `expected_*` pin at all fails. A check that runs and cannot finish must end in
   `record_fail`, or in `die`, which exits 1 with no verdict. Look for an empty
   value treated as agreement, an exit code ignored, a `|| true` that hides a
   failure, a skipped branch that still prints `ok`, or a tool that can exit 0
   without doing the work (`forge test` with no matching test, for example). The
   exit code and the `--json` verdict must agree, because both come from
   `FAILURES`.
2. **Canonical form and pins.** A change to what `lib/normalize.sh` emits (key
   order, quoting, casing, defaults) changes every pinned
   `expected_canonical_sha256`. A change to the verdict's field names or meaning
   breaks every `--json` and Action consumer. Either needs to be called out in the
   PR, not slipped in.
3. **Two derivations agree.** `lib/normalize.sh` and `test/SafeTx.sol` implement
   the same folding: format detection, batch modes, the MultiSend defaults per Safe
   version, and `lib/multisend-exceptions.json`. `lib/derive.sh` and `SafeTxLib.hash`
   compute the same digest. A change to one side must be in the other, and covered
   by a fixture both suites read.
4. **Untrusted input reaching code.** A config value, producer output or service
   response must not reach `eval`, `bash -c` (other than `producer_setup`, which is
   code by design), arithmetic (`(( ))`, `-eq`, `-gt`, or array subscripts, which
   run command substitutions), or a command's options (a value that starts with
   `-`). jq takes values through `--arg`, never by splicing them into the filter.
   Text from the service or the producer is filtered before it is printed. Under
   `--json`, stdout carries only the verdict document.
5. **What is signed.** Under `--propose`, the typed data comes only from the
   attested canonical form, the signature is checked against the attested hash
   before anything is sent, and nothing is sent unless every offline check passed
   and, with several claims, every claim's preflight passed.
   A service response can make the run refuse but must not change what is signed.
6. **The claim and the clone.** The claim is read one way: no headers but `[[run]]`
   and `[[run.claim]]`, no repeated or unknown keys. Paths from it stay inside the
   clone. Every file a run writes is claimed or listed as unclaimed. The producer's commit is
   checked out and verified by full SHA. Nothing a producer commits (an output file,
   a symlink) can stand in for what its script writes.
7. **The Action and workflows.** Inputs reach `run:` blocks through `env:`, never
   through `${{ }}` inside the script. Config-derived strings are escaped before they
   reach the job summary. `$GITHUB_OUTPUT` uses a random delimiter. Third-party
   actions are pinned by commit SHA. No workflow uses `pull_request_target`. The
   `major-tag` workflow moves only a bare `vN` ref for a `vX.Y.Z` release.
8. **One source.** A value or check needed in two places (the network table, which
   both the live check and `propose.sh` read from `lib/safe_hashes.sh`; a shape check
   in both `attest.sh` and `propose.sh`) must come from one place.
9. **Tests.** A behavior change in `attest.sh` or `lib/` needs an assertion in
   `test/shell/run.sh`. A property both derivations must hold goes in a fixture both
   suites read. A fixture must be a shape a real producer or the Safe UI can emit,
   or say why not in `test/fixtures/README.md`. A stub (the `curl` stand-ins in
   `run.sh`) must fail the way the real service does, not more kindly.

## After those, if budget remains

- If the code and the README disagree, especially its "How it proves it" table and
  its Threat model, report it and say which one you think is wrong and why. Same for
  `skills/*/SKILL.md`, `attest.toml` and `attest.batch.example.toml`.
- Check that the PR description's claims match the diff: "no behavior change",
  which checks or files are covered, which tests were added, and any counts it states.

## Large PRs

A PR is large when it changes more than 10 files or more than 500 lines. For a large
PR, do only the numbered checks. Skip the docs and PR-description checks, and read
test files only to check a suspected bug or item 9.

## PRs that only touch docs or tests

Skip the numbered checks. Report only claims that are wrong against the code,
citations that point at something that no longer says what the text claims, counts
the PR description states (check them against the two files under `out/`), and
tests that cannot fail (an assertion that holds whatever the code does, or a fixture
or stub that never reaches the path under test).

## What not to report

- Formatting and style. There is no shell linter in CI; report a shell construct
  only when it causes a wrong result.
- Comment style or density, unless a comment states something the code does not do.
- The contents of `lib/safe_hashes.sh` and `lib/LICENSE-AGPL-3.0.txt`. They are
  vendored verbatim and pinned by sha256 in `lib/VENDORED.md`. Do report a change to
  either that does not update that record, or a way `attest.sh` calls or parses
  `safe_hashes.sh` that is wrong.
