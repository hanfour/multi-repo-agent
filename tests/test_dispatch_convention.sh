#!/usr/bin/env bash
# bin/mra.sh dispatches by convention, not by a hand-maintained list.
#
# It used to be a 42-branch `case "$command"`, so every new command meant
# editing the entry point and the file grew monotonically (#39). A command is
# now just a `mra_cmd_<name>` function in a lib/cmd-*.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MRA="$SCRIPT_DIR/bin/mra.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# --- name mapping -----------------------------------------------------------
eval "$(sed -n '/^_mra_handler_for()/,/^}/p' "$MRA")"

eq "plain name"        "mra_cmd_review"     "$(_mra_handler_for review)"
eq "dashes to unders"  "mra_cmd_prd_issues" "$(_mra_handler_for prd-issues)"
eq "multiple dashes"   "mra_cmd_eval_probe" "$(_mra_handler_for eval-probe)"
eq "--all is special"  "mra_cmd_all"        "$(_mra_handler_for --all)"

# A crafted argument must map to a name, never escape into something else. The
# `declare -F` gate in main() is what stops an undefined name from running, but
# the mapping itself must not evaluate anything either.
eq "no substitution"  'mra_cmd_$(id)'  "$(_mra_handler_for '$(id)')"
eq "no path escape"   'mra_cmd_../x'   "$(_mra_handler_for '../x')"

# --- the entry point holds no per-command knowledge -------------------------
if grep -q 'case "\$command" in' "$MRA"; then
  fail "the hand-maintained command case is back"
else
  ok "no command case in the entry point"
fi

# Command names must live in the command modules, not in bin/mra.sh. `usage`
# legitimately lists them, so check only below it.
tail_after_usage=$(sed -n '/^_mra_handler_for()/,$p' "$MRA")
stray=""
for c in review analyze plan prd doctor snapshot federation dashboard; do
  case "$tail_after_usage" in *"$c"*) stray="$stray $c" ;; esac
done
[[ -z "$stray" ]] && ok "dispatch names no individual command" \
                  || fail "dispatch still mentions:$stray"

# --- end to end: a new command needs no edit anywhere in the dispatch --------
# An exported function is visible to the child shell, so this exercises the real
# resolution path in a real `mra` run without touching a single file.
mra_cmd_zzsmoke() { echo "zzsmoke reached with args: $*"; }
export -f mra_cmd_zzsmoke

out=$("$MRA" zzsmoke --flag 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"zzsmoke reached with args: zzsmoke --flag"* ]]; then
  ok "a command defined by convention alone is dispatched, argv intact"
else
  fail "convention dispatch did not reach the handler (rc=$rc): $out"
fi

# And an unknown name still falls through to the project-launch path rather
# than erroring — that was the old catch-all branch's job.
unknown=$("$MRA" zznotacommand 2>&1); urc=$?
if [[ "$unknown" == *"zzsmoke"* ]]; then
  fail "unknown command reached the wrong handler"
elif [[ $urc -ne 0 ]]; then
  ok "unknown name falls through to the project path and is rejected there"
else
  ok "unknown name falls through to the project path"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
