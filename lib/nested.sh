#!/usr/bin/env bash
#
# nested.sh: build the Safe transaction a *child* Safe sends to approve a
#            transaction on a parent Safe it owns.
#
# A Safe cannot produce an ECDSA signature, so when a Safe owns another Safe it
# approves on-chain instead: it calls `parent.approveHash(h)`, where `h` is the
# parent's EIP-712 transaction hash. That approval is itself a Safe transaction,
# and it is the one the child's owners actually sign.
#
# Nothing about it is a matter of choice. Given the parent Safe, the parent's
# hash, the child Safe and the child's nonce, every field is determined:
#
#     to        = <parent safe>
#     value     = 0
#     data      = 0xd4d9bdcd ‖ <parent hash>      (36 bytes)
#     operation = 0
#     gas fields = 0
#     nonce     = <child nonce>
#
# So this script *constructs* the transaction rather than verifying a file. There
# is no producer artifact for an approval, and inventing one would only add
# something else to tamper with. The output is a canonical SafeTx, so
# `derive.sh` hashes it exactly like any other.
#
# Note what the parent hash does NOT tell the Safe: nothing. `approveHash` stores
# a flag against (owner, hash) and never learns the preimage. At execution the
# full transaction is supplied again and re-hashed. That is why the parent's
# decoded intent has to travel with this. On-chain state can never explain to a
# signer what they approved.
#
# Some child Safes send a longer approval: `approveHash(h)` followed by the parent
# transaction itself, so that their owners can read what they approve. The
# `preimage-suffix` approval profile builds that form:
#
#     data = 0xd4d9bdcd ‖ <parent hash> ‖ 0xfb4e87b0 ‖ abi.encode(Tx[1])
#     Tx   = (uint256 chainId, address safe, uint256 nonce, address to,
#             uint256 value, bytes data, uint8 operation, uint256 safeTxGas,
#             uint256 baseGas, uint256 gasPrice, address gasToken,
#             address refundReceiver)
#
# `approveHash` reads only its first argument, so the extra bytes change nothing
# on chain, but they are a claim about what `h` is. They are rebuilt from the
# parent transaction here, never read from a file, so a suffix that describes a
# different transaction from the one hashed cannot be produced.
#
# Usage:
#   nested.sh --parent-safe 0x… --parent-hash 0x… \
#             --child-safe 0x… --child-nonce N --chain-id N [--safe-version V] \
#             [--approval plain|preimage-suffix --parent-canonical FILE]
set -euo pipefail

PARENT_SAFE=""; PARENT_HASH=""; CHILD_SAFE=""; CHILD_NONCE=""
CHAIN_ID=""; SAFE_VERSION="1.3.0"; APPROVAL="plain"; PARENT_CANONICAL=""

APPROVE_HASH_SELECTOR="d4d9bdcd"
PREIMAGE_SUFFIX_SELECTOR="fb4e87b0"

die() { printf 'nested.sh: %s\n' "$*" >&2; exit 1; }
lower() { printf '%s' "${1,,}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent-safe)  PARENT_SAFE="$2"; shift 2 ;;
    --parent-hash)  PARENT_HASH="$2"; shift 2 ;;
    --child-safe)   CHILD_SAFE="$2"; shift 2 ;;
    --child-nonce)  CHILD_NONCE="$2"; shift 2 ;;
    --chain-id)     CHAIN_ID="$2"; shift 2 ;;
    --safe-version) SAFE_VERSION="$2"; shift 2 ;;
    --approval)     APPROVAL="$2"; shift 2 ;;
    --parent-canonical) PARENT_CANONICAL="$2"; shift 2 ;;
    -h|--help)      grep -E '^#' "$0" | sed -E 's/^#\??//' | sed -E 's/^ //'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

parent_safe=$(lower "$PARENT_SAFE")
child_safe=$(lower "$CHILD_SAFE")
parent_hash=$(lower "$PARENT_HASH")

