#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
source "$SCRIPT_DIR/lib/stack-versions.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

RAILS="$TMP/rails-app"
mkdir -p "$RAILS"
printf '2.5.7\n' > "$RAILS/.ruby-version"
cat > "$RAILS/Gemfile" <<'GEMFILE'
source 'https://rubygems.org'
ruby '2.4.0'
GEMFILE
cat > "$RAILS/Gemfile.lock" <<'LOCK'
GEM
  remote: https://rubygems.org/
  specs:
    rails (4.2.11)
      rack (1.6.13)
    sidekiq (5.2.9)
    rack (1.6.13)

PLATFORMS
  ruby

DEPENDENCIES
  rails (~> 4.2)
  sidekiq

RUBY VERSION
   ruby 2.5.8p206

BUNDLED WITH
   1.17.3
LOCK
out=$(stack_versions_detect "$RAILS")
case "$out" in *"ruby 2.5.7 (.ruby-version)"*) pass "Ruby version comes from .ruby-version" ;; *) fail "Ruby .ruby-version was not detected" ;; esac
[[ "$(stack_versions_ruby "$RAILS")" == "2.5.7" ]] && pass "Ruby helper returns the .ruby-version value" || fail "Ruby helper did not return the .ruby-version value"
case "$out" in *"rails 4.2.11 (Gemfile.lock)"*"sidekiq 5.2.9 (Gemfile.lock)"*) pass "direct Gemfile.lock gems are resolved" ;; *) fail "direct gem versions were not detected" ;; esac
gem_lines=$(printf '%s\n' "$out" | sed -n '/(Gemfile.lock)/p')
[[ "$(printf '%s\n' "$gem_lines" | sed -n '1p')" == "- rails 4.2.11 (Gemfile.lock)" ]] && pass "rails is listed before other direct gems" || fail "rails was not listed first"
case "$out" in *"rack 1.6.13"*) fail "transitive GEM/specs entries must not be listed" ;; *) pass "only DEPENDENCIES gems are listed" ;; esac

LOCK_RUBY="$TMP/lock-ruby"
mkdir -p "$LOCK_RUBY"
cp "$RAILS/Gemfile.lock" "$LOCK_RUBY/Gemfile.lock"
out=$(stack_versions_detect "$LOCK_RUBY")
case "$out" in *"ruby 2.5.8p206 (Gemfile.lock)"*) pass "Ruby version falls back to Gemfile.lock" ;; *) fail "Gemfile.lock Ruby version fallback failed" ;; esac
[[ "$(stack_versions_ruby "$LOCK_RUBY")" == "2.5.8p206" ]] && pass "Ruby helper returns the lockfile value" || fail "Ruby helper did not return the lockfile value"

GEMFILE_RUBY="$TMP/gemfile-ruby"
mkdir -p "$GEMFILE_RUBY"
printf "ruby '3.1.4'\n" > "$GEMFILE_RUBY/Gemfile"
out=$(stack_versions_detect "$GEMFILE_RUBY")
case "$out" in *"ruby 3.1.4 (Gemfile)"*) pass "Ruby version falls back to Gemfile" ;; *) fail "Gemfile Ruby version fallback failed" ;; esac
[[ "$(stack_versions_ruby "$GEMFILE_RUBY")" == "3.1.4" ]] && pass "Ruby helper returns the Gemfile value" || fail "Ruby helper did not return the Gemfile value"

# Fixtures below assert the cap at 40 to keep them small; the default is higher.
export MRA_STACK_VERSIONS_GEM_CAP=40
CAP="$TMP/gem-cap"
mkdir -p "$CAP"
{
  printf 'GEM\n  specs:\n    rails (4.2.11)\n'
  for number in {1..41}; do printf '    gem%02d (1.0.0)\n' "$number"; done
  printf '\nDEPENDENCIES\n  rails\n'
  for number in {1..41}; do printf '  gem%02d\n' "$number"; done
} > "$CAP/Gemfile.lock"
out=$(stack_versions_detect "$CAP")
gem_count=$(printf '%s\n' "$out" | awk '/ \(Gemfile.lock\)$/ { count++ } END { print count+0 }')
[[ "$gem_count" -eq 40 ]] && pass "Gemfile.lock direct gem list is capped at 40" || fail "Gemfile.lock gem cap emitted $gem_count gems"
case "$out" in *"- 2 direct gems omitted"*) pass "Gemfile.lock reports the omitted gem count" ;; *) fail "omitted gem count was not reported" ;; esac
[[ "$(printf '%s\n' "$out" | sed -n '/(Gemfile.lock)/{p;q;}')" == "- rails 4.2.11 (Gemfile.lock)" ]] && pass "rails remains first when the gem cap applies" || fail "rails is not first at the gem cap"

