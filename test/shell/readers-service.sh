#!/usr/bin/env bash

group "Safe service request reader"
reader_cross safe-service.json auto "" --chain-id 1
reader_cross safe-service-safe-utils.json safe-service safe-utils --chain-id 1 --safe 0x111CEEee040739fD91D29C34C33E6B3E112F2177
while IFS=$'\t' read -r label mutation; do
  reader_reject "$label" "$mutation" safe-service.json safe-service "" --chain-id 1
done <<'CASES'
service wrong carried hash	.contractTransactionHash = "0x0000000000000000000000000000000000000000000000000000000000000000"
service conflicting hash aliases	.safeTxHash = "0x0000000000000000000000000000000000000000000000000000000000000000"
service null hash alias	.safeTxHash = null
service missing nonce	del(.nonce)
service null calldata	.data = null
service response is not a producer request	.executionDate = "2026-11-05"
service strict profile does not default refund fields	del(.gasToken)
service unsafe numeric chain	.chainId = 9007199254740992
CASES
reader_reject "service cannot infer chain from its hash" '.' safe-service.json safe-service
reader_reject "safe-utils profile is explicit" '.' safe-service-safe-utils.json safe-service "" --chain-id 1 --safe 0x111CEEee040739fD91D29C34C33E6B3E112F2177
reader_reject "safe-utils does not accept nonzero gas" '.gasPrice="1"' safe-service-safe-utils.json safe-service safe-utils --chain-id 1 --safe 0x111CEEee040739fD91D29C34C33E6B3E112F2177
reader_e2e safe-service.json safe-service "" --chain-id 1
