#!/usr/bin/env bash
#
# Shell-side test suite for forge-attest.
#
#   1. lib/normalize.sh: format detection, canonicalisation, guard rails
#   2. cast vs Solidity: the two hash derivations must agree on every fixture
#   3. attest.sh:        a full end-to-end run against a synthetic producer repo
#                         that emits a Transaction Builder batch
#   4. propose.sh:       signing and submission against a stubbed Transaction
#                         Service, and attest.sh --propose refusing unattested txs
#   5. skills:           the build-safe-tx template is byte-stable and attests
#
# Usage: test/shell/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$ROOT/test/fixtures"
NORMALIZE="$ROOT/lib/normalize.sh"
DERIVE="$ROOT/lib/derive.sh"

SAFE="0x111CEEee040739fD91D29C34C33E6B3E112F2177"
NONCE="42"

PASS=0
FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else GREEN=; RED=; BOLD=; RESET=; fi

pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
group() { printf '\n%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }

assert_eq() { # what got want
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"$'\n      got  '"$2"$'\n      want '"$3"; fi
}
assert_ne() { # what a b
  if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1 (both were $2)"; fi
}
assert_contains() { # what haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1"$'\n      output: '"$2"; fi
}

# normalize <fixture> [extra args...] -> canonical JSON on stdout
normalize() {
  local f="$1"; shift
  bash "$NORMALIZE" --input "$FIX/$f" --safe "$SAFE" --nonce "$NONCE" "$@" 2>"$TMP/err"
}

# normalize_err <fixture> [extra args...] -> stderr, expects failure
normalize_err() {
  local f="$1"; shift
  bash "$NORMALIZE" --input "$FIX/$f" --safe "$SAFE" --nonce "$NONCE" "$@" 2>&1 >/dev/null
}

canonical_sha() { sha256sum | awk '{print $1}'; }

safe_tx_hash() { # <canonical json path>
  bash "$DERIVE" "$1" | grep '^SAFE_TX_HASH=' | cut -d= -f2
}

# ---------------------------------------------------------------- 1. normalize

group "normalize.sh: format detection"

fmt() { normalize "$1" "${@:2}" >/dev/null; sed -n 's/^ *format *: *//p' "$TMP/err"; }

assert_eq "detects tx-builder (Frax SafeTxHelper output)" \
  "$(fmt tx-builder-frax-optimism.json --summary)" "tx-builder"
assert_eq "detects a bare transaction array" \
  "$(fmt tx-array.json --summary --chain-id 1)" "tx-array"
assert_eq "detects a flat SafeTx object" \
  "$(fmt safe-tx-single.json --summary)" "safe-tx"

group "normalize.sh: canonical form"

canon_frax="$TMP/frax.json"
normalize tx-builder-frax-optimism.json >"$canon_frax"

assert_eq "chainId is taken from the batch" \
  "$(jq -r .chainId "$canon_frax")" "10"
assert_eq "a 6-tx batch is signed as a delegatecall" \
  "$(jq -r .operation "$canon_frax")" "1"
assert_eq "…into MultiSendCallOnly 1.3.0" \
  "$(jq -r .to "$canon_frax")" "0x40a2accbd92bca938b02010e17a5b8929b49130d"
assert_eq "…with multiSend(bytes) calldata" \
  "$(jq -r .data "$canon_frax" | cut -c1-10)" "0x8d80ff0a"
assert_eq "the Safe binding comes from config" \
  "$(jq -r '[.safe, .nonce] | join(" ")' "$canon_frax")" \
  "$(printf '%s 42' "${SAFE,,}")"
assert_eq "every canonical scalar is a quoted string" \
  "$(jq -r '[.[] | type] | unique | join(",")' "$canon_frax")" "string"
assert_eq "canonical key order is fixed" \
  "$(jq -r 'keys_unsorted | join(",")' "$canon_frax")" \
  "safe,chainId,safeVersion,to,value,data,operation,safeTxGas,baseGas,gasPrice,gasToken,refundReceiver,nonce"

# The property the whole design rests on: `createdAt`, `meta`, key order, address
# checksum casing, hex casing and string-vs-number scalars are all presentation,
# and must not move the bytes that get signed.
assert_eq "volatile metadata does not change the canonical digest" \
  "$(normalize tx-builder-frax-optimism-restamped.json | canonical_sha)" \
  "$(cat "$canon_frax" | canonical_sha)"

assert_eq "a single-transaction batch is not wrapped in multiSend" \
  "$(normalize tx-builder-single.json | jq -r '[.to, .operation] | join(" ")')" \
  "0x000000000000000000000000000000000000dead 0"
assert_eq "null data becomes empty calldata" \
  "$(normalize tx-builder-single.json | jq -r .data)" "0x"
assert_eq "--batch-mode multisend wraps even a single transaction" \
  "$(normalize tx-builder-single.json --batch-mode multisend | jq -r .operation)" "1"
assert_eq "Safe 1.4.x selects the 1.4.1 MultiSendCallOnly" \
  "$(normalize tx-builder-frax-optimism.json --safe-version 1.4.1 | jq -r .to)" \
  "0x9641d764fc13c8b624c04430c7356c1c7c8102e2"

# The version -> MultiSend mapping must cover exactly the versions test/SafeTx.sol
# covers. A version one side maps and the other doesn't means the two derivations
# pick different `to` addresses and silently disagree.
assert_eq "Safe 1.5.x selects the 1.5.0 MultiSendCallOnly" \
  "$(normalize tx-builder-frax-optimism.json --safe-version 1.5.0 | jq -r .to)" \
  "0xa83c336b20401af773b6219ba5027174338d1836"
# The canonical MultiSendCallOnly is not universal; guessing it on a chain that
# uses a different deployment yields a `to` the Safe never calls.
assert_contains "zkSync Era refuses the canonical MultiSend default" \
  "$(normalize_err tx-builder-zksync-era.json)" \
  "chain 324 does not use the canonical MultiSendCallOnly"
assert_eq "…but an explicit address is honoured" \
  "$(normalize tx-builder-zksync-era.json --multisend 0xf220D3b4DFb23C4ade8C88E526C1353AbAcbC38F | jq -r .to)" \
  "0xf220d3b4dfb23c4ade8c88e526c1353abacbc38f"
assert_eq "Safe 1.5.0 has no divergent chains" \
  "$(normalize tx-builder-zksync-era.json --safe-version 1.5.0 | jq -r .to)" \
  "0xa83c336b20401af773b6219ba5027174338d1836"

assert_contains "an unknown Safe version is refused, not guessed at" \
  "$(normalize_err tx-builder-frax-optimism.json --safe-version 1.9.9)" \
  "no known MultiSendCallOnly for Safe 1.9.9"
assert_eq "…but works once the address is named" \
  "$(normalize tx-builder-frax-optimism.json --safe-version 1.9.9 \
       --multisend 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 | jq -r .to)" \
  "0x9641d764fc13c8b624c04430c7356c1c7c8102e2"

# Gas/refund fields are hash inputs that no batch format carries, so they come
# from config, and must reach both derivations, not just this one.
assert_eq "gas fields land in the canonical form" \
  "$(normalize tx-builder-frax-optimism.json --gas-price 1000 --safe-tx-gas 50000 \
       | jq -r '[.gasPrice, .safeTxGas] | join(" ")')" \
  "1000 50000"

# The packed payload commits to each entry's length, so the Frax batch encodes to
# 6 * (1 + 20 + 32 + 32 + 164) = 1494 bytes. In the `multiSend(bytes)` calldata
# that length sits in the second word: "0x" + selector(8) + offset(64), so chars
# 75..138.
assert_eq "multiSend payload length is 6 * 249 bytes" \
  "$(jq -r .data "$canon_frax" | cut -c75-138 | sed 's/^0*//')" "5d6"

group "normalize.sh: a batch that binds itself"

# The Transaction Builder schema has a slot for the Safe a batch was built for.
# When a producer fills it in, --safe stops being a required input.
assert_eq "the Safe is taken from meta.createdFromSafeAddress" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-self-binding.json" --nonce 42 | jq -r .safe)" \
  "${SAFE,,}"
assert_eq "a config Safe that agrees is accepted" \
  "$(normalize tx-builder-self-binding.json | jq -r .safe)" "${SAFE,,}"
assert_contains "a config Safe that contradicts the file is rejected" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-self-binding.json" --nonce 42 \
       --safe 0x000000000000000000000000000000000000b0b0 2>&1 >/dev/null)" \
  "safe address mismatch"
assert_contains "a file declaring no Safe still needs one" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-frax-optimism.json" --nonce 42 2>&1 >/dev/null)" \
  "no Safe address"

group "normalize.sh: guard rails"

assert_contains "rejects a contractMethod entry with no encoded data" \
  "$(normalize_err tx-builder-contract-method.json)" "contractMethod but no encoded 'data'"
assert_contains "rejects an inner delegatecall under MultiSendCallOnly" \
  "$(normalize_err tx-builder-delegatecall.json)" "MultiSendCallOnly rejects"
assert_contains "rejects an inner delegatecall under the 1.5.0 CallOnly default" \
  "$(normalize_err tx-builder-delegatecall.json --safe-version 1.5.0)" "MultiSendCallOnly rejects"
assert_contains "rejects an inner delegatecall under a chain-specific CallOnly" \
  "$(normalize_err tx-builder-delegatecall.json --multisend 0xf220D3b4DFb23C4ade8C88E526C1353AbAcbC38F)" \
  "MultiSendCallOnly rejects"
# A missing exceptions table means the divergent-chain guard is not running. That
# must be loud, not a silent fallback to guessing the canonical address.
assert_contains "a missing exceptions table is fatal, not skipped" \
  "$(cp "$NORMALIZE" "$TMP/detached.sh"; bash "$TMP/detached.sh" --input "$FIX/tx-builder-frax-optimism.json" \
       --safe "$SAFE" --nonce 42 2>&1 >/dev/null)" \
  "cannot check whether chain 10 uses the canonical MultiSendCallOnly"

assert_contains "accepts an inner delegatecall with an explicit MultiSend" \
  "$(normalize tx-builder-delegatecall.json --multisend 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761 | jq -r .to)" \
  "0xa238cbeb142c10ef7ad8442c6d1f9e89e07e7761"
assert_contains "rejects --batch-mode single on a multi-transaction batch" \
  "$(normalize_err tx-builder-frax-optimism.json --batch-mode single)" "but the batch holds 6 transactions"
assert_contains "requires a Safe address for batches" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-frax-optimism.json" --nonce 1 2>&1 >/dev/null)" \
  "no Safe address"
assert_contains "requires a nonce for batches" \
  "$(bash "$NORMALIZE" --input "$FIX/tx-builder-frax-optimism.json" --safe "$SAFE" 2>&1 >/dev/null)" \
  "no Safe nonce"
assert_contains "requires a chainId when the JSON has none" \
  "$(normalize_err tx-array.json)" "no chainId"

# A config value that disagrees with the JSON is a tampering signal, not a
# preference to be silently resolved.
assert_contains "refuses to override a value the JSON already carries" \
  "$(normalize_err tx-builder-frax-optimism.json --chain-id 1)" "chainId mismatch"
assert_contains "accepts a config value that agrees with the JSON" \
  "$(normalize tx-builder-frax-optimism.json --chain-id 10 | jq -r .chainId)" "10"

assert_contains "rejects malformed JSON" \
  "$(printf 'not json' >"$TMP/bad.json"; bash "$NORMALIZE" --input "$TMP/bad.json" 2>&1 >/dev/null)" \
  "not valid JSON"
assert_contains "rejects an empty batch" \
  "$(printf '{"chainId":1,"transactions":[]}' >"$TMP/empty.json"; \
     bash "$NORMALIZE" --input "$TMP/empty.json" --safe "$SAFE" --nonce 1 2>&1 >/dev/null)" \
  "no transactions"

# ------------------------------------------------- 2. cast vs Solidity agreement

group "cast vs Solidity: independent derivations must agree"

mkdir -p "$ROOT/out"

cross_check() { # <label> <fixture> [normalize args...]
  local label="$1" fixture="$2"; shift 2
  local canon="$TMP/cross.json"
  if ! normalize "$fixture" "$@" >"$canon"; then
    fail "$label (normalize failed: $(cat "$TMP/err"))"; return
  fi
  local cast_hash; cast_hash=$(safe_tx_hash "$canon")

  # Point the Solidity cross-check at the *raw* fixture, exactly as attest.sh
  # does: it must fold the batch itself rather than trusting normalize.sh.
  cp "$FIX/$fixture" "$ROOT/out/producer-tx.json"
  rm -f "$ROOT/out/solidity-safe-tx-hash.txt"

  # Mirror the normalize flags into the env attest.sh sets, so the Solidity side
  # is given exactly the same binding and any divergence is a real one.
  local force=""; [[ " $* " == *" --batch-mode multisend "* ]] && force=1
  local version=""; [[ " $* " == *" --safe-version "* ]] && version="1.4.1"
  local chain=""; [[ "$fixture" == "tx-array.json" ]] && chain="1"
  local multisend=""
  [[ " $* " == *" --multisend "* ]] && multisend="0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761"
  local gas_price=""; [[ " $* " == *" --gas-price "* ]] && gas_price="1000"
  local safe_tx_gas=""; [[ " $* " == *" --safe-tx-gas "* ]] && safe_tx_gas="50000"

  if ! ATTEST_JSON="out/producer-tx.json" \
       ATTEST_EXPECTED_SAFE_TX_HASH="$cast_hash" \
       ATTEST_SAFE="$SAFE" ATTEST_NONCE="$NONCE" ATTEST_CHAIN_ID="$chain" \
       ATTEST_SAFE_VERSION="$version" ATTEST_MULTISEND="$multisend" \
       ATTEST_FORCE_MULTISEND="$force" \
       ATTEST_GAS_PRICE="$gas_price" ATTEST_SAFE_TX_GAS="$safe_tx_gas" \
       forge test --root "$ROOT" --match-contract AttestTest -q >"$TMP/forge.log" 2>&1; then
    fail "$label"$'\n'"$(sed 's/^/      /' "$TMP/forge.log")"
    return
  fi
  assert_eq "$label" "$(tr 'A-Z' 'a-z' <"$ROOT/out/solidity-safe-tx-hash.txt")" "$cast_hash"
}

cross_check "flat SafeTx"                     safe-tx-single.json
cross_check "Frax Transaction Builder batch"  tx-builder-frax-optimism.json
cross_check "the same batch, re-stamped"      tx-builder-frax-optimism-restamped.json
cross_check "single-transaction batch"        tx-builder-single.json
cross_check "single-transaction batch, forced multiSend" \
                                              tx-builder-single.json --batch-mode multisend
cross_check "bare transaction array"          tx-array.json --chain-id 1
cross_check "batch declaring its own Safe"    tx-builder-self-binding.json
cross_check "non-zero gas fields from config" tx-builder-frax-optimism.json --gas-price 1000 --safe-tx-gas 50000
cross_check "Safe 1.4.1 MultiSendCallOnly"    tx-builder-frax-optimism.json --safe-version 1.4.1
cross_check "explicit MultiSend, inner delegatecall" \
                                              tx-builder-delegatecall.json --multisend 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761

# The pinned hash for the Frax batch, restated here so a change to *either*
# implementation has to be a deliberate edit to this file.
assert_eq "Frax batch hashes to the pinned value" \
  "$(safe_tx_hash "$canon_frax")" \
  "0xa55af81f3e8e946ba3989ba04fe1fa0685a104114c479e05f0367bba8c712680"

# --------------------------------------------------------------- nested Safes

group "nested.sh: the approval a child Safe sends"

NESTED="$ROOT/lib/nested.sh"
PARENT_HASH="0x6dadc73a833c7960871e229102e841631c21a2c4804ab190432fec57ebacce57"
CHILD="0x2222AA22bb22CC22dd22ee22fF220022110022FF"

nested() { bash "$NESTED" --parent-safe "$SAFE" --parent-hash "$PARENT_HASH" \
             --child-safe "$CHILD" --child-nonce 7 --chain-id 1 "$@"; }
nested >"$TMP/child.json"

assert_eq "the approval is sent to the parent Safe" \
  "$(jq -r .to "$TMP/child.json")" "${SAFE,,}"
assert_eq "…and signed by the child" \
  "$(jq -r .safe "$TMP/child.json")" "${CHILD,,}"
assert_eq "…as a plain zero-value CALL" \
  "$(jq -r '[.value, .operation] | join(" ")' "$TMP/child.json")" "0 0"
assert_eq "…carrying approveHash(parentHash)" \
  "$(jq -r .data "$TMP/child.json")" "0xd4d9bdcd${PARENT_HASH#0x}"
# Same value the Solidity side pins, so the two constructions agree.
assert_eq "the approval hashes to the pinned value" \
  "$(safe_tx_hash "$TMP/child.json")" \
  "0x73c63c06ac272032873f01cc1a80394bda911d061501699ad598f56d03313105"

assert_contains "a Safe cannot approve on itself" \
  "$(bash "$NESTED" --parent-safe "$SAFE" --parent-hash "$PARENT_HASH" --child-safe "$SAFE" \
       --child-nonce 7 --chain-id 1 2>&1 >/dev/null)" "the same Safe"
# Solidity rejects chainId 0, so accepting it here would produce a hash the
# cross-check could never match.
assert_contains "chain id 0 is refused, as it is on the Solidity side" \
  "$(bash "$NESTED" --parent-safe "$SAFE" --parent-hash "$PARENT_HASH" --child-safe "$CHILD" \
       --child-nonce 7 --chain-id 0 2>&1 >/dev/null)" "must be a positive integer"
assert_contains "a malformed parent hash is refused" \
  "$(bash "$NESTED" --parent-safe "$SAFE" --parent-hash 0xdead --child-safe "$CHILD" \
       --child-nonce 7 --chain-id 1 2>&1 >/dev/null)" "must be a 32-byte hash"

# ------------------------------------------------------------ 3. end-to-end run

group "attest.sh: end-to-end against a batch-emitting producer"

PRODUCER="$TMP/producer"
mkdir -p "$PRODUCER/script"
cat >"$PRODUCER/foundry.toml" <<'EOF'
[profile.default]
src = "script"
script = "script"
out = "forge-out"
libs = []
solc = "0.8.28"
fs_permissions = [{ access = "read-write", path = "./out" }]
EOF
# A miniature stand-in for FraxFinance's SafeTxHelper: same output shape, and the
# same volatile `createdAt` stamp that makes a byte-exact sha256 useless.
cat >"$PRODUCER/script/BuildBatch.s.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface Vm {
    function toString(address value) external pure returns (string memory);
    function toString(uint256 value) external pure returns (string memory);
    function toString(bytes calldata value) external pure returns (string memory);
    function projectRoot() external view returns (string memory);
    function createDir(string calldata path, bool recursive) external;
    function writeFile(string calldata path, string calldata data) external;
}

