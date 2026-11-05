# Producer format additions from the Foundry multisig research

Status: proposal. Review date: 2026-11-05. Except for the Safe-address binding
fix described below, these additions are not implemented or accepted
`input_format` values.

## Recommendation

Add `safe-eip712` and a narrowly specified `safe-service` format first. Extend
`tx-builder` with an explicit, tested decoded-method profile next. Preserve the
current canonical SafeTx schema and its hashes. Treat raw calldata, Base/Optimism
simulation output, Zeus traces, and ABI-encoded bundles as separate integrations
with their own reproduction requirements.

The [research][research] groups projects by workflow, not by serialization.
An S3 or S4 library is not itself a file format. Many scripts build a request in
memory or print hashes without writing an artifact forge-attest can reproduce.
Supporting the request schema does not automatically support running the script.

## Review scope and evidence

Reviewed forge-attest at `c0ffe21`, its two readers, the claim parser, output-file
tracking, cross-check and fixtures. Reviewed transaction construction and output
paths in the shared Base, Optimism, Zeus, forge-safe and safe-utils families;
also inspected the distinct writers/consumers listed below. Links pin the upstream
commits read for this proposal. This is a format compatibility review, not a
security audit or an execution test of the upstream projects.

The research remains the usage inventory. Downstream forks and vendored copies
were not individually re-audited. Compatibility with a family does not establish
compatibility with every fork, release, Safe version or chain deployment.

| Producer or consumer inspected | Observed artifact or boundary | Recommendation |
|---|---|---|
| [Base MultisigScript][base] | Builds full SafeTx typed JSON or `0x1901` plus two hashes; prints bytes and emits `DataToSign` | `safe-eip712` for exported full JSON; capture/extraction work for event or console bytes |
| [Optimism MultisigTask][op], [GnosisSafeHashes][op-hashes] | Simulation prints/returns signing bytes and constructs Safe calls; hashing also accommodates older Safe domains | Reproduce full call and bindings; hash-only output cannot supply calldata; keep the existing Safe >= 1.3.0 boundary |
| [Base task-signing-tool types][validation] | Expected/actual hashes, state changes and optional actual Safe typed data | Import a complete typed-data member only through an explicit extraction contract; state validation remains a separate feature |
| [forge-safe BatchScript][forge-safe] | Full typed data and service request in memory; service request includes Safe but not chain ID | Export a request or typed-data file before signing; require the missing chain binding |
| [safe-utils Safe.sol][safe-utils] | Service POST body omits Safe and chain, and omits zero gas-token/refund-address fields | Versioned service profile and explicit bindings, with a producer export hook |
| [Euler SafeUtils][euler] | Writes full service payload with Safe but no chain ID; also writes Transaction Builder JSON | `safe-service` for payload; existing encoded batch path for the other export |
| [LendMultisig][lend] | Constructs SafeTx typed data and a service POST body; ledger signing is on the broadcast path | Export full typed data in a non-signing run; do not run submission just to obtain a fixture |
| [ether.fi Utils][etherfi] | Encoded batch with top-level `safeAddress`, no file `version`, hard-coded builder metadata | Honor `safeAddress`; do not infer the app schema from metadata |
| [Royco ParameterUpdateBase][royco] | Separate encoded schedule, execute and cancel batch files | Existing batch shape; separate claims and nonces, not a new timelock format |
| [Boundless writer][boundless] | Encoded batch, file `version = "1.0"`, builder metadata `1.16.5`, Safe in metadata | Existing encoded batch shape; volatile timestamp needs a canonical pin |
| [EthStrat SafeBatchLib][ethstrat] | Decoded method plus input strings; `data: null`; file version `1.0`, builder metadata `2.0.1` | Decoded-method profile; currently refused by both readers |
| [Signals PrepareSafeUpgrade][signals] | Raw calldata files and a plan containing `safe_args` and a separate `safe` description | Explicit extraction to an existing `call` is preferable to a project-specific plan format |
| [Agglayer ObsoleteRollupType][agglayer] | Returns/logs multisig or timelock calldata | Export a bound call; do not infer target or operation from bytes alone |
| [Arcadia SafeTransactionBuilder][arcadia] | Returns already wrapped `multiSend(bytes)` calldata per Safe | Export one outer `call`; never wrap that calldata again |
| [pkxp SafeScript][pkxp] | Writes ABI-encoded `batch` and `payloads`, with `multisendAddr` | Defer producer-specific bundle decoding until the exact struct schema is pinned |
| [Pantos SubmitSafeTxs][pantos] | Consumes an array of signed call records; obtains each nonce from chain state | Not a `tx-array` batch: these are separate executions, needing explicit nonce-bound claims |

