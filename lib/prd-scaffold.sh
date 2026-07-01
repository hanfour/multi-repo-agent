#!/usr/bin/env bash
# `mra prd-scaffold` apply: create the greenfield-planned repos + register them.
# Mirrors lib/prd-issues.sh's gated/ungated/pure three-way skeleton and its TTY gate.

# git@github.com:acme  OR  https://github.com/acme  -> acme
_scaffold_resolve_org() { printf '%s' "$1" | sed -E 's#.*github\.com[:/]([^/]+).*#\1#'; }

_scaffold_validate_plan() {
  local sj="$1" tj="$2" req="$3" bare_org="$4"
  jq -e . "$sj" >/dev/null 2>&1 || { log_error "scaffold.json not valid JSON: $sj" "prd"; return 1; }
  [[ "$(jq -r '.requirement_id // ""' "$sj")" == "$req" ]] || { log_error "scaffold requirement_id mismatch" "prd"; return 1; }
  local n; n=$(jq '.repos | length' "$sj")
  [[ "$n" -ge 1 ]] || { log_error "scaffold plan has no repos" "prd"; return 1; }
  local names; names=" $(jq -r '.repos[].name' "$sj" | tr '\n' ' ') "
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

# Additive, atomic (jq > $tmp && mv), name-keyed idempotent. NEVER build_dep_graph/mra scan.
_scaffold_register() {
  local ws="$1" name="$2" type="$3" desc="$4" deps_csv="$5"
  local dg="$ws/.collab/dep-graph.json" md="$ws/.collab/manual-deps.json" rj="$ws/.collab/repos.json" tmp
  [[ -f "$md" ]] || echo '[]' > "$md"                 # init if absent
  [[ -f "$rj" ]] || echo '{"repos":[]}' > "$rj"
  # 1) dep-graph node, init shape, only if absent — ATOMIC
  tmp=$(mktemp)
  jq --arg n "$name" --arg t "$type" \
    '.projects[$n] = (.projects[$n] // {"type":$t,"port":null,"dockerImage":null,"dockerCompose":null,"lastCommit":"unknown","deps":{},"consumedBy":[],"confidence":{}})' \
    "$dg" > "$tmp" && mv "$tmp" "$dg"
  # 2) manual-deps edges (source depends on target), dedup — ATOMIC
  local d darr
  IFS=',' read -ra darr <<< "$deps_csv"
  for d in ${darr[@]+"${darr[@]}"}; do
    [[ -z "$d" ]] && continue
    tmp=$(mktemp)
    jq --arg s "$name" --arg t "$d" \
      'if any(.[]?; .source==$s and .target==$t) then . else . + [{"source":$s,"target":$t,"type":"api"}] end' \
      "$md" > "$tmp" && mv "$tmp" "$md"
  done
  # 3) repos.json entry, dedup — ATOMIC
  tmp=$(mktemp)
  jq --arg n "$name" --arg desc "$desc" \
    'if any(.repos[]?; .name==$n) then . else .repos += [{"name":$n,"clone":true,"branch":"main","description":$desc,"archived":false}] end' \
    "$rj" > "$tmp" && mv "$tmp" "$rj"
}

_scaffold_write_scope() {
  local ws="$1" req="$2"; shift 2
  printf '%s\n' "$*" > "$ws/.collab/requirements/$req-scope"
}

mra_prd_scaffold() {
  local scaffold="" tasks="" req="" confirm=false dry=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scaffold) scaffold="${2:-}"; shift 2;;
      --tasks) tasks="${2:-}"; shift 2;;
      --req) req="${2:-}"; shift 2;;
      --confirm) confirm=true; shift;;
      --dry-run) dry=true; shift;;
      *) log_error "prd-scaffold: unknown arg: $1" "prd"; return 1;;
    esac
  done
  [[ -n "$scaffold" && -n "$req" ]] || { log_error "usage: mra prd-scaffold --req <ID> [--confirm] [--dry-run]" "prd"; return 1; }
  [[ -f "$scaffold" ]] || { log_error "scaffold plan not found: $scaffold" "prd"; return 1; }
  local ws; ws=$(cd "$(dirname "$scaffold")/../.." && pwd)
  local gitorg bare_org
  gitorg=$(jq -r '.gitOrg // ""' "$ws/.collab/dep-graph.json" 2>/dev/null) || true; bare_org=$(_scaffold_resolve_org "$gitorg")
  _scaffold_validate_plan "$scaffold" "$tasks" "$req" "$bare_org" || return 1
  _scaffold_scan_pii "$scaffold" || return 1
  _prd_account_token "$bare_org" >/dev/null || return 1     # fail-loud before the gate
  _scaffold_print_plan "$scaffold" "$bare_org"
  if [[ "$dry" == true || "$confirm" != true ]]; then
    log_info "preview only — no repos created. Re-run with --confirm in your terminal." "prd"; return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "refusing to create repos non-interactively — run \`mra prd-scaffold --req $req --confirm\` in your own terminal" "prd"; return 0
  fi
  local cnt; cnt=$(jq '.repos|length' "$scaffold")
  printf 'Create %s repo(s) in %s? [y/N] ' "$cnt" "$bare_org" > /dev/tty
  local ans; read -r ans < /dev/tty
  [[ "$ans" == [yY]* ]] || { log_info "aborted — no repos created." "prd"; return 0; }
  _scaffold_create_all "$ws" "$scaffold" "$req" "$bare_org"
}

