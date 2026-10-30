#!/usr/bin/env bash
#
#  forge-attest: prove a Gnosis Safe transaction is exactly the output of a
#                specific Forge script, and was not changed afterwards.
#
#  Given a pinned commit of a "producer" repo, this:
#    1. clones it at that exact commit,
#    2. re-runs its Forge script(s) deterministically, and checks every file
#       a run writes is claimed or listed as unclaimed,               (completeness)
#    3. checks each claimed JSON's sha256 against a pinned value,     (source integrity)
#    4. normalises it into one canonical SafeTx, from any supported
#       Safe JSON shape including a Transaction Builder batch,        (canonical form)
#    5. derives the Safe EIP-712 tx hash two independent ways         (cast + Solidity)
#       and checks both against a pinned expected hash,
#    6. optionally checks that same hash against what is actually
#       queued in the Safe, via the Safe Transaction Service.         (live integrity)
#
#  A flat attest.toml is one claim. One with [[run]] tables holds several runs
#  of the producer, each with a [[run.claim]] per output file (lib/claims.sh).
#
#  With --propose, the attested transactions are also signed with the cast wallet
#  flags given after `--` and submitted to the Safe Transaction Service (proposed,
#  or confirmed if already queued), and the live check is then required. Nothing
#  is signed unless every claim attests and every claim's preflight passes.
#
#  Matching hashes across all layers prove the submitted Safe tx is exactly what
#  the script produced.
#
#  Usage: ./attest.sh [--config attest.toml] [--require-live] [--json] [--keep] [--help]
#                     [--propose -- <cast wallet flags, e.g. --ledger>]
#
#  --json emits a machine-readable verdict on stdout and moves the human report
#  to stderr, so a caller gets both without parsing colours. The exit code is
#  the same either way: 0 attested, 1 not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/status.sh
source "$SCRIPT_DIR/lib/status.sh"

CONFIG="$SCRIPT_DIR/attest.toml"
REQUIRE_LIVE=0
KEEP=0
JSON=0
PROPOSE=0
PROPOSE_WALLET=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --require-live) REQUIRE_LIVE=1; shift ;;
    --json) JSON=1; shift ;;
    --keep) KEEP=1; shift ;;
    --propose) PROPOSE=1; REQUIRE_LIVE=1; shift ;;
    --) shift; PROPOSE_WALLET=("$@"); break ;;
    -h|--help)
      grep -E '^#' "$0" | sed -E 's/^#\??//' | sed -E 's/^ //'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done
