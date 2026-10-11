#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Security Diagnostics
# Audits Docker network, Linux Policy Routing (ip rule),
# Netfilter DOCKER-USER & INPUT host boundary isolation,
# and Systemd persistence status.
# ========================================================

NETWORK_NAME="agy_net"
DEFAULT_SUBNET="172.16.151.0/24"
BRIDGE_NAME="agy0"

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
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

echo -e "${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo -e "${CLR_CYAN}${CLR_BOLD}       🛡️  ANTIGRAVITY SANDBOX SECURITY AUDITOR 🛡️          ${CLR_RESET}"
echo -e "${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo ""

# --------------------------------------------------------
# 1. Docker Daemon & Network Inspection
# --------------------------------------------------------
echo -e "${CLR_BOLD}[1/5] Docker Engine & Bridge Network (${NETWORK_NAME})${CLR_RESET}"
if ! command -v docker >/dev/null 2>&1; then
  log_fail "Docker CLI not found in PATH."
else
  if ! docker info >/dev/null 2>&1; then
    log_fail "Docker daemon is not running or current user lacks access."
  else
    log_pass "Docker daemon is responsive."

    if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
      subnet_found=$(docker network inspect "${NETWORK_NAME}" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "")
      if [ "${subnet_found}" = "${DEFAULT_SUBNET}" ]; then
        log_pass "Docker network '${NETWORK_NAME}' configured with subnet ${DEFAULT_SUBNET}."
      else
        log_warn "Docker network '${NETWORK_NAME}' has unexpected subnet: '${subnet_found}' (expected ${DEFAULT_SUBNET})."
      fi

      ACTIVE_BRIDGE="${BRIDGE_NAME}"
      bridge_opt=$(docker network inspect "${NETWORK_NAME}" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
      if [ -n "${bridge_opt}" ] && [ "${bridge_opt}" != "<no value>" ]; then
        ACTIVE_BRIDGE="${bridge_opt}"
        if [ "${bridge_opt}" = "${BRIDGE_NAME}" ]; then
          log_pass "Docker network bridge interface mapped to '${BRIDGE_NAME}'."
        else
          log_info "Docker network bridge interface mapped to '${bridge_opt}'."
        fi
      else
        net_id=$(docker network inspect "${NETWORK_NAME}" --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "${net_id}" ]; then
          ACTIVE_BRIDGE="br-${net_id:0:12}"
          log_info "Network '${NETWORK_NAME}' uses dynamic bridge interface '${ACTIVE_BRIDGE}'."
          log_info "Tip: To migrate to '${BRIDGE_NAME}', stop running containers, then run: ./scripts/teardown.sh && ./scripts/ensure-network.sh"
        fi
      fi
    else
      ACTIVE_BRIDGE="${BRIDGE_NAME}"
      log_fail "Docker network '${NETWORK_NAME}' does not exist. Run ensure-network.sh."
    fi
  fi
fi
echo ""

# --------------------------------------------------------
# 2. Kernel Interface Check
# --------------------------------------------------------
echo -e "${CLR_BOLD}[2/5] Kernel Bridge Interface (${ACTIVE_BRIDGE})${CLR_RESET}"
if command -v ip >/dev/null 2>&1; then
  if ip link show "${ACTIVE_BRIDGE}" >/dev/null 2>&1; then
    log_pass "Interface '${ACTIVE_BRIDGE}' exists in kernel."
  elif [ "${ACTIVE_BRIDGE}" != "${BRIDGE_NAME}" ] && ip link show "${BRIDGE_NAME}" >/dev/null 2>&1; then
    log_pass "Interface '${BRIDGE_NAME}' exists in kernel."
  else
    log_warn "Interface '${ACTIVE_BRIDGE}' not found in 'ip link' (created when network or first container starts)."
  fi
else
  log_warn "'ip' command not found."
fi
echo ""

# --------------------------------------------------------
# 3. Linux Kernel Policy Routing (ip rule)
# --------------------------------------------------------
echo -e "${CLR_BOLD}[3/5] Linux Kernel Policy Routing (ip rule)${CLR_RESET}"
if command -v ip >/dev/null 2>&1; then
  rules_dump=$(ip rule show 2>/dev/null || echo "")
  
  # Rule 70: local subnet lookup
  if echo "${rules_dump}" | grep -E "^70:[[:space:]]+from ${DEFAULT_SUBNET}[[:space:]]+to ${DEFAULT_SUBNET}[[:space:]]+lookup (main|254)" >/dev/null 2>&1; then
    log_pass "Rule prio 70: Intra-subnet traffic routing allowed (to ${DEFAULT_SUBNET})."
  else
    log_fail "Rule prio 70: Missing intra-subnet rule (from ${DEFAULT_SUBNET} to ${DEFAULT_SUBNET})."
  fi

  # Rule 80: RFC 1918 unreachable
  for rfc in "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"; do
    if echo "${rules_dump}" | grep -E "^80:[[:space:]]+from ${DEFAULT_SUBNET}[[:space:]]+to ${rfc}[[:space:]]+unreachable" >/dev/null 2>&1; then
      log_pass "Rule prio 80: Outbound to private RFC 1918 subnet ${rfc} marked unreachable."
    else
      log_fail "Rule prio 80: Missing unreachable rule for ${rfc}."
    fi
  done

  # Rule 100: default main table lookup
  if echo "${rules_dump}" | grep -E "^100:[[:space:]]+from ${DEFAULT_SUBNET}[[:space:]]+lookup (main|254)" >/dev/null 2>&1; then
    log_pass "Rule prio 100: Main routing table lookup active for external internet."
  else
    log_fail "Rule prio 100: Missing main routing table fallback rule."
  fi
else
  log_warn "'ip' command not found."
fi
echo ""

# --------------------------------------------------------
# 4. Netfilter Firewall (DOCKER-USER & INPUT)
# --------------------------------------------------------
echo -e "${CLR_BOLD}[4/5] Netfilter Packet Filtering (iptables)${CLR_RESET}"
if command -v iptables >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    if ! sudo -n true 2>/dev/null; then
      echo -e "  ${CLR_YELLOW}==> Root privileges required to inspect Netfilter rules.${CLR_RESET}"
      sudo -v 2>/dev/null || true
    fi
  fi

  # 4a: DOCKER-USER forwarding boundary
  if ${SUDO} iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    for dest in "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12"; do
      if ${SUDO} iptables -C DOCKER-USER -s "${DEFAULT_SUBNET}" -d "${dest}" -j DROP >/dev/null 2>&1; then
        log_pass "DOCKER-USER chain: Forwarding DROP rule to ${dest} is active."
      else
        log_fail "DOCKER-USER chain: Missing DROP rule to ${dest}."
      fi
    done
  else
    log_warn "DOCKER-USER chain not found in iptables filter table."
  fi

  # 4b: INPUT host boundary isolation
  if ${SUDO} iptables -L INPUT -n >/dev/null 2>&1; then
    # Established
    if ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || \
       ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -m state --state ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || \
       ${SUDO} iptables -C INPUT -i "${BRIDGE_NAME}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; then
      log_pass "INPUT chain: ESTABLISHED/RELATED stateful flows accepted on bridge."
    else
      log_fail "INPUT chain: Missing ESTABLISHED/RELATED rule on bridge."
    fi

    # DNS UDP/TCP
    if ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -p udp --dport 53 -j ACCEPT >/dev/null 2>&1 || \
       ${SUDO} iptables -C INPUT -i "${BRIDGE_NAME}" -p udp --dport 53 -j ACCEPT >/dev/null 2>&1; then
      log_pass "INPUT chain: Host DNS UDP port 53 query accepted on bridge."
    else
      log_fail "INPUT chain: Missing DNS UDP port 53 rule on bridge."
    fi

    if ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -p tcp --dport 53 -j ACCEPT >/dev/null 2>&1 || \
       ${SUDO} iptables -C INPUT -i "${BRIDGE_NAME}" -p tcp --dport 53 -j ACCEPT >/dev/null 2>&1; then
      log_pass "INPUT chain: Host DNS TCP port 53 query accepted on bridge."
    else
      log_fail "INPUT chain: Missing DNS TCP port 53 rule on bridge."
    fi

    # Host boundary DROP
    if ${SUDO} iptables -C INPUT -i "${ACTIVE_BRIDGE}" -j DROP >/dev/null 2>&1 || \
       ${SUDO} iptables -C INPUT -i "${BRIDGE_NAME}" -j DROP >/dev/null 2>&1; then
      log_pass "INPUT chain: Host boundary DROP rule active on bridge (unauthorized host ports blocked)."
    else
      log_fail "INPUT chain: Missing host boundary DROP rule on bridge (HOST PORTS EXPOSED!)."
    fi

    # Verify rule order (DROP must come after DNS in INPUT chain)
    input_rules=$(${SUDO} iptables -S INPUT 2>/dev/null || echo "")
    drop_line=$(echo "${input_rules}" | grep -n -E -- "-i (${ACTIVE_BRIDGE}|${BRIDGE_NAME}) -j DROP" | head -n1 | cut -d: -f1 || echo "0")
    dns_line=$(echo "${input_rules}" | grep -n -E -- "-i (${ACTIVE_BRIDGE}|${BRIDGE_NAME}) -p udp --dport 53 -j ACCEPT" | head -n1 | cut -d: -f1 || echo "0")
    if [ -n "${drop_line}" ] && [ -n "${dns_line}" ] && [ "${drop_line}" -gt 0 ] && [ "${dns_line}" -gt 0 ]; then
      if [ "${drop_line}" -gt "${dns_line}" ]; then
        log_pass "INPUT chain: Rule ordering verified (DNS evaluated before DROP)."
      else
        log_fail "INPUT chain: Incorrect rule ordering (DROP rule precedes DNS rule!)."
      fi
    fi
  else
    log_fail "INPUT chain inaccessible in iptables."
  fi
else
  log_warn "'iptables' command not found."
fi
echo ""

# --------------------------------------------------------
# 5. Systemd Persistence Status
# --------------------------------------------------------
echo -e "${CLR_BOLD}[5/5] Systemd Network Daemon Persistence${CLR_RESET}"
UNIT_FILE="/etc/systemd/system/agy-sandbox-network.service"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  if [ -f "${UNIT_FILE}" ]; then
    log_pass "Systemd unit file exists at ${UNIT_FILE}."
    
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
