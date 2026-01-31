#!/usr/bin/env bash
set -euo pipefail

# Environment variables for auto mode
AUTO_MODE="${AUTO_MODE:-false}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_REPO="${GITLAB_REPO:-}"

# Parse --auto flag
for arg in "$@"; do
  case "$arg" in
    --auto|-y) AUTO_MODE=true ;;
  esac
done

ask_yes_no() {
  local prompt="$1" response lowered
  while true; do
    read -r -p "$prompt [y/n]: " response
    lowered="$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')"
    case "$lowered" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer with y or n." ;;
    esac
  done
}

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: GitHub CLI (gh) not found in PATH." >&2
    exit 1
  fi
}

require_gh_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: GitHub CLI is not authenticated. Run 'gh auth login' or export GH_TOKEN." >&2
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_gitlab_repo() {
  local raw_input="$1"
  local default_host="${2:-gitlab.com}"
  local cleaned host path first_segment

  cleaned="$(trim "$raw_input")"
  cleaned="${cleaned%.git}"
  cleaned="${cleaned#ssh://}"
  cleaned="${cleaned#https://}"
  cleaned="${cleaned#http://}"

  if [[ "$cleaned" == git@* ]]; then
    cleaned="${cleaned#git@}"
    cleaned="${cleaned/:/\/}"
  fi

  if [[ "$cleaned" == */* ]]; then
    first_segment="${cleaned%%/*}"
    if [[ "$first_segment" == *.* ]]; then
      host="$first_segment"
      path="${cleaned#*/}"
    else
      host="$default_host"
      path="$cleaned"
    fi
  else
    host="$default_host"
    path="$cleaned"
  fi

  path="${path#/}"
  host="${host#/}"
  printf '%s\n' "${host}/${path}.git"
}

main() {
  require_gh
  require_gh_auth

  # In auto mode, skip confirmation prompts
  if [[ "$AUTO_MODE" != "true" ]]; then
    if ! ask_yes_no "Add env secrets and variables"; then
      echo "Nothing to do."
      return 0
    fi
  fi

  local repo_input scope_args=()
  if repo_input="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
    echo "Using GitHub repository: $repo_input"
  else
    if [[ "$AUTO_MODE" == "true" ]]; then
      echo "Error: Could not detect GitHub repository in auto mode." >&2
      exit 1
    fi
    read -r -p "Unable to detect repository automatically. Enter GitHub repository (owner/name): " repo_input
    repo_input="$(trim "$repo_input")"
    if [[ -z "$repo_input" ]]; then
      echo "Error: repository cannot be empty." >&2
      exit 1
    fi
    if [[ "$repo_input" == *"://"* ]]; then
      echo "Error: Provide the GitHub repository as owner/name (e.g. octo-org/migrator), not a URL." >&2
      exit 1
    fi
    if [[ ! "$repo_input" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      echo "Error: Repository must be in the format owner/name (e.g. octo-org/migrator)." >&2
      exit 1
    fi
  fi

  scope_args=(--repo "$repo_input")

  # Set GitLab token secret
  if [[ "$AUTO_MODE" == "true" ]]; then
    if [[ -n "$GITLAB_TOKEN" ]]; then
      echo "Setting GITLAB_TOKEN secret..."
      gh secret set GITLAB_TOKEN "${scope_args[@]}" --app actions --body "$GITLAB_TOKEN"
      echo "Secret GITLAB_TOKEN configured."
    else
      echo "Warning: GITLAB_TOKEN not provided, skipping secret setup."
    fi
  elif ask_yes_no "Add PAT secret for GitLab"; then
    local pat
    while true; do
      read -r -s -p "Enter GitLab PAT (input hidden): " pat
      echo
      pat="$(trim "$pat")"
      if [[ -z "$pat" ]]; then
        echo "PAT cannot be empty."
        continue
      fi
      gh secret set GITLAB_TOKEN "${scope_args[@]}" --app actions --body "$pat"
      unset pat
      echo "Secret GITLAB_TOKEN configured."
      break
    done
  else
    echo "Skipping PAT secret."
  fi

  # Set GitLab repository variable
  if [[ "$AUTO_MODE" == "true" ]]; then
    if [[ -n "$GITLAB_REPO" ]]; then
      local normalized_repo
      normalized_repo="$(normalize_gitlab_repo "$GITLAB_REPO")"
      echo "Setting GITLAB_REPO variable: $normalized_repo"
      gh variable set GITLAB_REPO "${scope_args[@]}" --body "$normalized_repo"
      echo "Variable GITLAB_REPO configured."
    else
      echo "Warning: GITLAB_REPO not provided, skipping variable setup."
    fi
  elif ask_yes_no "Add target GitLab repository variable"; then
    local gitlab_input normalized_repo
    read -r -p "Enter GitLab repository (gitlab.com/group/project, https URL, or git@gitlab.com:group/project): " gitlab_input
    gitlab_input="$(trim "$gitlab_input")"
    if [[ -z "$gitlab_input" ]]; then
      echo "Error: GitLab repository cannot be empty." >&2
      exit 1
    fi
    normalized_repo="$(normalize_gitlab_repo "$gitlab_input")"
    echo "Normalized GitLab repo: $normalized_repo"
    gh variable set GITLAB_REPO "${scope_args[@]}" --body "$normalized_repo"
    echo "Variable GITLAB_REPO configured."
  else
    echo "Skipping target repository variable."
  fi

  echo "Done."
}

main "$@"
