#!/usr/bin/env bash
# bin/mra.sh loads lib/*.sh from an explicit ordered list (MRA_LIBS), not a
# glob, because order matters — lib/review-verdict.sh mints the run's sentinel
# token at source time and later files read it.
#
# The cost of an explicit list is that it can fall behind: add lib/foo.sh,
# forget the list entry, and every function in it is simply absent at runtime
# with no error until something calls one. This test is what makes the explicit
# list safe to keep (#39).
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# Read the list without executing the rest of bin/mra.sh.
eval "$(sed -n '/^MRA_LIBS=(/,/^)/p' "$MRA_DIR/bin/mra.sh")"

[[ ${#MRA_LIBS[@]} -gt 0 ]] && ok "MRA_LIBS parsed (${#MRA_LIBS[@]} entries)" \
                            || fail "could not parse MRA_LIBS from bin/mra.sh"

# Every listed lib must exist.
missing_file=()
for lib in "${MRA_LIBS[@]}"; do
  [[ -f "$MRA_DIR/lib/$lib.sh" ]] || missing_file+=("$lib")
done
[[ ${#missing_file[@]} -eq 0 ]] && ok "every listed lib exists" \
  || fail "listed but absent from lib/: ${missing_file[*]}"

# Every lib must be listed.
mapfile -t on_disk < <(cd "$MRA_DIR/lib" && ls ./*.sh | sed 's|^\./||; s|\.sh$||' | sort)
mapfile -t listed < <(printf '%s\n' "${MRA_LIBS[@]}" | sort)
mapfile -t unlisted < <(comm -13 <(printf '%s\n' "${listed[@]}") <(printf '%s\n' "${on_disk[@]}"))
[[ ${#unlisted[@]} -eq 0 ]] && ok "every lib/*.sh is listed" \
  || fail "present in lib/ but never sourced: ${unlisted[*]}"

# A duplicate entry would source a file twice — harmless for pure function
# definitions, not for anything with top-level state such as the sentinel token.
dupes=$(printf '%s\n' "${MRA_LIBS[@]}" | sort | uniq -d)
[[ -z "$dupes" ]] && ok "no duplicate entries" || fail "listed twice: $dupes"

# The ceiling this list exists to respect.
lines=$(wc -l < "$MRA_DIR/bin/mra.sh" | tr -d " ")
(( lines <= 800 )) && ok "bin/mra.sh within the 800-line ceiling ($lines)" \
  || fail "bin/mra.sh is $lines lines, over the 800-line ceiling"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
