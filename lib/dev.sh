#!/usr/bin/env bash
# Deterministic implement -> review -> fix -> PR loop for `mra dev`.
# Verdict comes ONLY from $MRA_REVIEW_RESULT_FILE; exit code is never the gate.

_dev_read_status() {
  local rf="$1" st
  st=$(jq -r '.status // empty' "$rf" 2>/dev/null || true)
  [[ -n "$st" ]] && printf '%s' "$st" || printf 'REVIEW_INCOMPLETE'
}

_dev_fingerprint() {
  local rf="$1"
  jq -r '(.comments // [])[] | "\(.path):\(.line):\(.severity)"' "$rf" 2>/dev/null \
    | sort | tr '\n' ',' || true
}

_dev_progress() { # HEAD moved AND base...HEAD non-empty
  local dir="$1" base="$2"
  [[ -n "$(git -C "$dir" rev-list "$base"..HEAD 2>/dev/null)" ]] || return 1
  [[ -n "$(git -C "$dir" diff "$base"...HEAD 2>/dev/null)" ]] || return 1
}

_dev_escalate() { # workspace project stage reason  -> echoes DEV_RESULT, returns 2
  local workspace="$1" project="$2" stage="$3" reason="$4"
  mra_log "$workspace" "$project" "ESCALATED [$stage]: $reason" >/dev/null 2>&1 || true
  notify_escalation "$workspace" "$project" "$reason" >/dev/null 2>&1 || true
  log_error "[escalate] $project ($stage): $reason" "dev"
  printf 'DEV_RESULT status=ESCALATED stage=%s reason=%s\n' "$stage" "$reason"
  return 2
}

_dev_report() { # stage code_rounds  -> echoes DEV_RESULT, returns 0
  log_success "$2 review round(s); branch ready" "dev"
  printf 'DEV_RESULT status=APPROVED stage=%s rounds=%s\n' "$1" "$2"
  return 0
}

