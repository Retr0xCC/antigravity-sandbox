#!/usr/bin/env bash
set -e

# ========================================================
# Antigravity Sandbox Setup Hook
# Runs once during container creation/initialization
# ========================================================

USER_HOME="${HOME:-/home/vscode}"
MARKER_FILE="${USER_HOME}/.agy_initialized"
WORKSPACE_DIR="${1:-${CONTAINER_WORKSPACE_FOLDER:-$(pwd)}}"

# Verify permissions on persisted volumes without requiring sudo (safe under no-new-privileges)
if [ -d "${USER_HOME}/.gemini" ] && [ ! -w "${USER_HOME}/.gemini" ]; then
    echo "==> [antigravity-sandbox] Warning: ${USER_HOME}/.gemini is not writable by current user."
fi

if [ -d "${USER_HOME}/.cache" ] && [ ! -w "${USER_HOME}/.cache" ]; then
    echo "==> [antigravity-sandbox] Warning: ${USER_HOME}/.cache is not writable by current user."
fi

# Ensure cache subdirectories exist
mkdir -p "${USER_HOME}/.cache/uv" "${USER_HOME}/.cache/agy-downloads"

# XDG Git configuration file for sandbox-managed safe.directory (persists without conflicting with host gitconfig)
GIT_CONFIG_DIR="${USER_HOME}/.config/git"
mkdir -p "${GIT_CONFIG_DIR}"
GIT_XDG_CONFIG="${GIT_CONFIG_DIR}/config"

# Install agy-sync-auth utility for onboarding and syncing tokens to shared volume
cat << 'EOF_SYNC' > /tmp/agy-sync-auth
#!/usr/bin/env bash
set -e
USER_HOME="${HOME:-/home/vscode}"
SHARED_DIR="${USER_HOME}/.gemini-shared"
LOCAL_DIR="${USER_HOME}/.gemini"

if [ ! -d "${SHARED_DIR}" ]; then
    echo "==> [antigravity-sandbox] Error: Shared directory ${SHARED_DIR} does not exist." >&2
    echo "    Start the sandbox without '--shared-config isolated' to enable shared configuration." >&2
    exit 1
fi

if [ ! -w "${SHARED_DIR}" ]; then
    echo "==> [antigravity-sandbox] Error: ${SHARED_DIR} is mounted read-only." >&2
    echo "    To onboard new authentication tokens into the global volume, run the sandbox with:" >&2
    echo "      agy-sandbox <target_dir> --shared-config rw" >&2
    exit 1
fi

echo "==> [antigravity-sandbox] Syncing authentication tokens to ${SHARED_DIR}..."
FILES_SYNCED=0
for rel in "antigravity-cli/installation_id" "antigravity-cli/settings.json" "antigravity-cli/jetski_state.pbtxt" "antigravity-cli/last_check.timestamp"; do
    src="${LOCAL_DIR}/${rel}"
    dst="${SHARED_DIR}/${rel}"
    if [ -f "${src}" ]; then
        mkdir -p "$(dirname "${dst}")"
        cp -p "${src}" "${dst}"
        echo "  ✓ Synced ${rel}"
        FILES_SYNCED=$((FILES_SYNCED + 1))
    fi
done

if [ ${FILES_SYNCED} -eq 0 ]; then
    echo "==> [antigravity-sandbox] Warning: No authentication files found in ${LOCAL_DIR}/antigravity-cli/ to sync."
    echo "    Log into Antigravity ('agy auth' or run agy) first, then re-run 'agy-sync-auth'."
else
    echo "==> [antigravity-sandbox] Successfully synced ${FILES_SYNCED} configuration file(s) to agy-shared-config volume."
fi
EOF_SYNC
chmod 755 /tmp/agy-sync-auth
if [ -w /usr/local/bin ]; then
    cp -p /tmp/agy-sync-auth /usr/local/bin/agy-sync-auth 2>/dev/null || true
