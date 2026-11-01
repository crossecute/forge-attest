#!/usr/bin/env bash
# status.sh: the per-chain table attest.sh --attest keeps while it submits.
# Sourced after common.sh. The caller fills ST_NAME, ST_SAFE, ST_NONCE, ST_HASH
# and ST_URL (one entry per claim; ST_URL may be "") and then calls status_init.
#
# On a terminal the table is redrawn in place and each hash links to its
# Safe{Wallet} page (OSC 8). Anything else, or FORGE_ATTEST_LINKS=0, gets one
# plain line per change, with URLs written out, since CI logs link those.

ST_NAME=() ST_SAFE=() ST_NONCE=() ST_HASH=() ST_URL=() ST_STATE=()
ST_TTY=0 ST_LINES=0 ST_CLEAN=0 ST_COLS=80

# safe_ui_url <prefix> <safe> <safeTxHash>: the Safe{Wallet} transaction page,
# in the form apps/web/src/utils/tx-link.ts builds. The app shows checksummed
# addresses, so the id uses one.
safe_ui_url() {
  local safe
  [[ -n "$1" ]] || return 0
  safe=$(cast to-check-sum-address "$2")
  printf 'https://app.safe.global/transactions/tx?safe=%s:%s&id=multisig_%s_%s' "$1" "$safe" "$safe" "$3"
}

short() { printf '%s…%s' "${1:0:6}" "${1: -4}"; }

status_init() {
  local i
  [[ -t 1 && "${FORGE_ATTEST_LINKS:-1}" != 0 ]] && ST_TTY=1
  ST_COLS=$(tput cols 2>/dev/null || echo 80)
  for i in "${!ST_NAME[@]}"; do ST_STATE[i]="· waiting"; done
  if [[ "$ST_TTY" == 1 ]]; then
    status_draw
  else
    for i in "${!ST_NAME[@]}"; do
      printf '    %-22s %s nonce %s  %s  %s\n' "${ST_NAME[i]}" "${ST_SAFE[i]}" "${ST_NONCE[i]}" \
        "${ST_HASH[i]}" "${ST_URL[i]:-(no Safe{Wallet} link)}"
    done
  fi
}

# A row that wraps would throw off the cursor-up count of the next redraw, so the
# state is cut to what fits after the fixed 56 columns.
status_row() { # <index>
  local i="$1" cell state width
  cell=$(short "${ST_HASH[i]}")
  # OSC 8 hyperlink; terminals without support print the text alone.
  [[ -n "${ST_URL[i]}" ]] && cell=$'\033]8;;'"${ST_URL[i]}"$'\033\\'"$cell"$'\033]8;;\033\\'
  width=$(( ST_COLS - 57 ))
  (( width > 8 )) || width=8
  state="${ST_STATE[i]:0:width}"
  printf '    %-18.18s %s  %-6s %s  %s\n' "${ST_NAME[i]}" "$(short "${ST_SAFE[i]}")" \
    "${ST_NONCE[i]}" "$cell" "$state"
}

status_draw() {
  local i
  # In place only when nothing else was printed since the last draw.
  if [[ "$ST_CLEAN" == 1 && "$ST_LINES" -gt 0 ]]; then
    printf '\033[%dA' "$ST_LINES"
  fi
  printf '\033[2K    %-18s %-11s  %-6s %-11s  %s\n' chain safe nonce safeTxHash status
  for i in "${!ST_NAME[@]}"; do printf '\033[2K'; status_row "$i"; done
  ST_LINES=$(( ${#ST_NAME[@]} + 1 ))
  ST_CLEAN=1
}

# status_set <index> <state>
status_set() {
  ST_STATE[$1]="$2"
  if [[ "$ST_TTY" == 1 ]]; then
    status_draw
  else
    printf '    %-22s %s: %s\n' "${ST_NAME[$1]}" "$(short "${ST_HASH[$1]}")" "$2"
  fi
}

# Call before letting other output through (a signing prompt, an error log), so
# the next draw starts below it instead of overwriting it.
status_dirty() { ST_CLEAN=0; }

status_links() {
  local i
  for i in "${!ST_NAME[@]}"; do
    [[ -n "${ST_URL[i]}" ]] && printf '    %-22s %s\n' "${ST_NAME[i]}" "${ST_URL[i]}"
  done
  return 0
}
