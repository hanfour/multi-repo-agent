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
# On a cycle: warns (stderr) and falls back to input order (all ids still emitted).
_prd_topo_order() {
  local tj="$1"
  local total ids emitted
  total=$(jq '.tasks|length' "$tj")
  # jq emits only the acyclic prefix; when a cycle is detected ($ready empty)
  # it returns [] (no further ids), so the shell can count and detect the gap.
  ids=$(jq -r '
    .tasks as $t
    | ([$t[] | {id, tier, deps: .dependencies}]) as $nodes
    | def kahn(ns):
        if (ns|length)==0 then []
        else
          ([ ns[] | select([.deps[]? | select(. as $d | (ns|map(.id)|index($d)) != null)] | length == 0) ]
            | sort_by(.tier, .id)) as $ready
          | if ($ready|length)==0 then []
            else ($ready[0].id) as $pick
              | [$pick] + kahn([ ns[] | select(.id != $pick) ])
            end
        end;
      kahn($nodes)[]
  ' "$tj" 2>/dev/null)
  # Count non-blank lines emitted
  emitted=0
  if [[ -n "$ids" ]]; then
    emitted=$(printf '%s\n' "$ids" | grep -c '[^[:space:]]') || true
  fi
  if (( emitted < total )); then
    log_warn "prd: dependency cycle detected — using input order" "prd" >&2
    jq -r '.tasks[].id' "$tj"
  else
    printf '%s\n' "$ids"
  fi
}

# owner/repo from origin (review.sh:44-45 idiom). Empty on failure.
_prd_resolve_owner() {
  local dir="$1" url slug
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  slug=$(printf '%s' "$url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')
  printf '%s' "$slug"
}

# Build one issue body: title + acceptance checklist + PRD link + hidden resume marker.
_prd_issue_body() {
  local tj="$1" tid="$2" req="$3" prd_url="$4"
  local title ac
  title=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).title' "$tj")
  ac=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).acceptance_criteria[] | "- [ ] \(.)"' "$tj")
  printf '%s\n\n## Acceptance\n%s\n\nPRD: %s\n\n<!-- mra-prd %s:%s -->\n' "$title" "$ac" "$prd_url" "$req" "$tid"
}

# Pattern-based PII/secret guard over task text (reduces, not eliminates).
_prd_scan_pii() {
  local tj="$1" hits
  hits=$(jq -r '.tasks[] | .title, (.acceptance_criteria[]?)' "$tj" \
    | grep -niE '@[a-z0-9._-]+\.(com|org|net|io|tv)|(ghp_|sk-|AKIA)[A-Za-z0-9]{10,}|-----BEGIN' || true)
  [[ -z "$hits" ]] || { log_error "prd-issues: possible secret/PII in task text — aborting" "prd"; printf '%s\n' "$hits" >&2; return 1; }
  return 0
}

# Print the shell-computed plan (dependency-ordered) — what WILL be created.
_prd_print_plan() {
  local tj="$1" req="$2" tid proj title tier deps
  log_info "Issue plan for $req:" "prd"
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    proj=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).project' "$tj")
    title=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).title' "$tj")
    tier=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).tier' "$tj")
    deps=$(jq -r --arg t "$tid" '[.tasks[]|select(.id==$t).dependencies[]?]|join(",")' "$tj")
    printf '  [%s] tier %s  %s  (%s)%s\n' "$proj" "$tier" "$title" "$tid" "${deps:+  depends:$deps}" >&2
  done < <(_prd_topo_order "$tj")
}

