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
 │   - Decoupled state volumes:                                │
 │       agy-shared-config ──► /home/vscode/.gemini-shared     │
 │       agy-shared-cache  ──► /home/vscode/.cache             │
 │       agy-gemini-data   ──► /home/vscode/.gemini            │
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

- **Dedicated Netfilter chains (`AGY-SANDBOX-FWD` & `AGY-SANDBOX-IN`):** Network filtering is isolated into dedicated custom chains anchored to `DOCKER-USER` and `INPUT`. Forward transit traffic from container bridge `agy0` to all private/special IPv4 ranges (RFC 1918, CGNAT `100.64.0.0/10`, link-local `169.254.0.0/16`, loopback, multicast, RFC 5737 testnets) is unconditionally dropped. Host listening ports (SSH, DB, Docker daemon socket, host DNS on port 53) are 100% blocked via `AGY-SANDBOX-IN`, permitting only previously established connections (`ESTABLISHED,RELATED`). DNS resolution routes directly to external upstream Quad9 resolvers (`9.9.9.9`, `149.112.112.112`).
- **Fail-Closed readiness marker:** Container startup strictly requires a healthy, isolated network state. `ensure-network.sh` creates the marker `/run/agy-sandbox/network.ready` only after all bridge, Netfilter, and RPDB routing rules are successfully applied and verified. Both the sandbox CLI initializer (`init-sandbox.sh`) and Dev Container `initializeCommand` halt container startup in Fail-Closed mode if this marker or RPDB rules are missing.
- **Two-tier RPDB kernel policy routing:** Routing rules are strictly bound to the incoming interface (`iif agy0`), guaranteeing protection even when split-tunnel VPNs manipulate host main/default routing tables. Inter-container communication is disabled (`enable_icc=false`), while private/special destination CIDRs are immediately rejected at priority 100 (`unreachable`).
- **Pre-baked offline patcher & supply chain pinning:** The Docker image build pins external dependencies with immutable digests (`ghcr.io/astral-sh/uv` by sha256, `QNIX-Dev/eligibility-antigravity-patcher` by commit `90498f50353d414232f593dffe88899bc80b6312`). The patcher is pre-installed at image build time into `/usr/local/share/agy-sandbox/patcher` (owned by `root:root`). At container startup, `setup.sh` runs the patcher purely offline without `git clone` or external network access.
- **Host credential, socket & IPC neutralization (VULN-04 & NEW-05):**
  - *Host vs container scope:* Options `dev.containers.copyGitConfig`, `dev.containers.dockerCredentialHelper`, `dev.containers.mountWaylandSocket`, and `dev.containers.forwardGpg` are evaluated by the Dev Containers extension on the **host** prior to container creation. `diagnose.sh` audits host IDE user settings (`~/.config/Code/User/settings.json`) to verify that developers keep these flags disabled on the host.
  - *In-container defense-in-depth:* `remoteEnv` nullifies `SSH_AUTH_SOCK`, `VSCODE_GIT_IPC_HANDLE`, `WAYLAND_DISPLAY`, `VSCODE_IPC_HOOK_CLI`, and sets askpass helpers to `/bin/false`.
  - *Socket disarmament and elimination of reconnection race window (`postAttachCommand`):* Both on initial container startup (`postStartCommand`) and on EVERY window attach / reload (`postAttachCommand`), forwarded sockets are purged and disarmed: Wayland sockets (`vscode-wayland-*.sock`) are set to `chmod 000` (blocking connections even with bind mounts present), `gpg-agent` sockets (`S.gpg-agent*`) are purged and set to `chmod 000`, and Docker registry credentials (`~/.docker/config.json`) are deleted. Internal `vscode-ipc-*.sock` sockets are retained to preserve stable operation of the integrated terminal and CLI editor inside the container, while host CLI escalation is securely neutralized via `VSCODE_IPC_HOOK_CLI=""` in `remoteEnv`.
  - *Git functionality preservation via strict whitelist:* To ensure `git commit` continues to operate inside the sandbox, only safe identity settings are retained from copied host `~/.gitconfig` via a strict whitelist (`user.name`, `user.email`, `init.defaultBranch`), while all credential subsections (`credential`, `http`), auth tokens, SSH commands, and custom hooks are purged on container start and reconnect. `safe.directory` is configured in `/home/vscode/.config/git/config`, which is never overwritten by host sync.
  - *Port auto-forwarding lockdown:* `"remote.autoForwardPorts": false` and `"remote.restoreForwardedPorts": false` are strictly enforced to prevent background services from binding onto `127.0.0.1` of the host machine.
