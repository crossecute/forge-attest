#!/usr/bin/env bash
#
# landed.sh: find on chain the transactions a run simulated from its pinned
#            senders, and say whether each landed as simulated.
#
# Usage:  ETH_RPC_URL=<url> landed.sh <txs.json> <fork block>
#
# <txs.json> is the array attest.sh reads from forge's dry-run records:
# [{from, nonce, to, input, value, contract, created: [...]}], hex as forge writes
# it. Prints one JSON object per transaction, with the nonce in decimal, adding
#   state:  landed | pending | differs | failed | unknown
#   block, tx_hash, detail
#
# The transaction at a sender's nonce is found by bisecting the blocks after the
# fork block for the one where the nonce passes it, so the RPC must serve state
# at past blocks. Same sender and nonce, with the same to, input and value, is
# the simulated transaction; its receipt then shows whether it succeeded and
# created the predicted contracts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

TXS="${1:?usage: landed.sh <txs.json> <fork block>}"
FORK_BLOCK="${2:?usage: landed.sh <txs.json> <fork block>}"
[[ -n "${ETH_RPC_URL:-}" ]] || die "ETH_RPC_URL is not set"

rpc() { timeout 30 cast rpc "$@" 2>/dev/null; }
hex() { printf '0x%x' "$1"; }
# A quantity as a decimal, or nothing when the RPC gave something else.
dec() { [[ "$1" =~ ^\"?0x[0-9a-fA-F]{1,16}\"?$ ]] && printf '%d' "$(tr -d '"' <<<"$1")"; }
nonce_at() { dec "$(rpc eth_getTransactionCount "$1" "$2")"; }
code_at() { rpc eth_getCode "$1" "$(hex "$2")" | jq -r .; }

latest=$(dec "$(rpc eth_blockNumber)") || die "could not read the latest block"

# The nonce is written back in decimal, as reports print it.
emit() { # <tx> <state> <block> <hash> <detail>
  jq -c --arg n "$nonce" --arg s "$2" --arg b "$3" --arg h "$4" --arg d "$5" \
    '. + {nonce: $n, state: $s, block: $b, tx_hash: $h, detail: $d}' <<<"$1"
}

while IFS= read -r tx; do
  from=$(jq -r .from <<<"$tx")
  nonce=$(dec "$(jq -r .nonce <<<"$tx")") || die "not a nonce in the record: $(jq -r .nonce <<<"$tx" | printable)"
  live=$(nonce_at "$from" latest) || { emit "$tx" unknown "" "" "could not read the sender's nonce"; continue; }
  if (( live <= nonce )); then
    emit "$tx" pending "" "" "sender's nonce is $live"
    continue
  fi
  lo=$FORK_BLOCK hi=$latest
  n=$(nonce_at "$from" "$(hex "$lo")") \
    || { emit "$tx" unknown "" "" "could not read the sender's nonce at block $lo (archive state needed)"; continue; }
  if (( n > nonce )); then
    # The simulation read the nonce at the fork block, so this means the record
    # is not from that block.
    emit "$tx" differs "" "" "nonce $nonce was already used at fork block $FORK_BLOCK"
    continue
  fi
  while (( hi - lo > 1 )); do
    mid=$(( (lo + hi) / 2 ))
    n=$(nonce_at "$from" "$(hex "$mid")") || break
    if (( n > nonce )); then hi=$mid; else lo=$mid; fi
  done
  (( hi - lo == 1 )) || { emit "$tx" unknown "" "" "could not read the sender's nonce at past blocks"; continue; }

  got=$(rpc eth_getBlockByNumber "$(hex "$hi")" true | jq -c --arg f "${from,,}" --arg n "$(hex "$nonce")" \
    'first(.transactions[] | select((.from | ascii_downcase) == $f and .nonce == $n)) // empty' 2>/dev/null) || got=""
  [[ -n "$got" ]] || { emit "$tx" unknown "$hi" "" "no transaction at that nonce in block $hi"; continue; }
  hash=$(jq -r .hash <<<"$got")

  # Hex quantities compare without leading zeros; to is null for a create.
  diff=$(jq -rn --argjson a "$tx" --argjson b "$got" '
    def q: (. // "0x0") | ascii_downcase | ltrimstr("0x") | sub("^0+"; "");
    def addr: (. // "") | ascii_downcase;
    [ (if ($a.to | addr) != ($b.to | addr) then "to" else empty end),
      (if ($a.input | ascii_downcase) != ($b.input | ascii_downcase) then "input" else empty end),
      (if ($a.value | q) != ($b.value | q) then "value" else empty end) ] | join(", ")')
  if [[ -n "$diff" ]]; then
    emit "$tx" differs "$hi" "$hash" "the transaction at this nonce has a different $diff"
    continue
  fi

  receipt=$(rpc eth_getTransactionReceipt "$hash") || receipt=""
  status=$(jq -r '.status // empty' <<<"$receipt" 2>/dev/null) || status=""
  if [[ "$status" != 0x1 ]]; then
    emit "$tx" "$([[ "$status" == 0x0 ]] && echo failed || echo unknown)" "$hi" "$hash" "receipt status ${status:-unreadable}"
    continue
  fi
  want=$(jq -r '.contract // "" | ascii_downcase' <<<"$tx")
  if [[ -n "$want" && "$(jq -r '.contractAddress // "" | ascii_downcase' <<<"$receipt")" != "$want" ]]; then
    emit "$tx" differs "$hi" "$hash" "it created $(jq -r .contractAddress <<<"$receipt"), not $want"
    continue
  fi
  # A contract a call creates follows the creating contract's nonce, which the
  # input does not fix, so check its code first appears in this block.
  state=landed detail=""
  while IFS= read -r a; do
    before=$(code_at "$a" $((hi - 1))) after=$(code_at "$a" "$hi")
    if [[ -z "$before" || -z "$after" ]]; then
      state=unknown detail="could not read the code at $a"; break
    elif [[ "$before" != 0x || "$after" == 0x ]]; then
      state=differs detail="no code was created at $a in block $hi"; break
    fi
  done < <(jq -r '.created[]' <<<"$tx")
  emit "$tx" "$state" "$hi" "$hash" "$detail"
done < <(jq -c '.[]' "$TXS")
