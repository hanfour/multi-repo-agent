#!/usr/bin/env bash
# Scanner: docker-compose
# Scans docker-compose*.yml files for service dependencies via depends_on

set -uo pipefail

WORKSPACE="${1:-}"
if [[ -z "$WORKSPACE" ]]; then
  echo "usage: docker-compose.sh <workspace>" >&2
  exit 1
fi

# Find all docker-compose files
find "$WORKSPACE" -maxdepth 3 -name "docker-compose*.yml" -not -path "*/.git/*" 2>/dev/null | while read -r compose_file; do
  dir=$(dirname "$compose_file")

  # Parse services and their depends_on relationships
  # Track current service name
  current_service=""
  in_depends=false

  while IFS= read -r line; do
    # Detect top-level service definition (2 spaces, name, colon, not a comment)
    if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
      current_service="${BASH_REMATCH[1]}"
      # Skip known non-service keys
      if [[ "$current_service" == "volumes" || "$current_service" == "networks" || "$current_service" == "configs" || "$current_service" == "secrets" ]]; then
        current_service=""
      fi
      in_depends=false
      continue
    fi

    # Skip lines that start with '#' (comments)
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Detect depends_on block
    if [[ -n "$current_service" && "$line" =~ ^[[:space:]]{4}depends_on: ]]; then
      in_depends=true
      continue
    fi

    # Exit depends_on block when we hit a new 4-space key
    if [[ "$in_depends" == "true" && "$line" =~ ^[[:space:]]{4}[a-zA-Z] ]]; then
      in_depends=false
    fi

    # Parse depends_on entries (list form: "      - service_name")
    if [[ "$in_depends" == "true" && "$line" =~ ^[[:space:]]{6}-[[:space:]]*([a-zA-Z0-9_-]+) ]]; then
      dep="${BASH_REMATCH[1]}"
      if [[ -n "$current_service" && "$current_service" != "$dep" ]]; then
        printf '{"source": "%s", "target": "%s", "type": "infra", "confidence": "high", "scanner": "docker-compose"}\n' \
          "$current_service" "$dep"
      fi
    fi

    # Parse depends_on entries (map form: "      service_name:")
    if [[ "$in_depends" == "true" && "$line" =~ ^[[:space:]]{6}([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
      dep="${BASH_REMATCH[1]}"
      if [[ -n "$current_service" && "$current_service" != "$dep" && "$dep" != "condition" ]]; then
        printf '{"source": "%s", "target": "%s", "type": "infra", "confidence": "high", "scanner": "docker-compose"}\n' \
          "$current_service" "$dep"
      fi
    fi

  done < "$compose_file"
done
