#!/usr/bin/env bash

reader_normalize() { # fixture, format, profile, canonical path, extra normalize flags...
  local fixture="$1" format="$2" profile="$3" canonical="$4"; shift 4
  if ! bash "$NORMALIZE" --input "$FIX/$fixture" --format "$format" --profile "$profile" "$@" >"$canonical" 2>"$TMP/error"; then
    fail "$fixture normalization"
    cat "$TMP/error" >&2
    return 1
  fi
}

reader_reject() { # label, jq mutation, fixture, format, profile
  local label="$1" mutation="$2" fixture="$3" format="$4" profile="${5:-}"
  jq "$mutation" "$FIX/$fixture" >"$TMP/negative.json"
  if bash "$NORMALIZE" --input "$TMP/negative.json" --format "$format" --profile "$profile" "${@:6}" >"$TMP/rejected" 2>"$TMP/error"; then
    fail "$label"
  else pass "$label"; fi
}

reader_cross() { # fixture, format, profile, extra normalize flags...
  local fixture="$1" format="$2" profile="$3"; shift 3
  local canonical="$TMP/reader-canonical.json" hash
  reader_normalize "$fixture" "$format" "$profile" "$canonical" "$@" || return 1
  local force=""; [[ " $* " == *" --batch-mode multisend "* ]] && force=1
  hash=$(bash "$ROOT/lib/derive.sh" "$canonical" | sed -n 's/^SAFE_TX_HASH=//p')
  mkdir -p "$ROOT/out"
  cp "$FIX/$fixture" "$ROOT/out/reader-input.json"
  rm -f "$ROOT/out/solidity-safe-tx-hash.txt"
  if ATTEST_JSON=out/reader-input.json ATTEST_INPUT_FORMAT="$format" ATTEST_INPUT_PROFILE="$profile" \
     ATTEST_EXPECTED_SAFE_TX_HASH="$hash" ATTEST_SAFE="$(jq -r .safe "$canonical")" \
     ATTEST_CHAIN_ID="$(jq -r .chainId "$canonical")" ATTEST_NONCE="$(jq -r .nonce "$canonical")" \
     ATTEST_FORCE_MULTISEND="$force" ATTEST_GAS_PRICE="$(jq -r .gasPrice "$canonical")" \
     ATTEST_SAFE_TX_GAS="$(jq -r .safeTxGas "$canonical")" ATTEST_BASE_GAS="$(jq -r .baseGas "$canonical")" \
     ATTEST_GAS_TOKEN="$(jq -r .gasToken "$canonical")" ATTEST_REFUND_RECEIVER="$(jq -r .refundReceiver "$canonical")" \
     forge test --root "$ROOT" --match-contract AttestTest -q >"$TMP/cross.log" 2>&1; then
    assert_eq "$fixture independent derivation" "$(cat "$ROOT/out/solidity-safe-tx-hash.txt")" "$hash"
  else fail "$fixture independent derivation: $(cat "$TMP/cross.log")"; fi
}

