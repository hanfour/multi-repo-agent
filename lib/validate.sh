#!/usr/bin/env bash
# validate.sh — runtime structural validation for .collab/*.json files.
#
# Schemas live in schemas/*.schema.json (JSON Schema draft-07) and document the
# canonical shape. The shell checks here are deliberately light (required keys
# + type sanity) so they can run with only `jq` available. For exhaustive
# validation use ajv-cli with the bundled schemas, e.g.:
#   npx -y ajv-cli@5 validate -s schemas/dep-graph.schema.json -d .collab/dep-graph.json

_validate_log() {
  local level="$1" file="$2" msg="$3"
  if declare -F "log_$level" >/dev/null 2>&1; then
    "log_$level" "$file: $msg" "validate"
  else
    echo "[$level] $file: $msg" >&2
  fi
}

# validate_dep_graph_json <path>
validate_dep_graph_json() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0
  if ! jq -e '
    type == "object"
    and (.version|type) == "number"
    and (.workspace|type) == "string"
    and (.gitOrg|type) == "string"
    and (.lastScan|type) == "string"
    and (.projects|type) == "object"
    and (
      [.projects[]?] | all(
        type == "object"
        and (.deps|type) == "object"
        and (.consumedBy|type) == "array"
        and (.confidence|type) == "object"
      )
    )
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "dep-graph schema check failed"
    return 1
  fi
  return 0
}

# validate_repos_json <path>
validate_repos_json() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0
  if ! jq -e '
    type == "object"
    and (.repos|type) == "array"
    and (
      [.repos[]?] | all(
        type == "object"
        and (.name|type) == "string" and (.name|length) > 0
        and (.clone|type) == "boolean"
      )
    )
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "repos schema check failed"
    return 1
  fi
  return 0
}

# validate_db_json <path>
validate_db_json() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0
  if ! jq -e '
    type == "object"
    and (.databases|type) == "object"
    and (
      [.databases[]?] | all(
        type == "object"
        and (.engine == "mysql" or .engine == "postgres")
        and (.schemas|type) == "object"
      )
    )
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "db schema check failed"
    return 1
  fi
  return 0
}

# validate_manual_deps_json <path>
validate_manual_deps_json() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0
  if ! jq -e '
    type == "array"
    and all(
      type == "object"
      and (.source|type) == "string" and (.source|length) > 0
      and (.target|type) == "string" and (.target|length) > 0
    )
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "manual-deps schema check failed"
    return 1
  fi
  return 0
}

# validate_scanner_jsonl <jsonl-path>
validate_scanner_jsonl() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0
  local bad=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! echo "$line" | jq -e '
      type == "object"
      and (.source|type) == "string"
      and (.target|type) == "string"
      and (.type|type) == "string"
      and (.confidence == "high" or .confidence == "medium" or .confidence == "low")
      and (.scanner|type) == "string"
    ' >/dev/null 2>&1; then
      bad=$((bad + 1))
    fi
  done < "$file"
  if (( bad > 0 )); then
    _validate_log error "$file" "$bad invalid scanner record(s)"
    return 1
  fi
  return 0
}

# validate_collab_files <workspace>
validate_collab_files() {
  local workspace="$1"
  local rc=0
  validate_dep_graph_json "$workspace/.collab/dep-graph.json" || rc=1
  validate_repos_json     "$workspace/.collab/repos.json"     || rc=1
  validate_db_json        "$workspace/.collab/db.json"        || rc=1
  validate_manual_deps_json "$workspace/.collab/manual-deps.json" || rc=1
  return $rc
}
