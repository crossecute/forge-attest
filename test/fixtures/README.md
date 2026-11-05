# Test fixtures

Every JSON shape `forge-attest` accepts, pinned as a file so the hash derivations
have something stable to be tested against. `test/SafeTxHash.t.sol` reads these
from Solidity and `test/shell/run.sh` from bash; both assert the same hashes.

| File | Format | What it covers |
|------|--------|----------------|
| `safe-tx-single.json` | `safe-tx` | A flat, complete EIP-712 SafeTx. The output of [`forge-attest-example-safe-ops`](https://github.com/crossecute/forge-attest-example-safe-ops) at commit `df1d6f36`. |
| `call.json` | `call` | The call inside `safe-tx-single.json` with no Safe, nonce or chain. Bound to that file's values by config, it must hash to the same pinned value. |
| `tx-builder-frax-optimism.json` | `tx-builder` | A real six-transaction batch (see provenance below). The main worked example. |
| `tx-builder-frax-optimism-restamped.json` | `tx-builder` | The *same* batch with a different `createdAt` and `meta`, reordered keys, lowercased addresses, uppercased hex, and numbers where the original had quoted strings. Must normalise to identical bytes. |
| `tx-builder-single.json` | `tx-builder` | A one-transaction batch with `"data": null`, a plain ETH transfer. Exercises the "do not wrap a single transaction" path. |
| `tx-builder-self-binding.json` | `tx-builder` | A batch that names its own Safe via `meta.createdFromSafeAddress`, so no `--safe` is needed. Also covers a config Safe that contradicts the file. |
| `tx-builder-zksync-era.json` | `tx-builder` | The Frax batch re-pointed at chain 324, where the canonical MultiSendCallOnly is not what Safe{Wallet} uses. Must be **refused** unless `multisend_address` is named. |
| `tx-array.json` | `tx-array` | A bare array with no envelope, so `chainId` has to come from config. |
| `tx-builder-contract-method.json` | `tx-builder` | A UI export describing a call as `contractMethod` + inputs with null `data`. Must be **rejected**, because encoding it needs the target ABI. |
| `tx-builder-delegatecall.json` | `tx-builder` | A batch with an inner `operation: 1`. Must be **rejected** under MultiSendCallOnly and accepted with an explicit `--multisend`. |

## Provenance of `tx-builder-frax-optimism.json`

Copied verbatim from FraxFinance's `frax-oft-upgradeable`:

- **File:** `scripts/ops/V110/destinations/txs/UpgradeV110Destination-10.json`
- **Repo:** https://github.com/FraxFinance/frax-oft-upgradeable
- **Produced by:** [`SafeTxHelper.writeTxs`](https://github.com/FraxFinance/frax-standard-solidity/blob/master/src/SafeTxHelper.sol)
  in `frax-standard-solidity`
- **Fetched:** 2026-07-28

It is six `upgradeAndCall` calls to a proxy admin on Optimism (chain 10), and is
the reference for what a real `SafeTxHelper` artifact looks like: a `createdAt`
wall-clock stamp, `meta`, `value`/`operation` as quoted strings, and no Safe
address, nonce or gas fields anywhere. Those are exactly the facts an attestation
config has to supply.

## Typed-data fixtures

`safe-eip712.json` maps `safe-tx-single.json` into the complete typed-data
schema constructed by [Base](https://github.com/base/contracts/blob/eaa7729b0a23cfe7570386e3a1c4ebefa8212c41/scripts/universal/MultisigScript.sol#L807-L839).
`safe-eip712-safe-utils.json` removes only `types.EIP712Domain`, following the
[pinned safe-utils writer](https://github.com/Recon-Fuzz/safe-utils/blob/637e04202bb9bb879803f6b42137e2d5d035fbe0/src/Safe.sol).
Both are synthetic representations of the existing pinned transaction, not
production exports. Their identical canonical hash is pinned independently in
`Eip712Reader.t.sol`; the shell suite also checks byte equality with the original.

`safe-eip712-numeric.json` is the same typed transaction with numeric JSON
chain/uint fields, matching the integer-literal representation emitted by Foundry
serializers. Its canonical bytes and hash must equal the quoted fixture in both
readers. The uint256-max test retains quoted strings; the shell continues to
reject numeric literals above its exact-integer range.

## Service request fixtures

`safe-service.json` is synthetic: the signed fields of `safe-tx-single.json` with
request metadata, the pinned hash, and no chain/version, following the pinned
[forge-safe](https://github.com/ind-igo/forge-safe/blob/c4845beebc6653d545a1023643b5be1d9d99369d/src/BatchScript.sol#L265-L284)
and [Euler](https://github.com/euler-xyz/evk-periphery/blob/dd93a5f518ec0775f1cb87d358fe24b9fb5fbb66/script/utils/SafeUtils.s.sol#L453-L470)
request shapes. `safe-service-safe-utils.json` additionally omits the Safe and
zero gas/refund addresses, matching the pinned
[safe-utils writer](https://github.com/Recon-Fuzz/safe-utils/blob/637e04202bb9bb879803f6b42137e2d5d035fbe0/src/Safe.sol#L691-L702).
These are not production proposals or real signatures. Both must reproduce the
existing pinned hash with the correct claim bindings. Negative mutations retain
valid chain/Safe bindings so a missing binding cannot mask a hash/schema bug.
