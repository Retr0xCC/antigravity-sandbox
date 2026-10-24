#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Network Teardown
# Cleans up dynamic Netfilter rules, policy routing, and
# removes isolated bridge network
# ========================================================

# Resolve symlinks to find real script location
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

if [ -f "${SCRIPT_DIR}/sandbox.conf" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/sandbox.conf"
fi

NETWORK_NAME="${NETWORK_NAME:-agy_net}"
DEFAULT_SUBNET="172.16.151.0/24"
BRIDGE_NAME="${BRIDGE_NAME:-agy0}"
READY_FILE="${READY_FILE:-/run/agy-sandbox/network.ready}"

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

ensure_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "==> [antigravity-sandbox] Error: 'sudo' command not found. Please run as root." >&2
    exit 1
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "==> [antigravity-sandbox] Root privileges required to teardown kernel network isolation and Netfilter rules."
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

echo "==> [antigravity-sandbox] Tearing down sandbox network isolation..."

ACTIVE_BRIDGE="${BRIDGE_NAME:-br-agy}"
ACTIVE_SUBNET="${DEFAULT_SUBNET:-172.16.151.0/24}"

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

# 1. Immediately remove readiness marker to enter Fail-Closed state
if [ -f "${READY_FILE}" ]; then
  echo "==> Removing readiness marker ${READY_FILE}..."
  ${SUDO} rm -f "${READY_FILE}"
fi

# --------------------------------------------------------
# 2. Clean Netfilter iptables (DOCKER-USER & INPUT chains)
# --------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
  echo "==> Cleaning Netfilter iptables chains..."

  # Detach AGY-SANDBOX-FWD from DOCKER-USER
  if ${SUDO} iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    for dev in "${ACTIVE_BRIDGE}" "${BRIDGE_NAME}"; do
      while ${SUDO} iptables -C DOCKER-USER -i "${dev}" -j AGY-SANDBOX-FWD >/dev/null 2>&1; do
        ${SUDO} iptables -D DOCKER-USER -i "${dev}" -j AGY-SANDBOX-FWD 2>/dev/null || break
      done
    done

    # Clean legacy direct DROP rules
    for snet in "${ACTIVE_SUBNET}" "${DEFAULT_SUBNET}" "172.16.151.0/24"; do
      for dest in "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12"; do
        while ${SUDO} iptables -C DOCKER-USER -s "${snet}" -d "${dest}" -j DROP >/dev/null 2>&1; do
          ${SUDO} iptables -D DOCKER-USER -s "${snet}" -d "${dest}" -j DROP 2>/dev/null || break
        done
      done
    done
  fi

  # Flush and delete AGY-SANDBOX-FWD
  if ${SUDO} iptables -L AGY-SANDBOX-FWD -n >/dev/null 2>&1; then
    ${SUDO} iptables -F AGY-SANDBOX-FWD 2>/dev/null || true
    ${SUDO} iptables -X AGY-SANDBOX-FWD 2>/dev/null || true
  fi

  # Detach AGY-SANDBOX-IN from INPUT
  if ${SUDO} iptables -L INPUT -n >/dev/null 2>&1; then
    for dev in "${ACTIVE_BRIDGE}" "${BRIDGE_NAME}"; do
      while ${SUDO} iptables -C INPUT -i "${dev}" -j AGY-SANDBOX-IN >/dev/null 2>&1; do
        ${SUDO} iptables -D INPUT -i "${dev}" -j AGY-SANDBOX-IN 2>/dev/null || break
      done

      # Clean legacy direct INPUT rules
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
  fi

  # Flush and delete AGY-SANDBOX-IN
  if ${SUDO} iptables -L AGY-SANDBOX-IN -n >/dev/null 2>&1; then
    ${SUDO} iptables -F AGY-SANDBOX-IN 2>/dev/null || true
    ${SUDO} iptables -X AGY-SANDBOX-IN 2>/dev/null || true
  fi
fi

# --------------------------------------------------------
# 3. Clean IPv6 Boundary Rules (ip6tables)
# --------------------------------------------------------
if command -v ip6tables >/dev/null 2>&1; then
  echo "==> Cleaning ip6tables rules..."
  for dev in "${ACTIVE_BRIDGE}" "${BRIDGE_NAME}"; do
    while ${SUDO} ip6tables -C FORWARD -i "${dev}" -j DROP >/dev/null 2>&1; do
      ${SUDO} ip6tables -D FORWARD -i "${dev}" -j DROP 2>/dev/null || break
    done
    while ${SUDO} ip6tables -C INPUT -i "${dev}" -j DROP >/dev/null 2>&1; do
      ${SUDO} ip6tables -D INPUT -i "${dev}" -j DROP 2>/dev/null || break
    done
    if ${SUDO} ip6tables -L DOCKER-USER -n >/dev/null 2>&1; then
      while ${SUDO} ip6tables -C DOCKER-USER -i "${dev}" -j DROP >/dev/null 2>&1; do
        ${SUDO} ip6tables -D DOCKER-USER -i "${dev}" -j DROP 2>/dev/null || break
      done
    fi
  done
fi

# --------------------------------------------------------
# 4. Clean Linux Policy Routing (ip rule)
# --------------------------------------------------------
if command -v ip >/dev/null 2>&1; then
  echo "==> Removing Linux Policy Routing (ip rule)..."
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

  for snet in "${ACTIVE_SUBNET}" "${DEFAULT_SUBNET}" "172.16.151.0/24"; do
    while ip rule show 2>/dev/null | grep -E "[[:space:]]+from ${snet}[[:space:]]+" >/dev/null 2>&1; do
      ${SUDO} ip rule del from "${snet}" 2>/dev/null || break
    done
  done
fi

# --------------------------------------------------------
# 5. Remove Docker network
# --------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "==> Removing Docker network '${NETWORK_NAME}'..."
    docker network rm "${NETWORK_NAME}" 2>/dev/null || true
  fi
fi

echo "==> [antigravity-sandbox] Network teardown completed successfully."
