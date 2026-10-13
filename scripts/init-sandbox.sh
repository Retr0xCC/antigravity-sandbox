#!/usr/bin/env bash
set -euo pipefail

# ========================================================
# Antigravity Sandbox CLI & TUI Initializer
# Provides interactive terminal UI and headless CLI to
# inject isolated Dev Container environments and manage
# network boundaries.
# ========================================================

# Resolve symlinks to find real script location even when invoked via ~/.local/bin/agy-sandbox
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"


# ANSI Colors & Formatting
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_DIM="\033[2m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_WHITE="\033[1;37m"

cleanup_terminal() {
  if [ -t 0 ]; then
    tput cnorm 2>/dev/null || printf "\033[?25h"
    stty echo 2>/dev/null || true
  fi
}
trap cleanup_terminal EXIT

global_sigint() {
  cleanup_terminal
  echo ""
  echo -e "${CLR_YELLOW}==> [antigravity-sandbox] Interrupted by user (Ctrl+C).${CLR_RESET}" >&2
  exit 130
}
trap global_sigint INT TERM

ensure_sudo() {
  local reason="${1:-Administrative privileges (sudo) are required for this action.}"

  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: 'sudo' command not found. Please run as root.${CLR_RESET}" >&2
    return 1
  fi

  if sudo -n true 2>/dev/null; then
    return 0
  fi

  echo ""
  echo -e "${CLR_YELLOW}==> [antigravity-sandbox] ${reason}${CLR_RESET}"
  if ! sudo -v; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Sudo authentication failed or cancelled.${CLR_RESET}" >&2
    return 1
  fi
  return 0
}

get_template_description() {
  local t_name="$1"
  local desc_file="${ROOT_DIR}/templates/${t_name}/description.txt"
  if [ -f "${desc_file}" ]; then
    cat "${desc_file}"
  else
    echo "Custom sandbox profile"
  fi
}

list_templates() {
  echo -e "${CLR_BOLD}Available Antigravity Sandbox templates:${CLR_RESET}"
  for t in "${ROOT_DIR}/templates"/*; do
    if [ -d "$t" ]; then
      local name
      name="$(basename "$t")"
      local desc
      desc="$(get_template_description "${name}")"
      printf "  - ${CLR_CYAN}%-15s${CLR_RESET} %s\n" "${name}" "${desc}"
    fi
  done
}

assemble_dockerfile() {
  local base_file="$1"
  local template_name="$2"
  local template_dir="$3"
  local output_file="$4"

  local pkgs=()
  if [ -f "${template_dir}/packages.txt" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ "$line" =~ ^#.*$ ]] && continue
      [ -z "$line" ] && continue
      pkgs+=("$line")
    done < "${template_dir}/packages.txt"
  fi

  rm -f "${output_file}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^#\ Configure\ unprivileged\ vscode\ user ]] && [ ${#pkgs[@]} -gt 0 ]; then
      echo "# Install additional packages for ${template_name}" >> "${output_file}"
      echo "RUN apt-get update && apt-get install -y --no-install-recommends \\" >> "${output_file}"
      for p in "${pkgs[@]}"; do
        echo "    ${p} \\" >> "${output_file}"
      done
      echo "    && rm -rf /var/lib/apt/lists/*" >> "${output_file}"
      echo "" >> "${output_file}"
    fi

    if [[ "$line" =~ ^WORKDIR\ /workspaces ]] && [ -f "${template_dir}/extra.Dockerfile" ]; then
      cat "${template_dir}/extra.Dockerfile" >> "${output_file}"
      echo "" >> "${output_file}"
    fi

    echo "$line" >> "${output_file}"
  done < "${base_file}"
}

assemble_devcontainer_json() {
  local base_json="$1"
  local template_name="$2"
  local template_dir="$3"
  local output_file="$4"

  local display_name="${template_name}"
  if [ "${template_name}" = "default" ]; then
    display_name="Agy"
  fi

  local exts=()
  if [ -f "${template_dir}/extensions.txt" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ "$line" =~ ^#.*$ ]] && continue
      [ -z "$line" ] && continue
      exts+=("$line")
    done < "${template_dir}/extensions.txt"
  fi

  if command -v jq >/dev/null 2>&1; then
    local exts_json="[]"
    if [ ${#exts[@]} -gt 0 ]; then
      exts_json=$(printf '%s\n' "${exts[@]}" | jq -R . | jq -s .)
    fi

    local settings_json="{}"
    if [ -f "${template_dir}/settings.json" ]; then
      settings_json=$(jq . "${template_dir}/settings.json")
    else
      settings_json=$(jq ".customizations.vscode.settings" "${base_json}")
    fi

    jq --arg name "\${localWorkspaceFolderBasename} (${display_name} Sandbox)" \
       --argjson exts "${exts_json}" \
       --argjson settings "${settings_json}" \
       '.name = $name | .customizations.vscode.extensions = $exts | .customizations.vscode.settings = $settings' \
       "${base_json}" > "${output_file}"
  else
    local template_content
    template_content=$(cat "${base_json}")
    template_content="${template_content//@@TEMPLATE_NAME@@/${display_name}}"
    echo -e "${template_content}" > "${output_file}"
  fi
}

assemble_declarative_template() {
  local template_path="$1"
  local template_name="$2"
  local dest_dir="$3"

  # 1. Setup hook
  cp "${ROOT_DIR}/base/setup.sh" "${dest_dir}/setup.sh"
  if [ -f "${template_path}/extra-setup.sh" ]; then
    echo "" >> "${dest_dir}/setup.sh"
    cat "${template_path}/extra-setup.sh" >> "${dest_dir}/setup.sh"
  fi

  # 2. Dockerfile
  assemble_dockerfile "${ROOT_DIR}/base/Dockerfile" "${template_name}" "${template_path}" "${dest_dir}/Dockerfile"

  # 3. devcontainer.json
  assemble_devcontainer_json "${ROOT_DIR}/base/devcontainer.json" "${template_name}" "${template_path}" "${dest_dir}/devcontainer.json"
}

expand_path() {
  local p="$1"
  # Expand tilde: ~ or ~/path
  if [[ "$p" == "~" ]] || [[ "$p" == "~/" ]]; then
    p="${HOME}"
  elif [[ "$p" =~ ^~/(.*) ]]; then
    p="${HOME}/${BASH_REMATCH[1]}"
  fi

  # Remove trailing slashes (except root /)
  if [[ "$p" != "/" ]]; then
    p="${p%/}"
  fi

  # Convert relative path to absolute
  if [[ "$p" != /* ]]; then
    p="${PWD}/${p}"
  fi

  # Canonicalize if path exists
  if [ -d "$p" ]; then
    p="$(cd -P "$p" && pwd)"
  elif [ -f "$p" ]; then
    local dir
    dir="$(cd -P "$(dirname "$p")" && pwd)"
    p="${dir}/$(basename "$p")"
  else
    # Directory does not exist yet: canonicalize existing parent prefix
    local parent
    parent="$(dirname "$p")"
    local base
    base="$(basename "$p")"
    while [ ! -d "$parent" ] && [ "$parent" != "/" ] && [ "$parent" != "." ]; do
      base="$(basename "$parent")/${base}"
      parent="$(dirname "$parent")"
    done
    if [ -d "$parent" ]; then
      parent="$(cd -P "$parent" && pwd)"
      p="${parent}/${base}"
    fi
  fi

  echo "$p"
}

do_init_sandbox() {
  local target_dir="${1:-.}"
  local template="${2:-default}"
  local auto_gitignore="${3:-prompt}" # prompt, yes, no

  # Expand tilde and relative paths to canonical absolute path
  target_dir="$(expand_path "${target_dir}")"

  if [ ! -d "${target_dir}" ]; then
    echo "==> [antigravity-sandbox] Directory '${target_dir}' does not exist. Creating..."
    mkdir -p "${target_dir}"
  fi

  local template_path="${ROOT_DIR}/templates/${template}"
  if [ ! -d "${template_path}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Template '${template}' not found at ${template_path}${CLR_RESET}" >&2
    echo "    Available templates:" >&2
    list_templates >&2
    return 1
  fi

  local dest_devcontainer="${target_dir}/.devcontainer"
  echo "==> [antigravity-sandbox] Initializing sandbox in '${target_dir}'..."
  echo "==> [antigravity-sandbox] Selected template profile: '${template}'"

  mkdir -p "${dest_devcontainer}"

  # Dispatch: Full Custom Mode vs Declarative Mode
  if [ -f "${template_path}/devcontainer.json" ] || [ -f "${template_path}/Dockerfile" ]; then
    echo "==> [antigravity-sandbox] Deploying Full Custom template..."
    cp -r "${template_path}/"* "${dest_devcontainer}/"
    if [ ! -f "${dest_devcontainer}/setup.sh" ]; then
      cp "${ROOT_DIR}/base/setup.sh" "${dest_devcontainer}/setup.sh"
    fi
  else
    echo "==> [antigravity-sandbox] Assembling declarative template from base..."
    assemble_declarative_template "${template_path}" "${template}" "${dest_devcontainer}"
  fi

  if [ -f "${dest_devcontainer}/setup.sh" ]; then
    chmod +x "${dest_devcontainer}/setup.sh"
  fi

  # Ensure isolated docker network and dynamic kernel routing exist on host
  if command -v docker >/dev/null 2>&1; then
    "${SCRIPT_DIR}/ensure-network.sh" || true
  fi

  # Gitignore handling
  local target_gitignore="${target_dir}/.gitignore"
  if [ -f "${target_gitignore}" ]; then
    if ! grep -q "^\.devcontainer" "${target_gitignore}"; then
      local do_add="n"
      if [ "${auto_gitignore}" = "yes" ]; then
        do_add="y"
      elif [ "${auto_gitignore}" = "no" ]; then
        do_add="n"
      elif [ -t 0 ]; then
        local choice=""
        if ! read -r -p "==> Add .devcontainer/ to ${target_gitignore}? (y/N): " choice; then
          local rc=$?
          if [ "$rc" -gt 128 ]; then
            echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Operation cancelled.${CLR_RESET}"
            exit 130
          fi
          choice="n"
        fi
        do_add="${choice}"
      elif read -r choice 2>/dev/null; then
        do_add="${choice}"
      fi

      if [[ "${do_add}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo -e "\n# Dev Container Antigravity Sandbox (Isolated)\n.devcontainer/" >> "${target_gitignore}"
        echo "==> Added .devcontainer/ to ${target_gitignore}"
      fi
    fi
  fi

  echo ""
  echo -e "${CLR_GREEN}======================================================================${CLR_RESET}"
  echo -e "${CLR_BOLD} Antigravity Sandbox successfully configured in ${dest_devcontainer}!${CLR_RESET}"
  echo -e "${CLR_GREEN}======================================================================${CLR_RESET}"
  echo "Template: '${template}'"
  echo "Next steps:"
  echo " 1. Open the project in VS Code / Cursor: code ${target_dir}"
  echo " 2. Press F1 -> 'Dev Containers: Reopen in Container'"
  echo " 3. Antigravity Agent will run safely inside the isolated container"
  echo -e "${CLR_GREEN}======================================================================${CLR_RESET}"
}

# ========================================================
# Interactive TUI Implementation
# ========================================================

tui_header() {
  clear 2>/dev/null || true
  echo -e "${CLR_BOLD}${CLR_CYAN}┌─────────────────────────────────────────────────────────────┐${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}│               🛡️  ANTIGRAVITY SANDBOX CLI                   │${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}│         Hardened Dev Container Isolation Manager            │${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}└─────────────────────────────────────────────────────────────┘${CLR_RESET}"
  echo ""
}

pause_enter() {
  echo ""
  local rc=0
  local dummy=""
  read -r -p "Press [Enter] to return to the menu..." dummy || rc=$?
  if [ "$rc" -gt 128 ]; then
    return 130
  fi
}

tui_service_menu() {
  trap 'echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Returning to main menu...${CLR_RESET}"; sleep 0.5; return 130' INT
  while true; do
    tui_header
    echo -e "${CLR_BOLD}=== Network Isolation Service & Persistence ===${CLR_RESET}"
    echo ""
    
    # Quick Status Line
    local net_status="INACTIVE"
    if command -v docker >/dev/null 2>&1 && docker network inspect agy_net >/dev/null 2>&1; then
      net_status="${CLR_GREEN}ACTIVE${CLR_RESET}"
    else
      net_status="${CLR_RED}NOT RUNNING${CLR_RESET}"
    fi

    local host_bound="INACTIVE"
    local sudo_cmd=""
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then sudo_cmd="sudo"; fi
    local active_br="agy0"
    if command -v docker >/dev/null 2>&1 && docker network inspect agy_net >/dev/null 2>&1; then
      local br_opt
      br_opt=$(docker network inspect agy_net --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
      if [ -z "${br_opt}" ] || [ "${br_opt}" = "<no value>" ]; then
        local nid
        nid=$(docker network inspect agy_net --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "${nid}" ]; then active_br="br-${nid:0:12}"; fi
      else
        active_br="${br_opt}"
      fi
    fi
    if command -v iptables >/dev/null 2>&1 && (${sudo_cmd} iptables -C INPUT -i "${active_br}" -j DROP >/dev/null 2>&1 || ${sudo_cmd} iptables -C INPUT -i agy0 -j DROP >/dev/null 2>&1); then
      host_bound="${CLR_GREEN}ACTIVE (BLOCKED)${CLR_RESET}"
    else
      host_bound="${CLR_YELLOW}NOT ACTIVE${CLR_RESET}"
    fi

    local sysd_status="UNKNOWN"
    if [ -f /etc/systemd/system/agy-sandbox-network.service ] && command -v systemctl >/dev/null 2>&1; then
      if systemctl is-enabled agy-sandbox-network.service >/dev/null 2>&1; then
        sysd_status="${CLR_GREEN}ENABLED${CLR_RESET}"
      else
        sysd_status="${CLR_YELLOW}DISABLED${CLR_RESET}"
      fi
    else
      sysd_status="${CLR_DIM}NOT INSTALLED${CLR_RESET}"
    fi

    echo -e "  Docker Network (agy_net):    ${net_status}"
    echo -e "  Host Boundary (INPUT DROP):  ${host_bound}"
    echo -e "  Systemd Persistence:         ${sysd_status}"
    echo ""
    echo -e "  ${CLR_BOLD}[1]${CLR_RESET} Provision / Ensure Network Isolation now (ensure-network.sh)"
    echo -e "  ${CLR_BOLD}[2]${CLR_RESET} Enable & Start Systemd Persistence (systemctl enable --now)"
    echo -e "  ${CLR_BOLD}[3]${CLR_RESET} Disable & Stop Systemd Persistence (systemctl disable --now)"
    echo -e "  ${CLR_BOLD}[4]${CLR_RESET} Teardown Network Isolation (teardown-network.sh)"
    echo -e "  ${CLR_BOLD}[5]${CLR_RESET} Back to Main Menu"
    echo ""
    local rc=0
    local svc_choice="5"
    read -r -p "Select option [1-5]: " svc_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      return 130
    fi

    case "${svc_choice}" in
      1)
        if ! ensure_sudo "Root privileges are required to configure kernel routing and Netfilter rules."; then
          pause_enter
          continue
        fi
        echo ""
        "${SCRIPT_DIR}/ensure-network.sh" || true
        pause_enter
        ;;
      2)
        if ! ensure_sudo "Root privileges are required to install and enable systemd persistence service."; then
          pause_enter
          continue
        fi
        echo ""
        "${SCRIPT_DIR}/service.sh" enable || true
        pause_enter
        ;;
      3)
        if ! ensure_sudo "Root privileges are required to stop and disable systemd persistence service."; then
          pause_enter
          continue
        fi
        echo ""
        "${SCRIPT_DIR}/service.sh" disable || true
        pause_enter
        ;;
      4)
        if ! ensure_sudo "Root privileges are required to remove kernel routing and Netfilter rules."; then
          pause_enter
          continue
        fi
        echo ""
        "${SCRIPT_DIR}/teardown-network.sh" || true
        pause_enter
        ;;
      5|q|Q)
        break
        ;;
      *)
        echo -e "${CLR_RED}Invalid option.${CLR_RESET}"
        sleep 1
        ;;
    esac
  done
}

tui_init_wizard() {
  trap 'echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled by user.${CLR_RESET}"; sleep 0.5; return 130' INT
  tui_header
  echo -e "${CLR_BOLD}=== Initialize Project Sandbox Wizard ===${CLR_RESET}"
  echo ""
  
  local target_dir=""

  while true; do
    # Configure Readline for directory completion if interactive
    if [ -t 0 ]; then
      set -o emacs
      bind 'set mark-directories on' 2>/dev/null || true
      bind 'set mark-symlinked-directories on' 2>/dev/null || true
      bind 'set show-all-if-ambiguous on' 2>/dev/null || true
      bind 'set completion-ignore-case on' 2>/dev/null || true
      bind 'TAB:complete' 2>/dev/null || true
    fi

    local rc=0
    local target_input=""
    read -e -p "Target project directory: " target_input || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi

    # Trim leading/trailing whitespace
    target_input="$(echo "${target_input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "${target_input}" ]; then
      echo -e "${CLR_YELLOW}Path cannot be empty. Please enter a target directory path (or Ctrl+C to cancel).${CLR_RESET}"
      echo ""
      continue
    fi

    target_dir="$(expand_path "${target_input}")"

    # Check existence
    if [ -f "${target_dir}" ]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Error: '${target_dir}' is a regular file, not a directory.${CLR_RESET}"
      echo ""
      continue
    fi

    if [ -d "${target_dir}" ]; then
      echo -e "  Target path: ${CLR_GREEN}${target_dir}${CLR_RESET} ${CLR_DIM}(directory exists)${CLR_RESET}"
      break
    fi

    # Directory does not exist yet
    echo -e "  Target path: ${CLR_YELLOW}${target_dir}${CLR_RESET} ${CLR_DIM}(directory does not exist)${CLR_RESET}"
    local rc=0
    local create_choice="y"
    read -r -p "  Directory does not exist. Create it? [Y/n/cancel]: " create_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi

    case "${create_choice}" in
      [Yy]*|"")
        echo -e "  Directory will be created upon sandbox initialization."
        break
        ;;
      [Nn]*)
        echo ""
        echo "  Please enter another path:"
        continue
        ;;
      [Cc]*|[Qq]*)
        echo -e "${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
        sleep 0.5
        return 130
        ;;
      *)
        echo "  Please choose Y, N, or Cancel."
        continue
        ;;
    esac
  done

  echo ""
  echo -e "${CLR_BOLD}Available Templates:${CLR_RESET}"
  local templates_arr=()
  local i=1
  for t in "${ROOT_DIR}/templates"/*; do
    if [ -d "$t" ]; then
      local t_name
      t_name="$(basename "$t")"
      templates_arr+=("${t_name}")
      local t_desc
      t_desc="$(get_template_description "${t_name}")"
      printf "  ${CLR_BOLD}[%d]${CLR_RESET} ${CLR_CYAN}%-15s${CLR_RESET} - %s\n" "${i}" "${t_name}" "${t_desc}"
      ((i++)) || true
    fi
  done

  echo ""
  local rc=0
  local t_choice="1"
  read -r -p "Select template number [1-${#templates_arr[@]}, default: 1]: " t_choice || rc=$?
  if [ "$rc" -gt 128 ]; then
    echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
    sleep 0.5
    return 130
  fi
  t_choice="${t_choice:-1}"

  local selected_template="default"
  if [[ "${t_choice}" =~ ^[0-9]+$ ]] && [ "${t_choice}" -ge 1 ] && [ "${t_choice}" -le "${#templates_arr[@]}" ]; then
    selected_template="${templates_arr[$((t_choice - 1))]}"
  elif [ -n "${t_choice}" ]; then
    selected_template="${t_choice}"
  fi

  local add_git="yes"
  if [ -f "${target_dir}/.gitignore" ]; then
    local rc=0
    local git_choice="y"
    read -r -p "Add .devcontainer/ to ${target_dir}/.gitignore? (Y/n): " git_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi
    if [[ "${git_choice}" =~ ^[Nn]$ ]]; then
      add_git="no"
    fi
  fi

  echo ""
  do_init_sandbox "${target_dir}" "${selected_template}" "${add_git}"
  pause_enter
}

tui_diagnostics() {
  trap 'echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Diagnostics cancelled.${CLR_RESET}"; sleep 0.5; return 130' INT
  tui_header
  if ! ensure_sudo "Root privileges are required to audit Netfilter firewall and routing rules."; then
    pause_enter
    return
  fi
  "${SCRIPT_DIR}/diagnose.sh" || true
  pause_enter
}

run_tui() {
  while true; do
    trap 'cleanup_terminal; echo -e "\n${CLR_GREEN}Goodbye!${CLR_RESET}"; exit 0' INT
    tui_header
    echo -e "${CLR_BOLD}Main Menu:${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BOLD}[1] 🌐 Network Isolation Service${CLR_RESET}"
    echo -e "      ${CLR_DIM}Check isolation status, manage systemd daemon (enable/disable), or teardown${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BOLD}[2] 📦 Initialize Project Sandbox${CLR_RESET}"
    echo -e "      ${CLR_DIM}Interactive wizard: choose target directory, template profile, and .gitignore${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BOLD}[3] 🔍 Run Security Diagnostics${CLR_RESET}"
    echo -e "      ${CLR_DIM}Audit agy0 bridge, ip rule, Netfilter DOCKER-USER & host INPUT isolation${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BOLD}[4] 🚪 Exit${CLR_RESET}"
    echo ""
    local rc=0
    local main_choice="4"
    read -r -p "Select option [1-4]: " main_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      cleanup_terminal
      echo -e "\n${CLR_GREEN}Goodbye!${CLR_RESET}"
      exit 0
    fi

    case "${main_choice}" in
      1)
        tui_service_menu || true
        ;;
      2)
        tui_init_wizard || true
        ;;
      3)
        tui_diagnostics || true
        ;;
      4|q|Q)
        cleanup_terminal
        echo -e "${CLR_GREEN}Goodbye!${CLR_RESET}"
        exit 0
        ;;
      *)
        echo -e "${CLR_RED}Invalid option.${CLR_RESET}"
        sleep 1
        ;;
    esac
  done
}

# ========================================================
# CLI Argument Dispatcher
# ========================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Install bin symlink
  if [ "${1:-}" = "--install-bin" ]; then
    BIN_DIR="${HOME}/.local/bin"
    mkdir -p "${BIN_DIR}"
    ln -sf "${SCRIPT_DIR}/init-sandbox.sh" "${BIN_DIR}/agy-sandbox"
    echo "==> [antigravity-sandbox] Installed 'agy-sandbox' CLI command into ${BIN_DIR}/agy-sandbox"
    echo "    Ensure ${BIN_DIR} is in your PATH."
    exit 0
  fi

  # List templates
  if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    list_templates
    exit 0
  fi

  # Run diagnostics
  if [ "${1:-}" = "--diagnose" ] || [ "${1:-}" = "-d" ] || [ "${1:-}" = "diagnose" ]; then
    exec "${SCRIPT_DIR}/diagnose.sh"
  fi

  # Manage service
  if [ "${1:-}" = "--service" ] || [ "${1:-}" = "service" ]; then
    shift
    exec "${SCRIPT_DIR}/service.sh" "$@"
  fi

  # Force interactive TUI
  if [ "${1:-}" = "--interactive" ] || [ "${1:-}" = "-i" ]; then
    run_tui
    exit 0
  fi

  # Help
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
    echo "Usage: agy-sandbox [OPTIONS] [TARGET_DIR] [TEMPLATE]"
    echo ""
    echo "Without arguments in interactive terminal, launches the Antigravity TUI."
    echo ""
    echo "Options:"
    echo "  -i, --interactive        Launch interactive terminal user interface"
    echo "  -l, --list               List available sandbox templates"
    echo "  -d, --diagnose, diagnose Run security audit & boundary diagnostics"
    echo "  --service [COMMAND]      Manage systemd persistence (status|enable|disable|install)"
    echo "  --install-bin            Symlink agy-sandbox into ~/.local/bin"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Positional initialization:"
    echo "  agy-sandbox /path/to/project [template_name]"
    exit 0
  fi

  # If no arguments provided:
  if [ "$#" -eq 0 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      run_tui
      exit 0
    else
      # Non-interactive headless fallback when piped or called in CI without args
      do_init_sandbox "." "default" "no"
      exit 0
    fi
  fi

  # Positional arguments provided: agy-sandbox <target_dir> [template]
  TARGET_DIR="${1}"
  TEMPLATE="${2:-default}"
  do_init_sandbox "${TARGET_DIR}" "${TEMPLATE}" "prompt"
fi
