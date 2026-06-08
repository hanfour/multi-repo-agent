#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"
source "$SCRIPT_DIR/lib/branch-ops.sh"

errors=0

# valid names
for n in feat/x bugfix-123 release/v1.2.0; do
  if ! validate_branch_name "$n"; then echo "FAIL: '$n' should be valid"; errors=$((errors+1)); fi
done
# invalid: empty, leading dash, git-invalid
for n in "" "-foo" "--all" "feat/x..y" "feat~1" "feat^" "with space"; do
  if validate_branch_name "$n"; then echo "FAIL: '$n' should be INVALID"; errors=$((errors+1)); fi
done

# --- create_branch_workspace across a multi-repo fixture ---
WS=$(mktemp -d)
for r in a b; do
  mkdir -p "$WS/$r"
  git -C "$WS/$r" init -b main . &>/dev/null
  git -C "$WS/$r" config user.email t@t.t; git -C "$WS/$r" config user.name t
  git -C "$WS/$r" commit --allow-empty -m init &>/dev/null
done
# repo b already has feat/x (should be switched, not fail)
git -C "$WS/b" branch feat/x &>/dev/null

create_branch_workspace "$WS" feat/x &>/dev/null
for r in a b; do
  cur=$(git -C "$WS/$r" rev-parse --abbrev-ref HEAD)
  if [[ "$cur" != "feat/x" ]]; then echo "FAIL: $r should be on feat/x, got $cur"; errors=$((errors+1)); fi
done

# invalid name => non-zero, no repo changed
git -C "$WS/a" checkout main &>/dev/null
before=$(git -C "$WS/a" rev-parse --abbrev-ref HEAD)
if create_branch_workspace "$WS" "feat/x..y" &>/dev/null; then
  echo "FAIL: invalid name should make create_branch_workspace return non-zero"; errors=$((errors+1))
fi
after=$(git -C "$WS/a" rev-parse --abbrev-ref HEAD)
if [[ "$before" != "$after" ]]; then echo "FAIL: invalid name must not change any branch"; errors=$((errors+1)); fi

# named-repo subset: only repo a
git -C "$WS/a" checkout main &>/dev/null
create_branch_workspace "$WS" feat/y a &>/dev/null
if [[ "$(git -C "$WS/a" rev-parse --abbrev-ref HEAD)" != "feat/y" ]]; then
  echo "FAIL: repo a should be on feat/y"; errors=$((errors+1))
fi
if git -C "$WS/b" show-ref --verify --quiet refs/heads/feat/y; then
  echo "FAIL: repo b should NOT have feat/y (not in subset)"; errors=$((errors+1))
fi
rm -rf "$WS"

# --- switch_branch_workspace: switch where branch exists, leave others untouched ---
WS2=$(mktemp -d)
for r in a b; do
  mkdir -p "$WS2/$r"
  git -C "$WS2/$r" init -b main . &>/dev/null
  git -C "$WS2/$r" config user.email t@t.t; git -C "$WS2/$r" config user.name t
  git -C "$WS2/$r" commit --allow-empty -m init &>/dev/null
done
# only repo a has feat/x; both currently on main
git -C "$WS2/a" branch feat/x &>/dev/null

switch_branch_workspace "$WS2" feat/x &>/dev/null
if [[ "$(git -C "$WS2/a" rev-parse --abbrev-ref HEAD)" != "feat/x" ]]; then
  echo "FAIL: repo a should switch to feat/x"; errors=$((errors+1))
fi
if [[ "$(git -C "$WS2/b" rev-parse --abbrev-ref HEAD)" != "main" ]]; then
  echo "FAIL: repo b (no feat/x) should remain on main"; errors=$((errors+1))
fi

# invalid name => non-zero
if switch_branch_workspace "$WS2" "-foo" &>/dev/null; then
  echo "FAIL: invalid name should make switch_branch_workspace return non-zero"; errors=$((errors+1))
fi
rm -rf "$WS2"

# --- validate_repo_name: only flat names allowed ---
for n in api my-repo repo123; do
  if ! validate_repo_name "$n"; then echo "FAIL: '$n' should be a valid repo name"; errors=$((errors+1)); fi
done
for n in "a/b" "." ".." "-foo" "../x"; do
  if validate_repo_name "$n"; then echo "FAIL: '$n' should be an INVALID repo name"; errors=$((errors+1)); fi
done

# --- create_branch_workspace rejects a traversal repo name without touching the filesystem ---
WSV=$(mktemp -d)
mkdir -p "$WSV/api"
git -C "$WSV/api" init -b main . &>/dev/null
git -C "$WSV/api" config user.email t@t.t; git -C "$WSV/api" config user.name t
git -C "$WSV/api" commit --allow-empty -m init &>/dev/null
if create_branch_workspace "$WSV" feat/x "../evil" &>/dev/null; then
  echo "FAIL: create_branch_workspace should return non-zero when a repo name is invalid"; errors=$((errors+1))
fi
if [[ -e "$WSV/../evil" ]]; then echo "FAIL: traversal name must not create anything outside the workspace"; errors=$((errors+1)); fi
rm -rf "$WSV"

if [[ $errors -eq 0 ]]; then
  echo "PASS: branch-ops validation tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