MONO="$TMP/mono-repo"
mkdir -p "$MONO/apps/web"
cat > "$MONO/package.json" <<'JSON'
{"name":"mono-root","engines":{"node":">=18"},"dependencies":{"vue":"^3.5.0"}}
JSON
printf 'v20.19.5\n' > "$MONO/.nvmrc"
cat > "$MONO/pnpm-workspace.yaml" <<'YAML'
packages:
  - 'apps/*'
catalog:
  react: ^19.1.0
catalogs:
  ui:
    typescript: ^5.8.3
YAML
cat > "$MONO/apps/web/package.json" <<'JSON'
{"name":"web-app","dependencies":{"react":"catalog:"},"devDependencies":{"typescript":"catalog:ui"}}
JSON
cat > "$MONO/pnpm-lock.yaml" <<'YAML'
lockfileVersion: '9.0'
importers:
  .:
    dependencies:
      vue:
        specifier: ^3.5.0
        version: 3.5.2
  apps/web:
    dependencies:
      react:
        specifier: catalog:
        version: 19.1.1
    devDependencies:
      typescript:
        specifier: catalog:ui
        version: 5.8.3
YAML
out=$(stack_versions_detect "$MONO")
case "$out" in *"node 20.19.5 (.nvmrc)"*) pass "Node version prefers .nvmrc" ;; *) fail "Node .nvmrc version was not detected" ;; esac
[[ "$(stack_versions_node "$MONO")" == "20.19.5" ]] && pass "Node helper returns the .nvmrc value" || fail "Node helper did not return the .nvmrc value"
case "$out" in *"vue 3.5.2 (pnpm-lock.yaml; declared ^3.5.0)"*) pass "pnpm root package uses its resolved lock version" ;; *) fail "pnpm root package resolution or declared range failed" ;; esac
case "$out" in *"apps/web: react 19.1.1 (pnpm-lock.yaml; declared catalog: → ^19.1.0)"*) pass "pnpm workspace resolves the default catalog" ;; *) fail "pnpm default catalog resolution failed" ;; esac
case "$out" in *"apps/web: typescript 5.8.3 (pnpm-lock.yaml; declared catalog:ui → ^5.8.3)"*) pass "pnpm workspace resolves a named catalog" ;; *) fail "pnpm named catalog resolution failed" ;; esac

NPM="$TMP/npm-app"
mkdir -p "$NPM/packages/tools"
cat > "$NPM/package.json" <<'JSON'
{"name":"npm-app","engines":{"node":">=20 <21"},"workspaces":["packages/*"],"dependencies":{"vue":"^3.0.0","axios":"^1.6.0"}}
JSON
cat > "$NPM/packages/tools/package.json" <<'JSON'
{"name":"tooling-package","dependencies":{"express":"^4.0.0"}}
JSON
cat > "$NPM/package-lock.json" <<'JSON'
{"name":"npm-app","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"npm-app","version":"1.0.0"},"node_modules/vue":{"version":"3.4.1"},"node_modules/axios":{"version":"1.7.2"},"node_modules/express":{"version":"4.21.1"}}}
JSON
out=$(stack_versions_detect "$NPM")
case "$out" in *"node >=20 <21 (package.json engines)"*) pass "Node version falls back to package.json engines" ;; *) fail "package.json Node engines version was not detected" ;; esac
[[ "$(stack_versions_node "$NPM")" == ">=20 <21" ]] && pass "Node helper preserves the package.json engine range" || fail "Node helper did not preserve the package.json engine range"
case "$out" in *"vue 3.4.1 (package-lock.json; declared ^3.0.0)"*) pass "npm lock version is preferred over the declared range" ;; *) fail "npm lock version was not reported" ;; esac
case "$out" in *"axios 1.7.2 (package-lock.json; declared ^1.6.0)"*) pass "npm lock resolves each direct curated package" ;; *) fail "npm package-lock direct package was not resolved" ;; esac
case "$out" in *"packages/tools: express 4.21.1 (package-lock.json; declared ^4.0.0)"*) pass "package.json workspaces expand one directory level" ;; *) fail "package.json workspace package was not included" ;; esac

