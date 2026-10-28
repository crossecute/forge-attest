#!/usr/bin/env bash
#
# propose.sh: sign an attested SafeTx and submit it to the Safe Transaction
#             Service. Proposes it when nothing is queued at its nonce, adds a
#             confirmation when this exact hash is already queued, and refuses
#             when anything else is queued at that nonce.
#
# Usage:  propose.sh --canonical <safe-tx.json> --hash <safeTxHash> --network <name>
#                    [--origin <text>] -- <cast wallet flags, e.g. --ledger>
# Output: KEY=VALUE lines on stdout, human log on stderr:
#           PROPOSE_ACTION=proposed|confirmed|already-confirmed
#           PROPOSE_SENDER=0x...
#
# Env:    SAFE_API_KEY         sent as a Bearer token when set
#         SAFE_TX_SERVICE_URL  service base without `/api`, overriding the one
#                              looked up for --network (self-hosted, tests)
#
# Keys never pass through this script: signing is `cast wallet sign` with the
# caller's wallet flags. The typed data is built from the canonical form and the
# signature is checked against --hash before anything is sent, so cast's EIP-712
# encoder is a third derivation of the same hash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

exec 3>&1 1>&2

canonical="" hash="" network="" origin="forge-attest"
WALLET=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --canonical) canonical="$2"; shift 2 ;;
    --hash)      hash=$(lc "$2"); shift 2 ;;
    --network)   network="$2"; shift 2 ;;
    --origin)    origin="$2"; shift 2 ;;
    --) shift; WALLET=("$@"); break ;;
    *) die "propose.sh: unknown argument: $1" ;;
  esac
done

