#!/usr/bin/env bash
# Structural layer foundation (issue #23) — thin, bounded wrappers around the
# codegraph CLI (https://github.com/colbymchenry/codegraph, MIT, 100% local).
#
# Philosophy: ADOPT, never create. mra uses an existing per-project
# .codegraph/ index when one is present and hints at `codegraph init` when it
# is not — indexing stays the user's decision (codegraph's own rule). With no
# codegraph anywhere, every wrapper degrades silently: zero behaviour change.
#
# Every invocation is bounded (perl-alarm timeout + output byte cap), the same
# convergence discipline as the review provider watchdog (issue #18).
#
# Tunables:
#   MRA_CODEGRAPH_BIN               binary (default codegraph; test seam)
#   MRA_STRUCTURAL_TIMEOUT_SECONDS  per-call watchdog (default 30, 0 disables)
#   MRA_STRUCTURAL_MAX_BYTES        output cap (default 65536)
#   config structural.provider      auto | off (default auto)

structural_provider() {
  local v
  v=$(config_get "structural.provider" 2>/dev/null) || v=""
  [[ "$v" == "null" || -z "$v" ]] && v="auto"
  printf '%s' "$v"
}

# True when the structural layer can answer for this project: not configured
# off, codegraph CLI on PATH, and the project already has a .codegraph/ index.
structural_available() {
  local project_dir="$1"
  [[ "$(structural_provider)" != "off" ]] || return 1
  command -v "${MRA_CODEGRAPH_BIN:-codegraph}" >/dev/null 2>&1 || return 1
  [[ -d "$project_dir/.codegraph" ]]
}

# Bounded runner shared by all wrappers: watchdog + output cap. Output is
# buffered to a temp file first so the cap never SIGPIPEs the CLI mid-write.
_structural_run() {
  local project_dir="$1"; shift
  local bin="${MRA_CODEGRAPH_BIN:-codegraph}"
  command -v "$bin" >/dev/null 2>&1 || return 1

  local timeout="${MRA_STRUCTURAL_TIMEOUT_SECONDS:-30}"
  local cap="${MRA_STRUCTURAL_MAX_BYTES:-65536}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=30
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=65536

  local -a cmd=("$bin" "$@")
  if [[ "$timeout" != "0" ]] && command -v perl >/dev/null 2>&1; then
    cmd=(perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV or exit 127;' "$timeout" "${cmd[@]}")
  fi

  local out_file rc=0
  out_file=$(mktemp)
  if ( cd "$project_dir" && "${cmd[@]}" ) >"$out_file" 2>/dev/null; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 0 ]] && head -c "$cap" "$out_file"
  rm -f "$out_file"
  return "$rc"
}

# Symbol-level blast radius: what is affected by changing <symbol>.
structural_impact() {
  local project_dir="$1" symbol="$2" depth="${3:-}"
  local -a args=(impact "$symbol" --json)
  [[ -n "$depth" ]] && args+=(--depth "$depth")
  _structural_run "$project_dir" "${args[@]}"
}

# Symbol search across the project index.
structural_query() {
  local project_dir="$1" query="$2"
  _structural_run "$project_dir" query "$query" --json
}

# Test files transitively affected by the file list on stdin.
structural_affected() {
  local project_dir="$1"
  _structural_run "$project_dir" affected --stdin --quiet
}

# Who calls <symbol> — real edges from the graph.
structural_callers() {
  local project_dir="$1" symbol="$2"
  _structural_run "$project_dir" callers "$symbol" --json
}

# One-shot exploration: relevant symbols' source + call paths + blast radius
# for a natural-language query or a bag of symbol/file names.
structural_explore() {
  local project_dir="$1" query="$2"
  _structural_run "$project_dir" explore "$query"
}

# Review-side context section (issue #25): symbol-level blast radius (explore
# over the changed files) plus transitively affected test files, capped at
# MRA_REVIEW_STRUCTURAL_MAX_BYTES (default 8KB — size to the answer, not the
# budget). Best-effort by contract: any failure, missing index, or empty
# change set yields EMPTY output so the review prompt stays byte-identical.
structural_review_context() {
  local project_dir="$1" changed_files="$2"
  structural_available "$project_dir" || return 0
  [[ -n "${changed_files//[[:space:]]/}" ]] || return 0

  local cap="${MRA_REVIEW_STRUCTURAL_MAX_BYTES:-8192}"
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=8192

  local query explore_out affected_out
  query=$(printf '%s\n' "$changed_files" | head -10 | tr '\n' ' ')
  explore_out=$(structural_explore "$project_dir" "$query" 2>/dev/null) || explore_out=""
  affected_out=$(printf '%s\n' "$changed_files" | structural_affected "$project_dir" 2>/dev/null) || affected_out=""
  [[ -z "${explore_out//[[:space:]]/}" && -z "${affected_out//[[:space:]]/}" ]] && return 0

  local section
  section="## Structural Context (codegraph symbol graph)
Pre-computed from the project's code index; treat as already read. Verify only what the diff itself contradicts."
  if [[ -n "${explore_out//[[:space:]]/}" ]]; then
    section="${section}

### Blast radius around the changed files
${explore_out}"
  fi
  if [[ -n "${affected_out//[[:space:]]/}" ]]; then
    section="${section}

### Test files transitively affected (check whether they need updates)
${affected_out}"
  fi
  printf '%s' "$section" | head -c "$cap"
}

# Analyze-side messaging: adopt an existing index, hint when the CLI is
# present but the project is unindexed, stay silent when codegraph is absent.
structural_analyze_hint() {
  local project="$1" project_dir="$2"
  command -v "${MRA_CODEGRAPH_BIN:-codegraph}" >/dev/null 2>&1 || return 0
  [[ "$(structural_provider)" != "off" ]] || return 0
  if [[ -d "$project_dir/.codegraph" ]]; then
    log_info "structural: adopting existing codegraph index for $project" "structural"
  else
    log_info "structural: codegraph CLI detected but $project has no index — run 'codegraph init' in $project_dir to enable symbol-level context (mra never indexes for you)" "structural"
  fi
}