contract BuildBatch {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external {
        address token = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        bytes memory a = abi.encodeWithSignature("approve(address,uint256)", address(0xBEEF), 1e6);
        bytes memory b = abi.encodeWithSignature("transfer(address,uint256)", address(0xDEAD), 1e6);

        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": 1,\n  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ',\n  "meta": { "name": "Transactions Batch", "description": "" },\n  "transactions": [\n',
            '    { "to": "', vm.toString(token), '", "value": "0", "data": "', vm.toString(a), '", "operation": "0" },\n',
            '    { "to": "', vm.toString(token), '", "value": "0", "data": "', vm.toString(b), '", "operation": "0" }\n',
            "  ]\n}\n"
        );

        string memory outDir = string.concat(vm.projectRoot(), "/out");
        vm.createDir(outDir, true);
        vm.writeFile(string.concat(outDir, "/batch.json"), json);
    }
}
EOF
printf 'out/\nforge-out/\ncache/\n' >"$PRODUCER/.gitignore"
(
  cd "$PRODUCER"
  git init --quiet
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t commit --quiet -m "batch producer"
) >/dev/null 2>&1
PRODUCER_COMMIT=$(git -C "$PRODUCER" rev-parse HEAD)

# Derive the expectations the way an operator would the first time round.
(cd "$PRODUCER" && forge script script/BuildBatch.s.sol:BuildBatch >/dev/null 2>&1)
E2E_CANON="$TMP/e2e-canonical.json"
bash "$NORMALIZE" --input "$PRODUCER/out/batch.json" --safe "$SAFE" --nonce 7 >"$E2E_CANON" 2>/dev/null
E2E_SHA=$(canonical_sha <"$E2E_CANON")
E2E_HASH=$(safe_tx_hash "$E2E_CANON")

