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
| `tx-builder-contract-method.json` | `tx-builder` | A UI export describing a call as `contractMethod` + inputs with null `data`. Must be **rejected** by the ordinary reader; descriptor encoding requires the explicit static-v1 profile. |
| `nested-preimage-parent.json` | canonical `SafeTx` | The Aave v4 Risk Council transaction at Safe nonce 447 (`0x47c7…0fA8`, Ethereum, executed in block 26337526, `safeTxHash` `0x0ea9a8fe…8e4`) in `forge-attest`'s canonical form. |
| `nested-preimage-child-205.hex` | calldata | The calldata of the approval Safe `0xb291…Afef` executed at its nonce 205 for that transaction, from the Safe Transaction Service on 2026-11-06 (`safeTxHash` `0xcce0f737…07cb`). No trailing newline. `child_approval = "preimage-suffix"` must rebuild it exactly. |
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

## Decoded builder fixtures

`tx-builder-decoded.json` is a synthetic decoded representation of the existing
pinned transfer. It follows [EthStrat's writer](https://github.com/ethstrat/contracts/blob/e5a725c182aab8b3f34e58810a636948d85ed565/script/lib/SafeBatchLib.sol),
including `internalType` and the producer-reported `txBuilderVersion = "2.0.1"`.
That metadata is not an app version compatibility guarantee.

`tx-builder-static-vectors.json` extends that envelope with synthetic `transfer`,
`configure`, unnamed-input and zero-argument calls to cover all four scalar types,
both booleans and uint8/uint256 boundary values. No claim is made that the target
implements these synthetic functions; the tests check serialization without
executing them. `tx-builder-static-encoded.json` records the corresponding ABI
bytes, initially generated with cast and then matched against the original
Transaction Builder 1.18.3 and 2.1.0 encoder helpers. Their multi-call hash is pinned
in `DecodedReader.t.sol`; [compatibility instructions](../../docs/producer-readers.md#version-evidence-and-reproduction)
identify the exact source commits, package versions and tested scope. The fixture
is not a production Safe proposal or an assertion of whole-app compatibility.

## ether.fi binding variant

`tx-builder-etherfi-binding.json` is synthetic, not copied from a production
proposal. Its envelope follows [`Utils.generateSafeJson`](https://github.com/etherfi-protocol/smart-contracts/blob/15ff96d4d5e8e6a19a472cd40a7bcb858c9e7a88/script/utils/utils.sol#L735-L798).
The transaction list is reused from `tx-builder-self-binding.json` so the pinned
hash stays the same. The writer hard-codes `meta.txBuilderVersion = "1.16.5"`;
that string does not establish compatibility with that app release. The fixture
has no top-level `version`, matching this writer.

## Zeus traces fixture

`zeus-traces.json` is the output of `forge script --sig 'execute()' -vvvv --json`
for eigenx-contracts' `2-acceptAdminAndSetLimits.s.sol` at `f0d751f`, forge 1.8.1,
on a fork of Ethereum block 23443614. Only the fields the reader uses were kept
(`success`, `raw_logs`, and per trace `parent`, `children`, `idx`, `depth`,
`success`, `caller`, `address`, `kind`, `value`, `data`, `status`), and the
script's creation bytecode was blanked, so forge itself would print more. The calls
are the four of Safe `0x684c…9e09`'s executed nonce 0 transaction, whose hash
`0x9e338be3…` both suites pin. The environment values the script read were taken
from that transaction. Mutations in `readers-zeus.sh` and `ZeusReader.t.sol` edit
this file, so each keeps a valid event and Safe.