UI_PACKAGES="$TMP/ui-packages"
mkdir -p "$UI_PACKAGES"
cat > "$UI_PACKAGES/package.json" <<'JSON'
{"dependencies":{"@base-ui/react":"^1.0.0","@radix-ui/dialog":"^1.0.0","@radix-ui/popover":"^1.0.0","@radix-ui/tooltip":"^1.0.0"}}
JSON
out=$(stack_versions_detect "$UI_PACKAGES")
case "$out" in *"@base-ui/react ^1.0.0 (declared)"*) pass "Base UI is included in curated package versions" ;; *) fail "Base UI package was not reported" ;; esac
case "$out" in *"@radix-ui/dialog ^1.0.0 (declared)"*"@radix-ui/popover ^1.0.0 (declared)"*"@radix-ui/tooltip ^1.0.0 (declared)"*) pass "Radix packages are matched by scope" ;; *) fail "Radix scoped packages were not reported" ;; esac

RADIX_CAP="$TMP/radix-cap"
mkdir -p "$RADIX_CAP"
cat > "$RADIX_CAP/package.json" <<'JSON'
{"dependencies":{"@radix-ui/accordion":"^1.0.0","@radix-ui/alert-dialog":"^1.0.0","@radix-ui/dialog":"^1.0.0","@radix-ui/dropdown-menu":"^1.0.0","@radix-ui/popover":"^1.0.0","@radix-ui/tabs":"^1.0.0"}}
JSON
out=$(stack_versions_detect "$RADIX_CAP")
radix_count=$(printf '%s\n' "$out" | grep -c '@radix-ui/')
[[ "$radix_count" -eq 5 ]] && pass "Radix output caps package details at five" || fail "Radix output reported $radix_count package details"
case "$out" in *"- +1 more @radix-ui packages"*) pass "Radix overflow count is reported" ;; *) fail "Radix overflow count was not reported" ;; esac

GROUPED="$TMP/grouped-gems"
mkdir -p "$GROUPED"
{
  printf "source 'https://rubygems.org'\n"
  printf "gem 'rails'\ngem 'sidekiq'\ngem 'devise'\n"
  printf "group :development do\n  gem 'better_errors'\n  group :test do\n    gem 'capybara'\n  end\nend\n"
  printf "group :development, :test do\n  gem 'grouped_tool'\nend\n"
  printf "gem 'inline_test_tool', group: [:test]\n"
  printf "group :quality do\n  gem 'quality_tool'\nend\n"
  printf "group :development, :test do\n"
  for number in {1..38}; do printf "  gem 'zzzdevgem%02d'\n" "$number"; done
  printf 'end\n'
} > "$GROUPED/Gemfile"
{
  printf 'GEM\n  specs:\n'
  for name in rails sidekiq devise better_errors capybara grouped_tool inline_test_tool quality_tool; do
    printf '    %s (1.0.0)\n' "$name"
  done
  for number in {1..38}; do printf '    zzzdevgem%02d (1.0.0)\n' "$number"; done
  printf '\nDEPENDENCIES\n'
  for name in better_errors capybara grouped_tool inline_test_tool quality_tool; do printf '  %s\n' "$name"; done
  for number in {1..38}; do printf '  zzzdevgem%02d\n' "$number"; done
  printf '  rails\n  sidekiq\n  devise\n'
} > "$GROUPED/Gemfile.lock"
out=$(stack_versions_detect "$GROUPED")
gem_order=$(printf '%s\n' "$out" | sed -n '/Gemfile.lock/p' | sed -n '1,4p')
[[ "$gem_order" == $'- rails 1.0.0 (Gemfile.lock)\n- devise 1.0.0 (Gemfile.lock)\n- sidekiq 1.0.0 (Gemfile.lock)\n- better_errors 1.0.0 (Gemfile.lock; dev/test)' ]] && pass "runtime gems precede dev/test gems in alphabetical order" || fail "runtime gems were not prioritized alphabetically: $gem_order"
case "$out" in *"capybara 1.0.0 (Gemfile.lock; dev/test)"*"grouped_tool 1.0.0 (Gemfile.lock; dev/test)"*"inline_test_tool 1.0.0 (Gemfile.lock; dev/test)"*"quality_tool 1.0.0 (Gemfile.lock; dev/test)"*) pass "group blocks and inline group options are marked dev/test" ;; *) fail "Gemfile group declarations were not classified" ;; esac
gem_count=$(printf '%s\n' "$out" | grep -c 'Gemfile.lock')
[[ "$gem_count" -eq 40 ]] && pass "runtime gems have priority within the 40-gem cap" || fail "grouped Gemfile.lock gem cap emitted $gem_count gems"
case "$out" in *"- 6 direct gems omitted"*) pass "grouped Gemfile.lock reports gems omitted after prioritization" ;; *) fail "grouped Gemfile.lock omitted count was incorrect" ;; esac

