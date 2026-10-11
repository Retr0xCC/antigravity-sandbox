# Install Ansible toolchain and linters in isolated user tools directory
RUN uv tool install ansible-core && \
    uv tool install ansible-lint && \
    uv tool install yamllint

# Install standard Ansible collections required by rpi-edge-node
RUN /home/vscode/.local/bin/ansible-galaxy collection install community.general
