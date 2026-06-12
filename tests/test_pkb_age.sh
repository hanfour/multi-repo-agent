#!/usr/bin/env bash
# Verify pkb_age_hours parses meta timestamps on both BSD (macOS) and
# GNU (Linux) date. The BSD-only `date -j` silently returned epoch 0 on
# Linux, making every PKB look ancient and forcing regeneration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/pkb.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj/.mra/pkb"

NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$T/proj/.mra/pkb/meta.json" <<EOF
{"version": 2, "lastUpdated": "$NOW_TS"}
EOF

# --- native date (BSD on macOS, GNU on Linux): fresh meta is fresh ---
hours=$(pkb_age_hours "$T/proj")
if [[ "$hours" -lt 2 ]]; then
  pass_test "native date: fresh meta reports <2h (got $hours)"
else
  fail_test "native date: fresh meta should be <2h, got $hours"
fi

# --- GNU date simulation: -j unsupported, -d supported ---
date() {
  local a
  for a in "$@"; do
    [[ "$a" == "-j" ]] && return 1
  done
  if [[ "${1:-}" == "-d" ]]; then
    # GNU `date -d <ts>Z +%s` treats the Z suffix as UTC; emulate that
    # with BSD's -u when running on macOS, or delegate on real GNU.
    command date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$2" "+%s" 2>/dev/null \
      || command date -d "$2" "+%s"
    return
  fi
  command date "$@"
}

hours=$(pkb_age_hours "$T/proj")
unset -f date

if [[ "$hours" -lt 2 ]]; then
  pass_test "GNU date fallback: fresh meta reports <2h (got $hours)"
else
  fail_test "GNU date fallback: fresh meta should be <2h, got $hours"
fi

echo "---"
echo "Passed: $pass"
echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
