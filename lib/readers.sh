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
    (.data | type == "string" and test("^0x([0-9a-fA-F]{2})*$"))
  ' >/dev/null || die "invalid signed transaction fields (large integers must be decimal strings)"
  jq_root -c ' .chainId,.value,.operation,.safeTxGas,.baseGas,.gasPrice,.nonce' | reader_uints
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
    (if has("contractTransactionHash") then (.contractTransactionHash | type == "string" and test("^0x[0-9a-fA-F]{64}$")) else true end) and
    (if has("safeTxHash") then (.safeTxHash | type == "string" and test("^0x[0-9a-fA-F]{64}$")) else true end)
  ' >/dev/null || die "invalid service chain or transaction hash"
  jq_root -c 'if has("chainId") then .chainId else empty end' | reader_uints
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

reader_decoded() {
  reader_size_limit
  [[ "$PROFILE" == static-v1 ]] || die "tx-builder-decoded requires the explicit static-v1 profile"
  jq_root -e '
    type == "object" and .version == "1.0" and
    ((keys - ["version","chainId","createdAt","meta","transactions"]) | length == 0) and
    (.transactions | type == "array" and length > 0 and length <= 128)
  ' >/dev/null || die "invalid static-v1 batch envelope"
  jq_root -c 'if has("chainId") then .chainId else empty end' | reader_uints
  if [[ "$(jq_root '(.meta // {}) | has("createdFromSafeAddress")')" == true ]]; then
    norm_addr "$(jget .meta.createdFromSafeAddress)" >/dev/null
  fi
  local count i tx method n j name typ arg value data signature encoded key used payable
  local output='[]'
  count=$(jq_root '.transactions | length')
  for (( i=0; i<count; i++ )); do
    tx=$(jq_root -c --argjson i "$i" '.transactions[$i]')
    jq -c 'if has("value") then .value else 0 end' <<<"$tx" | reader_uints
    [[ "$(jq -r '.operation // 0 | tostring' <<<"$tx")" == 0 ]] || die "static-v1 supports CALL only"
    method=$(jq -c '.contractMethod // null' <<<"$tx")
    if [[ "$method" != null ]]; then
      jq -e '
        (.contractMethod | type == "object" and keys == ["inputs","name","payable"] and
          (.name | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]{0,63}$")) and
          (.payable | type == "boolean") and (.inputs | type == "array" and length <= 32)) and
        (.contractInputsValues | type == "object" or . == null)
      ' <<<"$tx" >/dev/null || die "invalid static-v1 method descriptor"
      name=$(jq -r '.contractMethod.name' <<<"$tx")
      [[ "$name" != receive && "$name" != fallback ]] || die "not an ABI function"
      value=$(jq -r '.value // 0 | tostring' <<<"$tx")
      [[ "$value" == 0 || "$(jq -r '.contractMethod.payable' <<<"$tx")" == true ]] || die "value sent to nonpayable method"
      signature="$name("; n=$(jq '.contractMethod.inputs | length' <<<"$tx")
      local args=()
      used='[]'
      for (( j=0; j<n; j++ )); do
        arg=$(jq -c --argjson j "$j" '.contractMethod.inputs[$j]' <<<"$tx")
        jq -e 'type == "object" and ((keys - ["internalType","name","type"]) | length == 0) and
          (.name | type == "string" and test("^([A-Za-z_][A-Za-z0-9_]*|)$")) and
          (.type == "address" or .type == "bool" or .type == "uint8" or .type == "uint256")' <<<"$arg" >/dev/null \
          || die "unsupported static-v1 input type or name"
        typ=$(jq -r .type <<<"$arg"); key=$(jq -r .name <<<"$arg")
        [[ -n "$key" ]] || key="$j"
        used=$(jq -c --arg key "$key" '. + [$key]' <<<"$used")
        value=$(jq -er --arg key "$key" '.contractInputsValues[$key] | select(type == "string")' <<<"$tx") \
          || die "missing or non-string method input: $key"
        case "$typ" in
          address) norm_addr "$value" >/dev/null ;;
          bool) [[ "$value" == true || "$value" == false ]] || die "bool input must be true or false" ;;
          uint8|uint256)
            [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || die "method integer must be a canonical decimal string"
            cast to-uint256 "$value" >/dev/null 2>&1 || die "method integer exceeds uint256" ;;
        esac
        (( j == 0 )) || signature+=","
        signature+="$typ"; args+=("$value")
      done
      signature+=")"
      jq -e --argjson used "$used" '
        (($used | unique | length) == ($used | length)) and
        (((.contractInputsValues // {}) | keys) == ($used | sort))' <<<"$tx" >/dev/null || die "unexpected or duplicate method inputs"
      encoded=$(cast calldata "$signature" "${args[@]}") || die "cannot encode static-v1 call"
      data=$(jq -r '.data // ""' <<<"$tx")
      [[ -z "$data" || "${data,,}" == "${encoded,,}" ]] || die "encoded calldata contradicts method descriptor"
      tx=$(jq -c --arg data "$encoded" '.data = $data' <<<"$tx")
    else
      jq -e '.contractInputsValues == null or (.contractInputsValues | type == "object" and length == 0)' <<<"$tx" >/dev/null \
        || die "method inputs without a method descriptor"
    fi
    tx=$(jq -c 'del(.contractMethod,.contractInputsValues)' <<<"$tx")
    output=$(jq -c --argjson tx "$tx" '. + [$tx]' <<<"$output")
  done
  J=$(jq_root -c --argjson txs "$output" '.transactions = $txs')
}

reader_uints() {
  jq -es 'all(.[]; if type == "number" then . >= 0 and . <= 9007199254740991 and floor == .
    elif type == "string" then test("^(0|[1-9][0-9]*)$") else false end)' >/dev/null \
    || die "invalid decimal integer (large integers must be strings)"
}
