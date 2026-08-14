#!/usr/bin/env bash
# Single source of truth for review diff acquisition.
# mode "working": working tree vs HEAD (staged + unstaged tracked changes; untracked excluded).
# mode "range"  : an explicit git range expression (e.g. "base...HEAD", "base...ref", "A..B").
#                 Any mode other than "working" is treated as a range expression.

# Paths whose CONTENT is not worth quoting into a review prompt: each is
# generated from something else that IS in the diff, so a reviewer reads the
# source and regenerates the artifact rather than reviewing the artifact.
#
# They also dominate the byte budget, and that budget is real. On 2026-08-14
# onead/super-dsp-2.0#892 sent codex 1,087,072 characters against its 1,048,576
# limit and the review died; pnpm-lock.yaml alone accounted for 465,442 of them
# — 46% of the diff for a file nobody reads. Omitting it puts the same PR at
# roughly 620,000, well inside the limit, without losing a line anyone would
# have reviewed.
#
# Override with MRA_REVIEW_GENERATED_GLOBS (newline-separated git glob
# pathspecs) for a repo whose generated set differs.
_review_generated_globs() {
  if [[ -n "${MRA_REVIEW_GENERATED_GLOBS:-}" ]]; then
    printf '%s\n' "$MRA_REVIEW_GENERATED_GLOBS"
    return 0
  fi
  cat <<'GLOBS'
**/package-lock.json
**/npm-shrinkwrap.json
**/pnpm-lock.yaml
**/yarn.lock
**/bun.lockb
**/composer.lock
**/Gemfile.lock
**/Cargo.lock
**/poetry.lock
**/uv.lock
**/Pipfile.lock
**/go.sum
**/*.min.js
**/*.min.css
**/*.map
GLOBS
}

# Emit the "these changed but are not quoted" account. Silence here would be
# worse than the bytes: a review that never mentions the lockfile reads as a
# review that saw no lockfile change.
_review_generated_summary() {
  local project_dir="$1"; shift
  local -a range=("$@")
  local -a include=() glob
  while IFS= read -r glob; do
    [[ -n "$glob" ]] && include+=(":(glob)$glob")
  done < <(_review_generated_globs)
  [[ ${#include[@]} -gt 0 ]] || return 0

  local numstat
  numstat=$(git -C "$project_dir" diff --numstat "${range[@]}" -- "${include[@]}" 2>/dev/null) || return 0
  [[ -n "$numstat" ]] || return 0

  printf '\n## Generated files — changed, content not quoted\n'
  printf 'These are derived from sources included above. Review the source; regenerate these.\n'
  local add del path
  while IFS=$'\t' read -r add del path; do
    [[ -n "$path" ]] || continue
    printf -- '- %s (+%s -%s)\n' "$path" "$add" "$del"
  done <<< "$numstat"
}

review_diff_text() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  local -a range=()
  if [[ "$mode" == "working" ]]; then range=(HEAD); else range=("$arg"); fi

  # Escape hatch: a caller that genuinely wants every byte can ask for it.
  if [[ "${MRA_REVIEW_QUOTE_GENERATED:-}" == "1" ]]; then
    git -C "$project_dir" diff "${range[@]}" 2>/dev/null || echo ""
    return 0
  fi

  local -a exclude=() glob
  while IFS= read -r glob; do
    [[ -n "$glob" ]] && exclude+=(":(exclude,glob)$glob")
  done < <(_review_generated_globs)

  # git applies an exclude-only pathspec to the full result set, so no explicit
  # include is needed and none is added: a "." here would silently narrow the
  # diff to the cwd for a project_dir below the repo root.
  git -C "$project_dir" diff "${range[@]}" -- "${exclude[@]}" 2>/dev/null || echo ""
  _review_generated_summary "$project_dir" "${range[@]}"
}

# The changed-files list is a manifest, not a quote: it stays complete, so the
# model can always see that a generated file moved even when its content is
# summarised rather than shown.
review_diff_files() {
  local project_dir="$1" mode="$2" arg="${3:-}"
  if [[ "$mode" == "working" ]]; then
    git -C "$project_dir" diff --name-only HEAD 2>/dev/null || echo ""
  else
    git -C "$project_dir" diff --name-only "$arg" 2>/dev/null || echo ""
  fi
}
