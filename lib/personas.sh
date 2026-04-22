#!/usr/bin/env bash
# Persona loader: reads markdown prompt fragments from agents/personas/

_personas_dir() {
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "$mra_dir/agents/personas"
}

list_personas() {
  local dir; dir="$(_personas_dir)"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    local name; name="$(basename "$f" .md)"
    [[ "$name" == "README" ]] && continue
    echo "$name"
  done
}

load_persona() {
  local name="$1"
  local file; file="$(_personas_dir)/${name}.md"
  if [[ ! -f "$file" ]]; then
    echo "persona not found: $name" >&2
    return 1
  fi
  cat "$file"
}
