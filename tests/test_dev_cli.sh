#!/usr/bin/env bash
# Arg-parsing + terminal-semantics for `mra dev` (parser tested directly).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/dev.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

reset() { DEV_PROJECT=""; DEV_TASK=""; DEV_BASE=""; DEV_MODEL=""; DEV_MAX_ROUNDS=""; DEV_NO_PR=false; DEV_AUTO_APPROVE=false; DEV_RESUME=false; DEV_DRY_RUN=false; }

# 1. project + multi-word task accumulate; defaults applied.
reset; _dev_parse_args api add a new field; rc=$?
assert_eq "parse ok rc" "0" "$rc"
assert_eq "project parsed" "api" "$DEV_PROJECT"
assert_eq "task accumulated" "add a new field" "$DEV_TASK"
assert_eq "default model sonnet" "sonnet" "$DEV_MODEL"
assert_eq "default max-rounds 3" "3" "$DEV_MAX_ROUNDS"

# 2. flags parsed.
reset; _dev_parse_args api "do x" --base develop --model opus --max-rounds 5 --no-pr --auto-approve --resume --dry-run
assert_eq "base" "develop" "$DEV_BASE"
assert_eq "model" "opus" "$DEV_MODEL"
assert_eq "max-rounds" "5" "$DEV_MAX_ROUNDS"
assert_eq "no-pr" "true" "$DEV_NO_PR"
assert_eq "auto-approve" "true" "$DEV_AUTO_APPROVE"
assert_eq "resume" "true" "$DEV_RESUME"
assert_eq "dry-run" "true" "$DEV_DRY_RUN"

# 3. missing task -> nonzero.
reset; _dev_parse_args api >/dev/null 2>&1; assert_eq "missing task fails" "1" "$?"
# 4. missing project+task -> nonzero.
reset; _dev_parse_args >/dev/null 2>&1; assert_eq "missing all fails" "1" "$?"
# 5. non-positive max-rounds rejected.
reset; _dev_parse_args api "x" --max-rounds 0 >/dev/null 2>&1; assert_eq "max-rounds 0 rejected" "1" "$?"
reset; _dev_parse_args api "x" --max-rounds abc >/dev/null 2>&1; assert_eq "max-rounds abc rejected" "1" "$?"
# 6. --base requires a value.
reset; _dev_parse_args api "x" --base >/dev/null 2>&1; assert_eq "base arity checked" "1" "$?"
# 7. unknown flag rejected.
reset; _dev_parse_args api "x" --frobnicate >/dev/null 2>&1; assert_eq "unknown flag rejected" "1" "$?"

echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all dev-cli tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
