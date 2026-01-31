#!/usr/bin/env bash
set -euo pipefail

# Setup GitLab project with proper configuration for mirroring.
# - Creates project if it doesn't exist
# - Configures protected branches to allow force push
# - Mirrors GitHub repo settings (description, visibility)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
AUTO_MODE="${AUTO_MODE:-false}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-}"  # Group/user namespace
PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-}"
PROJECT_VISIBILITY="${PROJECT_VISIBILITY:-private}"  # private, internal, public
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
MIRROR_ALL_BRANCHES="${MIRROR_ALL_BRANCHES:-true}"

print_usage() {
  cat <<'EOF'
setup-gitlab-project.sh - Create and configure GitLab project for mirroring

Usage:
  setup-gitlab-project.sh [options]

Options:
  --auto                  Non-interactive mode (requires env vars or flags)
  --token TOKEN           GitLab personal access token (or set GITLAB_TOKEN)
  --host HOST             GitLab host (default: gitlab.com)
  --namespace NAMESPACE   GitLab namespace (group or username)
  --name NAME             Project name
  --description DESC      Project description
  --visibility VIS        Visibility: private, internal, public (default: private)
  --default-branch BRANCH Default branch name (default: main)
  --help                  Show this help

Environment variables:
  GITLAB_TOKEN, GITLAB_HOST, GITLAB_NAMESPACE, PROJECT_NAME,
  PROJECT_DESCRIPTION, PROJECT_VISIBILITY, DEFAULT_BRANCH, AUTO_MODE
EOF
}

log() {
  echo "[gitlab-setup] $*"
}

error() {
  echo "[gitlab-setup] ERROR: $*" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO_MODE=true; shift ;;
    --token) GITLAB_TOKEN="$2"; shift 2 ;;
    --host) GITLAB_HOST="$2"; shift 2 ;;
    --namespace) GITLAB_NAMESPACE="$2"; shift 2 ;;
    --name) PROJECT_NAME="$2"; shift 2 ;;
    --description) PROJECT_DESCRIPTION="$2"; shift 2 ;;
    --visibility) PROJECT_VISIBILITY="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    --help) print_usage; exit 0 ;;
    *) error "Unknown option: $1"; print_usage; exit 1 ;;
  esac
done

# Validate required inputs
if [[ -z "$GITLAB_TOKEN" ]]; then
  if [[ "$AUTO_MODE" == "true" ]]; then
    error "GITLAB_TOKEN is required in auto mode"
    exit 1
  fi
  read -r -s -p "Enter GitLab personal access token: " GITLAB_TOKEN
  echo
fi

if [[ -z "$GITLAB_NAMESPACE" ]]; then
  if [[ "$AUTO_MODE" == "true" ]]; then
    error "GITLAB_NAMESPACE is required in auto mode"
    exit 1
  fi
  read -r -p "Enter GitLab namespace (group or username): " GITLAB_NAMESPACE
fi

if [[ -z "$PROJECT_NAME" ]]; then
  if [[ "$AUTO_MODE" == "true" ]]; then
    error "PROJECT_NAME is required in auto mode"
    exit 1
  fi
  read -r -p "Enter project name: " PROJECT_NAME
fi

GITLAB_API="https://${GITLAB_HOST}/api/v4"
PROJECT_PATH="${GITLAB_NAMESPACE}/${PROJECT_NAME}"
PROJECT_PATH_ENCODED="${PROJECT_PATH//\//%2F}"

# API helper function
gitlab_api() {
  local method="$1"
  local endpoint="$2"
  shift 2
  curl -fsSL --request "$method" \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    "$@" \
    "${GITLAB_API}${endpoint}"
}

# Check if project exists
check_project_exists() {
  local response
  if response=$(gitlab_api GET "/projects/${PROJECT_PATH_ENCODED}" 2>/dev/null); then
    echo "$response"
    return 0
  fi
  return 1
}

