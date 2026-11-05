# Producer readers

## Safe EIP-712 typed data

`input_format = "safe-eip712"` reads a complete `{types, primaryType, domain,
message}` envelope. Auto-detection recognizes those envelope keys too, including
malformed envelopes, which then fail schema validation. `input_profile` selects
a schema variant and is passed to both independent readers. It may also be set
in `[run.defaults]`; an explicit empty claim value clears the default.

```toml
input_format = "safe-eip712"
input_profile = "safe"
safe_version = "1.3.0"
```

The default/`safe` profile requires `types.EIP712Domain` in this exact order:
`chainId: uint256`, `verifyingContract: address`. `types.SafeTx` must carry all ten
[standard signed fields](../lib/safe-tx-types.json) in order, and `primaryType`
must be `SafeTx`. Extra or missing domain/message/type fields fail. The domain's
verifying contract is the Safe, not the transaction target. Domain names,
versions, salts, and Safe domains before 1.3.0 are unsupported.

`input_profile = "safe-utils"` additionally permits the missing explicit domain
type found in [Recon-Fuzz safe-utils](https://github.com/Recon-Fuzz/safe-utils/blob/637e04202bb9bb879803f6b42137e2d5d035fbe0/src/Safe.sol).
It still derives the fixed two-field Safe domain. This opt-in does not permit a
different declared domain or any missing signed field. The full profile follows
[Base's typed-data constructor](https://github.com/base/contracts/blob/eaa7729b0a23cfe7570386e3a1c4ebefa8212c41/scripts/universal/MultisigScript.sol#L807-L839).

The reader preserves the outer target, value, data and operation. Already-built
MultiSend or Multicall3 calldata is not unpacked or wrapped again, even when
`batch_mode` is set. The message nonce and gas/refund fields cannot be filled in
from configuration. Supplied claim values must agree, including explicitly
supplied zero values. Safe version comes from the claim, defaulting to 1.3.0;
this Safe domain does not encode a version.

Signed calldata must be a non-null `0x` hex string with complete bytes. Use
canonical decimal strings for integers, especially values above
`9007199254740991`; larger JSON numbers are refused before jq can round them into
a reviewed transaction. Values must fit uint256, operations must be 0 or 1,
and Safe and chain must be nonzero. Input size is limited to 1 MiB. These limits
apply to the new reader, not legacy batch file sizes.

The producer must write the full JSON envelope during the reviewed run. Base's
printed hex bytes, console markers, `DataToSign` event, hash-only `0x1901` data,
and task validation wrappers need separate capture/extraction support. A checked-in
export does not satisfy output provenance. No producer export hook or live
service request is run by this reader.

The canonical SafeTx and verdict schemas are unchanged. Equivalent typed and flat
transactions retain identical canonical bytes and hashes, with no on-chain data
or gas-cost change. The extra schema exists only in the off-chain source file.
The shell validates against the same type definitions used for signing; Solidity
validates the raw source independently with its own type definitions and hashes.

Run `forge test` and `bash test/shell/readers.sh` for unit, rejection,
cross-derivation, reproduction, signing preview and test-key signing checks.
`./test/shell/run.sh` includes the reader checks alongside the existing regression
suite. The signing tests use a stub service and never send a real proposal.

## Exported Safe service requests

`input_format = "safe-service"` reads a producer-written proposal request.
Auto-detection also recognizes `contractTransactionHash` or `safeTxHash` keys;
malformed carried hashes fail. This reader never obtains the producer artifact
from the live service, chooses the next nonce, signs, or submits anything.

```toml
input_format = "safe-service"
input_profile = "safe"
chain_id = "1"
```

The default/`safe` profile requires a Safe address and every signed field,
including both gas/refund addresses. The chain may come from the claim when
absent. This matches exported request bodies built by
[forge-safe](https://github.com/ind-igo/forge-safe/blob/c4845beebc6653d545a1023643b5be1d9d99369d/src/BatchScript.sol#L265-L284)
and [Euler](https://github.com/euler-xyz/evk-periphery/blob/dd93a5f518ec0775f1cb87d358fe24b9fb5fbb66/script/utils/SafeUtils.s.sol#L453-L470).
These source references establish the request shape, not a ready-to-run producer
integration for every downstream fork.

`input_profile = "safe-utils"` permits the omitted Safe, gas token and refund
receiver in the [pinned safe-utils request writer](https://github.com/Recon-Fuzz/safe-utils/blob/637e04202bb9bb879803f6b42137e2d5d035fbe0/src/Safe.sol#L691-L702).
The Safe and chain must then come from the claim. Only this profile supplies the
two omitted zero addresses, and all gas/refund fields must be zero, matching that
writer. A missing nonce, calldata, value, operation or numeric gas field is an
error; claim values cannot complete those fields. Explicit null is not omission.

Only signed fields, `safe`, `chainId`, `sender`, `signature`,
`origin` and the two hash aliases are accepted at the root. Live response fields
such as `executionDate` are refused. Every carried hash must be a complete
32-byte hex string and equal the independently derived transaction hash; both
aliases must agree. Missing hash aliases are allowed only when the format is
selected explicitly. Metadata cannot establish ownership or authorize signing.
Changing a signature/origin may change the raw source pin but not the canonical
transaction. The Safe and chain are reconciled with the claim when supplied. Safe contract
version comes only from the claim (default 1.3.0); request-level `safeVersion`
is not part of these producer schemas and is refused. Numeric and file-size limits are the same as for typed data.

The source must still be written during the reviewed producer run. Libraries
that build a request only in memory need a deterministic export hook; this reader
does not enable FFI, bypass their broadcast guards, or run a signing path to
extract a request. It preserves already-built outer MultiSend calldata and never
folds the request as a batch. Canonical bytes, wire format and execution cost
remain the same as for an equivalent flat SafeTx. `derive.sh -` is the shared
cast derivation used to check metadata hashes from canonical JSON on stdin.

## Decoded Transaction Builder calls

Enable the decoded reader through the existing batch format and an explicit
profile. `input_format = "auto"` also works when `input_profile` is supplied;
`input_format = "tx-builder-decoded"` is an explicit alias for the same reader.
Without this profile the existing batch reader still refuses null calldata with
a method descriptor.

```toml
input_format = "tx-builder"
input_profile = "static-v1"
safe_address = "0x111CEEee040739fD91D29C34C33E6B3E112F2177"
safe_nonce = "42"
```

`static-v1` accepts file `version = "1.0"`, encoded calls or native transfers,
and method descriptors with scalar `address`, `bool`, `uint8` and `uint256`
inputs. These are the types used by the pinned
[EthStrat writer](https://github.com/ethstrat/contracts/blob/e5a725c182aab8b3f34e58810a636948d85ed565/script/lib/SafeBatchLib.sol).
`contractMethod` must provide `name`, `inputs` and boolean `payable`.
`contractInputsValues` maps names to strings; unnamed inputs use their decimal
position (`"0"`, `"1"`). Missing, extra and ambiguous input names fail.
Zero-argument calls permit an empty, omitted or null values object. Nonempty input
values without a method are refused. Missing/null method metadata with empty/missing/null calldata remains valid
for a plain native transfer.

Use exact decimal integer strings within uint8/uint256 bounds, `true` or `false`
for booleans, and complete 20-byte hex addresses. Hex/signed/whitespace integer
spellings, alternate boolean spellings, tuples, arrays, dynamic bytes/strings,
other widths/types and tuple components are unsupported. Re-export with encoded
calldata and use the ordinary batch reader for those cases. The profile supports
CALL only, and value to a nonpayable method fails.

If a descriptor and a nonempty calldata string are both present, both must encode
the same bytes. In particular `data = "0x"` is a supplied empty call, not a request
to ignore it and use the descriptor. Null, omitted or empty-string data requests
encoding. The shell uses `cast calldata`; Solidity independently derives the
selector and ABI words from the raw producer descriptor. A single generated
calldata file is not shared between the derivations.

The ordinary batch rules still select a direct single call or MultiSend, with
Safe/nonce/chain/gas bindings and `batch_mode` overrides. The root envelope accepts
only `version`, `chainId`, `createdAt`, `meta` and `transactions`. A Safe declared
in `meta.createdFromSafeAddress` must be a nonempty valid address and agree with
the claim; otherwise supply the Safe in the claim. The profile is bounded to
1 MiB of source JSON, 128 calls, 32 inputs per method, and 64 characters per
function name. Static arguments add one 32-byte ABI word each, so a decoded method
is at most 1028 calldata bytes under this profile. Source descriptors vary in
size because they carry the parameter names, types and values. Equivalent decoded
and encoded calls have identical canonical bytes, on-chain calldata and gas cost.

### Version evidence and reproduction

File `version`, app package version, and `meta.txBuilderVersion` are distinct.
EthStrat's custom writer reports `2.0.1` in metadata; that is not evidence that
an app package at that version produced the file. Metadata never selects the
profile automatically, and `static-v1` does not certify arbitrary exports from
any package release.

The four vectors in `tx-builder-static-vectors.json` were compared with the
original field parsers and `encodeToHexData` helpers from both pinned packages:

| Reference package | Pinned source | Encoder dependencies exercised | Result |
|---|---|---|---|
| Transaction Builder 1.18.3 | [safe-react-apps](https://github.com/safe-global/safe-react-apps/tree/e8cccfb9a1042fa2954087988bae59c3b8c81780/apps/tx-builder) | web3-eth-abi 1.8.1, web3-utils 1.8.1, @ethersproject/abi 5.7.0 | All four vectors match |
| Transaction Builder 2.1.0 | [safe-wallet-monorepo](https://github.com/safe-global/safe-wallet-monorepo/tree/71373370acd419db94100d1351207c2f0806535d/apps/tx-builder) | ethers 6.17.0 | All four vectors match |

The source interfaces match but the encoders and integer parsers differ. The
verified vectors cover all four supported types, uint8/uint256 maxima, an integer
above JavaScript's exact numeric range, unnamed inputs, both booleans and a
zero-argument call. The comparison runs the pinned encoder helpers, not the full
UI, SDK transaction assembly, historical complete dependency tree, or every
possible input. Normal tests independently compare the captured encoded fixture
with the shell and Solidity implementations, including forced MultiSend, gas
bindings, mixed claim profiles and nested approvals.

The optional [compatibility test](../test/compat/tx-builder-encoders.cjs) fetches
only pinned source helpers, verifies package versions and compares the fixtures.
With Node 24 and npm available, run it separately from the normal offline suite:

```sh
npm install --prefix /tmp/forge-attest-encoders --ignore-scripts --no-audit --no-fund \
  ethers@6.17.0 web3-eth-abi@1.8.1 web3-utils@1.8.1 @ethersproject/abi@5.7.0
NODE_PATH=/tmp/forge-attest-encoders/node_modules node test/compat/tx-builder-encoders.cjs
```

The test asserts the ABI module actually resolved by web3-eth-abi is 5.7.0, as in
the pinned legacy lockfile. Its pinned top-level encoder versions and captured
fixtures do not claim that every transitive dependency of the historical app has
been rebuilt. Running the ordinary regression suite needs no Node dependencies
or additional source downloads.

## Zeus traces

`input_format = "zeus-traces"` reads the calls of a script built on Zeus's
[`MultisigBuilder`](https://github.com/Layr-Labs/zeus-templates/blob/b4c42abc64bb7cc414819deb177fa2f924a761a7/src/templates/MultisigBuilder.sol).
Such a script writes no file. It emits `ZeusRequireMultisig(address, uint8)` and
makes its calls under `vm.startPrank(multisig)`. The Zeus CLI runs
`forge script <path> --sig 'execute()' --rpc-url <rpc> -vvvv --json`, reads the
Safe and call type from that event and the calls from the traces, batches them
with Safe protocol-kit and proposes the result. This reader does the same from
the run's own stdout, so the output file is replaced by the run.

```toml
producer_repo   = "https://github.com/Layr-Labs/eigenx-contracts"
producer_commit = "f0d751f5c9bc3f7fb42c02646f67e31dbc577467"
producer_setup  = "git submodule update --init --recursive"

[[run]]
script     = "script/releases/v1.0.4-init/2-acceptAdminAndSetLimits.s.sol"
rpc_env    = "MAINNET_RPC_URL"
fork_block = "23443614"

[run.env]
ZEUS_ENV = "mainnet"
ZEUS_ENV_computeOpsMultisig = "0x684cf8978c2815716c85eAa237E311f5a44e9e09"
# ... every ZEUS_ENV_* and ZEUS_DEPLOYED_* value the script reads

[[run.claim]]
output_path       = "zeus/2-acceptAdminAndSetLimits"
input_format      = "zeus-traces"
safe_version      = "1.4.1"
multisend_address = "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"
safe_nonce        = "0"
expected_canonical_sha256 = "<canonical sha256>"
expected_safe_tx_hash     = "0x9e338be37a1756a80652767968a61be506fce16a0cbbec8d7441ff5e7724f478"
```

What the claim and the run must provide:

- `fork_block` and `rpc_env`. The Zeus CLI keeps only calls that succeed, so a call
  that reverts at another block would drop out of the batch without a message. A
  claim without them is refused when the config is read.
- The run's `sig` defaults to `execute()`, and `-vvvv` is added so forge prints
  the traces. Set `sig` for a script with another entry point.
- Zeus injects `ZEUS_ENV_*` and `ZEUS_DEPLOYED_*` values from its environment
  metadata. Put the ones the script reads in `[run.env]`, which the verdict
  records. They decide which contracts the calls go to, so review them like
  calldata.
- `multisend_address`, because several calls are batched through the MultiSend
  that Safe protocol-kit chose. For the executed eigenx transaction that was the
  plain MultiSend of Safe 1.4.1 (`0x38869bf6…`), not MultiSendCallOnly. No default
  is guessed for other versions. `safe_nonce` is the Safe's nonce when the
  transaction was built. `chain_id` defaults to the run's RPC chain, since forge's
  JSON carries none.
- `output_path` only names the claim. Nothing is read from the clone at that
  path, and a script that writes it fails the run. Pin `expected_canonical_sha256`
  and `expected_safe_tx_hash`. The raw output holds gas figures, so
  `expected_output_sha256` is not meaningful here.

The reader takes the Safe and the call type (0 for Call, 1 for DelegateCall, applied
to every inner call) from exactly one `ZeusRequireMultisig` event emitted by the
script. It then walks the entry call's direct children, in order:

- Reads (`STATICCALL`) and calls to the cheatcode address are skipped.
- Every other child must be a successful `CALL` whose caller is the multisig.
  Its target, value and calldata become one batch entry. Values must be within
  JavaScript's exact integer range, because the Zeus CLI converts them through
  a JavaScript number.
- A reverted call, a call made by the script rather than the multisig, a `CREATE`
  or `DELEGATECALL`, a second execution block (a `setUp` trace), a second event,
  or no calls at all fails the run. The Zeus CLI would drop or include these
  without saying so.

Calls made by other contracts during those calls are not batch entries. The
batch then follows the ordinary rules: one call is sent directly, several are
packed into `multiSend(bytes)` and delegatecalled. The canonical SafeTx, verdict
schema and on-chain cost are those of the equivalent `tx-array`.

**Differs from the Zeus CLI on current Foundry.** The CLI keeps calls whose trace
caller is the script contract, working around
[foundry-rs/foundry#10050](https://github.com/foundry-rs/foundry/issues/10050).
Forge 1.8.1 reports the pranked multisig as the caller, so that filter keeps no
calls there. This reader accepts the multisig as caller and rejects a call whose
caller is the script, which pre-fix Foundry could not tell apart. The verdict
records the forge version; pin `expected_forge_version` so the shape of the
traces cannot change under a pin.

The shell reader selects children by `parent`. The Solidity cross-check selects
them from the entry call's `children`, reads the event with its own ABI decoding
and parses values separately. Input is limited to 8 MiB, and the Solidity side
re-parses it for every field it reads, so a trace with many calls makes
`forge test` slow.

Reproduction against the executed eigenx transaction (Safe `0x684c…9e09`, nonce 0,
block 23443615): run the script at `f0d751f` with forge 1.8.1 on a fork of block
23443614, with `ZEUS_ENV_PermissionController`, `ZEUS_ENV_computeOpsMultisig`,
`ZEUS_ENV_computeWhitelisterMultisig`, `ZEUS_ENV_MAX_GLOBAL_ACTIVE_APPS` and
`ZEUS_DEPLOYED_AppController_Proxy` set. Its four calls fold to `safeTxHash`
`0x9e338be3…`, the executed transaction. The environment values were read back from
that transaction, so this shows the traces and batching agree with the chain, not
that those values are right. The public repository starts on 2025-09-29, after the
transaction was executed, so `f0d751f` may differ from the commit it was built
from. [`test/fixtures/zeus-traces.json`](../test/fixtures/zeus-traces.json) is a
trimmed copy of that run's output. Protocol-kit's nonce and MultiSend choices were
checked against this one transaction only.
