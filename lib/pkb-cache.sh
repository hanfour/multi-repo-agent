#!/usr/bin/env bash
# PKB cache: dir/meta/freshness, doc validity, and file-mtime tracking.

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
pkb_dir() {
  local project_dir="$1"
  echo "$project_dir/$PKB_DIR_NAME"
}

# Self-ignore the .mra cache directory so mra's per-project artifacts never
# pollute the target project's git origin. Mirrors the .collab/.gitignore that
# `mra init` writes for the workspace. Idempotent; leaves an existing file alone.
pkb_ensure_gitignore() {
  local project_dir="$1"
  local mra_root="$project_dir/${PKB_DIR_NAME%%/*}"   # <project_dir>/.mra
  local ignore_file="$mra_root/.gitignore"
  [[ -f "$ignore_file" ]] && return 0
  mkdir -p "$mra_root"
  printf '*\n' > "$ignore_file"
}

pkb_exists() {
  local project_dir="$1"
  [[ -f "$(pkb_dir "$project_dir")/meta.json" ]]
}

# A generated PKB doc is valid only if it is substantive — not an agent error
# string (a cut-off generator emits "Error: Reached max turns ...") and not
# trivially short. Without this guard a failed/cut-off generator silently
# pollutes the PKB, and the review agents then consume the garbage as context.
_pkb_valid_doc() {
  local content="$1"
  [[ -z "${content//[[:space:]]/}" ]] && return 1            # empty / whitespace-only
  case "$content" in
    "Error:"*|"API Error"*|"Execution error"*) return 1 ;;   # agent error output
  esac
  [[ "${#content}" -lt 80 ]] && return 1                     # too short to be a real doc
  return 0
}

# Move a freshly generated doc into place only if it passes _pkb_valid_doc;
# otherwise discard it (with a warning) so a cut-off/failed generator never
# pollutes the PKB. A skipped core doc just means that knowledge layer is
# absent — far better than feeding the review agents an error string.
_pkb_keep_doc() {
  local src="$1" dst="$2"
  if [[ -s "$src" ]] && _pkb_valid_doc "$(cat "$src")"; then
    mv "$src" "$dst"
  else
    log_warn "PKB: $(basename "$dst") generation failed/cut off — skipping (re-run 'mra analyze' or raise MRA_PKB_AGENT_MAX_TURNS)" "pkb" >&2
    rm -f "$src"
    # On a rebuild, also drop a STALE INVALID dst (e.g. a prior error string) so
    # the PKB never serves garbage. A valid prior doc is preserved (better than
    # nothing when a regen flakes).
    [[ -f "$dst" ]] && ! _pkb_valid_doc "$(cat "$dst")" && rm -f "$dst"
  fi
}

pkb_age_hours() {
  local project_dir="$1"
  local meta_file="$(pkb_dir "$project_dir")/meta.json"
  if [[ ! -f "$meta_file" ]]; then echo "999999"; return; fi

  local last_updated
  last_updated=$(jq -r '.lastUpdated // "1970-01-01T00:00:00Z"' "$meta_file" 2>/dev/null)
  local now_epoch last_epoch
  now_epoch=$(date +%s)
  # The timestamp is UTC (trailing Z): BSD date needs -u or it parses it
  # as local time. GNU date lacks -j entirely; -d handles the Z suffix.
  last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_updated" +%s 2>/dev/null \
    || date -d "$last_updated" +%s 2>/dev/null \
    || echo "0")
  echo $(( (now_epoch - last_epoch) / 3600 ))
}

# ---------------------------------------------------------------------------
# Meta management
# ---------------------------------------------------------------------------
pkb_init_meta() {
  local project_dir="$1" project="$2"
  local pkb="$(pkb_dir "$project_dir")"
  mkdir -p "$pkb/modules"
  pkb_ensure_gitignore "$project_dir"

  cat > "$pkb/meta.json" <<EOF
{
  "version": $PKB_VERSION,
  "project": "$project",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastUpdated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastReviewedCommit": "$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "")",
  "generatedFiles": [],
  "moduleCount": 0
}
EOF
}

