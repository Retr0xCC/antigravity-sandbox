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

## Host Requirements

Before deploying Antigravity Sandbox, ensure your host meets the following prerequisites:

* **Operating System:** Linux with kernel support for Routing Policy Database (RPDB / `ip rule`) and Netfilter (`iptables` and `ip6tables`).
* **Container Engine:** Docker Engine (20.10+) with Docker Buildx support (for multi-stage, reproducible, hash-pinned image builds).
* **Host CLI Utilities:** `iproute2` (`ip rule`, `ip route`), `iptables`, `jq`, `git` (2.20+), and `systemd` (for persistent network isolation daemon).
* **Permissions:** Administrative (`sudo`) privileges for network setup and systemd service installation. No root privileges are required for development inside the container.

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
                                 │  Mounts target project or isolated worktree
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                           Sandbox                           │
 │                                                             │
 │   - Unprivileged user: 'vscode' (UID 1000)                  │
 │   - Supply Chain Pinning: uv (SHA256), patcher (commit SHA) │
 │   - Offline patcher: /usr/local/share/agy-sandbox/patcher   │
 │   - Immutable setup: /usr/local/share/agy-sandbox/setup.sh  │
 │   - Security options: --security-opt=no-new-privileges:true │
 │   - Dropped capabilities: --cap-drop=NET_RAW                │
 │   - Resource limits: memory=8g, cpus=4, pids-limit=2048     │
 │   - Read-only .devcontainer: mounts source/.devcontainer:ro │
 │   - Git VFS Read-Only mounts: .git/hooks, config, info (ro) │
 │   - Pinned binary write lock: chmod 555 agy                 │
 │   - Credential leaks blocked: askpass=/bin/false, IPC null  │
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

- **Dedicated Netfilter chains (`AGY-SANDBOX-FWD` & `AGY-SANDBOX-IN`):** Network filtering is isolated into dedicated custom chains anchored to `DOCKER-USER` and `INPUT`. Forward transit traffic from container bridge `agy0` to all private/special IPv4 ranges (RFC 1918, CGNAT `100.64.0.0/10`, link-local `169.254.0.0/16`, loopback, multicast, testnets) is unconditionally dropped. Host listening ports (SSH, DB, Docker daemon socket) are blocked via `AGY-SANDBOX-IN`, permitting only host DNS resolution (port 53 UDP/TCP) and established connections (`ESTABLISHED,RELATED`).
- **Fail-Closed readiness marker:** Container startup strictly requires a healthy, isolated network state. `ensure-network.sh` creates the marker `/run/agy-sandbox/network.ready` only after all bridge, Netfilter, and RPDB routing rules are successfully applied and verified. Both the sandbox CLI initializer (`init-sandbox.sh`) and Dev Container `initializeCommand` halt container startup in Fail-Closed mode if this marker or RPDB rules are missing.
- **Two-tier RPDB kernel policy routing:** Routing rules are strictly bound to the incoming interface (`iif agy0`), guaranteeing protection even when split-tunnel VPNs manipulate host main/default routing tables. Intra-subnet traffic is allowed at priority 95 (`lookup main`), while private/special destination CIDRs are immediately rejected at priority 100 (`unreachable`).
- **Pre-baked offline patcher & supply chain pinning:** The Docker image build pins external dependencies with immutable digests (`ghcr.io/astral-sh/uv` by sha256, `QNIX-Dev/eligibility-antigravity-patcher` by commit `90498f50353d414232f593dffe88899bc80b6312`). The patcher is pre-installed at image build time into `/usr/local/share/agy-sandbox/patcher` (owned by `root:root`). At container startup, `setup.sh` runs the patcher purely offline without `git clone` or external network access.
- **Host credential & IPC neutralization:** Dev Container settings automatically enforce `dev.containers.copyGitConfig: false`, `dev.containers.dockerCredentialHelper: false`, `git.terminalAuthentication: false`, and `github.gitAuthentication: false`. `remoteEnv` nullifies `SSH_AUTH_SOCK`, `VSCODE_GIT_IPC_HANDLE`, and sets askpass tools to `/bin/false`. Startup scripts continuously purge forwarded host authentication sockets.
- **Hardened systemd daemon:** Network service scripts and configuration are copied to `/usr/local/lib/agy-sandbox/` owned by `root:root` with read-only permissions (`0755`/`0644`), eliminating Local Privilege Escalation (LPE) vulnerabilities. The systemd unit runs with isolation parameters `ProtectHome=yes`, `ProtectSystem=full`, `PrivateTmp=yes`, and manages the `/run/agy-sandbox` runtime directory.
- **Dynamic Docker IPAM with zero conflicts:** By default, subnets are assigned automatically through standard Docker IPAM from the conflict-free pool (`172.17.0.0/16`-`172.31.0.0/16`), with support for explicit static subnet overrides via `sandbox.conf`.
- **Isolated dual DNS (`9.9.9.9`, `149.112.112.112`):** Queries resolve directly through Quad9 upstream resolvers bypassing the host resolver, preventing DNS leaks and local host scanning via NetBIOS/mDNS.
- **Dropped network & system privileges:** The container runs with `--security-opt=no-new-privileges:true` and drops `CAP_NET_RAW` capability, preventing raw socket manipulation, ICMP packet craft, ARP spoofing, or modifying internal network tables.
- **Binary modification protection:** For pinned CLI versions (`AGY_VERSION != latest`), permissions on the `agy` binary are fixed to read and execute (`chmod 555`), and auto-update is blocked via `AGY_CLI_DISABLE_AUTO_UPDATE=1`. When running with `latest`, standard executable permissions (`chmod 755`) are preserved and self-updates remain active.
- **Authorization and history isolation:** Session tokens and chat history are saved in a dedicated Docker volume (`agy-gemini-data-${localWorkspaceFolderBasename} -> /home/vscode/.gemini`), without mixing with repository files on the host.
- **Protected `.devcontainer` configuration:** The `.devcontainer` directory is mounted read-only (`type=bind,readonly`) inside the container, preventing an in-container agent from tampering with container lifecycle scripts or `devcontainer.json`.

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

