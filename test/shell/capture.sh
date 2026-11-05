#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
ANVIL=""
trap '[[ -z "$ANVIL" ]] || kill "$ANVIL" 2>/dev/null || true; rm -rf "$TMP"' EXIT
PASS=0 FAILED=0 GREEN= RED= BOLD= RESET=
source "$ROOT/test/shell/assertions.sh"
SAFE=0x111CEEee040739fD91D29C34C33E6B3E112F2177
URL="https://safe-transaction-mainnet.safe.global/api/v1/safes/$SAFE/multisig-transactions/"
BODY=$(cat "$ROOT/test/fixtures/safe-service-safe-utils.json")
cat >"$TMP/claim.toml" <<TOML
producer_repo = "file://unused"
producer_commit = "1111111111111111111111111111111111111111"
producer_script = "script/Build.s.sol:Build"
capture = "safe-utils"
rpc_env = "CAPTURE_RPC"
fork_block = "0"
output_path = "captured/request.json"
input_format = "safe-service"
input_profile = "safe-utils"
safe_address = "$SAFE"
safe_nonce = "42"
chain_id = "1"
expected_safe_tx_hash = "0xd0e33f3b88aceb5122db6ad935c1d709c7602f8ed92fc6b27bdd507902bdf534"
TOML
bash "$ROOT/lib/claims.sh" "$TMP/claim.toml" >"$TMP/model.json"
assert_eq 'flat claims retain capture mode' "$(jq -r '.runs[0].capture' "$TMP/model.json")" safe-utils

reject_config() {
  local label="$1" from="$2" to="$3"
  sed "s/$from/$to/" "$TMP/claim.toml" >"$TMP/bad.toml"
  if bash "$ROOT/lib/claims.sh" "$TMP/bad.toml" >"$TMP/model.bad" 2>"$TMP/error"; then fail "$label"; else pass "$label"; fi
}
reject_config 'unknown capture mode rejected' 'capture = "safe-utils"' 'capture = "other"'
reject_config 'capture needs a pinned fork' 'fork_block = "0"' ''
reject_config 'capture needs RPC' 'rpc_env = "CAPTURE_RPC"' ''
reject_config 'capture needs the service reader' 'input_format = "safe-service"' 'input_format = "auto"'
reject_config 'capture needs explicit safe-utils profile' 'input_profile = "safe-utils"' ''
reject_config 'capture needs the Safe binding' "safe_address = \"$SAFE\"" ''
reject_config 'capture needs the nonce binding' 'safe_nonce = "42"' ''
cat >"$TMP/reserved.toml" <<TOML
producer_repo = "file://unused"
producer_commit = "1111111111111111111111111111111111111111"
[[run]]
script = "script/Build.s.sol:Build"
[run.env]
FORGE_ATTEST_CAPTURE_DIR = "elsewhere"
[[run.claim]]
output_path = "request.json"
TOML
if bash "$ROOT/lib/claims.sh" "$TMP/reserved.toml" >/dev/null 2>&1; then fail 'capture environment is reserved'; else pass 'capture environment is reserved'; fi

prepare() {
  local name="$1"
  bash "$ROOT/lib/capture.sh" prepare "$TMP/model.json" 0 "$TMP/$name" 1
}
request() {
  local name="$1"; shift
  FORGE_ATTEST_CAPTURE_DIR="$TMP/$name" "$TMP/$name/bin/curl" "$@"
}
args=(-s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -d "$BODY" "$URL")
prepare valid
assert_eq 'capture returns the safe-utils response framing' "$(request valid "${args[@]}")" $'{}\n201'
assert_eq 'capture preserves request bytes' "$(cat "$TMP/valid/0.json")" "$BODY"
bash "$ROOT/lib/capture.sh" verify "$TMP/valid"
pass 'all claimed proposals captured'
if request valid "${args[@]}" >/dev/null 2>&1; then fail 'duplicate rejected'; else pass 'duplicate rejected'; fi
if bash "$ROOT/lib/capture.sh" verify "$TMP/valid" >/dev/null 2>&1; then fail 'swallowed rejection fails verification'; else pass 'swallowed rejection fails verification'; fi