pkb_update_meta() {
  local project_dir="$1"
  local pkb="$(pkb_dir "$project_dir")"
  local meta_file="$pkb/meta.json"
  [[ ! -f "$meta_file" ]] && return

  local module_count
  module_count=$(find "$pkb/modules" -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')

  local generated_files
  generated_files=$(find "$pkb" -name '*.md' -not -path '*/modules/*' 2>/dev/null | \
    while read -r f; do basename "$f"; done | jq -R -s 'split("\n") | map(select(length > 0))')

  local tmp
  tmp=$(mktemp)
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg commit "$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "")" \
     --argjson mc "$module_count" \
     --argjson gf "$generated_files" \
     '.lastUpdated = $ts | .lastReviewedCommit = $commit | .moduleCount = $mc | .generatedFiles = $gf' \
     "$meta_file" > "$tmp" && mv "$tmp" "$meta_file"
}

# ---------------------------------------------------------------------------
# Staleness snapshot (issue #20) — git blob-hash based
#
# At PKB generation/update time we record the HEAD commit plus a
# path→blob-hash map of files that are dirty at that moment (their content is
# exactly what the PKB just distilled). Later, pkb_stale_files() reports every
# file that changed since — committed drift AND working-tree edits, including
# deletions — so consumers can warn instead of silently serving stale
# knowledge. Non-git projects keep the mtime fallback.
# ---------------------------------------------------------------------------
pkb_record_snapshot() {
  local project_dir="$1" meta_file
  meta_file="$(pkb_dir "$project_dir")/meta.json"
  [[ -f "$meta_file" ]] || return 0
  git -C "$project_dir" rev-parse HEAD >/dev/null 2>&1 || return 0

  local head dirty_json
  head=$(git -C "$project_dir" rev-parse HEAD)
  dirty_json=$(_pkb_dirty_hashes "$project_dir")

  local tmp
  tmp=$(mktemp)
  jq --arg c "$head" --argjson d "$dirty_json" \
     '.snapshotCommit = $c | .snapshotDirty = $d' "$meta_file" > "$tmp" && mv "$tmp" "$meta_file"
}

# path→blob-hash JSON object for every file git reports as changed right now.
# A deleted/missing path hashes to "" so a later change is distinguishable.
_pkb_dirty_hashes() {
  local project_dir="$1" path hash json="{}"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ -f "$project_dir/$path" ]]; then
      hash=$(git -C "$project_dir" hash-object -- "$path" 2>/dev/null || echo "")
    else
      hash=""
    fi
    json=$(jq --arg k "$path" --arg v "$hash" '. + {($k): $v}' <<<"$json")
  done < <(_pkb_git_dirty_paths "$project_dir")
  printf '%s' "$json"
}

# Paths git currently reports as changed (staged, unstaged, untracked,
# deleted). Rename entries yield the NEW path; porcelain quoting is stripped.
_pkb_git_dirty_paths() {
  local project_dir="$1" line path
  git -C "$project_dir" status --porcelain 2>/dev/null | while IFS= read -r line; do
    path="${line:3}"
    path="${path##* -> }"
    path="${path%\"}"; path="${path#\"}"
    printf '%s\n' "$path"
  done
}

# List files stale relative to the recorded snapshot: committed drift
# (snapshotCommit..HEAD) plus current dirty files whose content differs from
# what was dirty at snapshot time. Empty output = PKB fresh, or no
# snapshot/no git (callers keep their mtime fallback in that case).
pkb_stale_files() {
  local project_dir="$1" meta_file
  meta_file="$(pkb_dir "$project_dir")/meta.json"
  [[ -f "$meta_file" ]] || return 0
  git -C "$project_dir" rev-parse HEAD >/dev/null 2>&1 || return 0

  local snap_commit snap_dirty
  snap_commit=$(jq -r '.snapshotCommit // ""' "$meta_file" 2>/dev/null)
  [[ -n "$snap_commit" ]] || return 0
  snap_dirty=$(jq -c '.snapshotDirty // {}' "$meta_file" 2>/dev/null)

  {
    git -C "$project_dir" diff --name-only "$snap_commit" HEAD 2>/dev/null || true
    local path hash recorded
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if [[ -f "$project_dir/$path" ]]; then
        hash=$(git -C "$project_dir" hash-object -- "$path" 2>/dev/null || echo "")
      else
        hash=""
      fi
      recorded=$(jq -r --arg k "$path" '.[$k] // "__absent__"' <<<"$snap_dirty")
      [[ "$hash" == "$recorded" ]] || printf '%s\n' "$path"
    done < <(_pkb_git_dirty_paths "$project_dir")
  } | sort -u
}

