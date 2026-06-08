#!/usr/bin/env bash
# validate.sh — runtime structural validation for .collab/*.json files.
#
# Schemas live in schemas/*.schema.json (JSON Schema draft-07) and document the
# canonical shape. The shell checks here are deliberately light (required keys
# + type sanity) so they can run with only `jq` available. For exhaustive
# validation use ajv-cli with the bundled schemas, e.g.:
#   npx -y ajv-cli@5 validate -s schemas/dep-graph.schema.json -d .collab/dep-graph.json
#
# Identifier rules (TM-003):
#   - Generic identifiers (project, repo, db names, manual-deps endpoints)
#     must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. This rejects path
#     separators, `..`, leading dot/dash, whitespace, and absurdly long
#     keys. It matches the regex used by lib/project-path.sh and the MCP
#     tool schemas, so all three layers agree on what a "project name" is.
#   - DB schema names go to SQL `CREATE SCHEMA` / `USE` statements and
#     must use the stricter SQL-identifier regex
#     `^[A-Za-z_][A-Za-z0-9_]{0,62}$`. Same rationale as the project
#     identifier but with no `.` or `-` because those would break SQL.
_MRA_ID_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
_MRA_SQL_ID_REGEX='^[A-Za-z_][A-Za-z0-9_]{0,62}$'

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
  # TM-003: identifier regex on project keys + all cross-project references.
  if ! jq -e --arg re "$_MRA_ID_REGEX" '
    (.projects | keys | all(test($re)))
    and ([.projects[]?.consumedBy[]?] | all(test($re)))
    and ([.projects[]?.deps | values[]? | .[]?] | all(test($re)))
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "dep-graph contains identifier(s) outside $_MRA_ID_REGEX"
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
  # TM-003: repo names flow into `git clone "$GIT_ORG/$name.git"` and into
  # `$workspace/$name` paths; enforce the identifier regex.
  if ! jq -e --arg re "$_MRA_ID_REGEX" '
    [.repos[]?.name] | all(test($re))
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "repos.json has name(s) outside $_MRA_ID_REGEX"
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
  # TM-003: db container names use generic identifier; schema names are
  # interpolated into SQL CREATE/USE statements and must satisfy the
  # stricter SQL-identifier regex.
  if ! jq -e --arg re "$_MRA_ID_REGEX" '
    .databases | keys | all(test($re))
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "db.json has database name(s) outside $_MRA_ID_REGEX"
    return 1
  fi
  if ! jq -e --arg re "$_MRA_SQL_ID_REGEX" '
    [.databases[]?.schemas | keys[]?] | all(test($re))
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "db.json has schema name(s) outside $_MRA_SQL_ID_REGEX (SQL identifier required)"
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
  # TM-003: source/target are project identifiers; same regex as dep-graph.
  if ! jq -e --arg re "$_MRA_ID_REGEX" '
    all((.source | test($re)) and (.target | test($re)))
  ' "$file" >/dev/null 2>&1; then
    _validate_log error "$file" "manual-deps has source/target outside $_MRA_ID_REGEX"
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
