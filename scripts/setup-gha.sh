#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"
WORKFLOW_PATH="$WORKFLOW_DIR/mirror-to-gitlab.yaml"

# Environment variables for auto mode
AUTO_MODE="${AUTO_MODE:-false}"
FEATURE_POLICY="${FEATURE_POLICY:-}"  # always or keyword
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

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

yaml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

require_glab() {
  if ! command -v glab >/dev/null 2>&1; then
    echo "Error: glab CLI not found in PATH. Install it or choose an existing GitLab project." >&2
    exit 1
  fi
}

detect_glab_host() {
  local host
  if command -v glab >/dev/null 2>&1; then
    host="$(glab config get host 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ -n "$host" ]]; then
      printf '%s\n' "$host"
      return 0
    fi
  fi
  printf '%s\n' "gitlab.com"
}

# Check if GitLab project exists using the API
# Returns 0 if exists, 1 if not
check_gitlab_project_exists() {
  local gitlab_repo="$1"
  local token="${GITLAB_TOKEN:-}"

  # Extract host and path from normalized repo (e.g., gitlab.com/user/repo.git)
  local host path
  host="${gitlab_repo%%/*}"
  path="${gitlab_repo#*/}"
  path="${path%.git}"

  # URL-encode the path (replace / with %2F)
  local encoded_path="${path//\//%2F}"

  local api_url="https://${host}/api/v4/projects/${encoded_path}"

  if [[ -n "$token" ]]; then
    curl -fsSL --header "PRIVATE-TOKEN: ${token}" "$api_url" >/dev/null 2>&1
  else
    # Try without auth (works for public projects)
    curl -fsSL "$api_url" >/dev/null 2>&1
  fi
}

