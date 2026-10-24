#!/usr/bin/env bash
set -e

# ========================================================
# Antigravity Sandbox Setup Hook
# Runs once during container creation/initialization
# ========================================================

MARKER_FILE="/home/vscode/.agy_initialized"

# Fix permissions on persisted volume if needed
if [ -d "/home/vscode/.gemini" ]; then
    sudo chown -R vscode:vscode /home/vscode/.gemini 2>/dev/null || true
fi

# Exit early if already initialized
if [ -f "${MARKER_FILE}" ]; then
    echo "==> [antigravity-sandbox] Container already initialized. Skipping setup."
    exit 0
fi

echo "==> [antigravity-sandbox] Performing one-time initialization..."

# Verify or pin requested CLI version if specified
if [ -n "${AGY_VERSION:-}" ] && [ "${AGY_VERSION}" != "latest" ]; then
    CURRENT_VERSION=""
    if command -v agy >/dev/null 2>&1; then
        CURRENT_VERSION="$(agy --version 2>/dev/null || true)"
    fi
    WANTED_VERSION="${AGY_VERSION#v}"
    if [ "${CURRENT_VERSION}" != "${WANTED_VERSION}" ]; then
        echo "==> [antigravity-sandbox] Pinned AGY_VERSION=${AGY_VERSION} requested (current: ${CURRENT_VERSION:-none}). Installing..."
        for agy_bin in "/home/vscode/.antigravity/bin/agy" "/home/vscode/.local/bin/agy"; do
            [ -f "${agy_bin}" ] && chmod u+w "${agy_bin}" 2>/dev/null || true
        done
        SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "${SETUP_DIR}/install-agy.sh" ]; then
            bash "${SETUP_DIR}/install-agy.sh" "${AGY_VERSION}"
        elif [ -f "/tmp/install-agy.sh" ]; then
            bash "/tmp/install-agy.sh" "${AGY_VERSION}"
        fi
    fi
fi

# Optional Antigravity CLI patcher (QNIX-Dev)
AGY_PATCH="${AGY_PATCH:-}"
if [ "${AGY_PATCH}" = "true" ] || [ "${AGY_PATCH}" = "1" ] || [ "${AGY_PATCH}" = "yes" ]; then
    echo "==> [antigravity-sandbox] Applying Antigravity CLI patch (QNIX-Dev/eligibility-antigravity-patcher)..."
    MANAGER_DIR="/home/vscode/agy-manager"
    REPO_URL="https://github.com/QNIX-Dev/eligibility-antigravity-patcher.git"

    if [ ! -d "$MANAGER_DIR" ]; then
        echo "==> Cloning agy-manager..."
        git clone "$REPO_URL" "$MANAGER_DIR"
    fi

    cd "$MANAGER_DIR"
    echo "==> Installing patcher dependencies with uv..."
    [ -d ".venv" ] || uv venv
    uv pip install -q -r requirements.txt

    echo "==> Applying Antigravity CLI patch..."
    uv run python manager.py patch cli
else
    echo "==> [antigravity-sandbox] Skipping Antigravity CLI patch (AGY_PATCH=${AGY_PATCH}). Using clean official binary."
fi

# Executable permissions and auto-update lockdown
if [ -n "${AGY_VERSION:-}" ] && [ "${AGY_VERSION}" != "latest" ]; then
    echo "==> Locking Antigravity CLI executable permissions (chmod 555 for pinned version ${AGY_VERSION})..."
    for agy_bin in "/home/vscode/.antigravity/bin/agy" "/home/vscode/.local/bin/agy"; do
        if [ -f "${agy_bin}" ]; then
            chmod 555 "${agy_bin}" 2>/dev/null || true
        fi
    done
    # Ensure auto-update is disabled for pinned version
    if ! grep -q "AGY_CLI_DISABLE_AUTO_UPDATE" /home/vscode/.bashrc 2>/dev/null; then
        echo "export AGY_CLI_DISABLE_AUTO_UPDATE=true" >> /home/vscode/.bashrc
    fi
else
    echo "==> Setting standard executable permissions (chmod 755 for latest version with auto-updates enabled)..."
    for agy_bin in "/home/vscode/.antigravity/bin/agy" "/home/vscode/.local/bin/agy"; do
        if [ -f "${agy_bin}" ]; then
            chmod 755 "${agy_bin}" 2>/dev/null || true
        fi
    done
    # Remove auto-update disable export from ~/.bashrc if present
    if [ -f /home/vscode/.bashrc ]; then
        sed -i '/AGY_CLI_DISABLE_AUTO_UPDATE/d' /home/vscode/.bashrc 2>/dev/null || true
    fi
fi

# Safe git directory configuration for container workspaces
git config --global --add safe.directory "${PWD}" 2>/dev/null || true
git config --global --add safe.directory "*" 2>/dev/null || true

# Mark initialization as complete
touch "${MARKER_FILE}"

echo "==> [antigravity-sandbox] Setup completed successfully."
