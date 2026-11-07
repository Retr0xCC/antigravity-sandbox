#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Network Provisioner
# Ensures isolated bridge network exists with kernel routing
# and Netfilter (DOCKER-USER & INPUT) boundary isolation
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

ensure_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "==> [antigravity-sandbox] Error: 'sudo' command not found. Please run as root." >&2
    exit 1
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "==> [antigravity-sandbox] Root privileges required for kernel network isolation and Netfilter rules."
    if ! sudo -v; then
      echo "==> [antigravity-sandbox] Sudo authentication failed. Aborting." >&2
      exit 1
    fi
  fi
}
ensure_sudo

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

echo "==> [antigravity-sandbox] Checking Docker network: '${NETWORK_NAME}'..."

if ! command -v docker >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Error: docker CLI is not installed or not in PATH." >&2
  exit 1
fi

# Wait for Docker daemon to become responsive if starting early on boot
docker_retries=15
while ! docker info >/dev/null 2>&1; do
  if [ "${docker_retries}" -le 0 ]; then
    echo "==> [antigravity-sandbox] Error: Docker daemon is not responding." >&2
    exit 1
  fi
  sleep 1
  docker_retries=$((docker_retries - 1))
done

ACTIVE_BRIDGE="${BRIDGE_NAME}"
ACTIVE_SUBNET=""

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  existing_icc=$(docker network inspect "${NETWORK_NAME}" --format '{{index .Options "com.docker.network.bridge.enable_icc"}}' 2>/dev/null || echo "")
  containers_count=$(docker network inspect "${NETWORK_NAME}" --format '{{len .Containers}}' 2>/dev/null || echo "0")
  if [ "${existing_icc}" != "false" ]; then
    if [ "${containers_count}" = "0" ] || [ -z "${containers_count}" ]; then
      echo "==> [antigravity-sandbox] Notice: Existing network '${NETWORK_NAME}' has enable_icc != false and no active containers."
      echo "    Recreating '${NETWORK_NAME}' with com.docker.network.bridge.enable_icc=false for inter-container isolation..."
      docker network rm "${NETWORK_NAME}" 2>/dev/null || true
    else
      echo "==> [antigravity-sandbox] Warning: Existing network '${NETWORK_NAME}' has enable_icc != false, but ${containers_count} container(s) are connected."
      echo "    Cannot recreate in-use network automatically. Stop running sandboxes and rerun ensure-network.sh to enforce enable_icc=false."
    fi
  fi