reader_e2e() { # fixture, format, profile, extra normalize flags...
  local fixture="$1" format="$2" profile="$3"; shift 3
  local producer="$TMP/producer-$format" canonical="$TMP/e2e-$format.json" commit hash digest output
  reader_normalize "$fixture" "$format" "$profile" "$canonical" "$@" || return 1
  jq '.nonce = "43"' "$canonical" >"$TMP/second-$format.json"
  mkdir -p "$producer/script"
  cp "$ROOT/foundry.toml" "$producer/foundry.toml"
  sed -i 's/test = "test"/test = "script"/; s/src = "test"/src = "script"/' "$producer/foundry.toml"
  cat >"$producer/script/Build.s.sol" <<EOF
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface Vm { function createDir(string calldata, bool) external; function writeFile(string calldata, string calldata) external; }
contract Build {
  Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
  function run() external {
    vm.createDir("out", true);
    vm.writeFile("out/tx.json", $(jq -Rs . "$FIX/$fixture"));
    vm.writeFile("out/second.json", $(jq -Rs . "$TMP/second-$format.json"));
  }
}
EOF
  printf 'out/\nforge-out/\ncache/\n' >"$producer/.gitignore"
  git -C "$producer" init --quiet
  git -C "$producer" add -A
  git -C "$producer" -c user.name=test -c user.email=test@example.invalid commit --quiet -m 'test: write reader fixture'
  commit=$(git -C "$producer" rev-parse HEAD)
  hash=$(bash "$ROOT/lib/derive.sh" "$canonical" | sed -n 's/^SAFE_TX_HASH=//p')
  digest=$(sha256sum "$canonical" | cut -d' ' -f1)
  cat >"$TMP/e2e-$format.toml" <<EOF
producer_repo = "file://$producer"
producer_commit = "$commit"
producer_script = "script/Build.s.sol:Build"
unclaimed = ["out/second.json"]
output_path = "out/tx.json"
input_format = "$format"
input_profile = "$profile"
safe_address = "$(jq -r .safe "$canonical")"
safe_nonce = "$(jq -r .nonce "$canonical")"
chain_id = "$(jq -r .chainId "$canonical")"
expected_canonical_sha256 = "$digest"
expected_safe_tx_hash = "$hash"
EOF
  output=$(bash "$ROOT/attest.sh" --config "$TMP/e2e-$format.toml" --json 2>"$TMP/e2e.log")
  assert_eq "$format end-to-end with pinned profile" "$(jq -r .attested <<<"$output")" true
  cp "$TMP/e2e-$format.toml" "$TMP/nested-$format.toml"
  printf '\nchild_safe = "0x2222AA22bb22CC22dd22ee22fF220022110022FF"\nchild_nonce = "7"\n' >>"$TMP/nested-$format.toml"
  output=$(bash "$ROOT/attest.sh" --config "$TMP/nested-$format.toml" --json 2>"$TMP/nested.log")
  assert_eq "$format nested approval uses the original producer envelope" "$(jq -r .attested <<<"$output")" true
  cat >"$TMP/mixed-$format.toml" <<EOF
producer_repo = "file://$producer"
producer_commit = "$commit"
[[run]]
script = "script/Build.s.sol:Build"
[run.defaults]
input_format = "$format"
input_profile = "$profile"
[[run.claim]]
output_path = "out/tx.json"
safe_address = "$(jq -r .safe "$canonical")"
safe_nonce = "$(jq -r .nonce "$canonical")"
chain_id = "$(jq -r .chainId "$canonical")"
expected_canonical_sha256 = "$digest"
expected_safe_tx_hash = "$hash"
[[run.claim]]
output_path = "out/second.json"
input_format = "safe-tx"
input_profile = ""
expected_output_sha256 = "$(sha256sum "$TMP/second-$format.json" | cut -d' ' -f1)"
expected_safe_tx_hash = "$(bash "$ROOT/lib/derive.sh" "$TMP/second-$format.json" | sed -n 's/^SAFE_TX_HASH=//p')"
EOF
  output=$(bash "$ROOT/attest.sh" --config "$TMP/mixed-$format.toml" --json 2>"$TMP/mixed.log")
  assert_eq "$format mixes claims without leaking the reader profile" "$(jq -r '[.attested, (.claims | length)] | @tsv' <<<"$output")" $'true\t2'
  local key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  local owner; owner=$(cast wallet address --private-key "$key")
  mkdir -p "$TMP/reader-bin"
  cat >"$TMP/reader-bin/curl" <<'STUB'
#!/usr/bin/env bash
output= method= url= body=
while (( $# )); do
  case "$1" in -o) output="$2"; shift 2;; -X) method="$2"; shift 2;; --data-binary) body="${2#@}"; shift 2;; -H|-w|--max-time) shift 2;; -sS) shift;; *) url="$1"; shift;; esac
done
if [[ "$method" == POST ]]; then cp "$body" "$READER_SUBMITTED"; echo '{}' >"$output"; printf 201
elif [[ "$url" == *multisig-transactions* ]]; then echo '{"count":0,"next":null,"results":[]}' >"$output"; printf 200
else printf '{"nonce":0,"owners":["%s"]}' "$READER_OWNER" >"$output"; printf 200; fi
STUB
  chmod +x "$TMP/reader-bin/curl"
  local preview signed
  preview=$(PATH="$TMP/reader-bin:$PATH" READER_OWNER="$owner" READER_SUBMITTED="$TMP/submitted.json" \
    bash "$ROOT/lib/propose.sh" --canonical "$canonical" --hash "$hash" --network ethereum --preflight -- --private-key "$key" 2>"$TMP/preview.log")
  assert_contains "$format signing preview accepts attested transaction" "$preview" 'PROPOSE_ACTION=proposed'
  signed=$(PATH="$TMP/reader-bin:$PATH" READER_OWNER="$owner" READER_SUBMITTED="$TMP/submitted.json" \
    bash "$ROOT/lib/propose.sh" --canonical "$canonical" --hash "$hash" --network ethereum -- --private-key "$key" 2>"$TMP/sign.log")
  assert_contains "$format signing uses attested transaction" "$signed" 'PROPOSE_ACTION=proposed'
  assert_eq "$format submitted hash is the independent hash" "$(jq -r .contractTransactionHash "$TMP/submitted.json")" "$hash"
}