fi
mkdir -p "${USER_HOME}/.local/bin"
cp -p /tmp/agy-sync-auth "${USER_HOME}/.local/bin/agy-sync-auth" 2>/dev/null || true
rm -f /tmp/agy-sync-auth

# Orchestrate configuration migration from .gemini-shared to .gemini via Copy-on-Initialize
mkdir -p "${USER_HOME}/.gemini/antigravity-cli" "${USER_HOME}/.gemini/config"

# Break legacy symlinks for mcp_config.json if present from previous configurations
if [ -L "${USER_HOME}/.gemini/config/mcp_config.json" ]; then
    rm -f "${USER_HOME}/.gemini/config/mcp_config.json"
fi

# Notice: config/mcp_config.json is strictly project-isolated and NEVER shared across sandboxes!
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

        # If .gemini-shared is mounted read-write, synchronize local tokens to shared volume (initial onboarding / update)
        if [ -w "${USER_HOME}/.gemini-shared" ] && [ -f "${gemini_path}" ]; then
            mkdir -p "$(dirname "${shared_path}")"
            cp -p "${gemini_path}" "${shared_path}" 2>/dev/null || true
        fi
    done
fi

# Exit early if already initialized
if [ -f "${MARKER_FILE}" ]; then
    # Ensure target workspace directory and worktree gitdir are added to git safe.directory
    if [ -n "${WORKSPACE_DIR}" ] && [ -d "${WORKSPACE_DIR}" ]; then
        git config --file "${GIT_XDG_CONFIG}" --add safe.directory "${WORKSPACE_DIR}" 2>/dev/null || true
        if [ -f "${WORKSPACE_DIR}/.git" ]; then
            gitdir_ref="$(awk '/^gitdir:[[:space:]]*/ {print $2}' "${WORKSPACE_DIR}/.git" 2>/dev/null || echo "")"
            if [ -n "${gitdir_ref}" ]; then
                git config --file "${GIT_XDG_CONFIG}" --add safe.directory "${gitdir_ref}" 2>/dev/null || true
                git_common_dir="$(dirname "$(dirname "${gitdir_ref}")")"
                [ -d "${git_common_dir}" ] && git config --file "${GIT_XDG_CONFIG}" --add safe.directory "${git_common_dir}" 2>/dev/null || true
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
        fi
    fi
fi

# Optional Antigravity CLI patcher (QNIX-Dev)
AGY_PATCH="${AGY_PATCH:-}"
if [ "${AGY_PATCH}" = "true" ] || [ "${AGY_PATCH}" = "1" ] || [ "${AGY_PATCH}" = "yes" ]; then
    echo "==> [antigravity-sandbox] Applying Antigravity CLI patch (QNIX-Dev/eligibility-antigravity-patcher)..."
    chmod u+w "${USER_HOME}/.local/bin/agy" "/home/vscode/.antigravity/bin/agy" 2>/dev/null || true
    PATCHER_SCRIPT="/usr/local/share/agy-sandbox/patcher/manager.py"
    if [ -f "${PATCHER_SCRIPT}" ]; then
        python3 "${PATCHER_SCRIPT}" patch cli
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
    # Ensure auto-update is disabled for pinned version across interactive and non-interactive sessions
    for prof in "${USER_HOME}/.profile" "${USER_HOME}/.bashrc"; do
        if [ -f "${prof}" ] && ! grep -q "AGY_CLI_DISABLE_AUTO_UPDATE" "${prof}" 2>/dev/null; then
            sed -i '1s/^/export AGY_CLI_DISABLE_AUTO_UPDATE=true\n/' "${prof}" 2>/dev/null || echo "export AGY_CLI_DISABLE_AUTO_UPDATE=true" >> "${prof}"
        fi
    done
else
    echo "==> Setting standard executable permissions (chmod 755 for latest version with auto-updates enabled)..."
    for agy_bin in "/home/vscode/.antigravity/bin/agy" "/home/vscode/.local/bin/agy"; do
        if [ -f "${agy_bin}" ]; then
            chmod 755 "${agy_bin}" 2>/dev/null || true
        fi
    done
    # Remove auto-update disable export from shell profiles if present
    for prof in "${USER_HOME}/.profile" "${USER_HOME}/.bashrc"; do
        [ -f "${prof}" ] && sed -i '/AGY_CLI_DISABLE_AUTO_UPDATE/d' "${prof}" 2>/dev/null || true
    done
