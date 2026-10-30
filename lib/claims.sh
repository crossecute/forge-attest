#!/usr/bin/env bash
#
# claims.sh: read an attest.toml into one JSON model, so every later step reads
#            the claim from the same place.
#
# Usage:  claims.sh <attest.toml>  > model.json
#
# Two layouts. A flat file is one claim, as before. A file with [[run]] tables
# keeps the producer keys at the top, one [[run]] per `forge script` call, and one
# [[run.claim]] per output file that run writes. Only that subset of TOML is
# accepted: toml_get reads one section at a time, so anything a TOML parser would
# read differently (other headers, dotted keys, literal or multi-line strings,
# escapes, a repeated key) is refused rather than read one way here and another
# way by a reviewer.
#
# Model: { layout: "flat"|"runs", producer: {...},
#          runs: [{script, rpc_env, unclaimed: [...]}],
#          claims: [{run, output_path, <claim keys>...}] }
# Every value is a string as written, "" when unset; unclaimed is an array.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

CONFIG="${1:?usage: claims.sh <attest.toml>}"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

PRODUCER_KEYS=(producer_repo producer_commit producer_setup expected_forge_version)
RUN_KEYS=(script rpc_env unclaimed)
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
  elif [[ "$line" =~ ^[[:space:]]*\[ ]]; then
    die "config line $lineno: [table] headers are not supported; only [[run]] and [[run.claim]] are"
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

# check_section <file> <what> <allowed key...>
check_section() {
  local file="$1" what="$2" key dup
  shift 2
  dup=$(sed -nE 's/^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=.*/\1/p' "$file" | sort | uniq -d)
  [[ -z "$dup" ]] || die "config: key set more than once: $(echo $dup) (in $what)"
  while IFS= read -r key; do
    [[ " $* " == *" $key "* ]] || die "config: unknown key in $what: $key"
  done < <(sed -nE 's/^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=.*/\1/p' "$file")
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

# unclaimed_json <file>: a one-line array of plain strings
unclaimed_json() {
  local raw p
  raw=$(toml_get "$1" unclaimed)
  [[ -n "$raw" ]] || { echo '[]'; return; }
  jq -ce 'if type == "array" and all(.[]; type == "string") then . else error end' \
    <<<"$raw" 2>/dev/null || die "config: unclaimed must be a one-line array of strings: $raw"
  while IFS= read -r p; do rel_path unclaimed "$p"; done < <(jq -r '.[]' <<<"$raw")
}

if [[ "$layout" == flat ]]; then
  check_section "$TMP/top" "the claim" "${PRODUCER_KEYS[@]}" producer_script rpc_env unclaimed "${CLAIM_KEYS[@]}"
  producer=$(section_json "$TMP/top" "${PRODUCER_KEYS[@]}")
  run=$(section_json "$TMP/top" rpc_env | jq --arg s "$(toml_get "$TMP/top" producer_script)" \
    --argjson u "$(unclaimed_json "$TMP/top")" '{script: $s} + . + {unclaimed: $u}')
  runs_json=$(jq -n --argjson r "$run" '[$r]')
  claims_json=$(section_json "$TMP/top" "${CLAIM_KEYS[@]}" | jq -c '[{run: 0} + .]')
else
  check_section "$TMP/top" "the producer keys at the top" "${PRODUCER_KEYS[@]}"
  producer=$(section_json "$TMP/top" "${PRODUCER_KEYS[@]}")
  runs_json='[]' claims_json='[]'
  for (( r = 1; r <= runs; r++ )); do
    check_section "$TMP/r$r" "[[run]] $r" "${RUN_KEYS[@]}"
    run=$(section_json "$TMP/r$r" script rpc_env | jq --argjson u "$(unclaimed_json "$TMP/r$r")" '. + {unclaimed: $u}')
    runs_json=$(jq -c --argjson r "$run" '. + [$r]' <<<"$runs_json")
    c=1
    [[ -f "$TMP/r${r}c1" ]] || die "config: [[run]] $r has no [[run.claim]]"
    while [[ -f "$TMP/r${r}c$c" ]]; do
      check_section "$TMP/r${r}c$c" "[[run.claim]] $c of [[run]] $r" "${CLAIM_KEYS[@]}"
      claim=$(section_json "$TMP/r${r}c$c" "${CLAIM_KEYS[@]}" | jq --argjson i "$((r - 1))" '{run: $i} + .')
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
while IFS=$'\x1f' read -r script rpc_env; do
  [[ -n "$script" ]] || die "config: every run needs a script (producer_script in a flat claim)"
  [[ -z "$rpc_env" || "$rpc_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "config: rpc_env must name an environment variable: $rpc_env"
done < <(jq -r '.[] | [.script, .rpc_env] | join("\u001f")' <<<"$runs_json")

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
