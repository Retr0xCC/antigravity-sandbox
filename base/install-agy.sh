#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity CLI Installer & Version Pinner
# Downloads, extracts, and validates specific or latest
# releases of the Antigravity CLI from GitHub Releases.
# ========================================================

GITHUB_REPO="${GITHUB_REPO:-google-antigravity/antigravity-cli}"
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://github.com}"
TARGET_DIR="${TARGET_DIR:-${HOME}/.local/bin}"
VERSION="${AGY_VERSION:-}"
AGY_CACHE_DIR="${AGY_CACHE_DIR:-${HOME}/.cache/agy-downloads}"

# Antigravity eligibility patcher (QNIX-Dev) supply chain pinning (SEC-03)
PATCHER_REPO="${PATCHER_REPO:-https://github.com/QNIX-Dev/eligibility-antigravity-patcher.git}"
PATCHER_COMMIT="${PATCHER_COMMIT:-90498f50353d414232f593dffe88899bc80b6312}"
EXPECTED_SHA256="${EXPECTED_SHA256:-${AGY_SHA256:-}}"

# Official release SHA256 checksums for cryptographic supply chain verification (SEC-03, SEC-04 / VULN-02)
declare -A KNOWN_RELEASE_SHA256=(
  # 1.5.3 official releases
  ["1.5.3_agy_cli_linux_x64.tar.gz"]="1b4850599cce73a17f94ffb422df3bf9531531b77dbddc40c1a435e0c2c16807"
  ["1.5.3_agy_cli_linux_x64_musl.tar.gz"]="0b8c01c7ae634b99bc5b82e523358da0261ac664216ab027dd8f16eca6ed4783"
  ["1.5.3_agy_cli_linux_arm64.tar.gz"]="2d50060c7b1327995e5c81ec58829c91c2564ebb9fec165d3f9f1325ec188675"
  ["1.5.3_agy_cli_linux_arm64_musl.tar.gz"]="48a16d1fbe92d5978bb460657b5d6d4b60e532c8d369f30c6f22eb602bcf764e"
  ["1.5.3_agy_cli_mac_x64.tar.gz"]="f0470eac7fb2f98886e1210457531bf1883c439ffa9e99d730388a1ff3dfeef5"
  ["1.5.3_agy_cli_mac_arm64.tar.gz"]="b47034e1367fc3c9f2856f1e1ae30bf12819a7213821ba3cce2123b090f2df8a"
)

verify_archive_checksum() {
  local archive_path="$1"
  local version="$2"
  local asset_name="$3"
  local expected_hash="${EXPECTED_SHA256:-${AGY_SHA256:-}}"

  local clean_v="${version#v}"
  if [ -z "${expected_hash}" ]; then
    local key="${clean_v}_${asset_name}"
    expected_hash="${KNOWN_RELEASE_SHA256[${key}]:-}"
  fi

  if [ -n "${expected_hash}" ]; then
    echo "==> [install-agy] Verifying cryptographic SHA256 integrity..."
    local actual_hash
    actual_hash="$(sha256sum "${archive_path}" | awk '{print $1}')"
    if [ "${actual_hash}" != "${expected_hash}" ]; then
      echo "Fatal: SHA256 checksum mismatch for ${archive_path}!" >&2
      echo "       Expected: ${expected_hash}" >&2
      echo "       Actual:   ${actual_hash}" >&2
      echo "       Security Alert: Cached or downloaded asset may be corrupted or poisoned! Rejecting." >&2
      rm -f "${archive_path}" 2>/dev/null || true
      return 1
    fi
    echo "==> [install-agy] ✓ SHA256 checksum verified: ${actual_hash:0:16}..."
    return 0
  else
    # For custom versions, try querying GitHub API digest if curl and jq are available
    if [ "${version}" != "latest" ] && command -v jq >/dev/null 2>&1; then
      local clean_v="${version#v}"
      local api_digest=""
      for tag in "${version}" "v${clean_v}" "${clean_v}"; do
        local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}"
        api_digest=$(curl -fsSL "${api_url}" 2>/dev/null | jq -r --arg n "${asset_name}" '.assets[]? | select(.name == $n) | .digest // empty' | sed 's/^sha256://' || true)
        [ -n "${api_digest}" ] && break
      done

      if [ -n "${api_digest}" ]; then
        echo "==> [install-agy] Verifying against GitHub Release API digest..."
        local actual_hash
        actual_hash="$(sha256sum "${archive_path}" | awk '{print $1}')"
        if [ "${actual_hash}" != "${api_digest}" ]; then
          echo "Fatal: SHA256 mismatch against GitHub API digest! Expected: ${api_digest}, Actual: ${actual_hash}" >&2
          rm -f "${archive_path}" 2>/dev/null || true
          return 1
        fi
        echo "==> [install-agy] ✓ SHA256 checksum verified via GitHub API: ${actual_hash:0:16}..."
        return 0
      fi
    fi

    # Fail-closed check if SHA256 verification is required (e.g. pinned or explicit)
    if [ "${REQUIRE_SHA256:-false}" = "true" ] || [ "${AGY_PINNED:-true}" = "true" ]; then
      if [ "${version}" != "latest" ]; then
        echo "Fatal: Cryptographic SHA256 digest could not be verified for pinned version '${version}' (${asset_name}). Fail-closed (OPEN-02)." >&2
        rm -f "${archive_path}" 2>/dev/null || true
        return 1
      fi
    fi
    echo "==> [install-agy] Notice: No cryptographic SHA256 registered for ${version} (${asset_name})."
    return 0
  fi
}

