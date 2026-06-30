#!/usr/bin/env bash
# `mra prd` apply-side helpers: HTML rendering + GitHub issue creation.
# All mechanical facts live here (shell), never in agent prose.

# Render a .collab markdown file to its sibling .html. Guards: source must be
# under a .collab/ dir (no repo-tree writes), source must be non-empty, and the
# rendered .html must be non-empty (render-html.py returns 0 on a MISSING source
# and writes a non-empty template for an EMPTY one — so we check both ends).
prd_render_html() {
  local md="$1"
  case "$md" in
    */.collab/*) : ;;
    *) log_error "prd_render_html: refusing source outside .collab: $md" "prd"; return 1 ;;
  esac
  [[ -s "$md" ]] || { log_error "prd_render_html: source missing or empty: $md" "prd"; return 1; }
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Friendly preflight (substitute the real module from Step 3 if not 'markdown').
  python3 -c 'import markdown' 2>/dev/null \
    || { log_error "prd_render_html: python 'markdown' not installed — pip install markdown" "prd"; return 1; }
  python3 "$mra_dir/docs/superpowers/render-html.py" "$md" >/dev/null 2>&1 \
    || { log_error "prd_render_html: render failed: $md" "prd"; return 1; }
  local html="${md%.md}.html"
  [[ -s "$html" ]] || { log_error "prd_render_html: rendered html missing/empty: $html" "prd"; return 1; }
  printf '%s\n' "$html"
}
