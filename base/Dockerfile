FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

LABEL org.opencontainers.image.title="antigravity-sandbox" \
      org.opencontainers.image.description="Hardened minimal development container for Antigravity and AI coding agents" \
      org.opencontainers.image.licenses="GPL-3.0"

# Install core development tools, Python standard library, and security dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    build-essential \
    bash-completion \
    jq \
    sudo \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install uv (astral-sh fast Python package manager) pinned by immutable SHA256 digest
COPY --from=ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff /uv /uvx /bin/

# Clone and lock Antigravity CLI patcher (QNIX-Dev) in system directory (SEC-03)
ARG PATCHER_REPO="https://github.com/QNIX-Dev/eligibility-antigravity-patcher.git"
ARG PATCHER_COMMIT="90498f50353d414232f593dffe88899bc80b6312"
RUN mkdir -p /usr/local/share/agy-sandbox \
    && git clone "${PATCHER_REPO}" /usr/local/share/agy-sandbox/patcher \
    && cd /usr/local/share/agy-sandbox/patcher \
    && git checkout "${PATCHER_COMMIT}" \
    && rm -rf .git \
    && chown -R root:root /usr/local/share/agy-sandbox/patcher \
    && chmod -R a+rX /usr/local/share/agy-sandbox/patcher

# Copy and isolate setup hook and installer in system directory (CNT-03)
COPY --chown=root:root setup.sh /usr/local/share/agy-sandbox/setup.sh
COPY --chown=root:root install-agy.sh /usr/local/share/agy-sandbox/install-agy.sh
RUN chmod 0755 /usr/local/share/agy-sandbox/setup.sh /usr/local/share/agy-sandbox/install-agy.sh

# Pre-create directory for persisted Gemini volume with unprivileged ownership (no-new-privileges preparation)
RUN mkdir -p /home/vscode/.gemini \
    && chown -R vscode:vscode /home/vscode/.gemini \
    && chmod 0700 /home/vscode/.gemini

# Configure unprivileged vscode user
USER vscode
ENV HOME=/home/vscode
ENV PATH="/home/vscode/.antigravity/bin:/home/vscode/.local/bin:${PATH}"

# Pin specific CLI version
ARG AGY_VERSION=1.4.6
ENV AGY_VERSION=${AGY_VERSION}

# Install antigravity-cli for unprivileged user
RUN bash /usr/local/share/agy-sandbox/install-agy.sh "${AGY_VERSION}"

# Configure wrapper function and alias for agy with one-time setup marker
RUN cat <<'EOF' >> /home/vscode/.bash_aliases
# Antigravity Sandbox wrapper
agy() {
    if [ ! -f /home/vscode/.agy_initialized ]; then
        if [ -x /usr/local/share/agy-sandbox/setup.sh ]; then
            /usr/local/share/agy-sandbox/setup.sh "$PWD"
        else
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
                bash "$setup_script" "$PWD"
            fi
        fi
    fi

    command agy "$@"
}

alias antigravity="agy"
EOF

RUN echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> /home/vscode/.bashrc

WORKDIR /workspaces
CMD ["sleep", "infinity"]
