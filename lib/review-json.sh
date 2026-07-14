#!/usr/bin/env bash
# Review JSON lifecycle: validate, extract, repair, redact, and status mapping.

_review_redact_secrets_json() {
  local json="$1" token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local openai_token="" redacted
  if [[ -f "${HOME:-}/.codex/auth.json" && ! -L "${HOME:-}/.codex/auth.json" &&
        "$(_review_file_owner_uid "${HOME:-}/.codex/auth.json")" == "$(id -u)" ]]; then
    openai_token=$(jq -r '.OPENAI_API_KEY // ""' "${HOME:-}/.codex/auth.json" 2>/dev/null || true)
  fi
  redacted="$json"
  [[ -z "$token" ]] || redacted=${redacted//"$token"/"[REDACTED_GITHUB_TOKEN]"}
  [[ -z "$openai_token" ]] || redacted=${redacted//"$openai_token"/"[REDACTED_OPENAI_API_KEY]"}
  printf '%s' "$redacted" | jq -c '
    walk(
      if type == "string" then
        gsub("github_pat_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
        | gsub("gh[pousr]_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
        | gsub("sk-[A-Za-z0-9_-]{20,}"; "[REDACTED_OPENAI_API_KEY]")
      else . end
    )
  ' 2>/dev/null || printf '%s' "$redacted"
}

# --- TM-007 helpers -------------------------------------------------
#
# _validate_review_json: the Claude review output is downstream of
# attacker-influenced repo content. Validate its shape before any of
# its values reach GitHub. Required fields: status, summary, comments.
# Comments must have path/line/severity/body with severity from a
# closed enum. Anything else is rejected; the operator can still
# inspect the raw model output but no PR review will be posted.
_validate_review_json() {
  local json="${1:-}"
  if [[ -z "$json" ]]; then
    return 1
  fi
  echo "$json" | jq -e '
    type == "object"
    and (.status | type == "string")
    and (.status == "APPROVED" or .status == "CHANGES_REQUESTED" or .status == "COMMENT")
    and (.summary | type == "string")
    and (.comments | type == "array")
    and (
      [.comments[]?] | all(
        type == "object"
        and (.path | type == "string") and (.path | length) > 0
        and (.line | type == "number")
        and (.body | type == "string") and (.body | length) > 0
        and (.severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" or .severity == "LOW")
      )
    )
  ' >/dev/null 2>&1
}

# _review_event_for_status: map model-produced status to a GitHub
# review event, with the APPROVED -> APPROVE link gated by an explicit
# operator opt-in. Anything we don't recognise falls back to COMMENT.
_review_event_for_status() {
  local status="${1:-}"
  case "$status" in
    APPROVED)
      if [[ "${MRA_REVIEW_ALLOW_APPROVE:-}" == "1" ]]; then
        echo "APPROVE"
      else
        # log_warn writes to stdout in this codebase; force stderr so
        # callers using $(_review_event_for_status ...) capture only
        # the event name, not the warning text.
        log_warn "model said APPROVED but MRA_REVIEW_ALLOW_APPROVE is not set; downgrading to COMMENT" "review" >&2
        echo "COMMENT"
      fi
      ;;
    CHANGES_REQUESTED)
      echo "REQUEST_CHANGES"
      ;;
    *)
      echo "COMMENT"
      ;;
  esac
}

# _review_effective_status: derive the status that MRA will actually post. The
# returned value must agree with the GitHub review event, the review body, and the
# stdout `status:` line. A model-produced APPROVED verdict is downgraded to
# COMMENT unless the operator explicitly opts into real GitHub approvals.
_review_effective_status() {
  local status="${1:-}" review_json="${2:-}"
  if [[ "$status" == "APPROVED" && "${MRA_REVIEW_ALLOW_APPROVE:-}" != "1" ]]; then
    # _review_event_for_status also fails closed, but downgrade here so every
    # caller-visible surface is honest, not only the GitHub API event.
    echo "COMMENT"
    return 0
  fi
  if [[ "${MRA_REVIEW_APPROVE_IF_NO_HIGH:-}" == "1" && "${MRA_REVIEW_ALLOW_APPROVE:-}" == "1" ]]; then
    # Decide whether this verdict is eligible for the "approve if no HIGH" flip.
    #   APPROVED         -> recompute (downgrade if a HIGH comment slipped in).
    #   CHANGES_REQUESTED-> only if it itemised its concerns as comments. A
    #                       CHANGES_REQUESTED with NO comments put its blocker in
    #                       the summary prose (or is a truncated synthesis that
    #                       dropped its findings) — never manufacture that into an
    #                       approval; pass it through as a block.
    #   anything else    -> non-verdict (bare COMMENT / REVIEW_INCOMPLETE /
    #                       truncated single-pass) — pass through, never approve.
    case "$status" in
      APPROVED) ;;
      CHANGES_REQUESTED)
        local cc
        cc=$(printf '%s' "$review_json" | jq -r '.comments | length' 2>/dev/null) || cc=""
        [[ "$cc" == "0" || -z "$cc" ]] && { echo "$status"; return 0; }
        ;;
      *) echo "$status"; return 0 ;;
    esac
    # Recompute from the actual comment severities, ignoring the model's status
    # claim (so an APPROVED verdict carrying a HIGH comment still downgrades).
    # Fail CLOSED: only a clean numeric zero approves; empty / non-numeric jq
    # output (incl. a jq error — `|| high_count=""` keeps errexit from aborting
    # here) → CHANGES_REQUESTED, never a silent auto-approve.
    local high_count
    high_count=$(printf '%s' "$review_json" \
      | jq -r '[.comments[]? | select(.severity == "CRITICAL" or .severity == "HIGH")] | length' 2>/dev/null) || high_count=""
    if [[ "$high_count" == "0" ]]; then echo "APPROVED"; else echo "CHANGES_REQUESTED"; fi
    return 0
  fi
  echo "$status"
}

