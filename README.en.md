**English** | [Русский](README.ru.md)

# Antigravity Sandbox

> Isolated environment for Antigravity based on VS Code Dev Containers

[![Dev Container](https://img.shields.io/badge/Dev%20Containers-Supported-blue.svg)](https://containers.dev/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Codeberg](https://img.shields.io/badge/Codeberg-Main_Repo-2185D0?logo=codeberg&logoColor=white)](https://codeberg.org/Retr0xCC/antigravity-sandbox)
[![GitHub](https://img.shields.io/badge/GitHub-Mirror-181717?logo=github&logoColor=white)](https://github.com/Retr0xCC/antigravity-sandbox)

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
 │   - Subnet: Docker IPAM dynamic / custom via sandbox.conf   │
 │   - Bridge: agy0 (ICC enabled, IPv6 disabled)               │
 │   - Dedicated upstream DNS: 9.9.9.9, 149.112.112.112 (Quad9)│
 │   - Fail-Closed protection: /run/agy-sandbox/network.ready  │
 │   - Netfilter: AGY-SANDBOX-FWD (DROP LAN) & AGY-SANDBOX-IN  │
 │   - Linux Policy Routing: pref 95 intra / pref 100 unreach  │
 │   - Hardened Systemd Service: /usr/local/lib/agy-sandbox/   │
 └─────────────────────────────────────────────────────────────┘
```

### Security Implementation

- **Dedicated Netfilter chains (`AGY-SANDBOX-FWD` & `AGY-SANDBOX-IN`):** Network filtering is isolated into dedicated custom chains anchored to `DOCKER-USER` and `INPUT`. Forward transit traffic from container bridge `agy0` to all private/special IPv4 ranges (RFC 1918, CGNAT, loopback, link-local, multicast, testnets) is unconditionally dropped. Host listening ports (SSH, DB, Docker daemon socket) are blocked via `AGY-SANDBOX-IN`, permitting only host DNS resolution (port 53 UDP/TCP) and established connections (`ESTABLISHED,RELATED`).
- **Fail-Closed readiness marker:** Container startup strictly requires a healthy, isolated network state. `ensure-network.sh` creates the marker `/run/agy-sandbox/network.ready` only after all bridge, Netfilter, and RPDB routing rules are successfully applied and verified. The sandbox CLI initializer (`init-sandbox.sh`) halts container startup in Fail-Closed mode if this marker is missing.
- **Two-tier RPDB kernel policy routing:** Routing rules are strictly bound to the incoming interface (`iif agy0`), guaranteeing protection even when split-tunnel VPNs manipulate host main/default routing tables. Intra-subnet traffic is allowed at priority 95 (`lookup main`), while private/special destination CIDRs are immediately rejected at priority 100 (`unreachable`).
- **Hardened systemd daemon:** Network service scripts and configuration are copied to `/usr/local/lib/agy-sandbox/` owned by `root:root` with read-only permissions (`0755`/`0644`), eliminating Local Privilege Escalation (LPE) vulnerabilities. The systemd unit runs with isolation parameters `ProtectHome=yes`, `ProtectSystem=full`, `PrivateTmp=yes`, and manages the `/run/agy-sandbox` runtime directory.
- **Dynamic Docker IPAM with zero conflicts:** By default, subnets are assigned automatically through standard Docker IPAM from the conflict-free pool (`172.17.0.0/16`-`172.31.0.0/16`), with support for explicit static subnet overrides via `sandbox.conf`.
- **Isolated DNS (`--dns=9.9.9.9`, `--dns=149.112.112.112`):** Queries resolve directly through Quad9 bypassing the host resolver, preventing DNS leaks and local host scanning via NetBIOS/mDNS.
- **Dropped network privileges:** The container runs without `CAP_NET_ADMIN` capability, preventing raw socket manipulation, ARP spoofing, or modifying internal network tables.
- **Binary modification protection:** For pinned CLI versions (`AGY_VERSION != latest`), permissions on the `agy` binary are fixed to read and execute (`chmod 555`), and auto-update is blocked via `AGY_CLI_DISABLE_AUTO_UPDATE=1`. When running with `latest`, standard executable permissions (`chmod 755`) are preserved and self-updates remain active.
- **Authorization and history isolation:** Session tokens and chat history are saved in a dedicated Docker volume (`agy-gemini-data -> /home/vscode/.gemini`), without mixing with repository files on the host.
- **Mount restrictions:** Only the project working directory (`${localWorkspaceFolder}` in `/workspaces/<project>`) is mounted into the container. Access to the host filesystem outside this directory is completely closed off.

---

## Quick Start: Connecting to a Project

### agy-sandbox Initializer (TUI / CLI)

Deploying the sandbox to a target repository:

```bash
# Clone the sandbox repository
git clone https://codeberg.org/Retr0xCC/antigravity-sandbox.git ~/.antigravity-sandbox

# Install the 'agy-sandbox' command into ~/.local/bin
~/.antigravity-sandbox/scripts/init-sandbox.sh --install-bin

# Interactive mode (TUI):
agy-sandbox

# Or initialize directly via arguments:
agy-sandbox /path/to/project
agy-sandbox /path/to/project [template]
agy-sandbox /path/to/project [template] -v 1.4.6
```

#### CLI Parameters

```text
Usage: agy-sandbox [OPTIONS] [PROJECT_DIR] [TEMPLATE]

When run without arguments, opens an interactive menu (TUI).

Options:
  -i, --interactive              Interactive project, template, and version selection (TUI)
  -v, --agy-version <tag>        Pin specific Antigravity CLI version (e.g. 1.4.6, latest)
  --patch                        Apply QNIX-Dev eligibility patch to CLI binary (default)
  --no-patch, --skip-patch       Disable patch, keep clean official binary
  -l, --list                     List available templates
  -d, --diagnose                 Audit and diagnose network rules
  --service [COMMAND]            Manage systemd service (status | enable | disable | install)
  --install-bin                  Install agy-sandbox symlink in ~/.local/bin
  -h, --help                     Help
```

#### Antigravity CLI Version Pinning & Binary Patching

By default, sandboxes deploy with a pinned stable CLI version (`1.4.6`), preventing breaking changes from unexpected upstream updates, and apply the `QNIX-Dev` eligibility patch.

* **Single Control Variable:** Setting `AGY_VERSION` controls both the installed release and security lockdown. When pinned (`AGY_VERSION != latest`), the sandbox automatically locks the binary (`chmod 555`) and blocks auto-updates (`AGY_CLI_DISABLE_AUTO_UPDATE=true` in `~/.bashrc`). For `latest`, the binary retains standard permissions (`chmod 755`) and self-updates remain enabled.
* **Optional Patching:** Pass `--no-patch` (or select `No` in TUI Step 4) to keep the clean, unmodified official binary. Use `--patch` to explicitly enable it.
* **Persistent Defaults in `base/devcontainer.json`:** To permanently change default versions and patching behavior for all new sandboxes, simply edit `base/devcontainer.json` (`build.args.AGY_VERSION`, `remoteEnv.AGY_VERSION`, and `remoteEnv.AGY_PATCH`). The initializer automatically derives its defaults directly from this file.
* **Interactive TUI & CLI:** Wizard steps allow choosing between default stable (`1.4.6`), `latest`, custom tags, and toggling the patcher. CLI flags `-v, --agy-version <tag>` and `--no-patch` allow non-interactive specification.

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

### Configuration (`scripts/sandbox.conf` & Environment Overrides)

The sandbox network stack uses a single centralized configuration file `scripts/sandbox.conf` as the Single Source of Truth (SSOT). When installed as a system service, the configuration is deployed to `/usr/local/lib/agy-sandbox/sandbox.conf`.

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `NETWORK_NAME` | `"agy_net"` | Docker bridge network name. |
| `BRIDGE_NAME` | `"agy0"` | Linux kernel bridge interface name. |
| `SUBNET` | `""` | Subnet CIDR. If empty (`""`), Docker native IPAM automatically allocates a conflict-free subnet from pool `172.17.0.0/16`-`172.31.0.0/16`. If set (e.g. `"172.16.151.0/24"`), this static CIDR is enforced. |
| `DNS_PRIMARY` | `"9.9.9.9"` | Primary upstream DNS resolver (Quad9). |
| `DNS_SECONDARY` | `"149.112.112.112"` | Secondary upstream DNS resolver (Quad9). |
| `READY_FILE` | `"/run/agy-sandbox/network.ready"` | Fail-Closed readiness marker file path. |

All variables in `sandbox.conf` can be overridden by environment variables without modifying the file directly:

```bash
# Example 1: Enforce a static subnet and custom upstream DNS
sudo SUBNET="172.16.200.0/24" DNS_PRIMARY="1.1.1.1" agy-sandbox service install
sudo agy-sandbox service enable

# Example 2: Re-run network setup directly with temporary overrides
sudo NETWORK_NAME="custom_net" BRIDGE_NAME="cbr0" /usr/local/lib/agy-sandbox/ensure-network.sh
```

### Systemd Service Hardening & Fail-Closed Protection

- **Local Privilege Escalation (LPE) Prevention:** When running `sudo agy-sandbox service install`, all scripts and `sandbox.conf` are copied to `/usr/local/lib/agy-sandbox/` with ownership `root:root` and permissions `0755`/`0644`. The systemd service `agy-sandbox-network.service` references only this protected directory, preventing unprivileged users from modifying scripts executed by root.
- **Systemd Sandboxing:** The service executes with `ProtectHome=yes`, `ProtectSystem=full`, `PrivateTmp=yes`, and systemd manages the runtime directory `/run/agy-sandbox`.
- **Fail-Closed Guarantees:** Network setup writes `/run/agy-sandbox/network.ready` upon verifying all routing and firewall rules. `agy-sandbox` CLI initializer verifies this marker before generating devcontainers or launching environments.

---

### Verifying Network Isolation

To audit Netfilter rules, routing tables, and DNS availability, run the built-in diagnostic auditor:

```bash
agy-sandbox diagnose
# Or run the script directly:
~/.antigravity-sandbox/scripts/diagnose.sh
```

The diagnostic suite validates 6 security checkpoints:
1. **Docker Engine, Bridge Network (`agy_net`) & Readiness Marker:** Verifies daemon responsiveness, dynamic subnet discovery, bridge name mapping, and `/run/agy-sandbox/network.ready` existence.
2. **Kernel Bridge Interface (`agy0`):** Confirms link existence and state in kernel.
3. **Linux Kernel Policy Routing (`ip rule`):** Confirms priority 95 intra-subnet allowance (`lookup main`) and priority 100 `unreachable` rules across all 12 private/special IPv4 ranges, strictly scoped to incoming interface `iif agy0`.
4. **Netfilter Packet Filtering (`iptables` / `ip6tables`):** Audits atomic jumps to custom chains `AGY-SANDBOX-FWD` and `AGY-SANDBOX-IN`, intra-subnet `RETURN`, DROP rules for all 12 private destination ranges, and host input restrictions (only port 53 DNS allowed).
5. **DNS Resolver Reachability:** Issues a UDP query to Quad9 DNS (`9.9.9.9`) from the bridge interface.
6. **Egress Connectivity & Intranet Isolation:** Probes public HTTPS connectivity and validates that host-internal endpoints are completely blocked (without requiring elevated raw socket privileges).

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
* conditionally runs the `QNIX-Dev/eligibility-antigravity-patcher` patcher (if `AGY_PATCH=true`);
* conditionally locks the binary against modification (`chmod 555`) when a version is pinned, or preserves `chmod 755` for `latest`;
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
│   ├── install-agy.sh              # Standalone CLI downloader and version pinner
│   └── setup.sh                    # Initial container setup (agy patch, volume permissions)
├── scripts/
│   ├── sandbox.conf                # Central configuration (SSOT for network, bridge, subnets, and DNS)
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