write_config() { # <path> <canonical sha> <expected hash>
  cat >"$1" <<EOF
producer_repo   = "file://$PRODUCER"
producer_commit = "$PRODUCER_COMMIT"
producer_setup  = ""
producer_script = "script/BuildBatch.s.sol:BuildBatch"
output_path     = "out/batch.json"
input_format    = "auto"
batch_mode      = "auto"
safe_version    = "1.3.0"
expected_output_sha256    = ""
expected_canonical_sha256 = "$2"
expected_safe_tx_hash     = "$3"
safe_network = ""
safe_address = "$SAFE"
safe_nonce   = "7"
EOF
}

write_config "$TMP/e2e.toml" "$E2E_SHA" "$E2E_HASH"
e2e_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e.toml" 2>&1)
e2e_rc=$?
if [[ $e2e_rc -eq 0 ]]; then pass "a correct claim is ATTESTED"
else fail "a correct claim is ATTESTED"$'\n'"$(sed 's/^/      /' <<<"$e2e_out")"; fi
assert_contains "…and says so" "$e2e_out" "ATTESTED"
assert_contains "…reporting the detected format" "$e2e_out" "format   : tx-builder"
assert_contains "…and the inner transaction count" "$e2e_out" "inner tx : 2"
assert_contains "…with Solidity agreeing with cast" "$e2e_out" "Solidity agrees with cast"