reject_request() {
  local name="$1"; shift
  prepare "$name"
  if request "$name" "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}
reject_request get -s -w '\n%{http_code}' -X GET "$URL"
reject_request upload -s -w '\n%{http_code}' -X POST --upload-file /etc/passwd "$URL"
reject_request file-body -s -w '\n%{http_code}' -X POST -d @request.json "$URL"
reject_request malformed -s -w '\n%{http_code}' -X POST -d '{}' "$URL"
reject_request wrong-safe -s -w '\n%{http_code}' -X POST -d "$BODY" "${URL/$SAFE/0x0000000000000000000000000000000000000001}"
reject_request wrong-nonce -s -w '\n%{http_code}' -X POST -d "$(jq '.nonce="43"' <<<"$BODY")" "$URL"
reject_request non-proposal -s -w '\n%{http_code}' -X POST -d "$BODY" https://example.invalid/other
reject_request two-urls "${args[@]}" "$URL"
reject_request two-bodies "${args[@]}" -d "$BODY"
prepare missing
if bash "$ROOT/lib/capture.sh" verify "$TMP/missing" >/dev/null 2>&1; then fail 'missing proposal rejected'; else pass 'missing proposal rejected'; fi
if bash "$ROOT/lib/capture.sh" prepare "$TMP/model.json" 0 "$TMP/wrong-chain" 10 >/dev/null 2>&1; then fail 'RPC and claim chain must agree'; else pass 'RPC and claim chain must agree'; fi
prepare corrupt
printf 'invalid' >"$TMP/corrupt/map.json"
if bash "$ROOT/lib/capture.sh" verify "$TMP/corrupt" >/dev/null 2>&1; then fail 'invalid capture manifest rejected'; else pass 'invalid capture manifest rejected'; fi

# Prove that PATH interception blocks an otherwise reachable HTTP POST.
PORT=$((20000 + RANDOM % 20000))
anvil --port "$PORT" --chain-id 1 >"$TMP/anvil.log" 2>&1 &
ANVIL=$!
for _ in $(seq 100); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 0.1; done
cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null
producer="$TMP/producer"
mkdir -p "$producer/script"
cp "$ROOT/test/fixtures/safe-service-safe-utils.json" "$producer/request.json"
jq '.nonce = "43" | del(.contractTransactionHash)' "$producer/request.json" >"$TMP/request43.json"
bash "$ROOT/lib/normalize.sh" --input "$TMP/request43.json" --format safe-service --profile safe-utils \
  --safe "$SAFE" --chain-id 1 >"$TMP/canonical43.json"
hash43=$(bash "$ROOT/lib/derive.sh" "$TMP/canonical43.json" | sed -n 's/^SAFE_TX_HASH=//p')
jq --arg hash "$hash43" '. + {contractTransactionHash: $hash}' "$TMP/request43.json" >"$producer/request43.json"
cat >"$producer/foundry.toml" <<'TOML'
[profile.default]
src = "script"
test = "script"
solc = "0.8.28"
ffi = false
TOML
cat >"$producer/script/Build.s.sol" <<'SOLIDITY'
pragma solidity 0.8.28;
interface Vm { function ffi(string[] calldata) external returns (bytes memory); }
contract Build {
  function run() external {
    string[] memory cmd = new string[](2);
    cmd[0] = "bash";
    cmd[1] = "submit.sh";
    Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).ffi(cmd);
  }
}
SOLIDITY
cat >"$producer/submit.sh" <<'SHELL'
#!/usr/bin/env bash
set -eu
[[ "${CAPTURE_TEST_MODE:-}" != missing ]] || exit 0
body=$(cat request.json)
if [[ "${CAPTURE_TEST_MODE:-}" == hash ]]; then body=$(jq '.contractTransactionHash = "0x" + ("0" * 64)' <<<"$body"); fi
url="http://127.0.0.1:${CAPTURE_PORT}/api/v1/safes/0x111CEEee040739fD91D29C34C33E6B3E112F2177/multisig-transactions/"
response=$(curl -s -w '\n%{http_code}' -X POST -d "$body" "$url")
[[ "$(tail -n1 <<<"$response")" == 201 ]]
if [[ "${CAPTURE_TEST_MODE:-}" == duplicate ]]; then curl -s -w '\n%{http_code}' -X POST -d "$body" "$url" || true; fi
if [[ "${CAPTURE_TEST_MODE:-}" == extra ]]; then curl -s -w '\n%{http_code}' -X POST -d "$body" "${url/0x111CEEee040739fD91D29C34C33E6B3E112F2177/0x0000000000000000000000000000000000000001}" || true; fi
if [[ "${CAPTURE_TEST_MODE:-}" == multi ]]; then curl -s -w '\n%{http_code}' -X POST -d "$(cat request43.json)" "$url"; fi
if [[ "${CAPTURE_TEST_MODE:-}" == changed ]]; then printf '{"nonce":42}' > captured-request.json; fi
printf '0x00'
SHELL
printf 'out/\ncache/\n' >"$producer/.gitignore"
git -C "$producer" init --quiet
git -C "$producer" add -A
git -C "$producer" -c user.name=test -c user.email=test@example.invalid commit --quiet -m 'test: native Safe request producer'
commit=$(git -C "$producer" rev-parse HEAD)
capture_attest() {
  CAPTURE_PORT="$PORT" CAPTURE_RPC="http://127.0.0.1:$PORT" bash "$ROOT/attest.sh" --config "$1" --json
}
cat >"$TMP/e2e.toml" <<TOML
producer_repo = "file://$producer"
producer_commit = "$commit"
[[run]]
script = "script/Build.s.sol:Build"
capture = "safe-utils"
rpc_env = "CAPTURE_RPC"
fork_block = "0"
[run.env]
CAPTURE_PORT = "$PORT"
CAPTURE_TEST_MODE = "valid"
[[run.claim]]
output_path = "captured-request.json"
input_format = "safe-service"
input_profile = "safe-utils"
safe_address = "$SAFE"
safe_nonce = "42"
chain_id = "1"
live = false
expected_safe_tx_hash = "0xd0e33f3b88aceb5122db6ad935c1d709c7602f8ed92fc6b27bdd507902bdf534"
TOML
capture_attest "$TMP/e2e.toml" >"$TMP/verdict.json" 2>"$TMP/report.log" || { cat "$TMP/report.log"; exit 1; }
assert_eq 'unchanged FFI producer attests without real HTTP submission' "$(jq -r .attested "$TMP/verdict.json")" true
assert_eq 'capture mode recorded in verdict' "$(jq -r '.runs[0].capture' "$TMP/verdict.json")" safe-utils
assert_eq 'Solidity and cast independently agree on captured request' "$(jq -r '.claims[0].hashes.safe_tx_solidity' "$TMP/verdict.json")" 0xd0e33f3b88aceb5122db6ad935c1d709c7602f8ed92fc6b27bdd507902bdf534
for mode in missing duplicate extra changed hash; do
  sed "s/CAPTURE_TEST_MODE = \"valid\"/CAPTURE_TEST_MODE = \"$mode\"/" "$TMP/e2e.toml" >"$TMP/$mode.toml"
  if capture_attest "$TMP/$mode.toml" >"$TMP/verdict.$mode.json" 2>"$TMP/report.$mode.log"; then fail "$mode producer rejected"; else pass "$mode producer rejected"; fi
