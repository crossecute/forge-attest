#!/usr/bin/env bash

group "Zeus traces reader"
ZEUS_MS=0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526
ZEUS_FLAGS=(--chain-id 1 --nonce 0 --safe-version 1.4.1 --multisend "$ZEUS_MS")
ZEUS_EXECUTED=0x9e338be37a1756a80652767968a61be506fce16a0cbbec8d7441ff5e7724f478
READER_MULTISEND=$ZEUS_MS READER_SAFE_VERSION=1.4.1 reader_cross zeus-traces.json zeus-traces "" "${ZEUS_FLAGS[@]}"
assert_eq "zeus-traces reproduces the executed eigenx transaction" \
  "$(bash "$NORMALIZE" --input "$FIX/zeus-traces.json" --format zeus-traces "${ZEUS_FLAGS[@]}" | bash "$ROOT/lib/derive.sh" - | sed -n 's/^SAFE_TX_HASH=//p')" \
  "$ZEUS_EXECUTED"
jq '[.traces[1][1].arena[] | select(.parent == 0 and .trace.kind == "CALL"
      and .trace.address != "0x7109709ecfa91a80626ff3989d68f67f5b1dd12d") | .trace | {to: .address, value: "0", data}]' \
  "$FIX/zeus-traces.json" >"$TMP/zeus-fixture-calls.json"
assert_eq "the traces fold like the same calls given as a tx-array" \
  "$(bash "$NORMALIZE" --input "$FIX/zeus-traces.json" --format zeus-traces "${ZEUS_FLAGS[@]}" | sha256sum | cut -d' ' -f1)" \
  "$(bash "$NORMALIZE" --input "$TMP/zeus-fixture-calls.json" --format tx-array \
      --safe 0x684cf8978c2815716c85eaa237e311f5a44e9e09 "${ZEUS_FLAGS[@]}" | sha256sum | cut -d' ' -f1)"

# The Zeus CLI keeps calls whose trace caller is the script. The fixture's calls are
# made by the multisig, as current Foundry reports them.
while IFS=$'\t' read -r label mutation; do
  reader_reject "$label" "$mutation" zeus-traces.json zeus-traces "" "${ZEUS_FLAGS[@]}"
done <<'CASES'
zeus run that failed	.success = false
call made by the script instead of the multisig	.traces[1][1].arena[5].trace.caller = "0x9f7cf1d1f558e57ef88a59ac3d47214ef25b6a06"
call by an unrelated account	.traces[1][1].arena[5].trace.caller = "0x1111111111111111111111111111111111111111"
reverted call the Zeus CLI would drop	.traces[1][1].arena[5].trace.success = false
contract created as the multisig	.traces[1][1].arena[5].trace.kind = "CREATE"
delegatecall as the multisig	.traces[1][1].arena[5].trace.kind = "DELEGATECALL"
a second execution block	.traces[0][0] = "Execution"
no ZeusRequireMultisig event	.raw_logs[0].topics[0] = "0x0000000000000000000000000000000000000000000000000000000000000000"
two ZeusRequireMultisig events	.raw_logs += [.raw_logs[0]]
event emitted by another contract	.raw_logs[0].address = "0x25e5f8b1e7adf44518d35d5b2271f114e081f0e5"
call type other than 0 or 1	.raw_logs[0].data |= (.[0:-1] + "2")
zero multisig	.raw_logs[0].data = "0x" + ("0" * 128)
dirty multisig address word	.raw_logs[0].data |= ("0x1" + .[3:])
call value a JavaScript number rounds	.traces[1][1].arena[5].trace.value = "0x20000000000000"
malformed call data	.traces[1][1].arena[5].trace.data = "0x6"
no calls as the multisig	.traces[1][1].arena |= map(if .parent == 0 then .trace.kind = "STATICCALL" else . end)
CASES
reader_reject "zeus-traces has no profiles" . zeus-traces.json zeus-traces safe-utils "${ZEUS_FLAGS[@]}"
reader_reject "several calls need the CLI's MultiSend named" . zeus-traces.json zeus-traces "" \
  --chain-id 1 --nonce 0 --safe-version 1.4.1
