# Switch to root to configure NodeSource repository and install global Node packages
USER root

# Install Node.js 22 LTS from official NodeSource distribution (affine-mcp-server requires Node >= 20.18.1)
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install pinned affine-mcp-server globally
RUN npm install -g affine-mcp-server@3.11.0

# Install helper onboarding tool into system PATH
COPY affine-setup.sh /usr/local/bin/affine-setup
RUN chmod 0755 /usr/local/bin/affine-setup

# Return to standard unprivileged user
USER vscode
