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

# The scan set must cover every directory that holds shell we ship. It used to
# be lib/ + tests/ + test.sh, and the corpus work put new code in scripts/ and
# bin/ — where two BSD-first probes then sat for weeks. The guard was right and
# simply was not looking where the code went, so CI stayed red on Linux while
# every local run on macOS was green.
SCAN=("$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/scripts/*.sh "$SCRIPT_DIR"/bin/*.sh
      "$SCRIPT_DIR"/tests/*.sh "$SCRIPT_DIR"/test.sh)

mapfile -t offenders < <(
  grep -rn "stat -f[^|]*||[^|]*stat -c" "${SCAN[@]}" 2>/dev/null || true
)
if [[ ${#offenders[@]} -eq 0 ]]; then
  ok "no BSD-first stat probe remains"
else
  fail "BSD-first stat probes silently return filesystem info on Linux:"
  printf '       %s\n' "${offenders[@]}"
fi

# A BSD form with no GNU form near it is the same bug without the fallback: on
# Linux it does not fail over, it just returns filesystem text.
#
# The pair is not always on one line — the lock helpers try each form on its own
# line so the failing one's stdout can be discarded — so a hit counts as covered
# when `stat -c` appears within six lines either side. A deliberate one-time
# platform probe says so with a `stat-probe` marker on the preceding line.
# Comment lines are skipped: every one of these sites is commented, and matching
# the prose would make the guard fire on its own explanation. This file is
# excluded outright for the same reason.
mapfile -t lone < <(
  grep -rn -- "stat -f" "${SCAN[@]}" 2>/dev/null \
    | grep -v "stat -c" \
    | while IFS= read -r hit; do
        file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; code="${rest#*:}"
        [[ "$file" == "$SCRIPT_DIR/tests/test_stat_portability.sh" ]] && continue
        case "$code" in [[:space:]]*'#'*|'#'*) continue ;; esac
        lo=$(( line > 6 ? line - 6 : 1 ))
        if sed -n "${lo},$((line + 6))p" "$file" 2>/dev/null | grep -q "stat -c"; then
          continue
        fi
        prev="$(sed -n "$((line - 1))p" "$file" 2>/dev/null)"
        case "$prev" in *stat-probe*) continue ;; esac
        printf '%s\n' "$hit"
      done
)
if [[ ${#lone[@]} -eq 0 ]]; then
  ok "no lone BSD stat form outside a marked platform probe"
else
  fail "BSD-only stat with no GNU counterpart returns filesystem text on Linux:"
  printf '       %s\n' "${lone[@]}"
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