When run without arguments in an interactive terminal, opens the interactive menu (TUI).

Options:
  -i, --interactive              Interactive project, template, and version selection (TUI)
  -w, --worktree                 Create and run sandbox inside an isolated Git worktree
  --worktree-branch <name>       Git branch for worktree (default: 'agy-sandbox', implies --worktree)
  --mount <host:container[:ro|rw]> Bind mount host path into container (default mode: ro)
  -v, --agy-version <tag>        Pin specific Antigravity CLI version (e.g. 1.4.6, latest)
  --patch                        Apply QNIX-Dev eligibility patch to CLI binary (default)
  --no-patch, --skip-patch       Disable patch, keep clean official binary
  -l, --list                     List available templates
  -d, --diagnose                 Audit and diagnose security guardrails & network rules
  --service [COMMAND]            Manage systemd service (status | enable | disable | install)
  --install-bin                  Install agy-sandbox symlink in ~/.local/bin
  -h, --help                     Show help message

Examples:
  agy-sandbox /path/to/project node
  agy-sandbox --worktree /path/to/project python
  agy-sandbox --worktree --worktree-branch experiment-1 /path/to/project
  agy-sandbox --mount /tmp/datasets:/data:ro /path/to/project
```

#### Git Worktree Isolation Mode (`--worktree`)

When developing on existing repositories, giving an AI coding agent direct write access to your main project working tree creates risks: a hallucinating or compromised agent could modify build scripts, configuration files, or hook scripts that you might later execute on your host machine.

The `--worktree` flag provides complete filesystem separation using Git worktrees:

* **Adjacent Sandbox Directory:** The initializer automatically checks out an isolated Git worktree adjacent to your repository (`<repo>-sandbox`) on a dedicated branch (default: `agy-sandbox`, customizable via `--worktree-branch <branch>`).
* **VFS Read-Only Protection for Git Metadata:** Inside the worktree, Git requires access to the parent `.git` common directory. The sandbox mounts the parent `.git` directory and overlays kernel VFS Read-Only bind mounts directly on `.git/hooks`, `.git/config`, and `.git/info`. This physically blocks the container from writing malicious Git hooks (e.g. `pre-commit`) or modifying Git configuration to execute arbitrary code on the host.
* **Safe Exclusion:** `.devcontainer/` is added to `${main_git_dir}/info/exclude`, ensuring that container configurations never clutter git status or get committed into the repository.
* **Recommended Workflow:**
  1. Initialize sandbox: `agy-sandbox --worktree /path/to/project`
  2. Open the worktree: `code /path/to/project-sandbox`
  3. Reopen in Container (`F1` -> `Dev Containers: Reopen in Container`).
  4. Allow the agent to perform coding tasks inside the worktree.
  5. On your host machine, review the changes via `git diff main..agy-sandbox`, run local verification tests, and safely merge the branch when satisfied.

#### Secure Custom Mounts (`--mount`)

If your project requires additional datasets or shared assets outside the repository, pass the `--mount` flag (can be specified multiple times):

```bash
# Default mode: Read-Only (:ro)
agy-sandbox --mount /var/data/shared:/data:ro /path/to/project