fi

# Safe git directory configuration scoped strictly to target workspace and worktree gitdir
if [ -n "${WORKSPACE_DIR}" ] && [ -d "${WORKSPACE_DIR}" ]; then
    git config --file "${GIT_XDG_CONFIG}" --add safe.directory "${WORKSPACE_DIR}" 2>/dev/null || true
    if [ -f "${WORKSPACE_DIR}/.git" ]; then
        gitdir_ref="$(awk '/^gitdir:[[:space:]]*/ {print $2}' "${WORKSPACE_DIR}/.git" 2>/dev/null || echo "")"
        if [ -n "${gitdir_ref}" ]; then
            git config --file "${GIT_XDG_CONFIG}" --add safe.directory "${gitdir_ref}" 2>/dev/null || true
            git_common_dir="$(dirname "$(dirname "${gitdir_ref}")")"
            [ -d "${git_common_dir}" ] && git config --file "${GIT_XDG_CONFIG}" --add safe.directory "${git_common_dir}" 2>/dev/null || true
        fi
    fi
fi

# Clean up forwarded host authentication sockets, runtime symlinks, and credentials
# Note: Never execute 'chmod 000' on forwarded sockets as bind mounts share host inodes!
rm -f /tmp/vscode-git-*.sock \
      /tmp/vscode-ssh-auth-*.sock \
      /tmp/user/*/vscode-git-*.sock \
      /tmp/user/*/vscode-ssh-auth-*.sock \
      /tmp/vscode-wayland-*.sock \
      /tmp/user/*/vscode-wayland-*.sock \
      /tmp/user/*/wayland-* 2>/dev/null || true

rm -rf "${USER_HOME}/.gnupg"/S.gpg-agent* /tmp/vscode-gpg-agent* /tmp/user/*/vscode-gpg-agent* 2>/dev/null || true

rm -f "${USER_HOME}/.docker/config.json" 2>/dev/null || true

# Neutralize Wayland display variable to prevent container GUI access
for prof in "${USER_HOME}/.profile" "${USER_HOME}/.bashrc"; do
    if [ -f "${prof}" ] && ! grep -q "WAYLAND_DISPLAY" "${prof}" 2>/dev/null; then
        cat << 'EOF' >> "${prof}"

# Neutralize Wayland display variable to prevent container GUI access
unset WAYLAND_DISPLAY
export WAYLAND_DISPLAY=""
EOF
    fi
done

# Whitelist-sanitize copied .gitconfig: strips [credential] / [http] subsections while preserving git commit identity
if [ -f "${USER_HOME}/.gitconfig" ]; then
    GIT_NAME="$(git config --file "${USER_HOME}/.gitconfig" user.name 2>/dev/null || true)"
    GIT_EMAIL="$(git config --file "${USER_HOME}/.gitconfig" user.email 2>/dev/null || true)"
    GIT_BRANCH="$(git config --file "${USER_HOME}/.gitconfig" init.defaultBranch 2>/dev/null || true)"
    rm -f "${USER_HOME}/.gitconfig"
    [ -n "${GIT_NAME}" ] && git config --file "${USER_HOME}/.gitconfig" user.name "${GIT_NAME}" 2>/dev/null || true
    [ -n "${GIT_EMAIL}" ] && git config --file "${USER_HOME}/.gitconfig" user.email "${GIT_EMAIL}" 2>/dev/null || true
    [ -n "${GIT_BRANCH}" ] && git config --file "${USER_HOME}/.gitconfig" init.defaultBranch "${GIT_BRANCH}" 2>/dev/null || true
fi

# Mark initialization as complete
touch "${MARKER_FILE}"

echo "==> [antigravity-sandbox] Setup completed successfully."
