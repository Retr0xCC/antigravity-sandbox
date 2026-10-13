**English** | [Русский](README.ru.md)

# Antigravity Sandbox

> Isolated environment for Antigravity based on VS Code Dev Containers

[![Dev Container](https://img.shields.io/badge/Dev%20Containers-Supported-blue.svg)](https://containers.dev/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

---

## Overview

During operation, **Antigravity** executes shell commands, modifies files, and accesses the network. Running it directly creates risks for the host due to model errors or hallucinations.

**Antigravity Sandbox** isolates the agent inside a Docker container via the Dev Containers specification, solving three key problems:

* **Filesystem isolation:** the agent is restricted to the project working directory inside the container and has no access to host files (`~/.ssh`, tokens, environment variables, and system directories).
* **Blocking local network (LAN) access:** a standard Docker bridge does not isolate the host's local network. In this project, the network perimeter is protected at the kernel level using `iptables` and `ip rule` rules (via a systemd service), eliminating scanning and access to local resources (routers, NAS, other machines).
* **Host system cleanliness:** all dependencies, package managers, and temporary files remain inside the container without cluttering the main OS.

Session state, conversation history, and Antigravity authorization tokens are persisted in dedicated Docker volumes, kept separate from user files.

---

## Isolation Model and Architecture

```text
 ┌─────────────────────────────────────────────────────────────┐
 │                            Host                             │
 │                                                             │
 │   Protected resources (Inaccessible to container):          │
 │   - Host home directory (~/.ssh, ~/.aws, ~/.gnupg)          │
 │   - Host root filesystem (/)                                │
 │   - Host Docker socket (/var/run/docker.sock)               │
 │   - Host network sockets and ports (SSH, Postgres, Ollama)  │
 │     via Netfilter INPUT DROP on agy0 (only DNS permitted)   │
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                                 │  Mounts target project only
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                           Sandbox                           │
 │                                                             │
 │   - Unprivileged user: 'vscode' (UID 1000)                  │
 │   - Auto-patch binary at build: QNIX-Dev agy patch          │
 │   - Dropped network privileges: drop CAP_NET_ADMIN          │
 │   - Auto-update disabled: AGY_CLI_DISABLE_AUTO_UPDATE=1     │
 │   - Binary write protection: chmod 555 agy                  │
 │   - Isolated workspace: /workspaces/<proj>                  │
 │   - Persistent state volume:                                │
 │       agy-gemini-data ──► /home/vscode/.gemini              │
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                                 │  Isolated docker network
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                           Network                           │
 │                                                             │
 │   - Subnet: 172.16.151.0/24 (Interface: agy0)               │
 │   - Dedicated upstream DNS: 9.9.9.9 (Quad9 DNS)             │
 │   - IPv6 leak prevention: IPv6 disabled                     │
 │   - Netfilter DOCKER-USER DROP to RFC 1918 LAN              │
 │   - Netfilter INPUT DROP to host ports on agy0              │
 │   - Linux Policy Routing: unreachable to LAN                │
 │   - Rule persistence via Systemd: agy-sandbox-network       │
 └─────────────────────────────────────────────────────────────┘
```

### Security Implementation

- **Host service protection (INPUT chain):** Inbound traffic from container interface `agy0` to host listening ports (SSH, DB, Ollama, Docker daemon socket) is dropped by the Netfilter `INPUT` rule (`-i agy0 -j DROP`). Only local DNS requests (port 53 UDP/TCP) and established connections (ESTABLISHED/RELATED) are permitted.
- **Local network isolation (RFC 1918):** Transit traffic from the container subnet `172.16.151.0/24` to private LAN ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) is blocked in the `DOCKER-USER` forwarding chain and by a Linux kernel routing rule (`ip rule ... unreachable`).
- **Rule persistence (systemd):** Network configuration and filtering rules are managed by the `agy-sandbox-network.service` unit (`Type=oneshot`, `RemainAfterExit=yes`), which invokes `ensure-network.sh` on system startup and `teardown-network.sh` on shutdown.
- **Isolated DNS (`--dns=9.9.9.9`):** Queries resolve directly through Quad9 bypassing the host resolver, preventing DNS leaks and local host scanning via NetBIOS/mDNS.
- **Dropped network privileges:** The container runs without `CAP_NET_ADMIN` capability, preventing raw socket manipulation, ARP spoofing, or modifying internal network tables.
- **Binary modification protection:** Permissions on the patched `agy` binary are fixed to read and execute (`chmod 555`), and auto-update is blocked via `AGY_CLI_DISABLE_AUTO_UPDATE=1`.
- **Authorization and history isolation:** Session tokens and chat history are saved in a dedicated Docker volume (`agy-gemini-data -> /home/vscode/.gemini`), without mixing with repository files on the host.
- **Mount restrictions:** Only the project working directory (`${localWorkspaceFolder}` in `/workspaces/<project>`) is mounted into the container. Access to the host filesystem outside this directory is completely closed off.

---

## Quick Start: Connecting to a Project

### agy-sandbox Initializer (TUI / CLI)

Deploying the sandbox to a target repository:

```bash
# Clone the sandbox repository
git clone https://codeberg.org/Retr0defeated/antigravity-sandbox.git ~/.antigravity-sandbox

# Install the 'agy-sandbox' command into ~/.local/bin
~/.antigravity-sandbox/scripts/init-sandbox.sh --install-bin

# Interactive mode (TUI):
agy-sandbox

# Or initialize directly via arguments:
agy-sandbox /path/to/project
agy-sandbox /path/to/project [template]
```

#### CLI Parameters

```text
Usage: agy-sandbox [OPTIONS] [PROJECT_DIR] [TEMPLATE]

When run without arguments, opens an interactive menu (TUI).

Options:
  -i, --interactive        Interactive project and template selection (TUI)
  -l, --list               List available templates
  -d, --diagnose           Audit and diagnose network rules
  --service [COMMAND]      Manage systemd service (status | enable | disable | install)
  --install-bin            Install agy-sandbox symlink in ~/.local/bin
  -h, --help               Help
```

Available template profiles:
- `default` (default) — Clean base environment: antigravity-cli, uv, git, and a standard set of build tools.
- `rpi-edge-node` — Profile for edge node and gateway automation with Ansible (2.15+), `ansible-lint`, `yamllint`, `community.general` collection, Go (1.22+), OpenSSH client, and VS Code extensions (`redhat.ansible`, `golang.go`, `redhat.vscode-yaml`, `even-better-toml`, `samuelcolvin.jinjahtml` for Jinja2 `.j2` templates).
- `math-labs` — Profile for mathematical computing and data analysis with Python, Jupyter (`ms-toolsai.jupyter`), PDF viewer (`tomoki1207.pdf`), NumPy, SciPy, Matplotlib, SymPy, and pandas.

---

## Host Network Isolation Setup

To automatically apply filtering rules (`nftables`/`iptables`) and routing rules (`ip rule`) on OS boot, a systemd service is included in the project:

```bash
# Install and activate the service in the system:
sudo agy-sandbox service install
sudo agy-sandbox service enable

# Check status:
agy-sandbox service status

# Disable rules if necessary:
sudo agy-sandbox service disable
```

---

### Verifying Network Isolation

To verify Netfilter rules, routing tables, and DNS availability, a built-in audit is provided:

```bash
agy-sandbox diagnose
# Or run the script directly:
~/.antigravity-sandbox/scripts/diagnose.sh
```

---

## Running in VS Code

1. Open the project directory in VS Code:
   ```bash
   code /path/to/project
   ```

2. Open the command palette (`F1` or `Ctrl+Shift+P`) and select:
   ```text
   Dev Containers: Reopen in Container
   ```

3. The editor builds the Docker image and performs initial setup (`setup.sh` via `postCreateCommand`): installs dependencies and applies the `agy` patch.

4. Run the CLI in the container's integrated terminal:
   ```bash
   agy
   ```

---

### Container Lifecycle (setup.sh)

The initial setup script `setup.sh` runs once during container creation (`postCreateCommand`):
* sets permissions on the `/home/vscode/.gemini` volume;
* runs the `QNIX-Dev/eligibility-antigravity-patcher` patcher;
* locks the binary against modification (`chmod 555`);
* creates the `/home/vscode/.agy_initialized` marker, preventing repeated execution on restarts.

---

## Creating Custom Templates

`antigravity-sandbox` supports two template authoring formats:

### 1. Declarative Mode (Recommended)

Instead of duplicating the base `Dockerfile` and `setup.sh` files, simply create a directory `templates/<template_name>/` containing only the required manifests:

- **`packages.txt`** *(optional)* — system packages to install via `apt-get` (one per line, `#` comments supported).
- **`extensions.txt`** *(optional)* — VS Code extension identifiers (e.g. `golang.go`, `ms-python.python`).
- **`settings.json`** *(optional)* — editor configuration parameters merged into `customizations.vscode.settings`.
- **`extra.Dockerfile`** *(optional)* — additional build instructions for the image (e.g. `uv tool install ...`).
- **`extra-setup.sh`** *(optional)* — bash commands executed during initial container setup.
- **`description.txt`** *(optional)* — short description for CLI help (`--list`) and TUI menu (default: `Custom sandbox profile`).

The sandbox initializer automatically inherits the base configuration (`base/Dockerfile`, `base/setup.sh`, `base/devcontainer.json`), merging it with the template manifests.

### 2. Full Custom Mode

If you need to completely override the build environment, place your own `devcontainer.json` and/or `Dockerfile` directly in the `templates/<template_name>/` directory. The initializer will copy them to the target project without merging with the base layer.

---

## Repository Structure

```text
antigravity-sandbox/
├── .devcontainer/                  # Dev Container configuration for developing the sandbox itself
├── .github/workflows/
│   └── docker-publish.yml          # Multi-arch image build (linux/amd64, linux/arm64)
├── base/
│   ├── devcontainer.json           # Base Dev Container specification
│   ├── Dockerfile                  # Base Docker image
│   └── setup.sh                    # Initial container setup (agy patch, volume permissions)
├── scripts/
│   ├── ensure-network.sh           # Creation of agy_net network, Netfilter rules, and ip rule
│   ├── teardown-network.sh         # Removal of agy_net network and reset of filtering rules
│   ├── service.sh                  # Management of systemd unit (agy-sandbox-network.service)
│   ├── diagnose.sh                 # Host isolation and network rule audit script
│   └── init-sandbox.sh             # CLI entry point (agy-sandbox) and TUI menu
├── templates/
│   ├── default/                    # Base profile (inherits base/ configuration)
│   │   └── description.txt
│   ├── math-labs/                  # Profile for mathematical computing and data analysis
│   │   ├── packages.txt            # System packages (python3, graphviz)
│   │   ├── extensions.txt          # VS Code extensions (Jupyter, Python, PDF viewer)
│   │   ├── extra.Dockerfile        # Python library installation (numpy, scipy, matplotlib)
│   │   ├── settings.json           # VS Code configuration
│   │   └── description.txt
│   └── rpi-edge-node/              # Profile for edge node and gateway automation
│       ├── packages.txt            # System packages (openssh-client, golang)
│       ├── extensions.txt          # VS Code extensions (Ansible, Go, YAML, Jinja)
│       ├── extra.Dockerfile        # Installation of ansible-core and ansible-lint
│       ├── settings.json           # VS Code configuration
│       └── description.txt
├── .gitignore
├── LICENSE                         # GNU General Public License v3.0
├── README.en.md                    # English documentation
├── README.md                       # Symlink to README.en.md (default landing page)
└── README.ru.md                    # Russian documentation
```

---

## Third-Party Components

During container initialization (`setup.sh`), a third-party script is used:

* **[QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher)** (author: [QNIX-Dev](https://github.com/QNIX-Dev))
  * **Purpose:** patching the Antigravity CLI binary during environment build.
  * **License:** MIT License.

---

## License

- **antigravity-sandbox** (network isolation scripts, TUI, environment templates) — [GNU General Public License v3.0](LICENSE).
- **eligibility-antigravity-patcher** — [MIT License](https://github.com/QNIX-Dev/eligibility-antigravity-patcher/blob/main/LICENSE).