UNPARSEABLE="$TMP/unparseable-gemfile"
mkdir -p "$UNPARSEABLE"
printf 'gem dynamic_gem_name\n' > "$UNPARSEABLE/Gemfile"
cat > "$UNPARSEABLE/Gemfile.lock" <<'LOCK'
GEM
  specs:
    rails (4.2.11)
    runtime-gem (1.0.0)

DEPENDENCIES
  runtime-gem
  rails
LOCK
out=$(stack_versions_detect "$UNPARSEABLE")
case "$out" in *"rails 4.2.11 (Gemfile.lock)"*"runtime-gem 1.0.0 (Gemfile.lock)"*) pass "unparseable Gemfile falls back to lockfile ordering" ;; *) fail "unparseable Gemfile did not use the fallback behavior" ;; esac
case "$out" in *"runtime-gem 1.0.0 (Gemfile.lock; dev/test)"*) fail "unparseable Gemfile was partially classified" ;; *) pass "unparseable Gemfile classifications are discarded" ;; esac

NODE_VERSION="$TMP/node-version"
mkdir -p "$NODE_VERSION"
printf '18.20.4\n' > "$NODE_VERSION/.node-version"
out=$(stack_versions_detect "$NODE_VERSION")
case "$out" in *"node 18.20.4 (.node-version)"*) pass "Node version reads .node-version" ;; *) fail ".node-version was not detected" ;; esac
[[ "$(stack_versions_node "$NODE_VERSION")" == "18.20.4" ]] && pass "Node helper returns the .node-version value" || fail "Node helper did not return the .node-version value"

EMPTY="$TMP/empty-repo"
mkdir -p "$EMPTY"
out=$(stack_versions_detect "$EMPTY")
[[ -z "$out" ]] && pass "repository without version files returns empty output" || fail "empty repository produced version output"
[[ -z "$(stack_versions_ruby "$EMPTY")" && -z "$(stack_versions_node "$EMPTY")" ]] && pass "runtime helpers return empty output without version files" || fail "runtime helpers produced output without version files"

mkdir -p "$EMPTY/node_modules/hidden-package"
printf '{"name":"empty-repo","workspaces":["*"]}\n' > "$EMPTY/package.json"
printf '{"name":"hidden-package","dependencies":{"vue":"999.0.0"}}\n' > "$EMPTY/node_modules/hidden-package/package.json"
chmod 000 "$EMPTY/node_modules/hidden-package/package.json"
out=$(stack_versions_detect "$EMPTY")
case "$out" in *"999.0.0"*) fail "version detection read package metadata under node_modules" ;; *) pass "version detection ignores node_modules metadata" ;; esac
chmod 600 "$EMPTY/node_modules/hidden-package/package.json"

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: stack version tests passed"
else
  echo "FAIL: $errors stack version test(s) failed"
  exit 1
fi
