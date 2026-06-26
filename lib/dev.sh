#!/usr/bin/env bash
# Deterministic implement -> review -> fix -> PR loop for `mra dev`.
# Verdict comes ONLY from $MRA_REVIEW_RESULT_FILE; exit code is never the gate.

# Reap background _review_pkb_auto_update jobs review.sh spawns, and drop the
# verdict channel — called on EVERY terminal path so a mid-loop death (or normal
# exit) never orphans them.
_dev_teardown() {
  local p
  for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -n "${MRA_REVIEW_RESULT_FILE:-}" && -e "$MRA_REVIEW_RESULT_FILE" ]] && rm -f "$MRA_REVIEW_RESULT_FILE"
  unset MRA_REVIEW_RESULT_FILE
}

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
  _dev_teardown
  trap - EXIT
  return 2
}

_dev_report() { # stage code_rounds  -> echoes DEV_RESULT, returns 0
  log_success "$2 review round(s); branch ready" "dev"
  printf 'DEV_RESULT status=APPROVED stage=%s rounds=%s\n' "$1" "$2"
  _dev_teardown
  trap - EXIT
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

  # Verdict channel: created here so _dev_review_one / _dev_read_status are
  # never racing against an unbound variable under set -u (CRITICAL-1).
  MRA_REVIEW_RESULT_FILE=$(mktemp) || { log_error "mktemp failed" "dev"; return 1; }
  export MRA_REVIEW_RESULT_FILE
  # Backstop: reap background jobs + temp files even on a set-e/set-u abort.
  # Normal terminal paths (_dev_report, _dev_escalate) clear this explicitly
  # after their own teardown call so it never double-fires (IMPORTANT-3).
  trap '_dev_teardown' EXIT

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

  # 4 PR
  if [[ "${DEV_NO_PR:-false}" == true ]]; then _dev_report code "$round"; return 0; fi
  _dev_push "$dir" "$slug" || { _dev_escalate "$workspace" "$project" pr "push failed"; return 2; }
  local pr_n; pr_n=$(_dev_pr_open "$dir" "$slug" "mra: ${task:0:60}" "$(_dev_pr_body "$task")")
  [[ -z "$pr_n" ]] && { _dev_escalate "$workspace" "$project" pr "could not open PR"; return 2; }

  # 5 PR-REVIEW LOOP
  _dev_pr_loop "$workspace" "$project" "$dir" "$base" "$pr_n" "$slug" || return 2
  _dev_report pr "$round"; return 0
}

_dev_push() { git -C "$1" push -u origin "mra/$2" >/dev/null 2>&1; }

_dev_pr_body() { printf '## Summary\n\n%s\n\n## Test Plan\n- [ ] review findings addressed by mra dev loop\n' "$1"; }

_dev_pr_open() { # dir slug title body -> echo PR number
  local dir="$1" slug="$2" title="$3" body="$4" n
  n=$( (cd "$dir" && gh pr view "mra/$slug" --json number -q .number) 2>/dev/null || true)
  if [[ -z "$n" ]]; then
    mra_pr_create "$dir" "$title" "$body" >/dev/null 2>&1 || true
    n=$( (cd "$dir" && gh pr view "mra/$slug" --json number -q .number) 2>/dev/null || true)
  fi
  printf '%s' "$n"
}

# Single pinned review (§10-3): dismiss the bot's prior MRA reviews so the PR
# carries exactly one evolving review instead of N stacked ones.
_dev_pr_dismiss_prior() {
  local dir="$1" pr_n="$2"
  ( cd "$dir" && gh pr view "$pr_n" --json reviews \
      -q '.reviews[] | select(.author.login=="'"${MRA_BOT_LOGIN:-github-actions[bot]}"'") | .id' 2>/dev/null \
    | while read -r rid; do gh api -X PUT "repos/{owner}/{repo}/pulls/$pr_n/reviews/$rid/dismissals" -f message="superseded by mra dev" >/dev/null 2>&1 || true; done ) || true
}