# ---------------------------------------------------------------------------
# Record source file mtimes for incremental change detection
# Stores mtime of key source dirs in meta.json
# ---------------------------------------------------------------------------
_pkb_record_mtimes() {
  local project_dir="$1" pkb="$2"
  local meta_file="$pkb/meta.json"
  [[ ! -f "$meta_file" ]] && return

  local mtimes="{}"
  # Record mtime of key config/source files
  for f in package.json tsconfig.json Gemfile go.mod requirements.txt \
           .eslintrc.js .eslintrc.json CLAUDE.md AGENTS.md; do
    local full_path="$project_dir/$f"
    if [[ -f "$full_path" ]]; then
      local mtime
      mtime=$(stat -f %m "$full_path" 2>/dev/null || stat -c %Y "$full_path" 2>/dev/null || echo "0")
      mtimes=$(echo "$mtimes" | jq --arg k "$f" --arg v "$mtime" '. + {($k): ($v | tonumber)}')
    fi
  done

  # Record mtime of source directories
  for d in src frontend/src backend/src app lib; do
    local full_dir="$project_dir/$d"
    if [[ -d "$full_dir" ]]; then
      local newest_mtime
      newest_mtime=$(find "$full_dir" -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.rb' -o -name '*.go' -o -name '*.py' 2>/dev/null | \
        xargs stat -f %m 2>/dev/null | sort -rn | head -1 || echo "0")
      [[ -z "$newest_mtime" ]] && newest_mtime=0
      mtimes=$(echo "$mtimes" | jq --arg k "$d" --arg v "$newest_mtime" '. + {($k): ($v | tonumber)}')
    fi
  done

  local tmp
  tmp=$(mktemp)
  jq --argjson mtimes "$mtimes" '.sourceMtimes = $mtimes' "$meta_file" > "$tmp" && mv "$tmp" "$meta_file"
}

# Check which source areas have changed since last PKB generation
# Returns: space-separated list of changed areas (e.g., "package.json src")
_pkb_check_mtimes() {
  local project_dir="$1"
  local pkb
  pkb="$(pkb_dir "$project_dir")"
  local meta_file="$pkb/meta.json"

  if [[ ! -f "$meta_file" ]] || ! jq -e '.sourceMtimes' "$meta_file" &>/dev/null; then
    echo "all"
    return
  fi

  local changed=""
  local stored_mtimes
  stored_mtimes=$(jq -c '.sourceMtimes // {}' "$meta_file")

  # Check config files
  for f in package.json tsconfig.json Gemfile go.mod requirements.txt \
           .eslintrc.js .eslintrc.json CLAUDE.md AGENTS.md; do
    local full_path="$project_dir/$f"
    if [[ -f "$full_path" ]]; then
      local current_mtime stored_mtime
      current_mtime=$(stat -f %m "$full_path" 2>/dev/null || stat -c %Y "$full_path" 2>/dev/null || echo "0")
      stored_mtime=$(echo "$stored_mtimes" | jq -r --arg k "$f" '.[$k] // 0')
      if [[ "$current_mtime" != "$stored_mtime" ]]; then
        changed="$changed $f"
      fi
    fi
  done

  # Check source directories
  for d in src frontend/src backend/src app lib; do
    local full_dir="$project_dir/$d"
    if [[ -d "$full_dir" ]]; then
      local current_mtime stored_mtime
      current_mtime=$(find "$full_dir" -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.rb' -o -name '*.go' -o -name '*.py' 2>/dev/null | \
        xargs stat -f %m 2>/dev/null | sort -rn | head -1 || echo "0")
      [[ -z "$current_mtime" ]] && current_mtime=0
      stored_mtime=$(echo "$stored_mtimes" | jq -r --arg k "$d" '.[$k] // 0')
      if [[ "$current_mtime" != "$stored_mtime" ]]; then
        changed="$changed $d"
      fi
    fi
  done

  echo "${changed# }"
}