## Transaction Builder is a set of versioned profiles

Do not equate these three identifiers:

1. File `version`, such as `"1.0"`, describes the export envelope.
2. `meta.txBuilderVersion` is producer metadata. Custom writers can hard-code it,
   or omit it. It is not proof of the code that produced the file.
3. The package name, package version, commit and resolved dependencies identify
   the implementation that exports/imports and encodes the calls.

The [current Frax helper][frax] emits file version `1.0`; the existing
[fixture provenance](../test/fixtures/README.md) does not pin that historical
helper revision. The current helper cannot establish the old fixture's dependency
version. Preserve this limitation in the fixture record rather than backfilling
a guessed package version.

Source comparison found the following:

| Implementation pinned in this review | Version evidence | Schema and encoding evidence | Compatibility conclusion |
|---|---|---|---|
| Safe `safe-react-apps` Transaction Builder | [Manifest][legacy-package]: `1.18.3` | [Models][legacy-models] include optional encoded `data`, method inputs and tuple components; [encoder][legacy-encoder] uses web3 ABI tools | A distinct reference profile; source inspected, UI not executed |
| Safe `safe-wallet-monorepo` Transaction Builder | [Manifest][wallet-package]: `2.1.0` | [Models][wallet-models] match the above definitions, but [encoder][wallet-encoder] uses ethers `Interface` and different integer parsing | Matching interfaces do not prove equivalent encoding for every input |
| ether.fi and Boundless custom writers | Their source hard-codes `1.16.5` in metadata | ether.fi uses top-level `safeAddress`; Boundless uses `meta.createdFromSafeAddress` | These are producer variants, not verified exports from app release 1.16.5 |
| EthStrat custom writer | Source hard-codes `2.0.1` in metadata | Emits decoded calls with null data | Does not prove compatibility with every Transaction Builder 2.0.1 export |

Both inspected Safe apps export file `version = "1.0"` while recording their own
package version in metadata ([legacy export/import][legacy-import],
[current export/import][wallet-import]). Their `BatchTransaction` models have no
`operation` field. forge-attest's support for that field is a producer extension,
not evidence that those UIs preserve delegatecalls. Both apps also expose a
[library export][library] shaped as `{ data: ... }`, which is not a single
`BatchFile`. Do not silently flatten it into one Safe transaction.

A compatibility fixture must record the exact writer/importer commit, package
version where present, resolved encoder dependencies, file version, metadata,
encoded or decoded representation, Safe contract version, chain and MultiSend
address. Capture both the exported bytes and the actual outer SafeTx produced by
the selected consumer. Pin toolchain and dependency versions when regenerating it.

Test each profile with a direct single call, a forced single-call MultiSend,
multiple calls, native value, absent/null/empty calldata, Safe-address aliases,
and changed chain/nonce/gas bindings. For decoded profiles add positional input
names, tuples, arrays, booleans, signed and unsigned integer limits and integers
above JavaScript's safe numeric range. Compare outputs from both referenced
encoders on their supported overlap. Treat differences as explicit profile
boundaries. Unknown profiles should require an explicit selection or fail once
profile gating is implemented; today's shape detection does not provide that gate.

### Binding fix included with this proposal

