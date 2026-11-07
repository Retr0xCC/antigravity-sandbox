# Switch to root to configure NodeSource repository and install global Node packages
USER root

# Install Node.js 22 LTS from official NodeSource distribution with cryptographic GPG fingerprint verification
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.key && \
    gpg --dry-run --quiet --import --import-options import-show /tmp/nodesource.key 2>&1 | grep -q "6F71F525282841EEDAF851B42F59B5F99B1BE0B4" && \
    gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource.key && \
    rm -f /tmp/nodesource.key && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install pinned affine-mcp-server globally with lifecycle scripts disabled (--ignore-scripts)
RUN npm install -g --ignore-scripts affine-mcp-server@3.11.0

# Install helper onboarding tool into system PATH
COPY affine-setup.sh /usr/local/bin/affine-setup
RUN chmod 0755 /usr/local/bin/affine-setup

# Return to standard unprivileged user
USER vscode