# Omitting mode defaults safely to Read-Only with an informational notice:
agy-sandbox --mount /var/data/shared:/data /path/to/project

# Explicit Read-Write mode (use cautiously):
agy-sandbox --mount /var/data/output:/output:rw /path/to/project
```

**Security Blacklist Guardrails:**
To prevent accidental host compromise or privilege escalation, the initializer strictly verifies and forbids mounting:
* Root filesystem (`/`);
* Host system directories and their subdirectories: `/etc`, `/usr`, `/var`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/proc`, `/sys`, `/dev`, `/run`, `/root`;
* Docker daemon sockets (`/var/run/docker.sock`, `/run/docker.sock`);
* User home directory (`$HOME`) entirely;
* Sensitive directories in `$HOME`: `.ssh`, `.gnupg`, `.aws`, `.kube`, `.config`, `.docker`, `.local` (and their subdirectories).
Any attempt to mount a blacklisted path immediately terminates initialization with a fatal security error.

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
| `PIDS_LIMIT` | `"2048"` | Maximum container PID count limit to prevent fork bombs. |
| `MEMORY_LIMIT` | `"8g"` | Maximum container RAM allocation limit. |
| `CPUS_LIMIT` | `"4"` | Maximum container CPU cores limit. |
| `TMPFS_SIZE` | `"2g"` | Size of the in-memory `/tmp` mount (`rw,nosuid,nodev`). |

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

The diagnostic suite validates 8 comprehensive security checkpoints:
1. **Docker Engine, Bridge Network (`agy_net`) & Readiness Marker:** Verifies daemon responsiveness, dynamic subnet discovery, bridge name mapping, and `/run/agy-sandbox/network.ready` existence.
2. **Kernel Bridge Interface (`agy0`):** Confirms link existence and state in kernel.
3. **Linux Kernel Policy Routing (`ip rule`):** Confirms priority 95 intra-subnet allowance (`lookup main`) and priority 100 `unreachable` rules across all 12 private/special IPv4 ranges, strictly scoped to incoming interface `iif agy0`.
4. **Netfilter Packet Filtering (`iptables` / `ip6tables`):** Audits atomic jumps to custom chains `AGY-SANDBOX-FWD` and `AGY-SANDBOX-IN`, intra-subnet `RETURN`, DROP rules for all 12 private destination ranges, and host input restrictions (only port 53 DNS allowed).
5. **IPv6 Boundary & Systemd Persistence:** Audits IPv6 disable sysctl on `agy0`, ip6tables availability, and verifies that systemd service runs from immutable `/usr/local/lib/agy-sandbox/`.
6. **Supply Chain Pinning & Image Integrity:** Verifies immutable sha256 digest for `uv`, commit-pinned patcher, unprivileged volume permissions, root-owned scripts in `/usr/local/share/agy-sandbox/`, and Git worktree `safe.directory` logic.
7. **Dev Container Specification & Runtime Hardening:** Static audit of credential blocking flags, Askpass neutralization, Fail-Closed `initializeCommand`, `runArgs` security options, readonly `.devcontainer` mount, and CLI flags (`--worktree`, `--mount`).
8. **Container Boundary Verification & Live Egress Probes:** Live inspection of active containers (`no-new-privileges`, `NET_RAW` capability drop, pids limit), Read-Only `.git` worktree mounts (`hooks`, `config`, `info`), and non-privileged TCP socket egress probes.

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

The initial setup script `setup.sh` is pre-baked in `/usr/local/share/agy-sandbox/setup.sh` and runs during container creation (`postCreateCommand`):
* Verifies non-root writable permissions on the `/home/vscode/.gemini` state volume;
* Safely registers the target workspace in Git `safe.directory`, automatically resolving Git worktree pointers (`gitdir:`) to avoid dubious ownership errors without insecure wildcards (`safe.directory "*"`);
* Conditionally executes the pre-baked patcher (`/usr/local/share/agy-sandbox/patcher/manager.py`) purely offline without downloading external code;
* Locks the binary against modification (`chmod 555`) when a version is pinned, or preserves `chmod 755` for `latest`;
* Purges any forwarded host authentication sockets and copied credentials;
* Creates the `/home/vscode/.agy_initialized` marker, preventing repeated execution on restarts.

