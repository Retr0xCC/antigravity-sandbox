# ========================================================
# AFFiNE MCP Template Initialization Hook
# Scoped strictly to the current workspace (Principle of Least Privilege)
# ========================================================

# 1. Clean up any legacy shared credentials from global volume if present and writable
if [ -w "/home/vscode/.gemini-shared" ]; then
    if [ -d "/home/vscode/.gemini-shared/affine-mcp" ]; then
        mkdir -p /home/vscode/.gemini/affine-mcp
        cp -rn /home/vscode/.gemini-shared/affine-mcp/* /home/vscode/.gemini/affine-mcp/ 2>/dev/null || true
        rm -rf /home/vscode/.gemini-shared/affine-mcp
    fi

    if [ -f "/home/vscode/.gemini-shared/config/mcp_config.json" ] && command -v jq >/dev/null 2>&1; then
        if jq -e '.mcpServers.affine' "/home/vscode/.gemini-shared/config/mcp_config.json" >/dev/null 2>&1; then
            tmp_shared="$(mktemp)"
            jq 'del(.mcpServers.affine)' "/home/vscode/.gemini-shared/config/mcp_config.json" > "${tmp_shared}" && mv "${tmp_shared}" "/home/vscode/.gemini-shared/config/mcp_config.json"
        fi
    fi
fi

# 2. Ensure persistent storage for affine-mcp credentials in project-scoped volume
# (source=agy-gemini-data-${localWorkspaceFolderBasename},target=/home/vscode/.gemini)
mkdir -p /home/vscode/.gemini/affine-mcp /home/vscode/.config

if [ -L "/home/vscode/.config/affine-mcp" ]; then
    if [ "$(readlink "/home/vscode/.config/affine-mcp")" != "/home/vscode/.gemini/affine-mcp" ]; then
        ln -sfn /home/vscode/.gemini/affine-mcp /home/vscode/.config/affine-mcp
    fi
elif [ -d "/home/vscode/.config/affine-mcp" ]; then
    cp -rn /home/vscode/.config/affine-mcp/* /home/vscode/.gemini/affine-mcp/ 2>/dev/null || true
    rm -rf /home/vscode/.config/affine-mcp
    ln -sfn /home/vscode/.gemini/affine-mcp /home/vscode/.config/affine-mcp
else
    ln -sfn /home/vscode/.gemini/affine-mcp /home/vscode/.config/affine-mcp
fi

# 3. Decouple ~/.gemini/config/mcp_config.json from shared volume to keep MCP tools isolated to this project
LOCAL_MCP_CONFIG="/home/vscode/.gemini/config/mcp_config.json"
mkdir -p "$(dirname "${LOCAL_MCP_CONFIG}")"

# Break the symlink to .gemini-shared so other workspaces never see affine MCP
if [ -L "${LOCAL_MCP_CONFIG}" ]; then
    rm -f "${LOCAL_MCP_CONFIG}"
fi

if [ ! -f "${LOCAL_MCP_CONFIG}" ] || [ ! -s "${LOCAL_MCP_CONFIG}" ]; then
    cat <<'EOF' > "${LOCAL_MCP_CONFIG}"
{
  "mcpServers": {
    "affine": {
      "command": "affine-mcp"
    }
  }
}
EOF
elif command -v jq >/dev/null 2>&1; then
    if ! jq -e '.mcpServers.affine' "${LOCAL_MCP_CONFIG}" >/dev/null 2>&1; then
        tmp_mcp="$(mktemp)"
        jq '.mcpServers.affine = {"command": "affine-mcp"}' "${LOCAL_MCP_CONFIG}" > "${tmp_mcp}" && mv "${tmp_mcp}" "${LOCAL_MCP_CONFIG}"
    fi
fi

# 4. Ensure affine-setup utility is available in user PATH
mkdir -p /home/vscode/.local/bin
if [ ! -x "/usr/local/bin/affine-setup" ] && [ -f "${WORKSPACE_DIR}/.devcontainer/affine-setup.sh" ]; then
    cp "${WORKSPACE_DIR}/.devcontainer/affine-setup.sh" /home/vscode/.local/bin/affine-setup
    chmod 0755 /home/vscode/.local/bin/affine-setup
fi

echo "==> [affine-mcp] Template initialized with project-isolated persistence. Run 'affine-setup' to configure."
