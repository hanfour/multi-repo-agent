#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch.sh"
source "$SCRIPT_DIR/lib/review-select.sh"

errors=0
TEST_DIR=$(mktemp -d)

# Test get_default_branch
mkdir -p "$TEST_DIR/repo"
cd "$TEST_DIR/repo"
git init -b main . &>/dev/null
git commit --allow-empty -m "init" &>/dev/null
result=$(get_default_branch "$TEST_DIR/repo")
if [[ "$result" != "main" ]]; then
  echo "FAIL: default branch should be main, got $result"; errors=$((errors+1))
fi

# Test is_on_default_branch
result=$(is_on_default_branch "$TEST_DIR/repo")
if [[ $? -ne 0 ]]; then
  echo "FAIL: should be on default branch"; errors=$((errors+1))
fi

# Test is_on_default_branch (feature branch)
cd "$TEST_DIR/repo"
git checkout -b feature/test &>/dev/null
if is_on_default_branch "$TEST_DIR/repo"; then
  echo "FAIL: should NOT be on default branch"; errors=$((errors+1))
fi

# Test should_skip_dir (no .git)
mkdir -p "$TEST_DIR/no-git"
if ! should_skip_dir "$TEST_DIR/no-git"; then
  echo "FAIL: dir without .git should be skipped"; errors=$((errors+1))
fi

# --- safe_sync_repo: fast-forward a behind, clean feature branch ---
SAFE_DIR=$(mktemp -d)
git -C "$SAFE_DIR" init -b main --bare up &>/dev/null
git clone "$SAFE_DIR/up" "$SAFE_DIR/a" &>/dev/null
git -C "$SAFE_DIR/a" config user.email t@t.t; git -C "$SAFE_DIR/a" config user.name t
git -C "$SAFE_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SAFE_DIR/a" push -u origin main &>/dev/null
# second clone advances origin/main
git clone "$SAFE_DIR/up" "$SAFE_DIR/b" &>/dev/null
git -C "$SAFE_DIR/b" config user.email t@t.t; git -C "$SAFE_DIR/b" config user.name t
git -C "$SAFE_DIR/b" commit --allow-empty -m c2 &>/dev/null
git -C "$SAFE_DIR/b" push origin main &>/dev/null
# repo "a" is now behind by 1, clean => should fast-forward
before=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
safe_sync_repo "$SAFE_DIR/a" &>/dev/null
after=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
if [[ "$before" == "$after" ]]; then
  echo "FAIL: safe_sync_repo should fast-forward a behind/clean repo"; errors=$((errors+1))
fi

# --- safe_sync_repo: must NOT touch a dirty working tree ---
echo "dirty" > "$SAFE_DIR/a/file.txt"; git -C "$SAFE_DIR/a" add file.txt
git -C "$SAFE_DIR/b" commit --allow-empty -m c3 &>/dev/null
git -C "$SAFE_DIR/b" push origin main &>/dev/null
git -C "$SAFE_DIR/a" fetch --quiet
before=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
safe_sync_repo "$SAFE_DIR/a" &>/dev/null || true
after=$(git -C "$SAFE_DIR/a" rev-parse HEAD)
if [[ "$before" != "$after" ]]; then
  echo "FAIL: safe_sync_repo must NOT move HEAD when working tree is dirty"; errors=$((errors+1))
fi
rm -rf "$SAFE_DIR"

# --- push_repo: pushes a local-ahead branch to the bare remote ---
PUSH_DIR=$(mktemp -d)
git -C "$PUSH_DIR" init -b main --bare up &>/dev/null
git clone "$PUSH_DIR/up" "$PUSH_DIR/a" &>/dev/null
git -C "$PUSH_DIR/a" config user.email t@t.t; git -C "$PUSH_DIR/a" config user.name t
git -C "$PUSH_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$PUSH_DIR/a" push -u origin main &>/dev/null
git -C "$PUSH_DIR/a" commit --allow-empty -m c2 &>/dev/null   # now ahead by 1
before=$(git -C "$PUSH_DIR/up" rev-parse main)
push_repo "$PUSH_DIR/a" false &>/dev/null
after=$(git -C "$PUSH_DIR/up" rev-parse main)
if [[ "$before" == "$after" ]]; then echo "FAIL: push_repo should advance the bare remote"; errors=$((errors+1)); fi

