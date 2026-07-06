#!/usr/bin/env bash
# build_review_prompt: inline mode requires the completion sentinel; terminal does not.
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-prompt.sh"
# stub collaborators build_review_prompt may call for context
review_diff_text()  { echo "diff"; }
review_diff_files() { echo "x"; }

errors=0; pass=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

inline=$(build_review_prompt proj /tmp gf base nodetype "" "" false "" inline range "" 2>/dev/null)
case "$inline" in *"MRA-REVIEW-COMPLETE"*) ok "inline prompt requires sentinel";; *) fail "inline prompt missing sentinel instruction";; esac

term=$(build_review_prompt proj /tmp gf base nodetype "" "" false "" terminal range "" 2>/dev/null)
case "$term" in *"MRA-REVIEW-COMPLETE"*) fail "terminal prompt should NOT mention sentinel";; *) ok "terminal prompt unchanged";; esac

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
