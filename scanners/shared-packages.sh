#!/usr/bin/env bash
# Scanner: shared-packages
# Finds projects that share internal packages via Gemfile or package.json

set -uo pipefail

WORKSPACE="${1:-}"
if [[ -z "$WORKSPACE" ]]; then
  echo "usage: shared-packages.sh <workspace>" >&2
  exit 1
fi

# Get known project names
known_projects=()
for d in "$WORKSPACE"/*/; do
  [[ -d "$d" ]] && known_projects+=("$(basename "$d")")
done

for project_dir in "$WORKSPACE"/*/; do
  [[ ! -d "$project_dir" ]] && continue
  project=$(basename "$project_dir")
  [[ "$project" == .* ]] && continue

  # Ruby: scan Gemfile for internal gems
  gemfile="$project_dir/Gemfile"
  if [[ -f "$gemfile" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue

      # Look for gem references matching other project names
      for known in "${known_projects[@]}"; do
        if [[ "$known" == "$project" ]]; then continue; fi
        known_gem="${known//_/-}"  # normalize: underscores -> hyphens
        if [[ "$line" =~ gem[[:space:]]+[\"\'](${known_gem}|${known})[\"\'](,|[[:space:]]|$) ]]; then
          printf '{"source": "%s", "target": "%s", "type": "package", "confidence": "high", "scanner": "shared-packages"}\n' \
            "$project" "$known"
        fi
      done

      # Look for git/github source gems pointing to internal org
      if [[ "$line" =~ gem[[:space:]]+[\"\']([a-zA-Z0-9_-]+)[\"\'].*git.*onead ]]; then
        gem_name="${BASH_REMATCH[1]}"
        # Try to map gem name to known project
        for known in "${known_projects[@]}"; do
          if [[ "$known" == "$project" ]]; then continue; fi
          known_gem="${known//-/_}"
          gem_normalized="${gem_name//-/_}"
          if [[ "$gem_normalized" == "$known_gem" || "$gem_name" == "$known" ]]; then
            printf '{"source": "%s", "target": "%s", "type": "package", "confidence": "high", "scanner": "shared-packages"}\n' \
              "$project" "$known"
          fi
        done
      fi
    done < "$gemfile"
  fi

  # Node: scan package.json for @onead/ packages or workspace project names
  package_json="$project_dir/package.json"
  if [[ -f "$package_json" ]]; then
    # Extract dependency names matching @onead/* or workspace project names
    while IFS= read -r dep_name; do
      [[ -z "$dep_name" ]] && continue

      # @onead/ scoped packages
      if [[ "$dep_name" =~ ^@onead/(.+)$ ]]; then
        pkg_name="${BASH_REMATCH[1]}"
        # Try to match to a known project
        for known in "${known_projects[@]}"; do
          if [[ "$known" == "$project" ]]; then continue; fi
          known_normalized="${known//-/_}"
          pkg_normalized="${pkg_name//-/_}"
          if [[ "$pkg_normalized" == "$known_normalized" || "$pkg_name" == "$known" ]]; then
            printf '{"source": "%s", "target": "%s", "type": "package", "confidence": "high", "scanner": "shared-packages"}\n' \
              "$project" "$known"
          fi
        done
        # Even without project match, emit the package reference
        printf '{"source": "%s", "target": "%s", "type": "package", "confidence": "high", "scanner": "shared-packages"}\n' \
          "$project" "$dep_name"
        continue
      fi

      # Direct project name match in dependencies
      for known in "${known_projects[@]}"; do
        if [[ "$known" == "$project" ]]; then continue; fi
        if [[ "$dep_name" == "$known" ]]; then
          printf '{"source": "%s", "target": "%s", "type": "package", "confidence": "high", "scanner": "shared-packages"}\n' \
            "$project" "$known"
        fi
      done

    done < <(python3 -c "
import json, sys
try:
    d = json.load(open('$package_json'))
    deps = {}
    deps.update(d.get('dependencies', {}))
    deps.update(d.get('devDependencies', {}))
    deps.update(d.get('peerDependencies', {}))
    # Also check workspaces
    ws = d.get('workspaces', [])
    if isinstance(ws, dict):
        ws = ws.get('packages', [])
    for k in list(deps.keys()) + ws:
        print(k)
except Exception as e:
    pass
" 2>/dev/null)
  fi
done
