#!/usr/bin/env bash
# Scanner: gateway-routes
# Scans API gateway projects for route configurations proxying to other services

set -uo pipefail

WORKSPACE="${1:-}"
if [[ -z "$WORKSPACE" ]]; then
  echo "usage: gateway-routes.sh <workspace>" >&2
  exit 1
fi

# Known gateway project patterns
GATEWAY_PATTERNS=("*gateway*" "*proxy*" "*router*")

# Service name to port map built from known workspace conventions
# These come from docker-compose or env patterns
declare -A PORT_TO_SERVICE
PORT_TO_SERVICE["4000"]="erp"
PORT_TO_SERVICE["4001"]="masa"
PORT_TO_SERVICE["4500"]="api-gateway"
PORT_TO_SERVICE["5000"]="moai"
PORT_TO_SERVICE["3100"]="finance-system"
PORT_TO_SERVICE["5173"]="odm-ui"
PORT_TO_SERVICE["3030"]="oss-ui-v2"
PORT_TO_SERVICE["9443"]="partner-api-gateway"

# Get list of known project names from workspace
known_projects=()
for d in "$WORKSPACE"/*/; do
  [[ -d "$d" ]] && known_projects+=("$(basename "$d")")
done

is_gateway() {
  local project="$1"
  for pattern in "${GATEWAY_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$project" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# Scan gateway projects
for project_dir in "$WORKSPACE"/*/; do
  [[ ! -d "$project_dir" ]] && continue
  project=$(basename "$project_dir")
  [[ "$project" == .* ]] && continue

  if ! is_gateway "$project"; then
    continue
  fi

  # Scan env.example for *_HOST and *_URL variables pointing to other services
  find "$project_dir" -maxdepth 2 \( -name "env.example" -o -name ".env.example" -o -name ".env" \) \
    -not -path "*/.git/*" 2>/dev/null | while read -r env_file; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      # Match VAR=value patterns where value contains a host/URL
      if [[ "$line" =~ ^([A-Z_]+_(HOST|URL|BASE_URL|API_URL))[[:space:]]*=[[:space:]]*[\"\']*(.+)[\"\']*$ ]]; then
        var_name="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[3]}"
        value="${value//\"/}"
        value="${value//\'/}"

        # Try to extract port from URL
        if [[ "$value" =~ :([0-9]{4,5}) ]]; then
          port="${BASH_REMATCH[1]}"
          if [[ -v PORT_TO_SERVICE[$port] ]]; then
            target="${PORT_TO_SERVICE[$port]}"
            if [[ "$target" != "$project" ]]; then
              printf '{"source": "%s", "target": "%s", "type": "api", "confidence": "medium", "scanner": "gateway-routes"}\n' \
                "$project" "$target"
            fi
          fi
        fi

        # Try to match variable prefix to known project names
        # e.g. ERP_BASE_URL -> erp, MASA_URL -> masa
        for known in "${known_projects[@]}"; do
          known_upper="${known^^}"
          known_upper="${known_upper//-/_}"
          if [[ "$var_name" == "${known_upper}_"* || "$var_name" == "${known_upper}HOST" || "$var_name" == "${known_upper}URL" ]]; then
            if [[ "$known" != "$project" ]]; then
              printf '{"source": "%s", "target": "%s", "type": "api", "confidence": "medium", "scanner": "gateway-routes"}\n' \
                "$project" "$known"
            fi
          fi
        done
      fi
    done < "$env_file"
  done

  # Scan nginx.conf for proxy_pass directives
  find "$project_dir" -maxdepth 4 -name "nginx*.conf" -not -path "*/.git/*" 2>/dev/null | while read -r nginx_file; do
    while IFS= read -r line; do
      if [[ "$line" =~ proxy_pass[[:space:]]+http://([a-zA-Z0-9_-]+):([0-9]+) ]]; then
        upstream_host="${BASH_REMATCH[1]}"
        upstream_port="${BASH_REMATCH[2]}"

        # Match by port
        if [[ -v PORT_TO_SERVICE[$upstream_port] ]]; then
          target="${PORT_TO_SERVICE[$upstream_port]}"
          if [[ "$target" != "$project" ]]; then
            printf '{"source": "%s", "target": "%s", "type": "api", "confidence": "medium", "scanner": "gateway-routes"}\n' \
              "$project" "$target"
          fi
        fi

        # Match by hostname to known projects
        for known in "${known_projects[@]}"; do
          if [[ "$upstream_host" == "$known" || "$upstream_host" == "${known}-service" ]]; then
            if [[ "$known" != "$project" ]]; then
              printf '{"source": "%s", "target": "%s", "type": "api", "confidence": "medium", "scanner": "gateway-routes"}\n' \
                "$project" "$known"
            fi
          fi
        done
      fi
    done < "$nginx_file"
  done

  # Scan apisix config files
  find "$project_dir" -maxdepth 4 \( -name "apisix*.yml" -o -name "apisix*.yaml" -o -name "routes*.yml" \) \
    -not -path "*/.git/*" 2>/dev/null | while read -r apisix_file; do
    while IFS= read -r line; do
      if [[ "$line" =~ upstream.*:[[:space:]]*http://([a-zA-Z0-9_-]+):([0-9]+) ]]; then
        upstream_host="${BASH_REMATCH[1]}"
        upstream_port="${BASH_REMATCH[2]}"
        if [[ -v PORT_TO_SERVICE[$upstream_port] ]]; then
          target="${PORT_TO_SERVICE[$upstream_port]}"
          if [[ "$target" != "$project" ]]; then
            printf '{"source": "%s", "target": "%s", "type": "api", "confidence": "medium", "scanner": "gateway-routes"}\n' \
              "$project" "$target"
          fi
        fi
      fi
    done < "$apisix_file"
  done

done