# Un-gated create worker: labels + two-pass create+link + immutable ledger resume.
_prd_create_all() {
  local tj="$1" req="$2" prd_url="$3"
  local ws ledger; ws=$(cd "$(dirname "$tj")/../.." && pwd); ledger="${tj%-tasks.json}-issues.json"
  [[ "$tj" == *-tasks.json ]] || ledger="${tj%.json}-issues.json"
  [[ -f "$ledger" ]] || echo '{}' > "$ledger"
  local order; order=$(_prd_topo_order "$tj")
  local tid
  # PASS 1: create (skip ids already in the ledger -> resume-safe)
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    jq -e --arg t "$tid" 'has($t)' "$ledger" >/dev/null 2>&1 && continue
    local proj tier dir owner tok body url num
    proj=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).project' "$tj")
    tier=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).tier' "$tj")
    dir="$ws/$proj"; owner=$(_prd_resolve_owner "$dir")
    tok=$(_prd_account_token "${owner%%/*}") || { log_error "abort before create: $proj" "prd"; return 1; }
    GH_TOKEN="$tok" gh label create mra-prd -R "$owner" --force >/dev/null 2>&1 || true
    GH_TOKEN="$tok" gh label create "tier:$tier" -R "$owner" --force >/dev/null 2>&1 || true
    body=$(_prd_issue_body "$tj" "$tid" "$req" "$prd_url")
    local title_str; title_str=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).title' "$tj")
    local tmpurl; tmpurl=$(mktemp)
    GH_TOKEN="$tok" gh issue create -R "$owner" --title "$title_str" --label mra-prd --label "tier:$tier" --body "$body" > "$tmpurl" 2>/dev/null
    url=$(< "$tmpurl"); rm -f "$tmpurl"
    num=$(printf '%s' "$url" | sed 's|.*/issues/\([0-9][0-9]*\).*|\1|')
    [[ "$num" =~ ^[0-9]+$ ]] || { log_error "could not parse issue number: $url" "prd"; return 1; }
    local tmp; tmp=$(mktemp)
    jq --arg t "$tid" --arg o "$owner" --argjson n "$num" --arg u "$url" '. + {($t):{repo:$o,number:$n,url:$u}}' "$ledger" > "$tmp" && mv "$tmp" "$ledger"
  done <<< "$order"
  # PASS 2: inject "Depends on: owner/repo#N" (best-effort, idempotent)
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    local refs="" d ref
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      ref=$(jq -r --arg d "$d" '.[$d] | if .==null then "" else "\(.repo)#\(.number)" end' "$ledger")
      [[ -n "$ref" ]] && refs+="Depends on: $ref"$'\n'
    done < <(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).dependencies[]?' "$tj")
    [[ -z "$refs" ]] && continue
    local proj dir owner tok num body
    proj=$(jq -r --arg t "$tid" '.tasks[]|select(.id==$t).project' "$tj")
    dir="$ws/$proj"; owner=$(_prd_resolve_owner "$dir"); tok=$(_prd_account_token "${owner%%/*}") || continue
    num=$(jq -r --arg t "$tid" '.[$t].number' "$ledger")
    body=$(_prd_issue_body "$tj" "$tid" "$req" "$prd_url")$'\n'"$refs"
    GH_TOKEN="$tok" gh issue edit "$num" -R "$owner" --body "$body" >/dev/null 2>&1 || log_warn "depends-on link failed: $tid" "prd"
  done <<< "$order"
}

# The gated entry point.
mra_prd_open_issues() {
  local tasks="" req="" prd_url="" confirm=false dry=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tasks) tasks="${2:-}"; shift 2;;
      --req) req="${2:-}"; shift 2;;
      --prd-url) prd_url="${2:-}"; shift 2;;
      --confirm) confirm=true; shift;;
      --dry-run) dry=true; shift;;
      *) log_error "prd-issues: unknown arg: $1" "prd"; return 1;;
    esac
  done
  [[ -n "$tasks" && -n "$req" ]] || { log_error "usage: mra prd-issues --req <ID> [--confirm] [--dry-run]" "prd"; return 1; }
  [[ -f "$tasks" ]] || { log_error "tasks.json not found: $tasks" "prd"; return 1; }
  _prd_validate_tasks "$tasks" "$req" || return 1
  _prd_scan_pii "$tasks" || return 1
  _prd_print_plan "$tasks" "$req"
  if [[ "$dry" == true || "$confirm" != true ]]; then
    log_info "preview only — no issues created. Re-run with --confirm in your terminal." "prd"; return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "refusing to create non-interactively — run \`mra prd-issues --req $req --confirm\` in your own terminal" "prd"; return 0
  fi
  local n; n=$(jq '.tasks|length' "$tasks")
  printf 'Create %s issue(s)? [y/N] ' "$n" > /dev/tty
  local ans; read -r ans < /dev/tty
  [[ "$ans" == [yY]* ]] || { log_info "aborted — no issues created." "prd"; return 0; }
  _prd_create_all "$tasks" "$req" "$prd_url"
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
