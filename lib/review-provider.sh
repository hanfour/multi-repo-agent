#!/usr/bin/env bash
# Provider policy + invocation helpers for mra review.
#
# Review defaults to Codex, while Claude remains available as an explicit
# provider or fallback. The helpers here keep provider selection separate from
# review prompt construction and PR posting.

_review_config_value() {
  local key="$1" val
  val=$(config_get "review.$key" 2>/dev/null) || val=""
  [[ "$val" == "null" ]] && val=""
  printf '%s' "$val"
}

review_provider_default_mode() {
  local v config_version
  v=$(_review_config_value "providerMode")
  config_version=$(config_get "configVersion" 2>/dev/null || true)
  if [[ -z "$v" && ( -z "$config_version" || "$config_version" == "null" ) ]]; then
    printf '%s' "claude"
    return 0
  fi
  printf '%s' "${v:-codex}"
}

review_provider_allow_user_override() {
  local v
  v=$(_review_config_value "allowUserOverride")
  [[ "$v" == "true" || "$v" == "1" ]]
}

review_provider_validate_name() {
  case "$1" in
    claude|codex|fallback|dual) return 0 ;;
    *) return 1 ;;
  esac
}

review_provider_effective() {
  local requested="${1:-}" configured
  configured="${MRA_REVIEW_PROVIDER:-$(review_provider_default_mode)}"
  [[ -z "$configured" ]] && configured="codex"

  if ! review_provider_validate_name "$configured"; then
    log_error "invalid configured review provider: $configured (use claude|codex|fallback|dual)" "review"
    return 1
  fi

  if [[ -z "$requested" ]]; then
    printf '%s' "$configured"
    return 0
  fi
  if ! review_provider_validate_name "$requested"; then
    log_error "invalid --provider value: $requested (use claude|codex|fallback|dual)" "review"
    return 1
  fi

  if [[ "$requested" != "$configured" && "${MRA_REVIEW_ADMIN_OVERRIDE:-}" != "1" ]] && ! review_provider_allow_user_override; then
    log_error "--provider $requested is blocked by review.allowUserOverride=false (configured provider: $configured)" "review"
    return 1
  fi

  printf '%s' "$requested"
}

review_provider_primary() {
  local v
  v=$(_review_config_value "primaryProvider")
  printf '%s' "${v:-codex}"
}

review_provider_secondary() {
  local v
  v=$(_review_config_value "secondaryProvider")
  printf '%s' "${v:-claude}"
}

review_provider_dual_merge_policy() {
  local v
  v=$(_review_config_value "dualMergePolicy")
  case "${v:-union}" in
    union|primary|intersection) printf '%s' "${v:-union}" ;;
    *) printf '%s' "union" ;;
  esac
}

