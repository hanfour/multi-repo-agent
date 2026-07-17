#!/usr/bin/env bash
# PKB / structural ablation (issue #27) — the same review case runs 2×2
# (PKB on/off × structural on/off) so each layer's contribution is measured,
# not asserted. Low-frequency, operator-run (real model calls — never in CI).
#
# Usage: mra eval-ablation <project> [--base <ref>] [--pr <N>] [--model <m>]
# Report: JSON on stdout + persisted to <workspace>/.collab/eval/.

eval_pkb_ablation() {
  local workspace="$1"; shift
  local project="" base_ref="" pr_number="" model="haiku"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)
        if [[ $# -lt 2 ]]; then log_error "--base requires a ref" "eval"; return 1; fi
        base_ref="$2"; shift 2 ;;
      --pr)
        if [[ $# -lt 2 ]]; then log_error "--pr requires a PR number" "eval"; return 1; fi
        pr_number="$2"; shift 2 ;;
      --model)
        if [[ $# -lt 2 ]]; then log_error "--model requires a value" "eval"; return 1; fi
        model="$2"; shift 2 ;;
      -*) log_error "unknown option: $1" "eval"; return 1 ;;
      *) project="$1"; shift ;;
    esac
  done

  if [[ -z "$project" ]]; then
    log_error "usage: mra eval-ablation <project> [--base <ref>] [--pr <N>] [--model <m>]" "eval"
    return 1
  fi
  local project_dir="$workspace/$project"
  if [[ ! -d "$project_dir" ]]; then
    log_error "project directory not found: $project_dir" "eval"
    return 1
  fi

  local mra_dir mra_commit
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mra_commit=$(git -C "$mra_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  log_progress "ablation: running 4 arms (PKB on/off × structural on/off) — model $model" "eval" >&2

  local arms='[]' pkb_arm st_arm
  for pkb_arm in on off; do
    for st_arm in on off; do
      local t0=$SECONDS json="" findings=0
      # Subshell isolates the per-arm env toggles.
      json=$(
        [[ "$pkb_arm" == "off" ]] && export MRA_EVAL_DISABLE_PKB=1
        [[ "$st_arm" == "off" ]] && export MRA_STRUCTURAL_PROVIDER=off
        _eval_run_review "$workspace" "$project" "$pr_number" "$base_ref" "$model" ""
      ) || json=""
      local seconds=$((SECONDS - t0))
      findings=$(jq '.comments | length' <<<"$json" 2>/dev/null) || findings=0
      [[ "$findings" =~ ^[0-9]+$ ]] || findings=0
      log_info "arm pkb=$pkb_arm structural=$st_arm: $findings findings in ${seconds}s" "eval" >&2
      arms=$(jq -c \
        --arg p "$pkb_arm" --arg s "$st_arm" \
        --argjson f "$findings" --argjson d "$seconds" \
        '. + [{pkb: $p, structural: $s, findings: $f, seconds: $d}]' <<<"$arms")
    done
  done

  local report
  report=$(jq -n \
    --arg commit "$mra_commit" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$project" \
    --arg base "${base_ref:-auto}" \
    --arg model "$model" \
    --argjson arms "$arms" \
    '{mraCommit: $commit, date: $date, project: $project, base: $base, model: $model, arms: $arms}')

  local report_dir="$workspace/.collab/eval"
  mkdir -p "$report_dir"
  local report_file
  report_file="$report_dir/pkb-ablation-$(date +%Y%m%d_%H%M%S).json"
  printf '%s\n' "$report" > "$report_file"
  log_success "ablation report saved: $report_file" "eval" >&2

  printf '%s\n' "$report"
}