fi

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Network '${NETWORK_NAME}' already exists."
  ACTIVE_SUBNET=$(docker network inspect "${NETWORK_NAME}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")
  bridge_opt=$(docker network inspect "${NETWORK_NAME}" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
  if [ -n "${bridge_opt}" ] && [ "${bridge_opt}" != "<no value>" ]; then
    ACTIVE_BRIDGE="${bridge_opt}"
  else
    net_id=$(docker network inspect "${NETWORK_NAME}" --format '{{.Id}}' 2>/dev/null || echo "")
    if [ -n "${net_id}" ]; then
      ACTIVE_BRIDGE="br-${net_id:0:12}"
    else
      ACTIVE_BRIDGE="${BRIDGE_NAME}"
    fi
  fi
else
  # Network creation via native Docker IPAM (or explicit SUBNET if specified)
  if [ -n "${SUBNET}" ]; then
    echo "==> [antigravity-sandbox] Creating isolated bridge network '${NETWORK_NAME}' (${SUBNET}) with bridge '${BRIDGE_NAME}'..."
    docker network create \
      --driver bridge \
      --subnet "${SUBNET}" \
      --opt "com.docker.network.bridge.enable_icc=false" \
      --opt "com.docker.network.bridge.name=${BRIDGE_NAME}" \
      "${NETWORK_NAME}"
  else
    echo "==> [antigravity-sandbox] Creating isolated bridge network '${NETWORK_NAME}' (native Docker IPAM) with bridge '${BRIDGE_NAME}'..."
    docker network create \
      --driver bridge \
      --opt "com.docker.network.bridge.enable_icc=false" \
      --opt "com.docker.network.bridge.name=${BRIDGE_NAME}" \
      "${NETWORK_NAME}"
  fi
  ACTIVE_BRIDGE="${BRIDGE_NAME}"
  ACTIVE_SUBNET=$(docker network inspect "${NETWORK_NAME}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")
fi

if ! ip link show "${ACTIVE_BRIDGE}" >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Warning: Bridge interface '${ACTIVE_BRIDGE}' is not active in kernel yet."
  echo "    Docker will instantiate it when a container starts. Boundary rules will still apply."
fi

BLOCKED_RANGES=(
  "0.0.0.0/8"
  "10.0.0.0/8"
  "100.64.0.0/10"
  "127.0.0.0/8"
  "169.254.0.0/16"
  "172.16.0.0/12"
  "192.0.0.0/24"
  "192.0.2.0/24"
  "192.168.0.0/16"
  "198.18.0.0/15"
  "198.51.100.0/24"
  "203.0.113.0/24"
  "224.0.0.0/4"
  "240.0.0.0/4"
  "255.255.255.255/32"
)

# --------------------------------------------------------
# 1. Linux Kernel Policy Routing (ip rule)
# --------------------------------------------------------
if ! command -v ip >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Fatal Error: 'ip' command not found. Fail-closed." >&2
  exit 1
fi

echo "==> [antigravity-sandbox] Configuring Linux Policy Routing (ip rule)..."

  # Clean old rules for interface
  for dev in "${ACTIVE_BRIDGE}" "${BRIDGE_NAME}"; do
    while ip rule show 2>/dev/null | grep -E "^95:[[:space:]]+" | grep -F "iif ${dev}" >/dev/null 2>&1; do
      ${SUDO} ip rule del pref 95 iif "${dev}" to "${ACTIVE_SUBNET}" lookup main 2>/dev/null || \
      ${SUDO} ip rule del pref 95 iif "${dev}" 2>/dev/null || break
    done

    for cidr in "${BLOCKED_RANGES[@]}"; do
      cidr_pattern="(to ${cidr}|to ${cidr%/32})([[:space:]]|$)"
      while ip rule show 2>/dev/null | grep -E "^100:[[:space:]]+" | grep -F "iif ${dev}" | grep -E "${cidr_pattern}" >/dev/null 2>&1; do
        ${SUDO} ip rule del pref 100 iif "${dev}" to "${cidr}" unreachable 2>/dev/null || \
        ${SUDO} ip rule del pref 100 iif "${dev}" to "${cidr%/32}" unreachable 2>/dev/null || \
        ${SUDO} ip rule del pref 100 iif "${dev}" to "${cidr}" 2>/dev/null || \
        ${SUDO} ip rule del pref 100 iif "${dev}" to "${cidr%/32}" 2>/dev/null || break
      done
    done

    while ip rule show 2>/dev/null | grep -E "^100:[[:space:]]+" | grep -F "iif ${dev}" >/dev/null 2>&1; do
      ${SUDO} ip rule del pref 100 iif "${dev}" 2>/dev/null || break
    done

    for old_prio in 70 80; do
      while ip rule show 2>/dev/null | grep -E "^${old_prio}:[[:space:]]+" | grep -F "iif ${dev}" >/dev/null 2>&1; do
        ${SUDO} ip rule del pref "${old_prio}" iif "${dev}" 2>/dev/null || break
      done
    done
  done

  # Clean legacy rules matching 'from <subnet>'
  for old_s in "${ACTIVE_SUBNET}" "${SUBNET}" "172.16.151.0/24"; do
    [ -z "${old_s}" ] && continue
    while ip rule show 2>/dev/null | grep -E "[[:space:]]+from ${old_s}[[:space:]]+" >/dev/null 2>&1; do
      ${SUDO} ip rule del from "${old_s}" 2>/dev/null || break
    done
  done

  # Add rules pref 100: unreachable for private/special ranges
  for cidr in "${BLOCKED_RANGES[@]}"; do
    cidr_pattern="(to ${cidr}|to ${cidr%/32})([[:space:]]|$)"
    if ! ip rule show 2>/dev/null | grep -E "^100:[[:space:]]+" | grep -F "iif ${ACTIVE_BRIDGE}" | grep -E "${cidr_pattern}" | grep -F "unreachable" >/dev/null 2>&1; then
      ${SUDO} ip rule add pref 100 iif "${ACTIVE_BRIDGE}" to "${cidr}" unreachable
    fi
  done

# --------------------------------------------------------
# 2. Netfilter Isolation (DOCKER-USER & INPUT chains)
# --------------------------------------------------------
if ! command -v iptables >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Fatal Error: 'iptables' command not found. Fail-closed." >&2
  exit 1
fi

echo "==> [antigravity-sandbox] Configuring Netfilter isolation chains..."

# Verify DOCKER-USER chain exists before proceeding (Fail-Closed)
if ! ${SUDO} iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Fatal Error: 'DOCKER-USER' chain not found in iptables filter table. Is Docker daemon running with iptables enabled? Fail-closed." >&2
  exit 1
fi

# Create and flush dedicated chains
${SUDO} iptables -N AGY-SANDBOX-FWD >/dev/null 2>&1 || ${SUDO} iptables -F AGY-SANDBOX-FWD
${SUDO} iptables -N AGY-SANDBOX-IN >/dev/null 2>&1 || ${SUDO} iptables -F AGY-SANDBOX-IN

# Populate AGY-SANDBOX-FWD (no intra-subnet bypasses allowed)
# Blocked ranges dropped
for cidr in "${BLOCKED_RANGES[@]}"; do
  ${SUDO} iptables -A AGY-SANDBOX-FWD -d "${cidr}" -j DROP
done
# Terminate with RETURN
${SUDO} iptables -A AGY-SANDBOX-FWD -j RETURN

# Hook into DOCKER-USER
# Clean legacy direct rules from DOCKER-USER
for old_s in "${ACTIVE_SUBNET}" "${SUBNET}" "172.16.151.0/24"; do
  [ -z "${old_s}" ] && continue
  for dest in "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12"; do
    while ${SUDO} iptables -C DOCKER-USER -s "${old_s}" -d "${dest}" -j DROP >/dev/null 2>&1; do
      ${SUDO} iptables -D DOCKER-USER -s "${old_s}" -d "${dest}" -j DROP 2>/dev/null || break
    done
  done
done

# Remove stale jump if bridge changed
if [ "${ACTIVE_BRIDGE}" != "${BRIDGE_NAME}" ]; then
  while ${SUDO} iptables -C DOCKER-USER -i "${BRIDGE_NAME}" -j AGY-SANDBOX-FWD >/dev/null 2>&1; do
    ${SUDO} iptables -D DOCKER-USER -i "${BRIDGE_NAME}" -j AGY-SANDBOX-FWD 2>/dev/null || break
  done
fi

if ! ${SUDO} iptables -C DOCKER-USER -i "${ACTIVE_BRIDGE}" -j AGY-SANDBOX-FWD >/dev/null 2>&1; then
  ${SUDO} iptables -I DOCKER-USER 1 -i "${ACTIVE_BRIDGE}" -j AGY-SANDBOX-FWD
fi

# Populate AGY-SANDBOX-IN
${SUDO} iptables -A AGY-SANDBOX-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
${SUDO} iptables -A AGY-SANDBOX-IN -j DROP

# Clean legacy direct INPUT rules
for dev in "${ACTIVE_BRIDGE}" "${BRIDGE_NAME}"; do
  while ${SUDO} iptables -C INPUT -i "${dev}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; do
    ${SUDO} iptables -D INPUT -i "${dev}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || break
  done
  while ${SUDO} iptables -C INPUT -i "${dev}" -m state --state ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; do
    ${SUDO} iptables -D INPUT -i "${dev}" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || break
  done
  while ${SUDO} iptables -C INPUT -i "${dev}" -p udp --dport 53 -j ACCEPT >/dev/null 2>&1; do
    ${SUDO} iptables -D INPUT -i "${dev}" -p udp --dport 53 -j ACCEPT 2>/dev/null || break
  done
  while ${SUDO} iptables -C INPUT -i "${dev}" -p tcp --dport 53 -j ACCEPT >/dev/null 2>&1; do
    ${SUDO} iptables -D INPUT -i "${dev}" -p tcp --dport 53 -j ACCEPT 2>/dev/null || break
  done
  while ${SUDO} iptables -C INPUT -i "${dev}" -j DROP >/dev/null 2>&1; do
    ${SUDO} iptables -D INPUT -i "${dev}" -j DROP 2>/dev/null || break
  done
done

# Remove stale jump if bridge changed
if [ "${ACTIVE_BRIDGE}" != "${BRIDGE_NAME}" ]; then
  while ${SUDO} iptables -C INPUT -i "${BRIDGE_NAME}" -j AGY-SANDBOX-IN >/dev/null 2>&1; do
    ${SUDO} iptables -D INPUT -i "${BRIDGE_NAME}" -j AGY-SANDBOX-IN 2>/dev/null || break
  done
fi

# Hook AGY-SANDBOX-IN into INPUT
if ! ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -j AGY-SANDBOX-IN >/dev/null 2>&1; then
  ${SUDO} iptables -I INPUT 1 -i "${ACTIVE_BRIDGE}" -j AGY-SANDBOX-IN
fi

# --------------------------------------------------------
# 3. IPv6 Boundary Isolation
# --------------------------------------------------------
echo "==> [antigravity-sandbox] Configuring IPv6 boundary isolation..."
if command -v sysctl >/dev/null 2>&1; then
  ${SUDO} sysctl -w "net.ipv6.conf.${ACTIVE_BRIDGE}.disable_ipv6=1" >/dev/null 2>&1 || true
fi

if command -v ip6tables >/dev/null 2>&1; then
  if ! ${SUDO} ip6tables -C FORWARD -i "${ACTIVE_BRIDGE}" -j DROP >/dev/null 2>&1; then
    ${SUDO} ip6tables -I FORWARD 1 -i "${ACTIVE_BRIDGE}" -j DROP 2>/dev/null || true
  fi
  if ! ${SUDO} ip6tables -C INPUT -i "${ACTIVE_BRIDGE}" -j DROP >/dev/null 2>&1; then
    ${SUDO} ip6tables -I INPUT 1 -i "${ACTIVE_BRIDGE}" -j DROP 2>/dev/null || true
  fi
  if ${SUDO} ip6tables -L DOCKER-USER -n >/dev/null 2>&1; then
    if ! ${SUDO} ip6tables -C DOCKER-USER -i "${ACTIVE_BRIDGE}" -j DROP >/dev/null 2>&1; then
      ${SUDO} ip6tables -I DOCKER-USER 1 -i "${ACTIVE_BRIDGE}" -j DROP 2>/dev/null || true
    fi
  fi
fi

# --------------------------------------------------------
# 4. Fail-Closed Readiness Marker
# --------------------------------------------------------
RUN_DIR="$(dirname "${READY_FILE}")"
TMP_READY_FILE="${READY_FILE}.tmp.$$"

${SUDO} mkdir -p "${RUN_DIR}"
${SUDO} chmod 0755 "${RUN_DIR}"

cat <<EOF | ${SUDO} tee "${TMP_READY_FILE}" >/dev/null
NETWORK_NAME=${NETWORK_NAME}
ACTIVE_BRIDGE=${ACTIVE_BRIDGE}
ACTIVE_SUBNET=${ACTIVE_SUBNET}
TIMESTAMP=$(date +%s)
EOF

${SUDO} chmod 0644 "${TMP_READY_FILE}"
${SUDO} mv -f "${TMP_READY_FILE}" "${READY_FILE}"

echo "==> [antigravity-sandbox] Network '${NETWORK_NAME}' (${ACTIVE_SUBNET} on ${ACTIVE_BRIDGE}) and boundary isolation verified."