show_usage() {
  cat <<EOF
Usage: install-agy.sh [OPTIONS] [VERSION] [TARGET_DIR]

Installs a pinned or latest release of Antigravity CLI (agy) into the target directory.

Arguments:
  VERSION             Target version tag (e.g. '1.5.3', 'v1.5.3', or 'latest')
                      [Default: ${VERSION:-<required>}]
  TARGET_DIR          Destination binary directory
                      [Default: ${TARGET_DIR}]

Options:
  -v, --version <tag> Target release version
  --sha256 <hash>     Expected archive SHA256 checksum
  -d, --dir <path>    Destination binary directory
  -h, --help          Show this help message

Environment Variables:
  AGY_VERSION         Target version to install
  TARGET_DIR          Destination directory
  AGY_CACHE_DIR       Shared archive cache directory
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
    --sha256)
      if [ -z "${2:-}" ]; then
        echo "Fatal: Missing value for $1" >&2
        exit 1
      fi
      EXPECTED_SHA256="$2"
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
mkdir -p "${AGY_CACHE_DIR}" 2>/dev/null || true

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
    LATEST_CACHE="${AGY_CACHE_DIR}/latest_${ASSET_NAME}"
    trap 'rm -rf "${TMP_DIR}"; rm -f "${LATEST_CACHE}.tmp.$$" 2>/dev/null || true' EXIT

    LATEST_URL="${GITHUB_BASE_URL:-https://github.com}/${GITHUB_REPO}/releases/latest/download/${ASSET_NAME}"
    TEMP_DOWNLOAD="${LATEST_CACHE}.tmp.$$"

    # Default: skip caching for latest to ensure freshness, but allow fallback if offline
    if curl -fSL --retry 3 --retry-delay 2 -o "${TEMP_DOWNLOAD}" "${LATEST_URL}" 2>/dev/null && [ -s "${TEMP_DOWNLOAD}" ] && tar -tzf "${TEMP_DOWNLOAD}" >/dev/null 2>&1 && verify_archive_checksum "${TEMP_DOWNLOAD}" "latest" "${ASSET_NAME}"; then
      mv -f "${TEMP_DOWNLOAD}" "${LATEST_CACHE}"
      tar -xzf "${LATEST_CACHE}" -C "${TMP_DIR}"
    elif [ -f "${LATEST_CACHE}" ] && [ -s "${LATEST_CACHE}" ] && tar -tzf "${LATEST_CACHE}" >/dev/null 2>&1 && verify_archive_checksum "${LATEST_CACHE}" "latest" "${ASSET_NAME}"; then
      echo "==> [install-agy] Network unavailable. Found valid cached latest asset: ${LATEST_CACHE}. Falling back to cache."
      tar -xzf "${LATEST_CACHE}" -C "${TMP_DIR}"
    else
      rm -f "${TEMP_DOWNLOAD}" 2>/dev/null || true
      echo "Fatal: Failed to download latest release asset from ${LATEST_URL} and no valid cache found." >&2
      exit 1
    fi

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
  CACHED_ASSET="${AGY_CACHE_DIR}/${VERSION}_${ASSET_NAME}"
  trap 'rm -rf "${TMP_DIR}"; rm -f "${CACHED_ASSET}.tmp.$$" 2>/dev/null || true' EXIT

  CLEAN_TAG="${VERSION#v}"
  if [ ! -f "${CACHED_ASSET}" ] && [ -f "${AGY_CACHE_DIR}/${CLEAN_TAG}_${ASSET_NAME}" ]; then
    CACHED_ASSET="${AGY_CACHE_DIR}/${CLEAN_TAG}_${ASSET_NAME}"
  fi

  cached_valid=false
  if [ -f "${CACHED_ASSET}" ] && [ -s "${CACHED_ASSET}" ]; then
    if tar -tzf "${CACHED_ASSET}" >/dev/null 2>&1; then
      if verify_archive_checksum "${CACHED_ASSET}" "${VERSION}" "${ASSET_NAME}"; then
        cached_valid=true
      else
        echo "==> [install-agy] Warning: Cached asset failed SHA256 verification (corrupted or poisoned). Re-downloading..."
        rm -f "${CACHED_ASSET}" 2>/dev/null || true
      fi
    else
      echo "==> [install-agy] Warning: Corrupted cache detected for ${CACHED_ASSET}. Re-downloading..."
      rm -f "${CACHED_ASSET}" 2>/dev/null || true
    fi
  fi

  if [ "${cached_valid}" = "true" ]; then
    echo "==> [install-agy] Found valid cached asset: ${CACHED_ASSET}. Skipping download."
  else
    CANDIDATE_TAGS=("${CLEAN_TAG}" "v${CLEAN_TAG}")
    downloaded=false

    for tag in "${CANDIDATE_TAGS[@]}"; do
      DOWNLOAD_URL="${GITHUB_BASE_URL:-https://github.com}/${GITHUB_REPO}/releases/download/${tag}/${ASSET_NAME}"
      echo "==> [install-agy] Downloading release asset from ${DOWNLOAD_URL}..."
      TEMP_DOWNLOAD="${CACHED_ASSET}.tmp.$$"
      rm -f "${TEMP_DOWNLOAD}" 2>/dev/null || true
      if curl -fSL --retry 3 --retry-delay 2 -o "${TEMP_DOWNLOAD}" "${DOWNLOAD_URL}" 2>/dev/null; then
        if [ -s "${TEMP_DOWNLOAD}" ] && tar -tzf "${TEMP_DOWNLOAD}" >/dev/null 2>&1 && verify_archive_checksum "${TEMP_DOWNLOAD}" "${VERSION}" "${ASSET_NAME}"; then
          mv -f "${TEMP_DOWNLOAD}" "${CACHED_ASSET}"
          downloaded=true
          break
        else
          rm -f "${TEMP_DOWNLOAD}" 2>/dev/null || true
        fi
      else
        rm -f "${TEMP_DOWNLOAD}" 2>/dev/null || true
      fi
    done

    if [ "$downloaded" = false ]; then
      echo "Fatal: Failed to download release asset for version '${VERSION}'." >&2
      echo "       Target URL: https://github.com/${GITHUB_REPO}/releases/download/${CLEAN_TAG}/${ASSET_NAME}" >&2
      echo "       Please verify that version '${VERSION}' exists at: https://github.com/${GITHUB_REPO}/releases" >&2
      exit 1
    fi
  fi

  echo "==> [install-agy] Extracting ${ASSET_NAME}..."
  tar -xzf "${CACHED_ASSET}" -C "${TMP_DIR}"

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
