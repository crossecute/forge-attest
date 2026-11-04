#!/usr/bin/env bash
#
# claims.sh: read an attest.toml into one JSON model, so every later step reads
#            the claim from the same place.
#
# Usage:  claims.sh <attest.toml>  > model.json
#
# Two layouts. A flat file is one claim, as before. A file with [[run]] tables
# keeps the producer keys at the top, one [[run]] per `forge script` call, an
# optional [run.env] and [run.defaults], and one [[run.claim]] per output file.
# Only that subset of TOML is accepted: toml_get reads one section at a time,
# so anything a TOML parser would
# read differently (other headers, dotted keys, literal or multi-line strings,
# escapes, a repeated key) is refused rather than read one way here and another
# way by a reviewer.
#
# Model: { layout: "flat"|"runs", producer: {...},
#          runs: [{script, rpc_env, fork_block, env: {...}, senders: [...], unclaimed: [...]}],
#          claims: [{run, output_path, <claim keys>...}] }
# Every value is a string as written, "" when unset; senders and unclaimed are
# arrays.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

CONFIG="${1:?usage: claims.sh <attest.toml>}"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

PRODUCER_KEYS=(producer_repo producer_commit producer_setup expected_forge_version)
RUN_KEYS=(script rpc_env fork_block senders unclaimed)
DEFAULT_KEYS=(input_format batch_mode safe_version multisend_address)
CLAIM_KEYS=(output_path input_format batch_mode multisend_address safe_version chain_id
  safe_tx_gas base_gas gas_price gas_token refund_receiver
  child_safe child_nonce child_network expected_child_safe_tx_hash
  safe_network safe_address safe_nonce live safe_ui_prefix safe_tx_service_url
  expected_output_sha256 expected_canonical_sha256 expected_safe_tx_hash)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- split into sections ------------------------------------------------------
