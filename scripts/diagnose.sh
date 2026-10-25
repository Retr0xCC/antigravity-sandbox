#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Security Diagnostics
# Audits Docker network, Linux Policy Routing (ip rule),
# Netfilter AGY-SANDBOX-FWD & AGY-SANDBOX-IN isolation,
# IPv6 boundary, Systemd persistence & hardening, and
# Container egress boundary isolation.
# ========================================================

# Resolve symlinks to find real script location
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Save any explicit caller environment overrides before sourcing sandbox.conf
_ENV_NET="${NETWORK_NAME:-}"
_ENV_BR="${BRIDGE_NAME:-}"
_ENV_SUBNET="${SUBNET:-}"
_ENV_DNS1="${DNS_PRIMARY:-}"
_ENV_DNS2="${DNS_SECONDARY:-}"
_ENV_READY="${READY_FILE:-}"
_ENV_PIDS="${PIDS_LIMIT:-}"
_ENV_MEM="${MEMORY_LIMIT:-}"
_ENV_CPUS="${CPUS_LIMIT:-}"
_ENV_TMPFS="${TMPFS_SIZE:-}"

if [ -f "${SCRIPT_DIR}/sandbox.conf" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/sandbox.conf"
fi

# Apply environment variable overrides if explicitly provided
[ -n "${_ENV_NET}" ] && NETWORK_NAME="${_ENV_NET}"
[ -n "${_ENV_BR}" ] && BRIDGE_NAME="${_ENV_BR}"
[ -n "${_ENV_SUBNET}" ] && SUBNET="${_ENV_SUBNET}"
[ -n "${_ENV_DNS1}" ] && DNS_PRIMARY="${_ENV_DNS1}"
[ -n "${_ENV_DNS2}" ] && DNS_SECONDARY="${_ENV_DNS2}"
[ -n "${_ENV_READY}" ] && READY_FILE="${_ENV_READY}"
[ -n "${_ENV_PIDS}" ] && PIDS_LIMIT="${_ENV_PIDS}"
[ -n "${_ENV_MEM}" ] && MEMORY_LIMIT="${_ENV_MEM}"
[ -n "${_ENV_CPUS}" ] && CPUS_LIMIT="${_ENV_CPUS}"
[ -n "${_ENV_TMPFS}" ] && TMPFS_SIZE="${_ENV_TMPFS}"

ACTIVE_BRIDGE="${BRIDGE_NAME}"
ACTIVE_SUBNET="${SUBNET}"

if [ -f "${READY_FILE}" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in
      NETWORK_NAME) [ -n "$val" ] && NETWORK_NAME="$val" ;;
      ACTIVE_BRIDGE) [ -n "$val" ] && ACTIVE_BRIDGE="$val" ;;
      ACTIVE_SUBNET) [ -n "$val" ] && ACTIVE_SUBNET="$val" ;;
    esac
  done < "${READY_FILE}"