# The producer stamps a wall-clock `createdAt`, so the raw bytes drift between
# runs while the canonical digest does not. That is the point of the extra pin.
sleep 1
(cd "$PRODUCER" && forge script script/BuildBatch.s.sol:BuildBatch >/dev/null 2>&1)
assert_eq "the canonical digest survives a re-run" \
  "$(bash "$NORMALIZE" --input "$PRODUCER/out/batch.json" --safe "$SAFE" --nonce 7 2>/dev/null | canonical_sha)" \
  "$E2E_SHA"

write_config "$TMP/e2e-bad-hash.toml" "$E2E_SHA" \
  "0x0000000000000000000000000000000000000000000000000000000000000000"
bad_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-bad-hash.toml" 2>&1)
bad_rc=$?
if [[ $bad_rc -ne 0 ]]; then pass "a wrong expected_safe_tx_hash is NOT ATTESTED"
else fail "a wrong expected_safe_tx_hash was accepted"; fi
assert_contains "…and says which check failed" "$bad_out" "NOT ATTESTED"

write_config "$TMP/e2e-bad-sha.toml" "deadbeef" "$E2E_HASH"
sha_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-bad-sha.toml" 2>&1)
sha_rc=$?
if [[ $sha_rc -ne 0 ]]; then pass "a wrong canonical sha256 is NOT ATTESTED"
else fail "a wrong canonical sha256 was accepted"; fi
assert_contains "…naming the canonical digest" "$sha_out" "canonical sha256 mismatch"

# Binding the same batch to a different nonce must change the transaction, and
# therefore break a claim pinned to the old one.
sed 's/^safe_nonce.*/safe_nonce   = "8"/' "$TMP/e2e.toml" >"$TMP/e2e-nonce.toml"
nonce_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-nonce.toml" 2>&1)
nonce_rc=$?
if [[ $nonce_rc -ne 0 ]]; then pass "re-binding the batch to another nonce is NOT ATTESTED"
else fail "a nonce change went undetected"; fi

# With nothing pinned, cast agreeing with Solidity is the only check left, and
# that ties the output to nothing anyone reviewed.
write_config "$TMP/e2e-unpinned.toml" "" ""
unpinned_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-unpinned.toml" --json 2>"$TMP/unpinned.err")
unpinned_rc=$?
if [[ $unpinned_rc -ne 0 ]]; then pass "a claim with no expected hash pinned is NOT ATTESTED"
else fail "a claim with no expected hash pinned was accepted"; fi
assert_eq "…and --json says attested is false" "$(jq -r .attested <<<"$unpinned_out")" "false"
assert_contains "…naming the reason" "$(cat "$TMP/unpinned.err")" "no expected hash pinned"
assert_eq "…while still reporting the hash to pin" "$(jq -r .hashes.safe_tx <<<"$unpinned_out")" "$E2E_HASH"

write_config "$TMP/e2e-hash-only.toml" "" "$E2E_HASH"
if bash "$ROOT/attest.sh" --config "$TMP/e2e-hash-only.toml" >/dev/null 2>&1; then
  pass "pinning expected_safe_tx_hash alone is enough to attest"
else fail "pinning expected_safe_tx_hash alone is enough to attest"; fi

group "attest.sh: an output file committed at the pinned commit"

# Producers such as frax-oft-upgradeable commit their generated JSON, and some
# write it only conditionally. The committed copy here is tampered: it moves the
# transfer to 0xBAD. Only a file the script itself wrote may be attested.
STALE="$TMP/stale-producer"
mkdir -p "$STALE/script" "$STALE/out"
cp "$PRODUCER/foundry.toml" "$STALE/foundry.toml"
cat >"$STALE/script/Committed.s.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface Vm {
    function projectRoot() external view returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
}

contract NoWrite {
    function run() external {}
}

contract Write {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external {
        vm.writeFile(
            string.concat(vm.projectRoot(), "/out/committed.json"),
            '{"version":"1.0","chainId":1,"transactions":[{"to":"0x000000000000000000000000000000000000dEaD","value":"1","data":"0x","operation":"0"}]}\n'
        );
    }
}
EOF
printf '{"version":"1.0","chainId":1,"transactions":[{"to":"0x0000000000000000000000000000000000000BAD","value":"1","data":"0x","operation":"0"}]}\n' \
  >"$STALE/out/committed.json"
printf 'forge-out/\ncache/\n' >"$STALE/.gitignore"
(
  cd "$STALE"
  git init --quiet
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t commit --quiet -m "producer with a committed output"
) >/dev/null 2>&1

stale_config() { # <path> <script contract> <json to pin from>
  local canon="$TMP/stale-canonical.json"
  bash "$NORMALIZE" --input "$3" --safe "$SAFE" --nonce 7 >"$canon" 2>/dev/null
  sed -e "s|^producer_repo .*|producer_repo   = \"file://$STALE\"|" \
      -e "s|^producer_commit .*|producer_commit = \"$(git -C "$STALE" rev-parse HEAD)\"|" \
      -e "s|^producer_script .*|producer_script = \"script/Committed.s.sol:$2\"|" \
      -e "s|^output_path .*|output_path     = \"out/committed.json\"|" \
      -e "s|^expected_canonical_sha256 .*|expected_canonical_sha256 = \"$(canonical_sha <"$canon")\"|" \
      -e "s|^expected_safe_tx_hash .*|expected_safe_tx_hash     = \"$(safe_tx_hash "$canon")\"|" \
      "$TMP/e2e.toml" >"$1"
}

# Pinned from the committed file, as an operator's first run would have done.
stale_config "$TMP/stale.toml" NoWrite "$STALE/out/committed.json"
stale_out=$(bash "$ROOT/attest.sh" --config "$TMP/stale.toml" 2>&1)
if [[ $? -ne 0 ]]; then pass "a committed output the script did not write is not attested"
else fail "a committed output the script did not write was attested"; fi
assert_contains "…saying the script did not produce it" "$stale_out" "script did not produce expected output"

