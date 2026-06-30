#!/usr/bin/env bash
# `mra prd` apply-side helpers: HTML rendering + GitHub issue creation.
# All mechanical facts live here (shell), never in agent prose.

# Render a .collab markdown file to its sibling .html. Guards: source must be
# under a .collab/ dir (no repo-tree writes), source must be non-empty, and the
# rendered .html must be non-empty (render-html.py returns 0 on a MISSING source
# and writes a non-empty template for an EMPTY one — so we check both ends).
prd_render_html() {
  local md="$1"
  case "$md" in
    */.collab/*) : ;;
    *) log_error "prd_render_html: refusing source outside .collab: $md" "prd"; return 1 ;;
  esac
  [[ -s "$md" ]] || { log_error "prd_render_html: source missing or empty: $md" "prd"; return 1; }
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Friendly preflight (substitute the real module from Step 3 if not 'markdown').
  python3 -c 'import markdown' 2>/dev/null \
    || { log_error "prd_render_html: python 'markdown' not installed — pip install markdown" "prd"; return 1; }
  python3 "$mra_dir/docs/superpowers/render-html.py" "$md" >/dev/null 2>&1 \
    || { log_error "prd_render_html: render failed: $md" "prd"; return 1; }
  local html="${md%.md}.html"
  [[ -s "$html" ]] || { log_error "prd_render_html: rendered html missing/empty: $html" "prd"; return 1; }
  printf '%s\n' "$html"
}

# Validate the Task-Plan JSON before ANY gh call. Fail-fast, name the bad field.
_prd_validate_tasks() {
  local tj="$1" req="$2"
  jq -e . "$tj" >/dev/null 2>&1 || { log_error "tasks.json is not valid JSON: $tj" "prd"; return 1; }
  local got_req; got_req=$(jq -r '.requirement_id // ""' "$tj")
  [[ "$got_req" == "$req" ]] || { log_error "requirement_id mismatch: $got_req != $req" "prd"; return 1; }
  local ids; ids=" $(jq -r '.tasks[].id' "$tj" | tr '\n' ' ') "
  local n; n=$(jq '.tasks | length' "$tj")
  local i
  for (( i=0; i<n; i++ )); do
    local t; t=$(jq -c ".tasks[$i]" "$tj")
    local f
    for f in id project tier dependencies acceptance_criteria; do
      printf '%s' "$t" | jq -e "has(\"$f\")" >/dev/null 2>&1 \
        || { log_error "task[$i] missing field: $f" "prd"; return 1; }
    done
    local proj; proj=$(printf '%s' "$t" | jq -r '.project')
    [[ " ${MRA_PRD_PROJECTS:-} " == *" $proj "* ]] \
      || { log_error "task $(printf '%s' "$t" | jq -r .id): project '$proj' not in loaded scope (MRA_PRD_PROJECTS)" "prd"; return 1; }
    local dep
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      [[ "$ids" == *" $dep "* ]] || { log_error "task references unknown dependency id: $dep" "prd"; return 1; }
    done < <(printf '%s' "$t" | jq -r '.dependencies[]?')
  done
  return 0
}

# Kahn topological sort over the task-id DAG; tier ascending as tie-break.
# On a cycle: warn and fall back to input order (all ids still emitted).
_prd_topo_order() {
  local tj="$1"
  jq -r '
    .tasks as $t
    | ([$t[] | {id, tier, deps: .dependencies}]) as $nodes
    | ($nodes | map(.id)) as $all
    | def kahn(ns):
        if (ns|length)==0 then []
        else
          ([ ns[] | select([.deps[]? | select(. as $d | (ns|map(.id)|index($d)) != null)] | length == 0) ]
            | sort_by(.tier, .id)) as $ready
          | if ($ready|length)==0 then (ns|sort_by(.tier,.id)|map(.id))   # cycle: fallback
            else ($ready[0].id) as $pick
              | [$pick] + kahn([ ns[] | select(.id != $pick) ])
            end
        end;
      kahn($nodes)[]
  ' "$tj" 2>/dev/null || jq -r '.tasks[].id' "$tj"
  # cycle detection warning (non-fatal): if topo length != distinct ids, jq fell back
}

# owner/repo from origin (review.sh:44-45 idiom). Empty on failure.
_prd_resolve_owner() {
  local dir="$1" url slug
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  slug=$(printf '%s' "$url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')
  printf '%s' "$slug"
}

# GH_TOKEN for an owner via ghAccounts[owner] -> gh auth token --user <login>.
# Empty + return 1 on missing mapping OR unresolvable token (never fall back).
_prd_account_token() {
  local owner="$1" login tok
  login=$(config_get ghAccounts 2>/dev/null | jq -r --arg o "$owner" '.[$o] // ""' 2>/dev/null)
  [[ -n "$login" ]] || { log_error "no ghAccounts mapping for owner: $owner" "prd"; return 1; }
  tok=$(gh auth token --user "$login" 2>/dev/null) || true
  [[ -n "$tok" ]] || { log_error "cannot resolve gh token for '$login' — run: gh auth login --user $login" "prd"; return 1; }
  printf '%s' "$tok"
}