elif command -v docker >/dev/null 2>&1 && docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  subnet_found=$(docker network inspect "${NETWORK_NAME}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")
  if [ -n "${subnet_found}" ] && [ "${subnet_found}" != "<no value>" ]; then
    ACTIVE_SUBNET="${subnet_found}"
  fi
  bridge_opt=$(docker network inspect "${NETWORK_NAME}" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
  if [ -n "${bridge_opt}" ] && [ "${bridge_opt}" != "<no value>" ]; then
    ACTIVE_BRIDGE="${bridge_opt}"
  else
    net_id=$(docker network inspect "${NETWORK_NAME}" --format '{{.Id}}' 2>/dev/null || echo "")
    if [ -n "${net_id}" ]; then
      ACTIVE_BRIDGE="br-${net_id:0:12}"
    fi
  fi
fi

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

pass_count=0
warn_count=0
fail_count=0

log_pass() {
  echo -e "  [ ${CLR_GREEN}PASS${CLR_RESET} ] $1"
  ((pass_count++)) || true
}

log_warn() {
  echo -e "  [ ${CLR_YELLOW}WARN${CLR_RESET} ] $1"
  ((warn_count++)) || true
}

log_fail() {
  echo -e "  [ ${CLR_RED}FAIL${CLR_RESET} ] $1"
  ((fail_count++)) || true
}

log_info() {
  echo -e "  [ ${CLR_CYAN}INFO${CLR_RESET} ] $1"
}

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

BLOCKED_RANGES=(
  "0.0.0.0/8"
  "10.0.0.0/8"
  "100.64.0.0/10"
  "127.0.0.0/8"
  "169.254.0.0/16"
  "172.16.0.0/12"
  "192.0.0.0/24"
  "192.168.0.0/16"
  "198.18.0.0/15"
  "224.0.0.0/4"
  "240.0.0.0/4"
  "255.255.255.255/32"
)

echo -e "${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}       🛡️  ANTIGRAVITY SANDBOX SECURITY AUDITOR 🛡️          ${CLR_RESET}"
echo -e "${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo ""

# Container Egress Probe Helper (No CAP_NET_RAW / no ping)
audit_egress_isolation() {
  local exec_prefix="$1" # e.g. "" or "docker exec <cid>"
  local gw_ip="$2"

  echo -e "  Checking egress blocks via TCP sockets and HTTP (CAP_NET_RAW safe)..."

  # 1. Gateway host probe
  local gw_blocked=true
  for port in 22 80 2375 53; do
    if ${exec_prefix} timeout 2 bash -c "</dev/tcp/${gw_ip}/${port}" >/dev/null 2>&1; then
      log_fail "Host gateway socket ${gw_ip}:${port} is REACHABLE (HOST EXPOSED!)."
      gw_blocked=false
    fi
  done
  if [ "${gw_blocked}" = "true" ]; then
    log_pass "Host gateway sockets (${gw_ip}:22/80/2375/53) blocked from container."
  fi

  # 2. Cloud metadata probe (169.254.169.254)
  if ${exec_prefix} curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
    log_fail "Cloud metadata service (169.254.169.254) is REACHABLE!"
  elif ${exec_prefix} timeout 2 bash -c "</dev/tcp/169.254.169.254/80" >/dev/null 2>&1; then
    log_fail "Cloud metadata socket (169.254.169.254:80) is REACHABLE!"
  else
    log_pass "Cloud metadata service (169.254.169.254) blocked."
  fi

  # 3. CGNAT / Tailscale probe (100.64.0.1, 100.100.100.100)
  for cgnat_ip in "100.64.0.1" "100.100.100.100"; do
    if ${exec_prefix} timeout 2 bash -c "</dev/tcp/${cgnat_ip}/80" >/dev/null 2>&1; then
      log_fail "CGNAT/Tailscale socket ${cgnat_ip}:80 is REACHABLE!"
    else
      log_pass "CGNAT/Tailscale socket ${cgnat_ip}:80 blocked."
    fi
  done
}

# If explicitly requested container mode via CLI flag
if [ "${1:-}" = "--container" ] || [ "${1:-}" = "container" ] || [ "${1:-}" = "-c" ]; then
  echo -e "${CLR_BOLD}[In-Container Audit Mode]${CLR_RESET}"
  gw_ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' || echo "")
  if [ -z "${gw_ip}" ]; then
    gw_ip=$(echo "${ACTIVE_SUBNET}" | sed -E 's/\.[0-9]+\/[0-9]+$/\.1/')
  fi
  audit_egress_isolation "" "${gw_ip}"
  echo ""
  echo -e "${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
  echo -e "Audit Results:  ${CLR_GREEN}${pass_count} Passed${CLR_RESET}  |  ${CLR_YELLOW}${warn_count} Warnings${CLR_RESET}  |  ${CLR_RED}${fail_count} Failed${CLR_RESET}"
  if [ "${fail_count}" -eq 0 ]; then
    echo -e "${CLR_GREEN}${CLR_BOLD}🛡️  VERDICT: CONTAINER IS ISOLATED${CLR_RESET}"
    exit 0
  else
    echo -e "${CLR_RED}${CLR_BOLD}⚠️  VERDICT: CONTAINER LEAK DETECTED${CLR_RESET}"
    exit 1
  fi
fi

# --------------------------------------------------------
# 1. Docker Daemon, Bridge Network & Fail-Closed Marker
# --------------------------------------------------------
echo -e "${CLR_BOLD}[1/8] Docker Engine, Bridge Network (${NETWORK_NAME}) & Readiness Marker${CLR_RESET}"
if [ -f "${READY_FILE}" ]; then
  log_pass "Fail-Closed marker exists at ${READY_FILE} (network ready)."
else
  log_fail "Fail-Closed marker ${READY_FILE} is missing. Run ensure-network.sh."
fi

if ! command -v docker >/dev/null 2>&1; then
  log_fail "Docker CLI not found in PATH."
else
  if ! docker info >/dev/null 2>&1; then
    log_fail "Docker daemon is not running or current user lacks access."
  else
    log_pass "Docker daemon is responsive."

    if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
      subnet_found=$(docker network inspect "${NETWORK_NAME}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")
      if [ -n "${subnet_found}" ] && [ "${subnet_found}" = "${ACTIVE_SUBNET}" ]; then
        log_pass "Docker network '${NETWORK_NAME}' configured with subnet ${ACTIVE_SUBNET}."
      else
        log_warn "Docker network '${NETWORK_NAME}' has subnet '${subnet_found}' (expected ${ACTIVE_SUBNET})."
      fi

      bridge_opt=$(docker network inspect "${NETWORK_NAME}" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
      if [ -n "${bridge_opt}" ] && [ "${bridge_opt}" != "<no value>" ]; then
        if [ "${bridge_opt}" = "${ACTIVE_BRIDGE}" ]; then
          log_pass "Docker network bridge interface mapped to '${ACTIVE_BRIDGE}'."
        else
          log_info "Docker network bridge interface mapped to '${bridge_opt}'."
        fi
      else
        log_info "Docker network uses dynamic bridge '${ACTIVE_BRIDGE}'."
      fi
    else
      log_fail "Docker network '${NETWORK_NAME}' does not exist. Run ensure-network.sh."
    fi
  fi
fi
echo ""

# --------------------------------------------------------
# 2. Kernel Bridge Interface
# --------------------------------------------------------
echo -e "${CLR_BOLD}[2/8] Kernel Bridge Interface (${ACTIVE_BRIDGE})${CLR_RESET}"
if command -v ip >/dev/null 2>&1; then
  if ip link show "${ACTIVE_BRIDGE}" >/dev/null 2>&1; then
    log_pass "Interface '${ACTIVE_BRIDGE}' exists in kernel."
  elif [ "${ACTIVE_BRIDGE}" != "${BRIDGE_NAME}" ] && ip link show "${BRIDGE_NAME}" >/dev/null 2>&1; then
    log_pass "Interface '${BRIDGE_NAME}' exists in kernel."
  else
    log_fail "Bridge interface '${ACTIVE_BRIDGE}' not found in kernel ('ip link')."
  fi
else
  log_warn "'ip' command not found."
fi
echo ""

# --------------------------------------------------------
# 3. Linux Kernel Policy Routing (ip rule)
# --------------------------------------------------------
echo -e "${CLR_BOLD}[3/8] Linux Kernel Policy Routing (ip rule)${CLR_RESET}"
if command -v ip >/dev/null 2>&1; then
  rules_dump=$(${SUDO} ip rule show 2>/dev/null || ip rule show 2>/dev/null || echo "")

  # Rule pref 95: Intra-subnet lookup main bound to iif
  # Note: ip rule show prints 'to <dest>' before 'iif <dev>', and /32 is omitted by iproute2 for host bit length
  snet_pattern="(to ${ACTIVE_SUBNET}|to ${ACTIVE_SUBNET%/32})([[:space:]]|$)"
  if echo "${rules_dump}" | grep -E "^95:[[:space:]]+" | grep -F "iif ${ACTIVE_BRIDGE}" | grep -E "${snet_pattern}" | grep -E "lookup (main|254)" >/dev/null 2>&1; then
    log_pass "Rule prio 95: Intra-subnet traffic routing allowed (iif ${ACTIVE_BRIDGE} to ${ACTIVE_SUBNET} lookup main)."
  else
    log_fail "Rule prio 95: Missing intra-subnet rule (iif ${ACTIVE_BRIDGE} to ${ACTIVE_SUBNET} lookup main)."
  fi

  # Rules pref 100: Outbound unreachable for blocked ranges
  local_all_100_ok=true
  for cidr in "${BLOCKED_RANGES[@]}"; do
    cidr_pattern="(to ${cidr}|to ${cidr%/32})([[:space:]]|$)"
    if echo "${rules_dump}" | grep -E "^100:[[:space:]]+" | grep -F "iif ${ACTIVE_BRIDGE}" | grep -E "${cidr_pattern}" | grep -F "unreachable" >/dev/null 2>&1; then
      :
    else
      log_fail "Rule prio 100: Missing unreachable rule for ${cidr} on ${ACTIVE_BRIDGE}."
      local_all_100_ok=false
    fi
  done
  if [ "${local_all_100_ok}" = "true" ]; then
    log_pass "Rule prio 100: All 12 private/special ranges marked unreachable for iif ${ACTIVE_BRIDGE}."
  fi

  # Check for legacy 'from <subnet>' rules
  if echo "${rules_dump}" | grep -E "[[:space:]]+from (${ACTIVE_SUBNET}|172\.16\.151\.0\/24)" >/dev/null 2>&1; then
    log_warn "Legacy 'from <subnet>' rule detected in ip rule (can cause VPN route leaks). Run ensure-network.sh to migrate."
  else
    log_pass "RPDB rules strictly bound to incoming interface 'iif ${ACTIVE_BRIDGE}' (VPN-safe)."
  fi
else
  log_warn "'ip' command not found."
fi
echo ""

# --------------------------------------------------------
# 4. Netfilter Firewall (DOCKER-USER & INPUT chains)
# --------------------------------------------------------
echo -e "${CLR_BOLD}[4/8] Netfilter Packet Filtering (iptables)${CLR_RESET}"
if command -v iptables >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    if ! sudo -n true 2>/dev/null; then
      echo -e "  ${CLR_YELLOW}==> Root privileges required to inspect Netfilter rules.${CLR_RESET}"
      sudo -v 2>/dev/null || true
    fi
  fi

  # 4a: DOCKER-USER forwarding jump
  if ${SUDO} iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    if ${SUDO} iptables -C DOCKER-USER -i "${ACTIVE_BRIDGE}" -j AGY-SANDBOX-FWD >/dev/null 2>&1; then
      log_pass "DOCKER-USER chain: Forwarding jump to AGY-SANDBOX-FWD active for ${ACTIVE_BRIDGE}."
    else
      log_fail "DOCKER-USER chain: Missing jump to AGY-SANDBOX-FWD for ${ACTIVE_BRIDGE}."
    fi
  else
    log_warn "DOCKER-USER chain not found in iptables filter table."
  fi

  # 4b: Dedicated AGY-SANDBOX-FWD chain
  if ${SUDO} iptables -L AGY-SANDBOX-FWD -n >/dev/null 2>&1; then
    if ${SUDO} iptables -C AGY-SANDBOX-FWD -d "${ACTIVE_SUBNET}" -j RETURN >/dev/null 2>&1; then
      log_pass "AGY-SANDBOX-FWD chain: Intra-subnet traffic RETURN rule verified (${ACTIVE_SUBNET})."
    else
      log_fail "AGY-SANDBOX-FWD chain: Missing intra-subnet RETURN rule for ${ACTIVE_SUBNET}."
    fi

    local_fwd_drop_ok=true
    for cidr in "${BLOCKED_RANGES[@]}"; do
      if ! ${SUDO} iptables -C AGY-SANDBOX-FWD -d "${cidr}" -j DROP >/dev/null 2>&1; then
        local_fwd_drop_ok=false
        log_fail "AGY-SANDBOX-FWD chain: Missing DROP rule for ${cidr}."
      fi
    done
    if [ "${local_fwd_drop_ok}" = "true" ]; then
      log_pass "AGY-SANDBOX-FWD chain: DROP rules active for all 12 private/special ranges."
    fi
  else
    log_fail "AGY-SANDBOX-FWD chain does not exist in iptables."
  fi

  # 4c: INPUT chain jump to AGY-SANDBOX-IN
  if ${SUDO} iptables -L INPUT -n >/dev/null 2>&1; then
    if ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -j AGY-SANDBOX-IN >/dev/null 2>&1; then
      log_pass "INPUT chain: Host boundary jump to AGY-SANDBOX-IN active for ${ACTIVE_BRIDGE}."
    else
      log_fail "INPUT chain: Missing jump to AGY-SANDBOX-IN for ${ACTIVE_BRIDGE} (HOST PORTS EXPOSED!)."
    fi
  else
    log_fail "INPUT chain inaccessible in iptables."
  fi

  # 4d: Dedicated AGY-SANDBOX-IN chain
  if ${SUDO} iptables -L AGY-SANDBOX-IN -n >/dev/null 2>&1; then
    if ${SUDO} iptables -C AGY-SANDBOX-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; then
      log_pass "AGY-SANDBOX-IN chain: ESTABLISHED/RELATED stateful flows accepted."
    else
      log_fail "AGY-SANDBOX-IN chain: Missing ESTABLISHED/RELATED stateful rule."
    fi

    if ${SUDO} iptables -C AGY-SANDBOX-IN -j DROP >/dev/null 2>&1; then
      log_pass "AGY-SANDBOX-IN chain: Host boundary DROP rule active (all host services protected from container)."
    else
      log_fail "AGY-SANDBOX-IN chain: Missing host boundary DROP rule."
    fi
  else
    log_fail "AGY-SANDBOX-IN chain does not exist in iptables."
  fi
else
  log_warn "'iptables' command not found."
fi
echo ""

# --------------------------------------------------------
# 5. IPv6 & Systemd Persistence Status
# --------------------------------------------------------
echo -e "${CLR_BOLD}[5/8] IPv6 Boundary & Systemd Persistence${CLR_RESET}"

# IPv6 Sysctl & Rules
if command -v sysctl >/dev/null 2>&1; then
  dis_v6=$(sysctl -n "net.ipv6.conf.${ACTIVE_BRIDGE}.disable_ipv6" 2>/dev/null || echo "")
  if [ "${dis_v6}" = "1" ]; then
    log_pass "IPv6 disabled on ${ACTIVE_BRIDGE} via sysctl (disable_ipv6=1)."
  else
    log_warn "IPv6 disable_ipv6 sysctl on ${ACTIVE_BRIDGE} is '${dis_v6}' (expected 1)."
  fi
fi

if command -v ip6tables >/dev/null 2>&1; then
  v6_ok=true
  if ! ${SUDO} ip6tables -C FORWARD -i "${ACTIVE_BRIDGE}" -j DROP >/dev/null 2>&1; then
    log_fail "ip6tables FORWARD: Missing DROP rule for ${ACTIVE_BRIDGE}."
    v6_ok=false
  fi
  if ! ${SUDO} ip6tables -C INPUT -i "${ACTIVE_BRIDGE}" -j DROP >/dev/null 2>&1; then
    log_fail "ip6tables INPUT: Missing DROP rule for ${ACTIVE_BRIDGE}."
    v6_ok=false
  fi
  if [ "${v6_ok}" = "true" ]; then
    log_pass "ip6tables: IPv6 traffic from ${ACTIVE_BRIDGE} dropped in FORWARD & INPUT."
  fi
else
  log_info "ip6tables not available on this host."
fi

# Systemd unit inspection
UNIT_FILE="/etc/systemd/system/agy-sandbox-network.service"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  if [ -f "${UNIT_FILE}" ]; then
    log_pass "Systemd unit file exists at ${UNIT_FILE}."

    # Verify LPE Protection: ExecStart must not point to home/root
    exec_start=$(grep -E "^ExecStart=" "${UNIT_FILE}" | head -n1 | cut -d= -f2- | tr -d ' ' || echo "")
    if [[ "${exec_start}" =~ ^/usr/local/lib/agy-sandbox/ ]]; then
      log_pass "Systemd ExecStart points to secure system path: ${exec_start}"
    else
      log_fail "Systemd ExecStart points to insecure path: '${exec_start}' (LPE risk!). Expected /usr/local/lib/agy-sandbox/..."
    fi

    if [[ "${exec_start}" =~ ^/home/ || "${exec_start}" =~ ^/root/ ]]; then
      log_fail "CRITICAL SECURITY RISK: ExecStart runs script from user directory (${exec_start})!"
    fi

    # Check ownership of installed binary
    if [ -f "/usr/local/lib/agy-sandbox/ensure-network.sh" ]; then
      owner=$(stat -c "%U:%G" "/usr/local/lib/agy-sandbox/ensure-network.sh" 2>/dev/null || echo "unknown")
      if [ "${owner}" = "root:root" ]; then
        log_pass "/usr/local/lib/agy-sandbox/ensure-network.sh is owned by root:root."
      else
        log_fail "/usr/local/lib/agy-sandbox/ensure-network.sh owned by '${owner}' (must be root:root)."
      fi
    fi

    # Check hardening directives
    for directive in "ProtectHome=yes" "ProtectSystem=full" "PrivateTmp=yes" "RuntimeDirectory=agy-sandbox"; do
      if grep -q -F "${directive}" "${UNIT_FILE}"; then
        :
      else
        log_warn "Systemd unit missing hardening directive: ${directive}"
      fi
    done

    if systemctl is-enabled agy-sandbox-network.service >/dev/null 2>&1; then
      log_pass "Service 'agy-sandbox-network.service' is enabled (persists on reboot)."
    else
      log_warn "Service 'agy-sandbox-network.service' is disabled. Run: systemctl enable agy-sandbox-network.service"
    fi

    if systemctl is-active agy-sandbox-network.service >/dev/null 2>&1; then
      log_pass "Service 'agy-sandbox-network.service' is currently active."
    else
      log_warn "Service 'agy-sandbox-network.service' is currently inactive."
    fi
  else
    log_warn "Systemd unit file not installed. Rules will not persist across reboot."
  fi
else
  log_info "Host does not run systemd as init (or inside container). Persistence via systemd not applicable."
fi
echo ""

# --------------------------------------------------------
# 6. Supply Chain Pinning & Image Integrity (SEC-03, CNT-03)
# --------------------------------------------------------
echo -e "${CLR_BOLD}[6/8] Supply Chain Pinning & Image Integrity (SEC-03, CNT-03)${CLR_RESET}"

ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Check base/Dockerfile
if [ -f "${ROOT_DIR}/base/Dockerfile" ]; then
  # 1. uv pinning by digest
  if grep -E "^COPY --from=ghcr\.io/astral-sh/uv:.*@sha256:[a-f0-9]{64}" "${ROOT_DIR}/base/Dockerfile" >/dev/null 2>&1; then
    uv_pin=$(grep -E "^COPY --from=ghcr\.io/astral-sh/uv:" "${ROOT_DIR}/base/Dockerfile" | head -n1 | awk '{print $2}' | cut -d= -f2 || echo "")
    log_pass "base/Dockerfile: uv package manager pinned by immutable SHA256 digest (${uv_pin})."
  elif grep -E "^COPY --from=ghcr\.io/astral-sh/uv:latest" "${ROOT_DIR}/base/Dockerfile" >/dev/null 2>&1; then
    log_fail "base/Dockerfile: uv uses unpinned floating ':latest' tag (supply chain risk!)."
  else
    log_warn "base/Dockerfile: uv copy instruction not recognized or missing SHA256 digest."
  fi

  # 2. Patcher commit pinning
  if grep -E 'ARG PATCHER_COMMIT="[a-f0-9]{40}"' "${ROOT_DIR}/base/Dockerfile" >/dev/null 2>&1 || grep -E 'PATCHER_COMMIT="[a-f0-9]{40}"' "${ROOT_DIR}/base/Dockerfile" >/dev/null 2>&1; then
    patch_commit=$(grep -E 'PATCHER_COMMIT=' "${ROOT_DIR}/base/Dockerfile" | head -n1 | cut -d= -f2- | tr -d '"' || echo "")
    log_pass "base/Dockerfile: Antigravity CLI patcher commit pinned with immutable SHA (${patch_commit:0:12})."
  else
    log_fail "base/Dockerfile: Antigravity CLI patcher commit is not pinned to a 40-character SHA."
  fi

  # 3. Pre-creation of /home/vscode/.gemini
  if grep -q "/home/vscode/\.gemini" "${ROOT_DIR}/base/Dockerfile" && grep -q "chown -R vscode:vscode /home/vscode/\.gemini" "${ROOT_DIR}/base/Dockerfile"; then
    log_pass "base/Dockerfile: /home/vscode/.gemini pre-created with unprivileged ownership (vscode:vscode, 0700)."
  else
    log_warn "base/Dockerfile: /home/vscode/.gemini pre-creation with unprivileged ownership not detected."
  fi

  # 4. setup.sh copied to /usr/local/share/agy-sandbox/setup.sh
  if grep -q "setup\.sh /usr/local/share/agy-sandbox/setup\.sh" "${ROOT_DIR}/base/Dockerfile"; then
    log_pass "base/Dockerfile: setup.sh copied to protected system directory (/usr/local/share/agy-sandbox/setup.sh)."
  else
    log_fail "base/Dockerfile: setup.sh not copied to /usr/local/share/agy-sandbox/setup.sh."
  fi

  # 5. Patcher pre-cloned in system directory
  if grep -q "/usr/local/share/agy-sandbox/patcher" "${ROOT_DIR}/base/Dockerfile"; then
    log_pass "base/Dockerfile: Patcher pre-cloned into system directory (/usr/local/share/agy-sandbox/patcher)."
  else
    log_fail "base/Dockerfile: Patcher not pre-cloned at image build time."
  fi
else
  log_info "base/Dockerfile not found at ${ROOT_DIR}/base/Dockerfile. Skipping Dockerfile audit."
fi

# Check base/install-agy.sh
if [ -f "${ROOT_DIR}/base/install-agy.sh" ]; then
  if grep -E 'PATCHER_COMMIT=.*[a-f0-9]{40}' "${ROOT_DIR}/base/install-agy.sh" >/dev/null 2>&1; then
    log_pass "base/install-agy.sh: Patcher commit pinned with immutable SHA."
  else
    log_warn "base/install-agy.sh: Patcher commit SHA pinning not found."
  fi
fi

# Check base/setup.sh
if [ -f "${ROOT_DIR}/base/setup.sh" ]; then
  # 1. No runtime git clone
  if grep -q "git clone" "${ROOT_DIR}/base/setup.sh"; then
    log_fail "base/setup.sh: Found runtime 'git clone' (must use pre-baked patcher in /usr/local/share/agy-sandbox/patcher)."
  else
    log_pass "base/setup.sh: No runtime 'git clone' detected (offline safe)."
  fi

  # 2. No wildcard safe.directory "*"
  if grep -q 'safe\.directory "\*"' "${ROOT_DIR}/base/setup.sh"; then
    log_fail "base/setup.sh: Insecure wildcard 'safe.directory \"*\"' detected."
  else
    log_pass "base/setup.sh: Insecure wildcard 'safe.directory \"*\"' not present."
  fi

  # 3. Clean forwarded sockets
  if grep -q "rm -f /tmp/vscode-git-\*\.sock /tmp/vscode-ssh-auth-\*\.sock" "${ROOT_DIR}/base/setup.sh"; then
    log_pass "base/setup.sh: Forwarded host authentication socket cleanup routine present."
  else
    log_warn "base/setup.sh: Forwarded socket cleanup routine missing."
  fi

  # 4. Safe git directory support for worktrees (FEAT-01)
  if grep -q "gitdir" "${ROOT_DIR}/base/setup.sh"; then
    log_pass "base/setup.sh: Git worktree safe.directory registration logic present (FEAT-01)."
  else
    log_fail "base/setup.sh: Missing worktree gitdir resolution in safe.directory setup."
  fi
fi
echo ""

# --------------------------------------------------------
# 7. Dev Container Specification & Runtime Hardening (F1, F2, F8, F14, F15, F17)
# --------------------------------------------------------
echo -e "${CLR_BOLD}[7/8] Dev Container Specification & Runtime Hardening (F1, F2, F8, F14, F15, F17)${CLR_RESET}"

DEV_JSON="${ROOT_DIR}/base/devcontainer.json"
if [ -f "${DEV_JSON}" ] && command -v jq >/dev/null 2>&1; then
  # 1. Credential & secret leak prevention (F1)
  if jq -e '.customizations.vscode.settings["dev.containers.copyGitConfig"] == false and
            .customizations.vscode.settings["dev.containers.dockerCredentialHelper"] == false and
            .customizations.vscode.settings["git.terminalAuthentication"] == false and
            .customizations.vscode.settings["github.gitAuthentication"] == false' "${DEV_JSON}" >/dev/null 2>&1; then
    log_pass "base/devcontainer.json: All 4 credential leak prevention flags active in vscode settings (F1)."
  else
    log_fail "base/devcontainer.json: Missing one or more credential blocking flags in customizations.vscode.settings."
  fi

  # 2. remoteEnv channel neutralization (F1)
  if jq -e '.remoteEnv.SSH_AUTH_SOCK == "" and
            .remoteEnv.VSCODE_GIT_IPC_HANDLE == "" and
            .remoteEnv.VSCODE_GIT_ASKPASS_NODE == "" and
            .remoteEnv.VSCODE_GIT_ASKPASS_MAIN == "" and
            .remoteEnv.GIT_ASKPASS == "/bin/false" and
            .remoteEnv.SSH_ASKPASS == "/bin/false"' "${DEV_JSON}" >/dev/null 2>&1; then
    log_pass "base/devcontainer.json: Host IPC and Askpass channels neutralized in remoteEnv (F1)."
  else
    log_fail "base/devcontainer.json: remoteEnv missing IPC/Askpass neutralization variables (F1 risk!)."
  fi

  # 3. Fail-Closed initializeCommand (F2)
  init_cmd=$(jq -r '.initializeCommand // empty' "${DEV_JSON}")
  if [[ "${init_cmd}" =~ /run/agy-sandbox/network.ready ]] && [[ "${init_cmd}" =~ ip[[:space:]]+rule ]]; then
    log_pass "base/devcontainer.json: Fail-Closed initializeCommand validates readiness marker and RPDB rules (F2)."
  else
    log_fail "base/devcontainer.json: Missing or incomplete Fail-Closed initializeCommand (F2 risk!)."
  fi

  # 4. runArgs security flags & limits (CNT-01, NET-05, F8, F15)
  run_args=$(jq -r '.runArgs[]?' "${DEV_JSON}")
  args_ok=true
  for req in "--security-opt=no-new-privileges:true" \
             "--cap-drop=NET_RAW" \
             "--pids-limit=${PIDS_LIMIT}" \
             "--memory=${MEMORY_LIMIT}" \
             "--cpus=${CPUS_LIMIT}" \
             "--tmpfs=/tmp:rw,nosuid,nodev,size=${TMPFS_SIZE},mode=1777" \
             "--dns=${DNS_PRIMARY}" \
             "--dns=${DNS_SECONDARY}"; do
    if ! echo "${run_args}" | grep -F -- "${req}" >/dev/null 2>&1; then
      log_fail "base/devcontainer.json: runArgs missing required security argument: ${req}"
      args_ok=false
    fi
  done
  if [ "${args_ok}" = "true" ]; then
    log_pass "base/devcontainer.json: All runArgs security constraints present (no-new-privileges, cap-drop, limits from sandbox.conf, dual DNS, tmpfs)."
  fi

  # 5. mounts project isolation & readonly .devcontainer (CNT-02, F14, F17)
  mounts_str=$(jq -r '.mounts[]?' "${DEV_JSON}")
  if echo "${mounts_str}" | grep -E "source=agy-gemini-data-\\\$\{localWorkspaceFolderBasename\}" >/dev/null 2>&1; then
    log_pass "base/devcontainer.json: Project-isolated state volume configured (agy-gemini-data-\${localWorkspaceFolderBasename}, F14)."
  else
    log_fail "base/devcontainer.json: Missing project-scoped state volume in mounts (F14)."
  fi

  if echo "${mounts_str}" | grep -E "\.devcontainer.*readonly" >/dev/null 2>&1; then
    log_pass "base/devcontainer.json: .devcontainer mounted as Read-Only to prevent in-container host breakout (F17)."
  else
    log_fail "base/devcontainer.json: Missing readonly bind mount for .devcontainer (F17 risk!)."
  fi

  # 6. postStartCommand socket and credentials cleanup
  if jq -e '.postStartCommand | (contains("vscode-git-*.sock") and contains("vscode-ssh-auth-*.sock") and contains(".gitconfig"))' "${DEV_JSON}" >/dev/null 2>&1; then
    log_pass "base/devcontainer.json: postStartCommand cleans forwarded sockets and copied git credentials on startup."
  else
    log_warn "base/devcontainer.json: postStartCommand socket/credential cleanup routine missing or incomplete."
  fi

  # 7. init-sandbox.sh worktree and mount flags support (FEAT-01, FEAT-02)
  if [ -f "${ROOT_DIR}/scripts/init-sandbox.sh" ]; then
    if grep -q -- "--worktree" "${ROOT_DIR}/scripts/init-sandbox.sh" && grep -q -- "--mount" "${ROOT_DIR}/scripts/init-sandbox.sh"; then
      log_pass "scripts/init-sandbox.sh: CLI supports isolated Git worktree (--worktree) and custom bind mounts (--mount)."
    else
      log_fail "scripts/init-sandbox.sh: Missing --worktree or --mount flag support."
    fi
  fi
else
  log_info "base/devcontainer.json not found or jq unavailable. Skipping static devcontainer audit."
fi
echo ""

# --------------------------------------------------------
# 8. Container Boundary Verification
# --------------------------------------------------------
echo -e "${CLR_BOLD}[8/8] Container Egress Boundary Tests (TCP/HTTP Probes)${CLR_RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  active_cid=$(docker ps --filter "network=${NETWORK_NAME}" --format '{{.ID}}' 2>/dev/null | head -n1 || echo "")
  if [ -n "${active_cid}" ]; then
    c_name=$(docker ps --filter "id=${active_cid}" --format '{{.Names}}' 2>/dev/null || echo "${active_cid:0:12}")
    log_info "Active container detected on '${NETWORK_NAME}': ${c_name} (${active_cid:0:12})"

    # Verify protected system paths inside live container
    if docker exec "${active_cid}" test -f /usr/local/share/agy-sandbox/setup.sh 2>/dev/null; then
      s_owner=$(docker exec "${active_cid}" stat -c "%U:%G" /usr/local/share/agy-sandbox/setup.sh 2>/dev/null || echo "unknown")
      if [ "${s_owner}" = "root:root" ]; then
        log_pass "Container: /usr/local/share/agy-sandbox/setup.sh is owned by root:root."
      else
        log_fail "Container: /usr/local/share/agy-sandbox/setup.sh owned by '${s_owner}' (expected root:root)."
      fi
    fi

    if docker exec "${active_cid}" test -d /usr/local/share/agy-sandbox/patcher 2>/dev/null; then
      p_owner=$(docker exec "${active_cid}" stat -c "%U:%G" /usr/local/share/agy-sandbox/patcher 2>/dev/null || echo "unknown")
      if [ "${p_owner}" = "root:root" ]; then
        log_pass "Container: /usr/local/share/agy-sandbox/patcher is owned by root:root."
      else
        log_fail "Container: /usr/local/share/agy-sandbox/patcher owned by '${p_owner}' (expected root:root)."
      fi
    fi

    # Stage 3 Live container inspection (docker inspect)
    c_inspect=$(docker inspect "${active_cid}" 2>/dev/null || echo "[]")
    if [ "${c_inspect}" != "[]" ]; then
      if echo "${c_inspect}" | jq -e '.[0].HostConfig.SecurityOpt | index("no-new-privileges:true")' >/dev/null 2>&1; then
        log_pass "Container: HostConfig.SecurityOpt contains 'no-new-privileges:true'."
      else
        log_warn "Container: HostConfig.SecurityOpt missing 'no-new-privileges:true'."
      fi

      if echo "${c_inspect}" | jq -e '.[0].HostConfig.CapDrop | index("NET_RAW")' >/dev/null 2>&1; then
        log_pass "Container: HostConfig.CapDrop drops NET_RAW."
      else
        log_warn "Container: HostConfig.CapDrop does not contain NET_RAW."
      fi

      pids_lim=$(echo "${c_inspect}" | jq -r '.[0].HostConfig.PidsLimit // 0' 2>/dev/null || echo "0")
      if [ "${pids_lim}" -gt 0 ]; then
        log_pass "Container: HostConfig.PidsLimit enforced (${pids_lim})."
      else
        log_warn "Container: HostConfig.PidsLimit not enforced (${pids_lim})."
      fi

      devcont_ro=$(echo "${c_inspect}" | jq -r '.[0].Mounts[]? | select(.Destination | endswith("/.devcontainer")) | .RW' 2>/dev/null || echo "")
      if [ "${devcont_ro}" = "false" ]; then
        log_pass "Container: .devcontainer mount is strictly Read-Only (RW: false)."
      elif [ "${devcont_ro}" = "true" ]; then
        log_fail "Container: .devcontainer mount is writable (RW: true, F17 risk!)."
      else
        log_info "Container: .devcontainer dedicated mount not detected in container Mounts."
      fi

      # Stage 4 Git Worktree mounts protection (FEAT-01)
      has_git_mount=$(echo "${c_inspect}" | jq -r '.[0].Mounts[]? | select(.Destination | test("/\\.git(/.*)?$")) | .Destination' 2>/dev/null | head -n1 || echo "")
      if [ -n "${has_git_mount}" ]; then
        log_info "Container: Git worktree bind mounts detected. Auditing Git metadata protections..."
        for sub in "hooks" "config" "info"; do
          sub_rw=$(echo "${c_inspect}" | jq -r --arg s "/.git/${sub}" '.[0].Mounts[]? | select(.Destination | endswith($s)) | .RW' 2>/dev/null || echo "")
          if [ "${sub_rw}" = "false" ]; then
            log_pass "Container: .git/${sub} mount is strictly Read-Only (RW: false, FEAT-01)."
          elif [ "${sub_rw}" = "true" ]; then
            log_fail "Container: .git/${sub} mount is WRITABLE (RW: true, host RCE risk!)."
          else
            log_warn "Container: .git/${sub} dedicated Read-Only mount not detected in container Mounts."
          fi
        done
      fi
    fi

    gw_ip=$(echo "${ACTIVE_SUBNET}" | sed -E 's/\.[0-9]+\/[0-9]+$/\.1/')
    audit_egress_isolation "docker exec ${active_cid}" "${gw_ip}"
  else
    log_info "No active containers running on '${NETWORK_NAME}'. Skipping live container egress probe."
  fi
elif [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
  log_info "Running in container environment. Performing egress boundary probe..."
  gw_ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' || echo "")
  if [ -z "${gw_ip}" ]; then
    gw_ip=$(echo "${ACTIVE_SUBNET}" | sed -E 's/\.[0-9]+\/[0-9]+$/\.1/')
  fi
  audit_egress_isolation "" "${gw_ip}"
else
  log_info "Docker daemon and container environment not detected. Skipping container egress probe."
fi
echo ""

# --------------------------------------------------------
# Audit Summary
# --------------------------------------------------------
echo -e "${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo -e "Audit Results:  ${CLR_GREEN}${pass_count} Passed${CLR_RESET}  |  ${CLR_YELLOW}${warn_count} Warnings${CLR_RESET}  |  ${CLR_RED}${fail_count} Failed${CLR_RESET}"

if [ "${fail_count}" -eq 0 ]; then
  echo -e "${CLR_GREEN}${CLR_BOLD}🛡️  VERDICT: ALL SECURITY GUARDRAILS OPERATIONAL${CLR_RESET}"
  echo -e "   Container is strictly isolated from LAN and Host boundary."
  exit 0
else
  echo -e "${CLR_RED}${CLR_BOLD}⚠️  VERDICT: SECURITY GUARDRAILS INCOMPLETE (${fail_count} failures)${CLR_RESET}"
  echo -e "   Run 'ensure-network.sh' to re-apply isolated network boundaries."
  exit 1
fi
