#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Network Provisioner
# Ensures isolated bridge network exists with kernel routing
# and Netfilter (DOCKER-USER) boundary isolation
# ========================================================

NETWORK_NAME="agy_net"
DEFAULT_SUBNET="172.16.151.0/24"
BRIDGE_NAME="agy0"

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

echo "==> [antigravity-sandbox] Checking Docker network: '${NETWORK_NAME}'..."

if ! command -v docker >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Error: docker CLI is not installed or not in PATH." >&2
  exit 1
fi

ACTIVE_BRIDGE="${BRIDGE_NAME}"

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Network '${NETWORK_NAME}' already exists."
  bridge_opt=$(docker network inspect "${NETWORK_NAME}" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
  if [ -n "${bridge_opt}" ] && [ "${bridge_opt}" != "<no value>" ]; then
    ACTIVE_BRIDGE="${bridge_opt}"
  else
    connected_containers=$(docker network inspect "${NETWORK_NAME}" --format '{{len .Containers}}' 2>/dev/null || echo "0")
    if [ "${connected_containers}" -eq 0 ]; then
      echo "==> [antigravity-sandbox] Network '${NETWORK_NAME}' has 0 active containers. Upgrading bridge to '${BRIDGE_NAME}'..."
      docker network rm "${NETWORK_NAME}" 2>/dev/null || true
      docker network create \
        --driver bridge \
        --subnet "${DEFAULT_SUBNET}" \
        --opt "com.docker.network.bridge.enable_icc=true" \
        --opt "com.docker.network.bridge.name=${BRIDGE_NAME}" \
        "${NETWORK_NAME}"
      echo "==> [antigravity-sandbox] Recreated '${NETWORK_NAME}' with bridge '${BRIDGE_NAME}'."
      ACTIVE_BRIDGE="${BRIDGE_NAME}"
    else
      net_id=$(docker network inspect "${NETWORK_NAME}" --format '{{.Id}}' 2>/dev/null || echo "")
      if [ -n "${net_id}" ]; then
        ACTIVE_BRIDGE="br-${net_id:0:12}"
        echo "==> [antigravity-sandbox] Network in use by ${connected_containers} active containers on '${ACTIVE_BRIDGE}'."
      fi
    fi
  fi
else
  echo "==> [antigravity-sandbox] Creating isolated bridge network '${NETWORK_NAME}' (${DEFAULT_SUBNET})..."
  docker network create \
    --driver bridge \
    --subnet "${DEFAULT_SUBNET}" \
    --opt "com.docker.network.bridge.enable_icc=true" \
    --opt "com.docker.network.bridge.name=${BRIDGE_NAME}" \
    "${NETWORK_NAME}"
  echo "==> [antigravity-sandbox] Successfully created '${NETWORK_NAME}'."
  ACTIVE_BRIDGE="${BRIDGE_NAME}"
fi

# --------------------------------------------------------
# 1. Linux Kernel Policy Routing (ip rule)
# --------------------------------------------------------
if command -v ip >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Configuring Linux Policy Routing (ip rule)..."
  
  ensure_ip_rule() {
    local prio="$1"
    local spec="$2"
    local check_spec="${spec//type /}"
    if [[ "${check_spec}" =~ lookup\ 254 ]]; then
      check_spec="${check_spec//lookup 254/lookup (254|main)}"
    fi
    if ! ip rule show | grep -E "^${prio}:[[:space:]]+from ${DEFAULT_SUBNET}[[:space:]]+${check_spec}" >/dev/null 2>&1; then
      local -a spec_args
      read -r -a spec_args <<< "${spec}"
      if [[ "$(id -u)" -eq 0 ]]; then
        ip rule add priority "${prio}" from "${DEFAULT_SUBNET}" "${spec_args[@]}"
      elif command -v sudo >/dev/null 2>&1; then
        sudo ip rule add priority "${prio}" from "${DEFAULT_SUBNET}" "${spec_args[@]}"
    fi
    fi
  }

  ensure_ip_rule 70 "to ${DEFAULT_SUBNET} lookup 254"
  ensure_ip_rule 80 "to 172.16.0.0/12 type unreachable"
  ensure_ip_rule 80 "to 192.168.0.0/16 type unreachable"
  ensure_ip_rule 80 "to 10.0.0.0/8 type unreachable"
  ensure_ip_rule 100 "lookup 254"
fi

# --------------------------------------------------------
# 2. Netfilter Isolation (DOCKER-USER chain)
# --------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
  echo "==> [antigravity-sandbox] Configuring Netfilter DOCKER-USER rules..."
  
  SUDO=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi

  # Ensure DOCKER-USER chain exists or wait until Docker initializes it
  if ${SUDO} iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    for dest in "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12"; do
      if ! ${SUDO} iptables -C DOCKER-USER -s "${DEFAULT_SUBNET}" -d "${dest}" -j DROP >/dev/null 2>&1; then
        ${SUDO} iptables -I DOCKER-USER 1 -s "${DEFAULT_SUBNET}" -d "${dest}" -j DROP 2>/dev/null || true
      fi
    done
  fi

  # --------------------------------------------------------
  # 3. Host Boundary Isolation (INPUT chain)
  # Blocks access from sandbox container to host sockets/ports
  # while preserving established flows and host DNS if used
  # --------------------------------------------------------
  echo "==> [antigravity-sandbox] Configuring Netfilter INPUT host boundary rules..."

  apply_input_rules() {
    local dev="$1"
    # Clean existing rules for interface to guarantee idempotent ordering
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

    # Insert rules at position 1 in reverse order
    ${SUDO} iptables -I INPUT 1 -i "${dev}" -j DROP 2>/dev/null || true
    ${SUDO} iptables -I INPUT 1 -i "${dev}" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    ${SUDO} iptables -I INPUT 1 -i "${dev}" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    if ! ${SUDO} iptables -I INPUT 1 -i "${dev}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
      ${SUDO} iptables -I INPUT 1 -i "${dev}" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi
  }

  apply_input_rules "${BRIDGE_NAME}"
  if [ -n "${ACTIVE_BRIDGE:-}" ] && [ "${ACTIVE_BRIDGE}" != "${BRIDGE_NAME}" ]; then
    apply_input_rules "${ACTIVE_BRIDGE}"
  fi
fi

echo "==> [antigravity-sandbox] Network '${NETWORK_NAME}' and boundary isolation verified."

