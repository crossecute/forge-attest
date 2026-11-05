#!/usr/bin/env bash

# Loaded by normalize.sh; readers transform the in-memory JSON, never the source file.
reader_eip712() {
  reader_size_limit
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
  [[ "$(jget .safe | tr A-F a-f)" != 0x0000000000000000000000000000000000000000 ]] || die "Safe address must not be zero"
}

reader_size_limit() {
  local size
  size=$(wc -c <"$INPUT")
  (( size <= 1048576 )) || die "reader input exceeds 1 MiB"
}

reader_service() {
  reader_size_limit
  case "$PROFILE" in ""|safe|safe-utils) ;; *) die "unknown safe-service profile: $PROFILE" ;; esac
  jq_root -e '
    type == "object" and
    ((keys - ["safe","chainId","to","value","data","operation","safeTxGas","baseGas","gasPrice","gasToken","refundReceiver","nonce","sender","signature","origin","contractTransactionHash","safeTxHash"]) | length == 0)
  ' >/dev/null || die "not an exported Safe service request"
  jq_root -e '
    def scalar_uint: if type == "number" then . >= 0 and . <= 9007199254740991 and floor == .
      elif type == "string" then test("^(0|[1-9][0-9]*)$") else false end;
    (if has("chainId") then (.chainId | scalar_uint) else true end) and
    (if has("contractTransactionHash") then (.contractTransactionHash | type == "string" and test("^0x[0-9a-fA-F]{64}$")) else true end) and
    (if has("safeTxHash") then (.safeTxHash | type == "string" and test("^0x[0-9a-fA-F]{64}$")) else true end)
  ' >/dev/null || die "invalid service chain or transaction hash"
  SERVICE_HASH=$(jget .contractTransactionHash)
  SERVICE_ALT_HASH=$(jget .safeTxHash)
  if [[ "$PROFILE" == safe-utils ]]; then
    J=$(jq_root -c 'if has("gasToken") then . else . + {gasToken:"0x0000000000000000000000000000000000000000"} end |
      if has("refundReceiver") then . else . + {refundReceiver:"0x0000000000000000000000000000000000000000"} end')
    jq_root -e '([.safeTxGas,.baseGas,.gasPrice] | all(. == "0" or . == 0)) and
      (.gasToken | ascii_downcase == "0x0000000000000000000000000000000000000000") and
      (.refundReceiver | ascii_downcase == "0x0000000000000000000000000000000000000000")' >/dev/null \
      || die "safe-utils service profile requires zero gas/refund fields"
  else
    [[ -n "$(jget .safe)" ]] || die "service request is missing safe"
  fi
  local bound_safe bound_chain
  bound_safe=$(reconcile "safe address" "$(jget .safe)" "$SAFE")
  bound_chain=$(reconcile "chainId" "$(jget .chainId)" "$CHAIN_ID")
  J=$(jq_root -c --arg safe "$bound_safe" --arg chain "$bound_chain" '. + {safe:$safe, chainId:$chain}')
  reader_signed_fields
}

reader_service_hashes() {
  local canonical="$1" derived carried
  derived=$(bash "$NORMALIZE_DIR/derive.sh" - <<<"$canonical" | sed -n 's/^SAFE_TX_HASH=//p')
  for carried in "$SERVICE_HASH" "$SERVICE_ALT_HASH"; do
    [[ -n "$carried" ]] || continue
    [[ "${carried,,}" =~ ^0x[0-9a-f]{64}$ && "${carried,,}" == "$derived" ]] \
      || die "service transaction hash does not match the independently derived SafeTx"
  done
}