- **Hardened systemd daemon:** Network service scripts and configuration are copied to `/usr/local/lib/agy-sandbox/` owned by `root:root` with read-only permissions (`0755`/`0644`), eliminating Local Privilege Escalation (LPE) vulnerabilities. The systemd unit is linked to Docker (`PartOf=docker.service`, `WantedBy=... docker.service`), guaranteeing isolation recovery on Docker restarts. The systemd unit runs with isolation parameters `ProtectHome=yes`, `ProtectSystem=full`, `PrivateTmp=yes`, and manages the `/run/agy-sandbox` runtime directory.
- **Dynamic Docker IPAM with zero conflicts:** By default, subnets are assigned automatically through standard Docker IPAM from the conflict-free pool (`172.17.0.0/16`-`172.31.0.0/16`), with support for explicit static subnet overrides via `sandbox.conf`.
- **Isolated dual DNS (`9.9.9.9`, `149.112.112.112`):** Queries resolve directly through Quad9 upstream resolvers bypassing the host resolver, preventing DNS leaks and local host scanning via NetBIOS/mDNS.
- **Dropped network & system privileges and sudo elimination:** The container environment is strictly rootless (unprivileged user `vscode`, UID 1000). The `sudo` package and `/etc/sudoers*` configurations are completely purged from the image at build time. The container runs with mandatory `--security-opt=no-new-privileges:true` and drops `CAP_NET_RAW` capability, preventing raw socket manipulation, ICMP packet craft, ARP spoofing, or root privilege escalation inside the container.
- **Fail-Closed `jq` prerequisite validation:** Assembling Dev Container configurations (`init-sandbox.sh`) strictly requires the `jq` utility on the host. Generation attempts without `jq` immediately abort with exit code 1, preventing security degradation and silent fallback omission of security mounts.
- **Target directory security blacklist validation (VULN-05 & NEW-03):** The sandbox project directory (`target_dir`) and extra mount paths (`--mount`) are verified with canonical path resolution (`realpath -m`). Root filesystem (`/`), host system paths (`/etc`, `/usr`, `/proc`, `/sys`), user root home directory (`$HOME` / `~`), ancestor paths (`/home`, `/Users`, and any parent of `$HOME`), hidden dotfiles and dotdirs under `$HOME`, commas in mount options, and protected container system directories are strictly blocked. All legitimate project subdirectories under `$HOME` (`~/projects/...`, `~/code/...`) and external workspace trees are fully permitted.
- **Universal custom template hardening (Full Custom Mode & OPEN-03):** When utilizing custom templates (containing `devcontainer.json` and/or `Dockerfile`), the initializer enforces the full security baseline: templates providing only `Dockerfile` automatically receive the secured `base/devcontainer.json`; any `devcontainer.json` is unconditionally hardened with `--security-opt=no-new-privileges:true`, askpass/IPC neutralization, read-only `.devcontainer` bind mount, Fail-Closed `initializeCommand` validation, and host resource limits, while `privileged: true`, `capAdd`, `--privileged`, and `--cap-add` are strictly stripped.
- **Binary modification protection:** For pinned CLI versions (`AGY_VERSION != latest`), permissions on the `agy` binary are fixed to read and execute (`chmod 555`), and auto-update is blocked via `AGY_CLI_DISABLE_AUTO_UPDATE=1`. When running with `latest`, standard executable permissions (`chmod 755`) are preserved and self-updates remain active.
- **Decoupled persistent volume storage & package caching (VULN-02 & NEW-04):** Global shared configuration (auth credentials, settings, installation ID) can be preserved in a shared Docker volume (`agy-shared-config -> /home/vscode/.gemini-shared`). Setup copies auth files independently on container creation (Copy-on-Initialize, without symlinks), defeating cross-sandbox RCE. MCP configuration (`config/mcp_config.json`) is strictly project-isolated. Onboarding tokens into the shared volume (running with `--shared-config rw`) is performed via the `agy-sync-auth` helper command. For untrusted repositories, `--shared-config isolated` is recommended. Shared asset and wheel caching is managed via (`agy-shared-cache -> /home/vscode/.cache`). Project-isolated context is kept in `agy-gemini-data-${localWorkspaceFolderBasename}-${pathHash}`.
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
agy-sandbox /path/to/project [template] -v 1.5.3
```

#### CLI Parameters

```text
Usage: agy-sandbox [OPTIONS] [PROJECT_DIR] [TEMPLATE]

