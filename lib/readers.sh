#!/usr/bin/env bash

# Loaded by normalize.sh; readers transform the in-memory JSON, never the source file.
reader_eip712() {
  case "$PROFILE" in ""|safe|safe-utils) ;; *) die "unknown safe-eip712 profile: $PROFILE" ;; esac
  jq_root -e --slurpfile schema "$NORMALIZE_DIR/safe-tx-types.json" --arg profile "$PROFILE" '
    (keys == ["domain","message","primaryType","types"]) and
    (.primaryType == "SafeTx") and
    (.domain | keys == ["chainId","verifyingContract"]) and
    (.types.SafeTx == $schema[0].SafeTx) and
    (if .types | has("EIP712Domain") then
      (.types | keys == ["EIP712Domain","SafeTx"]) and (.types.EIP712Domain == $schema[0].EIP712Domain)
    else $profile == "safe-utils" and (.types | keys == ["SafeTx"]) end) and
    (.message | keys == ["baseGas","data","gasPrice","gasToken","nonce","operation","refundReceiver","safeTxGas","to","value"])
  ' >/dev/null || die "invalid SafeTx typed-data schema"
  J=$(jq_root -c '.message + {safe: .domain.verifyingContract, chainId: .domain.chainId}')
  reader_signed_fields
}

reader_signed_fields() {
  local key n
  jq_root -e '
    ([.safe,.to,.gasToken,.refundReceiver] | all(type == "string" and test("^0x[0-9a-fA-F]{40}$"))) and
    (.data | type == "string" and test("^0x([0-9a-fA-F]{2})*$")) and
    ([.chainId,.value,.operation,.safeTxGas,.baseGas,.gasPrice,.nonce] | all(
      if type == "number" then . >= 0 and . <= 9007199254740991 and floor == .
      elif type == "string" then test("^(0|[1-9][0-9]*)$") else false end))
  ' >/dev/null || die "invalid signed transaction fields (large integers must be decimal strings)"
  for key in chainId value operation safeTxGas baseGas gasPrice nonce; do
    n=$(jget ".$key")
    cast to-uint256 "$n" >/dev/null 2>&1 || die "$key exceeds uint256"
  done
  [[ "$(jget '.chainId')" != 0 ]] || die "chainId must be positive"
  [[ "${J,,}" != "" ]] || die "missing transaction"
}
