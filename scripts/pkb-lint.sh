#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/pkb-cache.sh"

usage() {
  echo "Usage: pkb-lint.sh <workspace-dir-or-repo-dir> [...]" >&2
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

shopt -s nullglob
invalid_count=0

_pkb_lint_repo() {
  local repo_dir="$1" file content reason
  # Match validated outputs: core docs in lib/pkb.sh:87-90 and module docs in
  # lib/pkb-prompts.sh:263-269 (also updated through lib/pkb.sh:202).
  for file in \
    "$repo_dir"/.mra/pkb/sitemap.md \
    "$repo_dir"/.mra/pkb/architecture.md \
    "$repo_dir"/.mra/pkb/conventions.md \
    "$repo_dir"/.mra/pkb/api-surface.md \
    "$repo_dir"/.mra/pkb/modules/*.md; do
    [[ -f "$file" ]] || continue
    content=$(<"$file")
    if ! _pkb_valid_doc "$content" reason; then
      printf 'INVALID %s: %s\n' "$file" "$reason"
      invalid_count=$((invalid_count + 1))
    fi
  done
}

for input_dir in "$@"; do
  if [[ ! -d "$input_dir" ]]; then
    printf 'pkb-lint: not a directory: %s\n' "$input_dir" >&2
    exit 2
  fi
  if [[ -d "$input_dir/.mra/pkb" ]]; then
    _pkb_lint_repo "$input_dir"
  else
    for repo_dir in "$input_dir"/*; do
      [[ -d "$repo_dir/.mra/pkb" ]] || continue
      _pkb_lint_repo "$repo_dir"
    done
  fi
done

printf 'Invalid PKB docs: %d\n' "$invalid_count"
if [[ "$invalid_count" -gt 0 ]]; then
  exit 1
fi
