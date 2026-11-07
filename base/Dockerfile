FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:d94c97dd9cacf183d0a6fd12a8e87b526e9e928307674ae9c94139139c0c6eae

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
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Enforce strictly rootless unprivileged container: purge sudo and remove sudoers configurations (VULN-03)
RUN apt-get purge -y sudo 2>/dev/null || true \
    && rm -rf /etc/sudoers /etc/sudoers.d /usr/bin/sudo /usr/bin/sudoedit /usr/lib/sudo 2>/dev/null || true

# Install uv (astral-sh fast Python package manager) pinned by immutable SHA256 digest (REG-01)
COPY --from=ghcr.io/astral-sh/uv:0.6.6@sha256:031ddbc79275e351a43cbb66f64d8cd314cc78c3878898f4ab4f147b092e8e2d /uv /uvx /usr/local/bin/

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

# Pre-create directories for persisted Gemini and cache volumes with unprivileged ownership (no-new-privileges preparation)
RUN mkdir -p /home/vscode/.gemini /home/vscode/.gemini-shared /home/vscode/.cache \
    && chown -R vscode:vscode /home/vscode/.gemini /home/vscode/.gemini-shared /home/vscode/.cache \
    && chmod 0755 /home/vscode/.cache \
    && chmod 0700 /home/vscode/.gemini /home/vscode/.gemini-shared

# Pin specific CLI version and pre-install into /home/vscode/.local/bin owned by vscode (REG-02)
# Ensures user-space patcher has write permissions and ~/.local/bin takes precedence in PATH
ARG AGY_VERSION=1.5.3
ENV AGY_VERSION=${AGY_VERSION}
RUN mkdir -p /home/vscode/.local/bin \
    && bash /usr/local/share/agy-sandbox/install-agy.sh "${AGY_VERSION}" "/home/vscode/.local/bin" \
    && chown -R vscode:vscode /home/vscode/.local \
    && chmod 0755 /home/vscode/.local/bin/agy

# Configure unprivileged vscode user
USER vscode
ENV HOME=/home/vscode
ENV PATH="/home/vscode/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Configure wrapper function and alias for agy with one-time setup marker
RUN cat <<'EOF' >> /home/vscode/.bash_aliases
# Antigravity Sandbox wrapper
agy() {
    if [ ! -f /home/vscode/.agy_initialized ]; then
        if [ -x /usr/local/share/agy-sandbox/setup.sh ]; then
            /usr/local/share/agy-sandbox/setup.sh "$PWD"
        fi
    fi

    command agy "$@"
}

alias antigravity="agy"
EOF

RUN echo "if [ -f ~/.bash_aliases ]; then . ~/.bash_aliases; fi" >> /home/vscode/.bashrc

WORKDIR /workspaces
CMD ["sleep", "infinity"]