When run without arguments in an interactive terminal, opens the interactive menu (TUI).

Options:
  -i, --interactive              Interactive project, template, and version selection (TUI)
  -w, --worktree, --isolate      Create and run sandbox inside an isolated Git clone
  --worktree-branch <name>       Git branch for sandbox clone (default: 'agy-sandbox', implies --worktree)
  -r, --review [DIR] [BRANCH]    Safely fetch and review sandbox changes in main repository
  --mount <host:container[:ro|rw]> Bind mount host path into container (default mode: ro)
  -v, --agy-version <tag>        Pin specific Antigravity CLI version (e.g. 1.5.3, latest)
  --pin, --pinned                Force version pinning (locks binary chmod 555, disables auto-update)
  --no-pin, --unpinned           Disable pinning (uses 'latest' unless -v specified, auto-update enabled)
  --patch                        Apply QNIX-Dev eligibility patch to CLI binary (default)
  --no-patch, --skip-patch       Disable patch, keep clean official binary
  --patcher-commit <sha>         Pin specific 40-character Git commit SHA for eligibility patcher
  --shared-config <mode>         Shared auth/config mount mode (readonly|rw|isolated|none, default: readonly)
  --shared-cache                 Share package and binary cache across sandboxes
  --no-shared-cache              Isolate package cache per sandbox (default: isolated)
  -l, --list                     List available templates
  -d, --diagnose                 Audit and diagnose security guardrails & network rules
  --service [COMMAND]            Manage systemd service (status | enable | disable | install)
  --install-bin                  Install agy-sandbox symlink in ~/.local/bin
  -h, --help                     Show help message

Examples:
  agy-sandbox /path/to/project default
  agy-sandbox --worktree /path/to/project math-labs
  agy-sandbox --worktree --worktree-branch experiment-1 /path/to/project
  agy-sandbox --review /path/to/project agy-sandbox
  agy-sandbox --mount /srv/datasets:/data:ro /path/to/project
