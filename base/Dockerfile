FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

LABEL org.opencontainers.image.title="antigravity-sandbox" \
      org.opencontainers.image.description="Hardened minimal development container for Antigravity and AI coding agents" \
      org.opencontainers.image.licenses="GPL-3.0"

# Install core development tools and security dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    build-essential \
    bash-completion \
    jq \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install uv (astral-sh fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Configure unprivileged vscode user
USER vscode
ENV HOME=/home/vscode
ENV PATH="/home/vscode/.antigravity/bin:/home/vscode/.local/bin:${PATH}"
ENV AGY_CLI_DISABLE_AUTO_UPDATE=true

# Install antigravity-cli for unprivileged user
RUN curl -fsSL --compressed https://antigravity.google/cli/install.sh | bash

# Create directory for persisted Gemini / Antigravity credentials volume
RUN mkdir -p /home/vscode/.gemini

# Configure wrapper function and alias for agy with one-time setup marker
RUN cat <<'EOF' >> /home/vscode/.bash_aliases
# Antigravity Sandbox wrapper
agy() {
    if [ ! -f /home/vscode/.agy_initialized ]; then
        local cur="$PWD"
        local setup_script=""
        while [ "$cur" != "/" ] && [ -n "$cur" ]; do
            if [ -f "$cur/.devcontainer/setup.sh" ]; then
                setup_script="$cur/.devcontainer/setup.sh"
                break
            fi
            cur="$(dirname "$cur")"
        done

        if [ -n "$setup_script" ]; then
            bash "$setup_script"
        fi
    fi

    command agy "$@"
}

alias antigravity="agy"
EOF

RUN echo "export AGY_CLI_DISABLE_AUTO_UPDATE=true" >> /home/vscode/.bashrc && \
    echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> /home/vscode/.bashrc

WORKDIR /workspaces
CMD ["sleep", "infinity"]
