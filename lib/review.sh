#!/usr/bin/env bash
# mra review: context-aware code review
#
# Usage:
#   mra review <project>              Terminal output (current branch vs main)
#   mra review <project> --pr <N>     Inline review on GitHub PR
#   mra review <project> --base <ref> Compare against specific branch
#   mra review <project> --no-debate  Skip debate, single-pass review

review_project() {
  local workspace="$1"
  shift
  local project="" pr_number="" base_ref="" model="sonnet" debate=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)
        if [[ $# -lt 2 ]]; then log_error "--pr requires a PR number" "review"; return 1; fi
        pr_number="$2"; shift 2 ;;
      --base)
        if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "review"; return 1; fi
        base_ref="$2"; shift 2 ;;
      --model)
        if [[ $# -lt 2 ]]; then log_error "--model requires a value" "review"; return 1; fi
        model="$2"; shift 2 ;;
      --no-debate)
        debate=false; shift ;;
      -*)
        log_error "unknown option: $1" "review"; return 1 ;;
      *)
        project="$1"; shift ;;
    esac
  done

  if [[ -z "$project" ]]; then
    log_error "usage: mra review <project> [--pr <N>] [--base <ref>]" "review"
    return 1
  fi

  local project_dir="$workspace/$project"
  if [[ ! -d "$project_dir" ]]; then
    log_error "$project: directory not found" "review"
    return 1
  fi

  local graph_file="$workspace/.collab/dep-graph.json"

  # --- Resolve base ref ---
  if [[ -z "$base_ref" ]]; then
    if [[ -n "$pr_number" ]]; then
      base_ref=$(resolve_pr_base "$project_dir" "$pr_number")
    else
      base_ref=$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    fi
  fi

  # --- Get project metadata from dep-graph ---
  local project_type="unknown" consumers="" deps=""
  if [[ -f "$graph_file" ]]; then
    project_type=$(jq -r --arg p "$project" '.projects[$p].type // "unknown"' "$graph_file" 2>/dev/null)
    consumers=$(jq -r --arg p "$project" '.projects[$p].consumedBy // [] | join(" ")' "$graph_file" 2>/dev/null)
    deps=$(jq -r --arg p "$project" '[.projects[$p].deps // {} | to_entries[].value[]] | unique | join(" ")' "$graph_file" 2>/dev/null)
  fi
  [[ "$project_type" == "null" ]] && project_type="unknown"

  # --- Detect API change ---
  local has_api_change="false"
  if [[ -d "$project_dir/.git" ]]; then
    local change_result
    change_result=$(is_api_change "$project_dir" "$project_type" 2>/dev/null || echo "low")
    [[ "${change_result%%|*}" == "high" ]] && has_api_change="true"
  fi

  # --- Output language ---
  local output_language=""
  output_language=$(config_get "outputLanguage" 2>/dev/null)
  [[ -z "$output_language" || "$output_language" == "null" ]] && output_language=""

  # --- Determine mode ---
  local output_mode="terminal"
  [[ -n "$pr_number" ]] && output_mode="inline"

  # --- Log context ---
  local mode_label="single-pass"
  [[ "$debate" == "true" ]] && mode_label="debate"
  log_progress "reviewing $project (type: $project_type, base: $base_ref, mode: $mode_label)" "review"
  [[ "$has_api_change" == "true" ]] && log_warn "API change detected — loading consumer context" "review"
  [[ -n "$consumers" ]] && log_info "consumers: $consumers" "review"

  # --- Build --add-dir args as string (for debate) and array (for single-pass) ---
  local claude_add_dirs_str=""
  local claude_args=("--add-dir" "$project_dir")
  claude_add_dirs_str="--add-dir $project_dir"
  for repo in $consumers $deps; do
    local repo_dir="$workspace/$repo"
    if [[ -d "$repo_dir" && "$repo" != "$project" ]]; then
      claude_args+=("--add-dir" "$repo_dir")
      claude_add_dirs_str="$claude_add_dirs_str --add-dir $repo_dir"
    fi
  done

  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # ===================================================================
  # DEBATE MODE: multi-agent adversarial review
  # ===================================================================
  if [[ "$debate" == "true" ]]; then
    local review_json
    review_json=$(run_debate_review \
      "$project" "$project_dir" "$graph_file" "$base_ref" \
      "$project_type" "$consumers" "$deps" "$has_api_change" \
      "$output_language" "$model" "$claude_add_dirs_str")

    if [[ -z "$review_json" ]]; then
      log_error "debate review returned empty response" "review"
      return 1
    fi

    review_json=$(extract_json "$review_json")

    if [[ "$output_mode" == "terminal" ]]; then
      # Print formatted output
      if echo "$review_json" | jq . &>/dev/null; then
        local status summary
        status=$(echo "$review_json" | jq -r '.status')
        summary=$(echo "$review_json" | jq -r '.summary')
        echo ""
        echo "Status: $status"
        echo "Summary: $summary"
        echo ""
        echo "$review_json" | jq -r '.comments[]? | "- [\(.severity)] \(.path):\(.line) — \(.body)"'
      else
        echo "$review_json"
      fi
    else
      if ! echo "$review_json" | jq . &>/dev/null; then
        log_error "debate did not produce valid JSON. Raw output:" "review"
        echo "$review_json"
        return 1
      fi
      post_inline_review "$project_dir" "$pr_number" "$review_json"
    fi
    return
  fi

  # ===================================================================
  # SINGLE-PASS MODE: standard review
  # ===================================================================

  # --- Build prompt ---
  local prompt
  prompt=$(build_review_prompt \
    "$project" "$project_dir" "$graph_file" "$base_ref" \
    "$project_type" "$consumers" "$deps" "$has_api_change" \
    "$output_language" "$output_mode")

  claude_args+=(--append-system-prompt-file "$mra_dir/agents/code-reviewer.md")
  claude_args+=(--model "$model")
  claude_args+=(--max-turns 3)
  claude_args+=(--setting-sources "project")

  # --- Run Claude ---
  log_progress "running Claude ($model)..." "review"

  if [[ "$output_mode" == "terminal" ]]; then
    # Terminal mode: just print
    claude -p "$prompt" "${claude_args[@]}" 2>/dev/null
  else
    # Inline mode: get JSON, parse, post to GitHub
    local review_json
    review_json=$(claude -p "$prompt" "${claude_args[@]}" 2>/dev/null)

    if [[ -z "$review_json" ]]; then
      log_error "Claude returned empty response" "review"
      return 1
    fi

    # Try to extract JSON from response (Claude might wrap it in markdown)
    review_json=$(extract_json "$review_json")

    if ! echo "$review_json" | jq . &>/dev/null; then
      log_error "Claude did not return valid JSON. Raw output:" "review"
      echo "$review_json"
      return 1
    fi

    post_inline_review "$project_dir" "$pr_number" "$review_json"
  fi
}

