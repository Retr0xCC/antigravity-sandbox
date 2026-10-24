#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity CLI Installer & Version Pinner
# Downloads, extracts, and validates specific or latest
# releases of the Antigravity CLI from GitHub Releases.
# ========================================================

GITHUB_REPO="google-antigravity/antigravity-cli"
TARGET_DIR="${TARGET_DIR:-${HOME}/.local/bin}"
VERSION="${AGY_VERSION:-}"

show_usage() {
  cat <<EOF
Usage: install-agy.sh [OPTIONS] [VERSION] [TARGET_DIR]

Installs a pinned or latest release of Antigravity CLI (agy) into the target directory.

Arguments:
  VERSION             Target version tag (e.g. '1.4.6', 'v1.4.6', or 'latest')
                      [Default: ${VERSION:-<required>}]
  TARGET_DIR          Destination binary directory
                      [Default: ${TARGET_DIR}]

Options:
  -v, --version <tag> Target release version
  -d, --dir <path>    Destination binary directory
  -h, --help          Show this help message

Environment Variables:
  AGY_VERSION         Target version to install
  TARGET_DIR          Destination directory
EOF
}

# Parse CLI arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    -v|--version)
      if [ -z "${2:-}" ]; then
        echo "Fatal: Missing value for $1" >&2
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    -d|--dir)
      if [ -z "${2:-}" ]; then
        echo "Fatal: Missing value for $1" >&2
        exit 1
      fi
      TARGET_DIR="$2"
      shift 2
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      if [ -z "${1:-}" ]; then
        shift
        continue
      fi
      if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
        if [[ ! "$1" =~ ^/ ]] && [[ ! "$1" =~ ^~ ]]; then
          VERSION="$1"
          shift
          continue
        fi
      fi
      if [[ "$1" =~ ^/ ]] || [[ "$1" =~ ^~ ]] || [ -d "$1" ]; then
        TARGET_DIR="$1"
        shift
        continue
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Fatal: No target version specified. Pass version as argument or set AGY_VERSION." >&2
  exit 1
fi

# Expand tilde in TARGET_DIR if needed
if [[ "$TARGET_DIR" == "~" ]] || [[ "$TARGET_DIR" == "~/" ]]; then
  TARGET_DIR="${HOME}"
elif [[ "$TARGET_DIR" =~ ^~/(.*) ]]; then
  TARGET_DIR="${HOME}/${BASH_REMATCH[1]}"
fi

# Detect Operating System
OS="$(uname -s)"
case "$OS" in
  Linux)
    PLATFORM_OS="linux"
    ;;
  Darwin)
    PLATFORM_OS="mac"
    ;;
  *)
    echo "Fatal: Unsupported operating system: ${OS}. Antigravity CLI supports Linux and macOS." >&2
    exit 1
    ;;
esac

# Detect Architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    PLATFORM_ARCH="x64"
    ;;
  aarch64|arm64)
    PLATFORM_ARCH="arm64"
    ;;
  *)
    echo "Fatal: Unsupported architecture: ${ARCH}. Google Antigravity CLI releases only support x86_64/amd64 and arm64/aarch64." >&2
    exit 1
    ;;
esac

# Detect musl libc on Linux
LIBC_SUFFIX=""
if [ "$PLATFORM_OS" = "linux" ]; then
  if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || (command -v ldd >/dev/null 2>&1 && ldd /bin/ls 2>&1 | grep -q musl); then
    LIBC_SUFFIX="_musl"
  fi
fi

ASSET_NAME="agy_cli_${PLATFORM_OS}_${PLATFORM_ARCH}${LIBC_SUFFIX}.tar.gz"
DEST_BIN="${TARGET_DIR}/agy"

echo "==> [install-agy] Target version: ${VERSION}"
echo "==> [install-agy] Target platform: ${PLATFORM_OS}_${PLATFORM_ARCH}${LIBC_SUFFIX}"
echo "==> [install-agy] Installation directory: ${TARGET_DIR}"

mkdir -p "${TARGET_DIR}"

