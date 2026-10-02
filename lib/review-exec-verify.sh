#!/usr/bin/env bash
# Runtime checks may remove findings, never add them. Contract: a failure
# anywhere in this stage returns the input JSON unchanged.

_review_exec_verify_prompt() {
  local findings="$1"
  cat <<HDR
## Runtime behaviour verification

For each finding below, decide whether its correctness DEPENDS on a language
or standard-library behaviour that can be checked by a short, self-contained
program. Use only Ruby or Node.js standard-library behaviour. The program must
not use repository code, gems, npm packages, databases, networks, or files.

Return a claim only when the finding is about that runtime behaviour. Do NOT
return findings whose truth depends on application code, data, framework
behaviour such as Rails or Vue, or anything else outside the runtime itself.
For each claim, return the zero-based finding index, language, optional setup,
expression, and claimed_outcome. setup contains statements that run before the
expression and must not print. expression must be a single expression, with no
statements or trailing semicolons. claimed_outcome is what the FINDING says
will happen, copied from the finding's own claim: use RAISES <ExceptionClass>
if the finding says the expression raises, crashes, or throws, or RETURNS
<inspect form> if it says the expression returns a specific value. Do NOT
evaluate whether the finding is right and do NOT write the behaviour you
expect; the program will be run to find out. Only include a claim if the
finding's assertion maps to exactly one of those two forms; otherwise leave it
out. For example, {"index":0,"language":"ruby","setup":"",
"expression":"nil.to_i","claimed_outcome":"RETURNS 0"} represents a finding
that says the expression returns 0. {"index":1,"language":"node",
"setup":"const value = null","expression":"value.toString()",
"claimed_outcome":"RAISES TypeError"} represents a finding that says the
expression throws TypeError. If a finding says Integer("12") raises
ArgumentError, use {"index":2,"language":"ruby","setup":"",
"expression":"Integer(\"12\")","claimed_outcome":"RAISES ArgumentError"},
even though that expression actually returns 12.

Reply with a strict JSON array only, with objects in this form:
[{"index":0,"language":"ruby","setup":"...","expression":"...","claimed_outcome":"..."}]
setup may be omitted or empty.
Return [] when no finding is checkable.

### Findings

$findings
HDR
}

_review_exec_verify_docker_call() {
  local docker_bin="$1"
  shift
  local input_file="" timeout_bin="" docker_pid watchdog_pid timeout_file rc
  if [[ "${1:-}" == "--stdin-file" ]]; then
    input_file="$2"
    shift 2
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=$(command -v timeout)
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=$(command -v gtimeout)
  fi

  if [[ -n "$timeout_bin" ]]; then
    if [[ -n "$input_file" ]]; then
      "$timeout_bin" -k 2 20 "$docker_bin" "$@" < "$input_file"
    else
      "$timeout_bin" -k 2 20 "$docker_bin" "$@" </dev/null
    fi
    return $?
  fi

  timeout_file=$(mktemp "${TMPDIR:-/tmp}/mra-review-exec-verify.timeout.XXXXXX") || return 125
  rm -f "$timeout_file" || return 125
  if [[ -n "$input_file" ]]; then
    "$docker_bin" "$@" < "$input_file" &
  else
    "$docker_bin" "$@" </dev/null &
  fi
  docker_pid=$!
  (
    sleep 20 &
    local timer_pid=$!
    local grace_pid=""
    trap 'kill "$timer_pid" 2>/dev/null || true; if [[ -n "$grace_pid" ]]; then kill "$grace_pid" 2>/dev/null || true; fi; exit 0' TERM INT
    wait "$timer_pid"
    : > "$timeout_file"
    kill -TERM "$docker_pid" 2>/dev/null || true
    sleep 2 &
    grace_pid=$!
    wait "$grace_pid" 2>/dev/null || true
    kill -KILL "$docker_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  if wait "$docker_pid"; then rc=0; else rc=$?; fi
  if [[ -f "$timeout_file" ]]; then rc=124; fi
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  rm -f "$timeout_file" || true
  return "$rc"
}

_review_exec_verify_docker_run() {
  local docker_bin="$1" image="$2" runtime="$3" program="$4" output_file="$5" container_name="$6"
  local input_file rc

  input_file=$(mktemp "${TMPDIR:-/tmp}/mra-review-exec-verify.input.XXXXXX") || return 125
  printf '%s\n' "$program" > "$input_file" || { rm -f "$input_file" || true; return 125; }
  if _review_exec_verify_docker_call "$docker_bin" --stdin-file "$input_file" run --rm \
    --name "$container_name" --init -i --network none --read-only \
    --tmpfs /tmp:rw,size=16m --memory 256m --cpus 1 --pids-limit 64 \
    --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
    "$image" "$runtime" - >"$output_file" 2>/dev/null; then
    rm -f "$input_file" || true
    return 0
  else
    rc=$?
  fi
  rm -f "$input_file" || true

  if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 143 ]]; then
    _review_exec_verify_docker_call "$docker_bin" kill "$container_name" >/dev/null 2>&1 || true
    _review_exec_verify_docker_call "$docker_bin" rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  return "$rc"
}

