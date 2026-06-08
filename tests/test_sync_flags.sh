#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0

# A clean, empty workspace (no repos) so a valid single-mode/default run exits 0 quickly.
WS=$(mktemp -d); mkdir -p "$WS/.collab"
echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"

# run sync with the given flags; capture output in $out and exit code in $rc.
# The `if out=$(...)` form suspends set -e so a non-zero exit does not abort the test.
run() {
  if out=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync "$@" 2>&1); then rc=0; else rc=$?; fi
}

# conflicting modes -> exit 1 + message
run --safe --push
if [[ $rc -eq 0 ]]; then echo "FAIL: --safe --push should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"choose only one"*) : ;; *) echo "FAIL: expected 'choose only one', got: $out"; errors=$((errors+1)) ;; esac

run --review --push
if [[ $rc -eq 0 ]]; then echo "FAIL: --review --push should exit non-zero"; errors=$((errors+1)); fi

run --safe --review
if [[ $rc -eq 0 ]]; then echo "FAIL: --safe --review should exit non-zero"; errors=$((errors+1)); fi

# --dry-run without --push -> exit 1 + message
run --dry-run
if [[ $rc -eq 0 ]]; then echo "FAIL: --dry-run without --push should exit non-zero"; errors=$((errors+1)); fi
case "$out" in *"only applies to --push"*) : ;; *) echo "FAIL: expected 'only applies to --push', got: $out"; errors=$((errors+1)) ;; esac

# valid combo: --push --dry-run on empty workspace -> exit 0
run --push --dry-run
if [[ $rc -ne 0 ]]; then echo "FAIL: --push --dry-run should exit 0 on empty workspace, got rc=$rc: $out"; errors=$((errors+1)); fi

# single mode --review on empty workspace -> not rejected by discipline gate (exit 0)
run --review
if [[ $rc -ne 0 ]]; then echo "FAIL: single --review should not be rejected, got rc=$rc: $out"; errors=$((errors+1)); fi

# single mode --safe on empty workspace -> not rejected by discipline gate (exit 0)
run --safe
if [[ $rc -ne 0 ]]; then echo "FAIL: single --safe should not be rejected, got rc=$rc: $out"; errors=$((errors+1)); fi

rm -rf "$WS"

# --- sync --json dispatch ---
# Re-create empty workspace for JSON dispatch tests
WS=$(mktemp -d); mkdir -p "$WS/.collab"
echo '{"gitOrg":"x","projects":{}}' > "$WS/.collab/dep-graph.json"

# 9/12. default mode --json on the empty $WS -> [] (valid array; exercises default-mode JSON dispatch)
jout=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync --json 2>/dev/null)
[[ "$(printf '%s' "$jout" | jq -c '.')" == "[]" ]] || { echo "FAIL: empty workspace --json should be []: $jout"; errors=$((errors+1)); }

# 10. --safe --json over a populated workspace -> array, clean stdout, logs on stderr
WJ=$(mktemp -d)
for r in a b; do
  git -C "$WJ" init -b main "$r" &>/dev/null
  git -C "$WJ/$r" config user.email t@t.t; git -C "$WJ/$r" config user.name t
  git -C "$WJ/$r" commit --allow-empty -m init &>/dev/null
done
git -C "$WJ/b" checkout -b feat/x &>/dev/null
EJ=$(mktemp)
jout=$(MRA_WORKSPACE="$WJ" bash "$SCRIPT_DIR/bin/mra.sh" sync --safe --json 2>"$EJ")
printf '%s' "$jout" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: --safe --json should be a JSON array: $jout"; errors=$((errors+1)); }
[[ "$(printf '%s' "$jout" | jq 'length')" == "2" ]] || { echo "FAIL: array should have 2 repos: $jout"; errors=$((errors+1)); }
printf '%s' "$jout" | jq -e 'all(.[]; has("repo") and has("action") and has("ok"))' >/dev/null 2>&1 || { echo "FAIL: each object needs repo/action/ok: $jout"; errors=$((errors+1)); }
printf '%s' "$jout" | jq . >/dev/null 2>&1 || { echo "FAIL: --safe --json stdout must be pure JSON: $jout"; errors=$((errors+1)); }
case "$jout" in *'[sync]'*) echo "FAIL: stdout must not contain the [sync] log tag: $jout"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WJ" "$EJ"

