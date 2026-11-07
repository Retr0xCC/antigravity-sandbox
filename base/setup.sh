#!/usr/bin/env bash
set -e

# ========================================================
# Antigravity Sandbox Setup Hook
# Runs once during container creation/initialization
# ========================================================

USER_HOME="${HOME:-/home/vscode}"
MARKER_FILE="${USER_HOME}/.agy_initialized"
WORKSPACE_DIR="${1:-${CONTAINER_WORKSPACE_FOLDER:-$(pwd)}}"

# Verify permissions on persisted volumes without requiring sudo (no-new-privileges safe, VULN-03)
if [ -d "${USER_HOME}/.gemini" ] && [ ! -w "${USER_HOME}/.gemini" ]; then
    echo "==> [antigravity-sandbox] Warning: ${USER_HOME}/.gemini is not writable by current user."
fi

if [ -d "${USER_HOME}/.cache" ] && [ ! -w "${USER_HOME}/.cache" ]; then
    echo "==> [antigravity-sandbox] Warning: ${USER_HOME}/.cache is not writable by current user."
fi

# Ensure cache subdirectories exist
mkdir -p "${USER_HOME}/.cache/uv" "${USER_HOME}/.cache/agy-downloads"

# Orchestrate configuration migration from .gemini-shared to .gemini (SEC-04 / Fix VULN-02)
mkdir -p "${USER_HOME}/.gemini/antigravity-cli" "${USER_HOME}/.gemini/config"

# Notice: config/mcp_config.json is strictly project-isolated and NEVER shared across sandboxes (Fix VULN-02)!
SHARED_CONFIG_FILES=(
    "antigravity-cli/installation_id"
    "antigravity-cli/settings.json"
    "antigravity-cli/jetski_state.pbtxt"
    "antigravity-cli/last_check.timestamp"
)

if [ -d "${USER_HOME}/.gemini-shared" ]; then
    for rel_path in "${SHARED_CONFIG_FILES[@]}"; do
        gemini_path="${USER_HOME}/.gemini/${rel_path}"
        shared_path="${USER_HOME}/.gemini-shared/${rel_path}"

        # Break/convert legacy symlinks from previous vulnerable versions
        if [ -L "${gemini_path}" ]; then
            target_link="$(readlink "${gemini_path}" 2>/dev/null || true)"
            rm -f "${gemini_path}"
            if [ -f "${target_link}" ]; then
                cp -p "${target_link}" "${gemini_path}" 2>/dev/null || true
            elif [ -f "${shared_path}" ]; then
                cp -p "${shared_path}" "${gemini_path}" 2>/dev/null || true
            fi
            chmod u+rw "${gemini_path}" 2>/dev/null || true
        fi

        # If file exists in .gemini-shared and NOT in project volume, copy it (isolated per-project instance)
        # Inherits authentication tokens without exposing the shared volume to writes/tampering
        if [ -f "${shared_path}" ] && [ ! -e "${gemini_path}" ]; then
            echo "==> [antigravity-sandbox] Initializing ${rel_path} from shared config..."
            mkdir -p "$(dirname "${gemini_path}")"
            cp -p "${shared_path}" "${gemini_path}" 2>/dev/null || true
            chmod u+rw "${gemini_path}" 2>/dev/null || true
        fi

        # If .gemini-shared is mounted read-write and empty, populate it from local config (initial onboarding)
        if [ -w "${USER_HOME}/.gemini-shared" ] && [ -f "${gemini_path}" ] && [ ! -e "${shared_path}" ]; then
            mkdir -p "$(dirname "${shared_path}")"
            cp -p "${gemini_path}" "${shared_path}" 2>/dev/null || true
        fi
    done
fi

# Exit early if already initialized
if [ -f "${MARKER_FILE}" ]; then
    # Ensure target workspace directory and worktree gitdir are added to git safe.directory
    if [ -n "${WORKSPACE_DIR}" ] && [ -d "${WORKSPACE_DIR}" ]; then
        git config --global --add safe.directory "${WORKSPACE_DIR}" 2>/dev/null || true
        if [ -f "${WORKSPACE_DIR}/.git" ]; then
            gitdir_ref="$(awk '/^gitdir:[[:space:]]*/ {print $2}' "${WORKSPACE_DIR}/.git" 2>/dev/null || echo "")"
            if [ -n "${gitdir_ref}" ]; then
                git config --global --add safe.directory "${gitdir_ref}" 2>/dev/null || true
                git_common_dir="$(dirname "$(dirname "${gitdir_ref}")")"
                [ -d "${git_common_dir}" ] && git config --global --add safe.directory "${git_common_dir}" 2>/dev/null || true
            fi
        fi
    fi
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
        if [ -f "/usr/local/share/agy-sandbox/install-agy.sh" ]; then
            bash "/usr/local/share/agy-sandbox/install-agy.sh" "${AGY_VERSION}"
        elif [ -f "${SETUP_DIR}/install-agy.sh" ]; then
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
    PATCHER_SCRIPT="/usr/local/share/agy-sandbox/patcher/manager.py"
    if [ -f "${PATCHER_SCRIPT}" ]; then
        python3 "${PATCHER_SCRIPT}" patch cli
    elif [ -d "/home/vscode/agy-manager" ]; then
        python3 "/home/vscode/agy-manager/manager.py" patch cli
    else
        echo "==> [antigravity-sandbox] Error: Built-in patcher not found at ${PATCHER_SCRIPT}." >&2
        exit 1
    fi
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

# Safe git directory configuration scoped strictly to target workspace (Fix F11 & FEAT-01)
if [ -n "${WORKSPACE_DIR}" ] && [ -d "${WORKSPACE_DIR}" ]; then
    git config --global --add safe.directory "${WORKSPACE_DIR}" 2>/dev/null || true
    if [ -f "${WORKSPACE_DIR}/.git" ]; then
        gitdir_ref="$(awk '/^gitdir:[[:space:]]*/ {print $2}' "${WORKSPACE_DIR}/.git" 2>/dev/null || echo "")"
        if [ -n "${gitdir_ref}" ]; then
            git config --global --add safe.directory "${gitdir_ref}" 2>/dev/null || true
            git_common_dir="$(dirname "$(dirname "${gitdir_ref}")")"
            [ -d "${git_common_dir}" ] && git config --global --add safe.directory "${git_common_dir}" 2>/dev/null || true
        fi
    fi
fi

# Clean up forwarded host authentication sockets and copied credentials (Fix F1 & VULN-04)
rm -f /tmp/vscode-git-*.sock \
      /tmp/vscode-ssh-auth-*.sock \
      /tmp/vscode-wayland-*.sock \
      /tmp/user/*/vscode-git-*.sock \
      /tmp/user/*/vscode-ssh-auth-*.sock \
      /tmp/user/*/vscode-wayland-*.sock \
      /home/vscode/.gitconfig \
      /home/vscode/.docker/config.json 2>/dev/null || true

# Mark initialization as complete
touch "${MARKER_FILE}"

echo "==> [antigravity-sandbox] Setup completed successfully."