# Extract JSON from Claude response (handles markdown fencing)
extract_json() {
  local raw="$1"

  # If it's already valid JSON, return as-is
  if echo "$raw" | jq . &>/dev/null 2>&1; then
    echo "$raw"
    return
  fi

  # Try to extract from ```json ... ``` block
  local extracted
  extracted=$(echo "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -n "$extracted" ]] && echo "$extracted" | jq . &>/dev/null 2>&1; then
    echo "$extracted"
    return
  fi

  # Try to extract from ``` ... ``` block
  extracted=$(echo "$raw" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
  if [[ -n "$extracted" ]] && echo "$extracted" | jq . &>/dev/null 2>&1; then
    echo "$extracted"
    return
  fi

  # Try to find first { to last }
  extracted=$(echo "$raw" | sed -n '/^{/,/^}/p')
  if [[ -n "$extracted" ]] && echo "$extracted" | jq . &>/dev/null 2>&1; then
    echo "$extracted"
    return
  fi

  # Give up, return raw
  echo "$raw"
}

# Resolve PR base branch
resolve_pr_base() {
  local project_dir="$1" pr_number="$2"
  local remote_url
  remote_url=$(git -C "$project_dir" remote get-url origin 2>/dev/null)
  local repo_slug
  repo_slug=$(echo "$remote_url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')

  if [[ -n "$repo_slug" ]]; then
    local base
    base=$(gh api "repos/$repo_slug/pulls/$pr_number" --jq '.base.ref' 2>/dev/null)
    if [[ -n "$base" ]]; then
      echo "$base"
      return
    fi
  fi
  echo "main"
}

# Post inline review to GitHub PR
post_inline_review() {
  local project_dir="$1" pr_number="$2" review_json="$3"

  # --- Resolve repo slug ---
  local remote_url
  remote_url=$(git -C "$project_dir" remote get-url origin 2>/dev/null)
  local repo_slug
  repo_slug=$(echo "$remote_url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')

  if [[ -z "$repo_slug" ]]; then
    log_error "cannot determine repo from git remote" "review"
    return 1
  fi

  # --- Parse review JSON ---
  local status summary comment_count
  status=$(echo "$review_json" | jq -r '.status // "CHANGES_REQUESTED"')
  summary=$(echo "$review_json" | jq -r '.summary // "Review completed"')
  comment_count=$(echo "$review_json" | jq '.comments | length')

  # --- Get latest commit SHA for the PR ---
  local commit_sha
  commit_sha=$(gh api "repos/$repo_slug/pulls/$pr_number" --jq '.head.sha' 2>/dev/null)
  if [[ -z "$commit_sha" ]]; then
    log_error "cannot get PR head SHA" "review"
    return 1
  fi

  # --- Map status to GitHub review event ---
  local event="COMMENT"
  if [[ "$status" == "APPROVED" ]]; then
    event="APPROVE"
  elif [[ "$status" == "CHANGES_REQUESTED" ]]; then
    event="REQUEST_CHANGES"
  fi

  # --- Build review body (summary) ---
  local api_note=""
  local has_api
  has_api=$(echo "$review_json" | jq -r '[.comments[]? | select(.severity == "CRITICAL")] | length')
  if [[ "$has_api" -gt 0 ]]; then
    api_note=$'\n\n> **Cross-project impact detected.** Consumer repos were analyzed for API compatibility.'
  fi

  local body="## MRA Code Review Summary

**Status:** \`${status}\`
**Issues found:** ${comment_count}${api_note}

${summary}"

  # --- Get valid diff lines from GitHub ---
  local diff_lines_file
  diff_lines_file=$(mktemp)
  gh api "repos/$repo_slug/pulls/$pr_number/files" --jq '
    .[] | .filename as $f | .patch // "" |
    split("\n") | to_entries[] |
    select(.value | test("^@@")) |
    .value | capture("\\+(?<start>[0-9]+)(,(?<count>[0-9]+))?") |
    {file: $f, start: (.start | tonumber), end: ((.start | tonumber) + ((.count // "1") | tonumber) - 1)}
  ' 2>/dev/null > "$diff_lines_file"

  # Filter comments to only include valid diff lines
  local valid_review_json
  valid_review_json=$(echo "$review_json" | jq --slurpfile hunks <(cat "$diff_lines_file" | jq -s '.') '
    .comments = [.comments[] |
      . as $c |
      if ($hunks[0] | any(.file == $c.path and $c.line >= .start and $c.line <= .end))
      then . else empty end
    ]
  ')
  rm -f "$diff_lines_file"

  comment_count=$(echo "$valid_review_json" | jq '.comments | length')
  local original_count
  original_count=$(echo "$review_json" | jq '.comments | length')
  local filtered_out=$((original_count - comment_count))
  if [[ "$filtered_out" -gt 0 ]]; then
    log_info "filtered $filtered_out comments with lines outside diff hunks" "review"

    # Append filtered comments to the review body so they're not lost
    local filtered_comments
    filtered_comments=$(echo "$review_json" | jq --slurpfile hunks <(cat /dev/null | jq -n '[]') -r '
      [.comments[] | . as $c |
        "- **[\(.severity)]** `\(.path):\(.line)` — \(.body)"
      ] | join("\n")
    ' 2>/dev/null)

    # Get only the filtered-out ones
    filtered_comments=$(echo "$review_json" | jq --argjson valid "$(echo "$valid_review_json" | jq '[.comments[] | {path, line}]')" -r '
      [.comments[] |
        . as $c |
        if ($valid | any(.path == $c.path and .line == $c.line)) then empty
        else "- **[\(.severity)]** `\(.path):\(.line)` — \(.body)" end
      ] | join("\n\n")
    ' 2>/dev/null)

    if [[ -n "$filtered_comments" ]]; then
      body="${body}

---

### Additional Findings (outside diff range)

${filtered_comments}"
    fi
  fi

  # --- Build API payload ---
  local body_file
  body_file=$(mktemp)
  echo "$body" > "$body_file"

  local payload
  if [[ "$comment_count" -gt 0 ]]; then
    # Build comments array for the API
    local comments_payload
    comments_payload=$(echo "$valid_review_json" | jq -c '[.comments[] | {
      path: .path,
      line: (.line // 1),
      side: "RIGHT",
      body: (
        (if .severity == "CRITICAL" then "**[CRITICAL]** "
         elif .severity == "HIGH" then "**[HIGH]** "
         else "**[MEDIUM]** " end) + .body
      )
    }]')

    payload=$(jq -n \
      --arg commit_id "$commit_sha" \
      --rawfile body "$body_file" \
      --arg event "$event" \
      --argjson comments "$comments_payload" \
      '{commit_id: $commit_id, body: $body, event: $event, comments: $comments}')
  else
    payload=$(jq -n \
      --arg commit_id "$commit_sha" \
      --rawfile body "$body_file" \
      --arg event "$event" \
      '{commit_id: $commit_id, body: $body, event: $event}')
  fi
  rm -f "$body_file"

  # --- Post review ---
  log_progress "posting inline review to $repo_slug#$pr_number ($comment_count comments)..." "review"

  local payload_file
  payload_file=$(mktemp)
  echo "$payload" > "$payload_file"

  local response
  response=$(gh api "repos/$repo_slug/pulls/$pr_number/reviews" \
    --method POST --input "$payload_file" 2>&1)
  rm -f "$payload_file"

  if echo "$response" | jq -e '.id' &>/dev/null; then
    local review_id
    review_id=$(echo "$response" | jq -r '.id')
    log_success "review posted: $repo_slug#$pr_number (review #$review_id)" "review"
    log_info "status: $status | comments: $comment_count" "review"
  else
    # Batch failed — try posting review without inline comments, then add comments individually
    log_warn "batch inline review failed, trying individual comments..." "review"

    # Post review body (summary) without inline comments
    local body_file
    body_file=$(mktemp)
    echo "$body" > "$body_file"
    local summary_payload
    summary_payload=$(jq -n \
      --arg commit_id "$commit_sha" \
      --rawfile body "$body_file" \
      --arg event "$event" \
      '{commit_id: $commit_id, body: $body, event: $event}')
    rm -f "$body_file"

    local summary_file
    summary_file=$(mktemp)
    echo "$summary_payload" > "$summary_file"
    local summary_response
    summary_response=$(gh api "repos/$repo_slug/pulls/$pr_number/reviews" \
      --method POST --input "$summary_file" 2>&1)
    rm -f "$summary_file"

    if echo "$summary_response" | jq -e '.id' &>/dev/null; then
      log_success "summary review posted" "review"
    else
      log_warn "summary review also failed, falling back to PR comment" "review"
      post_fallback_comment "$repo_slug" "$pr_number" "$body" "$review_json"
      return
    fi

    # Post each inline comment individually as review comments
    local posted=0 skipped=0
    local i=0
    while [[ $i -lt $comment_count ]]; do
      local c_path c_line c_body
      c_path=$(echo "$review_json" | jq -r ".comments[$i].path")
      c_line=$(echo "$review_json" | jq -r ".comments[$i].line")
      c_body=$(echo "$review_json" | jq -r ".comments[$i].body")
      local c_severity
      c_severity=$(echo "$review_json" | jq -r ".comments[$i].severity")

      local prefix=""
      case "$c_severity" in
        CRITICAL) prefix="**[CRITICAL]** " ;;
        HIGH) prefix="**[HIGH]** " ;;
        *) prefix="**[MEDIUM]** " ;;
      esac

      local c_payload
      c_payload=$(jq -n \
        --arg commit_id "$commit_sha" \
        --arg path "$c_path" \
        --argjson line "$c_line" \
        --arg side "RIGHT" \
        --arg body "${prefix}${c_body}" \
        '{commit_id: $commit_id, path: $path, line: $line, side: $side, body: $body}')

      local c_file
      c_file=$(mktemp)
      echo "$c_payload" > "$c_file"
      local c_response
      c_response=$(gh api "repos/$repo_slug/pulls/$pr_number/comments" \
        --method POST --input "$c_file" 2>&1)
      rm -f "$c_file"

      if echo "$c_response" | jq -e '.id' &>/dev/null; then
        ((posted++))
      else
        ((skipped++))
      fi
      ((i++))
    done

    log_success "posted $posted/$comment_count inline comments ($skipped skipped)" "review"
  fi
}

# Fallback: post as regular PR comment if inline review fails
post_fallback_comment() {
  local repo_slug="$1" pr_number="$2" body="$3" review_json="$4"

  # Append inline comments as text
  local comments_text
  comments_text=$(echo "$review_json" | jq -r '.comments[]? | "- **[\(.severity)]** `\(.path):\(.line)` — \(.body)"')

  if [[ -n "$comments_text" ]]; then
    body="${body}

---

### Inline Comments

${comments_text}"
  fi

  body="${body}

---
<sub>Generated by <a href=\"https://github.com/hanfour/multi-repo-agent\">multi-repo-agent</a></sub>"

  # Check for existing MRA comment
  local existing_id
  existing_id=$(gh api "repos/$repo_slug/issues/$pr_number/comments" \
    --jq '.[] | select(.body | contains("MRA Code Review")) | .id' 2>/dev/null | head -1)

  if [[ -n "$existing_id" ]]; then
    gh api "repos/$repo_slug/issues/comments/$existing_id" -X PATCH -f body="$body" > /dev/null 2>&1
    log_success "updated existing comment on $repo_slug#$pr_number" "review"
  else
    gh api "repos/$repo_slug/issues/$pr_number/comments" -f body="$body" > /dev/null 2>&1
    log_success "posted comment on $repo_slug#$pr_number" "review"
  fi
}
