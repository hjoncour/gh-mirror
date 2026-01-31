# gh-mirror

Automation helpers for mirroring a GitHub repository to GitLab. The toolkit
provides:

- `ghmirror`: a CLI that guides you through configuring GitHub secrets,
  GitLab credentials, and the GitHub Actions workflow that performs the mirror.
- `install.sh`: a curl-friendly installer that publishes `ghmirror` onto your
  `PATH` so the tool can be launched from any repository.

## Features

- **Auto-detect settings** from your GitHub repository (name, visibility, description)
- **Auto-create GitLab project** with matching settings via GitLab API
- **Configure protected branches** to allow force push automatically
- **Full initial mirror** pushes all branches, tags, and history
- **Automatic mirroring** via GitHub Actions on every push
- **Non-interactive mode** (`--auto`) for CI/CD pipelines

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com) authenticated with rights to
  manage repo secrets/variables.
- [GitLab CLI (`glab`)](https://gitlab.com/gitlab-org/cli) authenticated with a
  PAT that can create projects (optional, for manual project creation).
- GitLab Personal Access Token with `api` scope (for auto project creation and
  protected branch configuration).
- Bash, curl, and tar (available on macOS and most Linux distributions).

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/hjoncour/gh-mirror/master/install.sh | bash
```

Defaults:

- Installs the helper scripts into `~/.gh-mirror`.
- Publishes `ghmirror` to `~/.local/bin`.

If `~/.local/bin` is not already on your `PATH`, add it (for example):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Custom installation options

Override installer behaviour with environment variables:

| Variable               | Purpose                                              | Default                               |
| ---------------------- | ---------------------------------------------------- | ------------------------------------- |
| `GH_MIRROR_REPO_OWNER` | Repository owner                                     | `hjoncour`                            |
| `GH_MIRROR_REPO_NAME`  | Repository name                                      | `gh-mirror`                           |
| `GH_MIRROR_REPO_REF`   | Branch/ref to download                               | `main` (falls back to `master` etc.)  |
| `GH_MIRROR_HOME`       | Directory where scripts are staged                   | `~/.gh-mirror`                        |
| `GH_MIRROR_BIN`        | Directory where the `ghmirror` executable is copied  | `~/.local/bin`                        |
| `GH_MIRROR_TARBALL`    | Custom tarball URL (skips ref detection)             | _blank_                               |

Example (install into `/usr/local/bin`):

```bash
GH_MIRROR_BIN=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/hjoncour/gh-mirror/master/install.sh | sudo bash
```

## Usage

### Interactive Setup (Recommended for first-time)

From the GitHub repository you want to mirror:

```bash
ghmirror
```

The command walks through:

1. Creating or updating GitHub Actions secrets/variables (`GITLAB_TOKEN`,
   `GITLAB_REPO`).
2. Optional creation of the target GitLab project via `glab`.
3. Generating the `mirror-to-gitlab.yaml` workflow with your chosen feature
   branch policy (mirror every push vs. keyword-triggered pushes).

### Fully Automated Setup

For CI/CD pipelines or scripted deployments:

```bash
# Set required environment variables
export GITLAB_TOKEN="glpat-xxxxxxxxxxxx"

# Run fully automated setup (creates GitLab project, configures secrets, generates workflow)
ghmirror --auto

# Or specify a different GitLab namespace
ghmirror --auto --namespace my-gitlab-group

# Or use a self-hosted GitLab instance
ghmirror --auto --host gitlab.mycompany.com --namespace team
```

### Commands

| Command                  | Description                                           |
| ------------------------ | ----------------------------------------------------- |
| `ghmirror`               | Full setup (secrets + GitLab project + workflow)      |
| `ghmirror configure`     | Only configure GitHub secrets/variables               |
| `ghmirror workflow`      | Only generate the GitHub Actions workflow             |
| `ghmirror gitlab-setup`  | Only create/configure the GitLab project              |
| `ghmirror init`          | Push all branches and tags to GitLab now              |
| `ghmirror help`          | Show usage information                                |

### Options

| Option              | Description                                           |
| ------------------- | ----------------------------------------------------- |
| `--auto`, `-y`      | Non-interactive mode (auto-detect settings)           |
| `--token TOKEN`     | GitLab personal access token                          |
| `--namespace NS`    | GitLab namespace/group (default: same as GitHub owner)|
| `--host HOST`       | GitLab host (default: gitlab.com)                     |

### Environment Variables

| Variable           | Description                                            |
| ------------------ | ------------------------------------------------------ |
| `GITLAB_TOKEN`     | GitLab personal access token (required for --auto)     |
| `GITLAB_NAMESPACE` | Target GitLab namespace (group or username)            |
| `GITLAB_HOST`      | GitLab instance hostname (default: gitlab.com)         |

## How It Works

### Initial Setup

1. **Detects GitHub repo settings** (name, visibility, description, default branch)
2. **Creates GitLab project** with matching settings via GitLab API
3. **Configures protected branches** to allow force push
4. **Sets GitHub secrets** (`GITLAB_TOKEN`) and variables (`GITLAB_REPO`)
5. **Generates GitHub Actions workflow** for automatic mirroring
6. **Performs initial mirror** pushing all branches, tags, and full history

### Ongoing Mirroring

The GitHub Actions workflow triggers on every push:

- **Default branch pushes**: Always mirrored (force push to keep GitLab in sync)
- **Feature branch pushes**: Mirrored based on your policy:
  - `always`: Every push to any branch mirrors to GitLab
  - `keyword`: Only pushes with a keyword in the commit message mirror
- **Tags**: Always force-pushed to keep releases in sync

### Example Workflow

```yaml
# .github/workflows/mirror-to-gitlab.yaml (generated)
name: Mirror to GitLab

on:
  push:
    branches: ["**"]

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Push to GitLab
        run: |
          git remote add gitlab "https://oauth2:${{ secrets.GITLAB_TOKEN }}@${{ vars.GITLAB_REPO }}"
          git push --force --all gitlab
          git push --force --tags gitlab
```

## Updating

Re-run the installer. It will download the latest scripts and overwrite the
existing `ghmirror` binary.

## Uninstall

```bash
rm -rf ~/.gh-mirror
rm -f ~/.local/bin/ghmirror
```

Remove any `PATH` additions you created during installation.

## Troubleshooting

### "Permission denied" on GitLab push

Ensure your GitLab token has `api` and `write_repository` scopes. For protected
branches, the tool automatically configures force push permissions, but you may
need to verify this in GitLab Settings > Repository > Protected branches.

### "Project not found" errors

Check that:
1. The GitLab namespace exists and you have access to it
2. Your token has permission to create projects in that namespace
3. On GitLab.com, you cannot create top-level groups via API (only subgroups)

### GitHub Actions workflow not triggering

Verify that:
1. The workflow file exists at `.github/workflows/mirror-to-gitlab.yaml`
2. `GITLAB_TOKEN` secret is set in GitHub repo settings
3. `GITLAB_REPO` variable is set in GitHub repo settings

## License

GNU General Public License v2.0