[[ "$parent_safe" =~ ^0x[0-9a-f]{40}$ ]] || die "--parent-safe must be a 20-byte address"
[[ "$child_safe"  =~ ^0x[0-9a-f]{40}$ ]] || die "--child-safe must be a 20-byte address"
[[ "$parent_hash" =~ ^0x[0-9a-f]{64}$ ]] || die "--parent-hash must be a 32-byte hash"
[[ "$CHILD_NONCE" =~ ^[0-9]+$ ]]         || die "--child-nonce must be a non-negative integer"
# Solidity rejects chainId 0 outright; accepting it here would produce a hash the
# cross-check could never match, and no chain has id 0 anyway.
[[ "$CHAIN_ID"    =~ ^[0-9]+$ ]]         || die "--chain-id must be a positive integer"
(( CHAIN_ID > 0 ))                       || die "--chain-id must be a positive integer"

# A Safe cannot own itself, and `approveHash` would be meaningless if it could.
[[ "$parent_safe" != "$child_safe" ]] || die "--child-safe and --parent-safe are the same Safe"

# uint256 as one 32-byte word, address as one word, bytes as length and padded data.
uint_word() { local h; h=$(cast to-uint256 "$1") || die "not a uint256: $1"; printf '%s' "${h#0x}"; }
addr_word() { printf '%024d%s' 0 "${1#0x}"; }

# abi.encode of the one-element Tx[] above, as hex without 0x.
preimage_body() {
  local f="$1" data hex pad
  data=$(jq -r .data "$f"); hex="${data#0x}"
  [[ "$hex" =~ ^([0-9a-f]{2})*$ ]] || die "parent data is not whole lowercase hex bytes"
  pad=$(( (64 - ${#hex} % 64) % 64 ))
  uint_word 32; uint_word 1; uint_word 32
  uint_word "$(jq -r .chainId "$f")"
  addr_word "$(jq -r .safe "$f")"
  uint_word "$(jq -r .nonce "$f")"
  addr_word "$(jq -r .to "$f")"
  uint_word "$(jq -r .value "$f")"
  uint_word 384                                   # 12 head words: where `data` starts
  uint_word "$(jq -r .operation "$f")"
  uint_word "$(jq -r .safeTxGas "$f")"
  uint_word "$(jq -r .baseGas "$f")"
  uint_word "$(jq -r .gasPrice "$f")"
  addr_word "$(jq -r .gasToken "$f")"
  addr_word "$(jq -r .refundReceiver "$f")"
  uint_word $(( ${#hex} / 2 ))
  printf '%s' "$hex"
  (( pad == 0 )) || printf '%0*d' "$pad" 0
}

approve_data="0x${APPROVE_HASH_SELECTOR}${parent_hash#0x}"
case "$APPROVAL" in
  plain) [[ -z "$PARENT_CANONICAL" ]] || die "--parent-canonical only applies to --approval preimage-suffix" ;;
  preimage-suffix)
    [[ -f "$PARENT_CANONICAL" ]] || die "--approval preimage-suffix needs --parent-canonical FILE"
    # The suffix describes the transaction the hash commits to, so it must be that one.
    [[ "$(jq -r '.safe | ascii_downcase' "$PARENT_CANONICAL")" == "$parent_safe" ]] \
      || die "--parent-canonical is not for --parent-safe"
    [[ "$(jq -r .chainId "$PARENT_CANONICAL")" == "$CHAIN_ID" ]] || die "--parent-canonical is not for --chain-id"
    approve_data+="${PREIMAGE_SUFFIX_SELECTOR}$(preimage_body "$PARENT_CANONICAL")"
    ;;
  *) die "--approval must be plain or preimage-suffix" ;;
esac

jq -n \
  --arg safe "$child_safe" \
  --arg chainId "$CHAIN_ID" \
  --arg safeVersion "$SAFE_VERSION" \
  --arg to "$parent_safe" \
  --arg data "$approve_data" \
  --arg nonce "$CHILD_NONCE" \
  '{safe:$safe, chainId:$chainId, safeVersion:$safeVersion, to:$to, value:"0",
    data:$data, operation:"0", safeTxGas:"0", baseGas:"0", gasPrice:"0",
    gasToken:"0x0000000000000000000000000000000000000000",
    refundReceiver:"0x0000000000000000000000000000000000000000", nonce:$nonce}'
