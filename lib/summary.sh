#!/usr/bin/env bash
#
# summary.sh: render an attest.sh verdict and its report as Markdown, for the
#             GitHub Action's job summary.
#
# Usage:  summary.sh <verdict.json> <report.log>  > summary.md
#
# Both inputs carry config-derived strings, and on a fork PR the config is
# attacker-controlled; the report also carries the producer's own output.
set -euo pipefail

verdict="${1:?usage: summary.sh <verdict.json> <report.log>}"
log="${2:?usage: summary.sh <verdict.json> <report.log>}"

# text escapes Markdown. code is for code spans, where escapes do not apply, so
# it drops what would end the span or the table cell.
defs='
  def text: gsub("[[:cntrl:]]"; " ") | gsub("(?<c>[\\\\`*_\\[\\]<>|#~!])"; "\\\(.c)");
  def code: gsub("[[:cntrl:]`|]"; " ");'
v() { jq -r "$defs $1" "$verdict"; }

if [[ "$(v '.attested')" == "true" ]]; then
  echo "### ✅ ATTESTED"
  echo
  if [[ "$(v '.layout // "flat"')" == runs ]]; then
    echo "Every claimed Safe transaction is exactly the output of the pinned script."
  else
    echo "The queued Safe transaction is exactly the output of the pinned script."
  fi
else
  echo "### ❌ NOT ATTESTED"
  echo
  v '.failures[] | "- \(text)"'
fi

echo
if [[ "$(v '.layout // "flat"')" == runs ]]; then
  # A link is rendered only in the exact shape attest.sh builds, since the
  # Safe{Wallet} prefix comes from the claim.
  v '
    "Producer `\(.producer.repo | code)` @ `\(.producer.commit[0:12] | code)`",
    "",
    "| output | chain | Safe @ nonce | safeTxHash | |",
    "|---|---|---|---|---|",
    (.claims[] |
      "| `\(.output_path | code)` | \(.chain_id | text) | `\(.safe.address | code)` @ \(.safe.nonce | text) | " +
      (if (.url | test("^https://app\\.safe\\.global/transactions/tx\\?safe=[a-z0-9-]+:0x[0-9a-fA-F]{40}&id=multisig_0x[0-9a-fA-F]{40}_0x[0-9a-f]{64}$"))
       then "[`\(.hashes.safe_tx | code)`](\(.url))" else "`\(.hashes.safe_tx | code)`" end) +
      " | \(if .attested then "✅" else "❌" end) |")
  '
  v '.claims[] | select(.nested != null) |
    "", "Nested (`\(.output_path | code)`): the child Safe `\(.nested.safe | code)` signs `\(.nested.safe_tx | code)` at nonce \(.nested.nonce | text)."'
else
  v '
    "| | |",
    "|---|---|",
    "| safeTxHash | `\(.hashes.safe_tx | code)` |",
    "| canonical sha256 | `\(.hashes.canonical_sha256 | code)` |",
    "| Safe | `\(.safe.address | code)` @ nonce \(.safe.nonce | text) |",
    "| producer | `\(.producer.script | code)` @ `\(.producer.commit[0:12] | code)` |"
  '

  if [[ "$(v '.nested // ""')" != "" ]]; then
    echo
    v '"Nested: the child Safe `\(.nested.safe | code)` signs `\(.nested.safe_tx | code)` at nonce \(.nested.nonce | text)."'
  fi
fi

# The fence must be longer than any backtick run in the text as rendered.
# Measured on the raw log, removing an escape between two runs would join them
# into one long enough to close it.
report=$(sed -E 's/\x1b\[[0-9;]*m//g' "$log" | LC_ALL=C tr -d '\000-\010\013-\037\177')
fence='```'
while [[ "$report" == *"$fence"* ]]; do fence+='`'; done

echo
echo "<details><summary>Full report</summary>"
echo
echo "$fence"
printf '%s\n' "$report"
echo "$fence"
echo
echo "</details>"