reader_reject "zeus-traces is never auto-detected" . zeus-traces.json auto "" "${ZEUS_FLAGS[@]}"
reader_reject "the Safe comes from the event" . zeus-traces.json zeus-traces "" "${ZEUS_FLAGS[@]}" \
  --safe 0x111CEEee040739fD91D29C34C33E6B3E112F2177
reader_reject "a single call is never forced through MultiSend" . zeus-traces.json zeus-traces "" "${ZEUS_FLAGS[@]}" \
  --batch-mode multisend
reader_reject "a delegatecall call type cannot use MultiSendCallOnly" '.raw_logs[0].data |= (.[0:-1] + "1")' \
  zeus-traces.json zeus-traces "" --chain-id 1 --nonce 0 --safe-version 1.4.1 \
  --multisend 0x9641d764fc13c8B624c04430C7356C1C7C8102e2
jq '.raw_logs[0].data |= (.[0:-1] + "1")' "$FIX/zeus-traces.json" >"$TMP/zeus-delegate.json"
assert_eq "call type 1 makes every inner call a delegatecall" \
  "$(bash "$NORMALIZE" --input "$TMP/zeus-delegate.json" --format zeus-traces "${ZEUS_FLAGS[@]}" | jq -r '.data[138:140]')" 01
jq '.traces[1][1].arena[5].trace.value = "0x1fffffffffffff"' "$FIX/zeus-traces.json" >"$TMP/zeus-value.json"
assert_contains "a value within a JavaScript number is packed exactly" \
  "$(bash "$NORMALIZE" --input "$TMP/zeus-value.json" --format zeus-traces "${ZEUS_FLAGS[@]}" | jq -r .data)" \
  "$(printf '%064x' 9007199254740991)"

# A producer that behaves like a Zeus MultisigBuilder, run through attest.sh on a
# local fork. It calls two accounts as the Safe, so the traces hold two calls.
ZEUS_PORT=$((20000 + RANDOM % 20000))
anvil --port "$ZEUS_PORT" --chain-id 31337 >/dev/null 2>&1 &
ZEUS_ANVIL=$!
trap 'kill "$ZEUS_ANVIL" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 100); do cast chain-id --rpc-url "http://127.0.0.1:$ZEUS_PORT" >/dev/null 2>&1 && break; sleep 0.1; done
if cast chain-id --rpc-url "http://127.0.0.1:$ZEUS_PORT" >/dev/null 2>&1; then
  producer="$TMP/producer-zeus"
  mkdir -p "$producer/script"
  cp "$ROOT/foundry.toml" "$producer/foundry.toml"
  sed -i 's/test = "test"/test = "script"/; s/src = "test"/src = "script"/' "$producer/foundry.toml"
  cat >"$producer/script/Build.s.sol" <<'SOLIDITY'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface Vm { function startPrank(address) external; function stopPrank() external; }
contract Build {
  Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
  address constant SAFE = 0x111CEEee040739fD91D29C34C33E6B3E112F2177;
  event ZeusRequireMultisig(address addr, uint8 callType);
  function execute() external {
    emit ZeusRequireMultisig(SAFE, 0);
    vm.startPrank(SAFE);
    (bool ok,) = address(0xBEEF).call(abi.encodeWithSignature("ping(uint256)", 1));
    require(ok);
    (ok,) = address(0xCAFE).call(abi.encodeWithSignature("pong()"));
    require(ok);
    vm.stopPrank();
  }
}
SOLIDITY
  printf 'out/\nforge-out/\ncache/\n' >"$producer/.gitignore"
  git -C "$producer" init --quiet
  git -C "$producer" add -A
  git -C "$producer" -c user.name=test -c user.email=test@example.invalid commit --quiet -m 'test: zeus-like producer'
  commit=$(git -C "$producer" rev-parse HEAD)
  jq -n --arg a "$(cast calldata 'ping(uint256)' 1)" --arg b "$(cast calldata 'pong()')" \
    '[{to: "0x000000000000000000000000000000000000bEEF", value: "0", data: $a},
      {to: "0x000000000000000000000000000000000000cAFE", value: "0", data: $b}]' >"$TMP/zeus-calls.json"
  bash "$NORMALIZE" --input "$TMP/zeus-calls.json" --format tx-array \
    --safe 0x111CEEee040739fD91D29C34C33E6B3E112F2177 --nonce 5 --chain-id 31337 \
    --safe-version 1.4.1 --multisend "$ZEUS_MS" >"$TMP/zeus-expected.json"
  zeus_hash=$(bash "$ROOT/lib/derive.sh" "$TMP/zeus-expected.json" | sed -n 's/^SAFE_TX_HASH=//p')
  zeus_digest=$(sha256sum "$TMP/zeus-expected.json" | cut -d' ' -f1)
  cat >"$TMP/zeus-e2e.toml" <<TOML
