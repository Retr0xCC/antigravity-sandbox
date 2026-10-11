**English** | [Русский](README.ru.md)

# Antigravity Sandbox 🛡️

> Secure, isolated Dev Container sandbox environment for Google DeepMind Antigravity and AI coding agents.

[![CI Docker Publish](https://github.com/Retr0defeated/antigravity-sandbox/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/Retr0defeated/antigravity-sandbox/actions/workflows/docker-publish.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Dev Container](https://img.shields.io/badge/Dev%20Containers-Supported-blue.svg)](https://containers.dev/)

---

## 💡 Overview

Autonomous AI coding agents (such as **Antigravity CLI**, Claude Code, Aider) operate with powerful toolsets that include interactive shell execution (`bash`, `run_command`), file modifications, and network access. Running these agents directly on a developer workstation introduces significant risks:

1. **Host Blast Radius:** Rogue shell commands, hallucinations, or prompt injection payloads can compromise personal host files (`~/.ssh`, `~/.aws`, `~/.kube`, `/etc/`).
2. **Local Network Exposure:** An agent operating with host networking can inadvertently scan or access internal LAN subnets, IoT devices, home gateways, or private web interfaces.
3. **Configuration Drift & Machine Pollution:** Global packages, conflicting Python/Node dependencies, and dangling test files pollute your operating system.

**Antigravity Sandbox** solves this problem by packaging a hardened, isolated **Dev Container** runtime adhering to the [Development Containers Specification](https://containers.dev/). It restricts agent operations to a strictly controlled container boundary while persisting AI conversation context and credentials safely.

---

## 🔒 Security & Architecture Pillars

```text
 ┌─────────────────────────────────────────────────────────────┐
 │                    Developer Host Machine                   │
 │                                                             │
 │   Protected Resources (NOT accessible to container):        │
 │   - Host Home Directory (~/.ssh, ~/.aws, ~/.gnupg)          │
 │   - Host Root Filesystem (/)                                │
 │   - Host Docker Socket (/var/run/docker.sock)               │
 │   - Host Network Sockets & Ports (SSH, Postgres, Ollama)    │
 │     via Netfilter INPUT DROP on agy0 (allows DNS 53 only)   │
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                     Mounts only target project
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │             Antigravity Sandbox (Dev Container)             │
 │                                                             │
 │   - Non-root user: 'vscode' (UID 1000, unprivileged)        │
 │   - Pre-installed: antigravity-cli, uv, git, build-essential│
 │   - Zero network admin capabilities: NO CAP_NET_ADMIN       │
 │   - Auto-update disabled: AGY_CLI_DISABLE_AUTO_UPDATE=true  │
 │   - Binary locked: chmod 555 agy executable                 │
 │   - Isolated Workspace Mount: /workspaces/<project>         │
 │   - Persistent State Volume:                                │
 │       agy-gemini-data ──► /home/vscode/.gemini              │
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                    Isolated Docker Network
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                Docker Bridge Network (agy_net)              │
 │                                                             │
 │   - Subnet: 172.16.151.0/24 (Bridge: agy0)                  │
 │   - Explicit Upstream DNS: 9.9.9.9 (Quad9 Secured DNS)      │
 │   - Dual-Stack Leak Prevention: IPv6 disabled               │
 │   - Dynamic Netfilter DOCKER-USER DROP to RFC 1918 subnets  │
 │   - Dynamic Netfilter INPUT DROP to host sockets on agy0    │
 │   - Dynamic Kernel Policy Routing: unreachable to LAN       │
 │   - Systemd Service Persistence: agy-sandbox-network.service│
 └─────────────────────────────────────────────────────────────┘
```

### Key Guardrails

- **Host Boundary Protection (INPUT Chain):** Inbound packets from container interface `agy0` to the host's listening sockets (SSH port 22, databases, Ollama port 11434, Docker daemon) are dropped via the Netfilter `INPUT` chain (`-i agy0 -j DROP`), while preserving host DNS queries (port 53 UDP/TCP) and established connections.
- **Dynamic Kernel & LAN Isolation:** Outbound transit traffic from `172.16.151.0/24` to private RFC 1918 subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) is blocked via the `DOCKER-USER` forwarding chain and Linux Policy Routing (`ip rule`).
- **Reboot Persistence via Systemd:** Network isolation is managed by the lightweight `agy-sandbox-network.service` (`Type=oneshot`, `RemainAfterExit=yes`), ensuring kernel routing and firewall boundaries survive host reboots and Docker restarts.
- **Controlled DNS (`--dns=9.9.9.9`):** Intercepts DNS resolution through Quad9 secure upstream resolvers, avoiding host DNS cache pollution and local discovery.
- **Unprivileged Container:** Operates strictly without `CAP_NET_ADMIN`, preventing raw packet sockets, ARP manipulation, or kernel netfilter attack surfaces.
- **Antigravity CLI Lock & Auto-Update Protection:** Patched `agy` binary permissions are locked (`chmod 555`) and `AGY_CLI_DISABLE_AUTO_UPDATE=true` is enforced in the environment.
- **Credential & History Persistence:** Agent authentication and chat histories are mapped into an independent Docker volume (`agy-gemini-data -> /home/vscode/.gemini`), surviving container rebuilds without saving sensitive tokens to the host project folder.
- **Strict Bind Mount Boundaries:** Only the repository directory (`${localWorkspaceFolder}`) is mounted into `/workspaces/<project>`. The host filesystem remains inaccessible.

---

## 🚀 Quick Start: Adding Sandbox to Any Project

### Method 1: Interactive TUI or Initializer CLI

To equip your repository with the Antigravity Sandbox:

```bash
# Clone the sandbox repository (once)
git clone https://github.com/Retr0defeated/antigravity-sandbox.git ~/.antigravity-sandbox

# Install global 'agy-sandbox' command into ~/.local/bin
~/.antigravity-sandbox/scripts/init-sandbox.sh --install-bin

# Launch friendly interactive Terminal UI (TUI)
agy-sandbox

# Or initialize directly via CLI:
agy-sandbox /path/to/your/project
agy-sandbox /path/to/rpi-edge-node rpi-edge-node
```

#### CLI Options & Commands:

```text
Usage: agy-sandbox [OPTIONS] [TARGET_DIR] [TEMPLATE]

Without arguments in interactive terminal, launches the Antigravity TUI.

Options:
  -i, --interactive        Launch interactive terminal user interface
  -l, --list               List available sandbox templates
  -d, --diagnose, diagnose Run security audit & boundary diagnostics
  --service [COMMAND]      Manage systemd persistence (status|enable|disable|install)
  --install-bin            Symlink agy-sandbox into ~/.local/bin
  -h, --help               Show this help message
```

Available templates:
- `default` (default) — Minimal universal sandbox with `antigravity-cli`, `uv`, `git`, and base tools. Fast, lightweight, zero extra extensions.
- `rpi-edge-node` — Dedicated environment with Ansible (2.15+), `ansible-lint`, `yamllint`, `community.general`, Go (1.22+), OpenSSH client, and VS Code extensions (`redhat.ansible`, `golang.go`, `redhat.vscode-yaml`, `even-better-toml`, `samuelcolvin.jinjahtml` for Jinja2 `.j2` templates).

---

### Method 2: Systemd Persistence Daemon (Host Network Daemon)

To ensure network rules (`ip rule`, `DOCKER-USER`, and `INPUT` host boundary) survive host reboots:

```bash
# Enable & start systemd persistence daemon (runs ensure-network.sh on boot, teardown.sh on shutdown)
sudo agy-sandbox service enable
# Or directly via systemctl:
sudo systemctl enable --now agy-sandbox-network.service

# Check persistence daemon status:
agy-sandbox service status
sudo systemctl status agy-sandbox-network.service

# Disable persistence and cleanly remove isolation rules:
sudo agy-sandbox service disable
# Or directly via systemctl:
sudo systemctl disable --now agy-sandbox-network.service
```

---

### Method 3: Security Diagnostics & Audit

Verify all 7 layers of kernel, Netfilter, and host isolation:

```bash
agy-sandbox diagnose
# Or run standalone script:
~/.antigravity-sandbox/scripts/diagnose.sh
```

---

### Method 4: Manual Setup

1. Create a `.devcontainer` directory in your project root:
   ```bash
   mkdir -p .devcontainer
   ```
2. Copy files from `templates/default/` (or `templates/rpi-edge-node/`):
   ```bash
   cp -r ~/.antigravity-sandbox/templates/default/* .devcontainer/
   ```
3. Provision the isolated network on your host machine:
   ```bash
   ~/.antigravity-sandbox/scripts/ensure-network.sh
   ```
4. When finished, you can cleanly tear down the network rules:
   ```bash
   ~/.antigravity-sandbox/scripts/teardown.sh
   ```

---

## 🛠️ Usage with VS Code & Cursor

1. Open your project in VS Code or Cursor:
   ```bash
   code /path/to/your/project
   ```
2. Press `F1` (or `Ctrl+Shift+P` / `Cmd+Shift+P`) and execute:
   ```text
   Dev Containers: Reopen in Container
   ```
3. VS Code builds the image locally from `Dockerfile`, mounts your project, and launches an integrated terminal.
4. Run Antigravity CLI safely inside the container:
   ```bash
   agy
   ```

---

## ⚡ Automated Setup Hook & Performance

The sandbox setup hook (`setup.sh`) is fully **idempotent**:
1. During the first container creation (`postCreateCommand`), it sets up volume permissions and applies the CLI eligibility patch.
2. It locks `agy` executable permissions to read/execute only (`chmod 555`) to prevent accidental overwrites or auto-updates.
3. It creates `/home/vscode/.agy_initialized`.
4. Subsequent invocations of `agy` execute **instantly** without disk traversal or re-running package installations.

---

## 🎨 Creating Custom Templates

`antigravity-sandbox` supports two template authoring models:

### 1. Declarative Mode (Recommended)
Instead of copying 90% of `Dockerfile` and `setup.sh`, create a directory under `templates/<your-template>/` with only your specific requirements:

- **`packages.txt`** *(optional)*: System packages to install via `apt-get` (one per line, comments `#` allowed).
- **`extensions.txt`** *(optional)*: VS Code extension IDs to pre-install (e.g. `golang.go`, `ms-python.python`).
- **`settings.json`** *(optional)*: Custom editor settings merged into `customizations.vscode.settings`.
- **`extra.Dockerfile`** *(optional)*: Additional build steps (e.g., `uv tool install ...`).
- **`extra-setup.sh`** *(optional)*: Additional bash commands executed in the post-create hook.
- **`description.txt`**: One-line description for CLI `--list` and the interactive TUI.

*The sandbox initializer automatically inherits `base/Dockerfile`, `base/setup.sh`, and `base/devcontainer.json`, injecting your packages and extensions dynamically.*

### 2. Full Custom Mode
If you need complete control over the entire Dev Container configuration, simply place a `devcontainer.json` and/or `Dockerfile` inside `templates/<your-template>/`. The initializer detects them and copies all template files directly without modifications.

---

## 📂 Repository Structure

```text
antigravity-sandbox/
├── .devcontainer/                # Repository's own devcontainer configuration (default)
├── .github/
│   └── workflows/
│       └── docker-publish.yml    # Multi-arch CI pipeline (linux/amd64 & linux/arm64)
├── base/
│   ├── devcontainer.json         # Foundational devcontainer specification
│   ├── Dockerfile                # Minimal universal base image definition
│   └── setup.sh                  # One-time idempotent setup hook
├── scripts/
│   ├── ensure-network.sh         # Netfilter (DOCKER-USER & INPUT) & ip rule provisioner
│   ├── teardown-network.sh       # Clean network, firewall, and routing teardown
│   ├── teardown.sh               # Symlink to teardown-network.sh
│   ├── service.sh                # Systemd service (agy-sandbox-network.service) manager
│   ├── diagnose.sh               # Comprehensive 7-layer security isolation auditor
│   └── init-sandbox.sh           # Interactive TUI & CLI entrypoint (agy-sandbox)
├── templates/
│   ├── default/                  # Minimal universal sandbox (inherits 100% from base)
│   │   └── description.txt       # Template summary
│   └── rpi-edge-node/            # Declarative edge automation profile
│       ├── packages.txt          # Extra apt packages (openssh-client, golang-go, etc.)
│       ├── extensions.txt        # Extra VS Code extensions (ansible, go, yaml, jinja)
│       ├── extra.Dockerfile      # Extra build steps (uv tool install ansible-core)
│       ├── settings.json         # Custom VS Code settings
│       └── description.txt       # Template summary
├── .gitignore
├── LICENSE                       # GNU General Public License v3.0
├── README.md                     # English documentation
└── README.ru.md                  # Russian documentation
```

---

## 📄 License

Distributed under the [GNU General Public License v3.0](LICENSE) (GPLv3).