```

#### Recommended Host VS Code / Cursor Settings (Zero-Trust)

Because the Dev Containers extension processes socket forwarding and credential inheritance on the **host** before container creation, it is recommended to add the following directives to your global editor settings on the host (`F1 -> Preferences: Open User Settings (JSON)`):

```json
{
  "dev.containers.copyGitConfig": false,
  "dev.containers.dockerCredentialHelper": false,
  "dev.containers.mountWaylandSocket": false,
  "dev.containers.forwardGpg": false
}
```

The `./scripts/diagnose.sh` script automatically audits host VS Code and Cursor configuration files and reports their status.

#### Full Repository Isolation Mode (Isolated Sandbox Clone, `--worktree` / `--isolate`)

When developing on existing repositories, giving an AI coding agent direct write access to your main project working tree creates risks: a compromised model could modify build scripts, configuration files, or hook scripts that you might later execute on your host machine.

The `--worktree` flag (aliases: `--isolate`, `--clone`) provides strict physical isolation based on a standalone local Git clone with VFS Read-Only metadata protection:

* **Physical Isolation of the Host Repository (Fix VULN-01):** Instead of an insecure shared `.git` directory (as in traditional `git worktree`, where `.git` pointer hijacking or corrupting `refs/heads/main` led to Host RCE), the sandbox deploys as an **independent clone** (`<repo>-sandbox`) on the `agy-sandbox` branch with `--no-hardlinks`. The host's main repository directory is **never mounted into the container** (0% attack surface against your `main` branch, commit history, index, or host submodules).
* **Hardlink Attack Prevention (`--no-hardlinks`):** Cloning without hard links guarantees that Git object files inside the sandbox have independent filesystem inodes and are physically separated from host files.
* **VFS Read-Only Protection for Git Metadata:** Inside the sandbox clone, `.git/hooks`, `.git/info`, and the `.git/config` file are mounted by the Linux kernel with `readonly` flags. This physically blocks the container from modifying Git configuration (directives like `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`) or injecting malicious executable hooks.
* **Safe Exclusion:** `.devcontainer/` is added to `.git/info/exclude` in the sandbox, ensuring that container configurations never clutter git status or get committed.
* **Safe Review & Merge Workflow:**
  1. Initialize sandbox: `agy-sandbox --worktree /path/to/project`
  2. Open the sandbox in VS Code: `code /path/to/project-sandbox`
  3. Reopen in Container (`F1` -> `Dev Containers: Reopen in Container`).
  4. Allow the agent to perform coding tasks inside the sandbox.
  5. On your host machine, safely review changes with a single command:
     ```bash
     agy-sandbox --review /path/to/project agy-sandbox
     ```
     (or manually: `cd /path/to/project && git fetch /path/to/project-sandbox agy-sandbox && git diff HEAD..FETCH_HEAD`).
     Because changes are fetched strictly over the Git transport protocol (`upload-pack`), Git on the host only pulls commit and tree objects and never reads or executes configuration files or hooks from the sandbox.
  6. Safely merge the reviewed changes:
     ```bash
     cd /path/to/project && git merge FETCH_HEAD
     ```

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

By default, sandboxes deploy with a pinned stable CLI version (`1.5.3`), preventing breaking changes from unexpected upstream updates, and apply the `QNIX-Dev` eligibility patch.

* **Centralized Configuration via `scripts/sandbox.conf` (SSOT):** Parameters `AGY_VERSION`, `AGY_PATCH`, `AGY_PINNED`, `PATCHER_REPO`, and `PATCHER_COMMIT` are configured in `sandbox.conf`. When pinned (`AGY_VERSION != latest`), the sandbox automatically locks the binary (`chmod 555`) and blocks auto-updates (`AGY_CLI_DISABLE_AUTO_UPDATE=true` in `~/.bashrc`). For `latest`, the binary retains standard permissions (`chmod 755`) and self-updates remain enabled.
* **Automatic Pinning ("Pinning without explicit mention"):** When `AGY_PINNED` is left empty (`""`), pinning is automatically enabled with the patch (`AGY_PATCH="true" -> AGY_PINNED="true"`), preventing breaking changes from unexpected upstream updates. When the patch is disabled (`--no-patch` or `AGY_PATCH="false"`), pinning is automatically disabled (`AGY_PINNED="false"`), defaulting to the clean official `latest` release with auto-updates permitted.
* **Explicit Pinning Overrides:** CLI flags `--pin` and `--no-pin` (or setting `AGY_PINNED="true"` / `"false"` in `sandbox.conf`) allow overriding the automatic inference (e.g., pinning a clean unmodified version `1.5.3` via `--no-patch --pin`).
* **Patcher Version Selection:** The eligibility patcher version is immutably pinned by commit SHA via `PATCHER_COMMIT` in `sandbox.conf` or the `--patcher-commit <sha>` CLI flag, guaranteeing supply chain integrity (Supply Chain Pinning).
* **Interactive TUI & CLI:** Wizard steps allow choosing between default stable (`1.5.3`), `latest`, custom tags, and toggling the patcher. CLI flags `-v, --agy-version <tag>`, `--pin`, `--no-pin`, `--no-patch`, and `--patcher-commit <sha>` allow non-interactive specification.

#### Cross-Container Isolation & Shared Volume Hardening (Fix VULN-02)

When running multiple sandboxes across different projects (especially with untrusted external code), sharing Read-Write volumes presents severe risks of Cross-Sandbox RCE, cache poisoning, and token theft. The sandbox implements strict defense-in-depth boundaries:

* **MCP Configuration Isolation (`config/mcp_config.json`):** The `mcp_config.json` file is strictly excluded from shared volumes and stored only inside the project-isolated volume `~/.gemini/config/`. This eliminates the possibility of one container injecting malicious MCP server commands into other sandboxes.
* **VFS Read-Only Mount for Global Config (`SHARED_CONFIG="readonly"`):** The global volume `agy-shared-config` is mounted by the Linux kernel into `/home/vscode/.gemini-shared` as `readonly`. OAuth tokens and global settings are safely inherited using Copy-on-Initialize into the local project volume on container creation, enabling local session updates without modifying global state.
* **Cryptographic Release Verification (SHA256):** `install-agy.sh` computes and validates SHA256 checksums for both newly downloaded and cached release tarballs in `/home/vscode/.cache/agy-downloads`, completely preventing supply chain cache poisoning attacks.
* **Per-Project Cache Isolation (`SHARED_CACHE="false"`):** By default, each project uses its own dedicated cache volume (`agy-cache-<project>-<hash>`), eliminating dependency poisoning vectors across untrusted projects (Python wheels in UV_CACHE_DIR, go build cache, npm).
* **Deterministic Path Hashing for Project Volumes:** Project volume names are constructed as `agy-gemini-data-<folder_basename>-<path_hash>`, where `<path_hash>` is an 8-character SHA256 digest of the host directory path. Projects with identical folder names in different directories are guaranteed distinct volumes.

Available template profiles:
- `default` (default) — Clean base environment: antigravity-cli, uv, git, and a standard set of build tools.
- `affine-mcp` — Profile for AFFiNE Cloud and external instances integration via MCP (Node.js 22 LTS, affine-mcp-server 3.11.0, interactive `affine-setup` wizard).
- `rpi-edge-node` — Profile for edge node and gateway automation with Ansible (2.18+), `ansible-lint`, `yamllint`, `community.general` collection, Go (1.22+), OpenSSH client, and VS Code extensions (`redhat.ansible`, `golang.go`, `redhat.vscode-yaml`, `even-better-toml`, `samuelcolvin.jinjahtml` for Jinja2 `.j2` templates).
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
| `AGY_VERSION` | `"1.5.3"` | Target Antigravity CLI version to install (`"1.5.3"`, `"latest"`, or specific SemVer tag). |
| `AGY_PATCH` | `"true"` | Apply QNIX-Dev eligibility patch to CLI binary (`"true"` or `"false"`). |
| `AGY_PINNED` | `""` | Version pinning & auto-update lockdown (`"true"`, `"false"`, or `""`). When empty, pinning is automatically enabled when patch is active (`AGY_PATCH="true"`) and automatically disabled when patch is inactive (`AGY_PATCH="false"`, switching default to `latest`). |
| `PATCHER_REPO` | `"https://github.com/QNIX-Dev/eligibility-antigravity-patcher.git"` | Git repository URL for the QNIX-Dev eligibility patcher. |
| `PATCHER_COMMIT` | `"90498f50353d414232f593dffe88899bc80b6312"` | Pinned commit hash (40-character immutable SHA) of the QNIX-Dev patcher. |
| `SHARED_CONFIG` | `"readonly"` | Global configuration mount mode for `/home/vscode/.gemini-shared` (`"readonly"`, `"isolated"`, or `"rw"`). In `"readonly"` mode, tokens are safely inherited via Copy-on-Initialize into the local project volume without exposing global state to writes (Fix VULN-02). |
| `SHARED_CACHE` | `"false"` | Package and binary download cache isolation mode for `/home/vscode/.cache` (`"false"` enforces per-project cache volumes `agy-cache-<project>-<hash>` to prevent dependency poisoning; `"true"` enables global shared cache `agy-shared-cache`). |

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
3. **Linux Kernel Policy Routing (`ip rule`):** Confirms priority 100 `unreachable` rules across all 15 private/special IPv4 ranges (including RFC 5737 testnets), strictly scoped to incoming interface `iif agy0`, and absence of intra-subnet bypasses.
4. **Netfilter Packet Filtering (`iptables` / `ip6tables`):** Audits atomic jumps to custom chains `AGY-SANDBOX-FWD` and `AGY-SANDBOX-IN`, DROP rules for all 15 destination ranges, and complete host input blockage (including port 53).
5. **IPv6 Boundary & Systemd Persistence:** Audits IPv6 disable sysctl on `agy0`, ip6tables availability, and verifies that systemd service runs from immutable `/usr/local/lib/agy-sandbox/`.
6. **Supply Chain Pinning & Image Integrity:** Verifies immutable sha256 digest for `uv`, commit-pinned patcher, unprivileged volume permissions, root-owned scripts in `/usr/local/share/agy-sandbox/`, and Git worktree `safe.directory` logic.
7. **Dev Container Specification & Runtime Hardening:** Static audit of credential blocking flags, Askpass neutralization, Fail-Closed `initializeCommand`, `runArgs` security options, readonly `.devcontainer` mount, and CLI flags (`--worktree`, `--mount`).
8. **Container Boundary Verification & Live Egress Probes:** Live inspection of active containers (`no-new-privileges`, `NET_RAW` capability drop, pids limit), Read-Only `.git` worktree mounts (`hooks`, `config`, `info`), and non-privileged TCP socket egress probes.

---

### Pruning Residual Containers (`agy-sandbox --clean`)

During Dev Container builds, rebuilds, or experiments, Docker may accumulate stopped (`Exited`), dead, or orphaned containers from deleted directories. However, regular stopped project containers (`Exited`) you plan to resume later are **never deleted without your explicit consent**.

Antigravity Sandbox provides a selective, interactive pruner:

```bash
# Interactive selector with numbered stopped containers:
agy-sandbox --clean

