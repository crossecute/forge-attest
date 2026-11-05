#!/usr/bin/env bash

BIND_SAFE=0x111CEEee040739fD91D29C34C33E6B3E112F2177
BIND_FIXTURE=tx-builder-entry-bindings.json

# accepts <label> <jq mutation> <fixture> <normalize flags...>
reader_accept() {
  local label="$1" mutation="$2" fixture="$3"; shift 3
  jq "$mutation" "$FIX/$fixture" >"$TMP/positive.json"
  if bash "$NORMALIZE" --input "$TMP/positive.json" "$@" >"$TMP/accepted" 2>"$TMP/error"; then pass "$label"
  else fail "$label: $(cat "$TMP/error")"; fi
}

group "Batch entries that carry SafeTx fields"
reader_cross "$BIND_FIXTURE" tx-builder "" --safe "$BIND_SAFE" --nonce 42
reader_normalize "$BIND_FIXTURE" tx-builder "" "$TMP/entry-bound.json" --safe "$BIND_SAFE" --nonce 42
reader_normalize tx-builder-single.json tx-builder "" "$TMP/entry-plain.json" --safe "$BIND_SAFE" --nonce 42
assert_eq "entry fields at their defaults change nothing" "$(jq -S . "$TMP/entry-bound.json")" "$(jq -S . "$TMP/entry-plain.json")"

while IFS=$'\t' read -r label mutation expect; do
  reader_reject "$label" "$mutation" "$BIND_FIXTURE" tx-builder "" --safe "$BIND_SAFE" --nonce 42
  assert_contains "$label names the field" "$(cat "$TMP/error")" "$expect"
done <<'CASES'
entry safeTxGas differs	.transactions[0].safeTxGas="100"	carries safeTxGas 100
entry baseGas differs	.transactions[0].baseGas=1	carries baseGas 1
entry gasPrice differs	.transactions[0].gasPrice="1"	carries gasPrice 1
entry gasToken differs	.transactions[0].gasToken="0x0000000000000000000000000000000000000001"	carries gasToken
entry refundReceiver differs	.transactions[0].refundReceiver="0x0000000000000000000000000000000000000001"	carries refundReceiver
entry nonce differs from the claim	.transactions[0].nonce=7	carries nonce 7
entry nonce is null	.transactions[0].nonce=null	null nonce
entry gas is null	.transactions[0].gasPrice=null	null gasPrice
CASES

reader_accept "entry nonce equal to the claim is accepted" '.transactions[0].nonce=42' "$BIND_FIXTURE" \
  --safe "$BIND_SAFE" --nonce 42
reader_accept "entry gas equal to the claim is accepted" '.transactions[0].safeTxGas="100"' "$BIND_FIXTURE" \
  --safe "$BIND_SAFE" --nonce 42 --safe-tx-gas 100
reader_reject "entry gas of zero contradicts a claimed gas" '.' "$BIND_FIXTURE" tx-builder "" \
  --safe "$BIND_SAFE" --nonce 42 --safe-tx-gas 100
reader_reject "bare array entries are checked too" '[.transactions[0] | .baseGas="9"]' "$BIND_FIXTURE" tx-array "" \
  --safe "$BIND_SAFE" --nonce 42 --chain-id 1
reader_reject "static-v1 entries are checked too" '.transactions[0].safeTxGas="5"' tx-builder-decoded.json \
  tx-builder-decoded static-v1 --nonce 42