# Get namespace ID
get_namespace_id() {
  local response
  response=$(gitlab_api GET "/namespaces?search=${GITLAB_NAMESPACE}" 2>/dev/null) || {
    error "Failed to query namespaces"
    return 1
  }

  local ns_id
  ns_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

  if [[ -z "$ns_id" ]]; then
    error "Namespace '${GITLAB_NAMESPACE}' not found"
    return 1
  fi

  echo "$ns_id"
}

# Create GitLab project
create_project() {
  local namespace_id="$1"

  log "Creating GitLab project: ${PROJECT_PATH}"

  local payload
  payload=$(cat <<EOF
{
  "name": "${PROJECT_NAME}",
  "namespace_id": ${namespace_id},
  "description": "${PROJECT_DESCRIPTION}",
  "visibility": "${PROJECT_VISIBILITY}",
  "default_branch": "${DEFAULT_BRANCH}",
  "initialize_with_readme": false
}
EOF
)

  local response
  if ! response=$(gitlab_api POST "/projects" --data "$payload" 2>&1); then
    error "Failed to create project: $response"
    return 1
  fi

  log "Project created successfully"
  echo "$response"
}

# Get project ID from project info
get_project_id() {
  local project_info="$1"
  echo "$project_info" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

# Configure protected branch to allow force push
configure_protected_branch() {
  local project_id="$1"
  local branch="$2"

  log "Configuring protected branch '${branch}' to allow force push..."

  # First, try to unprotect the branch (if it's protected)
  gitlab_api DELETE "/projects/${project_id}/protected_branches/${branch}" 2>/dev/null || true

  # Re-protect with force push allowed
  local payload
  payload=$(cat <<EOF
{
  "name": "${branch}",
  "push_access_level": 40,
  "merge_access_level": 40,
  "allow_force_push": true
}
EOF
)

  local response
  if ! response=$(gitlab_api POST "/projects/${project_id}/protected_branches" --data "$payload" 2>&1); then
    # Branch might not exist yet, which is fine
    log "Note: Could not configure protected branch (branch may not exist yet)"
    return 0
  fi

  log "Protected branch configured with force push enabled"
}

# Update project settings
update_project_settings() {
  local project_id="$1"

  log "Updating project settings..."

  local payload
  payload=$(cat <<EOF
{
  "description": "${PROJECT_DESCRIPTION}",
  "default_branch": "${DEFAULT_BRANCH}"
}
EOF
)

  gitlab_api PUT "/projects/${project_id}" --data "$payload" >/dev/null 2>&1 || {
    log "Warning: Could not update some project settings"
  }
}

# Main execution
main() {
  log "Setting up GitLab project: ${PROJECT_PATH}"
  log "Host: ${GITLAB_HOST}"
  log "Visibility: ${PROJECT_VISIBILITY}"
  log "Default branch: ${DEFAULT_BRANCH}"

  local project_info project_id

  # Check if project already exists
  if project_info=$(check_project_exists); then
    log "Project already exists"
    project_id=$(get_project_id "$project_info")
  else
    log "Project does not exist, creating..."

    # Get namespace ID
    local namespace_id
    namespace_id=$(get_namespace_id) || exit 1
    log "Found namespace ID: ${namespace_id}"

    # Create the project
    project_info=$(create_project "$namespace_id") || exit 1
    project_id=$(get_project_id "$project_info")
  fi

  log "Project ID: ${project_id}"

  # Update project settings (in case they changed)
  update_project_settings "$project_id"

  # Configure protected branch for force push
  configure_protected_branch "$project_id" "$DEFAULT_BRANCH"

  # Output the GitLab repo URL for other scripts
  local gitlab_repo="${GITLAB_HOST}/${PROJECT_PATH}.git"
  log "GitLab repository: ${gitlab_repo}"

  # Export for other scripts
  echo "GITLAB_REPO=${gitlab_repo}"
  echo "GITLAB_PROJECT_ID=${project_id}"
}

main
