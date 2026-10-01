#!/usr/bin/env bash
# build_review_prompt: inline mode requires the completion sentinel; terminal does not.
set -uo pipefail

# Pin the sentinel token so the fixtures below can spell it literally. A real
# run mints a per-run nonce (GHSA-5gjm-rqvq-f877); lib/review-verdict.sh honours
# this override, and tests/test_review_verdict.sh covers the nonce itself.
export MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-prompt.sh"
# stub collaborators build_review_prompt may call for context
review_diff_text()  { echo "diff"; }
review_diff_files() { echo "x"; }

errors=0; pass=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

assert_prompt_rules() {
  local label="$1" prompt="$2" section_count instruction
  section_count=$(printf '%s\n' "$prompt" | grep -Fxc '## Before you report a finding' || true)
  [[ "$section_count" == "1" ]] && ok "$label prompt includes the rules section once" || fail "$label prompt must include the rules section once"

  for instruction in \
    '1. First, read the diff below to understand what changed.' \
    "3. Check the project's existing patterns, naming conventions, and architecture." \
    'Only flag issues that are in the DIFF. Do not review unchanged code.'; do
    case "$prompt" in
      *"$instruction"*) ok "$label prompt retains: $instruction" ;;
      *) fail "$label prompt missing existing instruction: $instruction" ;;
    esac
  done
}

inline=$(build_review_prompt proj /tmp gf base nodetype "" "" false "" inline range "" 2>/dev/null)
case "$inline" in *"MRA-REVIEW-COMPLETE"*) ok "inline prompt requires sentinel";; *) fail "inline prompt missing sentinel instruction";; esac
assert_prompt_rules inline "$inline"

term=$(build_review_prompt proj /tmp gf base nodetype "" "" false "" terminal range "" 2>/dev/null)
case "$term" in *"MRA-REVIEW-COMPLETE"*) fail "terminal prompt should NOT mention sentinel";; *) ok "terminal prompt unchanged";; esac
assert_prompt_rules terminal "$term"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