if [[ "$PROPOSE" == 1 ]]; then
  (( ${#PROPOSE_WALLET[@]} )) || die "--propose needs the signer's cast wallet flags after --, e.g. -- --ledger"
elif (( ${#PROPOSE_WALLET[@]} )); then
  die "wallet flags after -- are only used with --propose"
fi

# In JSON mode stdout is reserved for the verdict document. Keep a handle on the
# real stdout (fd 3) and point everything the run prints at stderr, so the human
# report still streams to a CI log while stdout stays parseable.
if [[ "$JSON" == 1 ]]; then
  exec 3>&1 1>&2
else
  exec 3>/dev/null
fi

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
for bin in git forge cast jq sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done

WORK="$(mktemp -d)"
cleanup() { [[ "$KEEP" == 1 ]] && { warn "kept workdir: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

# --- load config --------------------------------------------------------------
MODEL="$WORK/model.json"
bash "$SCRIPT_DIR/lib/claims.sh" "$CONFIG" >"$MODEL" || exit 1
layout=$(jq -r .layout "$MODEL")
producer_repo=$(jq -r .producer.producer_repo "$MODEL")
producer_commit=$(jq -r .producer.producer_commit "$MODEL")
producer_setup=$(jq -r .producer.producer_setup "$MODEL")
# Optional pin on the toolchain that re-runs the producer's script. See the
# toolchain step below for why an unrecorded forge version is a real hazard.
expected_forge_version=$(jq -r .producer.expected_forge_version "$MODEL")
n_runs=$(jq '.runs | length' "$MODEL")
n_claims=$(jq '.claims | length' "$MODEL")
cfg()     { jq -r --argjson i "$1" --arg k "$2" '.claims[$i][$k]' "$MODEL"; }
run_cfg() { jq -r --argjson i "$1" --arg k "$2" '.runs[$i][$k]' "$MODEL"; }
claims_of_run() { jq -r --argjson r "$1" '.claims | to_entries[] | select(.value.run == $r) | .key' "$MODEL"; }

# Failures are kept per claim as well as overall, so a multi-claim verdict can
# say which claim each one belongs to. In the flat layout there is one claim and
# the messages stay unprefixed.
FAILURES=()
record_fail() { # <message> [claim index]
  local msg="$1"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$1" >>"$WORK/fail.$2"
    [[ "$layout" == runs ]] && msg="[$(cfg "$2" output_path)] $1"
  fi
  status_dirty
  FAILURES+=("$msg")
  fail "$msg"
}
claim_failed() { [[ -s "$WORK/fail.$1" ]]; }

# live_safe_tx_hash <network> <address> <nonce> <log>
# Prints the hash safe_hashes.sh computes for the transaction queued at <nonce>,
# and leaves its sanitised output in <log>. Returns 2 when several transactions
# are queued there, 1 when no single hash could be read.
live_safe_tx_hash() {
  local hashes
  # With several transactions at one nonce the tool prompts for an index and, on
  # a closed stdin, re-prompts forever. head bounds that output and ends it.
  { timeout 60 bash "$SCRIPT_DIR/lib/safe_hashes.sh" --network "$1" --address "$2" --nonce "$3"
    echo "forge-attest: exit $?"; } </dev/null 2>&1 | head -c 1048576 | printable >"$4" || true
  grep -q 'Several transactions with identical nonce' "$4" && return 2
  tail -1 "$4" | grep -qx 'forge-attest: exit 0' || return 1
  # The output also prints service-provided text (decoded calldata), so take only
  # the tool's own anchored line, and only if there is exactly one.
  hashes=$(grep -oE '^Safe transaction hash: 0x[0-9a-fA-F]{64}$' "$4" || true)
  [[ -n "$hashes" && "$hashes" != *$'\n'* ]] || return 1
  lc "${hashes##* }"
}

echo
step "forge-attest"
printf '    producer : %s\n' "$producer_repo"
printf '    commit   : %s\n' "$producer_commit"
for (( r = 0; r < n_runs; r++ )); do printf '    script   : %s\n' "$(run_cfg "$r" script)"; done
echo

# --- 0. the toolchain that will re-run the script -----------------------------
# Step 2 re-runs `forge script` and step 3 pins its output byte-exactly, so the
# forge build is an input to the claim as much as the producer commit is. Left
# unrecorded, a Foundry upgrade shifts the output bytes and the run fails with
# nothing pointing at the cause. The quickest way back to green is then to blank
# out expected_output_sha256, which throws away the strongest check for an
# unrelated reason. Recording it makes a divergence explain itself. Pinning it is
# opt-in.
step "Toolchain"
forge_version=$(forge --version 2>/dev/null | head -1 | sed -E 's/^forge (Version: )?//')
cast_version=$(cast  --version 2>/dev/null | head -1 | sed -E 's/^cast (Version: )?//')
forge_commit=$(forge --version 2>/dev/null | awk '/Commit SHA:/ {print $3; exit}')
printf '    forge    : %s%s\n' "$forge_version" "${forge_commit:+ ($forge_commit)}"
printf '    cast     : %s\n' "$cast_version"
if [[ -z "$expected_forge_version" ]]; then
  warn "no expected_forge_version pinned: output bytes may move with the toolchain"
elif [[ "$forge_version" == "$expected_forge_version" ]]; then
  ok "matches pinned expected_forge_version"
else
  record_fail "forge version ($forge_version) != pinned expected_forge_version ($expected_forge_version)"
fi
echo

# --- 1. clone the producer at the pinned commit -------------------------------
step "Cloning producer at pinned commit"
git clone --quiet -- "$producer_repo" "$WORK/repo" || die "git clone failed: $producer_repo"
git -C "$WORK/repo" checkout --quiet "$producer_commit" 2>/dev/null \
  || die "commit not found in producer repo: $producer_commit"
actual_commit=$(git -C "$WORK/repo" rev-parse HEAD)
[[ "$actual_commit" == "$producer_commit" ]] \
  || die "checked-out HEAD ($actual_commit) != pinned commit ($producer_commit)"
ok "checked out $actual_commit"

# The producer's own solc pin, if it has one. A repo that leaves solc unset gets
# whatever the local foundry resolves, which is the same reproducibility hole one
# level down. Better to surface it in the verdict than to discover it later.
producer_solc=""
if [[ -f "$WORK/repo/foundry.toml" ]]; then
  producer_solc=$(toml_get "$WORK/repo/foundry.toml" solc)
  [[ -n "$producer_solc" ]] || producer_solc=$(toml_get "$WORK/repo/foundry.toml" solc_version)
fi
if [[ -n "$producer_solc" ]]; then
  ok "producer pins solc $producer_solc"
else
  warn "producer does not pin solc: its build depends on the local toolchain"
fi

# --- 2. run the producer's Forge script(s) ------------------------------------
step "Running the Forge script"
repo_real=$(cd "$WORK/repo" && pwd -P)
# A directory the producer commits as a symlink can point output_path outside the
# clone, where the rm below would delete a file and the read would attest one the
# script never wrote.
inside_clone() { # <path relative to the clone>
  local dir="$WORK/repo/$(dirname "$1")"
  [[ -d "$dir" ]] || return 0
  [[ "$(cd "$dir" && pwd -P)/" == "$repo_real/"* ]] \
    || die "output_path resolves outside the producer repo: $1"
}
# Every file in the clone but .git, with mtime and size, so a rewrite of the same
# bytes still shows as written.
snapshot() { # <file>
  (cd "$WORK/repo" && find . -path ./.git -prune -o -type f -printf '%P\t%T@\t%s\n') \
    | LC_ALL=C sort >"$1"
}
written_between() { # <before> <after>: paths new or changed
  LC_ALL=C comm -13 "$1" "$2" | cut -f1 | LC_ALL=C sort -u
}
# The producer's setup and script need no Safe API credentials.
in_clone() { (cd "$WORK/repo" && unset SAFE_API_KEY && "$@"); }

mapfile -t declared < <(jq -r '.claims[].output_path, .runs[].unclaimed[]' "$MODEL")
for p in "${declared[@]}"; do inside_clone "$p"; done
# A copy committed at the pinned commit would otherwise pass for the script's
# output when the script exits 0 without writing it.
for p in "${declared[@]}"; do rm -f "$WORK/repo/$p"; done

snapshot "$WORK/snap.setup.before"
if [[ -n "$producer_setup" ]]; then
  echo "    setup: $producer_setup"
  in_clone bash -c "$producer_setup" || die "producer_setup failed"
fi
snapshot "$WORK/snap.setup.after"
# Setup runs after the delete, so a file it writes at a claimed path is still
# attested, as the reviewed claim asks. It counts as the first run's output.
written_between "$WORK/snap.setup.before" "$WORK/snap.setup.after" >"$WORK/written.setup"

# Forge's own build and record directories are not outputs.
forge_dirs=$(in_clone forge config --json 2>/dev/null | jq -r '.out, .cache_path, .broadcast' 2>/dev/null) \
  || forge_dirs=$'out\ncache\nbroadcast'
mapfile -t forge_dirs <<<"$forge_dirs"
for k in "${!forge_dirs[@]}"; do
  forge_dirs[k]="${forge_dirs[k]#"$repo_real"/}"; forge_dirs[k]="${forge_dirs[k]#"$WORK/repo"/}"
done
broadcast_dir="${forge_dirs[2]:-broadcast}"

RUN_CHAIN=() RUN_BLOCK=()
for (( r = 0; r < n_runs; r++ )); do
  script=$(run_cfg "$r" script)
  rpc_env=$(run_cfg "$r" rpc_env)
  label="the script"
  (( n_runs > 1 )) && { label="run $((r + 1)) ($script)"; printf '    run %d   : %s\n' "$((r + 1))" "$script"; }
  args=()
  RUN_CHAIN[r]="" RUN_BLOCK[r]=""
  if [[ -n "$rpc_env" ]]; then
    url="${!rpc_env:-}"
    [[ -n "$url" ]] || die "rpc_env names $rpc_env, which is not set"
    RUN_CHAIN[r]=$(cast chain-id --rpc-url "$url") || die "could not read the chain id from \$$rpc_env"
    RUN_BLOCK[r]=$(cast block-number --rpc-url "$url" 2>/dev/null || true)
    # The URL is not printed: it often carries an API key.
    printf '    rpc      : $%s (chain %s, block %s)\n' "$rpc_env" "${RUN_CHAIN[r]}" "${RUN_BLOCK[r]:-?}"
    args=(--rpc-url "$url")
  fi
  mapfile -t run_claims < <(claims_of_run "$r")
  for i in "${run_claims[@]}"; do mkdir -p "$WORK/repo/$(dirname "$(cfg "$i" output_path)")"; done

  snapshot "$WORK/snap.$r.before"
  in_clone forge script "$script" "${args[@]}" >/dev/null 2>"$WORK/forge.err" \
    || { cat "$WORK/forge.err" >&2; die "forge script failed (see error above)"; }
  snapshot "$WORK/snap.$r.after"
  written_between "$WORK/snap.$r.before" "$WORK/snap.$r.after" >"$WORK/written.$r"
  while IFS= read -r f; do
    for d in "${forge_dirs[@]}"; do [[ "$f" == "$d/"* ]] && continue 2; done
    printf '%s\n' "$f"
  done <"$WORK/written.$r" >"$WORK/outputs.$r"

  # A deploy simulated under vm.startBroadcast is recorded in a dry-run file. Its
  # address depends on the deployer's live nonce, so calldata that embeds it
  # changes once the real deploy lands, and cannot be re-derived without the key.
  # Forge writes each record twice, as -latest and under a timestamp, so only the
  # -latest ones are summed; the largest single file is the floor if none is.
  bc_tx=0 bc_max=0 bc_file=""
  while IFS= read -r f; do
    [[ "$f" == "$broadcast_dir/"*.json ]] || continue
    n=$(jq '[.. | objects | select(has("transactions")) | .transactions | arrays | length] | add // 0' \
      "$WORK/repo/$f" 2>/dev/null || echo 0)
    (( n > 0 )) || continue
    bc_file="$f"
    (( n > bc_max )) && bc_max=$n
    [[ "$f" == *latest* ]] && bc_tx=$((bc_tx + n))
  done <"$WORK/written.$r"
  (( bc_tx > 0 )) || bc_tx=$bc_max
  if (( bc_tx > 0 )); then
    record_fail "$label simulates $bc_tx transaction(s) from an EOA ($bc_file): Safe calldata may depend on them; deploy in a separate script and pin the addresses"
  fi

  expected_paths=()
  for i in "${run_claims[@]}"; do
    p=$(cfg "$i" output_path)
    expected_paths+=("$p")
    inside_clone "$p"
    if { grep -qxF -- "$p" "$WORK/written.$r" \
         || { (( r == 0 )) && grep -qxF -- "$p" "$WORK/written.setup"; }; } \
       && [[ -f "$WORK/repo/$p" && ! -L "$WORK/repo/$p" ]]; then
      ok "produced $p"
    else
      record_fail "script did not produce expected output: $p" "$i"
    fi
  done

  # Every file the run wrote is either attested or deliberately set aside, so a
  # transaction cannot be produced and then left out of the claim unnoticed.
  mapfile -t unclaimed < <(run_cfg "$r" unclaimed | jq -r '.[]')
  extra=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for p in "${expected_paths[@]}" "${unclaimed[@]}"; do [[ "$f" == "$p" ]] && continue 2; done
    extra+=("$f")
  done <"$WORK/outputs.$r"
  if (( ${#extra[@]} )); then
    record_fail "$label wrote files no claim covers (claim them or list them in unclaimed): ${extra[*]}"
  fi
  for p in "${unclaimed[@]}"; do
    grep -qxF -- "$p" "$WORK/written.$r" || warn "listed as unclaimed but not written: $p"
  done
done

# --- 3-6. each claim ----------------------------------------------------------
R_SHA=() R_CANON_SHA=() R_DOMAIN=() R_MESSAGE=() R_HASH=() R_SOL=() R_CHILD=()
R_CHAIN=() R_SAFE=() R_NONCE=() R_URL=() R_LIVE=() R_ACTION=() R_SENDER=()

attest_claim() { # <claim index>
  local i="$1" out_json canonical norm_args sol_child
  local output_path input_format batch_mode multisend_address safe_version chain_id
  local safe_tx_gas base_gas gas_price gas_token refund_receiver safe_address safe_nonce
  local child_safe child_nonce child_network expected_child_hash
  local expected_sha expected_canonical_sha expected_hash got_sha canonical_sha cast_hash
  local sol_hash="" child_hash="" run
  for k in output_path input_format batch_mode multisend_address safe_version chain_id \
           safe_tx_gas base_gas gas_price gas_token refund_receiver safe_address safe_nonce \
           child_safe child_nonce child_network; do
    printf -v "$k" '%s' "$(cfg "$i" "$k")"
  done
  expected_sha=$(cfg "$i" expected_output_sha256)
  expected_canonical_sha=$(cfg "$i" expected_canonical_sha256)
  expected_hash=$(lc "$(cfg "$i" expected_safe_tx_hash)")
  expected_child_hash=$(lc "$(cfg "$i" expected_child_safe_tx_hash)")
  run=$(cfg "$i" run)
  out_json="$WORK/repo/$output_path"

  # --- 3. source integrity: sha256 of the emitted JSON ------------------------
  # Byte-exact, so it only applies to producers whose output has no volatile
  # metadata. Batch writers commonly stamp a `createdAt`; for those, pin
  # expected_canonical_sha256 (step 4) instead. It is stable by construction.
  step "Checking output integrity (sha256)"
  got_sha=$(sha256sum "$out_json" | awk '{print $1}')
  R_SHA[i]="$got_sha"
  printf '    sha256   : %s\n' "$got_sha"
  if [[ -z "$expected_sha" ]]; then
    warn "no expected_output_sha256 pinned: skipping byte-integrity check"
  elif [[ "$got_sha" == "$expected_sha" ]]; then
    ok "matches pinned sha256"
  else
    record_fail "output sha256 mismatch (expected $expected_sha)" "$i"
  fi

  # --- 4. normalise to the canonical SafeTx -----------------------------------
  step "Normalising to canonical SafeTx"
  norm_args=(--input "$out_json" --summary --print-digest)
  add_arg() { [[ -n "$2" ]] && norm_args+=("$1" "$2"); return 0; }
  add_arg --format          "$input_format"
  add_arg --batch-mode      "$batch_mode"
  add_arg --multisend       "$multisend_address"
  add_arg --safe-version    "$safe_version"
  add_arg --chain-id        "$chain_id"
  add_arg --safe            "$safe_address"
  add_arg --nonce           "$safe_nonce"
  add_arg --safe-tx-gas     "$safe_tx_gas"
  add_arg --base-gas        "$base_gas"
  add_arg --gas-price       "$gas_price"
  add_arg --gas-token       "$gas_token"
  add_arg --refund-receiver "$refund_receiver"

  canonical="$WORK/canonical.$i.json"
  bash "$SCRIPT_DIR/lib/normalize.sh" "${norm_args[@]}" \
    >"$canonical" 2>"$WORK/normalize.err" \
    || { cat "$WORK/normalize.err" >&2; die "could not normalise $output_path"; }
  grep -v '^CANONICAL_SHA256=' "$WORK/normalize.err" || true
  R_CHAIN[i]=$(jq -r .chainId "$canonical")
  R_SAFE[i]=$(jq -r .safe "$canonical")
  R_NONCE[i]=$(jq -r .nonce "$canonical")

  canonical_sha=$(sha256sum "$canonical" | awk '{print $1}')
  R_CANON_SHA[i]="$canonical_sha"
  printf '    canonical: %s\n' "$canonical_sha"
  if [[ -z "$expected_canonical_sha" ]]; then
    warn "no expected_canonical_sha256 pinned: skipping canonical-integrity check"
  elif [[ "$canonical_sha" == "$expected_canonical_sha" ]]; then
    ok "matches pinned canonical sha256"
  else
    record_fail "canonical sha256 mismatch (expected $expected_canonical_sha)" "$i"
  fi
  if [[ -z "$expected_sha" && -z "$expected_canonical_sha" ]]; then
    warn "neither sha256 is pinned: nothing anchors this run to a reviewed output"
  fi
  # A run given an RPC reads chain state from it, so its outputs are for that chain.
  if [[ -n "${RUN_CHAIN[run]}" && "${RUN_CHAIN[run]}" != "${R_CHAIN[i]}" ]]; then
    record_fail "transaction is for chain ${R_CHAIN[i]}, but the run's RPC is chain ${RUN_CHAIN[run]}" "$i"
  fi

  # --- 5a. derive the Safe tx hash via cast -----------------------------------
  step "Deriving Safe tx hash (cast)"
  eval "$(bash "$SCRIPT_DIR/lib/derive.sh" "$canonical")"   # sets DOMAIN_HASH / MESSAGE_HASH / SAFE_TX_HASH
  cast_hash=$(lc "$SAFE_TX_HASH")
  R_HASH[i]="$cast_hash" R_DOMAIN[i]="$DOMAIN_HASH" R_MESSAGE[i]="$MESSAGE_HASH"
  printf '    domain   : %s\n' "$DOMAIN_HASH"
  printf '    message  : %s\n' "$MESSAGE_HASH"
  printf '    safeTx   : %s\n' "$cast_hash"
  if [[ -n "$expected_hash" && "$cast_hash" != "$expected_hash" ]]; then
    record_fail "cast-derived hash != pinned expected_safe_tx_hash ($expected_hash)" "$i"
  else
    ok "cast derivation done"
  fi

  # --- 5b. cross-check the Safe tx hash via Solidity (forge test) -------------
  # The Solidity side re-reads the *producer's* JSON, not the canonical form, so it
  # redoes the batch folding independently, so a bug in normalize.sh cannot hide.
  # Claims run one at a time, so the fixed out/ paths are not shared.
  step "Cross-checking Safe tx hash (Solidity)"
  mkdir -p "$SCRIPT_DIR/out"
  cp "$out_json" "$SCRIPT_DIR/out/producer-tx.json"
  cp "$canonical" "$SCRIPT_DIR/out/canonical-safe-tx.json"
  rm -f "$SCRIPT_DIR/out/solidity-safe-tx-hash.txt" "$SCRIPT_DIR/out/solidity-child-safe-tx-hash.txt"
  if ATTEST_JSON="out/producer-tx.json" \
     ATTEST_EXPECTED_SAFE_TX_HASH="${expected_hash:-$cast_hash}" \
     ATTEST_SAFE="$safe_address" \
     ATTEST_NONCE="$safe_nonce" \
     ATTEST_CHAIN_ID="$chain_id" \
     ATTEST_SAFE_VERSION="$safe_version" \
     ATTEST_MULTISEND="$multisend_address" \
     ATTEST_FORCE_MULTISEND="$([[ "$batch_mode" == "multisend" ]] && echo 1 || echo '')" \
     ATTEST_SAFE_TX_GAS="$safe_tx_gas" \
     ATTEST_BASE_GAS="$base_gas" \
     ATTEST_GAS_PRICE="$gas_price" \
     ATTEST_GAS_TOKEN="$gas_token" \
     ATTEST_REFUND_RECEIVER="$refund_receiver" \
     ATTEST_CHILD_SAFE="$child_safe" \
     ATTEST_CHILD_NONCE="$child_nonce" \
       forge test --root "$SCRIPT_DIR" --match-contract AttestTest -q >"$WORK/forge-test.log" 2>&1; then
    sol_hash=$(lc "$(cat "$SCRIPT_DIR/out/solidity-safe-tx-hash.txt" 2>/dev/null || echo '')")
    printf '    safeTx   : %s\n' "${sol_hash:-<unavailable>}"
    # forge test exits 0 when no test matches (FOUNDRY_NO_MATCH_TEST set in the
    # environment, say), so only the written hash shows the check ran.
    if [[ -z "$sol_hash" ]]; then
      record_fail "Solidity cross-check ran no test: it wrote no hash" "$i"
    elif [[ "$sol_hash" != "$cast_hash" ]]; then
      record_fail "Solidity hash ($sol_hash) != cast hash ($cast_hash)" "$i"
    else
      ok "Solidity agrees with cast${expected_hash:+ and pinned expectation}"
    fi
  else
    cat "$WORK/forge-test.log" >&2
    record_fail "Solidity cross-check (forge test) failed" "$i"
  fi
  R_SOL[i]="$sol_hash"

  # --- 6. nested Safe: the approval a child Safe must send --------------------
  # The parent transaction is never signed by the child's owners. Only its hash is
  # approved, via `parent.approveHash(h)`. That approval is a Safe transaction in
  # its own right, and it is the one they actually sign. Every field of it is
  # determined by (parent, h, child, child nonce), so it is constructed here rather
  # than read from an artifact; there is nothing for a producer to choose.
  if [[ -n "$child_safe" ]]; then
    step "Nested approval (child Safe)"
    [[ -n "$child_nonce" ]] || die "config: child_nonce is required alongside child_safe"
    [[ -n "$safe_address" ]] || die "config: safe_address is required for a nested claim"

    bash "$SCRIPT_DIR/lib/nested.sh" \
      --parent-safe "$safe_address" --parent-hash "$cast_hash" \
      --child-safe "$child_safe" --child-nonce "$child_nonce" \
      --chain-id "${R_CHAIN[i]}" \
      --safe-version "$(jq -r .safeVersion "$canonical")" >"$WORK/child.$i.json" \
      || die "could not construct the nested approval"

    eval "$(bash "$SCRIPT_DIR/lib/derive.sh" "$WORK/child.$i.json")"
    child_hash=$(lc "$SAFE_TX_HASH")

    printf '    child    : %s nonce %s\n' "$child_safe" "$child_nonce"
    printf '    approves : %s\n' "$cast_hash"
    printf '    signs    : %s\n' "$child_hash"

    sol_child=$(lc "$(cat "$SCRIPT_DIR/out/solidity-child-safe-tx-hash.txt" 2>/dev/null || echo '')")
    if [[ -z "$sol_child" ]]; then
      record_fail "Solidity did not produce a nested approval hash" "$i"
    elif [[ "$sol_child" != "$child_hash" ]]; then
      record_fail "Solidity nested hash ($sol_child) != cast nested hash ($child_hash)" "$i"
    else
      ok "Solidity agrees with cast on the approval"
    fi

    if [[ -n "$expected_child_hash" && "$child_hash" != "$expected_child_hash" ]]; then
      record_fail "nested approval hash != pinned expected_child_safe_tx_hash ($expected_child_hash)" "$i"
    fi

    # The child's own queue, if asked for. Catches a different transaction being
    # queued on the child and presented to its owners as "the approval".
    if [[ -n "$child_network" ]]; then
      local child_rc=0 child_live msg
      child_live=$(live_safe_tx_hash "$child_network" "$child_safe" "$child_nonce" \
        "$WORK/child_hashes.out") || child_rc=$?
      if [[ "$child_rc" == 2 ]]; then
        record_fail "several transactions are queued on the child at nonce $child_nonce" "$i"
      elif [[ "$child_rc" != 0 ]]; then
        msg="child Safe queue unreachable or nothing at nonce $child_nonce"
        if [[ "$REQUIRE_LIVE" == 1 ]]; then record_fail "$msg" "$i"; else warn "$msg: skipping"; fi
      elif [[ "$child_live" == "$child_hash" ]]; then
        ok "the transaction queued on the child is this approval"
      else
        record_fail "queued on child ($child_live) != constructed approval ($child_hash)" "$i"
      fi
    fi
  fi
  R_CHILD[i]="$child_hash"

  # Each pin commits to the transaction, so any one anchors the run. With none,
  # the checks above can only compare cast with Solidity, which proves nothing
  # about whether the output is the one someone reviewed.
  if [[ -z "$expected_sha$expected_canonical_sha$expected_hash$expected_child_hash" ]]; then
    record_fail "no expected hash pinned: nothing ties this output to a reviewed one" "$i"
  fi
}

for (( i = 0; i < n_claims; i++ )); do
  R_SHA[i]="" R_CANON_SHA[i]="" R_DOMAIN[i]="" R_MESSAGE[i]="" R_HASH[i]="" R_SOL[i]=""
  R_CHILD[i]="" R_CHAIN[i]="" R_SAFE[i]="" R_NONCE[i]="" R_URL[i]="" R_LIVE[i]=""
  R_ACTION[i]="" R_SENDER[i]=""
  if (( n_claims > 1 )); then echo; step "Claim $((i + 1))/$n_claims: $(cfg "$i" output_path)"; fi
  # A claim whose output was not produced has nothing to check.
  claim_failed "$i" || attest_claim "$i"
done

# Only one transaction executes at a Safe's nonce, so two claims for the same one
# cannot both be what the owners sign.
if (( n_claims > 1 )); then
  dups=$(for (( i = 0; i < n_claims; i++ )); do
    [[ -n "${R_HASH[i]}" ]] && printf '%s %s %s\n' "${R_CHAIN[i]}" "$(lc "${R_SAFE[i]}")" "${R_NONCE[i]}"
  done | sort | uniq -d)
  if [[ -n "$dups" ]]; then
    for (( i = 0; i < n_claims; i++ )); do
      [[ -n "${R_HASH[i]}" ]] || continue
      grep -qxF -- "${R_CHAIN[i]} $(lc "${R_SAFE[i]}") ${R_NONCE[i]}" <<<"$dups" \
        && record_fail "another claim is for the same Safe, chain and nonce" "$i"
    done
  fi
fi

# Safe{Wallet} links. The app's chain prefix is its own config's shortName; the
# default assumes it equals the Transaction Service path segment for the network,
# which holds for the networks checked so far. safe_ui_prefix overrides it, and a
# claim with its own service has no default (the app shows the public service).
for (( i = 0; i < n_claims; i++ )); do
  [[ -n "${R_HASH[i]}" ]] || continue
  prefix=$(cfg "$i" safe_ui_prefix)
  if [[ -z "$prefix" && -z "$(cfg "$i" safe_tx_service_url)" && -z "${SAFE_TX_SERVICE_URL:-}" ]]; then
    svc=$(network_service "$(cfg "$i" safe_network)")
    [[ "$svc" == */tx-service/* ]] && prefix="${svc##*/}"
  fi
  R_URL[i]=$(safe_ui_url "$prefix" "${R_SAFE[i]}" "${R_HASH[i]}")
done

# --- 7. propose: sign and submit the attested transactions --------------------
# Runs only when every offline check passed, so what is signed and sent is the
# canonical form those checks hashed, never the producer's JSON as given. Every
# claim's preflight runs before the first signature, so a refusal on one chain
# cannot leave the others half-queued.
TABLE=0
if [[ "$PROPOSE" == 1 ]]; then
  step "Proposing to Safe Transaction Service"
  eligible=() manual=() refused=0
  for (( i = 0; i < n_claims; i++ )); do
    if [[ "$(cfg "$i" live)" == false ]]; then manual+=("$i"); else eligible+=("$i"); fi
  done
  for (( i = 0; i < n_claims; i++ )); do
    [[ -n "$(cfg "$i" child_safe)" ]] && refused=1
  done
  if [[ "$refused" == 1 ]]; then
    record_fail "--propose does not support nested claims"
  elif (( ${#FAILURES[@]} )); then
    refused=1
    record_fail "not proposing: the offline checks did not attest"
  else
    for i in "${eligible[@]}"; do
      if [[ -z "$(cfg "$i" safe_network)" || -z "$(cfg "$i" safe_address)" || -z "$(cfg "$i" safe_nonce)" ]]; then
        # The live check below cannot run without all three, and it is what proves
        # the submission landed. Its failure would come only after the send.
        refused=1
        record_fail "--propose needs safe_network, safe_address and safe_nonce" "$i"
      fi
    done
    if [[ -n "${SAFE_TX_SERVICE_URL:-}" ]] && (( ${#eligible[@]} > 1 )); then
      refused=1
      record_fail "SAFE_TX_SERVICE_URL names one service for every claim; set safe_tx_service_url per claim"
    fi
  fi

  if [[ "$refused" == 0 ]]; then
    for (( i = 0; i < n_claims; i++ )); do
      ST_NAME[i]="$(cfg "$i" safe_network) ${R_CHAIN[i]}"
      [[ -n "$(cfg "$i" safe_network)" ]] || ST_NAME[i]="chain ${R_CHAIN[i]}"
      ST_SAFE[i]="${R_SAFE[i]}" ST_NONCE[i]="${R_NONCE[i]}" ST_HASH[i]="${R_HASH[i]}" ST_URL[i]="${R_URL[i]}"
    done
    TABLE=1
    status_init
    for i in "${manual[@]}"; do status_set "$i" "– import manually"; done

    propose_args() { # <claim index>
      local svc
      svc=$(cfg "$1" safe_tx_service_url)
      PROPOSE_ARGS=(--canonical "$WORK/canonical.$1.json" --hash "${R_HASH[$1]}"
        --network "$(cfg "$1" safe_network)"
        --origin "forge-attest $(run_cfg "$(cfg "$1" run)" script)@${producer_commit:0:12}")
      [[ -n "$svc" ]] && PROPOSE_ARGS+=(--service-url "$svc")
      return 0
    }

    PLANNED=() PRE_SENDER=() preflight_ok=1
    for i in "${eligible[@]}"; do
      status_set "$i" "… preflight"
      propose_args "$i"
      if out=$(bash "$SCRIPT_DIR/lib/propose.sh" "${PROPOSE_ARGS[@]}" --preflight \
          -- "${PROPOSE_WALLET[@]}" 2>"$WORK/preflight.$i.log"); then
        eval "$out"   # sets PROPOSE_ACTION / PROPOSE_SENDER
        PLANNED[i]="$PROPOSE_ACTION" PRE_SENDER[i]="$PROPOSE_SENDER"
        case "$PROPOSE_ACTION" in
          proposed)  status_set "$i" "· ready to propose" ;;
          confirmed) status_set "$i" "· ready to confirm" ;;
          *)         status_set "$i" "· already confirmed" ;;
        esac
      else
        preflight_ok=0
        reason=$(grep -E 'error:' "$WORK/preflight.$i.log" | tail -1 | printable | sed -E 's/.*error:[[:space:]]*//')
        status_set "$i" "✗ refused: ${reason:-see log}"
        status_dirty
        cat "$WORK/preflight.$i.log" >&2
        record_fail "proposal to the Safe Transaction Service failed" "$i"
      fi
    done

    if [[ "$preflight_ok" == 0 ]]; then
      for i in "${eligible[@]}"; do
        [[ -n "${PLANNED[i]:-}" ]] && status_set "$i" "– not sent"
      done
      status_dirty
      warn "nothing was signed or sent: a claim's preflight was refused"
    fi
    for i in "${eligible[@]}"; do
      [[ "$preflight_ok" == 1 ]] || break
      if [[ "${PLANNED[i]}" == already-confirmed ]]; then
        R_ACTION[i]=already-confirmed R_SENDER[i]="${PRE_SENDER[i]}"
        status_set "$i" "✓ already confirmed"
        continue
      fi
      status_set "$i" "… sign on device"
      status_dirty
      propose_args "$i"
      if out=$(bash "$SCRIPT_DIR/lib/propose.sh" "${PROPOSE_ARGS[@]}" -- "${PROPOSE_WALLET[@]}"); then
        eval "$out"   # sets PROPOSE_ACTION / PROPOSE_SENDER
        R_ACTION[i]="$PROPOSE_ACTION" R_SENDER[i]="$PROPOSE_SENDER"
        status_set "$i" "✓ $PROPOSE_ACTION"
      else
        status_set "$i" "✗ failed: re-run"
        record_fail "proposal to the Safe Transaction Service failed" "$i"
      fi
    done
  fi
fi

# --- 8. live integrity: compare against the Safe Transaction Service ----------
for (( i = 0; i < n_claims; i++ )); do
  claim_tag=""
  (( n_claims > 1 )) && claim_tag=" ($(cfg "$i" output_path))"
  step "Live check against Safe Transaction Service$claim_tag"
  safe_network=$(cfg "$i" safe_network)
  safe_address=$(cfg "$i" safe_address)
  safe_nonce=$(cfg "$i" safe_nonce)
  if [[ -z "${R_HASH[i]}" ]]; then
    warn "no transaction derived: skipping live check"
  elif [[ "$(cfg "$i" live)" == false ]]; then
    # Stated in the claim, so a chain with no service is a reviewed exception,
    # not a check that silently could not run.
    warn "live = false: no Transaction Service to check this claim against"
  elif [[ -z "$safe_network" || -z "$safe_address" || -z "$safe_nonce" ]]; then
    # A flat SafeTx carries its own Safe and nonce, so a claim for one can attest
    # with these blank. That is a live check that cannot run, not one that passed.
    msg="safe_network/address/nonce not fully set"
    if [[ "$REQUIRE_LIVE" == 1 ]]; then
      record_fail "$msg: live check required" "$i"
    else
      warn "$msg: skipping live check"
    fi
  else
    live_out="$WORK/safe_hashes.$i.out"
    live_rc=0
    live_hash=$(live_safe_tx_hash "$safe_network" "$safe_address" "$safe_nonce" "$live_out") \
      || live_rc=$?

    if [[ "$live_rc" == 2 ]]; then
      # A competing transaction is evidence, not an outage: owners shown the queue
      # could sign the other one. --propose refuses the same state.
      record_fail "several transactions are queued at nonce $safe_nonce" "$i"
      [[ "$TABLE" == 1 ]] && status_set "$i" "✗ several transactions queued"
    elif [[ "$live_rc" != 0 ]]; then
      msg="Safe Transaction Service unreachable or no tx at nonce $safe_nonce"
      if [[ "$REQUIRE_LIVE" == 1 ]]; then
        cat "$live_out" >&2; record_fail "$msg" "$i"
      else
        warn "$msg: skipping (use --require-live to enforce)"
      fi
      [[ "$TABLE" == 1 ]] && status_set "$i" "${ST_STATE[i]} · not in queue"
    else
      R_LIVE[i]="$live_hash"
      printf '    safeTx   : %s\n' "$live_hash"
      if [[ "$live_hash" == "${R_HASH[i]}" ]]; then
        ok "queued Safe tx matches the script-derived hash"
        [[ "$TABLE" == 1 ]] && status_set "$i" "${ST_STATE[i]} · queued"
      else
        record_fail "queued Safe tx ($live_hash) != script-derived (${R_HASH[i]})" "$i"
        [[ "$TABLE" == 1 ]] && status_set "$i" "✗ queued ≠ attested"
      fi
    fi
  fi
done
if [[ "$TABLE" == 1 ]]; then
  echo
  step "Safe{Wallet} links"
  status_links
fi

# --- verdict ------------------------------------------------------------------
# The JSON document goes to fd 3 (real stdout under --json, /dev/null otherwise),
# so this runs unconditionally and the two report formats cannot drift apart.
# Lists go in as JSON arrays: as positional args, a string starting with `-`
# would be parsed as a jq option.
lines_json() { printf '%s\n' "$@" | jq -cRn '[inputs | select(. != "")]'; }

claim_json() { # <claim index>
  local i="$1" fails='[]'
  [[ -f "$WORK/fail.$i" ]] && fails=$(jq -cRn '[inputs | select(. != "")]' <"$WORK/fail.$i")
  jq -n \
    --argjson failures "$fails" \
    --argjson run "$(cfg "$i" run)" \
    --arg output_path      "$(cfg "$i" output_path)" \
    --arg safe_address     "$(cfg "$i" safe_address)" \
    --arg safe_nonce       "$(cfg "$i" safe_nonce)" \
    --arg safe_network     "$(cfg "$i" safe_network)" \
    --arg safe_version     "$(cfg "$i" safe_version)" \
    --arg chain_id         "${R_CHAIN[i]}" \
    --arg live             "$(cfg "$i" live)" \
    --arg output_sha256    "${R_SHA[i]}" \
    --arg canonical_sha256 "${R_CANON_SHA[i]}" \
    --arg domain_hash      "${R_DOMAIN[i]}" \
    --arg message_hash     "${R_MESSAGE[i]}" \
    --arg safe_tx_hash     "${R_HASH[i]}" \
    --arg safe_tx_solidity "${R_SOL[i]}" \
    --arg safe_tx_live     "${R_LIVE[i]}" \
    --arg child_safe       "$(cfg "$i" child_safe)" \
    --arg child_nonce      "$(cfg "$i" child_nonce)" \
    --arg child_safe_tx    "${R_CHILD[i]}" \
    --arg proposal_action  "${R_ACTION[i]}" \
    --arg proposal_sender  "${R_SENDER[i]}" \
    --arg url              "${R_URL[i]}" \
    '{
      output_path: $output_path, run: $run, attested: ($failures | length == 0),
      safe: { address: $safe_address, nonce: $safe_nonce,
              network: $safe_network, version: $safe_version },
      chain_id: $chain_id, live: ($live != "false"),
      hashes: {
        output_sha256:    $output_sha256,
        canonical_sha256: $canonical_sha256,
        domain:           $domain_hash,
        message:          $message_hash,
        safe_tx:          $safe_tx_hash,
        safe_tx_solidity: $safe_tx_solidity,
        safe_tx_live:     $safe_tx_live
      },
      nested: (if $child_safe == "" then null else
        { safe: $child_safe, nonce: $child_nonce, safe_tx: $child_safe_tx }
      end),
      proposal: (if $proposal_action == "" then null else
        { action: $proposal_action, sender: $proposal_sender, url: $url }
      end),
      url: $url,
      failures: $failures
    }'
}

for (( i = 0; i < n_claims; i++ )); do claim_json "$i"; done >"$WORK/claims.json"
for (( r = 0; r < n_runs; r++ )); do
  jq -n --arg script "$(run_cfg "$r" script)" --arg rpc_env "$(run_cfg "$r" rpc_env)" \
    --arg chain_id "${RUN_CHAIN[r]}" --arg block "${RUN_BLOCK[r]}" \
    --argjson written "$(jq -cRn '[inputs | select(. != "")]' <"$WORK/outputs.$r" 2>/dev/null || echo '[]')" \
    '{script: $script, rpc_env: $rpc_env, chain_id: $chain_id, block: $block, written: $written}'
done >"$WORK/runs.json"

jq -n \
  --argjson failures "$(lines_json "${FAILURES[@]+"${FAILURES[@]}"}")" \
  --argjson attested "$([[ ${#FAILURES[@]} -eq 0 ]] && echo true || echo false)" \
  --slurpfile claims "$WORK/claims.json" \
  --slurpfile runs   "$WORK/runs.json" \
  --arg layout          "$layout" \
  --arg producer_repo   "$producer_repo" \
  --arg producer_commit "$producer_commit" \
  --arg forge_version   "$forge_version" \
  --arg forge_commit    "$forge_commit" \
  --arg cast_version    "$cast_version" \
  --arg producer_solc   "$producer_solc" \
  '
    { forge: $forge_version, forge_commit: $forge_commit,
      cast: $cast_version, producer_solc: $producer_solc } as $toolchain
    | if $layout == "flat" then
        # The single-claim document keeps its original shape.
        $claims[0] as $c
        | { attested: $attested,
            producer: { repo: $producer_repo, commit: $producer_commit, script: $runs[0].script },
            safe: $c.safe, toolchain: $toolchain, hashes: $c.hashes,
            nested: $c.nested, proposal: $c.proposal, failures: $failures }
      else
        { attested: $attested, layout: $layout,
          producer: { repo: $producer_repo, commit: $producer_commit },
          toolchain: $toolchain, runs: $runs, claims: $claims, failures: $failures }
      end' >&3

echo
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  if [[ "$layout" == flat ]]; then
    printf '%s%s ATTESTED %s the submitted Safe tx is exactly the output of %s@%s\n' \
      "$C_BOLD" "$C_GREEN" "$C_RESET" "$(run_cfg 0 script)" "${producer_commit:0:12}"
  else
    printf '%s%s ATTESTED %s all %d Safe txs are exactly the outputs of %s@%s\n' \
      "$C_BOLD" "$C_GREEN" "$C_RESET" "$n_claims" "$producer_repo" "${producer_commit:0:12}"
    for (( i = 0; i < n_claims; i++ )); do
      printf '    %-40s %s\n' "$(cfg "$i" output_path)" "${R_HASH[i]}"
    done
  fi
  for (( i = 0; i < n_claims; i++ )); do
    [[ -n "${R_CHILD[i]}" ]] || continue
    printf '    %s sign %s on %s\n' "$C_BOLD" "${R_CHILD[i]}" "$(cfg "$i" child_safe)"
    # The parent hash binds the parent's nonce, and `approveHash` stores only a
    # flag. If the parent's nonce moves, every approval silently stops matching
    # and execution fails with an unhelpful "invalid owner" error. The expiry
    # is therefore part of the verdict, not a footnote.
    printf '    %svalid only while %s nonce == %s%s\n' \
      "$C_YELLOW" "$(cfg "$i" safe_address)" "$(cfg "$i" safe_nonce)" "$C_RESET"
  done
  exit 0
else
  printf '%s%s NOT ATTESTED %s %d check(s) failed:\n' \
    "$C_BOLD" "$C_RED" "$C_RESET" "${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
  exit 1
fi
