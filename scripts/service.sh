#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox Network Persistence Manager
# Generates, installs, and manages systemd service for
# agy-sandbox-network (Type=oneshot, RemainAfterExit=yes)
# ========================================================

# Resolve symlinks to find real script location
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

SERVICE_NAME="agy-sandbox-network.service"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
ENSURE_SCRIPT="${SCRIPT_DIR}/ensure-network.sh"
TEARDOWN_SCRIPT="${SCRIPT_DIR}/teardown-network.sh"

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

ensure_sudo() {
  local reason="${1:-Administrative privileges (sudo) are required to manage systemd services.}"
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "==> [antigravity-sandbox] Error: 'sudo' command not found. Please run as root." >&2
    return 1
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "==> [antigravity-sandbox] ${reason}"
    if ! sudo -v; then
      echo "==> [antigravity-sandbox] Sudo authentication failed. Aborting." >&2
      return 1
    fi
  fi
}

check_systemd_support() {
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    return 1
  fi
  return 0
}

generate_unit_content() {
  cat <<EOF
[Unit]
Description=Antigravity Sandbox Network Isolation Daemon
Documentation=https://github.com/Retr0defeated/antigravity-sandbox
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ENSURE_SCRIPT}
ExecStop=${TEARDOWN_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
}

cmd_generate() {
  generate_unit_content
}

cmd_status() {
  echo "==> [antigravity-sandbox] Checking systemd service status: '${SERVICE_NAME}'"

  if ! check_systemd_support; then
    echo "  [WARN] systemd is not running as init system in this environment."
    echo "         (Common inside Docker containers, minimal WSL2 distros, or non-systemd inits)."
    echo "         Kernel rules must be applied manually via ${ENSURE_SCRIPT}."
    return 3
  fi

  if [ ! -f "${UNIT_PATH}" ]; then
    echo "  Status: NOT INSTALLED"
    echo "  Unit file '${UNIT_PATH}' does not exist."
    return 2
  fi

  local is_enabled="unknown"
  local is_active="unknown"

  if systemctl is-enabled "${SERVICE_NAME}" >/dev/null 2>&1; then
    is_enabled="enabled"
  else
    is_enabled="disabled"
  fi

  if systemctl is-active "${SERVICE_NAME}" >/dev/null 2>&1; then
    is_active="active (running)"
  else
    is_active="inactive (dead)"
  fi

  echo "  Unit path: ${UNIT_PATH}"
  echo "  ExecStart: ${ENSURE_SCRIPT}"
  echo "  ExecStop:  ${TEARDOWN_SCRIPT}"
  echo "  Enabled:   ${is_enabled}"
  echo "  Active:    ${is_active}"

  if [ "${is_active}" = "active (running)" ]; then
    return 0
  else
    return 1
  fi
}

cmd_install() {
  if ! check_systemd_support; then
    echo "==> [antigravity-sandbox] Error: systemd is not active on this host." >&2
    return 1
  fi
  ensure_sudo "Root privileges required to install systemd service."

  echo "==> [antigravity-sandbox] Installing '${SERVICE_NAME}' to ${UNIT_PATH}..."
  
  # Ensure target scripts are executable
  chmod +x "${ENSURE_SCRIPT}" "${TEARDOWN_SCRIPT}" 2>/dev/null || true

  # Write unit file
  generate_unit_content | ${SUDO} tee "${UNIT_PATH}" >/dev/null
  ${SUDO} chmod 644 "${UNIT_PATH}"
  ${SUDO} systemctl daemon-reload
  echo "==> [antigravity-sandbox] Successfully installed ${UNIT_PATH}."
}

cmd_enable() {
  if ! check_systemd_support; then
    echo "==> [antigravity-sandbox] Error: systemd is not active on this host." >&2
    return 1
  fi
  ensure_sudo "Root privileges required to enable and start systemd service."

  if [ ! -f "${UNIT_PATH}" ]; then
    cmd_install
  fi

  echo "==> [antigravity-sandbox] Enabling and starting '${SERVICE_NAME}'..."
  ${SUDO} systemctl enable --now "${SERVICE_NAME}"
  echo "==> [antigravity-sandbox] Service '${SERVICE_NAME}' is now enabled and running."
}

cmd_disable() {
  if ! check_systemd_support; then
    echo "==> [antigravity-sandbox] Error: systemd is not active on this host." >&2
    return 1
  fi
  ensure_sudo "Root privileges required to stop and disable systemd service."

  echo "==> [antigravity-sandbox] Disabling and stopping '${SERVICE_NAME}'..."
  ${SUDO} systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
  echo "==> [antigravity-sandbox] Service '${SERVICE_NAME}' is stopped and disabled."
}

cmd_uninstall() {
  if ! check_systemd_support; then
    echo "==> [antigravity-sandbox] Error: systemd is not active on this host." >&2
    return 1
  fi
  ensure_sudo "Root privileges required to uninstall systemd service."

  echo "==> [antigravity-sandbox] Uninstalling '${SERVICE_NAME}'..."
  cmd_disable || true

  if [ -f "${UNIT_PATH}" ]; then
    ${SUDO} rm -f "${UNIT_PATH}"
    ${SUDO} systemctl daemon-reload
    echo "==> [antigravity-sandbox] Removed ${UNIT_PATH}."
  else
    echo "==> [antigravity-sandbox] Unit file was not present."
  fi
}

usage() {
  echo "Usage: $(basename "$0") <status|enable|disable|install|uninstall|generate>"
  echo ""
  echo "Commands:"
  echo "  status     Check installation and running status of systemd persistence"
  echo "  enable     Install, enable and start agy-sandbox-network.service (enable --now)"
  echo "  disable    Stop and disable agy-sandbox-network.service (disable --now)"
  echo "  install    Generate and install unit file into /etc/systemd/system/"
  echo "  uninstall  Stop, disable, and remove unit file"
  echo "  generate   Print service unit file to stdout"
}

ACTION="${1:-status}"

case "${ACTION}" in
  status)
    cmd_status
    ;;
  enable)
    cmd_enable
    ;;
  disable)
    cmd_disable
    ;;
  install)
    cmd_install
    ;;
  uninstall)
    cmd_uninstall
    ;;
  generate)
    cmd_generate
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "==> [antigravity-sandbox] Unknown command: '${ACTION}'" >&2
    usage >&2
    exit 1
    ;;
esac