_review_provider_validate_backend() {
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

review_provider_effective_model() {
  local provider="$1" cli_model="${2:-}" cli_model_provided="${3:-false}" cfg
  if [[ "$cli_model_provided" == "true" ]]; then
    printf '%s' "$cli_model"
    return 0
  fi

  cfg=$(_review_config_value "models.$provider")
  if [[ -n "$cfg" ]]; then
    printf '%s' "$cfg"
  elif [[ "$provider" == "claude" ]]; then
    printf '%s' "sonnet"
  else
    # Empty means "use the Codex CLI configured default". This avoids baking a
    # model slug into MRA that may not exist in every Codex installation.
    printf '%s' ""
  fi
}

review_provider_label() {
  local provider="$1" model="${2:-}"
  if [[ -n "$model" ]]; then
    printf '%s (%s)' "$provider" "$model"
  else
    printf '%s (default model)' "$provider"
  fi
}

_review_sandbox_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

_review_sandbox_canonical_path() {
  local path="$1" parent base real_parent
  parent=$(dirname "$path")
  base=$(basename "$path")
  if [[ -d "$parent" ]]; then
    real_parent=$(cd "$parent" && pwd -P) || real_parent="$parent"
    printf '%s/%s' "$real_parent" "$base"
  else
    printf '%s' "$path"
  fi
}

_review_write_codex_sandbox_profile() {
  local profile="$1" original_home="$2" path quoted
  {
    echo "(version 1)"
    echo "(allow default)"
    for path in /bin/ps /usr/bin/ps /sbin/sysctl /usr/sbin/sysctl; do
      quoted=$(_review_sandbox_quote "$path")
      echo "(deny process-exec (literal $quoted))"
    done
    for path in \
      "$original_home/.codex" \
      "$original_home/.claude" \
      "$original_home/.config/gh" \
      "$original_home/.ssh" \
      "$original_home/.aws" \
      "$original_home/.gnupg" \
      "$original_home/.docker" \
      "$original_home/.netrc" \
      "$original_home/.npmrc" \
      "$original_home/.pypirc"
    do
      path=$(_review_sandbox_canonical_path "$path")
      quoted=$(_review_sandbox_quote "$path")
      echo "(deny file-read* (subpath $quoted))"
      echo "(deny file-write* (subpath $quoted))"
    done
  } > "$profile"
  chmod 600 "$profile"
}

_review_without_github_credentials() {
  (
    local original_home="${HOME:-}" model_home prefix codex_sandbox_profile="" codex_auth_file="" codex_auth_deleter=""
    prefix="${MRA_REVIEW_MODEL_HOME:-${TMPDIR:-/tmp}/mra-review-model-home-${UID:-user}}"
    model_home=$(mktemp -d "${prefix}.XXXXXX") || return 1
    trap 'chmod -R u+w "$model_home" 2>/dev/null || true; rm -rf "$model_home"' EXIT HUP INT TERM
    mkdir -p "$model_home/.config" "$model_home/gh" "$model_home/.codex" "$model_home/.claude"
    chmod 700 "$model_home" "$model_home/.config" "$model_home/gh" "$model_home/.codex" "$model_home/.claude"
    if [[ "${MRA_REVIEW_AUTH_PROVIDER:-}" == "codex" ]]; then
      codex_auth_file="$model_home/.codex/auth.json"
      _review_copy_auth_file "$original_home/.codex/auth.json" "$codex_auth_file"
      if [[ ! -s "$codex_auth_file" ]] ||
          ! jq -e '.OPENAI_API_KEY | type == "string" and length > 0' "$codex_auth_file" >/dev/null 2>&1; then
        log_error "codex review requires an owner-controlled ~/.codex/auth.json OPENAI_API_KEY" "review" >&2
        return 1
      fi
      codex_sandbox_profile="$model_home/codex-sensitive.sb"
      _review_write_codex_sandbox_profile "$codex_sandbox_profile" "$original_home" || return 1
    else
      _review_copy_auth_file "$original_home/.claude/.credentials.json" "$model_home/.claude/.credentials.json"
    fi
    unset GH_TOKEN GITHUB_TOKEN
    # Auth-file lifetime (issue #17): the codex CLI re-reads auth.json on
    # stream reconnects, so the copied key must live for the whole invocation
    # — it is removed right after the child exits (and by the EXIT trap). A
    # fixed early-delete timer turned every transient relay drop into a
    # guaranteed 401. MRA_CODEX_AUTH_FILE_TTL_SECONDS is now opt-in: set it to
    # restore a hard deletion deadline (0 = delete immediately).
    _codex_start_auth_deleter() {
      local auth_file="$1"
      [[ -n "${MRA_CODEX_AUTH_FILE_TTL_SECONDS:-}" ]] || return 0
      ( sleep "$MRA_CODEX_AUTH_FILE_TTL_SECONDS"; rm -f "$auth_file" ) &
      codex_auth_deleter=$!
    }
    # Kill the deleter instead of waiting it out: waiting on a still-sleeping
    # TTL timer kept the review blocked long after codex exited (issue #18's
    # wait-on-sleeper hang). The auth file is already removed by the caller.
    _codex_stop_auth_deleter() {
      [[ -n "$codex_auth_deleter" ]] || return 0
      kill "$codex_auth_deleter" 2>/dev/null || true
      wait "$codex_auth_deleter" 2>/dev/null || true
    }
    export HOME="$model_home"
    export XDG_CONFIG_HOME="$model_home/.config"
    export GH_CONFIG_DIR="$model_home/gh"
    export GIT_CONFIG_GLOBAL=/dev/null
    export CODEX_HOME="$model_home/.codex"
    local rc=0
    if [[ "${MRA_REVIEW_AUTH_PROVIDER:-}" == "codex" ]]; then
      if ! command -v sandbox-exec >/dev/null 2>&1; then
        if [[ "${MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX:-}" == "1" ]]; then
          _codex_start_auth_deleter "$codex_auth_file"
          "$@" || rc=$?
          rm -f "$codex_auth_file"
          _codex_stop_auth_deleter
          return "$rc"
        fi
        log_error "codex review requires sandbox-exec to block access to local credentials" "review" >&2
        return 1
      fi
      _codex_start_auth_deleter "$codex_auth_file"
      sandbox-exec -f "$codex_sandbox_profile" "$@" || rc=$?
      rm -f "$codex_auth_file"
      _codex_stop_auth_deleter
    else
      "$@" || rc=$?
    fi
    return "$rc"
  )
}

_review_file_owner_uid() {
  local uid
  uid=$(stat -c '%u' "$1" 2>/dev/null || true)
  if [[ "$uid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$uid"
    return 0
  fi
  uid=$(stat -f '%u' "$1" 2>/dev/null || true)
  if [[ "$uid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$uid"
    return 0
  fi
  return 1
}

_review_copy_auth_file() {
  local source="$1" target="$2" owner
  [[ -f "$source" && ! -L "$source" ]] || return 0
  owner=$(_review_file_owner_uid "$source") || return 0
  [[ "$owner" == "$(id -u)" ]] || return 0
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
  chmod 600 "$target"
}

_review_create_sanitized_snapshot() {
  local project_dir="$1" snapshot
  snapshot=$(mktemp -d "${TMPDIR:-/tmp}/mra-review-snapshot.XXXXXX") || return 1
  chmod 700 "$snapshot"
  if ! git -C "$project_dir" archive --format=tar HEAD | tar -xf - -C "$snapshot"; then
    rm -rf "$snapshot"
    return 1
  fi
  # A tracked symlink can escape the snapshot even though the archive itself is
  # commit-bound. Protocol reviews do not need symlinks, so reject that channel
  # entirely instead of attempting target-by-target containment checks.
  find "$snapshot" -type l -delete
  find "$snapshot" -type d \( -name .claude -o -name .codex \) -prune -exec rm -rf {} +
  find "$snapshot" \( -name AGENTS.md -o -name CLAUDE.md -o -name .mcp.json \) -exec rm -rf {} +
  chmod -R a-w "$snapshot"
  printf '%s' "$snapshot"
}

_review_toml_string_value() {
  local file="$1" section="$2" key="$3"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  awk -v wanted="$section" -v key="$key" '
    BEGIN { active = (wanted == "") }
    /^[[:space:]]*\[/ {
      line=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", line)
      active=(line == wanted); next
    }
    active && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0; sub(/^[^=]*=[[:space:]]*/, "", line); sub(/[[:space:]]*#.*/, "", line)
      gsub(/^\"|\"[[:space:]]*$/, "", line); print line; exit
    }
  ' "$file"
}

_review_provider_codex_prompt() {
  local prompt="$1" system_prompt_file="${2:-}"
  if [[ -n "$system_prompt_file" && -f "$system_prompt_file" && ! -L "$system_prompt_file" ]]; then
    printf '%s\n\n%s\n%s\n\n%s' \
      '## Trusted MRA Reviewer Policy' \
      "$(cat "$system_prompt_file")" \
      '## Review Request' \
      "$prompt"
  else
    printf '%s' "$prompt"
  fi
}

_review_call_one_provider() {
  local stream="$1" tag="$2" provider="$3" prompt="$4" model="$5" project_dir="$6"
  local add_dirs="$7" max_turns="${8:-6}" system_prompt_file="${9:-}"
  [[ -n "$model" ]] || model=$(review_provider_effective_model "$provider" "" false)
  case "$provider" in
    claude)
      local _ad=()
      expand_add_dir_string _ad "$add_dirs" || return 1
      local args=(-p "$prompt")
      args+=("${_ad[@]}")
      [[ -n "$system_prompt_file" && -f "$system_prompt_file" ]] && args+=(--append-system-prompt-file "$system_prompt_file")
      [[ -n "$model" ]] && args+=(--model "$model")
      args+=(--max-turns "$max_turns")
      args+=(--disallowedTools "Write,Edit,NotebookEdit")
      if [[ "$stream" == "true" ]]; then
        _review_without_github_credentials claude_invoke --stream "$tag" "${args[@]}"
      else
        _review_without_github_credentials claude_invoke "$tag" "${args[@]}"
      fi
      ;;
    codex)
      local trusted_cwd snapshot rc=0 codex_config provider_name base_url wire_api requires_openai_auth codex_last codex_stdout
      prompt=$(_review_provider_codex_prompt "$prompt" "$system_prompt_file")
      trusted_cwd=$(mktemp -d "${TMPDIR:-/tmp}/mra-review-trusted.XXXXXX") || return 1
      snapshot=$(_review_create_sanitized_snapshot "$project_dir") || { rm -rf "$trusted_cwd"; return 1; }
      codex_last=$(mktemp "${TMPDIR:-/tmp}/mra-codex-last.XXXXXX") || { chmod -R u+w "$snapshot" 2>/dev/null || true; rm -rf "$snapshot" "$trusted_cwd"; return 1; }
      codex_stdout=$(mktemp "${TMPDIR:-/tmp}/mra-codex-stdout.XXXXXX") || { rm -f "$codex_last"; chmod -R u+w "$snapshot" 2>/dev/null || true; rm -rf "$snapshot" "$trusted_cwd"; return 1; }
      chmod 600 "$codex_last" "$codex_stdout"
      chmod 700 "$trusted_cwd"
      codex_config="${CODEX_HOME:-${HOME:-}/.codex}/config.toml"
      provider_name=$(_review_toml_string_value "$codex_config" "" model_provider)
      [[ "$provider_name" =~ ^[A-Za-z0-9._-]+$ ]] || provider_name="OpenAI"
      base_url=$(_review_toml_string_value "$codex_config" "model_providers.$provider_name" base_url)
      wire_api=$(_review_toml_string_value "$codex_config" "model_providers.$provider_name" wire_api)
      requires_openai_auth=$(_review_toml_string_value "$codex_config" "model_providers.$provider_name" requires_openai_auth)
      [[ "$base_url" =~ ^https://[A-Za-z0-9._:/-]+$ ]] || base_url="https://api.openai.com/v1"
      [[ "$wire_api" =~ ^(responses|chat)$ ]] || wire_api="responses"
      local args=(exec --sandbox read-only --cd "$trusted_cwd" --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules
        --output-last-message "$codex_last"
        -c shell_environment_policy.inherit=none
        -c 'shell_environment_policy.set.PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"'
        --add-dir "$snapshot"
        -c "model_provider=\"$provider_name\""
        -c "model_providers.$provider_name.name=\"$provider_name\""
        -c "model_providers.$provider_name.base_url=\"$base_url\""
        -c "model_providers.$provider_name.wire_api=\"$wire_api\"")
      if [[ "$requires_openai_auth" == "true" || "$requires_openai_auth" == "false" ]]; then
        args+=(-c "model_providers.$provider_name.requires_openai_auth=$requires_openai_auth")
      fi
      [[ -n "$model" ]] && args+=(--model "$model")
      args+=("$prompt")
      MRA_REVIEW_AUTH_PROVIDER=codex _review_without_github_credentials "${MRA_CODEX_BIN:-codex}" "${args[@]}" >"$codex_stdout" || rc=$?
      if [[ "$stream" == "true" && -s "$codex_stdout" ]]; then
        cat "$codex_stdout" >&2
      fi
      if [[ "$rc" -eq 0 ]]; then
        if [[ -s "$codex_last" ]]; then
          cat "$codex_last"
        elif [[ -s "$codex_stdout" ]]; then
          # Test doubles and older Codex builds may not implement
          # --output-last-message; keep the stdout fallback isolated here.
          cat "$codex_stdout"
        fi
      fi
      rm -f "$codex_last" "$codex_stdout"
      chmod -R u+w "$snapshot" 2>/dev/null || true
      rm -rf "$snapshot" "$trusted_cwd"
      return "$rc"
      ;;
    *)
      log_error "unsupported review provider at invocation time: $provider" "$tag" >&2
      return 2
      ;;
  esac
}

review_call_model() {
  local stream=false
  if [[ "${1:-}" == "--stream" ]]; then stream=true; shift; fi
  local tag="$1" provider="$2" prompt="$3" model="$4" project_dir="$5"
  local add_dirs="$6" max_turns="${7:-6}" system_prompt_file="${8:-}"

  case "$provider" in
    claude|codex)
      _review_call_one_provider "$stream" "$tag" "$provider" "$prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "$system_prompt_file"
      ;;
    fallback)
      if [[ "$stream" == "true" ]]; then
        log_info "fallback captures provider output before rendering so a secondary can run safely" "$tag" >&2
        stream=false
      fi
      local primary secondary out rc
      primary=$(review_provider_primary)
      secondary=$(review_provider_secondary)
      if ! _review_provider_validate_backend "$primary" || ! _review_provider_validate_backend "$secondary"; then
        log_error "fallback provider requires primary/secondary to be claude or codex (got '$primary'/'$secondary')" "$tag" >&2
        return 2
      fi
      if out=$(_review_call_one_provider false "$tag" "$primary" "$prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "$system_prompt_file"); then
        rc=0
      else
        rc=$?
      fi
      if [[ "$rc" -eq 0 && -n "$out" ]] && _review_provider_output_complete "$out"; then
        printf '%s' "$out"
        return 0
      fi
      log_warn "review primary provider '$primary' failed or returned an incomplete review; trying '$secondary'" "$tag" >&2
      if out=$(_review_call_one_provider false "$tag" "$secondary" "$prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "$system_prompt_file"); then
        rc=0
      else
        rc=$?
      fi
      if [[ "$rc" -eq 0 && -n "$out" ]] && _review_provider_output_complete "$out"; then
        printf '%s' "$out"
        return 0
      fi
      log_error "review fallback provider '$secondary' also failed or returned an incomplete review" "$tag" >&2
      return 1
      ;;
    dual)
      local primary secondary primary_out secondary_out primary_rc=0 secondary_rc=0 merged status
      primary=$(review_provider_primary)
      secondary=$(review_provider_secondary)
      if ! _review_provider_validate_backend "$primary" || ! _review_provider_validate_backend "$secondary"; then
        log_error "dual provider requires primary/secondary to be claude or codex (got '$primary'/'$secondary')" "$tag" >&2
        return 2
      fi
      primary_out=$(_review_call_one_provider false "$tag" "$primary" "$prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "$system_prompt_file") || primary_rc=$?
      secondary_out=$(_review_call_one_provider false "$tag" "$secondary" "$prompt" "$model" "$project_dir" "$add_dirs" "$max_turns" "$system_prompt_file") || secondary_rc=$?
      if [[ "$primary_rc" -ne 0 ]]; then
        log_warn "dual primary provider '$primary' failed with rc=$primary_rc; merging whatever output is available" "$tag" >&2
      fi
      if [[ "$secondary_rc" -ne 0 ]]; then
        log_warn "dual secondary provider '$secondary' failed with rc=$secondary_rc; merging whatever output is available" "$tag" >&2
      fi
      if [[ -z "$primary_out" && -z "$secondary_out" ]]; then
        return 1
      fi
      merged=$(_review_provider_merge_dual_json "$primary" "$primary_out" "$secondary" "$secondary_out")
      printf '%s\n' "$merged"
      status=$(printf '%s' "$merged" | jq -r '.status // ""' 2>/dev/null || true)
      case "$status" in
        APPROVED|CHANGES_REQUESTED)
          printf '===%s: %s===\n' "$MRA_REVIEW_SENTINEL_TOKEN" "$status"
          ;;
      esac
      ;;
    *)
      log_error "unknown review provider: $provider" "$tag" >&2
      return 2
      ;;
  esac
}

_review_provider_incomplete_json() {
  local reason="$1"
  if declare -F review_incomplete_json >/dev/null 2>&1; then
    review_incomplete_json "$reason"
  else
    jq -cn --arg s "REVIEW_INCOMPLETE — ${reason}" '{status:"COMMENT", summary:$s, comments:[]}'
  fi
}

_review_provider_singlepass_json() {
  local raw="$1" provider="$2"
  if declare -F _review_singlepass_body >/dev/null 2>&1; then
    _review_singlepass_body "$raw"
    return 0
  fi
  _review_provider_incomplete_json "$provider did not emit a validated review body."
}

_review_provider_output_complete() {
  local raw="$1" json status summary sentinel_status
  [[ "$raw" == *"===${MRA_REVIEW_SENTINEL_TOKEN}: "*"==="* ]] || return 1
  json=$(_review_provider_singlepass_json "$raw" "provider")
  _validate_review_json "$json" >/dev/null 2>&1 || return 1
  status=$(printf '%s' "$json" | jq -r '.status // ""' 2>/dev/null)
  summary=$(printf '%s' "$json" | jq -r '.summary // ""' 2>/dev/null)
  sentinel_status=$(printf '%s\n' "$raw" | awk -v token="$MRA_REVIEW_SENTINEL_TOKEN" '
    $0 == "===" token ": APPROVED===" { status="APPROVED" }
    $0 == "===" token ": CHANGES_REQUESTED===" { status="CHANGES_REQUESTED" }
    END { print status }
  ')
  [[ -n "$sentinel_status" && "$status" == "$sentinel_status" ]] || return 1
  [[ "$status" != "COMMENT" && "$summary" != *"REVIEW_INCOMPLETE"* ]]
}

_review_provider_merge_dual_json() {
  local primary="$1" primary_raw="$2" secondary="$3" secondary_raw="$4"
  local primary_json secondary_json policy
  primary_json=$(_review_provider_singlepass_json "$primary_raw" "$primary")
  secondary_json=$(_review_provider_singlepass_json "$secondary_raw" "$secondary")
  policy=$(review_provider_dual_merge_policy)
  jq -cn \
    --arg primary "$primary" \
    --arg secondary "$secondary" \
    --arg policy "$policy" \
    --argjson a "$primary_json" \
    --argjson b "$secondary_json" '
      def incomplete($x):
        (($x.status // "") == "COMMENT" and (($x.summary // "") | contains("REVIEW_INCOMPLETE")));
      def comments($x):
        (($x.comments // []) | map(select(type == "object")));
      def comment_key($x):
        [($x.path // ""), ($x.line // null), ($x.severity // "")];
      def has_blocker($cs):
        any($cs[]?; (.severity == "CRITICAL" or .severity == "HIGH"));
      def union_comments:
        ((comments($a) + comments($b)) | unique_by([.path, .line, .severity, .body]));
      def primary_comments:
        comments($a);
      def intersection_comments:
        (comments($a) as $ac | comments($b) as $bc
          | [$ac[] as $x | $bc[] | select(comment_key(.) == comment_key($x)) | $x]
          | unique_by([.path, .line, .severity, .body]));
      def selected_comments:
        if $policy == "primary" then primary_comments
        elif $policy == "intersection" then intersection_comments
        else union_comments
        end;
      def blocker_comments:
        (union_comments | map(select(.severity == "CRITICAL" or .severity == "HIGH")));
      def source_status($x; $cs):
        if incomplete($x) then "COMMENT"
        elif (($x.status // "") == "CHANGES_REQUESTED") then "CHANGES_REQUESTED"
        elif (($x.status // "") == "APPROVED") then
          if has_blocker($cs) then "CHANGES_REQUESTED" else "APPROVED" end
        else "COMMENT"
        end;
      def gate_status($blockers):
        if incomplete($a) or incomplete($b) then "COMMENT"
        elif ($blockers | length) > 0 then "CHANGES_REQUESTED"
        elif (($a.status // "") == "CHANGES_REQUESTED") or (($b.status // "") == "CHANGES_REQUESTED") then "CHANGES_REQUESTED"
        elif (($a.status // "") == "APPROVED") and (($b.status // "") == "APPROVED") then "APPROVED"
        else "COMMENT"
        end;
      selected_comments as $comments |
      blocker_comments as $blockers |
      {
        status: gate_status($blockers),
        summary: (
          "Dual-provider review (" + $primary + " + " + $secondary + ", merge policy: " + $policy + ").\n\n" +
          (if ($blockers | length) > 0 then "Approval gate includes " + (($blockers | length) | tostring) + " HIGH/CRITICAL blocker(s) across all providers.\n\n" else "" end) +
          $primary + ": " + ($a.summary // "no summary") + "\n\n" +
          $secondary + ": " + ($b.summary // "no summary")
        ),
        comments: $comments,
        blockerLedger: $blockers
      }'
}