# Clean ONLY defunct/orphaned containers (whose folders were deleted on host):
agy-sandbox --clean --orphaned

# Preview without deleting (Dry-Run):
agy-sandbox --clean --dry-run

# Complete purge of all stopped containers and intermediate image layers:
agy-sandbox --clean --all -f
```

The feature is also available in the TUI menu via option `[4] 🧹 Prune Residual Containers & Artifacts`. The pruner clearly categorizes containers:
* **Active (Running):** Active projects — strictly protected and preserved.
* **Stopped (Exited):** Closed projects whose folders still exist on disk — displayed as a numbered checklist where you can selectively pick which ones to keep and which to remove.
* **Defunct / Orphaned:** Failed builds (`created`/`dead`) and containers whose workspace folders were deleted on host — safely pruned.

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
* Verifies non-root writable permissions on persistent volumes (`/home/vscode/.gemini`, `/home/vscode/.gemini-shared`);
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
| **Host Services Access (SSH, DB, Ollama, Docker socket)** | Netfilter `AGY-SANDBOX-IN` DROP on `agy0` (100% of host ports blocked, including port 53; DNS routes to external Quad9) | **100% Blocked** |
| **Host Credentials, Sockets (SSH, Git, Wayland, GPG) & IPC Leaks** | Purging and disarming sockets (`chmod 000` for Wayland/GPG) on `postStartCommand`/`postAttachCommand`, blocking `VSCODE_IPC_HOOK_CLI` in `remoteEnv`, cleaning `.docker/config.json`, sanitizing `~/.gitconfig` via strict key whitelist (`user.name`, `user.email`, `init.defaultBranch`), disabling `remote.autoForwardPorts`, host settings audit in `diagnose.sh` | **Neutralized in Container / Recommended Host Settings** |
| **Root Privilege Escalation Inside Container** | Complete removal of `sudo` and `/etc/sudoers*` from image, mandatory `--security-opt=no-new-privileges:true`, stripping `privileged: true` and `capAdd` in Full Custom Mode | **100% Prevented** (Rootless) |
| **Container Breakout & Kernel Attacks** | `--security-opt=no-new-privileges:true`, `--cap-drop=NET_RAW`, unprivileged user (`vscode`), pids/memory/cpus limits | **Hardened** |
| **Container Configuration Tampering & Host RCE** | Read-Only bind mount for `.devcontainer/` inside container, mandatory security filtering even in Full Custom Mode | **100% Protected** |
| **Supply Chain Tampering at Build Time** | Digest-pinned base image (`ubuntu-24.04@sha256:d94c...`), digest-pinned `uv` (`0.6.6@sha256:031d...`), commit-pinned patcher (`90498f50353d`), pre-baked offline patcher in root-owned `/usr/local/share/agy-sandbox/patcher` | **100% Immutable** |
| **Git Hooks / Config Injection / tasks.json (`--worktree` mode)** | Isolated repository clone (`--worktree`), Read-Only pointer mount, read-only `.vscode/` and `.git/modules/` mounts, prevention of host `.git` direct mounting | **100% Protected** (Isolated Clone) |
| **Accidental Mounting of Host $HOME or System Paths** | Host blacklist validation (`validate_target_dir` & `validate_and_parse_mount`) with symlink resolution (`realpath -m`), blocking `/home`, `/Users`, root `$HOME`, `/`, dotfiles, commas, and system dirs | **100% Blocked** |

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
├── base/
│   ├── devcontainer.json           # Base Dev Container specification
│   ├── Dockerfile                  # Base Docker image
│   ├── install-agy.sh              # Standalone CLI downloader and version pinner
│   └── setup.sh                    # Initial container setup (agy patch, volume permissions)
├── scripts/
│   ├── sandbox.conf                # Central configuration (SSOT for network, host isolation, and container resource limits)
│   ├── ensure-network.sh           # Creation of agy_net network, Netfilter rules, and ip rule
│   ├── teardown-network.sh         # Reset of filtering & routing rules (network removal with --delete-network)
│   ├── service.sh                  # Management of systemd unit (agy-sandbox-network.service)
│   ├── diagnose.sh                 # Host isolation and network rule audit script
│   ├── prune-containers.sh         # Cleanup of residual, exited, and orphaned containers/images
│   └── init-sandbox.sh             # CLI entry point (agy-sandbox) and TUI menu
├── templates/
│   ├── affine-mcp/                 # Profile for AFFiNE Cloud and external instances integration via MCP
│   │   ├── packages.txt            # System packages (ca-certificates, curl, gnupg, jq)
│   │   ├── extensions.txt          # VS Code extensions (Markdown, REST client)
│   │   ├── extra.Dockerfile        # Installation of Node.js 22 LTS and affine-mcp-server
│   │   ├── extra-setup.sh          # Session persistence in agy-shared-config and mcp_config.json
│   │   ├── affine-setup.sh         # Interactive connection and diagnostics wizard
│   │   ├── settings.json           # VS Code configuration
│   │   ├── README.md               # Connection guide and prompts
│   │   └── description.txt
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

* **[Microsoft Dev Containers Base Image](https://github.com/devcontainers/images)** (image `mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:d94c97dd9cacf183d0a6fd12a8e87b526e9e928307674ae9c94139139c0c6eae`):
  * **Purpose:** Minimal Ubuntu 24.04 LTS base container image providing hardened rootless runtime.
  * **License:** MIT License.
* **[Astral uv](https://github.com/astral-sh/uv)** (image `ghcr.io/astral-sh/uv:0.6.6@sha256:031ddbc79275e351a43cbb66f64d8cd314cc78c3878898f4ab4f147b092e8e2d`):
  * **Purpose:** Ultra-fast, reproducible Python virtual environment and dependency installer used during image build.
  * **License:** Apache 2.0 / MIT.
* **[QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher)** (author: [QNIX-Dev](https://github.com/QNIX-Dev), commit `90498f50353d414232f593dffe88899bc80b6312`):
  * **Purpose:** Pre-baked into `/usr/local/share/agy-sandbox/patcher` at image build time to patch the Antigravity CLI binary offline.
  * **License:** MIT License.

---

## License

- **antigravity-sandbox** (network isolation scripts, TUI, environment templates) — [GNU General Public License v3.0](LICENSE).
- **eligibility-antigravity-patcher** — [MIT License](https://github.com/QNIX-Dev/eligibility-antigravity-patcher/blob/main/LICENSE).
