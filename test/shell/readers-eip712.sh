#!/usr/bin/env bash

group "Safe EIP-712 reader"
reader_cross safe-eip712.json auto ""
reader_cross safe-eip712-numeric.json auto ""
reader_cross safe-eip712-safe-utils.json safe-eip712 safe-utils
assert_eq "typed data preserves the existing canonical bytes" \
  "$(bash "$NORMALIZE" --input "$FIX/safe-eip712.json" | sha256sum | cut -d' ' -f1)" \
  "$(bash "$NORMALIZE" --input "$FIX/safe-tx-single.json" | sha256sum | cut -d' ' -f1)"
while IFS=$'\t' read -r label mutation; do
  reader_reject "$label" "$mutation" safe-eip712.json auto
 done <<'CASES'
wrong primaryType	.primaryType = "Other"
extra domain field	.domain.name = "Safe"
changed type	.types.SafeTx[3].type = "uint256"
reordered type	.types.SafeTx |= reverse
unknown message field	.message.extra = "0"
missing signed field	del(.message.data)
null signed calldata	.message.data = null
invalid operation	.message.operation = "256"
negative integer	.message.value = "-1"
uint256 overflow	.message.value = "115792089237316195423570985008687907853269984665640564039457584007913129639936"
unsafe numeric literal	.message.value = 9007199254740992
zero Safe	.domain.verifyingContract = "0x0000000000000000000000000000000000000000"
zero chain	.domain.chainId = "0"
CASES
reader_reject "unknown profile" '.' safe-eip712.json safe-eip712 wrong
reader_reject "missing domain needs the explicit safe-utils profile" '.' safe-eip712-safe-utils.json safe-eip712
reader_e2e safe-eip712.json safe-eip712 ""
