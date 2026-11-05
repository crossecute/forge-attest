#!/usr/bin/env bash

group "Decoded Transaction Builder reader"
reader_cross tx-builder-decoded.json tx-builder-decoded static-v1 --nonce 42
reader_cross tx-builder-decoded.json tx-builder static-v1 --nonce 42
reader_cross tx-builder-decoded.json auto static-v1 --nonce 42
reader_cross tx-builder-static-vectors.json tx-builder-decoded static-v1 --nonce 42
reader_cross tx-builder-decoded.json tx-builder-decoded static-v1 --nonce 42 --batch-mode multisend
reader_cross tx-builder-decoded.json tx-builder-decoded static-v1 --nonce 42 --gas-price 1000 --safe-tx-gas 50000
for decoded_format in auto tx-builder tx-builder-decoded; do
  for safe_key in safe safeAddress; do
    for declared_safe in 0x111CEEee040739fD91D29C34C33E6B3E112F2177 0x0000000000000000000000000000000000000b0b; do
      reader_reject "$decoded_format rejects top-level $safe_key=$declared_safe" \
        ".[\"$safe_key\"] = \"$declared_safe\"" tx-builder-decoded.json "$decoded_format" static-v1 \
        --nonce 42 --safe 0x111CEEee040739fD91D29C34C33E6B3E112F2177
      assert_contains "$decoded_format reports the unsupported envelope" "$(cat "$TMP/error")" \
        "invalid static-v1 batch envelope"
    done
  done
done
while IFS=$'\t' read -r label mutation; do
  reader_reject "$label" "$mutation" tx-builder-decoded.json tx-builder-decoded static-v1 --nonce 42
done <<'CASES'
decoded calldata contradiction	.transactions[0].data="0x"
decoded unsupported type	.transactions[0].contractMethod.inputs[1].type="bytes"
decoded uint8 overflow	.transactions[0].contractMethod.inputs[1].type="uint8"
decoded extra argument	.transactions[0].contractInputsValues.extra="1"
decoded missing argument	del(.transactions[0].contractInputsValues.amount)
decoded non-string argument	.transactions[0].contractInputsValues.amount=1
decoded value sent to nonpayable method	.transactions[0].value="1"
decoded orphaned argument values	.transactions[0].contractMethod=null
decoded unsupported file version	.version="2.0"
decoded CALL-only profile	.transactions[0].operation="1"
decoded call count limit	.transactions = [range(0;129) | {to:"0x000000000000000000000000000000000000bEEF"}]
CASES
reader_reject "decoded needs an explicit profile" '.' tx-builder-decoded.json tx-builder-decoded "" --nonce 42
reader_e2e tx-builder-decoded.json tx-builder-decoded static-v1 --nonce 42