# Handle 'latest' installation
if [ "${VERSION}" = "latest" ]; then
  echo "==> [install-agy] Installing latest version..."
  installed_via_script=false

  # Try official installer script
  if curl -fsSL --compressed https://antigravity.google/cli/install.sh 2>/dev/null | bash -s -- --dir "${TARGET_DIR}" 2>/dev/null; then
    installed_via_script=true
  fi

  if [ "$installed_via_script" = false ]; then
    echo "==> [install-agy] Official installer unavailable, falling back to GitHub Releases latest download..."
    TMP_DIR="$(mktemp -d /tmp/agy-install.XXXXXX)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    LATEST_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/${ASSET_NAME}"
    if ! curl -fSL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${ASSET_NAME}" "${LATEST_URL}"; then
      echo "Fatal: Failed to download latest release asset from ${LATEST_URL}." >&2
      exit 1
    fi

    tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"
    if [ -f "${TMP_DIR}/antigravity" ]; then
      SRC_BIN="${TMP_DIR}/antigravity"
    else
      SRC_BIN="$(find "${TMP_DIR}" -name antigravity -type f -print -quit)"
    fi

    if [ -z "${SRC_BIN}" ] || [ ! -f "${SRC_BIN}" ]; then
      echo "Fatal: Could not locate 'antigravity' binary in the extracted archive." >&2
      exit 1
    fi

    rm -f "${DEST_BIN}" 2>/dev/null || (chmod u+w "${DEST_BIN}" 2>/dev/null && rm -f "${DEST_BIN}") || true
    mv "${SRC_BIN}" "${DEST_BIN}"
    chmod +x "${DEST_BIN}"
  fi
else
  # Specific version pinned
  TMP_DIR="$(mktemp -d /tmp/agy-install.XXXXXX)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  CLEAN_TAG="${VERSION#v}"
  CANDIDATE_TAGS=("${CLEAN_TAG}" "v${CLEAN_TAG}")
  downloaded=false

  for tag in "${CANDIDATE_TAGS[@]}"; do
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${ASSET_NAME}"
    echo "==> [install-agy] Downloading release asset from ${DOWNLOAD_URL}..."
    if curl -fSL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${ASSET_NAME}" "${DOWNLOAD_URL}" 2>/dev/null; then
      downloaded=true
      break
    fi
  done

  if [ "$downloaded" = false ]; then
    echo "Fatal: Failed to download release asset for version '${VERSION}'." >&2
    echo "       Target URL: https://github.com/${GITHUB_REPO}/releases/download/${CLEAN_TAG}/${ASSET_NAME}" >&2
    echo "       Please verify that version '${VERSION}' exists at: https://github.com/${GITHUB_REPO}/releases" >&2
    exit 1
  fi

  echo "==> [install-agy] Extracting ${ASSET_NAME}..."
  tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

  if [ -f "${TMP_DIR}/antigravity" ]; then
    SRC_BIN="${TMP_DIR}/antigravity"
  else
    SRC_BIN="$(find "${TMP_DIR}" -name antigravity -type f -print -quit)"
  fi

  if [ -z "${SRC_BIN}" ] || [ ! -f "${SRC_BIN}" ]; then
    echo "Fatal: Could not locate 'antigravity' binary in the extracted archive." >&2
    exit 1
  fi

  # Replace binary in target directory and set executable bit
  rm -f "${DEST_BIN}" 2>/dev/null || (chmod u+w "${DEST_BIN}" 2>/dev/null && rm -f "${DEST_BIN}") || true
  mv "${SRC_BIN}" "${DEST_BIN}"
  chmod +x "${DEST_BIN}"
fi

# Validation: ensure binary runs and outputs version
if [ ! -f "${DEST_BIN}" ] || [ ! -x "${DEST_BIN}" ]; then
  echo "Fatal: Installed executable not found or not executable at ${DEST_BIN}." >&2
  exit 1
fi

INSTALLED_VERSION="$("${DEST_BIN}" --version 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
if [ -z "${INSTALLED_VERSION}" ]; then
  echo "Fatal: Installed binary '${DEST_BIN}' failed to execute or return version." >&2
  exit 1
fi

if [ "${VERSION}" != "latest" ]; then
  EXPECTED_VERSION="${VERSION#v}"
  if [ "${INSTALLED_VERSION}" != "${EXPECTED_VERSION}" ]; then
    echo "Fatal: Version mismatch! Expected '${EXPECTED_VERSION}', but installed binary reports '${INSTALLED_VERSION}'." >&2
    exit 1
  fi
fi

echo "==> [install-agy] Success! Installed agy version: ${INSTALLED_VERSION} -> ${DEST_BIN}"