# 11. --review --json -> error, non-zero, no JSON
if jout=$(MRA_WORKSPACE="$WS" bash "$SCRIPT_DIR/bin/mra.sh" sync --review --json 2>/dev/null); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: --review --json should exit non-zero"; errors=$((errors+1)); }
if printf '%s' "$jout" | jq -e . >/dev/null 2>&1; then echo "FAIL: --review --json should produce no JSON on stdout: $jout"; errors=$((errors+1)); fi

# 13. failure path: a repo whose --safe fetch fails -> non-zero exit, stdout still a JSON array with ok:false
WF=$(mktemp -d)
git -C "$WF" init -b main a &>/dev/null
git -C "$WF/a" config user.email t@t.t; git -C "$WF/a" config user.name t
git -C "$WF/a" commit --allow-empty -m init &>/dev/null
git -C "$WF/a" remote add origin /nonexistent/x.git
EF=$(mktemp)
if jout=$(MRA_WORKSPACE="$WF" bash "$SCRIPT_DIR/bin/mra.sh" sync --safe --json 2>"$EF"); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "FAIL: fetch-failure --safe --json should exit non-zero"; errors=$((errors+1)); }
printf '%s' "$jout" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: stdout should still be a JSON array on failure: $jout"; errors=$((errors+1)); }
[[ "$(printf '%s' "$jout" | jq -r '.[] | select(.repo=="a") | .ok')" == "false" ]] || { echo "FAIL: failed repo should have ok:false: $jout"; errors=$((errors+1)); }
grep -q 'fetch failed' "$EF" || { echo "FAIL: fetch-failure message should be on stderr: $(cat "$EF")"; errors=$((errors+1)); }
rm -rf "$WF" "$EF"

# 14. --push --dry-run --json -> array, would-push*, clean stdout, log on stderr (bare origin OUTSIDE the workspace)
WP=$(mktemp -d); BARE=$(mktemp -d)/up.git
git init -b main --bare "$BARE" &>/dev/null
git clone "$BARE" "$WP/a" &>/dev/null
git -C "$WP/a" config user.email t@t.t; git -C "$WP/a" config user.name t
git -C "$WP/a" commit --allow-empty -m c1 &>/dev/null
git -C "$WP/a" push -u origin main &>/dev/null
git -C "$WP/a" checkout -b feat/x &>/dev/null
git -C "$WP/a" commit --allow-empty -m work &>/dev/null
EP=$(mktemp)
jout=$(MRA_WORKSPACE="$WP" bash "$SCRIPT_DIR/bin/mra.sh" sync --push --dry-run --json 2>"$EP")
printf '%s' "$jout" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "FAIL: --push --dry-run --json should be a JSON array: $jout"; errors=$((errors+1)); }
[[ "$(printf '%s' "$jout" | jq -r '.[] | select(.repo=="a") | .action')" =~ ^(would-push|would-push-new|up-to-date)$ ]] || { echo "FAIL: push dry-run action should be would-push*/up-to-date: $jout"; errors=$((errors+1)); }
case "$jout" in *'[sync]'*) echo "FAIL: --push --json stdout must not contain [sync] tag: $jout"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$WP" "$BARE" "$EP"

rm -rf "$WS"

# 15. text-mode regression: sync --safe (no --json) emits human log lines, not JSON
WT=$(mktemp -d)
git -C "$WT" init -b main a &>/dev/null
git -C "$WT/a" config user.email t@t.t; git -C "$WT/a" config user.name t
git -C "$WT/a" commit --allow-empty -m init &>/dev/null
tout=$(MRA_WORKSPACE="$WT" bash "$SCRIPT_DIR/bin/mra.sh" sync --safe 2>&1) || true
case "$tout" in *'[sync]'*) : ;; *) echo "FAIL: text-mode --safe should emit [sync] log lines: $tout"; errors=$((errors+1)) ;; esac
if printf '%s' "$tout" | jq -e 'type=="array"' >/dev/null 2>&1; then echo "FAIL: text-mode --safe must not emit a JSON array: $tout"; errors=$((errors+1)); fi
rm -rf "$WT"

if [[ $errors -eq 0 ]]; then
  echo "PASS: sync flag discipline tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
