#!/usr/bin/env bash
# stats.sh — print the counts that appear in the README badge line, computed from
# the source, so they can be regenerated instead of hand-maintained (drift-proof).
#
# Usage:
#   scripts/stats.sh          # human-readable summary
#   scripts/stats.sh --badge  # the README badge fragment (commands + test suites)
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Top-level CLI commands = the first-level branches of main()'s `case "$command"`.
commands=$(awk '
  /case "\$command"/ { f=1; next }
  f && /^  esac/     { exit }
  f && /^    [a-z][a-z0-9|_-]*\)/ {
    line=$0
    sub(/\).*/, "", line)          # keep the label part before ")"
    gsub(/[ \t]/, "", line)
    n=split(line, parts, "|")       # a) or a|b) both count their labels
    for (i=1; i<=n; i++) if (parts[i] != "") print parts[i]
  }
' "$MRA_DIR/bin/mra.sh" | sort -u | grep -c '.')

# Test suites = tests/test_*.sh files.
suites=$(find "$MRA_DIR/tests" -maxdepth 1 -name 'test_*.sh' | grep -c '.')

if [[ "${1:-}" == "--badge" ]]; then
  printf '%s CLI commands | %s test suites\n' "$commands" "$suites"
else
  printf 'CLI commands : %s\n' "$commands"
  printf 'Test suites  : %s\n' "$suites"
fi
