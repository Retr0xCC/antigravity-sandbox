# Install Ansible toolchain and linters in isolated user tools directory
RUN uv tool install ansible-core==2.18.2 && \
    uv tool install ansible-lint==25.1.3 && \
    uv tool install yamllint==1.35.1

# Install standard Ansible collections required by rpi-edge-node
RUN /home/vscode/.local/bin/ansible-galaxy collection install community.general:10.4.0
