#!/usr/bin/env bash
# A review with nothing to review must never reach the model.
#
# Found by running `mra review finance-system --pr 303` against a real PR from a
# checkout that did not contain the PR's head. The range is `<base>...HEAD` and
# HEAD was the local branch, so the diff came out empty, the prompt carried
# "(diff unavailable)" and no changed files — and the review ran anyway. The
# model returned:
#
#   {"status":"APPROVED","summary":"...未包含可用 diff 或 changed files...","comments":[]}
#   ===MRA-REVIEW-COMPLETE-<nonce>: APPROVED===
#
# A well-formed sentinel, so the completeness firewall accepted it. With the
# default MRA_REVIEW_POST_MODE that is an APPROVED review posted to a 25-file
# pull request nothing ever looked at. The same empty input produced
# CHANGES_REQUESTED on a previous run, so the verdict is arbitrary.
#
# lib/review.sh already guards this for `--working` and for an explicit
# `--range`/`--head`, and its own comment says "never a silent empty review".
# The default path that `--pr` uses was the one left uncovered.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MRA_REVIEW_POST_MODE=none
export MRA_REVIEW_PR_CONTEXT=0

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MRA_CONFIG="$TMP/config.json"
echo '{"configVersion":2,"review":{"providerMode":"claude","primaryProvider":"claude"}}' > "$MRA_CONFIG"

WS="$TMP/ws"
mkdir -p "$WS/.collab" "$WS/proj"
echo '{"projects":{"proj":{"type":"node","deps":{},"consumedBy":[],"confidence":{}}},"gitOrg":"acme","workspace":"'"$WS"'","version":1,"lastScan":"now"}' \
  > "$WS/.collab/dep-graph.json"

R="$WS/proj"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'one\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m init

for lib in colors config project-path review-verdict args review-diff review-prompt \
           review-json review-strategy review-provider review-post review-select \
           review-context pkb pkb-cache review; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/$lib.sh" 2>/dev/null || true
done

# The model must not be called at all — recording it is the point of the test.
MODEL_MARKER="$TMP/model-was-called"
review_call_model() { : > "$MODEL_MARKER"; printf '%s\n' '{"status":"APPROVED","summary":"x","comments":[]}'; }
_review_post_review() { :; }

# --- HEAD == base, so `<base>...HEAD` is empty -------------------------------
rm -f "$MODEL_MARKER"
out=$(review_project "$WS" proj --pr 1 --base main 2>&1); rc=$?

if [[ -e "$MODEL_MARKER" ]]; then
  fail "an empty diff still reached the model"
else
  ok "an empty diff never reaches the model"
fi

if [[ $rc -ne 0 ]]; then
  ok "a --pr review with no visible changes fails loud (rc=$rc)"
else
  fail "a --pr review with no visible changes exited 0 — a caller cannot tell it reviewed nothing"
fi

case "$out" in
  *APPROVED*) fail "output mentions APPROVED for a review that saw nothing: $out" ;;
  *) ok "no verdict is emitted for a review that saw nothing" ;;
esac

# The message has to tell the operator what to do — this failure means the
# checkout does not contain the PR head, which is not obvious from "no changes".
case "$out" in
  *checkout*|*fetch*|*head*) ok "the error points at the checkout" ;;
  *) fail "error does not say why there is nothing to review: $out" ;;
esac

# --- Control: a real diff still reviews normally -----------------------------
git -C "$R" checkout -q -b feature
printf 'two\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m change
rm -f "$MODEL_MARKER"
review_project "$WS" proj --pr 1 --base main >/dev/null 2>&1 || true
[[ -e "$MODEL_MARKER" ]] && ok "a non-empty diff still reaches the model" \
                        || fail "the guard blocks a legitimate review"

# --- Control: no PR number and no changes is not an error --------------------
git -C "$R" checkout -q main
rm -f "$MODEL_MARKER"
review_project "$WS" proj --base main >/dev/null 2>&1; nrc=$?
[[ $nrc -eq 0 ]] && ok "branch review with nothing to review is not an error" \
                 || fail "branch review with no changes should exit 0, got $nrc"
[[ -e "$MODEL_MARKER" ]] && fail "branch review with no changes still called the model" \
                         || ok "branch review with no changes skips the model"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