# Clearing the path must not break a script that does write it: the
# regenerated file, not the committed one, is what gets attested.
printf '{"version":"1.0","chainId":1,"transactions":[{"to":"0x000000000000000000000000000000000000dEaD","value":"1","data":"0x","operation":"0"}]}\n' \
  >"$TMP/regenerated.json"
stale_config "$TMP/regen.toml" Write "$TMP/regenerated.json"
regen_out=$(bash "$ROOT/attest.sh" --config "$TMP/regen.toml" 2>&1)
if [[ $? -eq 0 ]]; then pass "a committed output the script rewrites is attested as rewritten"
else fail "a committed output the script rewrites is attested as rewritten"$'\n'"$(sed 's/^/      /' <<<"$regen_out")"; fi

group "attest.sh: the claim is read one way only"

claim_err() { # <config> -> combined output; the run must fail
  local out
  out=$(bash "$ROOT/attest.sh" --config "$1" 2>&1) && echo "UNEXPECTED SUCCESS"
  printf '%s' "$out"
}

{ cat "$TMP/e2e.toml"; echo 'expected_safe_tx_hash = "0x00"'; } >"$TMP/dup.toml"
assert_contains "a key set twice is refused" "$(claim_err "$TMP/dup.toml")" \
  "key set more than once: expected_safe_tx_hash"

{ cat "$TMP/e2e.toml"; echo '[extra]'; } >"$TMP/table.toml"
assert_contains "a [table] header is refused" "$(claim_err "$TMP/table.toml")" \
  "[table] headers are not supported"

sed "s|^producer_commit .*|producer_commit = \"${PRODUCER_COMMIT:0:12}\"|" "$TMP/e2e.toml" >"$TMP/short.toml"
assert_contains "an abbreviated producer_commit is refused" "$(claim_err "$TMP/short.toml")" \
  "producer_commit must be a full lowercase commit SHA"

sed 's|^producer_commit .*|producer_commit = "--orphan=x"|' "$TMP/e2e.toml" >"$TMP/opt.toml"
assert_contains "a producer_commit shaped like a git option is refused" "$(claim_err "$TMP/opt.toml")" \
  "producer_commit must be a full lowercase commit SHA"

sed 's|^output_path .*|output_path     = "out/../../batch.json"|' "$TMP/e2e.toml" >"$TMP/dotdot.toml"
assert_contains "an output_path with '..' is refused" "$(claim_err "$TMP/dotdot.toml")" \
  "output_path must be relative"

# A producer that commits its output directory as a symlink to elsewhere: the
# file there must be neither deleted nor attested.
LINKED="$TMP/linked-producer"
mkdir -p "$LINKED" "$TMP/outside"
cp -r "$PRODUCER/script" "$PRODUCER/foundry.toml" "$LINKED/"
ln -s "$TMP/outside" "$LINKED/out"
echo keep >"$TMP/outside/batch.json"
(
  cd "$LINKED"
  git init --quiet
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t commit --quiet -m "symlinked out/"
) >/dev/null 2>&1
sed -e "s|^producer_repo .*|producer_repo   = \"file://$LINKED\"|" \
    -e "s|^producer_commit .*|producer_commit = \"$(git -C "$LINKED" rev-parse HEAD)\"|" \
    "$TMP/e2e.toml" >"$TMP/linked.toml"
assert_contains "an output_path behind a symlink out of the clone is refused" \
  "$(claim_err "$TMP/linked.toml")" "output_path resolves outside the producer repo"
assert_eq "…and the file it points at is left alone" "$(cat "$TMP/outside/batch.json")" "keep"

group "attest.sh: a nested claim"

cat "$TMP/e2e.toml" >"$TMP/e2e-nested.toml"
cat >>"$TMP/e2e-nested.toml" <<EOF
child_safe    = "$CHILD"
child_nonce   = "7"
child_network = ""
expected_child_safe_tx_hash = ""
EOF
nested_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-nested.toml" 2>&1)
nested_rc=$?
if [[ $nested_rc -eq 0 ]]; then pass "a nested claim is ATTESTED"
else fail "a nested claim is ATTESTED"$'\n'"$(sed 's/^/      /' <<<"$nested_out")"; fi
assert_contains "…reporting the child and its nonce" "$nested_out" "child    : $CHILD nonce 7"
assert_contains "…the hash it approves" "$nested_out" "approves : $E2E_HASH"
assert_contains "…and the hash its owners sign" "$nested_out" "signs    : 0x"
assert_contains "…with Solidity agreeing on the approval" "$nested_out" "Solidity agrees with cast on the approval"
# The parent hash binds the parent nonce and approveHash stores only a flag, so a
# stale parent nonce voids every approval silently. Say so in the verdict.
assert_contains "…and states the expiry condition" "$nested_out" "valid only while"

# The approval is derived, so pinning a wrong one must fail like any other pin.
sed 's|^expected_child_safe_tx_hash = ""|expected_child_safe_tx_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"|' \
  "$TMP/e2e-nested.toml" >"$TMP/e2e-nested-bad.toml"
bad_nested=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-nested-bad.toml" 2>&1)
if [[ $? -ne 0 ]]; then pass "a wrong expected_child_safe_tx_hash is NOT ATTESTED"
else fail "a wrong nested pin was accepted"; fi
assert_contains "…naming the nested pin" "$bad_nested" "expected_child_safe_tx_hash"

# A child bound to a different nonce is a different transaction.
sed 's|^child_nonce   = "7"|child_nonce   = "8"|' "$TMP/e2e-nested.toml" >"$TMP/e2e-nonce8.toml"
assert_ne "re-binding the approval to another child nonce changes what is signed" \
  "$(bash "$ROOT/attest.sh" --config "$TMP/e2e-nested.toml" 2>&1 | grep -oE 'signs    : 0x[a-f0-9]{64}')" \
  "$(bash "$ROOT/attest.sh" --config "$TMP/e2e-nonce8.toml" 2>&1 | grep -oE 'signs    : 0x[a-f0-9]{64}')"

# ------------------------------------------------------------ propose.sh

group "propose.sh: signing and submission"

# A stand-in for curl that serves canned Transaction Service responses from
# $STUB/safe.json and $STUB/queue.json, answers every POST with 201, and logs
# each request so a test can assert what was (or was not) sent.
STUB="$TMP/stub"
mkdir -p "$STUB/bin"
cat >"$STUB/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" method=GET body="" url="" auth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    -w|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$method $url" >>"$STUB/log"
[[ -n "$auth" ]] && echo "$auth" >>"$STUB/auth"
case "$method $url" in
  "GET "*/v1/safes/*)                  cp "$STUB/safe.json" "$out"; cat "$STUB/safe.status" 2>/dev/null || printf 200 ;;
  "GET "*/multisig-transactions/\?*)   cp "$STUB/queue.json" "$out"; printf 200 ;;
  POST*) cp "$body" "$STUB/posted.json"; echo '{}' >"$out"; printf 201 ;;
  *) printf 404 ;;
