#!/usr/bin/env bash
# Review result rendering + GitHub posting: emit verdict, notify, post inline / fallback review.

_review_validate_expected_head() {
  local expected="$1" local_head="$2" remote_head="$3"
  [[ -n "$expected" && "$local_head" == "$expected" && "$remote_head" == "$expected" ]]
}

# Render review JSON to terminal or post to GitHub PR — shared by debate & persona paths.
# Returns 0 on success, 1 on empty/invalid response.
_render_review_json() {
  local review_json="$1" output_mode="$2" project_dir="$3" pr_number="$4" source_label="${5:-review}"

  if [[ -z "$review_json" ]]; then
    log_error "${source_label} review returned empty response" "review"
    return 1
  fi

  review_json=$(extract_json "$review_json")
  review_json=$(_review_redact_secrets_json "$review_json")

  if [[ "$output_mode" == "terminal" ]]; then
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
      # One cheap self-repair pass: the synthesis model occasionally emits a
      # body string with an unescaped inner double-quote (or stray markdown),
      # producing JSON jq can't parse — non-deterministic, so a substantive
      # review is lost. Ask a fast model to re-emit corrected JSON before
      # giving up.
      local repaired
      repaired=$(extract_json "$(_repair_review_json "$review_json" "$project_dir")")
      if [[ -n "$repaired" ]] && echo "$repaired" | jq . &>/dev/null; then
        log_info "review JSON was malformed; self-repair succeeded" "review"
        review_json="$repaired"
      else
        log_error "${source_label} did not produce valid JSON. Raw output:" "review"
        echo "$review_json"
        return 1
      fi
    fi
    if [[ "${MRA_REVIEW_POST_MODE:-github}" != "none" ]]; then
      post_inline_review "$project_dir" "$pr_number" "$review_json"
    fi
  fi
}

# Verdict transport for `mra dev`: write the canonical review JSON to
# $MRA_REVIEW_RESULT_FILE (if set), via extract -> repair -> validate. Anything
# unparseable-after-repair becomes a synthetic REVIEW_INCOMPLETE — NEVER coerced
# to APPROVED. Human/log output on stdout is left untouched (separate channel).
_review_emit_verdict() {
  local review_json="$1" project_dir="$2"
  [[ -z "${MRA_REVIEW_RESULT_FILE:-}" ]] && return 0
  local j
  j=$(extract_json "$review_json")
  j=$(_review_redact_secrets_json "$j")
  if ! printf '%s' "$j" | jq . >/dev/null 2>&1; then
    j=$(extract_json "$(_repair_review_json "$j" "$project_dir")")
  fi
  if _validate_review_json "$j"; then
    printf '%s' "$j" > "$MRA_REVIEW_RESULT_FILE"
  else
    printf '{"status":"REVIEW_INCOMPLETE","comments":[]}' > "$MRA_REVIEW_RESULT_FILE"
  fi
}

_review_status_for_notify() {
  local raw="${1:-}" j status summary
  j=$(extract_json "$raw")
  if printf '%s' "$j" | jq . >/dev/null 2>&1; then
    status=$(printf '%s' "$j" | jq -r '.status // ""' 2>/dev/null)
    summary=$(printf '%s' "$j" | jq -r '.summary // ""' 2>/dev/null)
    if [[ "$status" == "COMMENT" && "$summary" == *"REVIEW_INCOMPLETE"* ]]; then
      printf '%s' "REVIEW_INCOMPLETE"
    elif [[ -n "$status" ]]; then
      printf '%s' "$(_review_effective_status "$status" "$j")"
    else
      printf '%s' "COMPLETED"
    fi
  else
    printf '%s' "REVIEW_INCOMPLETE"
  fi
}

_review_notify_complete() {
  local workspace="$1" project="$2" result="${3:-COMPLETED}"
  declare -F notify_review_complete >/dev/null || return 0
  notify_review_complete "$workspace" "$project" "${result:-COMPLETED}" >/dev/null 2>&1 || true
}

# Count shown in the summary body's "Issues found" line. An incomplete review
# has no meaningful count, so show N/A — otherwise "Issues found: 0" next to a
# REVIEW_INCOMPLETE warning misreads as a clean "0 issues" green.
_review_issues_display() {
  local summary="$1" comment_count="$2"
  if [[ "$summary" == *"REVIEW_INCOMPLETE"* ]]; then
    printf 'N/A (review did not complete)'
  else
    printf '%s' "$comment_count"
  fi
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

  review_json=$(_review_redact_secrets_json "$review_json")

  # --- Parse review JSON ---
  local status summary comment_count
  status=$(echo "$review_json" | jq -r '.status // "CHANGES_REQUESTED"')
  summary=$(echo "$review_json" | jq -r '.summary // "Review completed"')
  comment_count=$(echo "$review_json" | jq '.comments | length')

  # --- Bind the review to the exact commit that was analyzed. ---
  local remote_head local_head expected_head commit_sha
  remote_head=$(gh api "repos/$repo_slug/pulls/$pr_number" --jq '.head.sha' 2>/dev/null)
  local_head=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)
  expected_head="${MRA_REVIEW_EXPECTED_HEAD_SHA:-$local_head}"
  if [[ -z "$remote_head" || -z "$local_head" || -z "$expected_head" ]]; then
    log_error "cannot get PR head SHA" "review"
    return 1
  fi
  if ! _review_validate_expected_head "$expected_head" "$local_head" "$remote_head"; then
    log_error "PR head changed during review (expected $expected_head, local $local_head, remote $remote_head); refusing to post" "review"
    return 1
  fi
  commit_sha="$expected_head"

  # --- Validate the review JSON shape (TM-007). Reject obviously
  # malformed Claude output before turning it into a GitHub review. ---
  if ! _validate_review_json "$review_json"; then
    log_error "review JSON did not pass schema validation; skipping post" "review"
    return 1
  fi

  # --- Map status to GitHub review event (TM-007). Model-produced
  # status is NEVER allowed to APPROVE a PR unless the operator opts
  # in with MRA_REVIEW_ALLOW_APPROVE=1. The same Claude session that
  # produced this JSON sees PR content (potentially attacker-controlled
  # via prompt injection), so treating its APPROVE verdict as binding
  # is unsafe by default. ---
  status=$(_review_effective_status "$status" "$review_json")
  local event
  event=$(_review_event_for_status "$status")

  # --- Build review body (summary) ---
  local api_note=""
  local has_api
  has_api=$(echo "$review_json" | jq -r '[.comments[]? | select(.severity == "CRITICAL")] | length')
  if [[ "$has_api" -gt 0 ]]; then
    api_note=$'\n\n> **Cross-project impact detected.** Consumer repos were analyzed for API compatibility.'
  fi

  local issues_display
  issues_display=$(_review_issues_display "$summary" "$comment_count")
  local body="## MRA Code Review Summary

**Status:** \`${status}\`
**Issues found:** ${issues_display}${api_note}

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
    local blocker_count
    blocker_count=$(printf '%s' "$review_json" | jq '[.comments[]? | select(.severity == "CRITICAL" or .severity == "HIGH")] | length')
    log_info "status: $status | comments: $comment_count | blockers: $blocker_count" "review"
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
