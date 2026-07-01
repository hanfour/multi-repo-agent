#!/usr/bin/env bash
# `mra prd-scaffold` apply: create the greenfield-planned repos + register them.
# Mirrors lib/prd-issues.sh's gated/ungated/pure three-way skeleton and its TTY gate.

# git@github.com:acme  OR  https://github.com/acme  -> acme
_scaffold_resolve_org() { printf '%s' "$1" | sed -E 's#.*github\.com[:/]([^/]+).*#\1#'; }

_scaffold_validate_plan() {
  local sj="$1" tj="$2" req="$3" bare_org="$4"
  jq -e . "$sj" >/dev/null 2>&1 || { log_error "scaffold.json not valid JSON: $sj" "prd"; return 1; }
  [[ "$(jq -r '.requirement_id // ""' "$sj")" == "$req" ]] || { log_error "scaffold requirement_id mismatch" "prd"; return 1; }
  local names; names=" $(jq -r '.repos[].name' "$sj" | tr '\n' ' ') "
  local n; n=$(jq '.repos | length' "$sj")
  [[ "$n" -ge 1 ]] || { log_error "scaffold plan has no repos" "prd"; return 1; }
  local i
  for (( i=0; i<n; i++ )); do
    local r name org vis f; r=$(jq -c ".repos[$i]" "$sj")
    for f in name org visibility type; do
      printf '%s' "$r" | jq -e "has(\"$f\")" >/dev/null 2>&1 || { log_error "repo[$i] missing field: $f" "prd"; return 1; }
    done
    name=$(printf '%s' "$r"|jq -r .name); org=$(printf '%s' "$r"|jq -r .org); vis=$(printf '%s' "$r"|jq -r .visibility)
    validate_repo_name "$name" || { log_error "invalid repo name: $name" "prd"; return 1; }
    [[ "$name" =~ $_MRA_ID_REGEX ]] || { log_error "repo name outside $_MRA_ID_REGEX: $name" "prd"; return 1; }
    [[ "$org" == "$bare_org" ]] || { log_error "repo $name org '$org' != workspace org '$bare_org' (v1 single-org)" "prd"; return 1; }
    [[ "$vis" == "private" || "$vis" == "public" ]] || { log_error "repo $name visibility must be private|public" "prd"; return 1; }
  done
  if [[ -n "$tj" && -f "$tj" ]]; then
    local p
    while IFS= read -r p; do [[ -z "$p" ]] && continue; [[ "$names" == *" $p "* ]] || { log_error "task project '$p' not in scaffold repos" "prd"; return 1; }; done < <(jq -r '.tasks[]?.project' "$tj")
  fi
  return 0
}

_scaffold_scan_pii() {
  local sj="$1" hits
  hits=$(jq -r '.repos[] | .name, .org, (.description // "")' "$sj" \
    | grep -niE '@[a-z0-9._-]+\.(com|org|net|io|tv)|(ghp_|sk-|AKIA)[A-Za-z0-9]{10,}|-----BEGIN' || true)
  [[ -z "$hits" ]] || { log_error "prd-scaffold: possible secret/PII in scaffold plan — aborting" "prd"; printf '%s\n' "$hits" >&2; return 1; }
  return 0
}

_scaffold_print_plan() {
  local sj="$1" org="$2" n i
  log_info "Scaffold plan (org $org):" "prd"
  n=$(jq '.repos|length' "$sj")
  for (( i=0; i<n; i++ )); do
    printf '  create %s/%s [%s] %s\n' "$org" "$(jq -r ".repos[$i].name" "$sj")" "$(jq -r ".repos[$i].visibility" "$sj")" "$(jq -r ".repos[$i].type" "$sj")" >&2
  done
}
