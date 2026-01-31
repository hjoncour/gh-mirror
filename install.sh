#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${GH_MIRROR_REPO_OWNER:-hjoncour}"
REPO_NAME="${GH_MIRROR_REPO_NAME:-gh-mirror}"
REPO_REF="${GH_MIRROR_REPO_REF:-main}"
REPO_URL="${GH_MIRROR_REPO:-https://github.com/${REPO_OWNER}/${REPO_NAME}}"
CUSTOM_TARBALL="${GH_MIRROR_TARBALL:-}"
INSTALL_ROOT="${GH_MIRROR_HOME:-$HOME/.gh-mirror}"
BIN_DIR="${GH_MIRROR_BIN:-$HOME/.local/bin}"

echo "ghmirror installer"
if [[ -n "$CUSTOM_TARBALL" ]]; then
  echo "Source repository : $REPO_URL (custom tarball)"
else
  echo "Source repository : $REPO_URL (@ $REPO_REF)"
fi
echo "Install location  : $INSTALL_ROOT"
echo "Binary directory  : $BIN_DIR"

mkdir -p "$INSTALL_ROOT"
mkdir -p "$BIN_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

download_and_extract() {
  local ref="$1" url="$2"
  rm -rf "$TMP_DIR"/*
  echo "Downloading sources from $url"
  if curl -fsSL "$url" -o "$TMP_DIR/source.tar.gz"; then
    tar -xz -C "$TMP_DIR" -f "$TMP_DIR/source.tar.gz"
    local extracted
    extracted="$(find "$TMP_DIR" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
    if [[ -n "$extracted" ]]; then
      SRC_DIR="$extracted"
      REPO_REF="$ref"
      return 0
    fi
  fi
  return 1
}

SRC_DIR=""

if [[ -n "$CUSTOM_TARBALL" ]]; then
  if ! download_and_extract "$REPO_REF" "$CUSTOM_TARBALL"; then
    echo "Error: failed to download custom tarball $CUSTOM_TARBALL" >&2
    exit 1
  fi
else
  refs_to_try=("$REPO_REF")
  if [[ "$REPO_REF" != "main" ]]; then
    refs_to_try+=("main")
  fi
  if [[ "$REPO_REF" != "master" ]]; then
    refs_to_try+=("master")
  fi

  for ref in "${refs_to_try[@]}"; do
    if download_and_extract "$ref" "${REPO_URL}/archive/refs/heads/${ref}.tar.gz"; then
      break
    else
      echo "Warning: could not download ref '$ref' from ${REPO_URL}."
    fi
  done

  if [[ -z "$SRC_DIR" ]]; then
    echo "Error: unable to download repository tarball from $REPO_URL (tried refs: ${refs_to_try[*]})." >&2
    exit 1
  fi
fi

echo "Installing helper scripts into $INSTALL_ROOT..."
rm -rf "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"
cp -R "$SRC_DIR/scripts" "$INSTALL_ROOT/"
cp -R "$SRC_DIR/bin" "$INSTALL_ROOT/"

# Ensure helper scripts are executable.
find "$INSTALL_ROOT" -type f -name "*.sh" -exec chmod +x {} \;

echo "Publishing ghmirror command to $BIN_DIR..."
install -m 0755 "$INSTALL_ROOT/bin/ghmirror" "$BIN_DIR/ghmirror"

echo
echo "ghmirror installed successfully."
echo "Ensure $BIN_DIR is on your PATH. Example:"
echo "  export PATH=\"$BIN_DIR:\$PATH\""
echo
echo "Usage:"
echo "  ghmirror           # run full setup (secrets + workflow) in the current repo"
echo "  ghmirror configure # only configure GitHub secrets/variables"
echo "  ghmirror workflow  # only scaffold/update the workflow file"
echo "  ghmirror --auto    # fully automated setup (requires GITLAB_TOKEN env var)"
