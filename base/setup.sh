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

# Target directory for agy-manager outside of workspace projects
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

# Lock down agy executable permissions to prevent auto-updates and overwrites
echo "==> Locking Antigravity CLI executable permissions..."
for agy_bin in "/home/vscode/.antigravity/bin/agy" "/home/vscode/.local/bin/agy"; do
    if [ -f "${agy_bin}" ]; then
        chmod 555 "${agy_bin}" 2>/dev/null || true
    fi
done

# Safe git directory configuration for container workspaces
git config --global --add safe.directory "${PWD}" 2>/dev/null || true
git config --global --add safe.directory "*" 2>/dev/null || true

# Mark initialization as complete
touch "${MARKER_FILE}"

echo "==> [antigravity-sandbox] Setup completed successfully."