determine_default_branch() {
  local branch
  if branch="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null)"; then
    branch="${branch#origin/}"
    printf '%s\n' "$branch"
    return 0
  fi
  if branch="$(git symbolic-ref --short HEAD 2>/dev/null)"; then
    printf '%s\n' "$branch"
    return 0
  fi
  printf '%s\n' "main"
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

echo "Configure GitHub Actions workflow to mirror default branch to GitLab."

default_branch="$(determine_default_branch)"
gitlab_repo=""

# Check if GITLAB_REPO is already set (from configure-gh-env.sh or environment)
if [[ -n "$GITLAB_REPO" ]]; then
  gitlab_repo="$(normalize_gitlab_repo "$GITLAB_REPO")"
  echo "Checking GitLab repository: $gitlab_repo"

  if check_gitlab_project_exists "$gitlab_repo"; then
    echo "GitLab project exists."
  else
    echo "GitLab project does not exist yet."
    if [[ "$AUTO_MODE" == "true" ]]; then
      echo "Run 'ghmirror gitlab-setup' first to create the project, or create it manually."
    elif ask_yes_no "Would you like to create it now"; then
      # Try to create via API using setup-gitlab-project.sh logic
      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      if [[ -x "$SCRIPT_DIR/setup-gitlab-project.sh" ]]; then
        bash "$SCRIPT_DIR/setup-gitlab-project.sh" --auto
      elif command -v glab >/dev/null 2>&1; then
        require_glab
        gitlab_host="$(detect_glab_host)"
        # Extract path from normalized repo
        gitlab_project_path="${gitlab_repo#*/}"
        gitlab_project_path="${gitlab_project_path%.git}"
        echo "Creating GitLab project via glab..."
        glab project create "$gitlab_project_path" --visibility private --default-branch "$default_branch" || {
          echo "Failed to create project. Create it manually at: https://${gitlab_repo%.git}" >&2
        }
      else
        echo "Create the project manually at: https://${gitlab_repo%.git}"
      fi
    fi
  fi
elif [[ "$AUTO_MODE" == "true" ]]; then
  echo "Note: GITLAB_REPO not provided; workflow will use vars.GITLAB_REPO from GitHub Actions."
elif ask_yes_no "Do you already have a target GitLab repository"; then
  read -r -p "Enter GitLab repository (gitlab.com/<namespace>/<repo>[.git] or https URL): " gitlab_repo_input
  gitlab_repo="$(normalize_gitlab_repo "$gitlab_repo_input")"
else
  if ask_yes_no "Would you like to create a new GitLab project with glab now"; then
    require_glab
    gitlab_host="$(detect_glab_host)"
    echo "glab will use host: $gitlab_host"
    read -r -p "New project path (namespace/project): " gitlab_project_path
    gitlab_project_path="$(trim "$gitlab_project_path")"
    if [[ "$gitlab_project_path" != */* ]]; then
      echo "Error: Project path must include namespace/project." >&2
      exit 1
    fi
    read -r -p "Visibility [private/internal/public] (default: private): " visibility_input
    visibility_input="$(trim "$visibility_input")"
    case "$visibility_input" in
      "" ) visibility="private" ;;
      private|internal|public ) visibility="$visibility_input" ;;
      * )
        echo "Invalid visibility: $visibility_input" >&2
        exit 1
        ;;
    esac
    echo "Creating GitLab project $gitlab_host/$gitlab_project_path (visibility: $visibility, default branch: $default_branch)..."
    create_output=""
    if ! create_output="$(glab project create "$gitlab_project_path" --visibility "$visibility" --default-branch "$default_branch" 2>&1)"; then
      if grep -qi "unknown flag" <<<"$create_output"; then
        echo "glab does not support --default-branch; retrying without it."
        if ! glab project create "$gitlab_project_path" --visibility "$visibility"; then
          printf '%s\n' "$create_output" >&2
          echo "Failed to create GitLab project via glab." >&2
          exit 1
        fi
        if ! glab project update "$gitlab_project_path" --default-branch "$default_branch" >/dev/null 2>&1; then
          echo "Warning: unable to set default branch automatically. Adjust it manually in GitLab."
        else
          echo "Set GitLab default branch to $default_branch."
        fi
      else
        printf '%s\n' "$create_output" >&2
        echo "Failed to create GitLab project via glab." >&2
        exit 1
      fi
    else
      printf '%s\n' "$create_output"
    fi
    gitlab_repo="$(normalize_gitlab_repo "${gitlab_host}/${gitlab_project_path}.git" "$gitlab_host")"
    echo "Created GitLab project: https://${gitlab_repo}"
  else
    echo "A GitLab repository is required for the workflow. Aborting." >&2
    exit 1
  fi
fi

if [[ -n "$gitlab_repo" ]]; then
  gitlab_repo_comment="Target GitLab repo: ${gitlab_repo}"
else
  gitlab_repo_comment="Set vars.GITLAB_REPO to gitlab.com/<namespace>/<repo>.git"
fi

echo "Default behaviour: default branch pushes always mirror to GitLab."
feature_policy="${FEATURE_POLICY:-always}"
keyword_input=""
feature_behavior_comment="Non-default branch pushes (PR commits): mirror immediately with no keyword."

# In auto mode, use provided FEATURE_POLICY (defaults to 'always')
if [[ "$AUTO_MODE" == "true" ]]; then
  echo "Feature branch policy: $feature_policy"
  if [[ "$feature_policy" == "keyword" ]]; then
    keyword_input="${OVERRIDE_KEYWORD:-SYNC_TO_GITLAB}"
    feature_behavior_comment="Non-default branch pushes (PR commits): mirror only when commit message contains \"${keyword_input}\" so you can opt-in per push."
  fi
elif ask_yes_no "Mirror non-default branch pushes automatically (i.e., every commit pushed to PR/feature branches mirrors to GitLab)"; then
  feature_policy="always"
  feature_behavior_comment="Non-default branch pushes (PR commits): mirror immediately with no keyword."
else
  feature_policy="keyword"
  while true; do
    read -r -p "Enter keyword that must appear in commit messages to mirror non-default branches (e.g. SYNC_TO_GITLAB): " keyword_input
    keyword_input="$(trim "$keyword_input")"
    if [[ -n "$keyword_input" ]]; then
      break
    fi
    echo "Keyword cannot be empty when conditional mirroring is enabled."
  done
  feature_behavior_comment="Non-default branch pushes (PR commits): mirror only when commit message contains \"${keyword_input}\" so you can opt-in per push."
fi

mkdir -p "$WORKFLOW_DIR"

escaped_keyword="$(yaml_escape "$keyword_input")"
default_behavior_comment="- Default branch pushes: ALWAYS mirror (force overwrite keeps GitLab in sync with main)."
if [[ "$feature_policy" == "keyword" ]]; then
  override_comment="- Non-default branch pushes (PR commits): mirror only when commit message contains \"${keyword_input}\"; lets you opt-in per push."
  keyword_detail_comment="- Opt-in keyword currently required: \"${keyword_input}\"."
  yaml_keyword="\"${escaped_keyword}\""
  # For keyword policy: run on default branch OR when keyword found in commit message
  job_if_condition="github.event_name == 'workflow_dispatch' ||
      (
        github.event_name == 'push' &&
        (
          github.ref == format('refs/heads/{0}', github.event.repository.default_branch) ||
          (github.event.head_commit != null && contains(github.event.head_commit.message, '${escaped_keyword}')) ||
          (github.event.commits != null && contains(join(github.event.commits.*.message, ' '), '${escaped_keyword}'))
        )
      )"
else
  override_comment="- Non-default branch pushes (PR commits): mirror immediately like default branch pushes (no keyword required)."
  keyword_detail_comment="- Opt-in keyword disabled (all feature pushes mirror automatically)."
  yaml_keyword='""'
  # For always policy: run on any push
  job_if_condition="github.event_name == 'workflow_dispatch' || github.event_name == 'push'"
fi

cat >"$WORKFLOW_PATH" <<EOF
# Mirror to GitLab workflow (generated via scripts/setup-gha.sh)
# Options:
#   ${default_behavior_comment}
#   ${override_comment}
#   ${keyword_detail_comment}
#   - ${gitlab_repo_comment}
#   - Re-run scripts/setup-gha.sh to update keyword/policy after changing expectations.
name: Mirror to GitLab (ALWAYS overwrite default)

on:
  push:
    branches: ["**"]
  workflow_dispatch: {}

permissions:
  contents: read

concurrency:
  # Ensure only one mirror job runs per branch ref at a time; avoids concurrent force-push races.
  group: mirror-to-gitlab-\${{ github.ref }}
  cancel-in-progress: true

env:
  # Canonical branch resolved from the GitHub repository (e.g., main/master). Always mirrored.
  DEFAULT_BRANCH: \${{ github.event.repository.default_branch }}
  # Policy set by setup script. `always` mirrors every feature/PR push; `keyword` mirrors only when the keyword is present.
  FEATURE_PUSH_POLICY: "${feature_policy}"
  # Commit-message keyword required when FEATURE_PUSH_POLICY == 'keyword'. Empty when policy == 'always'.
  OVERRIDE_KEYWORD: ${yaml_keyword}

jobs:
  mirror:
    runs-on: ubuntu-latest
    # Gate: allow manual runs, always run for default-branch pushes, and conditionally mirror feature branches per policy.
    if: >
      ${job_if_condition}

    steps:
      # Fetch entire history and tags so force pushes mirror the complete state.
      - name: Checkout (full history)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # Configure Git identity and trust the workspace before interacting with remotes.
      - name: Configure git
        run: |
          git config --global user.name  "github-actions[bot]"
          git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git config --global --add safe.directory "\$GITHUB_WORKSPACE"
          git fetch --prune --tags origin

      # Add/update GitLab remote using PAT + repository URL from workflow variables.
      - name: Add GitLab remote
        env:
          GITLAB_TOKEN: \${{ secrets.GITLAB_TOKEN }}
          GITLAB_REPO:  \${{ vars.GITLAB_REPO }}
        run: |
          test -n "\$GITLAB_TOKEN" || { echo "Missing secret GITLAB_TOKEN"; exit 1; }
          test -n "\$GITLAB_REPO"  || { echo "Missing var GITLAB_REPO (gitlab.com/<ns>/<repo>.git)"; exit 1; }
          git remote remove gitlab 2>/dev/null || true
          git remote add gitlab "https://oauth2:\${GITLAB_TOKEN}@\${GITLAB_REPO}"
          git remote -v

      # Discover GitLab's default branch to ensure we overwrite the correct branch.
      - name: Detect GitLab default branch & fetch it
        id: rem
        run: |
          set -euo pipefail
          git fetch --prune --tags gitlab
          REMOTE_HEAD=\$(git ls-remote --symref gitlab HEAD | awk '/^ref:/ {print \$2}' | sed 's#refs/heads/##' || true)
          if [ -z "\$REMOTE_HEAD" ]; then REMOTE_HEAD="\${DEFAULT_BRANCH}"; fi
          echo "remote_head=\$REMOTE_HEAD" >> "\$GITHUB_OUTPUT"
          echo "GitLab default branch is: \$REMOTE_HEAD"

      # Force sync the GitLab default branch with the GitHub default branch.
      - name: FORCE overwrite GitLab default from GitHub default
        env:
          REMOTE_HEAD: \${{ steps.rem.outputs.remote_head }}
          DEFAULT_BRANCH: \${{ env.DEFAULT_BRANCH }}
        run: |
          set -euo pipefail
          echo "Overwriting gitlab:\$REMOTE_HEAD from origin/\$DEFAULT_BRANCH (HARD FORCE)"
          echo "(Ensure GitLab Protected Branch allows Force push — you already enabled it.)"
          git push --force gitlab "refs/remotes/origin/\${DEFAULT_BRANCH}:refs/heads/\${REMOTE_HEAD}"

      # If this push is on a non-default branch (feature/PR branch), mirror that branch too.
      - name: FORCE push current branch (if not default)
        env:
          DEFAULT_BRANCH: \${{ env.DEFAULT_BRANCH }}
        run: |
          set -euo pipefail
          CURRENT_BRANCH="\${GITHUB_REF#refs/heads/}"
          if [[ "\$CURRENT_BRANCH" != "\$DEFAULT_BRANCH" ]]; then
            echo "Mirroring feature branch: \$CURRENT_BRANCH"
            git push --force gitlab "refs/remotes/origin/\${CURRENT_BRANCH}:refs/heads/\${CURRENT_BRANCH}"
          else
            echo "Current branch is default branch; already mirrored above."
          fi

      # Keep release tags in sync by force pushing them as well.
      - name: FORCE push tags
        run: git push --force --tags gitlab

      # Optional cleanup: delete stale branches on GitLab to avoid MR noise when PRUNE_REMOTE is true.
      - name: OPTIONAL prune all remote branches except default
        if: \${{ vars.PRUNE_REMOTE == 'true' }}
        env:
          REMOTE_HEAD: \${{ steps.rem.outputs.remote_head }}
        shell: bash
        run: |
          set -euo pipefail
          mapfile -t REMOTE < <(git ls-remote --heads gitlab | awk '{print \$2}' | sed 's#refs/heads/##' || true)
          for rb in "\${REMOTE[@]}"; do
            [[ "\$rb" == "\$REMOTE_HEAD" ]] && continue
            echo "Deleting remote branch \$rb on GitLab"
            git push gitlab --delete "\$rb" || true
          done
EOF

echo "Workflow written to \$WORKFLOW_PATH"
if [[ -n "$gitlab_repo" ]]; then
  echo "Remember to set GitHub Actions variable GITLAB_REPO to: $gitlab_repo"
fi
echo "Ensure secret GITLAB_TOKEN is configured."
if [[ "$feature_policy" == "keyword" ]]; then
  echo "Feature branch pushes will mirror only when commit messages include: $keyword_input"
else
  echo "Feature branch pushes will mirror automatically."
fi
