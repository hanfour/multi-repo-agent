#!/usr/bin/env bash
# Detect runtime and framework versions from repository metadata.

_stack_versions_trim() {
  printf '%s\n' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

_stack_versions_ruby() {
  local project_dir="$1" value lock_file="$1/Gemfile.lock"
  if [[ -f "$project_dir/.ruby-version" ]]; then
    value=$(_stack_versions_trim "$(sed -n '1p' "$project_dir/.ruby-version")")
    [[ -n "$value" ]] && printf '%s (.ruby-version)\n' "$value"
    return 0
  fi

  if [[ -f "$lock_file" ]]; then
    value=$(awk '
      $0 == "RUBY VERSION" { in_ruby = 1; next }
      in_ruby && /^[A-Z][A-Z ]*$/ { exit }
      in_ruby && /ruby[[:space:]]+/ {
        sub(/^.*ruby[[:space:]]+/, "")
        print
        exit
      }
    ' "$lock_file")
    value=$(_stack_versions_trim "$value")
    if [[ -n "$value" ]]; then
      printf '%s (Gemfile.lock)\n' "$value"
      return 0
    fi
  fi

  if [[ -f "$project_dir/Gemfile" ]]; then
    value=$(awk '
      /^[[:space:]]*ruby[[:space:]]+/ {
        sub(/^[[:space:]]*ruby[[:space:]]+/, "")
        gsub(/\047|"/, "")
        sub(/,.*/, "")
        gsub(/[[:space:]]/, "")
        print
        exit
      }
    ' "$project_dir/Gemfile")
    value=$(_stack_versions_trim "$value")
    [[ -n "$value" ]] && printf '%s (Gemfile)\n' "$value"
  fi
}

_stack_versions_gemfile_devtest() {
  local gemfile="$1"
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function has_devtest(value) {
      if (value ~ /(^|[^[:alnum:]_])(development|test)([^[:alnum:]_]|$)/) return 1
      return value !~ /(^|[^[:alnum:]_])production([^[:alnum:]_]|$)/
    }
    function push_block(devtest) {
      inherited[++depth] = active_devtest
      active_devtest = active_devtest || devtest
    }
    function pop_block() {
      if (depth > 0) {
        active_devtest = inherited[depth]
        delete inherited[depth]
        depth--
      } else {
        valid = 0
      }
    }
    # Gemfile groups other than production are not runtime dependencies.
    BEGIN { valid = 1; depth = 0; active_devtest = 0; names = "" }
    {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      line = trim(line)
      if (line == "") next

      if (line ~ /^end([[:space:]]|$)/) {
        pop_block()
        next
      }

      if (line ~ /^group([[:space:]]+|\()/) {
        if (line ~ /(^|[[:space:]])do([[:space:]]*\|[^|]*\|)?[[:space:]]*$/) {
          group_args = line
          sub(/^group[[:space:]]*/, "", group_args)
          sub(/[[:space:]]+do([[:space:]]*\|[^|]*\|)?[[:space:]]*$/, "", group_args)
          sub(/^\(/, "", group_args)
          sub(/\)$/, "", group_args)
          if (group_args == "" || group_args ~ /[^[:alnum:]_,:[:space:]\047\"]/) valid = 0
          push_block(has_devtest(group_args))
        } else valid = 0
        next
      }

      if (line ~ /^gem([^[:alnum:]_]|$)/) {
        declaration = line
        sub(/^gem[[:space:]]*/, "", declaration)
        sub(/^\(/, "", declaration)
        quote = substr(declaration, 1, 1)
        if (quote != "\047" && quote != "\"") { valid = 0; next }
        rest = substr(declaration, 2)
        quote_end = index(rest, quote)
        if (!quote_end) { valid = 0; next }
        name = substr(rest, 1, quote_end - 1)
        if (name == "" || name ~ /[^[:alnum:]_.+-]/ || substr(line, length(line), 1) == ",") {
          valid = 0
          next
        }
        options = substr(rest, quote_end + 1)
        if (active_devtest || (options ~ /group[[:space:]]*:/ && has_devtest(options))) {
          if (names != "") names = names ","
          names = names name
        }
        if (line ~ /(^|[[:space:]])do([[:space:]]*\|[^|]*\|)?[[:space:]]*$/) push_block(0)
        next
      }

      if (line ~ /(^|[[:space:]])do([[:space:]]*\|[^|]*\|)?[[:space:]]*$/ ||
          line ~ /^(if|unless|case|begin)([[:space:]]|$)/) push_block(0)
    }
    END {
      if (depth != 0) valid = 0
      if (!valid) exit 1
      printf "%s", names
    }
  ' "$gemfile"
}

# A Rails app easily has 100+ direct gems. Each line costs about ten tokens, and
# a cap that stops alphabetically at "l" hides sidekiq/devise, so the default
# lists nearly all of them.
_stack_versions_gems() {
  local lock_file="$1" gemfile="${2:-}" gemfile_devtest="" parsed_gemfile=false
  local cap="${MRA_STACK_VERSIONS_GEM_CAP:-120}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=120
  if [[ -n "$gemfile" && -f "$gemfile" ]] && gemfile_devtest=$(_stack_versions_gemfile_devtest "$gemfile"); then
    parsed_gemfile=true
  fi
  LC_ALL=C awk -v devtest_list="$gemfile_devtest" -v use_groups="$parsed_gemfile" -v cap="$cap" '
    BEGIN {
      count = split(devtest_list, group_names, ",")
      for (i = 1; i <= count; i++) if (group_names[i] != "") devtest[group_names[i]] = 1
    }
    $0 == "GEM" { in_gem = 1; in_specs = 0; next }
    in_gem && /^[A-Z][A-Z ]*$/ && $0 != "GEM" { in_gem = 0; in_specs = 0 }
    in_gem && $0 == "  specs:" { in_specs = 1; next }
    in_specs && /^    [^ ]/ {
      line = $0
      sub(/^    /, "", line)
      name = line
      sub(/[[:space:]]*\(.*/, "", name)
      version = line
      sub(/^[^(]*\(/, "", version)
      sub(/\).*/, "", version)
      if (name != "" && version != "") resolved[name] = version
    }
    $0 == "DEPENDENCIES" { in_deps = 1; in_gem = 0; in_specs = 0; next }
    in_deps && $0 !~ /^  / { in_deps = 0 }
    in_deps && /^  [^ ]/ {
      dep = $0
      sub(/^  /, "", dep)
      sub(/[[:space:](].*$/, "", dep)
      sub(/!$/, "", dep)
      if (dep != "" && !seen[dep]++) deps[++dep_count] = dep
    }
    END {
      if (use_groups == "true") {
        for (i = 2; i <= dep_count; i++) {
          value = deps[i]
          j = i - 1
          while (j >= 1 && deps[j] > value) {
            deps[j + 1] = deps[j]
            j--
          }
          deps[j + 1] = value
        }
      }
      total = 0
      for (i = 1; i <= dep_count; i++) {
        name = deps[i]
        if (name in resolved) total++
      }
      shown = 0
      if ("rails" in resolved) {
        for (i = 1; i <= dep_count; i++) {
          if (deps[i] == "rails") {
            printf "- rails %s (Gemfile.lock)\n", resolved["rails"]
            shown++
            break
          }
        }
      }
      for (i = 1; i <= dep_count && shown < cap; i++) {
        name = deps[i]
        if (name == "rails" || !(name in resolved) || (use_groups == "true" && name in devtest)) continue
        printf "- %s %s (Gemfile.lock)\n", name, resolved[name]
        shown++
      }
      for (i = 1; i <= dep_count && shown < cap; i++) {
        name = deps[i]
        if (name == "rails" || !(name in resolved) || use_groups != "true" || !(name in devtest)) continue
        printf "- %s %s (Gemfile.lock; dev/test)\n", name, resolved[name]
        shown++
      }
      if (total > shown) printf "- %d direct gems omitted\n", total - shown
    }
  ' "$lock_file"
}

_stack_versions_node() {
  local project_dir="$1" value
  local source
  for source in .nvmrc .node-version; do
    if [[ -f "$project_dir/$source" ]]; then
      value=$(_stack_versions_trim "$(sed -n '1p' "$project_dir/$source")")
      if [[ -n "$value" ]]; then
        printf '%s (%s)\n' "${value#v}" "$source"
        return 0
      fi
    fi
  done
  if [[ -f "$project_dir/package.json" ]] && command -v jq >/dev/null 2>&1; then
    value=$(jq -r '.engines.node // empty | strings' "$project_dir/package.json" 2>/dev/null || true)
    value=$(_stack_versions_trim "$value")
    [[ -n "$value" ]] && printf '%s (package.json engines)\n' "$value"
  fi
}

_stack_versions_pnpm_patterns() {
  local file="$1"
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^packages:[[:space:]]*($|#)/ { in_packages = 1; next }
    in_packages && /^[^[:space:]#]/ { exit }
    in_packages && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      value = trim(value)
      if ((substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") ||
          (substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\""))
        value = substr(value, 2, length(value) - 2)
      if (value != "") print value
    }
  ' "$file"
}

_stack_versions_package_patterns() {
  local file="$1"
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    if (.workspaces | type) == "array" then .workspaces[]
    elif (.workspaces.packages | type) == "array" then .workspaces.packages[]
    else empty end
    | strings
  ' "$file" 2>/dev/null || true
}

_stack_versions_catalog_range() {
  local file="$1" catalog_name="$2" package_name="$3"
  [[ -f "$file" ]] || return 0
  awk -v wanted_catalog="$catalog_name" -v wanted_package="$package_name" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function entry(line,    split_at, key, value) {
      split_at = index(line, ":")
      if (!split_at) return
      key = trim(substr(line, 1, split_at - 1))
      value = trim(substr(line, split_at + 1))
      sub(/[[:space:]]+#.*$/, "", value)
      value = trim(value)
      if ((substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") ||
          (substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\""))
        value = substr(value, 2, length(value) - 2)
      if (key == wanted_package && value != "") {
        print value
        found = 1
      }
    }
    /^[^[:space:]#]/ {
      if ($0 ~ /^catalog:[[:space:]]*($|#)/) { section = "default"; next }
      if ($0 ~ /^catalogs:[[:space:]]*($|#)/) { section = "named"; catalog = ""; next }
      section = ""
      next
    }
    section == "default" {
      line = $0
      spaces = length(line)
      sub(/^ */, "", line)
      spaces -= length(line)
      if (spaces == 2) entry(trim($0))
      if (found) exit
    }
    section == "named" {
      line = $0
      spaces = length(line)
      sub(/^ */, "", line)
      spaces -= length(line)
      if (spaces == 2) {
        line = trim($0)
        split_at = index(line, ":")
        catalog = split_at ? trim(substr(line, 1, split_at - 1)) : ""
        if ((substr(catalog, 1, 1) == "\047" && substr(catalog, length(catalog), 1) == "\047") ||
            (substr(catalog, 1, 1) == "\"" && substr(catalog, length(catalog), 1) == "\""))
          catalog = substr(catalog, 2, length(catalog) - 2)
      } else if (spaces == 4 && catalog == wanted_catalog) {
        entry(trim($0))
      }
      if (found) exit
    }
  ' "$file"
}

_stack_versions_pnpm_resolved() {
  local lock_file="$1" importer="$2" package_name="$3"
  awk -v wanted_importer="$importer" -v wanted_package="$package_name" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function unquote(value) {
      value = trim(value)
      if ((substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") ||
          (substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\""))
        value = substr(value, 2, length(value) - 2)
      return value
    }
    $0 == "importers:" { in_importers = 1; next }
    in_importers && /^[^[:space:]#]/ { exit }
    in_importers && /^  [^ ]/ {
      importer = $0
      sub(/^  /, "", importer)
      sub(/:[[:space:]]*$/, "", importer)
      importer = unquote(importer)
      group = ""
      active_package = 0
      next
    }
    in_importers && importer == wanted_importer && /^    (dependencies|devDependencies):/ {
      group = $1
      sub(/:$/, "", group)
      next
    }
    in_importers && importer == wanted_importer && /^    [^ ]/ { group = ""; next }
    in_importers && importer == wanted_importer && group != "" && /^      [^ ]/ {
      package = $0
      sub(/^      /, "", package)
      sub(/:[[:space:]]*$/, "", package)
      active_package = (unquote(package) == wanted_package)
      next
    }
    in_importers && importer == wanted_importer && active_package && /^        version:/ {
      version = $0
      sub(/^        version:[[:space:]]*/, "", version)
      version = unquote(version)
      sub(/\(.*/, "", version)
      print version
      exit
    }
  ' "$lock_file"
}

_stack_versions_npm_resolved() {
  local lock_file="$1" package_name="$2"
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg package "$package_name" '.packages["node_modules/" + $package].version // empty' \
    "$lock_file" 2>/dev/null || true
}

_stack_versions_yarn_resolved() {
  local lock_file="$1" package_name="$2" declared="$3"
  awk -v wanted_package="$package_name" -v wanted_range="$declared" '
    function unquote(value) {
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      return value
    }
    /^[^[:space:]#].*:[[:space:]]*$/ {
      header = $0
      sub(/:[[:space:]]*$/, "", header)
      in_match = (index(header, wanted_package "@" wanted_range) > 0)
      next
    }
    in_match && /^[[:space:]]+version[[:space:]:]/ {
      version = $0
      sub(/^[[:space:]]+version[[:space:]:]+/, "", version)
      version = unquote(version)
      print version
      exit
    }
  ' "$lock_file"
}

_stack_versions_resolved() {
  local project_dir="$1" importer="$2" package_name="$3" declared="$4" result
  if [[ -f "$project_dir/pnpm-lock.yaml" ]]; then
    result=$(_stack_versions_pnpm_resolved "$project_dir/pnpm-lock.yaml" "$importer" "$package_name")
    if [[ -n "$result" ]]; then printf '%s|pnpm-lock.yaml\n' "$result"; return 0; fi
  fi
  if [[ -f "$project_dir/package-lock.json" ]]; then
    result=$(_stack_versions_npm_resolved "$project_dir/package-lock.json" "$package_name")
    if [[ -n "$result" ]]; then printf '%s|package-lock.json\n' "$result"; return 0; fi
  fi
  if [[ -f "$project_dir/yarn.lock" ]]; then
    result=$(_stack_versions_yarn_resolved "$project_dir/yarn.lock" "$package_name" "$declared")
    if [[ -n "$result" ]]; then printf '%s|yarn.lock\n' "$result"; return 0; fi
  fi
}

stack_versions_detect() {
  local LC_ALL=C
  local project_dir="$1" ruby_value node_value lock_file="$1/Gemfile.lock"
  local pnpm_workspace="$1/pnpm-workspace.yaml" package_file="$1/package.json"
  [[ -d "$project_dir" ]] || return 0
  project_dir=$(cd "$project_dir" 2>/dev/null && pwd -P) || return 0
  lock_file="$project_dir/Gemfile.lock"
  package_file="$project_dir/package.json"
  pnpm_workspace="$project_dir/pnpm-workspace.yaml"

  ruby_value=$(_stack_versions_ruby "$project_dir")
  [[ -n "$ruby_value" ]] && printf '%s\n' "- ruby $ruby_value"
  if [[ -f "$lock_file" ]]; then
    _stack_versions_gems "$lock_file" "$project_dir/Gemfile"
  fi

  node_value=$(_stack_versions_node "$project_dir")
  [[ -n "$node_value" ]] && printf '%s\n' "- node $node_value"

  # Keep version output to framework-defining packages that shape review advice.
  local framework_packages=(
    vue react react-dom next nuxt angular @angular/core @nestjs/core typescript vite webpack
    express prisma @prisma/client jquery lodash moment axios element-ui element-plus vuex pinia
    vue-router @tanstack/react-query tailwindcss @base-ui/react @base-ui-components/react
    '@radix-ui/*' @headlessui/react @mui/material antd react-router react-router-dom
    @tanstack/react-router react-hook-form zod yup date-fns dayjs rxjs @nestjs/common
    class-validator typeorm sequelize mysql2 pg
  )
  local package_dirs=("$project_dir") package_patterns=() workspace_dirs=()
  local pattern candidate parent package_dir existing importer display_prefix package_json
  local pair package_name declared catalog_name catalog_range declared_label resolved source
  local item is_framework is_radix radix_count=0

  if [[ -f "$pnpm_workspace" ]]; then
    while IFS= read -r pattern; do package_patterns+=("$pattern"); done < <(_stack_versions_pnpm_patterns "$pnpm_workspace")
  fi
  if [[ -f "$package_file" ]]; then
    while IFS= read -r pattern; do package_patterns+=("$pattern"); done < <(_stack_versions_package_patterns "$package_file")
  fi

  for pattern in "${package_patterns[@]}"; do
    [[ "$pattern" != '!'* && -n "$pattern" ]] || continue
    pattern="${pattern%/}"
    case "$pattern" in
      *'*'*)
        if [[ "$pattern" == "*" ]]; then
          parent="."
        else
          [[ "$pattern" == */\* && "${pattern#*\*}" == "" ]] || continue
          parent="${pattern%/*}"
          [[ -n "$parent" ]] || parent="."
        fi
        ;;
      *) parent="" ;;
    esac
    if [[ -n "$parent" ]]; then
      case "/$parent/" in */../*|*/node_modules/*) continue ;; esac
      for candidate in "$project_dir/$parent"/*; do
        [[ -d "$candidate" && ! -L "$candidate" ]] || continue
        candidate=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
        case "$candidate" in "$project_dir"/*) ;; *) continue ;; esac
        existing="${candidate#"$project_dir"/}"
        case "/$existing/" in */../*|*/node_modules/*) continue ;; esac
        workspace_dirs+=("$candidate")
      done
    elif [[ "$pattern" != *'*'* ]]; then
      candidate="$project_dir/$pattern"
      case "/$pattern/" in */../*|*/node_modules/*) continue ;; esac
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue
      workspace_dirs+=("$candidate")
    fi
  done

  if [[ ${#workspace_dirs[@]} -gt 0 ]]; then
    while IFS= read -r package_dir; do
      local duplicate=false
      for existing in "${package_dirs[@]}"; do
        [[ "$existing" == "$package_dir" ]] && duplicate=true
      done
      [[ "$duplicate" == true ]] || package_dirs+=("$package_dir")
    done < <(printf '%s\n' "${workspace_dirs[@]}" | LC_ALL=C sort -u)
  fi

  for package_dir in "${package_dirs[@]}"; do
    package_json="$package_dir/package.json"
    [[ -f "$package_json" && ! -L "$package_json" ]] || continue
    command -v jq >/dev/null 2>&1 || continue
    importer="${package_dir#"$project_dir"/}"
    display_prefix="${importer}: "
    [[ "$package_dir" == "$project_dir" ]] && { importer="."; display_prefix=""; }
    while IFS= read -r pair; do
      IFS=$'\t' read -r package_name declared <<< "$pair"
      [[ -n "$package_name" && -n "$declared" ]] || continue
      is_framework=false
      is_radix=false
      case "$package_name" in
        @radix-ui/*) is_framework=true; is_radix=true ;;
      esac
      for item in "${framework_packages[@]}"; do
        if [[ "$item" == "$package_name" ]]; then is_framework=true; break; fi
      done
      [[ "$is_framework" == true ]] || continue
      if [[ "$is_radix" == true && $radix_count -ge 5 ]]; then
        radix_count=$((radix_count+1))
        continue
      fi

      catalog_name=""
      catalog_range=""
      if [[ "$declared" == catalog:* ]]; then
        catalog_name="${declared#catalog:}"
        catalog_range=$(_stack_versions_catalog_range "$pnpm_workspace" "$catalog_name" "$package_name")
        if [[ -n "$catalog_name" ]]; then
          declared_label="catalog:$catalog_name → $catalog_range"
        else
          declared_label="catalog: → $catalog_range"
        fi
        [[ -n "$catalog_range" ]] || declared_label="$declared"
      else
        catalog_range="$declared"
        declared_label="$declared"
      fi

      resolved=$(_stack_versions_resolved "$project_dir" "$importer" "$package_name" "$catalog_range")
      if [[ "$resolved" == *'|'* ]]; then
        source="${resolved#*|}"
        resolved="${resolved%%|*}"
        printf '%s%s %s (%s; declared %s)\n' "- ${display_prefix}" "$package_name" "$resolved" "$source" "$declared_label"
      elif [[ -n "$catalog_range" && "$declared" == catalog:* ]]; then
        printf '%s%s %s (declared %s)\n' "- ${display_prefix}" "$package_name" "$catalog_range" "$declared_label"
      else
        printf '%s%s %s (declared)\n' "- ${display_prefix}" "$package_name" "$declared"
      fi
      [[ "$is_radix" == true ]] && radix_count=$((radix_count+1))
    done < <(jq -r '(.dependencies // {} | .) as $dependencies | (.devDependencies // {}) as $dev_dependencies | ($dependencies + $dev_dependencies) | to_entries[] | [.key, (.value | tostring)] | @tsv' "$package_json" 2>/dev/null || true)
  done
  [[ $radix_count -gt 5 ]] && printf '%s\n' "- +$((radix_count-5)) more @radix-ui packages"
  return 0
}
