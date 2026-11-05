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
   With blank pins it prints every derived hash. This run is not a verdict,
   whatever it prints: with nothing pinned it reports `NOT ATTESTED` with
   `no expected hash pinned`. Any other failure is real; stop and report it.
   Show the user the decoded summary
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

6. **Sign off, if asked.** Only when the user asks to submit it, and only after
   step 4 attested, give them the command to run themselves:
   `SAFE_API_KEY=<key> ${CLAUDE_PLUGIN_ROOT}/attest.sh --config attest/<OUTPUT_NAME>.toml --attest -- <wallet flags>`,
   with their signer's `cast` flags (`--ledger`, `--trezor`, `--account <name>`).
   Do not run it for them: it signs with their wallet and publishes to the Safe
   Transaction Service. It proposes the transaction, or confirms it if already
   queued, then requires the live check. For a nested claim it signs the child's
   approval instead and needs `child_network` set. The hashes it prints before
   signing should match the device and step 5.

For a complete Safe EIP-712 envelope, use `input_format = "safe-eip712"`.
Set `input_profile = "safe-utils"` only for the pinned variant that omits the
explicit domain type; otherwise use the default `safe` profile. Keep all signed
fields in the producer output and reconcile claim bindings. See
`docs/producer-readers.md`. Do not treat console markers or two signing hashes as
the full envelope.

For an exported service proposal body, use `input_format = "safe-service"` and
an explicit chain binding if missing. Only opt into the pinned `safe-utils`
profile when its documented omissions apply. Do not use a downloaded service
response as the producer artifact or infer a nonce. Both hash aliases are checked
if present; see `docs/producer-readers.md`.

For supported `safe-utils` scripts that submit through `solidity-http`'s bare
curl POST over FFI, use `capture = "safe-utils"` on a run with a pinned RPC block.
Keep the original producer script unchanged and claim each intercepted request
with `input_format = "safe-service"`, `input_profile = "safe-utils"`, an explicit
Safe and nonce, and reviewed hashes. `output_path` names the capture, not a file
the producer must write. Use only public test keys for the producer's local
signature. This transport adapter is not a network sandbox; review the actual
HTTP/FFI code path and the limits in `README.md`. See `attest.capture.example.toml`.

For decoded Transaction Builder entries, opt into `input_profile = "static-v1"`
with `input_format = "tx-builder"` (or its `tx-builder-decoded` alias). Check that
the descriptor uses only the supported address/bool/uint8/uint256 scalar types.
Do not choose a profile from `meta.txBuilderVersion` alone. Unsupported types
need producer-encoded calldata; see `docs/producer-readers.md` for the exact
version evidence, input limits and mismatch rules.

For a Zeus `MultisigBuilder` script, which writes no file, use
`input_format = "zeus-traces"` in a `[[run]]` that sets `rpc_env` and `fork_block`
and puts the `ZEUS_*` values it reads in `[run.env]`. Take those values and
`multisend_address` from the user or the Zeus environment, never from the model.
A reverted call, a call the script makes as itself, or a second event fails the
run; do not edit the claim to get around that. See `docs/producer-readers.md`.
