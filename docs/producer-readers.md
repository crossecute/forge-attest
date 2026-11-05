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