dev_project() {
  local workspace="$1" project="$2" task="$3"
  local dir base slug v fp
  dir=$(resolve_project_dir "$workspace" "$project") || { log_error "unknown project: $project" "dev"; return 1; }
  base="${DEV_BASE:-origin/$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@origin/@@' || echo main)}"
  _dev_validate "$dir" "$base" || return 1
  slug=$(_dev_slugify "$task")
  [[ "${DEV_DRY_RUN:-false}" == true ]] && { log_info "[dry-run] would work on mra/$slug from $base" "dev"; return 0; }

  # 1 BRANCH (dev owns it; fork from base, not current HEAD)
  _dev_branch "$dir" "$slug" "$base" || return 1

  # 2 IMPLEMENT
  local out st
  out=$(_dev_run_agent "$dir" implement "$task")
  st=$(_dev_parse_sentinel "$out")
  [[ "$st" == BLOCKED:* ]] && { _dev_escalate "$workspace" "$project" implement "${st#BLOCKED:}"; return 2; }
  _dev_progress "$dir" "$base" || { _dev_escalate "$workspace" "$project" implement "no diff produced"; return 2; }
  _dev_ensure_pkb "$dir" "$project"   # build-if-missing before first review (D14)

  # 3 CODE-REVIEW LOOP (three-valued; bounded)
  local round=0 retry=0 prev_fp="" global=0 _rv_tmp
  _rv_tmp=$(mktemp) || { log_error "mktemp failed" "dev"; return 1; }
  while :; do
    global=$((global+1)); [[ "$global" -gt "${DEV_GLOBAL_CAP:-12}" ]] && { rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" code "global review ceiling"; return 2; }
    _dev_review_one "$workspace" "$project" code "$base" "" > "$_rv_tmp"
    IFS='|' read -r v fp < "$_rv_tmp"
    case "$v" in
      APPROVED) break ;;
      COMMENT|REVIEW_INCOMPLETE)
        retry=$((retry+1)); [[ "$retry" -gt "${DEV_RETRY_CAP:-2}" ]] && { rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" code "review never completed"; return 2; }
        continue ;;
      CHANGES_REQUESTED)
        [[ -n "$prev_fp" && "$fp" == "$prev_fp" ]] && { rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" code "no progress: identical findings"; return 2; }
        out=$(_dev_run_agent "$dir" fix "$(jq -r '(.comments//[])[]|"- [\(.severity)] \(.path):\(.line) — \(.body)"' "$MRA_REVIEW_RESULT_FILE" 2>/dev/null || true)")
        st=$(_dev_parse_sentinel "$out")
        [[ "$st" == BLOCKED:* ]] && { rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" fix "${st#BLOCKED:}"; return 2; }
        _dev_progress "$dir" "$base" || { rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" fix "fix produced no diff"; return 2; }
        prev_fp="$fp"; round=$((round+1))
        [[ "$round" -ge "${DEV_MAX_ROUNDS:-3}" ]] && { rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" code "code-review cap"; return 2; }
        continue ;;
      *) rm -f "$_rv_tmp"; _dev_escalate "$workspace" "$project" code "unknown verdict: $v"; return 2 ;;
    esac
  done
  rm -f "$_rv_tmp"

  # PR + pr-review loop inserted in Task 5. For now, stop at local APPROVED.
  if [[ "${DEV_NO_PR:-false}" == true ]]; then _dev_report code "$round"; return 0; fi
  _dev_report code "$round"; return 0
}

_dev_validate() {
  local dir="$1" base="$2"
  [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] && { log_error "working tree not clean: $dir" "dev"; return 1; }
  local cur protected; cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  for protected in main master develop production; do
    [[ "$cur" == "$protected" ]] && { log_error "refusing to run on protected branch: $cur" "dev"; return 1; }
  done
  return 0
}

_dev_branch() {
  local dir="$1" slug="$2" base="$3"
  git -C "$dir" fetch --quiet origin 2>/dev/null || true
  if git -C "$dir" show-ref --verify --quiet "refs/heads/mra/$slug"; then
    if [[ "${DEV_RESUME:-false}" == true ]]; then
      # Reattach to existing branch — do NOT reset to base (would destroy prior commits).
      git -C "$dir" checkout "mra/$slug" >/dev/null 2>&1 || { log_error "cannot checkout mra/$slug" "dev"; return 1; }
      return 0
    else
      log_error "branch mra/$slug exists; pass --resume" "dev"; return 1
    fi
  fi
  # Branch does not exist — fresh fork from base.
  git -C "$dir" checkout -B "mra/$slug" "$base" >/dev/null 2>&1 || { log_error "cannot create mra/$slug from $base" "dev"; return 1; }
}

# Build-if-missing PKB before the first review (D14). Uses the real pkb helpers
# (pkb_exists / pkb_generate, as called by `mra analyze`). Non-fatal on failure —
# a missing PKB just risks REVIEW_INCOMPLETE, which the loop already handles.
_dev_ensure_pkb() {
  local dir="$1" project="$2"
  pkb_exists "$dir" 2>/dev/null && return 0
  pkb_generate "$project" "$dir" "${DEV_MODEL:-sonnet}" "" >/dev/null 2>&1 || true
}

# Run one debate review; emit verdict to RF; echo "STATUS|FINGERPRINT".
# mode=code (local base...HEAD) | pr (post to GitHub PR + verdict).
_dev_review_one() {
  local workspace="$1" project="$2" mode="$3" base="$4" pr_n="$5"
  : > "$MRA_REVIEW_RESULT_FILE"
  local -a rargs=(--strategy debate --base "$base")
  local pr_ctx="" allow=""
  if [[ "$mode" == pr ]]; then
    rargs+=(--pr "$pr_n"); pr_ctx=0
    [[ "${DEV_AUTO_APPROVE:-false}" == true ]] && allow=1
  fi
  # set -e firewall (§10-1): || true so review_project's documented return-1
  # (malformed-JSON path) can never abort the loop before we read the file.
  MRA_REVIEW_VERIFY_APPROVE=1 MRA_REVIEW_PR_CONTEXT="$pr_ctx" MRA_REVIEW_ALLOW_APPROVE="$allow" \
    review_project "$workspace" "$project" "${rargs[@]}" 1>&2 || true
  printf '%s|%s' "$(_dev_read_status "$MRA_REVIEW_RESULT_FILE")" "$(_dev_fingerprint "$MRA_REVIEW_RESULT_FILE")"
}
