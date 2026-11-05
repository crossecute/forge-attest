#!/usr/bin/env bash

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

