#!/usr/bin/env bash
# `mra prd` interactive launcher: REQ-id allocation + prd_launch.

# Atomically reserve the next REQ-YYYY-NNNN via mkdir-lock. Scans existing .md
# and .locks/ for max+1; retries on EEXIST. Cleaned of empty reservations by
# the caller on normal exit.
_prd_alloc_req_id() {
  local workspace="$1" year="${2:-$(date +%Y)}"
  local reqdir="$workspace/.collab/requirements" lockdir="$workspace/.collab/requirements/.locks"
  mkdir -p "$lockdir"
  local f base n max=0
  for f in "$reqdir"/REQ-"$year"-*.md "$lockdir"/REQ-"$year"-*; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f"); base="${base%.md}"; n="${base##*-}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n > max )) && max=$((10#$n))
  done
  local i id
  for (( i=max+1; i<=max+50; i++ )); do
    id=$(printf 'REQ-%s-%04d' "$year" "$i")
    if mkdir "$lockdir/$id" 2>/dev/null; then printf '%s' "$id"; return 0; fi
  done
  log_error "prd: could not allocate a REQ id" "prd"; return 1
}

# Greenfield sibling of prd_launch: no existing repos/PKB, no scope sidecar.
prd_launch_new() {
  local workspace="$1" graph_file="$2" new_name="$3"
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local req; req=$(_prd_alloc_req_id "$workspace") || return 1
  # Bare org the scaffold apply will require every repo to belong to (org==gitOrg).
  # Compute it authoritatively and hand it to the agent so it can't guess wrong.
  local bare_org; bare_org=$(jq -r '.gitOrg // ""' "$graph_file" 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+).*#\1#')
  export MRA_PRD_REQ_ID="$req"
  export MRA_PRD_MODE=new
  export MRA_PRD_NEW_NAME="$new_name"
  export MRA_PRD_ORG="$bare_org"
  local frags="## mra prd --new session
You are planning a BRAND-NEW project '${new_name}' (${req}). Workspace root: ${workspace}.
No existing repos or PKB — invent the architecture; propose a repo split + stack for the human to confirm.
All new repos belong to the GitHub org: ${bare_org}. Use MRA_PRD_ORG='${bare_org}' verbatim for every repo's 'org' field.
Write ALL artifacts under ${workspace}/.collab/ only. Render each .md via: mra prd-render \"<abs .md>\".
You do NOT create repos or issues. When ready, STOP and tell the operator to run in their own terminal:
  mra prd-scaffold --req ${req} --confirm
  mra prd-issues   --req ${req} --confirm"
  [[ -n "${MRA_PRD_CLAUDE_BIN:-}" ]] && export MRA_CLAUDE_BIN="$MRA_PRD_CLAUDE_BIN"
  # No trailing project args -> zero --add-dir, zero PKB. No scope sidecar (written by scaffold apply).
  ( cd "$workspace" && _launch_interactive "$workspace" "$graph_file" "$mra_dir/agents/prd-agent-new.md" "$frags" )
}

prd_launch() {
  local workspace="$1" graph_file="$2"; shift 2
  local projects=("$@")
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local req; req=$(_prd_alloc_req_id "$workspace") || return 1
  export MRA_PRD_REQ_ID="$req"
  export MRA_PRD_PROJECTS="${projects[*]}"
  printf '%s\n' "${projects[*]}" > "$workspace/.collab/requirements/$req-scope"
  local frags
  frags="## mra prd session
You are planning ${req}. Workspace root: ${workspace}. Write ALL artifacts under ${workspace}/.collab/ only.
Preview the issue plan with: ${mra_dir}/bin/mra.sh prd-issues --req ${req} --dry-run
You do NOT create issues. After presenting the plan, STOP and tell the operator to run, in their own terminal:
  mra prd-issues --req ${req} --confirm"
  [[ -n "${MRA_PRD_CLAUDE_BIN:-}" ]] && export MRA_CLAUDE_BIN="$MRA_PRD_CLAUDE_BIN"
  ( cd "$workspace" && _launch_interactive "$workspace" "$graph_file" "$mra_dir/agents/prd-agent.md" "$frags" "${projects[@]}" )
}