_scaffold_create_all() {
  local ws="$1" sj="$2" req="$3" bare_org="$4"
  local ledger="$ws/.collab/requirements/$req-scaffold-repos.json"
  [[ -f "$ledger" ]] || echo '{}' > "$ledger"
  local tok; tok=$(_prd_account_token "$bare_org") || return 1   # abort before any create
  local created=() n i; n=$(jq '.repos|length' "$sj")
  for (( i=0; i<n; i++ )); do
    local name vis desc type deps
    name=$(jq -r ".repos[$i].name" "$sj"); vis=$(jq -r ".repos[$i].visibility" "$sj")
    desc=$(jq -r ".repos[$i].description // \"\"" "$sj"); type=$(jq -r ".repos[$i].type" "$sj")
    deps=$(jq -r "[.repos[$i].deps[]?]|join(\",\")" "$sj")
    if jq -e --arg n "$name" 'has($n)' "$ledger" >/dev/null 2>&1; then
      created+=("$name")   # resume: already created
    else
      if GH_TOKEN="$tok" gh repo view "$bare_org/$name" >/dev/null 2>&1; then
        log_error "repo $bare_org/$name already exists (not from this run) — aborting (adopt not supported)" "prd"; return 1
      fi
      ( cd "$ws" && GH_TOKEN="$tok" gh repo create "$bare_org/$name" "--$vis" --description "$desc" --clone ) \
        || { log_error "gh repo create failed: $name" "prd"; return 1; }
      local tmp; tmp=$(mktemp)
      jq --arg n "$name" --arg o "$bare_org" --arg v "$vis" \
        '. + {($n):{org:$o,url:("https://github.com/"+$o+"/"+$n),visibility:$v,created:true,registered:false}}' \
        "$ledger" > "$tmp" && mv "$tmp" "$ledger"
      # verify clone landed at $ws/name; fallback for unborn/no-clone
      [[ -d "$ws/$name/.git" ]] || { mkdir -p "$ws/$name"; git -C "$ws/$name" init -q; \
        git -C "$ws/$name" remote add origin "https://github.com/$bare_org/$name.git" 2>/dev/null || true; }
      GH_TOKEN="$tok" git -C "$ws/$name" commit --allow-empty -q -m "chore: scaffold $name ($req)" || true
      GH_TOKEN="$tok" git -C "$ws/$name" push -u origin HEAD >/dev/null 2>&1 || log_warn "push failed for $name (re-run to resume)" "prd"
      created+=("$name")
    fi
    _scaffold_register "$ws" "$name" "$type" "$desc" "$deps"
    local tmp2; tmp2=$(mktemp)
    jq --arg n "$name" '.[$n].registered = true' "$ledger" > "$tmp2" && mv "$tmp2" "$ledger"
  done
  _scaffold_write_scope "$ws" "$req" ${created[@]+"${created[@]}"}
}