[[ -f "$canonical" ]] || die "propose.sh: --canonical file not found: $canonical"
[[ "$hash" =~ ^0x[0-9a-f]{64}$ ]] || die "propose.sh: --hash must be a 32-byte hex hash"
[[ -n "$network" ]] || die "propose.sh: --network is required"
(( ${#WALLET[@]} )) || die "propose.sh: pass the signer's cast wallet flags after --, e.g. -- --ledger"
for bin in cast jq curl; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

get() { jq -er "$1" "$canonical"; }
safe=$(cast to-check-sum-address "$(get .safe)")
chain_id=$(get .chainId)
nonce=$(get .nonce)

# The canonical file must still be the one that was attested.
eval "$(bash "$SCRIPT_DIR/derive.sh" "$canonical")"
[[ "$(lc "$SAFE_TX_HASH")" == "$hash" ]] \
  || die "canonical form hashes to $(lc "$SAFE_TX_HASH"), not the attested $hash"

# --- service URL --------------------------------------------------------------
# The network table is read as data from the vendored safe_hashes.sh, so the
# live check and this script resolve a network name to the same service.
map_lookup() { # <array name> <key>
  sed -n -E "/^declare -A -r $1=\(/,/^\)/ s/^[[:space:]]*\[\"$2\"\]=\"(.*)\"$/\1/p" \
    "$SCRIPT_DIR/safe_hashes.sh"
}
if [[ -n "${SAFE_TX_SERVICE_URL:-}" ]]; then
  base="${SAFE_TX_SERVICE_URL%/}"
else
  base=$(map_lookup API_URLS "$network")
  [[ -n "$base" ]] || die "unknown network '$network': not in lib/safe_hashes.sh"
  base=${base/\$\{BASE_URL\}/https://api.safe.global/tx-service}
  net_chain=$(map_lookup CHAIN_IDS "$network")
  [[ "$net_chain" == "$chain_id" ]] \
    || die "network '$network' is chain $net_chain but the transaction is for chain $chain_id"
fi
api="$base/api"

# api <METHOD> <path> [body file] -> response body in $TMP/resp, status on stdout
api() {
  local args=(-sS --max-time 30 -o "$TMP/resp" -w '%{http_code}' -X "$1"
              -H 'accept: application/json')
  [[ -n "${SAFE_API_KEY:-}" ]] && args+=(-H "Authorization: Bearer $SAFE_API_KEY")
  [[ -n "${3:-}" ]] && args+=(-H 'content-type: application/json' --data-binary "@$3")
  curl "${args[@]}" "$api$2" || true
}
expect() { # <status> <allowed...>
  local got="$1"; shift
  for want in "$@"; do [[ "$got" == "$want" ]] && return 0; done
  die "Safe Transaction Service returned HTTP $got: $(head -c 400 "$TMP/resp" 2>/dev/null)"
}

[[ -n "${SAFE_API_KEY:-}" ]] || warn "SAFE_API_KEY is not set: the service may reject or rate-limit requests"
printf '    service  : %s\n' "$base"

# --- signer and Safe state ----------------------------------------------------
sender=$(cast to-check-sum-address "$(cast wallet address "${WALLET[@]}")")
printf '    signer   : %s\n' "$sender"

expect "$(api GET "/v1/safes/$safe/")" 200
safe_nonce=$(jq -er '.nonce | tostring' "$TMP/resp")
jq -e --arg s "${sender,,}" 'any(.owners[]; ascii_downcase == $s)' "$TMP/resp" >/dev/null \
  || die "$sender is not an owner of $safe"
(( nonce >= safe_nonce )) \
  || die "Safe nonce is already $safe_nonce: nonce $nonce has been used"

# A different hash at this nonce is a competing transaction (a replacement, a
# rejection, or a substitution). Its owners decide which one runs, not this tool.
expect "$(api GET "/v2/safes/$safe/multisig-transactions/?nonce=$nonce")" 200
others=$(jq -r --arg h "$hash" '.results[] | .safeTxHash | ascii_downcase | select(. != $h)' "$TMP/resp")
[[ -z "$others" ]] \
  || die "another transaction is already queued at nonce $nonce: $(echo $others)"
queued=$(jq -r --arg h "$hash" '[.results[] | select((.safeTxHash | ascii_downcase) == $h)] | length' "$TMP/resp")

if (( queued )); then
  if jq -e --arg h "$hash" --arg s "${sender,,}" \
       'any(.results[] | select((.safeTxHash | ascii_downcase) == $h) | .confirmations[]?; .owner | ascii_downcase == $s)' \
       "$TMP/resp" >/dev/null; then
    ok "already queued and confirmed by $sender"
    printf 'PROPOSE_ACTION=already-confirmed\nPROPOSE_SENDER=%s\n' "$sender" >&3
    exit 0
  fi
  action=confirmed
else
  action=proposed
fi

# --- sign ---------------------------------------------------------------------
jq '{
  types: {
    EIP712Domain: [ {name: "chainId", type: "uint256"},
                    {name: "verifyingContract", type: "address"} ],
    SafeTx: [ {name: "to", type: "address"}, {name: "value", type: "uint256"},
              {name: "data", type: "bytes"}, {name: "operation", type: "uint8"},
              {name: "safeTxGas", type: "uint256"}, {name: "baseGas", type: "uint256"},
              {name: "gasPrice", type: "uint256"}, {name: "gasToken", type: "address"},
              {name: "refundReceiver", type: "address"}, {name: "nonce", type: "uint256"} ]
  },
  primaryType: "SafeTx",
  domain: { chainId: .chainId, verifyingContract: .safe },
  message: { to, value, data, operation, safeTxGas, baseGas, gasPrice,
             gasToken, refundReceiver, nonce }
}' "$canonical" >"$TMP/typed.json"

step "Sign with your wallet. The device should show:"
printf '    domain   : %s\n' "$DOMAIN_HASH"
printf '    message  : %s\n' "$MESSAGE_HASH"
printf '    safeTx   : %s\n' "$hash"
signature=$(cast wallet sign --data --from-file "$TMP/typed.json" "${WALLET[@]}")
cast wallet verify --address "$sender" --no-hash "$hash" "$signature" >/dev/null 2>&1 \
  || die "signature does not recover to $sender over $hash"
ok "signature recovers to $sender over the attested hash"

# --- submit -------------------------------------------------------------------
if [[ "$action" == proposed ]]; then
  # Field types follow safe-core-sdk's proposeTransaction body: operation and
  # nonce are numbers, amounts are decimal strings, addresses are checksummed.
  jq --arg to "$(cast to-check-sum-address "$(get .to)")" \
     --arg gasToken "$(cast to-check-sum-address "$(get .gasToken)")" \
     --arg refundReceiver "$(cast to-check-sum-address "$(get .refundReceiver)")" \
     --arg hash "$hash" --arg sender "$sender" --arg signature "$signature" \
     --arg origin "$origin" '{
       to: $to, value, data, operation: (.operation | tonumber),
       safeTxGas, baseGas, gasPrice, gasToken: $gasToken,
       refundReceiver: $refundReceiver, nonce: (.nonce | tonumber),
       contractTransactionHash: $hash, sender: $sender,
       signature: $signature, origin: $origin
     }' "$canonical" >"$TMP/body.json"
  expect "$(api POST "/v2/safes/$safe/multisig-transactions/" "$TMP/body.json")" 200 201
  ok "proposed $hash to $safe at nonce $nonce"
else
  jq -n --arg signature "$signature" '{signature: $signature}' >"$TMP/body.json"
  expect "$(api POST "/v1/multisig-transactions/$hash/confirmations/" "$TMP/body.json")" 200 201
  ok "added $sender's confirmation to $hash"
fi

printf 'PROPOSE_ACTION=%s\nPROPOSE_SENDER=%s\n' "$action" "$sender" >&3
