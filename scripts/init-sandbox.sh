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

CLI_MOUNTS=()

# Antigravity CLI Defaults derived directly from base/devcontainer.json
BASE_DEVCONTAINER="${ROOT_DIR}/base/devcontainer.json"
DEFAULT_AGY_VERSION=""
DEFAULT_AGY_PATCH=""
if [ -f "${BASE_DEVCONTAINER}" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_AGY_VERSION="$(jq -r '.remoteEnv.AGY_VERSION // empty' "${BASE_DEVCONTAINER}" 2>/dev/null || true)"
  DEFAULT_AGY_PATCH="$(jq -r '.remoteEnv.AGY_PATCH // empty' "${BASE_DEVCONTAINER}" 2>/dev/null || true)"
fi

validate_version_format() {
  local ver="$1"
  if [ "$ver" = "latest" ]; then
    return 0
  fi
  if [[ "$ver" =~ ^[vV]?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    return 0
  fi
  return 1
}

# ANSI Colors & Formatting
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_DIM="\033[2m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"

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
  local agy_version="${5:-${AGY_VERSION:-${DEFAULT_AGY_VERSION}}}"
  local agy_patch="${6:-${AGY_PATCH:-${DEFAULT_AGY_PATCH}}}"
  local extra_mounts_json="${7:-[]}"

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

    local base_settings="{}"
    base_settings=$(jq ".customizations.vscode.settings // {}" "${base_json}")

    local tmpl_settings="{}"
    if [ -f "${template_dir}/settings.json" ]; then
      tmpl_settings=$(jq . "${template_dir}/settings.json")
    fi

    # Initialize fail-closed host check command synchronized with sandbox.conf
    local ready_path="${READY_FILE}"
    local init_cmd="bash -c 'ready=\"${ready_path}\"; if [ ! -s \"\$ready\" ]; then echo \"[FAIL-CLOSED] Sandbox network isolation is NOT active! Run: sudo ./scripts/ensure-network.sh\" >&2; exit 1; fi; br=\$(grep \"^ACTIVE_BRIDGE=\" \"\$ready\" 2>/dev/null | cut -d= -f2); [ -z \"\$br\" ] && br=\"${BRIDGE_NAME}\"; if ! ip rule show 2>/dev/null | grep -q \"iif \${br}\"; then echo \"[FAIL-CLOSED] Sandbox network isolation is NOT active! Missing RPDB routing rules for \${br}. Run: sudo ./scripts/ensure-network.sh\" >&2; exit 1; fi'"

    # Enforce security settings with highest precedence over template
    # shellcheck disable=SC2016
    local jq_filter='
      .name = $name
      | .customizations.vscode.extensions = $exts
      | .customizations.vscode.settings = (($base_settings * $tmpl_settings) * {
          "dev.containers.copyGitConfig": false,
          "dev.containers.dockerCredentialHelper": false,
          "git.terminalAuthentication": false,
          "github.gitAuthentication": false,
          "git.autofetch": false
        })
      | .runArgs = [
          "--network=" + $net,
          "--dns=" + $dns1,
          "--dns=" + $dns2,
          "--pids-limit=" + $pids,
          "--memory=" + $mem,
          "--cpus=" + $cpus,
          "--tmpfs=/tmp:rw,nosuid,nodev,size=" + $tmpfs + ",mode=1777"
        ] + (.runArgs | map(select((
            startswith("--network=") or
            startswith("--dns=") or
            startswith("--pids-limit=") or
            startswith("--memory=") or
            startswith("--cpus=") or
            startswith("--tmpfs=/tmp:")
          ) | not)))
      | .mounts = (
          ((.mounts // []) as $m |
           (if ($m | any(startswith("source=agy-shared-config,target=/home/vscode/.gemini-shared"))) then
              $m
            else
              ["source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume"] + $m
            end) as $m1 |
           (if ($m1 | any(startswith("source=agy-shared-cache,target=/home/vscode/.cache"))) then
              $m1
            else
              $m1 + ["source=agy-shared-cache,target=/home/vscode/.cache,type=volume"]
            end) as $m2 |
           (if ($m2 | any(startswith("source=agy-gemini-data-"))) then
              $m2
            else
              $m2 + ["source=agy-gemini-data-${localWorkspaceFolderBasename},target=/home/vscode/.gemini,type=volume"]
            end) as $m3 |
           $m3 + ($extra_mounts | map(. as $x | select(($m3 | index($x)) == null)))
          )
        )
      | .initializeCommand = $init_cmd
      | .build.args.AGY_VERSION = $ver
      | .remoteEnv.AGY_VERSION = $ver
      | .remoteEnv.AGY_PATCH = $patch
      | .remoteEnv.UV_CACHE_DIR = "/home/vscode/.cache/uv"
      | .remoteEnv.AGY_CACHE_DIR = "/home/vscode/.cache/agy-downloads"
      | del(.remoteEnv.AGY_CLI_DISABLE_AUTO_UPDATE)
      | del(.remoteEnv.ANTIGRAVITY_NO_AUTO_UPDATE)
    '

    jq --arg name "\${localWorkspaceFolderBasename} (${display_name} Sandbox)" \
       --arg ver "${agy_version}" \
       --arg patch "${agy_patch}" \
       --arg net "${NETWORK_NAME}" \
       --arg dns1 "${DNS_PRIMARY}" \
       --arg dns2 "${DNS_SECONDARY}" \
       --arg pids "${PIDS_LIMIT}" \
       --arg mem "${MEMORY_LIMIT}" \
       --arg cpus "${CPUS_LIMIT}" \
       --arg tmpfs "${TMPFS_SIZE}" \
       --arg init_cmd "${init_cmd}" \
       --argjson exts "${exts_json}" \
       --argjson base_settings "${base_settings}" \
       --argjson tmpl_settings "${tmpl_settings}" \
       --argjson extra_mounts "${extra_mounts_json}" \
       "${jq_filter}" \
       "${base_json}" > "${output_file}"
  else
    local template_content
    template_content=$(cat "${base_json}")
    template_content="${template_content//@@TEMPLATE_NAME@@/${display_name}}"
    template_content="${template_content//\"AGY_VERSION\": \"1.4.6\"/\"AGY_VERSION\": \"${agy_version}\"}"
    template_content="${template_content//\"AGY_PATCH\": \"true\"/\"AGY_PATCH\": \"${agy_patch}\"}"
    template_content="${template_content//\"--network=agy_net\"/\"--network=${NETWORK_NAME}\"}"
    template_content="${template_content//\"--dns=9.9.9.9\"/\"--dns=${DNS_PRIMARY}\"}"
    template_content="${template_content//\"--dns=149.112.112.112\"/\"--dns=${DNS_SECONDARY}\"}"
    template_content="${template_content//\"--pids-limit=2048\"/\"--pids-limit=${PIDS_LIMIT}\"}"
    template_content="${template_content//\"--memory=8g\"/\"--memory=${MEMORY_LIMIT}\"}"
    template_content="${template_content//\"--cpus=4\"/\"--cpus=${CPUS_LIMIT}\"}"
    template_content="${template_content//\"size=2g\"/\"size=${TMPFS_SIZE}\"}"
    if ! echo "${template_content}" | grep -q "source=agy-shared-config"; then
      template_content=$(echo "${template_content}" | sed 's|"mounts": \[|"mounts": \[\n    "source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume",|')
    fi
    if ! echo "${template_content}" | grep -q "source=agy-shared-cache"; then
      template_content=$(echo "${template_content}" | sed 's|"mounts": \[|"mounts": \[\n    "source=agy-shared-cache,target=/home/vscode/.cache,type=volume",|')
    fi
    if ! echo "${template_content}" | grep -q "source=agy-gemini-data-"; then
      template_content=$(echo "${template_content}" | sed 's|"mounts": \[|"mounts": \[\n    "source=agy-gemini-data-${localWorkspaceFolderBasename},target=/home/vscode/.gemini,type=volume",|')
    fi
    if ! echo "${template_content}" | grep -q "UV_CACHE_DIR"; then
      template_content=$(echo "${template_content}" | sed 's|"remoteEnv": {|"remoteEnv": {\n    "UV_CACHE_DIR": "/home/vscode/.cache/uv",\n    "AGY_CACHE_DIR": "/home/vscode/.cache/agy-downloads",|')
    fi
    echo -e "${template_content}" > "${output_file}"
  fi
}

assemble_declarative_template() {
  local template_path="$1"
  local template_name="$2"
  local dest_dir="$3"
  local agy_version="${4:-${AGY_VERSION:-${DEFAULT_AGY_VERSION}}}"
  local agy_patch="${5:-${AGY_PATCH:-${DEFAULT_AGY_PATCH}}}"
  local extra_mounts_json="${6:-[]}"

  # 1. Setup hook
  cp "${ROOT_DIR}/base/setup.sh" "${dest_dir}/setup.sh"
  if [ -f "${template_path}/extra-setup.sh" ]; then
    echo "" >> "${dest_dir}/setup.sh"
    cat "${template_path}/extra-setup.sh" >> "${dest_dir}/setup.sh"
  fi

  # 2. Dockerfile
  assemble_dockerfile "${ROOT_DIR}/base/Dockerfile" "${template_name}" "${template_path}" "${dest_dir}/Dockerfile"

  # 3. devcontainer.json
  assemble_devcontainer_json "${ROOT_DIR}/base/devcontainer.json" "${template_name}" "${template_path}" "${dest_dir}/devcontainer.json" "${agy_version}" "${agy_patch}" "${extra_mounts_json}"

  # 4. CLI installer
  cp "${ROOT_DIR}/base/install-agy.sh" "${dest_dir}/install-agy.sh"
  chmod +x "${dest_dir}/install-agy.sh"
}

expand_path() {
  local p="$1"
  # Expand tilde: ~ or ~/path
  # shellcheck disable=SC2088
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

validate_and_parse_mount() {
  local spec="$1"
  if [ -z "${spec}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Empty mount specification.${CLR_RESET}" >&2
    return 1
  fi

  local parts=()
  IFS=':' read -r -a parts <<< "${spec}"

  local host_raw=""
  local container_path=""
  local mode="ro"

  if [ ${#parts[@]} -eq 2 ]; then
    host_raw="${parts[0]}"
    container_path="${parts[1]}"
    mode="ro"
    echo -e "${CLR_CYAN}==> [antigravity-sandbox] Notice: Mount mode not specified for '${host_raw}', defaulting to Read-Only (:ro)${CLR_RESET}" >&2
  elif [ ${#parts[@]} -eq 3 ]; then
    host_raw="${parts[0]}"
    container_path="${parts[1]}"
    mode="${parts[2]}"
  else
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Invalid --mount format '${spec}'. Expected '<host_path>:<container_path>[:ro|rw]'.${CLR_RESET}" >&2
    return 1
  fi

  if [ -z "${host_raw}" ] || [ -z "${container_path}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Host or container path in '${spec}' cannot be empty.${CLR_RESET}" >&2
    return 1
  fi

  if [ "${mode}" != "ro" ] && [ "${mode}" != "rw" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Invalid mount mode '${mode}' in '${spec}'. Expected 'ro' or 'rw'.${CLR_RESET}" >&2
    return 1
  fi

  if [[ "${container_path}" != /* ]]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Container mount path '${container_path}' must be an absolute path (starting with /).${CLR_RESET}" >&2
    return 1
  fi

  local host_path
  host_path="$(expand_path "${host_raw}")"
  local canonical_host
  canonical_host="$(realpath -m "${host_path}" 2>/dev/null || echo "${host_path}")"

  # Security Blacklist checks
  # 1. Root filesystem
  if [ "${canonical_host}" = "/" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '/' is blacklisted for security reasons!${CLR_RESET}" >&2
    return 1
  fi

  # 2. System directories and subdirectories
  local sys_dirs=("/etc" "/usr" "/var" "/bin" "/sbin" "/lib" "/lib64" "/proc" "/sys" "/dev" "/run" "/root")
  for s_dir in "${sys_dirs[@]}"; do
    if [ "${canonical_host}" = "${s_dir}" ] || [[ "${canonical_host}" == "${s_dir}/"* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' (resolves to '${canonical_host}') is in system directory '${s_dir}' and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi
  done

  # Docker sockets
  if [ "${canonical_host}" = "/var/run/docker.sock" ] || [ "${canonical_host}" = "/run/docker.sock" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' is a Docker socket and is blacklisted for security reasons!${CLR_RESET}" >&2
    return 1
  fi

  # 3. User Home Directory entirely
  local canonical_home
  canonical_home="$(realpath -m "${HOME}" 2>/dev/null || echo "${HOME}")"
  if [ "${canonical_host}" = "${canonical_home}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' is the entire user HOME directory and is blacklisted for security reasons!${CLR_RESET}" >&2
    return 1
  fi

  # 4. Sensitive directories under user HOME
  local sens_dirs=(".ssh" ".gnupg" ".aws" ".kube" ".config" ".docker" ".local")
  for s_sub in "${sens_dirs[@]}"; do
    local s_path="${canonical_home}/${s_sub}"
    if [ "${canonical_host}" = "${s_path}" ] || [[ "${canonical_host}" == "${s_path}/"* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' contains sensitive directory '${s_sub}' and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi
  done

  if [ ! -e "${host_path}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Host mount path '${host_raw}' does not exist.${CLR_RESET}" >&2
    return 1
  fi
  canonical_host="$(realpath "${host_path}")"

  local mount_str
  if [ "${mode}" = "ro" ]; then
    mount_str="source=${canonical_host},target=${container_path},type=bind,readonly"
  else
    mount_str="source=${canonical_host},target=${container_path},type=bind"
  fi

  echo "${mount_str}"
  return 0
}

do_init_sandbox() {
  local target_dir="${1:-.}"
  local template="${2:-default}"
  local auto_gitignore="${3:-prompt}" # prompt, yes, no
  local agy_version="${4:-${AGY_VERSION:-${DEFAULT_AGY_VERSION}}}"
  local agy_patch="${5:-${AGY_PATCH:-${DEFAULT_AGY_PATCH}}}"
  local use_worktree="${6:-${CLI_WORKTREE:-false}}"
  local worktree_branch="${7:-${CLI_WORKTREE_BRANCH:-agy-sandbox}}"

  # Expand tilde and relative paths to canonical absolute path
  target_dir="$(expand_path "${target_dir}")"

  local extra_mounts=()

  # 1. Process custom mounts from CLI_MOUNTS
  if [ ${#CLI_MOUNTS[@]} -gt 0 ]; then
    for m_spec in "${CLI_MOUNTS[@]}"; do
      local m_entry=""
      if ! m_entry="$(validate_and_parse_mount "${m_spec}")"; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Mount validation failed for '${m_spec}'. Aborting.${CLR_RESET}" >&2
        return 1
      fi
      extra_mounts+=("${m_entry}")
    done
  fi

  # 2. Process Git worktree isolation if requested (FEAT-01)
  local is_worktree=false
  local worktree_dir=""
  if [ "${use_worktree}" = "true" ]; then
    if [ ! -d "${target_dir}" ]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Target directory '${target_dir}' does not exist.${CLR_RESET}" >&2
      return 1
    fi

    if ! git -C "${target_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Target directory '${target_dir}' is not a git repository. Cannot create git worktree.${CLR_RESET}" >&2
      return 1
    fi

    local main_repo_dir
    main_repo_dir="$(git -C "${target_dir}" rev-parse --show-toplevel)"
    local main_git_dir
    main_git_dir="$(git -C "${target_dir}" rev-parse --git-common-dir)"
    if [[ "${main_git_dir}" != /* ]]; then
      main_git_dir="$(cd "${main_repo_dir}/${main_git_dir}" && pwd)"
    else
      main_git_dir="$(cd "${main_git_dir}" && pwd)"
    fi

    worktree_dir="${main_repo_dir}-sandbox"
    if [ -d "${worktree_dir}" ]; then
      if [ -f "${worktree_dir}/.git" ]; then
        echo "==> [antigravity-sandbox] Existing git worktree found at '${worktree_dir}'. Reusing worktree..."
      else
        echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Directory '${worktree_dir}' exists but is not a valid git worktree.${CLR_RESET}" >&2
        return 1
      fi
    else
      echo "==> [antigravity-sandbox] Creating git worktree in '${worktree_dir}' on branch '${worktree_branch}'..."
      if ! git -C "${main_repo_dir}" worktree add -B "${worktree_branch}" "${worktree_dir}"; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Failed to create git worktree in '${worktree_dir}'.${CLR_RESET}" >&2
        return 1
      fi
    fi

    mkdir -p "${main_git_dir}/hooks" "${main_git_dir}/info"
    [ -f "${main_git_dir}/config" ] || touch "${main_git_dir}/config"

    # Exclude .devcontainer/ in the main repository info/exclude
    local exclude_file="${main_git_dir}/info/exclude"
    if [ ! -f "${exclude_file}" ] || ! grep -q "^\.devcontainer" "${exclude_file}"; then
      echo -e "\n# Antigravity Sandbox Dev Container\n.devcontainer/" >> "${exclude_file}"
      echo "==> [antigravity-sandbox] Added .devcontainer/ to ${exclude_file}"
    fi

    # Add 4 VFS Read-Only Git metadata protection mounts
    extra_mounts+=(
      "source=${main_git_dir},target=${main_git_dir},type=bind"
      "source=${main_git_dir}/hooks,target=${main_git_dir}/hooks,type=bind,readonly"
      "source=${main_git_dir}/config,target=${main_git_dir}/config,type=bind,readonly"
      "source=${main_git_dir}/info,target=${main_git_dir}/info,type=bind,readonly"
    )

    # Redirect target directory to worktree directory
    target_dir="${worktree_dir}"
    auto_gitignore="no"
    is_worktree=true
  fi

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
  echo "==> [antigravity-sandbox] Target Antigravity CLI version: '${agy_version}'"
  echo "==> [antigravity-sandbox] Apply Antigravity CLI patch: '${agy_patch}'"

  mkdir -p "${dest_devcontainer}"

  local extra_mounts_json="[]"
  if [ ${#extra_mounts[@]} -gt 0 ] && command -v jq >/dev/null 2>&1; then
    extra_mounts_json="$(printf '%s\n' "${extra_mounts[@]}" | jq -R . | jq -s .)"
  fi

  # Dispatch: Full Custom Mode vs Declarative Mode
  if [ -f "${template_path}/devcontainer.json" ] || [ -f "${template_path}/Dockerfile" ]; then
    echo "==> [antigravity-sandbox] Deploying Full Custom template..."
    cp -r "${template_path}/"* "${dest_devcontainer}/"
    if [ ! -f "${dest_devcontainer}/setup.sh" ]; then
      cp "${ROOT_DIR}/base/setup.sh" "${dest_devcontainer}/setup.sh"
    fi
    if [ ! -f "${dest_devcontainer}/install-agy.sh" ]; then
      cp "${ROOT_DIR}/base/install-agy.sh" "${dest_devcontainer}/install-agy.sh"
      chmod +x "${dest_devcontainer}/install-agy.sh"
    fi
    if [ -f "${dest_devcontainer}/devcontainer.json" ] && command -v jq >/dev/null 2>&1; then
      local tmp_dc
      tmp_dc="$(mktemp)"
      local custom_filter='
        .runArgs = [
          "--network=" + $net,
          "--dns=" + $dns1,
          "--dns=" + $dns2,
          "--pids-limit=" + $pids,
          "--memory=" + $mem,
          "--cpus=" + $cpus,
          "--tmpfs=/tmp:rw,nosuid,nodev,size=" + $tmpfs + ",mode=1777"
        ] + ((.runArgs // []) | map(select((
            startswith("--network=") or
            startswith("--dns=") or
            startswith("--pids-limit=") or
            startswith("--memory=") or
            startswith("--cpus=") or
            startswith("--tmpfs=/tmp:")
          ) | not)))
        | .mounts = (
          ((.mounts // []) as $m |
           (if ($m | any(startswith("source=agy-shared-config,target=/home/vscode/.gemini-shared"))) then
              $m
            else
              ["source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume"] + $m
            end) as $m1 |
           (if ($m1 | any(startswith("source=agy-shared-cache,target=/home/vscode/.cache"))) then
              $m1
            else
              $m1 + ["source=agy-shared-cache,target=/home/vscode/.cache,type=volume"]
            end) as $m2 |
           (if ($m2 | any(startswith("source=agy-gemini-data-"))) then
              $m2
            else
              $m2 + ["source=agy-gemini-data-${localWorkspaceFolderBasename},target=/home/vscode/.gemini,type=volume"]
            end) as $m3 |
           $m3 + ($extra_mounts | map(. as $x | select(($m3 | index($x)) == null)))
          )
        )
        | .remoteEnv.UV_CACHE_DIR = "/home/vscode/.cache/uv"
        | .remoteEnv.AGY_CACHE_DIR = "/home/vscode/.cache/agy-downloads"
      '
      jq --arg net "${NETWORK_NAME}" \
         --arg dns1 "${DNS_PRIMARY}" \
         --arg dns2 "${DNS_SECONDARY}" \
         --arg pids "${PIDS_LIMIT}" \
         --arg mem "${MEMORY_LIMIT}" \
         --arg cpus "${CPUS_LIMIT}" \
         --arg tmpfs "${TMPFS_SIZE}" \
         --argjson extra_mounts "${extra_mounts_json}" \
         "${custom_filter}" \
         "${dest_devcontainer}/devcontainer.json" > "${tmp_dc}"
      mv "${tmp_dc}" "${dest_devcontainer}/devcontainer.json"
    elif [ -f "${dest_devcontainer}/devcontainer.json" ]; then
      if ! grep -q "source=agy-shared-config" "${dest_devcontainer}/devcontainer.json"; then
        sed -i 's|"mounts": \[|"mounts": \[\n    "source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume",|' "${dest_devcontainer}/devcontainer.json" 2>/dev/null || true
      fi
      if ! grep -q "source=agy-shared-cache" "${dest_devcontainer}/devcontainer.json"; then
        sed -i 's|"mounts": \[|"mounts": \[\n    "source=agy-shared-cache,target=/home/vscode/.cache,type=volume",|' "${dest_devcontainer}/devcontainer.json" 2>/dev/null || true
      fi
      if ! grep -q "source=agy-gemini-data-" "${dest_devcontainer}/devcontainer.json"; then
        sed -i 's|"mounts": \[|"mounts": \[\n    "source=agy-gemini-data-${localWorkspaceFolderBasename},target=/home/vscode/.gemini,type=volume",|' "${dest_devcontainer}/devcontainer.json" 2>/dev/null || true
      fi
      if ! grep -q "UV_CACHE_DIR" "${dest_devcontainer}/devcontainer.json"; then
        sed -i 's|"remoteEnv": {|"remoteEnv": {\n    "UV_CACHE_DIR": "/home/vscode/.cache/uv",\n    "AGY_CACHE_DIR": "/home/vscode/.cache/agy-downloads",|' "${dest_devcontainer}/devcontainer.json" 2>/dev/null || true
      fi
    fi
  else
    echo "==> [antigravity-sandbox] Assembling declarative template from base..."
    assemble_declarative_template "${template_path}" "${template}" "${dest_devcontainer}" "${agy_version}" "${agy_patch}" "${extra_mounts_json}"
  fi

  if [ -f "${dest_devcontainer}/setup.sh" ]; then
    chmod +x "${dest_devcontainer}/setup.sh"
  fi
  if [ -f "${dest_devcontainer}/install-agy.sh" ]; then
    chmod +x "${dest_devcontainer}/install-agy.sh"
  fi

  # Ensure isolated docker network and dynamic kernel routing exist on host (Fail-Closed)
  if command -v docker >/dev/null 2>&1; then
    echo "==> [antigravity-sandbox] Ensuring isolated network boundaries (Fail-Closed)..."
    local ready_chk="${READY_FILE}"
    if ! "${SCRIPT_DIR}/ensure-network.sh" || [ ! -f "${ready_chk}" ]; then
      echo -e "\n${CLR_RED}==> [antigravity-sandbox] FATAL: Network isolation failed or ${ready_chk} is missing!${CLR_RESET}" >&2
      echo -e "${CLR_RED}==> [antigravity-sandbox] Aborting initialization in Fail-Closed mode to prevent unisolated execution.${CLR_RESET}" >&2
      exit 1
    fi
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
  if [ "${is_worktree}" = "true" ]; then
    echo "Mode: Isolated Git Worktree on branch '${worktree_branch}'"
    echo "Host git hooks and config protected as Read-Only via VFS bind mounts."
  fi
  echo "Next steps:"
  echo " 1. Open the project in VS Code / Cursor: code ${target_dir}"
  echo " 2. Press F1 -> 'Dev Containers: Reopen in Container'"
  echo " 3. Antigravity Agent will run safely inside the isolated container"
  if [ "${is_worktree}" = "true" ]; then
    echo " Note: All modifications are isolated in the git worktree and '${worktree_branch}' branch."
  fi
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
  read -r -p "Press [Enter] to return to the menu..." || rc=$?
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
    local net_name="${NETWORK_NAME}"
    local active_subnet="UNKNOWN"
    local active_br="${BRIDGE_NAME}"
    local ready_marker="${READY_FILE}"

    if [ -f "${ready_marker}" ]; then
      while IFS='=' read -r key val || [ -n "$key" ]; do
        case "$key" in
          NETWORK_NAME) [ -n "$val" ] && net_name="$val" ;;
          ACTIVE_BRIDGE) [ -n "$val" ] && active_br="$val" ;;
          ACTIVE_SUBNET) [ -n "$val" ] && active_subnet="$val" ;;
        esac
      done < "${ready_marker}"
    fi

    if command -v docker >/dev/null 2>&1 && docker network inspect "${net_name}" >/dev/null 2>&1; then
      local sub_opt
      sub_opt=$(docker network inspect "${net_name}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")
      if [ -n "${sub_opt}" ] && [ "${sub_opt}" != "<no value>" ]; then active_subnet="${sub_opt}"; fi
      local br_opt
      br_opt=$(docker network inspect "${net_name}" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
      if [ -n "${br_opt}" ] && [ "${br_opt}" != "<no value>" ]; then
        active_br="${br_opt}"
      else
        local nid
        nid=$(docker network inspect "${net_name}" --format '{{.Id}}' 2>/dev/null || echo "")
        if [ -n "${nid}" ]; then active_br="br-${nid:0:12}"; fi
      fi
      if [ -f "${ready_marker}" ]; then
        net_status="${CLR_GREEN}ACTIVE (Ready: ${active_subnet})${CLR_RESET}"
      else
        net_status="${CLR_YELLOW}ACTIVE (${active_subnet})${CLR_RESET}"
      fi
    else
      net_status="${CLR_RED}NOT RUNNING${CLR_RESET}"
    fi

    local host_bound="INACTIVE"
    local sudo_cmd=""
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then sudo_cmd="sudo"; fi

    if command -v iptables >/dev/null 2>&1 && (${sudo_cmd} iptables -C INPUT -i "${active_br}" -j AGY-SANDBOX-IN >/dev/null 2>&1 || ${sudo_cmd} iptables -C INPUT -i "${active_br}" -j DROP >/dev/null 2>&1 || ${sudo_cmd} iptables -C INPUT -i agy0 -j DROP >/dev/null 2>&1); then
      host_bound="${CLR_GREEN}ACTIVE (CHAIN AGY-SANDBOX-IN)${CLR_RESET}"
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

    echo -e "  Docker Network (${net_name}):    ${net_status}"
    echo -e "  Host Boundary (AGY-SANDBOX-IN): ${host_bound}"
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
        local ready_chk="${READY_FILE}"
        if ! "${SCRIPT_DIR}/ensure-network.sh" || [ ! -f "${ready_chk}" ]; then
          echo -e "\n${CLR_RED}==> [antigravity-sandbox] Network isolation failed or ${ready_chk} missing!${CLR_RESET}"
        else
          echo -e "\n${CLR_GREEN}==> [antigravity-sandbox] Network isolation successfully verified.${CLR_RESET}"
        fi
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
    read -er -p "Target project directory: " target_input || rc=$?
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

  echo ""
  echo -e "${CLR_BOLD}Antigravity CLI Version Selection:${CLR_RESET}"
  echo -e "  ${CLR_BOLD}[1]${CLR_RESET} ${CLR_CYAN}default (${DEFAULT_AGY_VERSION})${CLR_RESET} - Pinned stable release (Recommended)"
  echo -e "  ${CLR_BOLD}[2]${CLR_RESET} ${CLR_CYAN}latest${CLR_RESET}          - Always install latest upstream release"
  echo -e "  ${CLR_BOLD}[3]${CLR_RESET} ${CLR_CYAN}custom${CLR_RESET}          - Specify custom version tag (e.g. 1.4.5, v1.4.7)"
  echo ""

  local selected_version="${DEFAULT_AGY_VERSION}"
  while true; do
    local rc=0
    local v_choice="1"
    read -r -p "Select version option [1-3, default: 1]: " v_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi
    v_choice="${v_choice:-1}"
    case "${v_choice}" in
      1)
        selected_version="${DEFAULT_AGY_VERSION}"
        break
        ;;
      2)
        selected_version="latest"
        break
        ;;
      3)
        while true; do
          local rc_custom=0
          local custom_tag=""
          read -r -p "Enter version tag (e.g. 1.4.5, v1.4.7) or 'cancel': " custom_tag || rc_custom=$?
          if [ "$rc_custom" -gt 128 ] || [ "${custom_tag}" = "cancel" ] || [ "${custom_tag}" = "q" ]; then
            break
          fi
          custom_tag="$(echo "${custom_tag}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
          if [ -z "${custom_tag}" ]; then
            continue
          fi
          if validate_version_format "${custom_tag}"; then
            selected_version="${custom_tag}"
            break 2
          else
            echo -e "${CLR_RED}Invalid version format '${custom_tag}'. Expected e.g. '1.4.5' or 'v1.4.7'.${CLR_RESET}"
          fi
        done
        ;;
      *)
        echo -e "${CLR_RED}Please choose 1, 2, or 3.${CLR_RESET}"
        ;;
    esac
  done

  echo ""
  echo -e "${CLR_BOLD}Antigravity CLI Binary Patching (QNIX-Dev patcher):${CLR_RESET}"
  echo -e "  ${CLR_BOLD}[1]${CLR_RESET} ${CLR_CYAN}Yes${CLR_RESET} - Apply patch (Default / Recommended)"
  echo -e "  ${CLR_BOLD}[2]${CLR_RESET} ${CLR_CYAN}No${CLR_RESET}  - Keep clean official binary without modifications"
  echo ""

  local selected_patch="true"
  while true; do
    local rc=0
    local p_choice="1"
    read -r -p "Apply patch? [1-2, default: 1]: " p_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi
    p_choice="${p_choice:-1}"
    case "${p_choice}" in
      1|[Yy]|[Yy][Ee][Ss])
        selected_patch="true"
        break
        ;;
      2|[Nn]|[Nn][Oo])
        selected_patch="false"
        break
        ;;
      *)
        echo -e "${CLR_RED}Please choose 1 (Yes) or 2 (No).${CLR_RESET}"
        ;;
    esac
  done

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
  do_init_sandbox "${target_dir}" "${selected_template}" "${add_git}" "${selected_version}" "${selected_patch}" "false" "agy-sandbox"
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
  CLI_VERSION="${AGY_VERSION:-${DEFAULT_AGY_VERSION}}"
  CLI_PATCH="${AGY_PATCH:-${DEFAULT_AGY_PATCH}}"
  CLI_WORKTREE=false
  CLI_WORKTREE_BRANCH="agy-sandbox"
  CLI_MOUNTS=()
  TARGET_DIR=""
  TEMPLATE=""
  FORCE_INTERACTIVE=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install-bin)
        BIN_DIR="${HOME}/.local/bin"
        mkdir -p "${BIN_DIR}"
        ln -sf "${SCRIPT_DIR}/init-sandbox.sh" "${BIN_DIR}/agy-sandbox"
        echo "==> [antigravity-sandbox] Installed 'agy-sandbox' CLI command into ${BIN_DIR}/agy-sandbox"
        echo "    Ensure ${BIN_DIR} is in your PATH."
        exit 0
        ;;
      --list|-l)
        list_templates
        exit 0
        ;;
      --diagnose|-d|diagnose)
        exec "${SCRIPT_DIR}/diagnose.sh"
        ;;
      --service|service)
        shift
        exec "${SCRIPT_DIR}/service.sh" "$@"
        ;;
      --interactive|-i)
        FORCE_INTERACTIVE=true
        shift
        ;;
      -w|--worktree)
        CLI_WORKTREE=true
        shift
        ;;
      --worktree-branch=*)
        CLI_WORKTREE_BRANCH="${1#*=}"
        CLI_WORKTREE=true
        shift
        ;;
      --worktree-branch)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing branch name for --worktree-branch${CLR_RESET}" >&2
          exit 1
        fi
        CLI_WORKTREE_BRANCH="$2"
        CLI_WORKTREE=true
        shift 2
        ;;
      --mount=*)
        CLI_MOUNTS+=("${1#*=}")
        shift
        ;;
      --mount)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing specification for --mount${CLR_RESET}" >&2
          exit 1
        fi
        CLI_MOUNTS+=("$2")
        shift 2
        ;;
      -v|--agy-version|--version)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing version argument for $1${CLR_RESET}" >&2
          exit 1
        fi
        if ! validate_version_format "$2"; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Invalid version format '$2'. Expected 'latest' or SemVer tag (e.g. '1.4.6' or 'v1.4.6').${CLR_RESET}" >&2
          exit 1
        fi
        CLI_VERSION="$2"
        shift 2
        ;;
      --patch)
        CLI_PATCH="true"
        shift
        ;;
      --no-patch|--skip-patch)
        CLI_PATCH="false"
        shift
        ;;
      -h|--help|help)
        echo "Usage: agy-sandbox [OPTIONS] [TARGET_DIR] [TEMPLATE]"
        echo ""
        echo "Without arguments in interactive terminal, launches the Antigravity TUI."
        echo ""
        echo "Options:"
        echo "  -i, --interactive              Launch interactive terminal user interface"
        echo "  -w, --worktree                 Create and run sandbox inside an isolated Git worktree"
        echo "  --worktree-branch <name>       Git branch for worktree (default: 'agy-sandbox', implies --worktree)"
        echo "  --mount <host:container[:ro|rw]> Bind mount host path into container (default mode: ro)"
        echo "  -v, --agy-version <tag>        Pin specific Antigravity CLI version (e.g. '1.4.6', 'latest')"
        echo "  --patch                        Apply QNIX-Dev eligibility patch to CLI binary (default)"
        echo "  --no-patch, --skip-patch       Disable patch, keep clean official binary"
        echo "  -l, --list                     List available sandbox templates"
        echo "  -d, --diagnose, diagnose       Run security audit & boundary diagnostics"
        echo "  --service [COMMAND]            Manage systemd persistence (status|enable|disable|install)"
        echo "  --install-bin                  Symlink agy-sandbox into ~/.local/bin"
        echo "  -h, --help                     Show this help message"
        echo ""
        echo "Examples:"
        echo "  agy-sandbox /path/to/project node"
        echo "  agy-sandbox --worktree /path/to/project python"
        echo "  agy-sandbox --worktree --worktree-branch experiment-1 /path/to/project"
        echo "  agy-sandbox --mount /var/data/shared:/data:ro /path/to/project"
        exit 0
        ;;
      *)
        if [ -z "$TARGET_DIR" ]; then
          TARGET_DIR="$1"
        elif [ -z "$TEMPLATE" ]; then
          TEMPLATE="$1"
        else
          echo -e "${CLR_RED}==> [antigravity-sandbox] Unknown argument: $1${CLR_RESET}" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [ "$FORCE_INTERACTIVE" = true ]; then
    run_tui
    exit 0
  fi

  # If no arguments provided:
  if [ -z "$TARGET_DIR" ]; then
    if [ "$CLI_WORKTREE" = true ] || [ ${#CLI_MOUNTS[@]} -gt 0 ]; then
      do_init_sandbox "." "default" "prompt" "${CLI_VERSION}" "${CLI_PATCH}" "${CLI_WORKTREE}" "${CLI_WORKTREE_BRANCH}"
      exit 0
    fi
    if [ -t 0 ] && [ -t 1 ]; then
      run_tui
      exit 0
    else
      # Non-interactive headless fallback when piped or called in CI without args
      do_init_sandbox "." "default" "no" "${CLI_VERSION}" "${CLI_PATCH}" "${CLI_WORKTREE}" "${CLI_WORKTREE_BRANCH}"
      exit 0
    fi
  fi

  # Positional arguments provided: agy-sandbox <target_dir> [template]
  TEMPLATE="${TEMPLATE:-default}"
  do_init_sandbox "${TARGET_DIR}" "${TEMPLATE}" "prompt" "${CLI_VERSION}" "${CLI_PATCH}" "${CLI_WORKTREE}" "${CLI_WORKTREE_BRANCH}"
fi
