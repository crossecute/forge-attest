#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

capture_error() {
  printf 'safe-utils capture: %s\n' "$1" >&2
  [[ -z "${FORGE_ATTEST_CAPTURE_DIR:-}" ]] || : >"$FORGE_ATTEST_CAPTURE_DIR/failed"
  exit 1
}

capture_request() {
  local state="${FORGE_ATTEST_CAPTURE_DIR:?missing capture directory}"
  local method="" body="" url="" format="" safe nonce id
  while (( $# )); do
    case "$1" in
      -s|--silent|-S|-sS) shift ;;
      -X|--request|-d|--data|-w|--write-out|-H|--header)
        (( $# >= 2 )) || capture_error "missing curl option value"
        case "$1" in
          -X|--request) [[ -z "$method" ]] || capture_error "repeated method"; method="$2" ;;
          -d|--data) [[ -z "$body" ]] || capture_error "repeated body"; body="$2" ;;
          -w|--write-out) [[ -z "$format" ]] || capture_error "repeated write-out"; format="$2" ;;
        esac
        shift 2 ;;
      http://*|https://*) [[ -z "$url" ]] || capture_error "multiple URLs"; url="$1"; shift ;;
      *) capture_error "unsupported curl argument" ;;
    esac
  done
  [[ "$method" == POST && "$format" == '\n%{http_code}' ]] \
    || capture_error "only the safe-utils POST/write-out transport is supported"
  [[ "$url" =~ ^https?://[A-Za-z0-9.:-]+/[A-Za-z0-9/_-]*api/v1/safes/(0x[0-9a-fA-F]{40})/multisig-transactions/$ ]] \
    || capture_error "not a Safe proposal endpoint"
  safe="${BASH_REMATCH[1],,}"
  [[ ${#body} -le 1048576 ]] || capture_error "request exceeds 1 MiB"
  # Do not interpret curl's @file syntax or copy a producer-supplied response.
  nonce=$(jq -er 'select(type == "object") | .nonce | select(type == "string" or type == "number") | tostring' \
    <<<"$body" 2>/dev/null) || capture_error "invalid proposal body or nonce"
  [[ "$nonce" =~ ^(0|[1-9][0-9]*)$ ]] || capture_error "invalid proposal nonce"
  id=$(jq -er --arg safe "$safe" --arg nonce "$nonce" \
    '.[] | select(.safe == $safe and .nonce == $nonce) | .id' "$state/map.json") \
    || capture_error "unclaimed Safe/nonce proposal"
  # mkdir also rejects concurrent or repeated proposals at the same binding.
  mkdir "$state/seen.$id" 2>/dev/null || capture_error "duplicate Safe/nonce proposal"
  printf '%s' "$body" >"$state/$id.json"
  printf '{}\n201'
}

if [[ "${0##*/}" == curl ]]; then
  capture_request "$@"
  exit
fi

case "${1:-}" in
  prepare)
    model="$2" run="$3" state="$4" chain="$5"
    mkdir -p "$state/bin"
    jq --argjson run "$run" --arg chain "$chain" '
      [.claims | to_entries[] | select(.value.run == $run) |
        if .value.chain_id != "" and .value.chain_id != $chain then error("capture claim chain differs from RPC")
        else {id: .key, safe: (.value.safe_address | ascii_downcase), nonce: .value.safe_nonce} end]' \
      "$model" >"$state/map.json"
    ln -s "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/capture.sh" "$state/bin/curl"
    ;;
  verify)
    state="$2"
    [[ ! -f "$state/failed" ]] || capture_error "a transport request was rejected"
    ids=$(jq -er 'select(type == "array" and length > 0) | .[].id' "$state/map.json") \
      || capture_error "invalid capture manifest"
    while IFS= read -r id; do
      [[ -f "$state/$id.json" && -d "$state/seen.$id" ]] || capture_error "missing claimed proposal"
    done <<<"$ids"
    ;;
  *) capture_error "expected prepare or verify" ;;
esac