_dev_pr_loop() {
  local workspace="$1" project="$2" dir="$3" base="$4" pr_n="$5" slug="$6"
  local round=0 retry=0 prev_fp="" v fp out st global=0
  local _pr_rv_tmp; _pr_rv_tmp=$(mktemp) || { _dev_escalate "$workspace" "$project" pr "mktemp failed"; return 2; }
  while :; do
    global=$((global+1)); [[ "$global" -gt "${DEV_GLOBAL_CAP:-12}" ]] && { rm -f "$_pr_rv_tmp"; _dev_escalate "$workspace" "$project" pr "global review ceiling"; return 2; }
    _dev_push "$dir" "$slug" || true
    _dev_pr_dismiss_prior "$dir" "$pr_n"
    _dev_review_one "$workspace" "$project" pr "$base" "$pr_n" > "$_pr_rv_tmp"
    IFS='|' read -r v fp < "$_pr_rv_tmp"
    case "$v" in
      APPROVED) rm -f "$_pr_rv_tmp"; return 0 ;;
      COMMENT|REVIEW_INCOMPLETE)
        retry=$((retry+1)); [[ "$retry" -gt "${DEV_RETRY_CAP:-2}" ]] && { rm -f "$_pr_rv_tmp"; _dev_escalate "$workspace" "$project" pr "pr-review never completed"; return 2; }
        continue ;;
      CHANGES_REQUESTED)
        [[ -n "$prev_fp" && "$fp" == "$prev_fp" ]] && { rm -f "$_pr_rv_tmp"; _dev_escalate "$workspace" "$project" pr "no progress"; return 2; }
        out=$(_dev_run_agent "$dir" fix "$(jq -r '(.comments//[])[]|"- [\(.severity)] \(.path):\(.line) — \(.body)"' "$MRA_REVIEW_RESULT_FILE" 2>/dev/null || true)")
        st=$(_dev_parse_sentinel "$out")
        { [[ "$st" == BLOCKED:* ]] || ! _dev_progress "$dir" "$base"; } && { rm -f "$_pr_rv_tmp"; _dev_escalate "$workspace" "$project" pr "fix blocked or empty"; return 2; }
        prev_fp="$fp"; round=$((round+1))
        [[ "$round" -ge "${DEV_MAX_ROUNDS:-3}" ]] && { rm -f "$_pr_rv_tmp"; _dev_escalate "$workspace" "$project" pr "pr-review cap"; return 2; }
        continue ;;  # next iteration's top-of-loop push + --pr review IS the re-confirm (§10-2)
      *) rm -f "$_pr_rv_tmp"; _dev_escalate "$workspace" "$project" pr "unknown verdict: $v"; return 2 ;;
    esac
  done
  rm -f "$_pr_rv_tmp"
}

_dev_parse_args() {
  DEV_PROJECT=""; DEV_TASK=""; DEV_BASE="${DEV_BASE:-}"; DEV_MODEL="sonnet"; DEV_MAX_ROUNDS="3"
  DEV_NO_PR=false; DEV_AUTO_APPROVE=false; DEV_RESUME=false; DEV_DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)       [[ $# -lt 2 ]] && { log_error "--base requires a value" "dev"; return 1; }; DEV_BASE="$2"; shift 2 ;;
      --model)      [[ $# -lt 2 ]] && { log_error "--model requires a value" "dev"; return 1; }; DEV_MODEL="$2"; shift 2 ;;
      --max-rounds) [[ $# -lt 2 ]] && { log_error "--max-rounds requires a value" "dev"; return 1; }
                    [[ "$2" =~ ^[1-9][0-9]*$ ]] || { log_error "--max-rounds must be a positive integer" "dev"; return 1; }
                    DEV_MAX_ROUNDS="$2"; shift 2 ;;
      --no-pr)        DEV_NO_PR=true; shift ;;
      --auto-approve) DEV_AUTO_APPROVE=true; shift ;;
      --resume)       DEV_RESUME=true; shift ;;
      --dry-run)      DEV_DRY_RUN=true; shift ;;
      -*) log_error "unknown option: $1" "dev"; return 1 ;;
      *)  if [[ -z "$DEV_PROJECT" ]]; then DEV_PROJECT="$1"; else DEV_TASK+="${DEV_TASK:+ }$1"; fi; shift ;;
    esac
  done
  [[ -z "$DEV_PROJECT" || -z "$DEV_TASK" ]] && { log_error "usage: mra dev <project> \"<task>\" [--base R] [--model M] [--max-rounds N] [--no-pr] [--auto-approve] [--resume] [--dry-run]" "dev"; return 1; }
  return 0
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
  local -a rargs=(--strategy debate --base "$base" --model "${DEV_MODEL:-sonnet}")
  local pr_ctx="" allow=""
  if [[ "$mode" == pr ]]; then
    rargs+=(--pr "$pr_n"); pr_ctx=0
    [[ "${DEV_AUTO_APPROVE:-false}" == true ]] && allow=1
  fi
  # set -e firewall (§10-1): || true so review_project's documented return-1
  # (malformed-JSON path) can never abort the loop before we read the file.
  MRA_REVIEW_VERIFY_APPROVE=1 MRA_REVIEW_PR_CONTEXT="$pr_ctx" MRA_REVIEW_ALLOW_APPROVE="$allow" \
    review_project "$workspace" "$project" "${rargs[@]}" 1>&2 || true
  printf '%s|%s\n' "$(_dev_read_status "$MRA_REVIEW_RESULT_FILE")" "$(_dev_fingerprint "$MRA_REVIEW_RESULT_FILE")"
}