# Resolve a single-pass raw review response into the JSON to post. A missing
# completion sentinel (#8), an empty response, or unparseable JSON all mean the
# review did not cleanly complete → the neutral REVIEW_INCOMPLETE verdict (never
# APPROVE). Otherwise the extracted, validated review JSON. Always prints ONE
# valid JSON object.
_review_singlepass_body() {
  local raw="$1"
  local sentinel_status
  sentinel_status=$(printf '%s\n' "$raw" | awk -v token="$MRA_REVIEW_SENTINEL_TOKEN" '
    $0 ~ "^[[:space:]]*===" token ":[[:space:]]*APPROVED[[:space:]]*===[[:space:]]*$" { status="APPROVED" }
    $0 ~ "^[[:space:]]*===" token ":[[:space:]]*CHANGES_REQUESTED[[:space:]]*===[[:space:]]*$" { status="CHANGES_REQUESTED" }
    END { print status }
  ')
  if [[ -z "$raw" || -z "$sentinel_status" ]]; then
    review_incomplete_json; return 0
  fi
  # Strip the completion-sentinel line before extraction: extract_json's
  # last-resort "{ ... }" fallback range-matches on separate lines (sed never
  # closes an addr1,addr2 range on the line addr1 matched, in both GNU and
  # BSD sed), so a compact single-line JSON body immediately followed by the
  # sentinel line would otherwise be left un-isolated and fail jq parsing.
  # The match is anchored to a WHOLE line that IS the sentinel (tolerating
  # surrounding/internal whitespace) rather than a bare substring: a
  # substring strip would also delete any body/summary line that merely
  # MENTIONS the token (very plausible when mra reviews its own
  # sentinel-mechanism PRs), silently dropping a real HIGH/CRITICAL finding
  # while leaving the resulting JSON still valid — a false green (#8).
  local body
  body=$(printf '%s\n' "$raw" | grep -vE "^[[:space:]]*===${MRA_REVIEW_SENTINEL_TOKEN}:[[:space:]]*(APPROVED|CHANGES_REQUESTED)[[:space:]]*===[[:space:]]*$") || true
  local j json_status
  j=$(extract_json "$body")
  json_status=$(printf '%s' "$j" | jq -r '.status // ""' 2>/dev/null || true)
  if _validate_review_json "$j" && [[ "$sentinel_status" == "$json_status" ]]; then
    printf '%s' "$j"
  else
    review_incomplete_json
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

# A: one cheap self-repair pass for malformed review JSON. The synthesis model
# occasionally emits a body string with an unescaped inner double-quote (or
# stray markdown), so jq can't parse it — non-deterministic, which would
# otherwise discard a substantive review. Ask a fast, tool-less model to
# re-emit corrected JSON. Echoes the model output (the caller re-extracts +
# re-validates); empty/unchanged on failure. Best-effort — never aborts the
# caller. Mockable in tests via MRA_CLAUDE_BIN; model via MRA_REVIEW_REPAIR_MODEL.
_repair_review_json() {
  local broken="${1:-}" project_dir="${2:-}"
  [[ -z "$broken" ]] && return 0
  local prompt
  prompt="The text below is meant to be ONE JSON object for a code review but is malformed (most likely an unescaped double-quote inside a string value, or stray markdown). Output ONLY the corrected JSON object: no markdown fences, no commentary, nothing before or after. Backslash-escape every double-quote that appears inside a string value. Preserve ALL original content (paths, line numbers, severities, comment bodies) exactly.

${broken}"
  _review_without_github_credentials claude_invoke review-repair -p "$prompt" \
    --model "${MRA_REVIEW_REPAIR_MODEL:-haiku}" \
    --max-turns 1 \
    --disallowedTools "Write,Edit,NotebookEdit" \
    --setting-sources "project" 2>/dev/null || true
}
