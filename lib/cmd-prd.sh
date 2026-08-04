#!/usr/bin/env bash
# Cross-repo PRD planning commands.
#
# Dispatched by convention from bin/mra.sh: `mra <name>` runs
# mra_cmd_<name> with dashes replaced by underscores. Adding a command means
# adding a function here — the dispatch itself is not edited (#39).
#
# Each still receives the full argv with the command name at $1, exactly as
# the case branch it replaced did, so the `shift` each body opens with means
# the same thing.

mra_cmd_prd() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local graph_file="$workspace/.collab/dep-graph.json"
  local prd_projects=() new_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new)
        [[ -n "${2:-}" && "$2" != -* ]] || { log_error "usage: mra prd --new <name>" "prd"; exit 1; }
        new_name="$2"; shift 2 ;;
      --no-sync) shift ;;  # accepted no-op: the interactive planner never auto-syncs
      -*) log_error "unknown option: $1" "prd"; exit 1 ;;
      *) prd_projects+=("$1"); shift ;;
    esac
  done
  if [[ -n "$new_name" ]]; then
    [[ "${#prd_projects[@]}" -eq 0 ]] || { log_error "prd --new takes no positional projects" "prd"; exit 1; }
    validate_repo_name "$new_name" || { log_error "invalid project name: $new_name" "prd"; exit 1; }
    [[ "$new_name" =~ $_MRA_ID_REGEX ]] || { log_error "name must match $_MRA_ID_REGEX" "prd"; exit 1; }
    prd_launch_new "$workspace" "$graph_file" "$new_name"
  else
    if [[ "${#prd_projects[@]}" -eq 0 ]]; then
      while IFS= read -r p; do prd_projects+=("$p"); done < <(list_all_projects "$graph_file")
    else
      validate_repo_subset "$workspace" "${prd_projects[@]}" || exit 1
    fi
    # No auto-sync: a full-workspace network sync blocks (and can hang) the interactive
    # planner before it even starts, and planning reads the repos + PKB as-is.
    # Run `mra sync` beforehand if you want fresh repos.
    prd_launch "$workspace" "$graph_file" "${prd_projects[@]}"
  fi
}

mra_cmd_prd_issues() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local req="" extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --req) req="$2"; shift 2 ;;
      *) extra+=("$1"); shift ;;
    esac
  done
  [[ -n "$req" ]] || { log_error "usage: mra prd-issues --req <REQ-ID> [--confirm] [--dry-run]" "prd"; exit 1; }
  local tasks="$workspace/.collab/requirements/$req-tasks.json"
  local prd_html="$workspace/.collab/requirements/$req.html"
  local scope_file="$workspace/.collab/requirements/$req-scope"
  [[ -f "$scope_file" ]] || { log_error "no scope record for $req — was it created by 'mra prd'?" "prd"; exit 1; }
  MRA_PRD_PROJECTS="$(cat "$scope_file")"; export MRA_PRD_PROJECTS
  mra_prd_open_issues --tasks "$tasks" --req "$req" --prd-url "$prd_html" "${extra[@]}"
}

mra_cmd_prd_scaffold() {
  shift
  local workspace; workspace=$(resolve_workspace)
  local req="" extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --req) req="$2"; shift 2 ;;
      *) extra+=("$1"); shift ;;
    esac
  done
  [[ -n "$req" ]] || { log_error "usage: mra prd-scaffold --req <REQ-ID> [--confirm] [--dry-run]" "prd"; exit 1; }
  local scaffold="$workspace/.collab/requirements/$req-scaffold.json"
  local tasks="$workspace/.collab/requirements/$req-tasks.json"
  [[ -f "$scaffold" ]] || { log_error "not a greenfield REQ (no scaffold plan) — was it created by 'mra prd --new'?" "prd"; exit 1; }
  mra_prd_scaffold --scaffold "$scaffold" --tasks "$tasks" --req "$req" "${extra[@]}"
}

mra_cmd_prd_render() {
  shift
  [[ -n "${1:-}" ]] || { log_error "usage: mra prd-render <.collab .md path>" "prd"; exit 1; }
  prd_render_html "$1"
}