esac
EOF
chmod +x "$STUB/bin/curl"

# Anvil's well-known dev keys: test values only.
OWNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OTHER_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OTHER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
OTHER_HASH=0x1111111111111111111111111111111111111111111111111111111111111111

stub_state() { # <safe nonce> <queue results json> [owners json]
  rm -f "$STUB/log" "$STUB/auth" "$STUB/posted.json" "$STUB/safe.status"
  jq -n --argjson n "$1" --argjson o "${3:-[\"$OWNER\"]}" '{nonce: $n, owners: $o}' >"$STUB/safe.json"
  jq -n --argjson r "$2" '{count: ($r | length), results: $r}' >"$STUB/queue.json"
}
queued() { # <hash> <confirming owner...>
  local h="$1"; shift
  jq -n --arg h "$h" '[{safeTxHash: $h, confirmations: ($ARGS.positional | map({owner: .}))}]' --args "$@"
}
propose() { # <canonical> <hash> <pk> -> stdout of propose.sh, stderr in $TMP/propose.err
  PATH="$STUB/bin:$PATH" STUB="$STUB" SAFE_TX_SERVICE_URL=https://stub.invalid/tx-service/eth \
  SAFE_API_KEY=test-key \
    bash "$ROOT/lib/propose.sh" --canonical "$1" --hash "$2" --network ethereum -- --private-key "$3" \
    2>"$TMP/propose.err"
}
posts() { grep -c '^POST' "$STUB/log" 2>/dev/null || true; }

