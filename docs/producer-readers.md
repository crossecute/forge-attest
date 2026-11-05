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
