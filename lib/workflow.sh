#!/usr/bin/env bash
# Workflow helpers for sub-agent development loop
# These functions are called by Claude's Bash tool during the mra workflow.

# Create and switch to a feature branch
# Usage: mra_branch_create <project-dir> <task-slug>
mra_branch_create() {
  local project_dir="$1" task_slug="$2"
  if [[ -z "$project_dir" || -z "$task_slug" ]]; then
    echo "ERROR: usage: mra_branch_create <project-dir> <task-slug>" >&2
    return 1
  fi
  local branch="mra/$task_slug"
  git -C "$project_dir" checkout -b "$branch" 2>/dev/null || git -C "$project_dir" checkout "$branch"
  echo "$branch"
}

# Commit changes with conventional commit format
# Usage: mra_commit <project-dir> <type> <message>
mra_commit() {
  local project_dir="$1" type="$2" message="$3"
  if [[ -z "$project_dir" || -z "$type" || -z "$message" ]]; then
    echo "ERROR: usage: mra_commit <project-dir> <type> <message>" >&2
    return 1
  fi
  git -C "$project_dir" add -A
  git -C "$project_dir" commit -m "$type: $message"
}

# Push branch and create PR
# Usage: mra_pr_create <project-dir> <title> <body>
mra_pr_create() {
  local project_dir="$1" title="$2" body="$3"
  if [[ -z "$project_dir" || -z "$title" ]]; then
    echo "ERROR: usage: mra_pr_create <project-dir> <title> <body>" >&2
    return 1
  fi
  local branch
  branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD)
  git -C "$project_dir" push -u origin "$branch"
  cd "$project_dir" && gh pr create --title "$title" --body "${body:-}"
}

# Get diff for review (current branch vs default branch)
# Usage: mra_diff <project-dir>
mra_diff() {
  local project_dir="$1"
  if [[ -z "$project_dir" ]]; then
    echo "ERROR: usage: mra_diff <project-dir>" >&2
    return 1
  fi
  local default_branch
  default_branch=$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/origin/@@' || echo "main")
  git -C "$project_dir" diff "$default_branch"...HEAD
}

# Get commit log for review (current branch vs default branch)
# Usage: mra_log_commits <project-dir>
mra_log_commits() {
  local project_dir="$1"
  if [[ -z "$project_dir" ]]; then
    echo "ERROR: usage: mra_log_commits <project-dir>" >&2
    return 1
  fi
  local default_branch
  default_branch=$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/origin/@@' || echo "main")
  git -C "$project_dir" log "$default_branch"...HEAD --oneline
}

# Log workflow event to .collab/logs/
# Usage: mra_log <workspace> <project> <message>
mra_log() {
  local workspace="$1" project="$2" message="$3"
  if [[ -z "$workspace" || -z "$project" || -z "$message" ]]; then
    echo "ERROR: usage: mra_log <workspace> <project> <message>" >&2
    return 1
  fi
  local log_dir="$workspace/.collab/logs"
  local log_file="$log_dir/$(date +%Y%m%d-%H%M%S)-$project.log"
  mkdir -p "$log_dir"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $message" >> "$log_file"
  echo "$log_file"
}

# Check if branch exists locally
# Usage: mra_branch_exists <project-dir> <branch-name>
mra_branch_exists() {
  local project_dir="$1" branch="$2"
  if [[ -z "$project_dir" || -z "$branch" ]]; then
    echo "ERROR: usage: mra_branch_exists <project-dir> <branch-name>" >&2
    return 1
  fi
  git -C "$project_dir" rev-parse --verify "$branch" &>/dev/null
}

# Return to default branch
# Usage: mra_branch_cleanup <project-dir>
mra_branch_cleanup() {
  local project_dir="$1"
  if [[ -z "$project_dir" ]]; then
    echo "ERROR: usage: mra_branch_cleanup <project-dir>" >&2
    return 1
  fi
  local default_branch
  default_branch=$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/origin/@@' || echo "main")
  git -C "$project_dir" checkout "$default_branch"
}