stub_state 7 '[]'
out=$(propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK")
assert_contains "an empty queue at the nonce is proposed" "$out" "PROPOSE_ACTION=proposed"
assert_contains "…to the v2 propose endpoint of the checksummed Safe" "$(cat "$STUB/log")" \
  "POST https://stub.invalid/tx-service/eth/api/v2/safes/$SAFE/multisig-transactions/"
assert_eq "…carrying the attested hash" "$(jq -r .contractTransactionHash "$STUB/posted.json")" "$E2E_HASH"
assert_eq "…and the signer as sender" "$(jq -r .sender "$STUB/posted.json")" "$OWNER"
assert_eq "…with operation and nonce as numbers" \
  "$(jq -c '[.operation, .nonce] | map(type)' "$STUB/posted.json")" '["number","number"]'
if cast wallet verify --address "$OWNER" --no-hash "$E2E_HASH" \
     "$(jq -r .signature "$STUB/posted.json")" >/dev/null 2>&1; then
  pass "…whose EIP-712 typed-data signature recovers over the derived hash"
else fail "…whose EIP-712 typed-data signature recovers over the derived hash"; fi
assert_contains "…sending the API key as a Bearer token" "$(cat "$STUB/auth")" "Authorization: Bearer test-key"

# A flat SafeTx on another chain and operation: cast's typed-data hash must still
# equal derive.sh's, or propose.sh refuses after signing.
single_canon="$TMP/single-canon.json"
bash "$NORMALIZE" --input "$FIX/safe-tx-single.json" >"$single_canon" 2>/dev/null
stub_state "$(jq -r .nonce "$single_canon")" '[]'
out=$(propose "$single_canon" "$(safe_tx_hash "$single_canon")" "$OWNER_PK")
assert_contains "a flat SafeTx signs over the same hash derive.sh computes" "$out" "PROPOSE_ACTION=proposed"

stub_state 7 "$(queued "$E2E_HASH" "$OTHER")"
out=$(propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK")
assert_contains "the same hash already queued gets a confirmation" "$out" "PROPOSE_ACTION=confirmed"
assert_contains "…posted to its confirmations endpoint" "$(cat "$STUB/log")" \
  "POST https://stub.invalid/tx-service/eth/api/v1/multisig-transactions/$E2E_HASH/confirmations/"
assert_eq "…carrying only the signature" "$(jq -c keys "$STUB/posted.json")" '["signature"]'

stub_state 7 "$(queued "$E2E_HASH" "${OWNER,,}")"
out=$(propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK")
assert_contains "a signer who already confirmed is not asked again" "$out" "PROPOSE_ACTION=already-confirmed"
assert_eq "…and nothing is posted" "$(posts)" "0"

stub_state 7 "$(queued "$OTHER_HASH" "$OTHER")"
if propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK" >/dev/null; then
  fail "a different transaction queued at the nonce was ignored"
else pass "a different transaction queued at the nonce is refused"; fi
assert_contains "…naming it" "$(cat "$TMP/propose.err")" "$OTHER_HASH"
assert_eq "…and nothing is posted" "$(posts)" "0"

stub_state 7 '[]'
if propose "$E2E_CANON" "$E2E_HASH" "$OTHER_PK" >/dev/null; then
  fail "a non-owner signer was accepted"
else pass "a signer who is not an owner is refused"; fi
assert_contains "…saying why" "$(cat "$TMP/propose.err")" "$OTHER is not an owner"
assert_eq "…and nothing is posted" "$(posts)" "0"

stub_state 8 '[]'
if propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK" >/dev/null; then
  fail "a used nonce was accepted"
else pass "a nonce the Safe has already used is refused"; fi
assert_contains "…saying why" "$(cat "$TMP/propose.err")" "nonce 7 has been used"

# The service is untrusted: a value it returns is checked against its expected
# shape before bash evaluates or prints it. Arithmetic on a raw string would
# expand a command substitution in an array subscript.
stub_state '"nonce[$(touch '"$TMP"'/pwned)]"' '[]'
if propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK" >/dev/null; then
  fail "a non-numeric nonce from the service was accepted"
else pass "a non-numeric nonce from the service is refused"; fi
assert_eq "…without evaluating it" "$(ls "$TMP/pwned" 2>/dev/null)" ""
assert_contains "…saying why" "$(cat "$TMP/propose.err")" "malformed nonce"

# Escape sequences could rewrite the hashes already on screen.
ESC=$'\e'
stub_state 7 "$(queued "0xab${ESC}[2K${ESC}[1Aspoofed" "$OTHER")"
if propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK" >/dev/null; then
  fail "a malformed queued hash from the service was accepted"
else pass "a malformed queued hash from the service is refused"; fi
assert_contains "…saying why" "$(cat "$TMP/propose.err")" "malformed safeTxHash"
assert_eq "…without printing escape sequences" "$(grep -c "$ESC" "$TMP/propose.err")" "0"

stub_state 7 '[]'
printf '%s' "${ESC}[2Kerror" >"$STUB/safe.json"; printf 500 >"$STUB/safe.status"
propose "$E2E_CANON" "$E2E_HASH" "$OWNER_PK" >/dev/null
assert_contains "an error response is reported" "$(cat "$TMP/propose.err")" "HTTP 500"
assert_eq "…without printing escape sequences" "$(grep -c "$ESC" "$TMP/propose.err")" "0"

stub_state 7 '[]'
if propose "$E2E_CANON" "$OTHER_HASH" "$OWNER_PK" >/dev/null; then
  fail "a canonical file that does not hash to --hash was accepted"
else pass "a canonical file that does not hash to --hash is refused"; fi
assert_contains "…saying why" "$(cat "$TMP/propose.err")" "not the attested $OTHER_HASH"
assert_eq "…before any request" "$(cat "$STUB/log" 2>/dev/null)" ""

# Without an override the network name picks the service, and it must agree
# with the transaction's own chain id.
rm -f "$STUB/log"
if PATH="$STUB/bin:$PATH" STUB="$STUB" bash "$ROOT/lib/propose.sh" --canonical "$E2E_CANON" \
     --hash "$E2E_HASH" --network optimism -- --private-key "$OWNER_PK" 2>"$TMP/propose.err" >/dev/null; then
  fail "a network on another chain was accepted"
else pass "a network whose chain differs from the transaction is refused"; fi
assert_contains "…saying why" "$(cat "$TMP/propose.err")" "is chain 10 but the transaction is for chain 1"

stub_state 7 '[]'
PATH="$STUB/bin:$PATH" STUB="$STUB" bash "$ROOT/lib/propose.sh" --canonical "$E2E_CANON" \
  --hash "$E2E_HASH" --network ethereum -- --private-key "$OWNER_PK" >/dev/null 2>&1
assert_eq "a network name resolves through safe_hashes.sh's base URL" \
  "$(head -1 "$STUB/log")" "GET https://api.safe.global/tx-service/eth/api/v1/safes/$SAFE/"

group "attest.sh --propose: only an attested transaction is sent"

sed 's/^safe_network.*/safe_network = "ethereum"/' "$TMP/e2e-unpinned.toml" >"$TMP/e2e-propose-unpinned.toml"
rm -f "$STUB/log"
gate_out=$(PATH="$STUB/bin:$PATH" STUB="$STUB" bash "$ROOT/attest.sh" \
  --config "$TMP/e2e-propose-unpinned.toml" --json --propose -- --private-key "$OWNER_PK" 2>"$TMP/gate.err")
assert_eq "an unattested claim is NOT ATTESTED under --propose" "$(jq -r .attested <<<"$gate_out")" "false"
assert_contains "…saying it did not propose" "$(cat "$TMP/gate.err")" "not proposing: the offline checks did not attest"
assert_eq "…without contacting the service" "$(posts)" "0"
assert_eq "…and reports no proposal" "$(jq -r .proposal <<<"$gate_out")" "null"

# An attested claim reaches propose.sh with the canonical form and hash it
# checked. --propose implies --require-live, and the stub serves no live data
# to safe_hashes.sh, so the run still ends NOT ATTESTED on the live check.
sed 's/^safe_network.*/safe_network = "ethereum"/' "$TMP/e2e.toml" >"$TMP/e2e-propose.toml"
stub_state 7 '[]'
sent_out=$(PATH="$STUB/bin:$PATH" STUB="$STUB" SAFE_TX_SERVICE_URL=https://stub.invalid/tx-service/eth \
  bash "$ROOT/attest.sh" --config "$TMP/e2e-propose.toml" --json --propose -- --private-key "$OWNER_PK" \
  2>"$TMP/sent.err")
assert_eq "an attested claim is proposed" "$(jq -c .proposal <<<"$sent_out")" \
  "{\"action\":\"proposed\",\"sender\":\"$OWNER\"}"
assert_eq "…as the hash attest.sh derived" "$(jq -r .contractTransactionHash "$STUB/posted.json")" "$E2E_HASH"
assert_contains "…with an origin naming the producer commit" "$(jq -r .origin "$STUB/posted.json")" \
  "BuildBatch.s.sol:BuildBatch@${PRODUCER_COMMIT:0:12}"
assert_eq "…and the live check is then required" \
  "$(jq -r '.failures[]' <<<"$sent_out")" "Safe Transaction Service unreachable or no tx at nonce 7"

# A flat SafeTx carries its own Safe and nonce, so its claim can attest with
# safe_address and safe_nonce blank. The required live check would then skip,
# and nothing would prove the submission landed.
cat >"$TMP/e2e-propose-flat.toml" <<EOF
producer_repo   = "file://$PRODUCER"
producer_commit = "$PRODUCER_COMMIT"
producer_setup  = "mkdir -p out && cp '$FIX/safe-tx-single.json' out/flat.json"
producer_script = "script/BuildBatch.s.sol:BuildBatch"
output_path     = "out/flat.json"
expected_safe_tx_hash = "$(safe_tx_hash "$single_canon")"
safe_network = "ethereum"
safe_address = ""
safe_nonce   = ""
EOF
rm -f "$STUB/log"
flat_out=$(PATH="$STUB/bin:$PATH" STUB="$STUB" SAFE_TX_SERVICE_URL=https://stub.invalid/tx-service/eth \
  bash "$ROOT/attest.sh" --config "$TMP/e2e-propose-flat.toml" --json --propose -- --private-key "$OWNER_PK" \
  2>"$TMP/flat.err")
assert_eq "a claim without safe_address and safe_nonce is NOT ATTESTED under --propose" \
  "$(jq -r .attested <<<"$flat_out")" "false"
assert_eq "…failing only for the missing fields" "$(jq -r '.failures[]' <<<"$flat_out")" \
  "--propose needs safe_network, safe_address and safe_nonce"$'\n'"safe_network/address/nonce not fully set: live check required"
assert_eq "…without contacting the service" "$(cat "$STUB/log" 2>/dev/null)" ""

# The same gap without --propose: --require-live alone must fail, not skip.
sed '/^safe_network/d' "$TMP/e2e-propose-flat.toml" >"$TMP/e2e-flat.toml"
if bash "$ROOT/attest.sh" --config "$TMP/e2e-flat.toml" >/dev/null 2>&1; then
  pass "a flat claim without safe_network, safe_address and safe_nonce is ATTESTED"
else fail "a flat claim without safe_network, safe_address and safe_nonce is ATTESTED"; fi
flat_live_out=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-flat.toml" --json --require-live 2>/dev/null)
assert_eq "…but NOT ATTESTED under --require-live" "$(jq -r .attested <<<"$flat_live_out")" "false"
assert_eq "…failing only for the skipped live check" "$(jq -r '.failures[]' <<<"$flat_live_out")" \
  "safe_network/address/nonce not fully set: live check required"

if bash "$ROOT/attest.sh" --config "$TMP/e2e.toml" --propose >/dev/null 2>"$TMP/gate.err"; then
  fail "--propose without wallet flags was accepted"
else pass "--propose without wallet flags is refused"; fi
assert_contains "…asking for them" "$(cat "$TMP/gate.err")" "after --, e.g. -- --ledger"

group "attest.sh: the live check reads one queued transaction"

# A stand-in for the curl that safe_hashes.sh calls: the Safe's version, and
# $LIVE/queue.json for its queue at a nonce.
LIVE="$TMP/live"
mkdir -p "$LIVE/bin"
cat >"$LIVE/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${@: -1}" in
  */multisig-transactions/*) cat "$LIVE/queue.json" ;;
  */api/v1/safes/*) echo '{"version":"1.3.0"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$LIVE/bin/curl"
live_tx() { # <canonical> [dataDecoded json] -> one queue entry
  jq -c --argjson d "${2:-null}" '{to, value, data, operation: (.operation | tonumber), safeTxGas,
    baseGas, gasPrice, gasToken, refundReceiver, nonce: (.nonce | tonumber), dataDecoded: $d}' "$1"
}
live_queue() { jq -s '{count: length, results: .}' >"$LIVE/queue.json"; }
live_run() { # <attest.sh args...> -> verdict on stdout, report in $TMP/live.err
  PATH="$LIVE/bin:$PATH" LIVE="$LIVE" bash "$ROOT/attest.sh" --config "$TMP/e2e-propose.toml" --json "$@" \
    2>"$TMP/live.err"
}
# The same batch with its second transfer redirected: a different transaction.
jq '.data |= sub("000000000000000000000000000000000000dead"; "0000000000000000000000000000000000000bad")' \
  "$E2E_CANON" >"$TMP/live-other.json"

live_tx "$E2E_CANON" | live_queue
live_ok=$(live_run --require-live)
assert_eq "the attested transaction queued alone is ATTESTED" "$(jq -r .attested <<<"$live_ok")" "true"
assert_eq "…reporting the live hash" "$(jq -r .hashes.safe_tx_live <<<"$live_ok")" "$E2E_HASH"

{ live_tx "$E2E_CANON"; live_tx "$TMP/live-other.json"; } | live_queue
SECONDS=0
live_two=$(live_run)
assert_eq "a competing transaction at the nonce is NOT ATTESTED, even without --require-live" \
  "$(jq -r .attested <<<"$live_two")" "false"
assert_eq "…naming it" "$(jq -r '.failures[]' <<<"$live_two")" "several transactions are queued at nonce 7"
if (( SECONDS < 30 )); then pass "…without waiting on the tool's index prompt"
else fail "…without waiting on the tool's index prompt (took ${SECONDS}s)"; fi

# Service-provided text lands in the tool's output. A decoded method that forges
# the hash line, with escapes, must neither pass nor reach the terminal raw.
live_tx "$TMP/live-other.json" \
  "$(jq -cn --arg h "$E2E_HASH" '{method: ("x\u001b[2K\nSafe transaction hash: " + $h), parameters: []}')" \
  | live_queue
live_forged=$(live_run --require-live)
assert_eq "a forged hash line in decoded calldata is NOT ATTESTED" "$(jq -r .attested <<<"$live_forged")" "false"
assert_eq "…because two hash lines are not read as one" "$(jq -r '.failures[]' <<<"$live_forged")" \
  "Safe Transaction Service unreachable or no tx at nonce 7"
if grep -q $'\x1b' "$TMP/live.err"; then fail "…and its escape bytes reach the report"
else pass "…and its escape bytes do not reach the report"; fi

group "skills/build-safe-tx: the producer template"

# The skill copies this template into an ops repo and writes claims that pin the
# byte-exact sha256, so its output must be byte-stable. The skill also sets
# safe_address, as a cross-check against the file's own binding; the claim below
# leaves it blank to show that binding holds on its own.
TPL_PRODUCER="$TMP/template-producer"
mkdir -p "$TPL_PRODUCER/script"
cp "$PRODUCER/foundry.toml" "$TPL_PRODUCER/"
cp "$ROOT/skills/build-safe-tx/template.s.sol" "$TPL_PRODUCER/script/BuildSafeTx.s.sol"
printf 'out/\nforge-out/\ncache/\n' >"$TPL_PRODUCER/.gitignore"
(
  cd "$TPL_PRODUCER"
  git init --quiet
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t commit --quiet -m "template producer"
) >/dev/null 2>&1
(cd "$TPL_PRODUCER" && forge script script/BuildSafeTx.s.sol:BuildSafeTx >/dev/null 2>&1)
TPL_SHA1=$(sha256sum <"$TPL_PRODUCER/out/safe-tx.json" | awk '{print $1}')
sleep 1
(cd "$TPL_PRODUCER" && forge script script/BuildSafeTx.s.sol:BuildSafeTx >/dev/null 2>&1)
assert_eq "the template's output is byte-identical across runs" \
  "$(sha256sum <"$TPL_PRODUCER/out/safe-tx.json" | awk '{print $1}')" "$TPL_SHA1"

TPL_CANON="$TMP/template-canonical.json"
bash "$NORMALIZE" --input "$TPL_PRODUCER/out/safe-tx.json" --nonce 7 >"$TPL_CANON" 2>/dev/null
assert_eq "…and binds itself to its Safe" "$(jq -r .safe "$TPL_CANON")" "${SAFE,,}"

cat >"$TMP/template.toml" <<EOF
producer_repo   = "file://$TPL_PRODUCER"
producer_commit = "$(git -C "$TPL_PRODUCER" rev-parse HEAD)"
producer_setup  = ""
producer_script = "script/BuildSafeTx.s.sol:BuildSafeTx"
output_path     = "out/safe-tx.json"
input_format    = "tx-builder"
batch_mode      = "auto"
safe_version    = "1.3.0"
expected_output_sha256    = "$TPL_SHA1"
expected_canonical_sha256 = "$(canonical_sha <"$TPL_CANON")"
expected_safe_tx_hash     = "$(safe_tx_hash "$TPL_CANON")"
safe_network = ""
safe_address = ""
safe_nonce   = "7"
EOF
tpl_out=$(bash "$ROOT/attest.sh" --config "$TMP/template.toml" 2>&1)
if [[ $? -eq 0 ]]; then pass "a claim pinning the template's byte-exact sha256 is ATTESTED"
else fail "a claim pinning the template's byte-exact sha256 is ATTESTED"$'\n'"$(sed 's/^/      /' <<<"$tpl_out")"; fi

# --------------------------------------------------- vendored file integrity
#
# These files feed the hash derivation, so a silent change to either produces a
# confidently wrong answer rather than an error. VENDORED.md is the record of
# what they are meant to be; this asserts the bytes still match it.
group "Vendored files match VENDORED.md"

check_vendored() { # file
  local want got
  # the sha256 recorded under this file's own "## `name`" section
  want=$(sed -n "/^## .$1./,/^## /p" "$ROOT/lib/VENDORED.md" \
         | grep -m1 -oE '\*\*sha256:\*\* .[0-9a-f]{64}' \
         | grep -oE '[0-9a-f]{64}')
  got=$(sha256sum "$ROOT/lib/$1" | awk '{print $1}')
  if [[ -z "$want" ]]; then
    fail "no sha256 recorded in VENDORED.md for $1"
  else
    assert_eq "$1 matches its recorded sha256" "$got" "$want"
  fi
}

check_vendored safe_hashes.sh
check_vendored multisend-exceptions.json

# ------------------------------------------------------------------- verdict

echo
if [[ $FAILED -eq 0 ]]; then
  printf '%s%s%d passed%s\n' "$BOLD" "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%s%d failed%s, %d passed\n' "$BOLD" "$RED" "$FAILED" "$RESET" "$PASS"
  exit 1
fi
