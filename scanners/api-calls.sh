#!/usr/bin/env bash
# Scanner: api-calls (low confidence)
# Scans .env* files for *_HOST, *_URL, *_API_URL variables and maps them to known services

set -uo pipefail

WORKSPACE="${1:-}"
if [[ -z "$WORKSPACE" ]]; then
  echo "usage: api-calls.sh <workspace>" >&2
  exit 1
fi

# Known port -> service mappings (from docker-compose conventions)
declare -A PORT_TO_SERVICE
PORT_TO_SERVICE["4000"]="erp"
PORT_TO_SERVICE["4001"]="masa"
PORT_TO_SERVICE["4500"]="api-gateway"
PORT_TO_SERVICE["5000"]="moai"
PORT_TO_SERVICE["3100"]="finance-system"
PORT_TO_SERVICE["5173"]="odm-ui"
PORT_TO_SERVICE["3030"]="oss-ui-v2"
PORT_TO_SERVICE["9443"]="partner-api-gateway"

# Known hostname -> service mappings (service name patterns)
declare -A HOST_TO_SERVICE
HOST_TO_SERVICE["erp"]="erp"
HOST_TO_SERVICE["masa"]="masa"
HOST_TO_SERVICE["moai"]="moai"
HOST_TO_SERVICE["api-gateway"]="api-gateway"
HOST_TO_SERVICE["api_gateway"]="api-gateway"
HOST_TO_SERVICE["finance-system"]="finance-system"
HOST_TO_SERVICE["finance_system"]="finance-system"
HOST_TO_SERVICE["odm-ui"]="odm-ui"

# Get known project names
known_projects=()
for d in "$WORKSPACE"/*/; do
  [[ -d "$d" ]] && known_projects+=("$(basename "$d")")
done

for project_dir in "$WORKSPACE"/*/; do
  [[ ! -d "$project_dir" ]] && continue
  project=$(basename "$project_dir")
  [[ "$project" == .* ]] && continue

  find "$project_dir" -maxdepth 2 \( -name ".env*" -o -name "env.example" \) \
    -not -path "*/.git/*" 2>/dev/null | while read -r env_file; do
    while IFS= read -r line; do
      # Skip comments
      [[ "$line" =~ ^[[:space:]]*# ]] && continue

      # Match variables ending in _HOST, _URL, _API_URL
      if [[ "$line" =~ ^([A-Z_]+(HOST|URL|API_URL))[[:space:]]*=[[:space:]]*[\"\']*([^\"\'[:space:]]+) ]]; then
        var_name="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[3]}"

        # Skip self-references and infrastructure (redis, mysql, fluent, etc.)
        [[ "$value" =~ redis|mysql|postgres|fluent|localhost|127\.0\.0\.1 ]] && continue
        [[ "$value" =~ ^https?://accounts\. ]] && continue  # keycloak/auth

        target=""

        # Try to extract port from URL value
        if [[ "$value" =~ :([0-9]{4,5}) ]]; then
          port="${BASH_REMATCH[1]}"
          if [[ -v PORT_TO_SERVICE[$port] ]]; then
            target="${PORT_TO_SERVICE[$port]}"
          fi
        fi

        # If no port match, try hostname match
        if [[ -z "$target" ]]; then
          for known_host in "${!HOST_TO_SERVICE[@]}"; do
            if [[ "$value" =~ $known_host ]]; then
              target="${HOST_TO_SERVICE[$known_host]}"
              break
            fi
          done
        fi

        # Try to infer from variable name prefix (e.g. MOAI_HOST -> moai)
        if [[ -z "$target" ]]; then
          for known in "${known_projects[@]}"; do
            known_upper="${known^^}"
            known_upper="${known_upper//-/_}"
            if [[ "$var_name" == "${known_upper}_HOST" || "$var_name" == "${known_upper}_URL" || \
                  "$var_name" == "${known_upper}_API_URL" || "$var_name" == "${known_upper}_BASE_URL" ]]; then
              target="$known"
              break
            fi
          done
        fi

        # Emit if we found a target and it's not self
        if [[ -n "$target" && "$target" != "$project" ]]; then
          printf '{"source": "%s", "target": "%s", "type": "api", "confidence": "low", "scanner": "api-calls"}\n' \
            "$project" "$target"
        fi
      fi
    done < "$env_file"
  done
done
