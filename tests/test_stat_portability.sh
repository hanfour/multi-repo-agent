#!/usr/bin/env bash
# `stat -f` means opposite things on the two platforms mra runs on: on BSD/macOS
# it is a FORMAT flag, on GNU/Linux it is filesystem status. A BSD-first probe
# does not fail on Linux — it SUCCEEDS with unrelated output, so the `||`
# fallback never runs and the caller silently consumes garbage.
#
# Found in CI when a mode assertion compared `File: "/tmp/..."` against 0600.
# The same ordering was in lib/pkb-cache.sh, where the value feeds PKB staleness
# detection, and lib/doctor.sh, where it feeds a permission check — both would
# have been wrong on Linux without failing.
#
# GNU-first is safe on both: macOS's stat rejects -c outright, so the fallback
# does run there.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

mapfile -t offenders < <(
  grep -rn "stat -f[^|]*||[^|]*stat -c" \
    "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/tests/*.sh "$SCRIPT_DIR"/test.sh 2>/dev/null || true
)
if [[ ${#offenders[@]} -eq 0 ]]; then
  ok "no BSD-first stat probe remains"
else
  fail "BSD-first stat probes silently return filesystem info on Linux:"
  printf '       %s\n' "${offenders[@]}"
fi

# The ordering actually used must work here, whichever platform "here" is.
probe=$(stat -c '%a' "$SCRIPT_DIR/README.md" 2>/dev/null || stat -f '%Lp' "$SCRIPT_DIR/README.md" 2>/dev/null)
[[ "$probe" =~ ^[0-7]{3,4}$ ]] && ok "GNU-first mode probe yields a mode ($probe)" \
                               || fail "mode probe returned '$probe'"

mprobe=$(stat -c %Y "$SCRIPT_DIR/README.md" 2>/dev/null || stat -f %m "$SCRIPT_DIR/README.md" 2>/dev/null)
[[ "$mprobe" =~ ^[0-9]+$ ]] && ok "GNU-first mtime probe yields an epoch" \
                            || fail "mtime probe returned '$mprobe'"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
