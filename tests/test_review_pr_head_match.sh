#!/usr/bin/env bash
# Reviewing `--pr N` from a checkout that is not the PR's head reviews the wrong
# code — and the result looks entirely plausible.
#
# Found running `mra review erp --pr 4915` from an unrelated feature branch.
# The range is `<base>...HEAD`, so mra diffed that branch instead of the PR:
# 3 files / +262 of somebody's unfinished work, against a PR touching a
# completely different set. Not empty, so the empty-diff guard did not fire;
# under the default post mode that review would have been posted to #4915.
#
# lib/review-post.sh already refuses to POST when local HEAD does not match the
# PR head, but only after the model has run — the tokens are spent and its
# message ("PR head changed during review") misdescribes a checkout that was
# never right. The check belongs before the review.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MRA_REVIEW_POST_MODE=none MRA_REVIEW_PR_CONTEXT=0

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export MRA_CONFIG="$TMP/config.json"
echo '{"configVersion":2,"review":{"providerMode":"claude","primaryProvider":"claude"}}' > "$MRA_CONFIG"
WS="$TMP/ws"; mkdir -p "$WS/.collab" "$WS/proj"
echo '{"projects":{"proj":{"type":"node","deps":{},"consumedBy":[],"confidence":{}}},"gitOrg":"acme","workspace":"'"$WS"'","version":1,"lastScan":"now"}' > "$WS/.collab/dep-graph.json"

R="$WS/proj"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
# The head lookup derives the repo slug from origin.
git -C "$R" remote add origin git@github.com:acme/proj.git
printf 'one\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m init
# A feature branch that is NOT the PR head, with real changes of its own.
git -C "$R" checkout -q -b unrelated
printf 'unrelated work\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m unrelated
LOCAL=$(git -C "$R" rev-parse HEAD)

for lib in colors config project-path review-verdict args review-diff review-prompt \
           review-json review-strategy review-provider review-post review-select \
           review-context pkb pkb-cache review; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/$lib.sh" 2>/dev/null || true
done

MODEL_MARKER="$TMP/model-was-called"
review_call_model() { : > "$MODEL_MARKER"; printf '%s\n' '{"status":"APPROVED","summary":"x","comments":[]}'; }
_review_post_review() { :; }

# gh is the only source of the PR head; stub it rather than reach the network.
GH_STUB="$TMP/bin"; mkdir -p "$GH_STUB"
make_gh() {
  cat > "$GH_STUB/gh" <<INNER
#!/usr/bin/env bash
case "\$*" in
  *"pulls/1"*) echo "$1" ;;
  *) echo "" ;;
esac
INNER
  chmod +x "$GH_STUB/gh"
}
export PATH="$GH_STUB:$PATH"

# --- HEAD is a different commit than the PR head ----------------------------
make_gh "0000000000000000000000000000000000000000"
rm -f "$MODEL_MARKER"
out=$(review_project "$WS" proj --pr 1 --base main 2>&1); rc=$?

[[ -e "$MODEL_MARKER" ]] && fail "the wrong checkout still reached the model" \
                         || ok "a checkout that is not the PR head never reaches the model"
[[ $rc -ne 0 ]] && ok "the run fails loud (rc=$rc)" \
                || fail "exited 0 while reviewing the wrong commit"
case "$out" in
  *"gh pr checkout"*) ok "the error names the remedy" ;;
  *) fail "error does not say how to fix it: $out" ;;
esac
case "$out" in
  *"changed during review"*) fail "misdescribes a never-correct checkout as a mid-review change" ;;
  *) ok "the message describes the actual situation" ;;
esac

# --- Control: HEAD IS the PR head -------------------------------------------
make_gh "$LOCAL"
rm -f "$MODEL_MARKER"
review_project "$WS" proj --pr 1 --base main >/dev/null 2>&1 || true
[[ -e "$MODEL_MARKER" ]] && ok "the matching checkout reviews normally" \
                         || fail "the guard blocks a correct review"

# --- Control: no PR number means no head to match ----------------------------
rm -f "$MODEL_MARKER"
review_project "$WS" proj --base main >/dev/null 2>&1 || true
[[ -e "$MODEL_MARKER" ]] && ok "a branch review is unaffected" \
                         || fail "the guard wrongly blocks a plain branch review"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