producer_repo = "file://$producer"
producer_commit = "$commit"
producer_script = "script/Build.s.sol:Build"
rpc_env = "ZEUS_RPC"
fork_block = "0"
output_path = "zeus/execute"
input_format = "zeus-traces"
safe_version = "1.4.1"
multisend_address = "$ZEUS_MS"
safe_nonce = "5"
expected_canonical_sha256 = "$zeus_digest"
expected_safe_tx_hash = "$zeus_hash"
TOML
  output=$(ZEUS_RPC="http://127.0.0.1:$ZEUS_PORT" bash "$ROOT/attest.sh" --config "$TMP/zeus-e2e.toml" --json 2>"$TMP/zeus-e2e.log" || true)
  assert_eq "a zeus-like script attests against an independent fold of its calls" "$(jq -r .attested <<<"$output")" true
  assert_eq "the Safe comes from the event and both derivations agree" \
    "$(jq -r --arg h "$zeus_hash" '[.hashes.safe_tx == $h, .hashes.safe_tx_solidity == $h] | @tsv' <<<"$output")" \
    $'true\ttrue'
  assert_eq "the verdict records the entry point and block the traces came from" \
    "$(jq -r '[.fork_block, .sig] | @tsv' <<<"$output")" $'0\texecute()'
  sed "s/^expected_safe_tx_hash = .*/expected_safe_tx_hash = \"0x$(printf '1%.0s' $(seq 64))\"/" \
    "$TMP/zeus-e2e.toml" >"$TMP/zeus-wrong.toml"
  output=$(ZEUS_RPC="http://127.0.0.1:$ZEUS_PORT" bash "$ROOT/attest.sh" --config "$TMP/zeus-wrong.toml" --json 2>/dev/null || true)
  assert_eq "a wrong pinned hash is not attested" "$(jq -r .attested <<<"$output")" false
  sed '/^fork_block/d' "$TMP/zeus-e2e.toml" >"$TMP/zeus-unpinned.toml"
  if ZEUS_RPC="http://127.0.0.1:$ZEUS_PORT" bash "$ROOT/attest.sh" --config "$TMP/zeus-unpinned.toml" --json >/dev/null 2>"$TMP/zeus-unpinned.log"; then
    fail "a zeus-traces run without fork_block is refused"
  else
    assert_contains "a zeus-traces run without fork_block is refused" "$(cat "$TMP/zeus-unpinned.log")" "fork_block"
  fi
else
  fail "anvil did not start: the zeus-traces end-to-end test needs it"
fi
kill "$ZEUS_ANVIL" 2>/dev/null || true

for bad_sig in "--json" "execute" "execute(uint256,)" "run() --broadcast"; do
  printf 'producer_repo = "file:///x"\nproducer_commit = "%s"\nproducer_script = "script/A.s.sol"\nsig = "%s"\noutput_path = "a.json"\n' \
    "$(printf 'a%.0s' $(seq 40))" "$bad_sig" >"$TMP/bad-sig.toml"
  if bash "$ROOT/lib/claims.sh" "$TMP/bad-sig.toml" >/dev/null 2>&1; then
    fail "sig \"$bad_sig\" is refused"
  else pass "sig \"$bad_sig\" is refused"; fi
done
