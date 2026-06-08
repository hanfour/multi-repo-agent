#!/usr/bin/env bash
# Scanner: shared-db
# Finds projects that share a database name, emitting a shared infra dependency

set -uo pipefail

WORKSPACE="${1:-}"
if [[ -z "$WORKSPACE" ]]; then
  echo "usage: shared-db.sh <workspace>" >&2
  exit 1
fi

PAIRS_FILE=$(mktemp)

for project_dir in "$WORKSPACE"/*/; do
  [[ ! -d "$project_dir" ]] && continue
  project=$(basename "$project_dir")

  # Skip hidden and infrastructure-only dirs
  [[ "$project" == .* ]] && continue
  [[ "$project" == "ito-dev-env-setup" ]] && continue

  # Rails: config/database*.yml - look for "database:" values
  while IFS= read -r db_file; do
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*database:[[:space:]]*([a-zA-Z0-9_][a-zA-Z0-9_-]*)[[:space:]]*$ ]]; then
        db_name="${BASH_REMATCH[1]}"
        # Skip template placeholders and test databases
        [[ "$db_name" == *"test"* ]] && continue
        [[ "$db_name" == *"ci"* ]] && continue
        echo "$project $db_name" >> "$PAIRS_FILE"
      fi
    done < "$db_file"
  done < <(find "$project_dir" -maxdepth 3 -name "database*.yml" -not -path "*/.git/*" 2>/dev/null)

  # Node/Rails: .env*, env.example - look for DB_NAME, DATABASE_NAME, MYSQL_DATABASE, POSTGRES_DB
  while IFS= read -r env_file; do
    while IFS= read -r line; do
      # Skip comments
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      # Match DB_NAME=value, DATABASE_NAME=value, MYSQL_DATABASE=value, POSTGRES_DB=value
      if [[ "$line" =~ ^(DB_NAME|DATABASE_NAME|MYSQL_DATABASE|POSTGRES_DB)[[:space:]]*=[[:space:]]*[\"\']*([a-zA-Z0-9_][a-zA-Z0-9_-]*) ]]; then
        db_name="${BASH_REMATCH[2]}"
        [[ -z "$db_name" ]] && continue
        [[ "$db_name" == *"test"* ]] && continue
        echo "$project $db_name" >> "$PAIRS_FILE"
      fi
    done < "$env_file"
  done < <(find "$project_dir" -maxdepth 2 \( -name ".env*" -o -name "env.example" \) -not -path "*/.git/*" 2>/dev/null)

done

# Sort and deduplicate pairs
sort -u -o "$PAIRS_FILE" "$PAIRS_FILE"

# Build db_name -> projects mapping using a temp file per db
DB_DIR=$(mktemp -d)

while IFS=' ' read -r project db_name; do
  [[ -z "$project" || -z "$db_name" ]] && continue
  echo "$project" >> "$DB_DIR/$db_name"
done < "$PAIRS_FILE"

# Emit relationships for shared databases
for db_file in "$DB_DIR"/*; do
  [[ ! -f "$db_file" ]] && continue
  db_name=$(basename "$db_file")

  # Get unique project list
  mapfile -t projects < <(sort -u "$db_file")
  count="${#projects[@]}"

  if [[ "$count" -lt 2 ]]; then
    continue
  fi

  # Each project that shares this db gets an infra -> mysql/postgres dependency
  for proj in "${projects[@]}"; do
    printf '{"source": "%s", "target": "mysql", "type": "infra", "confidence": "high", "scanner": "shared-db"}\n' \
      "$proj"
  done
done

rm -f "$PAIRS_FILE"
rm -rf "$DB_DIR"