_review_exec_verify_normalize_line() {
  local value="$1"
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || value=""
  if [[ "$value" == "RAISES "* ]]; then value=${value%%:*}; fi
  printf '%s' "$value"
}

_review_exec_verify_program() {
  local language="$1" setup="$2" expression="$3"
  if [[ "$language" == "ruby" ]]; then
    printf 'begin\n%s\n__mra_v = (%s)\nputs "RETURNS #{__mra_v.inspect}"\nrescue Exception => __mra_e\nputs "RAISES #{__mra_e.class}"\nend\n' "$setup" "$expression"
  else
    printf 'try {\n%s\nconst __mra_v = (%s);\nconsole.log("RETURNS " + require("util").inspect(__mra_v));\n} catch (__mra_e) {\nconsole.log("RAISES " + ((__mra_e && __mra_e.constructor && __mra_e.constructor.name) || typeof __mra_e));\n}\n' "$setup" "$expression"
  fi
}

# _review_exec_verify_findings <review-json> <project-dir> <provider> <model> <add-dirs> <turns> <system-prompt-file>
_review_exec_verify_findings() {
  local review_json="$1" project_dir="$2" provider="${3:-claude}" model="${4:-}"
  local add_dirs="${5:-}" turns="${6:-6}" sys="${7:-}"

  [[ "${MRA_REVIEW_EXEC_VERIFY:-0}" == "1" ]] || { printf '%s' "$review_json"; return 0; }
  printf '%s' "$review_json" | jq -e . >/dev/null 2>&1 || { printf '%s' "$review_json"; return 0; }

  local n findings prompt raw claims docker_bin
  n=$(printf '%s' "$review_json" | jq -r 'if (.comments | type) == "array" then (.comments | length) else 0 end' 2>/dev/null) || n=0
  [[ "$n" -gt 0 ]] || { printf '%s' "$review_json"; return 0; }

  findings=$(printf '%s' "$review_json" | jq -c '[.comments | to_entries[] | {index: .key, finding: .value}]' 2>/dev/null) || {
    printf '%s' "$review_json"; return 0;
  }
  prompt=$(_review_exec_verify_prompt "$findings") || { printf '%s' "$review_json"; return 0; }
  raw=$(review_call_model exec-verify "$provider" "$prompt" "$model" "$project_dir" "$add_dirs" "$turns" "$sys" 2>/dev/null) || raw=""

  claims=$(printf '%s' "$raw" | sed -n '/\[/,$p' \
    | sed '/^[[:space:]]*```[[:alpha:]]*[[:space:]]*$/d' \
    | jq -cs '
    if length == 1 and (.[0] | type) == "array" then .[0] else error("expected one JSON array") end
  ' 2>/dev/null) || claims=""
  [[ -n "$claims" ]] || { printf '%s' "$review_json"; return 0; }
  claims=$(printf '%s' "$claims" | jq -c --argjson count "$n" '
    if type == "array"
      and all(.[];
        type == "object"
        and (.index | type == "number" and floor == . and . >= 0 and . < $count)
        and (.language == "ruby" or .language == "node")
        and (
          (((has("claimed_outcome")) and (.claimed_outcome | type == "string" and length > 0 and (index("\n") == null)))
            and (has("finding_holds_if") | not))
          or
          (((has("claimed_outcome") | not) and (.finding_holds_if | type == "string" and length > 0 and (index("\n") == null))))
        )
        and (
          ((has("snippet") and (has("expression") | not))
            and ((keys - ["claimed_outcome", "finding_holds_if"]) == ["index", "language", "snippet"]))
          or
          (has("expression")
            and ((keys - ["setup", "claimed_outcome", "finding_holds_if"]) == ["expression", "index", "language"])
            and (.expression | type == "string" and length > 0)
            and ((has("setup") | not) or (.setup | type == "string")))
        )
      )
      and ([.[].index] | length == (unique | length))
    then . else error("invalid claim array") end
  ' 2>/dev/null) || claims=""
  [[ -n "$claims" ]] || { printf '%s' "$review_json"; return 0; }

  docker_bin=$(command -v docker 2>/dev/null) || { printf '%s' "$review_json"; return 0; }

  local -a dropped_indices=()
  local claim index language setup expression claimed normalized_claimed version image runtime output_file program observed normalized_observed rc container_name outcome
  while IFS= read -r claim; do
    index=$(printf '%s' "$claim" | jq -r '.index') || continue
    language=$(printf '%s' "$claim" | jq -r '.language') || continue
    if printf '%s' "$claim" | jq -e 'has("snippet") and (has("expression") | not)' >/dev/null 2>&1; then
      continue
    fi
    setup=$(printf '%s' "$claim" | jq -r '.setup // ""') || continue
    expression=$(printf '%s' "$claim" | jq -r '.expression') || continue
    claimed=$(printf '%s' "$claim" | jq -r '.claimed_outcome // .finding_holds_if') || continue
    version=""
    if [[ "$language" == "ruby" ]]; then
      if declare -F stack_versions_ruby >/dev/null 2>&1; then
        version=$(stack_versions_ruby "$project_dir") || version=""
      fi
      # .ruby-version may say "ruby-2.5.7"; Gemfile.lock says "2.5.8p206".
      version=${version#ruby-}
      [[ "$version" =~ ^([0-9]+(\.[0-9]+){1,2})p[0-9]+$ ]] && version=${BASH_REMATCH[1]}
      [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || continue
      image="ruby:$version-slim"
      runtime=ruby
    else
      if declare -F stack_versions_node >/dev/null 2>&1; then
        version=$(stack_versions_node "$project_dir") || version=""
      fi
      [[ "$version" =~ ([0-9]+) ]] || continue
      version=${BASH_REMATCH[1]}
      image="node:$version-slim"
      runtime=node
    fi

    if _review_exec_verify_docker_call "$docker_bin" image inspect "$image" >/dev/null 2>&1; then
      :
    else
      rc=$?
      if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 143 ]]; then continue; fi
      printf 'exec verification skipped finding index=%s: image unavailable; run docker pull %s\n' "$index" "$image" >&2
      continue
    fi

    output_file=$(mktemp "${TMPDIR:-/tmp}/mra-review-exec-verify.XXXXXX") || continue
    container_name="mra-exec-verify-$$-${RANDOM}-${RANDOM}"
    program=$(_review_exec_verify_program "$language" "$setup" "$expression") || { rm -f "$output_file" || true; continue; }
    observed=""
    outcome=kept
    if _review_exec_verify_docker_run "$docker_bin" "$image" "$runtime" "$program" "$output_file" "$container_name"; then
      rc=0
    else
      rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then
      observed=$(tail -n 1 "$output_file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || observed=""
      normalized_claimed=$(_review_exec_verify_normalize_line "$claimed") || normalized_claimed=""
      normalized_observed=$(_review_exec_verify_normalize_line "$observed") || normalized_observed=""
      if [[ "$normalized_observed" != "$normalized_claimed" && ( "$normalized_observed" == "RAISES "* || "$normalized_observed" == "RETURNS "* ) && ( "$normalized_claimed" == "RAISES "* || "$normalized_claimed" == "RETURNS "* ) ]]; then
        dropped_indices+=("$index")
        outcome=dropped
      fi
    fi
    printf 'exec verification index=%s image=%s claimed=%q observed=%q exit=%s outcome=%s\n' "$index" "$image" "$claimed" "$observed" "$rc" "$outcome" >&2
    rm -f "$output_file" || true
  done < <(printf '%s\n' "$claims" | jq -c '.[]')

  if [[ ${#dropped_indices[@]} -eq 0 ]]; then
    printf '%s' "$review_json"
    return 0
  fi

  local drop_json filtered
  drop_json=$(printf '%s\n' "${dropped_indices[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)') || {
    printf '%s' "$review_json"; return 0;
  }
  filtered=$(printf '%s' "$review_json" | jq -c --argjson drop "$drop_json" '
    .comments = [ .comments | to_entries[] | select(.key as $i | ($drop | index($i)) | not) | .value ]
  ' 2>/dev/null) || { printf '%s' "$review_json"; return 0; }

  printf '%s' "$filtered"
}
