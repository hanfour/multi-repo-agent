#!/usr/bin/env bash
# Single source of truth for review diff acquisition.
# mode "working": working tree vs HEAD (staged + unstaged tracked changes; untracked excluded).
# mode "range"  : an explicit git range expression (e.g. "base...HEAD", "base...ref", "A..B").
#                 Any mode other than "working" is treated as a range expression.

review_diff_text() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff "$arg" 2>/dev/null || echo ""
  fi
}

review_diff_files() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff --name-only HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff --name-only "$arg" 2>/dev/null || echo ""
  fi
}