---

## Security Model and Residual Risks

### What is 100% Closed (Zero-Trust Guardrails)

The Antigravity Sandbox implements defense-in-depth across multiple layers:

| Attack Vector | Security Mechanism | Protection Level |
| :--- | :--- | :--- |
| **Local Network (LAN) & Intranet Scanning** | RPDB interface-bound rules (`iif agy0` priority 100 `unreachable`) & Netfilter `AGY-SANDBOX-FWD` DROP | **100% Blocked** (kernel level) |
| **Cloud Metadata Theft (`169.254.169.254`)** | Explicit routing and firewall rejection of link-local IP ranges | **100% Blocked** |
| **Host Services Access (SSH, DB, Ollama, Docker socket)** | Netfilter `AGY-SANDBOX-IN` DROP on `agy0` (only port 53 DNS allowed) | **100% Blocked** |
| **Host Credentials & Secret Sockets Leak** | VS Code setting overrides (`copyGitConfig: false`, `dockerCredentialHelper: false`), `remoteEnv` askpass/IPC nullification, startup socket deletion | **100% Neutralized** |
| **Container Breakout & Kernel Attacks** | `--security-opt=no-new-privileges:true`, `--cap-drop=NET_RAW`, unprivileged user (`vscode`), pids/memory/cpus limits | **Hardened** |
| **Container Configuration Tampering** | Read-only bind mount for `.devcontainer/` inside container | **100% Protected** |
| **Supply Chain Tampering at Build Time** | Digest-pinned `uv` (`sha256:32a...`), commit-pinned patcher (`90498f50353d`), pre-baked offline patcher in root-owned `/usr/local/share/agy-sandbox/patcher` | **100% Immutable** |
| **Git Hooks / Config Injection (`--worktree` mode)** | Kernel VFS Read-Only bind mounts on `.git/hooks`, `.git/config`, and `.git/info` | **100% Protected** (VFS Read-Only) |

### Residual Risk (Direct Mounts WITHOUT `--worktree`)

> [!WARNING]
> When running the sandbox directly against an existing host repository **without** the `--worktree` flag, the container has direct write access to your project workspace files.

If your project contains build scripts, configuration files, or task definitions that are executed on your host:
* `Makefile`, `build.sh`, `configure`
* `package.json` (`scripts`, `preinstall`, `postinstall`)
* `.vscode/tasks.json` or `.vscode/launch.json`
* Python setup files (`setup.py`, `pyproject.toml`)

A hallucinating or malicious AI model could modify these scripts inside the container. If you subsequently run `make`, `npm test`, or execute a VS Code task on your host machine outside the sandbox, arbitrary code will execute on your host system with your user privileges.

**Guidance & Mitigation:**
* For untrusted code, external repositories, autonomous agent tasks, or sensitive developer environments, **ALWAYS run with `--worktree`**:
  ```bash
  agy-sandbox --worktree /path/to/project
  ```
* In worktree mode, any modifications made by Antigravity are strictly confined to the `<repo>-sandbox` directory and its isolated Git branch. Furthermore, the host's `.git/hooks` and `.git/config` are physically protected as Read-Only via VFS bind mounts.
* Never place unencrypted secrets, `.env` files with production credentials, or private SSH keys inside your workspace directory before launching the sandbox.

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
│   ├── sandbox.conf                # Central configuration (SSOT for network, host isolation, and container resource limits)
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

The sandbox environment incorporates the following pinned third-party dependencies:

* **[Astral uv](https://github.com/astral-sh/uv)** (image `ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff`):
  * **Purpose:** Ultra-fast, reproducible Python virtual environment and dependency installer used during image build.
  * **License:** Apache 2.0 / MIT.
* **[QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher)** (author: [QNIX-Dev](https://github.com/QNIX-Dev), commit `90498f50353d414232f593dffe88899bc80b6312`):
  * **Purpose:** Pre-baked into `/usr/local/share/agy-sandbox/patcher` at image build time to patch the Antigravity CLI binary offline.
  * **License:** MIT License.

---

## License

- **antigravity-sandbox** (network isolation scripts, TUI, environment templates) — [GNU General Public License v3.0](LICENSE).
- **eligibility-antigravity-patcher** — [MIT License](https://github.com/QNIX-Dev/eligibility-antigravity-patcher/blob/main/LICENSE).
