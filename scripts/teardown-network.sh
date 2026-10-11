#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Network Teardown
# Cleans up dynamic Netfilter rules, policy routing, and
# removes isolated bridge network
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

ACTIVE_BRIDGE="${BRIDGE_NAME}"
if command -v docker >/dev/null 2>&1 && docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
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

# --------------------------------------------------------
# 1. Clean Netfilter DOCKER-USER & INPUT rules
# --------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
  if ${SUDO} iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    echo "==> Removing DOCKER-USER Netfilter rules..."
    for dest in "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12"; do
      while ${SUDO} iptables -C DOCKER-USER -s "${DEFAULT_SUBNET}" -d "${dest}" -j DROP >/dev/null 2>&1; do
        ${SUDO} iptables -D DOCKER-USER -s "${DEFAULT_SUBNET}" -d "${dest}" -j DROP 2>/dev/null || break
      done
    done
  fi

  clean_input_rules() {
    local dev="$1"
    echo "==> Removing INPUT host boundary Netfilter rules for '${dev}'..."
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
  }

  clean_input_rules "${BRIDGE_NAME}"
  if [ -n "${ACTIVE_BRIDGE:-}" ] && [ "${ACTIVE_BRIDGE}" != "${BRIDGE_NAME}" ]; then
    clean_input_rules "${ACTIVE_BRIDGE}"
  fi
fi

# --------------------------------------------------------
# 2. Clean Linux Policy Routing (ip rule)
# --------------------------------------------------------
if command -v ip >/dev/null 2>&1; then
  echo "==> Removing Linux Policy Routing (ip rule)..."
  delete_ip_rule() {
    local prio="$1"
    local spec="$2"
    local check_spec="${spec}"
    if [[ "${spec}" =~ lookup\ 254 ]]; then
      check_spec="${spec//lookup 254/lookup (254|main)}"
    fi
    while ip rule show | grep -E "^${prio}:[[:space:]]+from ${DEFAULT_SUBNET}[[:space:]]+${check_spec}" >/dev/null 2>&1; do
      ${SUDO} ip rule del priority "${prio}" from "${DEFAULT_SUBNET}" ${spec} 2>/dev/null || \
      ${SUDO} ip rule del priority "${prio}" from "${DEFAULT_SUBNET}" 2>/dev/null || break
    done
  }

  delete_ip_rule 70 "to ${DEFAULT_SUBNET} lookup 254"
  delete_ip_rule 80 "to 172.16.0.0/12 type unreachable"
  delete_ip_rule 80 "to 192.168.0.0/16 type unreachable"
  delete_ip_rule 80 "to 10.0.0.0/8 type unreachable"
  delete_ip_rule 100 "lookup 254"
fi

# --------------------------------------------------------
# 3. Remove Docker network
# --------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "==> Removing Docker network '${NETWORK_NAME}'..."
    docker network rm "${NETWORK_NAME}" 2>/dev/null || true
  fi
fi

echo "==> [antigravity-sandbox] Network teardown completed successfully."