# Section files: top, then r<i> for each [[run]] and r<i>c<j> for its claims.
sections=(top)
current="$TMP/top"
: >"$current"
runs=0 claims_in_run=0 lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
    continue
  elif [[ "$line" =~ ^\[\[run\]\][[:space:]]*(#.*)?$ ]]; then
    runs=$((runs + 1)); claims_in_run=0
    sections+=("r$runs"); current="$TMP/r$runs"; : >"$current"
  elif [[ "$line" =~ ^\[\[run\.claim\]\][[:space:]]*(#.*)?$ ]]; then
    (( runs )) || die "config line $lineno: [[run.claim]] before any [[run]]"
    claims_in_run=$((claims_in_run + 1))
    sections+=("r${runs}c$claims_in_run"); current="$TMP/r${runs}c$claims_in_run"; : >"$current"
  elif [[ "$line" =~ ^\[run\.(env|defaults)\][[:space:]]*(#.*)?$ ]]; then
    table="${BASH_REMATCH[1]}"
    (( runs )) || die "config line $lineno: [run.$table] before any [[run]]"
    current="$TMP/r${runs}.$table"
    [[ ! -f "$current" ]] || die "config line $lineno: repeated [run.$table]"
    : >"$current"
  elif [[ "$line" =~ ^[[:space:]]*\[ ]]; then
    die "config line $lineno: unsupported table header"
  elif [[ "$line" =~ ^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*(.*)$ ]]; then
    rhs="${BASH_REMATCH[1]}"
    # toml_get takes a basic string verbatim; TOML would decode escapes in it,
    # and reads '...' and """...""" as strings toml_get does not know.
    [[ "$rhs" != \'* && "$rhs" != \"\"\"* ]] \
      || die "config line $lineno: use a one-line \"double-quoted\" string"
    [[ "$rhs" != \"* || "$rhs" =~ ^\"[^\"\\]*\"[[:space:]]*(#.*)?$ ]] \
      || die "config line $lineno: strings may not contain \\ or a second \""
    printf '%s\n' "$line" >>"$current"
  else
    die "config line $lineno: not a 'key = value' line: $(printf '%s' "$line" | printable)"
  fi
done <"$CONFIG"

layout=flat
(( runs )) && layout=runs

section_keys() {
  sed -nE 's/^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=.*/\1/p' "$1"
}

# check_section <file> <what> <allowed key...>
check_section() {
  local file="$1" what="$2" key dup
  shift 2
  dup=$(section_keys "$file" | sort | uniq -d)
  [[ -z "$dup" ]] || die "config: key set more than once: $(echo $dup) (in $what)"
  while IFS= read -r key; do
    [[ " $* " == *" $key "* ]] || die "config: unknown key in $what: $key"
  done < <(section_keys "$file")
}

# section_json <file> <key...>: the keys as a JSON object of strings
section_json() {
  local file="$1" key args=()
  shift
  for key in "$@"; do args+=(--arg "$key" "$(toml_get "$file" "$key")"); done
  jq -n '$ARGS.named' "${args[@]}"
}

# rel_path <what> <path>: deleted and then read inside the clone, so relative
# and without '..'.
rel_path() {
  [[ -n "$2" && "$2" != /* && "/$2/" != */../* ]] \
    || die "config: $1 must be relative to the producer repo, without '..': $2"
}

# array_json <file> <key>: a one-line array of plain strings
array_json() {
  local raw
  raw=$(toml_get "$1" "$2")
  [[ -n "$raw" ]] || { echo '[]'; return; }
  jq -ce 'if type == "array" and all(.[]; type == "string") then . else error end' \
    <<<"$raw" 2>/dev/null || die "config: $2 must be a one-line array of strings: $raw"
}

environment_json() {
  local file="$1" key value args=() keys=()
  [[ -f "$file" ]] || { echo '{}'; return; }
  mapfile -t keys < <(section_keys "$file")
  check_section "$file" "[run.env]" "${keys[@]}"
  for key in "${keys[@]}"; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || die "config: invalid producer environment name: $key"
    case "$key" in
      SAFE_API_KEY|PATH|IFS|BASH_ENV|ENV|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE|LD_*|DYLD_*|GLIBC_TUNABLES|GCONV_PATH|LIBPATH|SHLIB_PATH)
        die "config: reserved producer environment name: $key" ;;
    esac
    grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"" "$file" \
      || die "config: [run.env] values must be double-quoted strings: $key"
    value=$(toml_get "$file" "$key")
    args+=(--arg "$key" "$value")
  done
  jq -cn '$ARGS.named' "${args[@]}"
}

# run_json <file> <script>: one run of the model
run_json() {
  local u s p
  u=$(array_json "$1" unclaimed)
  while IFS= read -r p; do rel_path unclaimed "$p"; done < <(jq -r '.[]' <<<"$u")
  s=$(array_json "$1" senders)
  section_json "$1" rpc_env fork_block | jq -c --arg script "$2" --argjson s "$s" --argjson u "$u" \
    --argjson env "$(environment_json "$1.env")" \
    '{script: $script} + . + {env: $env, senders: $s, unclaimed: $u}'
}

if [[ "$layout" == flat ]]; then
  check_section "$TMP/top" "the claim" "${PRODUCER_KEYS[@]}" producer_script rpc_env fork_block senders unclaimed "${CLAIM_KEYS[@]}"
  producer=$(section_json "$TMP/top" "${PRODUCER_KEYS[@]}")
  run=$(run_json "$TMP/top" "$(toml_get "$TMP/top" producer_script)")
  runs_json=$(jq -n --argjson r "$run" '[$r]')
  claims_json=$(section_json "$TMP/top" "${CLAIM_KEYS[@]}" | jq -c '[{run: 0} + .]')
else
  check_section "$TMP/top" "the producer keys at the top" "${PRODUCER_KEYS[@]}"
  producer=$(section_json "$TMP/top" "${PRODUCER_KEYS[@]}")
  runs_json='[]' claims_json='[]'
  for (( r = 1; r <= runs; r++ )); do
    check_section "$TMP/r$r" "[[run]] $r" "${RUN_KEYS[@]}"
    run=$(run_json "$TMP/r$r" "$(toml_get "$TMP/r$r" script)")
    runs_json=$(jq -c --argjson r "$run" '. + [$r]' <<<"$runs_json")
    defaults='{}'
    if [[ -f "$TMP/r$r.defaults" ]]; then
      check_section "$TMP/r$r.defaults" "[run.defaults]" "${DEFAULT_KEYS[@]}"
      defaults=$(section_json "$TMP/r$r.defaults" "${DEFAULT_KEYS[@]}")
    fi
    c=1
    [[ -f "$TMP/r${r}c1" ]] || die "config: [[run]] $r has no [[run.claim]]"
    while [[ -f "$TMP/r${r}c$c" ]]; do
      check_section "$TMP/r${r}c$c" "[[run.claim]] $c of [[run]] $r" "${CLAIM_KEYS[@]}"
      mapfile -t keys < <(section_keys "$TMP/r${r}c$c")
      # Explicit empty values clear defaults, so merge by key presence.
      claim=$(section_json "$TMP/r${r}c$c" "${CLAIM_KEYS[@]}" | jq --argjson i "$((r - 1))" \
        --argjson defaults "$defaults" --argjson explicit "$(section_json "$TMP/r${r}c$c" "${keys[@]}")" \
        '. + $defaults + $explicit + {run: $i}')
      claims_json=$(jq -c --argjson c "$claim" '. + [$c]' <<<"$claims_json")
      c=$((c + 1))
    done
  done
fi

# --- values every later step relies on ----------------------------------------
pv() { jq -r --arg k "$1" '.[$k]' <<<"$producer"; }
[[ -n "$(pv producer_repo)" ]] || die "config: producer_repo is required"
# Checked before git sees it: a value starting with `-` would be read as an option.
[[ "$(pv producer_commit)" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
  || die "config: producer_commit must be a full lowercase commit SHA"

# Fields are split on \x1f, not tab: read merges runs of a whitespace IFS, so an
# empty field would shift the ones after it.
# A sender's transactions are only re-derivable from a fixed block, since the
# addresses they create follow its nonce there; and only a run given rpc_env
# forks at a block this tool sets.
while IFS=$'\x1f' read -r script rpc_env fork_block senders bad_sender; do
  [[ -n "$script" ]] || die "config: every run needs a script (producer_script in a flat claim)"
  [[ -z "$rpc_env" || "$rpc_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "config: rpc_env must name an environment variable: $rpc_env"
  [[ -z "$fork_block" || "$fork_block" =~ ^(0|[1-9][0-9]{0,15})$ ]] \
    || die "config: fork_block must be a decimal block number: $fork_block"
  [[ -z "$fork_block" || -n "$rpc_env" ]] || die "config: fork_block needs rpc_env, the chain it forks"
  [[ "$senders" == 0 || -n "$fork_block" ]] || die "config: senders needs fork_block"
  [[ -z "$bad_sender" ]] || die "config: senders must be addresses: $bad_sender"
done < <(jq -r '.[] | [.script, .rpc_env, .fork_block, (.senders | length),
    (first(.senders[] | select(test("^0x[0-9a-fA-F]{40}$") | not)) // "")] | join("\u001f")' <<<"$runs_json")

# safe_ui_prefix and safe_tx_service_url end up in links and requests, and on a
# fork PR the config is the attacker's.
while IFS=$'\x1f' read -r path live prefix service; do
  [[ -n "$path" ]] || die "config: output_path is required"
  rel_path output_path "$path"
  [[ -z "$live" || "$live" == true || "$live" == false ]] \
    || die "config: live must be true or false, not $live"
  [[ -z "$prefix" || "$prefix" =~ ^[a-z0-9-]{1,32}$ ]] \
    || die "config: safe_ui_prefix must be a chain short name such as oeth, not $prefix"
  [[ -z "$service" || "$service" =~ ^https?://[A-Za-z0-9.:/_-]+$ ]] \
    || die "config: safe_tx_service_url must be a plain http(s) URL: $service"
done < <(jq -r '.[] | [.output_path, .live, .safe_ui_prefix, .safe_tx_service_url] | join("\u001f")' <<<"$claims_json")

# Two claims on one file, or a claimed file also listed as unclaimed, would each
# be attested or excused by the other.
dup=$(jq -r '.[].output_path' <<<"$claims_json" | sort | uniq -d)
[[ -z "$dup" ]] || die "config: more than one claim names output_path $(echo $dup)"
both=$(jq -rn --argjson r "$runs_json" --argjson c "$claims_json" \
  '[$c[].output_path] - ([$c[].output_path] - [$r[].unclaimed[]]) | .[]')
[[ -z "$both" ]] || die "config: listed as both claimed and unclaimed: $(echo $both)"

jq -n --arg layout "$layout" --argjson producer "$producer" \
  --argjson runs "$runs_json" --argjson claims "$claims_json" \
  '{layout: $layout, producer: $producer, runs: $runs, claims: $claims}'