[Issue #43](https://github.com/crossecute/forge-attest/issues/43) records that an
ether.fi-shaped batch was detected but its `safeAddress` was ignored. The separate
fix commit reads `safe`, `safeAddress` and `meta.createdFromSafeAddress`, rejects
disagreement between declarations or configuration, and covers the alias in both
independent derivations. This fixes one verified producer variant. It does not
certify all Transaction Builder releases. Existing valid fixtures retain their
pinned hashes; contradictory declarations now fail.

## Proposed readers

### 1. `safe-eip712`: full SafeTx typed data

Read `{ types, primaryType, domain, message }` with `primaryType = "SafeTx"`.
Take `safe` from `domain.verifyingContract`, chain ID from `domain.chainId`, and
all ten signed fields from `message`. Require a complete message, including data;
do not complete a partial signed transaction from config. Safe version must be
supplied separately when needed because this domain does not encode it.

Validate the SafeTx field names, order and types against the exact supported
Safe schema. Validate the domain definition when present. Some [safe-utils typed
data][safe-utils] omits the explicit `types.EIP712Domain`; support that only as a
named, tested profile using the fixed two-field domain. Reject extra domain
fields, another primary type, incompatible schemas and Safe < 1.3.0. Every
producer binding must agree with the claim. Preserve uint256 values exactly.

The outer `message.to`, `value`, `data` and `operation` are already the transaction
to sign. Do not unpack and refold a MultiSend or Multicall3 payload, replace its
target, or apply batch defaults. A delegatecall into Base's multicall remains
that exact delegatecall.

Base's console output is hex bytes that can contain JSON. A reader for a JSON
file does not also solve marker extraction, multiple nested-Safe messages or event
selection. First require the producer to write the full typed-data artifact.
If console/event capture is later added, pin its emitter, selector and occurrence
and retain the original captured bytes. A `0x1901` preimage containing only hashes
cannot be decoded back to the transaction fields.

### 2. `safe-service`: exported proposal request

Read the outer signed fields of an exported service request, not a live response
used as the producer artifact. The service URL is transport context and must not
silently become the chain binding. Require chain ID from the claim when absent.
Reconcile a declared Safe with the claim; require a claim Safe when absent.

Define profiles from source, not a general permission to omit fields:

- forge-safe/Euler: signed gas fields and Safe are present; chain ID is absent.
- safe-utils at the pinned source: Safe and chain are absent; gas token and refund
  receiver are omitted and fixed to zero by that producer's hashing path. Only
  this named profile may supply those two zero defaults.

Require all other signed fields. Never fetch a nonce, infer the next free nonce,
or substitute the currently queued transaction. If `contractTransactionHash`
or `safeTxHash` is carried, compare it with both independent local derivations
and the claim pin. Conflicting hash aliases fail. Sender, signature and origin
remain source metadata; importing them does not prove ownership or authorize
signing. Keep source-byte and canonical pins separate because signatures or
transport metadata can vary without changing the signed SafeTx.

This shares the existing SafeTx validation model without relaxing the current
strict `safe-tx` reader. Use one shared validation helper within each language;
keep the shell and Solidity derivations independent.

### 3. Decoded Transaction Builder entries

Extend `tx-builder` through a named decoded profile, rather than adding an
EthStrat-only format. Build calldata from the complete `contractMethod` descriptor
and `contractInputsValues`; the descriptor supplies the ABI fragment. A downloaded
contract ABI is not inherently required. Use the actual importer/encoder behavior
for the selected version profile, including unnamed inputs and tuple components.

If both nonempty encoded data and a descriptor are provided, encode and compare
them, rejecting disagreement. Null data with a valid descriptor is a decoded
call; null data without one may still be a plain native transfer. Unsupported
parameter types and malformed or missing arguments must fail explicitly.

Implement independent encoders and fixtures before enabling this. A shared
preprocessing step that feeds the same generated calldata into both hash
implementations would not independently check descriptor encoding. A smaller
initial type subset is acceptable if it is declared and all other types fail.
Keep the existing rejection until that independent coverage exists.

## Deferred integrations

| Candidate | Required work before support |
|---|---|
| Raw calldata text, including prebuilt MultiSend | Prefer a producer-written `call` today. A future `calldata` reader must explicitly bind target, value, operation, Safe, nonce, chain and gas fields. Distinguish packed inner transactions from complete `multiSend(bytes)` calldata; never guess which one a file contains. |
| Base/Optimism simulation or validation bundles | Capture complete payloads and match each to its Safe and nonce. Compare reported domain/message hashes against locally reconstructed fields. Keep state-diff policy, task-origin signatures and sibling/nested approvals distinct from transaction provenance. |
| Zeus traces | Pin the Forge trace schema, script/emitter identity and event; select successful direct script calls in order without counting internal calls twice. Pin protocol-kit and reproduce its batching, operation and nonce choices offline. The inspected [Zeus API strategy][zeus-api] calls `createTransaction` without an explicit nonce; its resolved protocol-kit nonce behavior is not verified here. |
| ABI-encoded pkxp bundle | Pin the producer structs and decode the exact `batch`/`payloads` schema; compare duplicate representations and preserve the supplied MultiSend target. Do not treat ABI bytes as a generic call list. |
| Pantos signed transaction arrays | Add explicit per-execution Safe/nonce bindings and separate claims. Its `from` is the Safe and its consumer uses live `safe.nonce()`. Folding the array as one batch would change what executes. |
| Safe library backup export | Select a batch explicitly, preserve its boundaries and bind it through a separate claim. A library backup is not one transaction. |

Timelock schedule, execute and cancel are ordinary outer calls. Keep their actual
target and calldata, including salts, predecessors and delays. Multiple output
files can already use runs/claims. Do not invent a timelock format or concatenate
separate Safe transactions merely because they were generated together.

## Implementation and acceptance plan

Land format additions as separate changes in the order above. Each must update
`lib/normalize.sh`, `test/SafeTx.sol`, config validation in `lib/claims.sh` where
needed, `attest.sh` cross-check plumbing, both test suites, fixture provenance,
README format/config guidance and affected producer skills. The Solidity
cross-check currently auto-detects through `readAny`; a named profile must reach
it as well as the shell reader. Do not allow an explicit shell format selection
to disagree with Solidity's interpretation.

Every addition needs a source-derived positive fixture and malformed/mismatch
cases in a shared table or parameterized suite. Assert the same pinned
canonical bytes and SafeTx hash for equivalent representations. Retain all old
fixture pins. Exercise normal attestation and the `--attest` preview/signing
input with the new representation, including nested approvals and several claims.
Signing must still use only the independently attested canonical transaction.

Reproduction must remain non-signing and non-submitting. The current runner
tracks files written during the reviewed setup/run, so a checked-in export or a
separate service fetch is insufficient. For libraries that construct requests
only in memory, add a producer-side deterministic export hook. Trace or console
capture needs explicit runner support and original-byte provenance; redirecting
arbitrary old logs into a JSON file does not establish script provenance.

New input envelopes add off-chain parsing and fixture storage costs; they do not
change the SafeTx wire format or on-chain execution cost when the canonical
transaction is identical. A decoded descriptor or trace is variable-size because
it carries ABI values or execution records: bound file size, call count, nesting
and decoded lengths in each implementation. Keep original bytes for the source
hash and avoid floating-point parsing or truncation of large integers.

Before publishing support, run the Solidity and shell suites and compare the
version-profile fixtures against the pinned upstream consumers. This proposal's
upstream compatibility conclusions are source-level only; those consumer runs,
Zeus protocol-kit behavior and historical Frax dependency provenance remain
unverified.

## Pinned sources

[research]: https://github.com/crossecute/research/blob/2e3b132bdde3ba4e44df08b1e2f6deac81af48ff/research/foundry-msig-proposal-research.md
[base]: https://github.com/base/contracts/blob/eaa7729b0a23cfe7570386e3a1c4ebefa8212c41/scripts/universal/MultisigScript.sol
[op]: https://github.com/ethereum-optimism/superchain-ops/blob/586217bca0fe5ef61b643954ef118ff7eaaa0b8c/src/tasks/MultisigTask.sol
[op-hashes]: https://github.com/ethereum-optimism/superchain-ops/blob/586217bca0fe5ef61b643954ef118ff7eaaa0b8c/src/libraries/GnosisSafeHashes.sol
[validation]: https://github.com/base/task-signing-tool/blob/e18a2b0a9b1d0e1d70d52d123180a8c9be6f4226/src/lib/types/validation-data.ts
[forge-safe]: https://github.com/ind-igo/forge-safe/blob/c4845beebc6653d545a1023643b5be1d9d99369d/src/BatchScript.sol
[safe-utils]: https://github.com/Recon-Fuzz/safe-utils/blob/637e04202bb9bb879803f6b42137e2d5d035fbe0/src/Safe.sol
[euler]: https://github.com/euler-xyz/evk-periphery/blob/dd93a5f518ec0775f1cb87d358fe24b9fb5fbb66/script/utils/SafeUtils.s.sol
[lend]: https://github.com/lendxyz/lend-contracts/blob/ba2922e40b6f890cf5bf6af88946084294351085/script/common/LendMultisig.s.sol
[etherfi]: https://github.com/etherfi-protocol/smart-contracts/blob/15ff96d4d5e8e6a19a472cd40a7bcb858c9e7a88/script/utils/utils.sol
[royco]: https://github.com/roycoprotocol/royco-dawn/blob/d68947a1c52bf52b26455f7202f8b67b2494cc4b/script/update/base/ParameterUpdateBase.sol
[boundless]: https://github.com/boundless-xyz/boundless/blob/54b801486fbcb6efdef3e1c6a9381d3211282c0b/contracts/scripts/write_safe_batch.py
[ethstrat]: https://github.com/ethstrat/contracts/blob/e5a725c182aab8b3f34e58810a636948d85ed565/script/lib/SafeBatchLib.sol
[signals]: https://github.com/signals-protocol/v1-contract/blob/3bfe019fa6948ced506630fb32a95aae118fb9fa/script/actions/PrepareSafeUpgrade.s.sol
[agglayer]: https://github.com/agglayer/agglayer-contracts/blob/110bda5a03e70ee7331bc06407a8e79226d3e520/script/forge/obsolete-rollup-type/ObsoleteRollupType.s.sol
[arcadia]: https://github.com/arcadia-finance/safe-signer/blob/d4530f93a954a0ccd686e74ef0b8d79e89ad72f2/transaction_builder/script/utils/SafeTransactionBuilder.sol
[pkxp]: https://github.com/panukettu/pkxp-forge-safe/blob/57bc931893dbef84e9fe5248627451efb0cdb208/src/SafeScript.s.sol
[pantos]: https://github.com/pantos-io/ethereum-contracts/blob/597893976955cbe8882287be7d4b2e2bf54a5537/script/SubmitSafeTxs.s.sol
[frax]: https://github.com/FraxFinance/frax-standard-solidity/blob/dba7c2981202e9e1664ab109478dfe553f90e1e6/src/SafeTxHelper.sol
[zeus-api]: https://github.com/Layr-Labs/zeus/blob/8c9569d69463340dff4a7dd07ed54276febffa71/src/signing/strategies/gnosis/api/gnosisApi.ts
[library]: https://github.com/safe-global/safe-wallet-monorepo/blob/71373370acd419db94100d1351207c2f0806535d/apps/tx-builder/src/lib/batches/index.ts
[legacy-package]: https://github.com/safe-global/safe-react-apps/blob/e8cccfb9a1042fa2954087988bae59c3b8c81780/apps/tx-builder/package.json
[legacy-models]: https://github.com/safe-global/safe-react-apps/blob/e8cccfb9a1042fa2954087988bae59c3b8c81780/apps/tx-builder/src/typings/models.ts
[legacy-encoder]: https://github.com/safe-global/safe-react-apps/blob/e8cccfb9a1042fa2954087988bae59c3b8c81780/apps/tx-builder/src/utils.ts
[legacy-import]: https://github.com/safe-global/safe-react-apps/blob/e8cccfb9a1042fa2954087988bae59c3b8c81780/apps/tx-builder/src/store/transactionLibraryContext.tsx
[wallet-package]: https://github.com/safe-global/safe-wallet-monorepo/blob/71373370acd419db94100d1351207c2f0806535d/apps/tx-builder/package.json
[wallet-models]: https://github.com/safe-global/safe-wallet-monorepo/blob/71373370acd419db94100d1351207c2f0806535d/apps/tx-builder/src/typings/models.ts
[wallet-encoder]: https://github.com/safe-global/safe-wallet-monorepo/blob/71373370acd419db94100d1351207c2f0806535d/apps/tx-builder/src/utils.ts
[wallet-import]: https://github.com/safe-global/safe-wallet-monorepo/blob/71373370acd419db94100d1351207c2f0806535d/apps/tx-builder/src/store/transactionLibraryContext.tsx
