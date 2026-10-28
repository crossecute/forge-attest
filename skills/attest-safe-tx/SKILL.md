---
name: attest-safe-tx
description: Write and run a forge-attest claim that proves a Safe transaction is exactly the output of a Forge script at a pinned commit, and report the hash a signer should see on their hardware wallet. Use after build-safe-tx, or when a signer asks to verify a queued Safe transaction against an ops repo script.
argument-hint: [script path or claim file] [--nonce N] [--network NAME]
allowed-tools: [Read, Glob, Grep, Write, Edit, Bash]
---

# Attest a Safe transaction

Request: $ARGUMENTS

`${CLAUDE_PLUGIN_ROOT}` is the forge-attest checkout. Its `README.md` documents
every claim field and check; read the "Pointing it at your own repo" and "Threat
model" sections before writing a claim.

## Rules

- Pin only values that the run derived and the user has reviewed. Never fill an
  `expected_*` field from memory or from the transaction service.
- A claim pins a commit, so the script must be committed and the commit must be
  reachable at `producer_repo`. If the working tree has uncommitted changes to
  the script, stop and say so.
- `producer_setup` and the producer's script run as code on this machine. Only
  point `producer_repo` at a repo the user controls.
- Do not edit `attest.sh` or `lib/` to make a run pass.

## Steps

1. **Write the claim.** Create `attest/<OUTPUT_NAME>.toml` in the ops repo,
   starting from `${CLAUDE_PLUGIN_ROOT}/attest.batch.example.toml`. Set
   `producer_repo` (the ops repo's remote URL), `producer_commit` (the full
   40-hex SHA of the commit holding the script), `producer_script`,
   `output_path`, `safe_nonce`, and `safe_network` if the live check should run.
   For a script made from the build-safe-tx template, set
   `input_format = "tx-builder"`. Always set `safe_address`: the file binds its
   own Safe, so this acts as an independent cross-check, and the live check
   skips without it. Leave all three `expected_*` hashes blank.

2. **First run.** `${CLAUDE_PLUGIN_ROOT}/attest.sh --config attest/<OUTPUT_NAME>.toml --json`.
   With blank pins it prints every derived hash. It also prints `ATTESTED`,
   because with nothing pinned only the cast and Solidity derivations are
   compared. Do not report that as a verdict. Show the user the decoded summary
   and the three hashes. If they have not seen a readback of this transaction
   (build-safe-tx step 5), do that readback now before going on.

3. **Pin.** On the user's confirmation, write the derived values into
   `expected_output_sha256` (only when the producer is byte-stable, as the
   template is), `expected_canonical_sha256`, and `expected_safe_tx_hash`.

4. **Verify.** Run again. Report the verdict line as printed. When the
   transaction has been proposed, run with `--require-live`; a skipped live check
   is an unknown, not a pass. Report which checks ran and which were skipped.

5. **Hand over.** Tell the signer the `safeTxHash` to compare on their hardware
   wallet, the Safe and nonce it is valid for, and that a different nonce means a
   different transaction. Suggest committing the claim and running it in CI with
   the forge-attest GitHub Action (see the README), pinned by commit SHA.
