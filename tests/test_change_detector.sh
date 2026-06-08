#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/sync.sh"            # get_default_branch
source "$SCRIPT_DIR/lib/review-diff.sh"     # review_diff_files
source "$SCRIPT_DIR/lib/change-detector.sh"

errors=0
T=$(mktemp -d)
git -C "$T" init -b main repo &>/dev/null
R="$T/repo"
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
mkdir -p "$R/config" "$R/app/models"
echo "x" > "$R/app/models/u.rb"; git -C "$R" add .; git -C "$R" commit -m base &>/dev/null
A=$(git -C "$R" rev-parse HEAD)
# work on a feature branch so the default branch (main) stays at A — mirrors real review usage
git -C "$R" checkout -b feat &>/dev/null
# B: an API-surface change (routes.rb) + a non-API change
printf 'Rails.routes\n' > "$R/config/routes.rb"
echo "y" >> "$R/app/models/u.rb"
git -C "$R" add .; git -C "$R" commit -m feat &>/dev/null
B=$(git -C "$R" rev-parse HEAD)
# C: a non-API-only change
echo "z" >> "$R/app/models/u.rb"; git -C "$R" add .; git -C "$R" commit -m chore &>/dev/null

# range A..B contains routes.rb -> high
res=$(is_api_change "$R" rails-api range "$A..$B")
case "$res" in high*) : ;; *) echo "FAIL: A..B (routes.rb) should be high, got: $res"; errors=$((errors+1)) ;; esac

# range B..HEAD is models-only -> low
res=$(is_api_change "$R" rails-api range "$B..$(git -C "$R" rev-parse HEAD)")
case "$res" in low|none) : ;; *) echo "FAIL: B..HEAD (models only) should be low/none, got: $res"; errors=$((errors+1)) ;; esac

# empty range -> none
res=$(is_api_change "$R" rails-api range "$B..$B")
case "$res" in none) : ;; *) echo "FAIL: empty range should be none, got: $res"; errors=$((errors+1)) ;; esac

# backward-compat: 2-arg call falls back to default_branch...HEAD (HEAD is C; main is A => routes.rb in range) -> high
res=$(is_api_change "$R" rails-api)
case "$res" in high*) : ;; *) echo "FAIL: 2-arg back-compat should see routes.rb (high), got: $res"; errors=$((errors+1)) ;; esac

rm -rf "$T"

# --- controller change with a public method => high (controller-detection fix) ---
CT=$(mktemp -d)
git -C "$CT" init -b main repo &>/dev/null
CR="$CT/repo"
git -C "$CR" config user.email t@t.t; git -C "$CR" config user.name t
mkdir -p "$CR/app/controllers"
git -C "$CR" commit --allow-empty -m base &>/dev/null
CA=$(git -C "$CR" rev-parse HEAD)
git -C "$CR" checkout -b feat &>/dev/null
printf 'class UsersController\n  def index\n  end\nend\n' > "$CR/app/controllers/users_controller.rb"
git -C "$CR" add .; git -C "$CR" commit -m "add controller" &>/dev/null
CB=$(git -C "$CR" rev-parse HEAD)

res=$(is_api_change "$CR" rails-api range "$CA..$CB")
case "$res" in high*) : ;; *) echo "FAIL: controller w/ def index should be high, got: $res"; errors=$((errors+1)) ;; esac
rm -rf "$CT"

# --- is_api_change working mode: uncommitted routes.rb => high ---
WK=$(mktemp -d)
git -C "$WK" init -b main repo &>/dev/null
WR="$WK/repo"
git -C "$WR" config user.email t@t.t; git -C "$WR" config user.name t
mkdir -p "$WR/config"
printf 'Rails.routes old\n' > "$WR/config/routes.rb"
git -C "$WR" add .; git -C "$WR" commit -m base &>/dev/null
# Now modify routes.rb in working tree (tracked + uncommitted)
printf 'Rails.routes new\n' > "$WR/config/routes.rb"
res=$(is_api_change "$WR" rails-api working "")
case "$res" in high*) : ;; *) echo "FAIL: working-mode uncommitted routes.rb should be high, got: $res"; errors=$((errors+1)) ;; esac
rm -rf "$WK"

# --- concerns-only controller change is NOT high (locks the grep -qvE concerns/ exclusion) ---
CC=$(mktemp -d)
git -C "$CC" init -b main repo &>/dev/null
CCR="$CC/repo"
git -C "$CCR" config user.email t@t.t; git -C "$CCR" config user.name t
mkdir -p "$CCR/app/controllers/concerns"
git -C "$CCR" commit --allow-empty -m base &>/dev/null
CCA=$(git -C "$CCR" rev-parse HEAD)
git -C "$CCR" checkout -b feat &>/dev/null
printf 'module Auth\n  def authenticate\n  end\nend\n' > "$CCR/app/controllers/concerns/auth_concern.rb"
git -C "$CCR" add .; git -C "$CCR" commit -m "add concern" &>/dev/null
CCB=$(git -C "$CCR" rev-parse HEAD)
res=$(is_api_change "$CCR" rails-api range "$CCA..$CCB")
case "$res" in high*) echo "FAIL: concerns-only change should NOT be high, got: $res"; errors=$((errors+1)) ;; *) : ;; esac
rm -rf "$CC"

if [[ $errors -eq 0 ]]; then
  echo "PASS: is_api_change mode-aware tests passed"
else
  echo "FAIL: $errors tests failed"; exit 1
fi
