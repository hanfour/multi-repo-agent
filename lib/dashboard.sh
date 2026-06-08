#!/usr/bin/env bash
# Terminal UI Dashboard

# ANSI helpers
_cursor_home() { printf '\033[H'; }
_clear_screen() { printf '\033[2J'; }
_hide_cursor() { printf '\033[?25l'; }
_show_cursor() { printf '\033[?25h'; }
_move_to() { printf '\033[%d;%dH' "$1" "$2"; }
_bold() { printf '\033[1m%s\033[0m' "$1"; }
_dim() { printf '\033[2m%s\033[0m' "$1"; }
_green() { printf '\033[0;32m%s\033[0m' "$1"; }
_red() { printf '\033[0;31m%s\033[0m' "$1"; }
_yellow() { printf '\033[0;33m%s\033[0m' "$1"; }
_cyan() { printf '\033[0;36m%s\033[0m' "$1"; }

# Get terminal dimensions
_term_width() { tput cols 2>/dev/null || echo 80; }
_term_height() { tput lines 2>/dev/null || echo 24; }

# Draw a horizontal line
_hline() {
  local width="$1" char="${2:-─}"
  printf '%*s' "$width" '' | tr ' ' "$char"
}

# Truncate string to max length
_truncate() {
  local str="$1" max="$2"
  if [[ ${#str} -gt $max ]]; then
    echo "${str:0:$((max-3))}..."
  else
    echo "$str"
  fi
}

# Render the dashboard
render_dashboard() {
  local workspace="$1"
  local graph_file="$workspace/.collab/dep-graph.json"
  local db_json="$workspace/.collab/db.json"
  local snapshots_file="$workspace/.collab/snapshots/snapshots.json"
  local width; width=$(_term_width)
  local half=$((width / 2 - 2))

  _clear_screen
  _cursor_home

  # Header
  local workspace_name
  workspace_name=$(jq -r '.workspace // "unknown"' "$graph_file" 2>/dev/null)
  local now; now=$(date '+%Y-%m-%d %H:%M')
  local title="MRA Dashboard — $workspace_name"
  local padding=$((width - ${#title} - ${#now} - 6))
  printf '  %s%*s%s\n' "$(_bold "$title")" "$padding" "" "$(_dim "$now")"
  printf '  %s\n' "$(_hline $((width - 4)))"
  echo ""

  # Two-column layout
  local left_col=$((half - 1))

  # === LEFT: Projects ===
  local project_lines=()
  local project_count=0
  if [[ -f "$graph_file" ]]; then
    while IFS= read -r project; do
      [[ -z "$project" ]] && continue
      project_count=$((project_count + 1))
      local pdir="$workspace/$project"
      local ptype; ptype=$(jq -r --arg p "$project" '.projects[$p].type // "?"' "$graph_file")
      ptype=$(_truncate "$ptype" 12)

      local branch="n/a" status_str=""
      if [[ -d "$pdir/.git" ]]; then
        branch=$(git -C "$pdir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        branch=$(_truncate "$branch" 12)
        local changes; changes=$(git -C "$pdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$changes" -gt 0 ]]; then
          status_str=$(_yellow "${changes}m")
        else
          status_str=$(_green "ok")
        fi
      else
        status_str=$(_red "missing")
      fi

      project_lines+=("$(printf '  %-16s %-12s %-12s %s' "$(_truncate "$project" 15)" "$ptype" "$branch" "$status_str")")
    done < <(jq -r '.projects | keys[]' "$graph_file" 2>/dev/null)
  fi

  # === RIGHT: Dependency Graph ===
  local dep_lines=()
  if [[ -f "$graph_file" ]]; then
    while IFS= read -r project; do
      [[ -z "$project" ]] && continue
      # Non-infra deps
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        dep_lines+=("  $project --> $dep")
      done < <(jq -r --arg p "$project" '(.projects[$p].deps // {}) | to_entries[] | select(.key != "infra") | .value[]' "$graph_file" 2>/dev/null)
      # Infra deps
      local infra; infra=$(jq -r --arg p "$project" '(.projects[$p].deps.infra // []) | join(", ")' "$graph_file" 2>/dev/null)
      [[ -n "$infra" && "$infra" != "" ]] && dep_lines+=("  $(_dim "$project -.> $infra")")
    done < <(jq -r '.projects | keys[]' "$graph_file" 2>/dev/null)
  fi

  # Print PROJECTS header + DEPENDENCY GRAPH header
  printf '  %-*s  %s\n' "$left_col" "$(_bold "PROJECTS ($project_count)")" "$(_bold "DEPENDENCY GRAPH")"
  printf '  %-*s  %s\n' "$left_col" "$(_hline 24)" "$(_hline 24)"

  # Print rows side by side
  local max_rows=${#project_lines[@]}
  [[ ${#dep_lines[@]} -gt $max_rows ]] && max_rows=${#dep_lines[@]}
  [[ $max_rows -gt 15 ]] && max_rows=15  # cap at 15 rows

  for ((i=0; i<max_rows; i++)); do
    local left="${project_lines[$i]:-}"
    local right="${dep_lines[$i]:-}"
    # Strip ANSI for length calculation, pad accordingly
    local left_plain; left_plain=$(printf '%s' "$left" | sed 's/\x1b\[[0-9;]*m//g')
    local left_pad=$((left_col - ${#left_plain}))
    [[ $left_pad -lt 0 ]] && left_pad=0
    printf '%s%*s  %s\n' "$left" "$left_pad" "" "$right"
  done

  echo ""

  # === Bottom: DB + Health + Snapshots + Changes ===
  printf '  %-*s  %s\n' "$left_col" "$(_bold "DATABASES")" "$(_bold "RECENT CHANGES")"
  printf '  %-*s  %s\n' "$left_col" "$(_hline 16)" "$(_hline 16)"

  # DB info
  local db_lines=()
  if [[ -f "$db_json" ]]; then
    while IFS= read -r db_name; do
      [[ -z "$db_name" ]] && continue
      local engine; engine=$(jq -r --arg n "$db_name" '.databases[$n].engine // "?"' "$db_json")
      local version; version=$(jq -r --arg n "$db_name" '.databases[$n].version // "?"' "$db_json")
      local container_name="mra-db-$db_name"
      local db_status
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        db_status=$(_green "RUNNING")
      else
        db_status=$(_red "STOPPED")
      fi
      db_lines+=("  $db_name ($engine:$version): $db_status")

      # Schemas
      local has_schemas; has_schemas=$(jq -r --arg n "$db_name" '.databases[$n] | has("schemas")' "$db_json")
      if [[ "$has_schemas" == "true" ]]; then
        while IFS= read -r schema; do
          [[ -z "$schema" ]] && continue
          local tcount
          tcount=$(docker exec "$container_name" mysql -uroot -p"$(jq -r --arg n "$db_name" '.databases[$n].password // "mra_password"' "$db_json")" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$schema'" 2>/dev/null | tr -d ' ' || echo "?")
          db_lines+=("    $schema: $tcount tables")
        done < <(jq -r --arg n "$db_name" '.databases[$n].schemas | keys[]' "$db_json" 2>/dev/null)
      fi
    done < <(jq -r '.databases | keys[]' "$db_json")
  else
    db_lines+=("  (no db.json)")
  fi

  # Changes
  local change_lines=()
  if [[ -f "$graph_file" ]]; then
    while IFS= read -r project; do
      [[ -z "$project" ]] && continue
      local pdir="$workspace/$project"
      [[ ! -d "$pdir/.git" ]] && continue
      local changes; changes=$(git -C "$pdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      [[ "$changes" -eq 0 ]] && continue
      change_lines+=("  $(_yellow "$project"): $changes file(s)")
    done < <(jq -r '.projects | keys[]' "$graph_file" 2>/dev/null)
  fi
  [[ ${#change_lines[@]} -eq 0 ]] && change_lines+=("  $(_green "all clean")")

  # Print DB + Changes side by side
  local bottom_max=${#db_lines[@]}
  [[ ${#change_lines[@]} -gt $bottom_max ]] && bottom_max=${#change_lines[@]}
  [[ $bottom_max -gt 8 ]] && bottom_max=8

  for ((i=0; i<bottom_max; i++)); do
    local left="${db_lines[$i]:-}"
    local right="${change_lines[$i]:-}"
    local left_plain; left_plain=$(printf '%s' "$left" | sed 's/\x1b\[[0-9;]*m//g')
    local left_pad=$((left_col - ${#left_plain}))
    [[ $left_pad -lt 0 ]] && left_pad=0
    printf '%s%*s  %s\n' "$left" "$left_pad" "" "$right"
  done

  echo ""

  # Snapshots line
  if [[ -f "$snapshots_file" ]]; then
    local snap_count; snap_count=$(jq 'length' "$snapshots_file" 2>/dev/null || echo 0)
    local latest; latest=$(jq -r '.[-1].name // "none"' "$snapshots_file" 2>/dev/null)
    printf '  %s: %s snapshots (latest: %s)\n' "$(_bold "SNAPSHOTS")" "$snap_count" "$latest"
  fi

  echo ""
  printf '  %s\n' "$(_hline $((width - 4)))"
  printf '  %s\n' "$(_dim "[q] quit  [r] refresh  [s] scan  [d] doctor  [e] export")"
}

# Interactive dashboard loop
run_dashboard() {
  local workspace="$1"

  # Trap to restore cursor on exit
  trap '_show_cursor; _clear_screen' EXIT INT TERM

  _hide_cursor

  while true; do
    render_dashboard "$workspace"

    # Wait for keypress (1 char, no enter needed)
    local key
    read -rsn1 -t 30 key 2>/dev/null || key=""

    case "$key" in
      q|Q) break ;;
      r|R) continue ;;  # refresh (re-render)
      s|S)
        _show_cursor
        _clear_screen
        handle_scan "$workspace" 2>&1
        echo ""
        echo "Press any key to return to dashboard..."
        read -rsn1
        _hide_cursor
        ;;
      d|D)
        _show_cursor
        _clear_screen
        run_doctor "$workspace" 2>&1
        echo ""
        echo "Press any key to return to dashboard..."
        read -rsn1
        _hide_cursor
        ;;
      e|E)
        _show_cursor
        _clear_screen
        export_all_projects "$workspace" 2>&1
        echo ""
        echo "Press any key to return to dashboard..."
        read -rsn1
        _hide_cursor
        ;;
      "") continue ;;  # timeout, auto-refresh
    esac
  done

  _show_cursor
}
