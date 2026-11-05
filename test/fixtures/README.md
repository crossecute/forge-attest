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
| `tx-builder-etherfi-binding.json` | `tx-builder` | Synthetic batch using the existing self-binding fixture's calls with ether.fi's `chainId`, `safeAddress`, `meta.txBuilderVersion` and `transactions` envelope. Tests absent, agreeing and conflicting config bindings. |
| `tx-builder-zksync-era.json` | `tx-builder` | The Frax batch re-pointed at chain 324, where the canonical MultiSendCallOnly is not what Safe{Wallet} uses. Must be **refused** unless `multisend_address` is named. |
| `tx-array.json` | `tx-array` | A bare array with no envelope, so `chainId` has to come from config. |
| `tx-builder-contract-method.json` | `tx-builder` | A UI export describing a call as `contractMethod` + inputs with null `data`. Must be **rejected**, because descriptor encoding is not implemented. |
| `tx-builder-delegatecall.json` | `tx-builder` | A batch with an inner `operation: 1`. Must be **rejected** under MultiSendCallOnly and accepted with an explicit `--multisend`. |

## Provenance of `tx-builder-frax-optimism.json`

Copied verbatim from FraxFinance's `frax-oft-upgradeable`:

- **File:** `scripts/ops/V110/destinations/txs/UpgradeV110Destination-10.json`
- **Repo:** https://github.com/FraxFinance/frax-oft-upgradeable
- **Verified source snapshot (2026-11-05):** [artifact at `6964529b`](https://github.com/FraxFinance/frax-oft-upgradeable/blob/6964529b29b367d976d62a6df1efbbacb31d3205/scripts/ops/V110/destinations/txs/UpgradeV110Destination-10.json). Its blob hash `447b40acc76f22948b44407016b9e04a8adf77d9` matches this fixture byte-for-byte; this does not identify the historical helper dependency revision.
- **Produced by:** [`SafeTxHelper.writeTxs`](https://github.com/FraxFinance/frax-standard-solidity/blob/master/src/SafeTxHelper.sol)
  in `frax-standard-solidity`
- **Fetched:** 2026-07-28

It is six `upgradeAndCall` calls to a proxy admin on Optimism (chain 10), and is
the reference for what a real `SafeTxHelper` artifact looks like: a `createdAt`
wall-clock stamp, `meta`, `value`/`operation` as quoted strings, and no Safe
address, nonce or gas fields anywhere. Those are exactly the facts an attestation
config has to supply.

## ether.fi binding variant

`tx-builder-etherfi-binding.json` is synthetic, not copied from a production
proposal. Its envelope follows [`Utils.generateSafeJson`](https://github.com/etherfi-protocol/smart-contracts/blob/15ff96d4d5e8e6a19a472cd40a7bcb858c9e7a88/script/utils/utils.sol#L735-L798).
The transaction list is reused from `tx-builder-self-binding.json` so the pinned
hash stays the same. The writer hard-codes `meta.txBuilderVersion = "1.16.5"`;
that string does not establish compatibility with that app release. The fixture
has no top-level `version`, matching this writer.