done
sed 's/CAPTURE_TEST_MODE = "valid"/CAPTURE_TEST_MODE = "multi"/' "$TMP/e2e.toml" >"$TMP/multi.toml"
cat >>"$TMP/multi.toml" <<TOML
[[run.claim]]
output_path = "second-request.json"
input_format = "safe-service"
input_profile = "safe-utils"
safe_address = "$SAFE"
safe_nonce = "43"
chain_id = "1"
live = false
expected_safe_tx_hash = "$hash43"
TOML
capture_attest "$TMP/multi.toml" >"$TMP/multi.json" 2>"$TMP/multi.log" || { cat "$TMP/multi.log"; exit 1; }
assert_eq 'several native proposals attest without dropping an output' "$(jq -r '.attested and (.claims | length == 2)' "$TMP/multi.json")" true
sed 's/safe_nonce = "43"/safe_nonce = "42"/' "$TMP/multi.toml" >"$TMP/duplicate-bindings.toml"
if bash "$ROOT/lib/claims.sh" "$TMP/duplicate-bindings.toml" >/dev/null 2>&1; then fail 'duplicate claim bindings rejected'; else pass 'duplicate claim bindings rejected'; fi
sed -e "s|file://unused|file://$producer|" -e "s/1111111111111111111111111111111111111111/$commit/" \
  -e 's|captured/request.json|script/Build.s.sol|' "$TMP/claim.toml" >"$TMP/flat.toml"
capture_attest "$TMP/flat.toml" >"$TMP/flat.json" 2>"$TMP/flat.log" || { cat "$TMP/flat.log"; exit 1; }
assert_eq 'flat capture records its mode and preserves a logical path that names source' \
  "$(jq -r '.attested and .capture == "safe-utils" and .fork_block == "0"' "$TMP/flat.json")" true
printf '\nCapture checks: %s passed, %s failed\n' "$PASS" "$FAILED"
[[ "$FAILED" == 0 ]]