# --- push_repo dry-run: does NOT advance the remote even when ahead ---
git -C "$PUSH_DIR/a" commit --allow-empty -m c3 &>/dev/null   # ahead again
before=$(git -C "$PUSH_DIR/up" rev-parse main)
push_repo "$PUSH_DIR/a" true &>/dev/null
after=$(git -C "$PUSH_DIR/up" rev-parse main)
if [[ "$before" != "$after" ]]; then echo "FAIL: dry-run push must NOT advance the remote"; errors=$((errors+1)); fi

# --- push_repo: new branch with no upstream gets pushed with -u ---
git -C "$PUSH_DIR/a" checkout -b feat/new &>/dev/null
git -C "$PUSH_DIR/a" commit --allow-empty -m f1 &>/dev/null
push_repo "$PUSH_DIR/a" false &>/dev/null
new_upstream=$(git -C "$PUSH_DIR/a" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")
if [[ "$new_upstream" != "origin/feat/new" ]]; then
  echo "FAIL: push_repo push-new should set upstream origin/feat/new, got '$new_upstream'"; errors=$((errors+1))
fi

# --- push_repo: behind branch is NOT pushed ---
git clone "$PUSH_DIR/up" "$PUSH_DIR/b" &>/dev/null
git -C "$PUSH_DIR/b" config user.email t@t.t; git -C "$PUSH_DIR/b" config user.name t
git -C "$PUSH_DIR/b" commit --allow-empty -m adv &>/dev/null
git -C "$PUSH_DIR/b" push origin main &>/dev/null   # advance remote main
git -C "$PUSH_DIR/a" checkout main &>/dev/null
git -C "$PUSH_DIR/a" fetch --quiet
before=$(git -C "$PUSH_DIR/up" rev-parse main)
push_repo "$PUSH_DIR/a" false &>/dev/null
after=$(git -C "$PUSH_DIR/up" rev-parse main)
if [[ "$before" != "$after" ]]; then echo "FAIL: behind branch must not be pushed"; errors=$((errors+1)); fi
rm -rf "$PUSH_DIR"

# --- sync_review_workspace: sync half + target selection (review stubbed) ---
SR_DIR=$(mktemp -d)
git -C "$SR_DIR" init -b main --bare up &>/dev/null
git clone "$SR_DIR/up" "$SR_DIR/a" &>/dev/null
git -C "$SR_DIR/a" config user.email t@t.t; git -C "$SR_DIR/a" config user.name t
git -C "$SR_DIR/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SR_DIR/a" push -u origin main &>/dev/null
# advance origin/main via a second clone, so repo a is behind -> safe_sync ff -> "changed"
git clone "$SR_DIR/up" "$SR_DIR/b" &>/dev/null
git -C "$SR_DIR/b" config user.email t@t.t; git -C "$SR_DIR/b" config user.name t
git -C "$SR_DIR/b" commit --allow-empty -m c2 &>/dev/null
git -C "$SR_DIR/b" push origin main &>/dev/null
# repo b: bring up-to-date with its own clone so it is NOT changed and stays on-default
git -C "$SR_DIR/b" fetch --quiet; git -C "$SR_DIR/b" pull --ff-only --quiet &>/dev/null || true

# stub review_project to avoid real Claude; record which repos were reviewed
REVIEW_LOG=$(mktemp)
review_project() { echo "$2" >> "$REVIEW_LOG"; return 0; }

sync_review_workspace "$SR_DIR" &>/dev/null
# repo a was behind -> fast-forwarded -> HEAD moved -> in 'changed' -> reviewed
if ! grep -qx a "$REVIEW_LOG"; then echo "FAIL: repo a (fast-forwarded) should be reviewed"; errors=$((errors+1)); fi
# repo b: on default branch, up-to-date, not changed -> NOT reviewed
if grep -qx b "$REVIEW_LOG"; then echo "FAIL: repo b (clean on-default) should NOT be reviewed"; errors=$((errors+1)); fi
rm -rf "$SR_DIR" "$REVIEW_LOG"

# --- push_repo: a diverged branch is NOT pushed (integration) ---
DV_DIR=$(mktemp -d)
git -C "$DV_DIR" init -b main --bare up &>/dev/null
git clone "$DV_DIR/up" "$DV_DIR/a" &>/dev/null
git -C "$DV_DIR/a" config user.email t@t.t; git -C "$DV_DIR/a" config user.name t
git -C "$DV_DIR/a" commit --allow-empty -m base &>/dev/null
git -C "$DV_DIR/a" push -u origin main &>/dev/null
# second clone advances origin/main
git clone "$DV_DIR/up" "$DV_DIR/b" &>/dev/null
git -C "$DV_DIR/b" config user.email t@t.t; git -C "$DV_DIR/b" config user.name t
git -C "$DV_DIR/b" commit --allow-empty -m bcommit &>/dev/null
git -C "$DV_DIR/b" push origin main &>/dev/null
# a commits locally too => ahead AND behind => diverged
git -C "$DV_DIR/a" commit --allow-empty -m acommit &>/dev/null
git -C "$DV_DIR/a" fetch --quiet
before=$(git -C "$DV_DIR/up" rev-parse main)
push_repo "$DV_DIR/a" false &>/dev/null || true
after=$(git -C "$DV_DIR/up" rev-parse main)
if [[ "$before" != "$after" ]]; then echo "FAIL: diverged branch must not advance the remote"; errors=$((errors+1)); fi
rm -rf "$DV_DIR"

rm -rf "$TEST_DIR"

# --- sync_result_json: jq object, correct types, injection-safe ---
o=$(sync_result_json app pulled true)
printf '%s' "$o" | jq -e . >/dev/null 2>&1 || { echo "FAIL: sync_result_json not valid JSON: $o"; errors=$((errors+1)); }
[[ "$(printf '%s' "$o" | jq -r '.repo')" == "app" ]] || { echo "FAIL: .repo wrong: $o"; errors=$((errors+1)); }
[[ "$(printf '%s' "$o" | jq -r '.action')" == "pulled" ]] || { echo "FAIL: .action wrong: $o"; errors=$((errors+1)); }
printf '%s' "$o" | jq -e '.ok==true and (.ok|type)=="boolean"' >/dev/null 2>&1 || { echo "FAIL: .ok should be boolean true: $o"; errors=$((errors+1)); }
of=$(sync_result_json x clone-failed false)
printf '%s' "$of" | jq -e '.ok==false and (.ok|type)=="boolean"' >/dev/null 2>&1 || { echo "FAIL: .ok should be boolean false: $of"; errors=$((errors+1)); }
# injection-safety: a repo name with a double-quote stays valid JSON
oq=$(sync_result_json 'a"b' pulled true)
printf '%s' "$oq" | jq -e . >/dev/null 2>&1 || { echo "FAIL: quote in repo broke JSON: $oq"; errors=$((errors+1)); }
[[ "$(printf '%s' "$oq" | jq -r '.repo')" == 'a"b' ]] || { echo "FAIL: quoted repo not preserved: $oq"; errors=$((errors+1)); }
# guard: non-boolean ok rejected (non-zero, no JSON)
if sync_result_json app pulled notabool >/dev/null 2>&1; then echo "FAIL: sync_result_json should reject non-boolean ok"; errors=$((errors+1)); fi

# --- _sync_record: file sink, no-op when SYNC_RESULT_FILE unset ---
unset SYNC_RESULT_FILE 2>/dev/null || true
_sync_record app pulled true   # must be a no-op, no error, no file
RF=$(mktemp); rm -f "$RF"      # a path that does not exist yet
SYNC_RESULT_FILE="$RF" _sync_record app pulled true
SYNC_RESULT_FILE="$RF" _sync_record lib up-to-date true
[[ -f "$RF" ]] || { echo "FAIL: _sync_record should create the sink file"; errors=$((errors+1)); }
[[ "$(wc -l < "$RF" | tr -d ' ')" == "2" ]] || { echo "FAIL: _sync_record should append one line per call: $(cat "$RF")"; errors=$((errors+1)); }
[[ "$(head -1 "$RF")" == $'app\tpulled\ttrue' ]] || { echo "FAIL: _sync_record line format wrong: $(head -1 "$RF")"; errors=$((errors+1)); }
rm -f "$RF"

# --- safe_sync_repo records its outcome to the SYNC_RESULT_FILE sink ---
# up-to-date fixture: clone a bare origin, commit+push, so local == origin/main
SS=$(mktemp -d)
git init -b main --bare "$SS/up.git" &>/dev/null
git clone "$SS/up.git" "$SS/a" &>/dev/null
git -C "$SS/a" config user.email t@t.t; git -C "$SS/a" config user.name t
git -C "$SS/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SS/a" push -u origin main &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" safe_sync_repo "$SS/a" >/dev/null 2>&1 || true
grep -qx $'a\tup-to-date\ttrue' "$RF" || { echo "FAIL: safe_sync_repo should record 'up-to-date true': $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$SS" "$RF"
# fetch-failure fixture: a repo with a bad origin
FF=$(mktemp -d)
git -C "$FF" init -b main a &>/dev/null
git -C "$FF/a" config user.email t@t.t; git -C "$FF/a" config user.name t
git -C "$FF/a" commit --allow-empty -m c1 &>/dev/null
git -C "$FF/a" remote add origin /nonexistent/x.git
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" safe_sync_repo "$FF/a" >/dev/null 2>&1 || true
grep -qx $'a\tfetch-failed\tfalse' "$RF" || { echo "FAIL: safe_sync_repo should record 'fetch-failed false': $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$FF" "$RF"

# --- push_repo records its outcome (dry-run, no real push) ---
PP=$(mktemp -d)
git init -b main --bare "$PP/up.git" &>/dev/null
git clone "$PP/up.git" "$PP/a" &>/dev/null
git -C "$PP/a" config user.email t@t.t; git -C "$PP/a" config user.name t
git -C "$PP/a" commit --allow-empty -m c1 &>/dev/null
git -C "$PP/a" push -u origin main &>/dev/null
# feature branch with no upstream + a commit -> push-new -> dry-run -> would-push-new
git -C "$PP/a" checkout -b feat/x &>/dev/null
git -C "$PP/a" commit --allow-empty -m work &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" push_repo "$PP/a" true >/dev/null 2>&1 || true
grep -qx $'a\twould-push-new\ttrue' "$RF" || { echo "FAIL: push_repo dry-run should record would-push-new: $(cat "$RF")"; errors=$((errors+1)); }
# back on default branch, up-to-date with origin -> up-to-date
git -C "$PP/a" checkout main &>/dev/null
: > "$RF"
SYNC_RESULT_FILE="$RF" push_repo "$PP/a" true >/dev/null 2>&1 || true
grep -qx $'a\tup-to-date\ttrue' "$RF" || { echo "FAIL: push_repo should record up-to-date: $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$PP" "$RF"

# --- sync_repo records its outcome ---
# clone fixture: a missing dir cloned from a local bare origin -> cloned
SD=$(mktemp -d); mkdir -p "$SD/origin" "$SD/ws"
git init -b main --bare "$SD/origin/a.git" &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" sync_repo "$SD/ws/a" "$SD/origin" >/dev/null 2>&1 || true
grep -qx $'a\tcloned\ttrue' "$RF" || { echo "FAIL: sync_repo should record cloned: $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$SD" "$RF"
# feature-branch fixture -> skipped-branch
SB=$(mktemp -d)
git -C "$SB" init -b main a &>/dev/null
git -C "$SB/a" config user.email t@t.t; git -C "$SB/a" config user.name t
git -C "$SB/a" commit --allow-empty -m c1 &>/dev/null
git -C "$SB/a" checkout -b feat/x &>/dev/null
RF=$(mktemp); : > "$RF"
SYNC_RESULT_FILE="$RF" sync_repo "$SB/a" "ignored-org" >/dev/null 2>&1 || true
grep -qx $'a\tskipped-branch\ttrue' "$RF" || { echo "FAIL: sync_repo should record skipped-branch: $(cat "$RF")"; errors=$((errors+1)); }
rm -rf "$SB" "$RF"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all sync tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
