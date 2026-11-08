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

# Fail-Closed check: jq is strictly required for secure JSON manipulation and policy enforcement
if ! command -v jq >/dev/null 2>&1; then
  echo -e "\n\033[1;31m==> [antigravity-sandbox] FATAL: 'jq' command is required for secure sandbox generation.\033[0m" >&2
  echo -e "\033[1;31m==> [antigravity-sandbox] Fail-Closed: Aborting to prevent generation of unconstrained sandbox environments.\033[0m" >&2
  echo "    Please install jq via your package manager (e.g. 'sudo apt-get install -y jq' or 'brew install jq')." >&2
  exit 1
fi

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
_ENV_PATCHER_REPO="${PATCHER_REPO:-}"
_ENV_PATCHER_COMMIT="${PATCHER_COMMIT:-}"
_ENV_SHARED_CONFIG="${SHARED_CONFIG:-}"
_ENV_SHARED_CACHE="${SHARED_CACHE:-}"

# Sourcing sandbox.conf as Single Source of Truth (SSOT)
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
[ -n "${_ENV_PATCHER_REPO}" ] && PATCHER_REPO="${_ENV_PATCHER_REPO}"
[ -n "${_ENV_PATCHER_COMMIT}" ] && PATCHER_COMMIT="${_ENV_PATCHER_COMMIT}"
[ -n "${_ENV_SHARED_CONFIG}" ] && SHARED_CONFIG="${_ENV_SHARED_CONFIG}"
[ -n "${_ENV_SHARED_CACHE}" ] && SHARED_CACHE="${_ENV_SHARED_CACHE}"

DEFAULT_SHARED_CONFIG="${SHARED_CONFIG:-readonly}"
DEFAULT_SHARED_CACHE="${SHARED_CACHE:-false}"

CLI_MOUNTS=()

# Antigravity CLI Defaults (Single Source of Truth: scripts/sandbox.conf with base/devcontainer.json fallback)
BASE_DEVCONTAINER="${ROOT_DIR}/base/devcontainer.json"

# 1. Target release version from sandbox.conf, fallback to base/devcontainer.json
CONFIG_AGY_VERSION="${AGY_VERSION:-}"
if [ -z "${CONFIG_AGY_VERSION}" ] && [ -f "${BASE_DEVCONTAINER}" ] && command -v jq >/dev/null 2>&1; then
  CONFIG_AGY_VERSION="$(jq -r '.remoteEnv.AGY_VERSION // empty' "${BASE_DEVCONTAINER}" 2>/dev/null || true)"
fi
CONFIG_AGY_VERSION="${CONFIG_AGY_VERSION:-1.5.3}"
PINNED_STABLE_VERSION="${CONFIG_AGY_VERSION}"

# 2. Patch toggle from sandbox.conf, fallback to base/devcontainer.json
DEFAULT_AGY_PATCH="${AGY_PATCH:-}"
if [ -z "${DEFAULT_AGY_PATCH}" ] && [ -f "${BASE_DEVCONTAINER}" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_AGY_PATCH="$(jq -r '.remoteEnv.AGY_PATCH // empty' "${BASE_DEVCONTAINER}" 2>/dev/null || true)"
fi
DEFAULT_AGY_PATCH="${DEFAULT_AGY_PATCH:-true}"

# 3. Pinning behavior from sandbox.conf:
# By default, version pinning is enabled for security (PINNED_STABLE_VERSION=1.5.3 with SHA256 verification),
# even when --no-patch is chosen (clean official binary).
DEFAULT_AGY_PINNED="${AGY_PINNED:-true}"

# 4. Resolve default version based on pinning:
# If pinned, default version is PINNED_STABLE_VERSION (e.g. 1.5.3).
# If unpinned, default version is "latest".
if [ "${DEFAULT_AGY_PINNED}" = "true" ] || [ "${DEFAULT_AGY_PINNED}" = "1" ] || [ "${DEFAULT_AGY_PINNED}" = "yes" ]; then
  DEFAULT_AGY_VERSION="${PINNED_STABLE_VERSION}"
else
  DEFAULT_AGY_VERSION="latest"
fi

# 5. Patcher Repository and Commit SHA from sandbox.conf, fallback to base/Dockerfile
DEFAULT_PATCHER_REPO="${PATCHER_REPO:-https://github.com/QNIX-Dev/eligibility-antigravity-patcher.git}"
DEFAULT_PATCHER_COMMIT="${PATCHER_COMMIT:-90498f50353d414232f593dffe88899bc80b6312}"

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
  local patcher_commit="${5:-${DEFAULT_PATCHER_COMMIT}}"
  local patcher_repo="${6:-${DEFAULT_PATCHER_REPO}}"

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
    if [[ "$line" =~ ^ARG\ PATCHER_COMMIT= ]] && [ -n "${patcher_commit}" ]; then
      echo "ARG PATCHER_COMMIT=\"${patcher_commit}\"" >> "${output_file}"
      continue
    fi
    if [[ "$line" =~ ^ARG\ PATCHER_REPO= ]] && [ -n "${patcher_repo}" ]; then
      echo "ARG PATCHER_REPO=\"${patcher_repo}\"" >> "${output_file}"
      continue
    fi

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
  local patcher_commit="${8:-${CLI_PATCHER_COMMIT:-${DEFAULT_PATCHER_COMMIT}}}"
  local target_dir="${9:-}"
  local shared_config="${10:-${DEFAULT_SHARED_CONFIG}}"
  local shared_cache="${11:-${DEFAULT_SHARED_CACHE}}"

  local display_name="${template_name}"
  if [ "${template_name}" = "default" ]; then
    display_name="Agy"
  fi

  local path_hash="default"
  local folder_basename="project"
  if [ -n "${target_dir}" ]; then
    path_hash=$(echo -n "${target_dir}" | sha256sum | cut -c1-8)
    folder_basename="$(basename "${target_dir}")"
  fi
  local project_volume="agy-gemini-data-${folder_basename}-${path_hash}"

  local cache_volume="agy-cache-${folder_basename}-${path_hash}"
  if [ "${shared_cache}" = "true" ] || [ "${shared_cache}" = "1" ] || [ "${shared_cache}" = "yes" ]; then
    cache_volume="agy-shared-cache"
  fi

  local shared_config_mount=""
  if [ "${shared_config}" = "readonly" ] || [ "${shared_config}" = "ro" ]; then
    shared_config_mount="source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume,readonly"
  elif [ "${shared_config}" = "rw" ] || [ "${shared_config}" = "true" ]; then
    shared_config_mount="source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume"
  elif [ "${shared_config}" = "isolated" ] || [ "${shared_config}" = "none" ] || [ "${shared_config}" = "false" ]; then
    shared_config_mount=""
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
  local init_cmd="bash -c 'ready=\"${ready_path}\"; if [ ! -s \"\$ready\" ]; then echo \"[FAIL-CLOSED] Sandbox network isolation is NOT active! Run: sudo ./scripts/ensure-network.sh\" >&2; exit 1; fi; br=\$(grep \"^ACTIVE_BRIDGE=\" \"\$ready\" 2>/dev/null | cut -d= -f2); [ -z \"\$br\" ] && br=\"${BRIDGE_NAME}\"; rules_cnt=\$(ip rule show 2>/dev/null | grep -v \"\\[detached\\]\" | grep \"iif \${br}\" | grep -c \"unreachable\"); if [ \"\$rules_cnt\" -lt 12 ]; then echo \"[FAIL-CLOSED] Sandbox network isolation is NOT active! Incomplete RPDB routing rules for \${br} (\$rules_cnt/12+). Run: sudo ./scripts/ensure-network.sh\" >&2; exit 1; fi'"

  # Enforce security settings with highest precedence over template
  local clean_forwarding_cmd="rm -f /tmp/vscode-git-*.sock /tmp/vscode-ssh-auth-*.sock /tmp/user/*/vscode-git-*.sock /tmp/user/*/vscode-ssh-auth-*.sock /tmp/vscode-wayland-*.sock /tmp/user/*/vscode-wayland-*.sock /tmp/user/*/wayland-* 2>/dev/null || true; rm -rf /home/vscode/.gnupg/S.gpg-agent* /tmp/vscode-gpg-agent* /tmp/user/*/vscode-gpg-agent* 2>/dev/null || true; rm -f /home/vscode/.docker/config.json 2>/dev/null || true; if [ -f /home/vscode/.gitconfig ]; then _n=\"\$(git config --file /home/vscode/.gitconfig user.name 2>/dev/null || true)\"; _e=\"\$(git config --file /home/vscode/.gitconfig user.email 2>/dev/null || true)\"; _b=\"\$(git config --file /home/vscode/.gitconfig init.defaultBranch 2>/dev/null || true)\"; rm -f /home/vscode/.gitconfig; [ -n \"\$_n\" ] && git config --file /home/vscode/.gitconfig user.name \"\$_n\" 2>/dev/null || true; [ -n \"\$_e\" ] && git config --file /home/vscode/.gitconfig user.email \"\$_e\" 2>/dev/null || true; [ -n \"\$_b\" ] && git config --file /home/vscode/.gitconfig init.defaultBranch \"\$_b\" 2>/dev/null || true; fi"

  # shellcheck disable=SC2016
  local jq_filter='
    del(.privileged)
    | del(.capAdd)
    | del(.capDrop)
    | .name = $name
    | .customizations.vscode.extensions = $exts
    | .customizations.vscode.settings = (($base_settings * $tmpl_settings) * {
        "dev.containers.copyGitConfig": false,
        "dev.containers.dockerCredentialHelper": false,
        "dev.containers.mountWaylandSocket": false,
        "dev.containers.forwardGpg": false,
        "git.terminalAuthentication": false,
        "github.gitAuthentication": false,
        "git.autofetch": false,
        "remote.autoForwardPorts": false,
        "remote.restoreForwardedPorts": false
      })
    | .runArgs = [
        "--network=" + $net,
        "--dns=" + $dns1,
        "--dns=" + $dns2,
        "--security-opt=no-new-privileges:true",
        "--sysctl=net.ipv6.conf.all.disable_ipv6=1",
        "--sysctl=net.ipv6.conf.default.disable_ipv6=1",
        "--pids-limit=" + $pids,
        "--memory=" + $mem,
        "--cpus=" + $cpus,
        "--tmpfs=/tmp:rw,nosuid,nodev,size=" + $tmpfs + ",mode=1777",
        "--init"
      ] + ((.runArgs // []) | map(select((
          startswith("--network=") or
          startswith("--dns=") or
          startswith("--pids-limit=") or
          startswith("--memory=") or
          startswith("--cpus=") or
          startswith("--tmpfs=/tmp:") or
          startswith("--security-opt=no-new-privileges") or
          startswith("--sysctl=net.ipv6.conf") or
          startswith("--privileged") or
          startswith("--cap-add") or
          (. == "--init")
        ) | not)))
    | .runArgs = (
        if (.runArgs | any(test("^--cap-drop=(CAP_)?NET_RAW$"))) then
          .runArgs
        else
          .runArgs + ["--cap-drop=NET_RAW"]
        end
      )
    | .mounts = (
        ((.mounts // []) | map(select(
          (startswith("source=agy-shared-config") or
           startswith("source=agy-shared-cache") or
           startswith("source=agy-cache-") or
           startswith("source=agy-gemini-data-") or
           test("(target|destination)=([^,]+/)?\\.devcontainer")) | not
        ))) as $filtered |
        [
          "source=${localWorkspaceFolder}/.devcontainer,target=${containerWorkspaceFolder}/.devcontainer,type=bind,readonly"
        ] +
        (if ($shared_cfg != "") then [$shared_cfg] else [] end) +
        $filtered +
        [
          ("source=" + $cache_vol + ",target=/home/vscode/.cache,type=volume"),
          ("source=" + $proj_vol + ",target=/home/vscode/.gemini,type=volume")
        ] as $base_m |
        $base_m + ($extra_mounts | map(. as $x | select(($base_m | index($x)) == null)))
      )
    | .initializeCommand = $init_cmd
    | .build.args.AGY_VERSION = $ver
    | .build.args.PATCHER_COMMIT = $patcher_commit
    | .remoteEnv.AGY_VERSION = $ver
    | .remoteEnv.AGY_PATCH = $patch
    | .remoteEnv.UV_CACHE_DIR = "/home/vscode/.cache/uv"
    | .remoteEnv.AGY_CACHE_DIR = "/home/vscode/.cache/agy-downloads"
    | .remoteEnv.SSH_AUTH_SOCK = ""
    | .remoteEnv.VSCODE_GIT_IPC_HANDLE = ""
    | .remoteEnv.VSCODE_GIT_ASKPASS_NODE = ""
    | .remoteEnv.VSCODE_GIT_ASKPASS_MAIN = ""
    | .remoteEnv.GIT_ASKPASS = "/bin/false"
    | .remoteEnv.SSH_ASKPASS = "/bin/false"
    | .remoteEnv.WAYLAND_DISPLAY = ""
    | .remoteEnv.VSCODE_IPC_HOOK_CLI = ""
    | (if ($ver != "latest") then .remoteEnv.AGY_CLI_DISABLE_AUTO_UPDATE = "true" else del(.remoteEnv.AGY_CLI_DISABLE_AUTO_UPDATE) end)
    | del(.remoteEnv.ANTIGRAVITY_NO_AUTO_UPDATE)
    | .postStartCommand = (
        if (.postStartCommand | type) == "string" then
          (if (.postStartCommand | contains("vscode-wayland")) then .postStartCommand else (.postStartCommand + "; " + $clean_cmd) end)
        elif (.postStartCommand | type) == "array" then
          (if (.postStartCommand | any(tostring | contains("vscode-wayland"))) then .postStartCommand else (["bash", "-c", ($clean_cmd + "; \"$@\""), "--"] + .postStartCommand) end)
        elif (.postStartCommand | type) == "object" then
          (.postStartCommand + {"agy_cleanup": $clean_cmd})
        else
          $clean_cmd
        end
      )
    | .postAttachCommand = (
        if (.postAttachCommand | type) == "string" then
          (if (.postAttachCommand | contains("vscode-wayland")) then .postAttachCommand else (.postAttachCommand + "; " + $clean_cmd) end)
        elif (.postAttachCommand | type) == "array" then
          (if (.postAttachCommand | any(tostring | contains("vscode-wayland"))) then .postAttachCommand else (["bash", "-c", ($clean_cmd + "; \"$@\""), "--"] + .postAttachCommand) end)
        elif (.postAttachCommand | type) == "object" then
          (.postAttachCommand + {"agy_cleanup": $clean_cmd})
        else
          $clean_cmd
        end
      )
  '

  jq --arg name "\${localWorkspaceFolderBasename} (${display_name} Sandbox)" \
     --arg ver "${agy_version}" \
     --arg patch "${agy_patch}" \
     --arg patcher_commit "${patcher_commit}" \
     --arg net "${NETWORK_NAME}" \
     --arg dns1 "${DNS_PRIMARY}" \
     --arg dns2 "${DNS_SECONDARY}" \
     --arg pids "${PIDS_LIMIT}" \
     --arg mem "${MEMORY_LIMIT}" \
     --arg cpus "${CPUS_LIMIT}" \
     --arg tmpfs "${TMPFS_SIZE}" \
     --arg init_cmd "${init_cmd}" \
     --arg clean_cmd "${clean_forwarding_cmd}" \
     --arg shared_cfg "${shared_config_mount}" \
     --arg cache_vol "${cache_volume}" \
     --arg proj_vol "${project_volume}" \
     --argjson exts "${exts_json}" \
     --argjson base_settings "${base_settings}" \
     --argjson tmpl_settings "${tmpl_settings}" \
     --argjson extra_mounts "${extra_mounts_json}" \
     "${jq_filter}" \
     "${base_json}" > "${output_file}"
}

assemble_declarative_template() {
  local template_path="$1"
  local template_name="$2"
  local dest_dir="$3"
  local agy_version="${4:-${AGY_VERSION:-${DEFAULT_AGY_VERSION}}}"
  local agy_patch="${5:-${AGY_PATCH:-${DEFAULT_AGY_PATCH}}}"
  local extra_mounts_json="${6:-[]}"
  local patcher_commit="${7:-${CLI_PATCHER_COMMIT:-${DEFAULT_PATCHER_COMMIT}}}"
  local patcher_repo="${8:-${DEFAULT_PATCHER_REPO}}"
  local target_dir="${9:-}"
  local shared_config="${10:-${DEFAULT_SHARED_CONFIG}}"
  local shared_cache="${11:-${DEFAULT_SHARED_CACHE}}"

  # 1. Setup hook
  cp "${ROOT_DIR}/base/setup.sh" "${dest_dir}/setup.sh"
  if [ -f "${template_path}/extra-setup.sh" ]; then
    echo "" >> "${dest_dir}/setup.sh"
    cat "${template_path}/extra-setup.sh" >> "${dest_dir}/setup.sh"
  fi

  # 2. Dockerfile
  assemble_dockerfile "${ROOT_DIR}/base/Dockerfile" "${template_name}" "${template_path}" "${dest_dir}/Dockerfile" "${patcher_commit}" "${patcher_repo}"

  # 3. devcontainer.json
  assemble_devcontainer_json "${ROOT_DIR}/base/devcontainer.json" "${template_name}" "${template_path}" "${dest_dir}/devcontainer.json" "${agy_version}" "${agy_patch}" "${extra_mounts_json}" "${patcher_commit}" "${target_dir}" "${shared_config}" "${shared_cache}"

  # 4. CLI installer
  cp "${ROOT_DIR}/base/install-agy.sh" "${dest_dir}/install-agy.sh"
  if [ -n "${patcher_commit}" ]; then
    sed -i 's|PATCHER_COMMIT=.*[a-f0-9]\{40\}.*|PATCHER_COMMIT="${PATCHER_COMMIT:-'"${patcher_commit}"'}"|' "${dest_dir}/install-agy.sh" 2>/dev/null || true
  fi
  chmod +x "${dest_dir}/install-agy.sh"

  # 5. Copy auxiliary template files (scripts, configs, readme)
  for item in "${template_path}"/*; do
    [ -e "${item}" ] || continue
    local b_name
    b_name="$(basename "${item}")"
    case "${b_name}" in
      description.txt|packages.txt|extra.Dockerfile|extra-setup.sh|settings.json|extensions.txt)
        ;;
      *)
        cp -r "${item}" "${dest_dir}/"
        ;;
    esac
  done
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

validate_target_dir() {
  local dir_raw="$1"
  if [ -z "${dir_raw}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Target directory cannot be empty.${CLR_RESET}" >&2
    return 1
  fi

  local dir_path
  dir_path="$(expand_path "${dir_raw}")"
  local canonical_target
  canonical_target="$(realpath -m "${dir_path}" 2>/dev/null || echo "${dir_path}")"

  # 1. Root filesystem
  if [ "${canonical_target}" = "/" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Root filesystem '/' cannot be used as sandbox target directory!${CLR_RESET}" >&2
    return 1
  fi

  local canonical_home
  canonical_home="$(realpath -m "${HOME:-/home/$(whoami)}" 2>/dev/null || echo "${HOME}")"

  # 2. Check if target is inside user HOME hierarchy
  # Allows subdirectories under user HOME even on Ostree/Silverblue where $HOME is /var/home/...
  if [ -n "${canonical_home}" ] && ([ "${canonical_target}" = "${canonical_home}" ] || [[ "${canonical_target}" == "${canonical_home}/"* ]]); then
    # User root HOME directory itself
    if [ "${canonical_target}" = "${canonical_home}" ]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Cannot initialize sandbox directly in user root HOME directory ('${canonical_home}')!${CLR_RESET}" >&2
      echo -e "    Mounting the entire home directory exposes host secrets (~/.ssh, ~/.gnupg, ~/.bashrc) to the container." >&2
      echo -e "    Please specify a dedicated project subdirectory (e.g. 'agy-sandbox ~/projects/my-project')." >&2
      return 1
    fi

    # Check if target is a hidden file or directory in user HOME
    if [[ "${canonical_target}" == "${canonical_home}/."* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Target directory '${canonical_target}' is a hidden file or directory in user HOME and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi

    # Sensitive credential and configuration directories under user HOME
    local sens_dirs=(".ssh" ".gnupg" ".aws" ".kube" ".config" ".docker" ".local" ".azure" ".password-store")
    for s_sub in "${sens_dirs[@]}"; do
      local s_path="${canonical_home}/${s_sub}"
      if [ "${canonical_target}" = "${s_path}" ] || [[ "${canonical_target}" == "${s_path}/"* ]]; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: '${canonical_target}' is a sensitive directory ('${s_sub}') and cannot be used as sandbox target directory!${CLR_RESET}" >&2
        return 1
      fi
    done

    # Verified safe user project subdirectory
    echo "${canonical_target}"
    return 0
  fi

  # 3. Check if target is /home, /Users, or an ancestor of user HOME
  if [ "${canonical_target}" = "/home" ] || [ "${canonical_target}" = "/Users" ] || [[ "${canonical_home}" == "${canonical_target}/"* ]]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Target directory '${canonical_target}' is an ancestor of user HOME ('${canonical_home}') and is blacklisted for security reasons!${CLR_RESET}" >&2
    return 1
  fi

  # 4. Critical host system directories
  local sys_dirs=("/etc" "/usr" "/var" "/bin" "/sbin" "/lib" "/lib64" "/proc" "/sys" "/dev" "/run" "/root")
  for s_dir in "${sys_dirs[@]}"; do
    if [ "${canonical_target}" = "${s_dir}" ] || [[ "${canonical_target}" == "${s_dir}/"* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: '${canonical_target}' is in system directory '${s_dir}' and cannot be used as sandbox target directory!${CLR_RESET}" >&2
      return 1
    fi
  done

  echo "${canonical_target}"
  return 0
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

  # Reject commas to prevent option injection attacks
  if [[ "${host_raw}" == *","* ]] || [[ "${container_path}" == *","* ]]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Mount paths cannot contain commas (','): '${spec}'${CLR_RESET}" >&2
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

  local canonical_container
  canonical_container="$(realpath -m "${container_path}" 2>/dev/null || echo "${container_path}")"

  # Protect container system and sensitive directories from overwrite
  local protected_container_dirs=(
    "/usr/local/share/agy-sandbox"
    "/usr/local/bin"
    "/etc"
    "/home/vscode/.config/git"
    "/bin"
    "/sbin"
    "/usr"
    "/lib"
    "/lib64"
    "/var"
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/root"
  )
  for p_dir in "${protected_container_dirs[@]}"; do
    if [ "${canonical_container}" = "${p_dir}" ] || [[ "${canonical_container}" == "${p_dir}/"* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Container mount path '${container_path}' targets protected system directory '${p_dir}'.${CLR_RESET}" >&2
      return 1
    fi
  done
  container_path="${canonical_container}"

  local host_path
  host_path="$(expand_path "${host_raw}")"
  local canonical_host
  canonical_host="$(realpath -m "${host_path}" 2>/dev/null || echo "${host_path}")"

  if [[ "${canonical_host}" == *","* ]]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Canonical host path contains commas (','): '${canonical_host}'${CLR_RESET}" >&2
    return 1
  fi

  # Security Blacklist checks
  # 1. Root filesystem
  if [ "${canonical_host}" = "/" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '/' is blacklisted for security reasons!${CLR_RESET}" >&2
    return 1
  fi

  local canonical_home
  canonical_home="$(realpath -m "${HOME:-/home/$(whoami)}" 2>/dev/null || echo "${HOME}")"

  # 2. Check if host mount path is inside user HOME hierarchy
  # Allows subdirectories under user HOME even on Ostree/Silverblue where $HOME is /var/home/...
  if [ -n "${canonical_home}" ] && ([ "${canonical_host}" = "${canonical_home}" ] || [[ "${canonical_host}" == "${canonical_home}/"* ]]); then
    if [ "${canonical_host}" = "${canonical_home}" ]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' is the entire user HOME directory and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi

    # Hidden files or directories under user HOME
    if [[ "${canonical_host}" == "${canonical_home}/."* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' is a hidden file or directory in user HOME and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi

    # Sensitive directories under user HOME
    local sens_dirs=(".ssh" ".gnupg" ".aws" ".kube" ".config" ".docker" ".local" ".azure" ".password-store")
    for s_sub in "${sens_dirs[@]}"; do
      local s_path="${canonical_home}/${s_sub}"
      if [ "${canonical_host}" = "${s_path}" ] || [[ "${canonical_host}" == "${s_path}/"* ]]; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' contains sensitive directory '${s_sub}' and is blacklisted for security reasons!${CLR_RESET}" >&2
        return 1
      fi
    done
  else
    # 3. Docker sockets
    if [ "${canonical_host}" = "/var/run/docker.sock" ] || [ "${canonical_host}" = "/run/docker.sock" ]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' is a Docker socket and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi

    # 4. Ancestor directories of user HOME
    if [ "${canonical_host}" = "/home" ] || [ "${canonical_host}" = "/Users" ] || [[ "${canonical_home}" == "${canonical_host}/"* ]]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' is an ancestor of user HOME ('${canonical_home}') and is blacklisted for security reasons!${CLR_RESET}" >&2
      return 1
    fi

    # 5. System directories and subdirectories
    local sys_dirs=("/etc" "/usr" "/var" "/bin" "/sbin" "/lib" "/lib64" "/proc" "/sys" "/dev" "/run" "/root")
    for s_dir in "${sys_dirs[@]}"; do
      if [ "${canonical_host}" = "${s_dir}" ] || [[ "${canonical_host}" == "${s_dir}/"* ]]; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Host mount path '${host_raw}' (resolves to '${canonical_host}') is in system directory '${s_dir}' and is blacklisted for security reasons!${CLR_RESET}" >&2
        return 1
      fi
    done
  fi

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

do_review_sandbox() {
  local target_dir_raw="${1:-.}"
  local branch="${2:-agy-sandbox}"

  if ! git check-ref-format --branch "${branch}" 2>/dev/null; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Invalid git branch name '${branch}'.${CLR_RESET}" >&2
    return 1
  fi

  local target_dir=""
  if ! target_dir="$(validate_target_dir "${target_dir_raw}")"; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Review target directory validation failed. Aborting.${CLR_RESET}" >&2
    return 1
  fi

  if [ ! -d "${target_dir}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Directory '${target_dir}' does not exist.${CLR_RESET}" >&2
    return 1
  fi

  local main_repo_dir
  if git -C "${target_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    main_repo_dir="$(git -C "${target_dir}" rev-parse --show-toplevel)"
  else
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: '${target_dir}' is not a git repository.${CLR_RESET}" >&2
    return 1
  fi

  local sandbox_dir="${main_repo_dir}-sandbox"
  if [ ! -d "${sandbox_dir}" ]; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Sandbox clone not found at '${sandbox_dir}'.${CLR_RESET}" >&2
    echo "    Run 'agy-sandbox --worktree ${main_repo_dir}' first to initialize an isolated sandbox." >&2
    return 1
  fi

  echo -e "${CLR_BOLD}==> [antigravity-sandbox] Reviewing changes from '${sandbox_dir}' (branch: '${branch}')...${CLR_RESET}"

  # Fetch changes from sandbox into main repository FETCH_HEAD
  echo "==> Fetching commits from sandbox via safe Git transport protocol..."
  if ! git -C "${main_repo_dir}" fetch --no-recurse-submodules -- "${sandbox_dir}" "refs/heads/${branch}"; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Failed to fetch branch '${branch}' from '${sandbox_dir}'.${CLR_RESET}" >&2
    return 1
  fi

  echo ""
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
  echo -e "${CLR_BOLD} Git Diff Summary (HEAD .. FETCH_HEAD):${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
  git -C "${main_repo_dir}" diff --stat HEAD..FETCH_HEAD || true
  echo ""

  echo -e "${CLR_BOLD}Detailed Diff Preview:${CLR_RESET}"
  git -C "${main_repo_dir}" diff --color=always HEAD..FETCH_HEAD | head -n 120 || true

  echo ""
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
  echo -e "${CLR_GREEN}✓ Review completed safely without host execution risks.${CLR_RESET}"
  echo "To merge these reviewed changes into your current branch on the host, run:"
  echo -e "  ${CLR_BOLD}cd ${main_repo_dir} && git merge FETCH_HEAD${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
}

do_init_sandbox() {
  local target_dir_raw="${1:-.}"
  local template="${2:-default}"
  local auto_gitignore="${3:-prompt}" # prompt, yes, no
  local agy_version="${4:-${AGY_VERSION:-${DEFAULT_AGY_VERSION}}}"
  local agy_patch="${5:-${AGY_PATCH:-${DEFAULT_AGY_PATCH}}}"
  local use_worktree="${6:-${CLI_WORKTREE:-false}}"
  local worktree_branch="${7:-${CLI_WORKTREE_BRANCH:-agy-sandbox}}"
  local patcher_commit="${8:-${CLI_PATCHER_COMMIT:-${DEFAULT_PATCHER_COMMIT}}}"
  local patcher_repo="${9:-${DEFAULT_PATCHER_REPO}}"
  local shared_config="${10:-${CLI_SHARED_CONFIG:-${DEFAULT_SHARED_CONFIG}}}"
  local shared_cache="${11:-${CLI_SHARED_CACHE:-${DEFAULT_SHARED_CACHE}}}"

  # Validate target directory against security blacklist
  local target_dir=""
  if ! target_dir="$(validate_target_dir "${target_dir_raw}")"; then
    echo -e "${CLR_RED}==> [antigravity-sandbox] Target directory validation failed. Aborting.${CLR_RESET}" >&2
    return 1
  fi

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

  # 2. Process Git repository isolation if requested (isolated clone)
  local is_worktree=false
  local worktree_dir=""
  if [ "${use_worktree}" = "true" ]; then
    if ! git check-ref-format --branch "${worktree_branch}" 2>/dev/null; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Invalid git branch name '${worktree_branch}'.${CLR_RESET}" >&2
      return 1
    fi

    if [ ! -d "${target_dir}" ]; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Target directory '${target_dir}' does not exist.${CLR_RESET}" >&2
      return 1
    fi

    if ! git -C "${target_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Target directory '${target_dir}' is not a git repository. Cannot create isolated sandbox clone.${CLR_RESET}" >&2
      return 1
    fi

    local main_repo_dir
    main_repo_dir="$(git -C "${target_dir}" rev-parse --show-toplevel)"
    worktree_dir="${main_repo_dir}-sandbox"

    if [ -d "${worktree_dir}" ]; then
      # Check if this is an old vulnerable git worktree (where .git is a file)
      if [ -f "${worktree_dir}/.git" ]; then
        echo -e "${CLR_YELLOW}==> [antigravity-sandbox] Warning: Detected legacy/vulnerable git worktree at '${worktree_dir}'.${CLR_RESET}"
        echo -e "    Legacy worktrees share the host's .git and are vulnerable to Host RCE via git hooks or config injection."
        if [ -n "$(git -C "${worktree_dir}" status --porcelain 2>/dev/null)" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Existing worktree '${worktree_dir}' contains uncommitted changes!${CLR_RESET}" >&2
          echo -e "    Aborting to prevent data loss. Commit, stash, or manually remove '${worktree_dir}' before proceeding." >&2
          return 1
        fi
        echo -e "    Recreating '${worktree_dir}' as a fully isolated Git clone..."
        rm -rf "${worktree_dir}"
      elif [ -d "${worktree_dir}/.git" ]; then
        echo "==> [antigravity-sandbox] Existing isolated git clone found at '${worktree_dir}'. Reusing..."
      else
        echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Directory '${worktree_dir}' exists but is not a valid git repository.${CLR_RESET}" >&2
        return 1
      fi
    fi

    if [ ! -d "${worktree_dir}" ]; then
      echo "==> [antigravity-sandbox] Creating isolated sandbox clone in '${worktree_dir}' on branch '${worktree_branch}'..."
      # Use --no-hardlinks to ensure complete physical separation of object inodes (prevents hardlink attacks)
      if ! git clone --no-hardlinks "${main_repo_dir}" "${worktree_dir}"; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Failed to clone repository into '${worktree_dir}'.${CLR_RESET}" >&2
        return 1
      fi
      if ! git -C "${worktree_dir}" checkout -B "${worktree_branch}" --; then
        echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Failed to switch to branch '${worktree_branch}' in '${worktree_dir}'.${CLR_RESET}" >&2
        return 1
      fi
    fi

    # Redirect target directory to sandbox clone directory
    target_dir="${worktree_dir}"
    auto_gitignore="no"
    is_worktree=true
  fi

  # 3. Add VFS Read-Only Git metadata protection mounts (Defense-in-Depth)
  # Protects against agent modifying .git/config (core.fsmonitor / core.hooksPath), injecting hooks, or submodules
  if [ -d "${target_dir}/.git" ]; then
    mkdir -p "${target_dir}/.git/hooks" "${target_dir}/.git/info" "${target_dir}/.git/modules"
    [ -f "${target_dir}/.git/config" ] || touch "${target_dir}/.git/config"

    # Exclude .devcontainer/ in info/exclude
    local exclude_file="${target_dir}/.git/info/exclude"
    if [ ! -f "${exclude_file}" ] || ! grep -q "^\.devcontainer" "${exclude_file}"; then
      echo -e "\n# Antigravity Sandbox Dev Container\n.devcontainer/" >> "${exclude_file}"
    fi

    extra_mounts+=(
      "source=\${localWorkspaceFolder}/.git/hooks,target=\${containerWorkspaceFolder}/.git/hooks,type=bind,readonly"
      "source=\${localWorkspaceFolder}/.git/config,target=\${containerWorkspaceFolder}/.git/config,type=bind,readonly"
      "source=\${localWorkspaceFolder}/.git/info,target=\${containerWorkspaceFolder}/.git/info,type=bind,readonly"
      "source=\${localWorkspaceFolder}/.git/modules,target=\${containerWorkspaceFolder}/.git/modules,type=bind,readonly"
    )
  elif [ -f "${target_dir}/.git" ]; then
    # In case of existing worktree file pointer, lock .git file as Read-Only
    extra_mounts+=(
      "source=\${localWorkspaceFolder}/.git,target=\${containerWorkspaceFolder}/.git,type=bind,readonly"
    )
  fi

  # 4. Protect .vscode/ against Host RCE via tasks.json / settings.json
  mkdir -p "${target_dir}/.vscode"
  if [ ! -f "${target_dir}/.vscode/settings.json" ]; then
    cat << 'EOF' > "${target_dir}/.vscode/settings.json"
{
  "dev.containers.copyGitConfig": false,
  "dev.containers.dockerCredentialHelper": false,
  "dev.containers.mountWaylandSocket": false,
  "dev.containers.forwardGpg": false
}
EOF
  elif command -v jq >/dev/null 2>&1; then
    local tmp_vs
    tmp_vs="$(mktemp)"
    if jq '. * {
      "dev.containers.copyGitConfig": false,
      "dev.containers.dockerCredentialHelper": false,
      "dev.containers.mountWaylandSocket": false,
      "dev.containers.forwardGpg": false
    }' "${target_dir}/.vscode/settings.json" > "${tmp_vs}" 2>/dev/null; then
      mv "${tmp_vs}" "${target_dir}/.vscode/settings.json"
    else
      rm -f "${tmp_vs}" 2>/dev/null || true
    fi
  fi
  extra_mounts+=(
    "source=\${localWorkspaceFolder}/.vscode,target=\${containerWorkspaceFolder}/.vscode,type=bind,readonly"
  )

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
  if [ "${agy_patch}" = "true" ] || [ "${agy_patch}" = "1" ] || [ "${agy_patch}" = "yes" ]; then
    echo "==> [antigravity-sandbox] Patcher commit pinned: '${patcher_commit:0:12}'"
  fi

  mkdir -p "${dest_devcontainer}"

  local extra_mounts_json="[]"
  if [ ${#extra_mounts[@]} -gt 0 ]; then
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
    if [ ! -f "${dest_devcontainer}/devcontainer.json" ]; then
      echo "==> [antigravity-sandbox] Custom template lacks devcontainer.json. Deploying secure base/devcontainer.json..."
      cp "${ROOT_DIR}/base/devcontainer.json" "${dest_devcontainer}/devcontainer.json"
    fi
    local path_hash="default"
    local folder_basename="project"
    if [ -n "${target_dir}" ]; then
      path_hash=$(echo -n "${target_dir}" | sha256sum | cut -c1-8)
      folder_basename="$(basename "${target_dir}")"
    fi
    local project_volume="agy-gemini-data-${folder_basename}-${path_hash}"

    local cache_volume="agy-cache-${folder_basename}-${path_hash}"
    if [ "${shared_cache}" = "true" ] || [ "${shared_cache}" = "1" ] || [ "${shared_cache}" = "yes" ]; then
      cache_volume="agy-shared-cache"
    fi

    local shared_config_mount=""
    if [ "${shared_config}" = "readonly" ] || [ "${shared_config}" = "ro" ]; then
      shared_config_mount="source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume,readonly"
    elif [ "${shared_config}" = "rw" ] || [ "${shared_config}" = "true" ]; then
      shared_config_mount="source=agy-shared-config,target=/home/vscode/.gemini-shared,type=volume"
    elif [ "${shared_config}" = "isolated" ] || [ "${shared_config}" = "none" ] || [ "${shared_config}" = "false" ]; then
      shared_config_mount=""
    fi

    local ready_path="${READY_FILE}"
    local init_cmd="bash -c 'ready=\"${ready_path}\"; if [ ! -s \"\$ready\" ]; then echo \"[FAIL-CLOSED] Sandbox network isolation is NOT active! Run: sudo ./scripts/ensure-network.sh\" >&2; exit 1; fi; br=\$(grep \"^ACTIVE_BRIDGE=\" \"\$ready\" 2>/dev/null | cut -d= -f2); [ -z \"\$br\" ] && br=\"${BRIDGE_NAME}\"; rules_cnt=\$(ip rule show 2>/dev/null | grep -v \"\\[detached\\]\" | grep \"iif \${br}\" | grep -c \"unreachable\"); if [ \"\$rules_cnt\" -lt 12 ]; then echo \"[FAIL-CLOSED] Sandbox network isolation is NOT active! Incomplete RPDB routing rules for \${br} (\$rules_cnt/12+). Run: sudo ./scripts/ensure-network.sh\" >&2; exit 1; fi'"
    local clean_forwarding_cmd="rm -f /tmp/vscode-git-*.sock /tmp/vscode-ssh-auth-*.sock /tmp/user/*/vscode-git-*.sock /tmp/user/*/vscode-ssh-auth-*.sock /tmp/vscode-wayland-*.sock /tmp/user/*/vscode-wayland-*.sock /tmp/user/*/wayland-* 2>/dev/null || true; rm -rf /home/vscode/.gnupg/S.gpg-agent* /tmp/vscode-gpg-agent* /tmp/user/*/vscode-gpg-agent* 2>/dev/null || true; rm -f /home/vscode/.docker/config.json 2>/dev/null || true; if [ -f /home/vscode/.gitconfig ]; then _n=\"\$(git config --file /home/vscode/.gitconfig user.name 2>/dev/null || true)\"; _e=\"\$(git config --file /home/vscode/.gitconfig user.email 2>/dev/null || true)\"; _b=\"\$(git config --file /home/vscode/.gitconfig init.defaultBranch 2>/dev/null || true)\"; rm -f /home/vscode/.gitconfig; [ -n \"\$_n\" ] && git config --file /home/vscode/.gitconfig user.name \"\$_n\" 2>/dev/null || true; [ -n \"\$_e\" ] && git config --file /home/vscode/.gitconfig user.email \"\$_e\" 2>/dev/null || true; [ -n \"\$_b\" ] && git config --file /home/vscode/.gitconfig init.defaultBranch \"\$_b\" 2>/dev/null || true; fi"

    local tmp_dc
    tmp_dc="$(mktemp)"
    # shellcheck disable=SC2016
    local custom_filter='
      del(.privileged)
      | del(.capAdd)
      | del(.securityOpt)
      | del(.capDrop)
      | .customizations.vscode.settings = ((.customizations.vscode.settings // {}) * {
          "dev.containers.copyGitConfig": false,
          "dev.containers.dockerCredentialHelper": false,
          "dev.containers.mountWaylandSocket": false,
          "dev.containers.forwardGpg": false,
          "git.terminalAuthentication": false,
          "github.gitAuthentication": false,
          "git.autofetch": false,
          "remote.autoForwardPorts": false,
          "remote.restoreForwardedPorts": false
        })
      | .runArgs = [
        "--network=" + $net,
        "--dns=" + $dns1,
        "--dns=" + $dns2,
        "--security-opt=no-new-privileges:true",
        "--sysctl=net.ipv6.conf.all.disable_ipv6=1",
        "--sysctl=net.ipv6.conf.default.disable_ipv6=1",
        "--pids-limit=" + $pids,
        "--memory=" + $mem,
        "--cpus=" + $cpus,
        "--tmpfs=/tmp:rw,nosuid,nodev,size=" + $tmpfs + ",mode=1777",
        "--init"
      ] + ((.runArgs // []) | map(select((
          startswith("--network=") or
          startswith("--dns=") or
          startswith("--pids-limit=") or
          startswith("--memory=") or
          startswith("--cpus=") or
          startswith("--tmpfs=/tmp:") or
          startswith("--security-opt=") or
          startswith("--sysctl=net.ipv6.conf") or
          startswith("--privileged") or
          startswith("--cap-add") or
          (. == "--init")
        ) | not)))
      | .runArgs = (
          if (.runArgs | any(test("^--cap-drop=(CAP_)?NET_RAW$"))) then
            .runArgs
          else
            .runArgs + ["--cap-drop=NET_RAW"]
          end
        )
      | .mounts = (
        ((.mounts // []) | map(select(
          (startswith("source=agy-shared-config") or
           startswith("source=agy-shared-cache") or
           startswith("source=agy-cache-") or
           startswith("source=agy-gemini-data-") or
           test("(target|destination)=([^,]+/)?\\.devcontainer")) | not
        ))) as $filtered |
        [
          "source=${localWorkspaceFolder}/.devcontainer,target=${containerWorkspaceFolder}/.devcontainer,type=bind,readonly"
        ] +
        (if ($shared_cfg != "") then [$shared_cfg] else [] end) +
        $filtered +
        [
          ("source=" + $cache_vol + ",target=/home/vscode/.cache,type=volume"),
          ("source=" + $proj_vol + ",target=/home/vscode/.gemini,type=volume")
        ] as $base_m |
        $base_m + ($extra_mounts | map(. as $x | select(($base_m | index($x)) == null)))
      )
      | .initializeCommand = (
          if (.initializeCommand | type) == "string" then
            (if (.initializeCommand | contains("Sandbox network isolation is NOT active")) then .initializeCommand else ($init_cmd + "; " + .initializeCommand) end)
          elif (.initializeCommand | type) == "array" then
            (if (.initializeCommand | any(tostring | contains("Sandbox network isolation is NOT active"))) then .initializeCommand else (["bash", "-c", ($init_cmd + "; \"$@\""), "--"] + .initializeCommand) end)
          elif (.initializeCommand | type) == "object" then
            (.initializeCommand + {"agy_fail_closed": $init_cmd})
          else
            $init_cmd
          end
        )
      | .build.args.AGY_VERSION = (.build.args.AGY_VERSION // $ver)
      | .build.args.PATCHER_COMMIT = (.build.args.PATCHER_COMMIT // $patcher_commit)
      | .remoteEnv.AGY_VERSION = (.remoteEnv.AGY_VERSION // $ver)
      | .remoteEnv.AGY_PATCH = (.remoteEnv.AGY_PATCH // $patch)
      | .remoteEnv.UV_CACHE_DIR = "/home/vscode/.cache/uv"
      | .remoteEnv.AGY_CACHE_DIR = "/home/vscode/.cache/agy-downloads"
      | .remoteEnv.SSH_AUTH_SOCK = ""
      | .remoteEnv.VSCODE_GIT_IPC_HANDLE = ""
      | .remoteEnv.VSCODE_GIT_ASKPASS_NODE = ""
      | .remoteEnv.VSCODE_GIT_ASKPASS_MAIN = ""
      | .remoteEnv.GIT_ASKPASS = "/bin/false"
      | .remoteEnv.SSH_ASKPASS = "/bin/false"
      | .remoteEnv.WAYLAND_DISPLAY = ""
      | .remoteEnv.VSCODE_IPC_HOOK_CLI = ""
      | (if ($ver != "latest") then .remoteEnv.AGY_CLI_DISABLE_AUTO_UPDATE = "true" else del(.remoteEnv.AGY_CLI_DISABLE_AUTO_UPDATE) end)
      | del(.remoteEnv.ANTIGRAVITY_NO_AUTO_UPDATE)
      | .postStartCommand = (
          if (.postStartCommand | type) == "string" then
            (if (.postStartCommand | contains("vscode-wayland")) then .postStartCommand else (.postStartCommand + "; " + $clean_cmd) end)
          elif (.postStartCommand | type) == "array" then
            (if (.postStartCommand | any(tostring | contains("vscode-wayland"))) then .postStartCommand else (["bash", "-c", ($clean_cmd + "; \"$@\""), "--"] + .postStartCommand) end)
          elif (.postStartCommand | type) == "object" then
            (.postStartCommand + {"agy_cleanup": $clean_cmd})
          else
            $clean_cmd
          end
        )
      | .postAttachCommand = (
          if (.postAttachCommand | type) == "string" then
            (if (.postAttachCommand | contains("vscode-wayland")) then .postAttachCommand else (.postAttachCommand + "; " + $clean_cmd) end)
          elif (.postAttachCommand | type) == "array" then
            (if (.postAttachCommand | any(tostring | contains("vscode-wayland"))) then .postAttachCommand else (["bash", "-c", ($clean_cmd + "; \"$@\""), "--"] + .postAttachCommand) end)
          elif (.postAttachCommand | type) == "object" then
            (.postAttachCommand + {"agy_cleanup": $clean_cmd})
          else
            $clean_cmd
          end
        )
    '
    jq --arg net "${NETWORK_NAME}" \
       --arg dns1 "${DNS_PRIMARY}" \
       --arg dns2 "${DNS_SECONDARY}" \
       --arg pids "${PIDS_LIMIT}" \
       --arg mem "${MEMORY_LIMIT}" \
       --arg cpus "${CPUS_LIMIT}" \
       --arg tmpfs "${TMPFS_SIZE}" \
       --arg init_cmd "${init_cmd}" \
       --arg clean_cmd "${clean_forwarding_cmd}" \
       --arg ver "${agy_version}" \
       --arg patch "${agy_patch}" \
       --arg patcher_commit "${patcher_commit}" \
       --arg shared_cfg "${shared_config_mount}" \
       --arg cache_vol "${cache_volume}" \
       --arg proj_vol "${project_volume}" \
       --argjson extra_mounts "${extra_mounts_json}" \
       "${custom_filter}" \
       "${dest_devcontainer}/devcontainer.json" > "${tmp_dc}"
    mv "${tmp_dc}" "${dest_devcontainer}/devcontainer.json"
  else
    echo "==> [antigravity-sandbox] Assembling declarative template from base..."
    assemble_declarative_template "${template_path}" "${template}" "${dest_devcontainer}" "${agy_version}" "${agy_patch}" "${extra_mounts_json}" "${patcher_commit}" "${patcher_repo}" "${target_dir}" "${shared_config}" "${shared_cache}"
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
    echo "Mode: Isolated Sandbox Clone on branch '${worktree_branch}'"
    echo "Host repository is 100% physically isolated; sandbox .git metadata locked as Read-Only."
  fi
  echo "Next steps:"
  echo " 1. Open the sandbox in VS Code / Cursor: code ${target_dir}"
  echo " 2. Press F1 -> 'Dev Containers: Reopen in Container'"
  echo " 3. Antigravity Agent will run safely inside the isolated container"
  if [ "${is_worktree}" = "true" ]; then
    echo " 4. When finished, safely review and merge changes into your main repo on host:"
    echo "    agy-sandbox --review ${main_repo_dir:-<main_repo>} ${worktree_branch}"
    echo "    (or manually: cd ${main_repo_dir:-<main_repo>} && git fetch ${target_dir} ${worktree_branch} && git diff HEAD..FETCH_HEAD)"
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
  CLI_MOUNTS=()

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

    if ! target_dir="$(validate_target_dir "${target_input}")"; then
      echo ""
      continue
    fi

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

  # Git Worktree Isolation option
  local use_worktree="false"
  local worktree_branch="agy-sandbox"

  if [ -d "${target_dir}" ] && git -C "${target_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo ""
    echo -e "${CLR_BOLD}Repository Isolation Mode (Isolated Clone):${CLR_RESET}"
    echo -e "  Target directory is a Git repository. You can isolate the agent"
    echo -e "  inside a standalone clone with full protection of your main repository"
    echo -e "  and read-only .git metadata enforcement."
    echo ""
    echo -e "  ${CLR_BOLD}[1]${CLR_RESET} ${CLR_CYAN}No${CLR_RESET}  - Configure sandbox directly inside '${target_dir}' (Default)"
    echo -e "  ${CLR_BOLD}[2]${CLR_RESET} ${CLR_CYAN}Yes${CLR_RESET} - Create isolated sandbox clone (e.g. '${target_dir}-sandbox')"
    echo ""

    local rc=0
    local wt_choice="1"
    read -r -p "Enable Git worktree isolation? [1-2, default: 1]: " wt_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi
    wt_choice="${wt_choice:-1}"
    case "${wt_choice}" in
      2|[Yy]|[Yy][Ee][Ss])
        use_worktree="true"
        echo ""
        local rc_wt=0
        local wt_branch_input=""
        read -r -p "Enter worktree branch name [default: agy-sandbox]: " wt_branch_input || rc_wt=$?
        if [ "$rc_wt" -gt 128 ]; then
          echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
          sleep 0.5
          return 130
        fi
        wt_branch_input="$(echo "${wt_branch_input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        worktree_branch="${wt_branch_input:-agy-sandbox}"
        echo -e "  ${CLR_GREEN}✓ Worktree enabled on branch '${worktree_branch}'${CLR_RESET}"
        ;;
      *)
        use_worktree="false"
        ;;
    esac
  fi

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
  echo -e "  ${CLR_BOLD}[1]${CLR_RESET} ${CLR_CYAN}stable (${PINNED_STABLE_VERSION})${CLR_RESET} - Pinned release (Recommended with patch)"
  echo -e "  ${CLR_BOLD}[2]${CLR_RESET} ${CLR_CYAN}latest${CLR_RESET}                 - Always install latest upstream release"
  echo -e "  ${CLR_BOLD}[3]${CLR_RESET} ${CLR_CYAN}custom${CLR_RESET}                 - Specify custom version tag (e.g. 1.5.3, v1.5.3)"
  echo ""

  local default_v_choice="1"
  if [ "${DEFAULT_AGY_PINNED}" = "false" ]; then
    default_v_choice="2"
  fi

  local selected_version="${DEFAULT_AGY_VERSION}"
  while true; do
    local rc=0
    local v_choice="${default_v_choice}"
    read -r -p "Select version option [1-3, default: ${default_v_choice}]: " v_choice || rc=$?
    if [ "$rc" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi
    v_choice="${v_choice:-${default_v_choice}}"
    case "${v_choice}" in
      1)
        selected_version="${PINNED_STABLE_VERSION}"
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
          read -r -p "Enter version tag (e.g. 1.5.3, v1.5.3) or 'cancel': " custom_tag || rc_custom=$?
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
            echo -e "${CLR_RED}Invalid version format '${custom_tag}'. Expected e.g. '1.5.3' or 'v1.5.3'.${CLR_RESET}"
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

  local default_p_choice="1"
  if [ "${DEFAULT_AGY_PATCH}" = "false" ] || [ "${DEFAULT_AGY_PATCH}" = "0" ] || [ "${DEFAULT_AGY_PATCH}" = "no" ]; then
    default_p_choice="2"
  fi

  local selected_patch="${DEFAULT_AGY_PATCH}"
  while true; do
    local rc=0
    local p_choice="${default_p_choice}"
    read -r -p "Apply patch? [1-2, default: ${default_p_choice}]: " p_choice || rc=$?
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

  # Additional Host Bind Mounts
  echo ""
  echo -e "${CLR_BOLD}Additional Host Bind Mounts (Optional):${CLR_RESET}"
  echo -e "  Mount external host directories into the container (e.g. datasets, shared caches)."
  echo -e "  Format: <host_path>:<container_path>[:ro|rw] (default mode: ro)"
  echo ""
  echo -e "  ${CLR_BOLD}[1]${CLR_RESET} ${CLR_CYAN}No${CLR_RESET}  - Standard sandbox mounts only (Default)"
  echo -e "  ${CLR_BOLD}[2]${CLR_RESET} ${CLR_CYAN}Yes${CLR_RESET} - Configure custom bind mounts"
  echo ""

  local rc=0
  local mount_choice="1"
  read -r -p "Configure custom mounts? [1-2, default: 1]: " mount_choice || rc=$?
  if [ "$rc" -gt 128 ]; then
    echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
    sleep 0.5
    return 130
  fi
  mount_choice="${mount_choice:-1}"

  case "${mount_choice}" in
    2|[Yy]|[Yy][Ee][Ss])
      while true; do
        echo ""
        local rc_m=0
        local m_input=""
        read -er -p "Enter mount (or press Enter when finished): " m_input || rc_m=$?
        if [ "$rc_m" -gt 128 ]; then
          break
        fi
        m_input="$(echo "${m_input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${m_input}" ] && break

        local parsed_entry=""
        if parsed_entry="$(validate_and_parse_mount "${m_input}")"; then
          CLI_MOUNTS+=("${m_input}")
          echo -e "  ${CLR_GREEN}✓ Added custom mount: ${m_input}${CLR_RESET}"
        else
          echo -e "  ${CLR_YELLOW}Mount rejected. Please re-enter or press Enter to skip.${CLR_RESET}"
        fi
      done
      ;;
  esac

  local add_git="yes"
  if [ "${use_worktree}" != "true" ] && [ -f "${target_dir}/.gitignore" ]; then
    echo ""
    local rc_git=0
    local git_choice="y"
    read -r -p "Add .devcontainer/ to ${target_dir}/.gitignore? (Y/n): " git_choice || rc_git=$?
    if [ "$rc_git" -gt 128 ]; then
      echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Wizard cancelled.${CLR_RESET}"
      sleep 0.5
      return 130
    fi
    if [[ "${git_choice}" =~ ^[Nn]$ ]]; then
      add_git="no"
    fi
  fi

  # Summary and Confirmation
  echo ""
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}           SANDBOX INITIALIZATION SUMMARY                    ${CLR_RESET}"
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
  echo -e "  Target Directory: ${CLR_BOLD}${target_dir}${CLR_RESET}"
  if [ "${use_worktree}" = "true" ]; then
    echo -e "  Git Isolation:    ${CLR_GREEN}Enabled (branch: ${worktree_branch}, path: ${target_dir}-sandbox)${CLR_RESET}"
  else
    echo -e "  Git Isolation:    ${CLR_DIM}Disabled (direct repository setup)${CLR_RESET}"
  fi
  echo -e "  Template Profile: ${CLR_CYAN}${selected_template}${CLR_RESET}"
  echo -e "  Antigravity CLI:  ${CLR_CYAN}${selected_version}${CLR_RESET} (Patched: ${selected_patch})"
  if [ "${selected_patch}" = "true" ] || [ "${selected_patch}" = "1" ] || [ "${selected_patch}" = "yes" ]; then
    local p_commit="${CLI_PATCHER_COMMIT:-${DEFAULT_PATCHER_COMMIT}}"
    echo -e "  Patcher Commit:   ${CLR_CYAN}${p_commit:0:12}${CLR_RESET}"
  fi
  if [ ${#CLI_MOUNTS[@]} -gt 0 ]; then
    echo -e "  Custom Mounts:    ${CLR_GREEN}${#CLI_MOUNTS[@]} mount(s)${CLR_RESET}"
    for cm in "${CLI_MOUNTS[@]}"; do
      echo -e "                    ${CLR_DIM}- ${cm}${CLR_RESET}"
    done
  else
    echo -e "  Custom Mounts:    ${CLR_DIM}None (standard isolation)${CLR_RESET}"
  fi
  echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
  echo ""

  local rc_confirm=0
  local confirm_init="y"
  read -r -p "Proceed with sandbox initialization? [Y/n]: " confirm_init || rc_confirm=$?
  if [ "$rc_confirm" -gt 128 ] || [[ "${confirm_init}" =~ ^[Nn]$ ]]; then
    echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Initialization cancelled by user.${CLR_RESET}"
    sleep 0.5
    return 0
  fi

  echo ""
  do_init_sandbox "${target_dir}" "${selected_template}" "${add_git}" "${selected_version}" "${selected_patch}" "${use_worktree}" "${worktree_branch}" "${CLI_PATCHER_COMMIT:-${DEFAULT_PATCHER_COMMIT}}" "${DEFAULT_PATCHER_REPO}" "${CLI_SHARED_CONFIG:-${DEFAULT_SHARED_CONFIG}}" "${CLI_SHARED_CACHE:-${DEFAULT_SHARED_CACHE}}"
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

tui_prune() {
  trap 'echo -e "\n${CLR_YELLOW}==> [antigravity-sandbox] Container cleanup cancelled.${CLR_RESET}"; sleep 0.5; return 130' INT
  tui_header
  "${SCRIPT_DIR}/prune-containers.sh" || true
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
    echo -e "  ${CLR_BOLD}[4] 🧹 Prune Residual Containers & Artifacts${CLR_RESET}"
    echo -e "      ${CLR_DIM}Clean exited, dead, or orphaned containers, keeping only active workspaces${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BOLD}[5] 🚪 Exit${CLR_RESET}"
    echo ""
    local rc=0
    local main_choice="5"
    read -r -p "Select option [1-5]: " main_choice || rc=$?
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
      4)
        tui_prune || true
        ;;
      5|q|Q)
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
  CLI_VERSION_SET=false
  CLI_PINNED_SET=false
  CLI_PINNED="${AGY_PINNED:-}"
  [ -n "${CLI_PINNED}" ] && CLI_PINNED_SET=true
  CLI_VERSION=""
  CLI_PATCH="${DEFAULT_AGY_PATCH}"
  CLI_PATCHER_COMMIT="${DEFAULT_PATCHER_COMMIT}"
  CLI_SHARED_CONFIG="${DEFAULT_SHARED_CONFIG}"
  CLI_SHARED_CACHE="${DEFAULT_SHARED_CACHE}"
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
      --clean|-c|--prune|clean|prune)
        shift
        exec "${SCRIPT_DIR}/prune-containers.sh" "$@"
        ;;
      --review|-r|review)
        shift
        do_review_sandbox "$@"
        exit $?
        ;;
      --interactive|-i)
        FORCE_INTERACTIVE=true
        shift
        ;;
      -w|--worktree|--isolate|--clone)
        CLI_WORKTREE=true
        shift
        ;;
      --worktree-branch=*|--branch=*)
        val="${1#*=}"
        if ! git check-ref-format --branch "$val" 2>/dev/null; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Invalid branch name '$val' for $1${CLR_RESET}" >&2
          exit 1
        fi
        CLI_WORKTREE_BRANCH="$val"
        CLI_WORKTREE=true
        shift
        ;;
      --worktree-branch|--branch)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing branch name for $1${CLR_RESET}" >&2
          exit 1
        fi
        if ! git check-ref-format --branch "$2" 2>/dev/null; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Security Error: Invalid branch name '$2' for $1${CLR_RESET}" >&2
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
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Invalid version format '$2'. Expected 'latest' or SemVer tag (e.g. '1.5.3' or 'v1.5.3').${CLR_RESET}" >&2
          exit 1
        fi
        CLI_VERSION="$2"
        CLI_VERSION_SET=true
        shift 2
        ;;
      --pin|--pinned)
        CLI_PINNED="true"
        CLI_PINNED_SET=true
        shift
        ;;
      --no-pin|--unpinned)
        CLI_PINNED="false"
        CLI_PINNED_SET=true
        shift
        ;;
      --patch)
        CLI_PATCH="true"
        shift
        ;;
      --no-patch|--skip-patch)
        CLI_PATCH="false"
        shift
        ;;
      --patcher-commit)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing commit SHA for --patcher-commit${CLR_RESET}" >&2
          exit 1
        fi
        if [[ ! "$2" =~ ^[a-f0-9]{40}$ ]]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Invalid commit SHA '$2'. Expected a 40-character Git commit hash.${CLR_RESET}" >&2
          exit 1
        fi
        CLI_PATCHER_COMMIT="$2"
        shift 2
        ;;
      --patcher-commit=*)
        val="${1#*=}"
        if [[ ! "$val" =~ ^[a-f0-9]{40}$ ]]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Invalid commit SHA '$val'. Expected a 40-character Git commit hash.${CLR_RESET}" >&2
          exit 1
        fi
        CLI_PATCHER_COMMIT="$val"
        shift
        ;;
      --shared-config=*)
        CLI_SHARED_CONFIG="${1#*=}"
        shift
        ;;
      --shared-config)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing value for --shared-config${CLR_RESET}" >&2
          exit 1
        fi
        CLI_SHARED_CONFIG="$2"
        shift 2
        ;;
      --shared-cache)
        CLI_SHARED_CACHE="true"
        shift
        ;;
      --no-shared-cache|--isolated-cache)
        CLI_SHARED_CACHE="false"
        shift
        ;;
      --shared-cache=*)
        CLI_SHARED_CACHE="${1#*=}"
        shift
        ;;
      -t|--template)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing template name for $1${CLR_RESET}" >&2
          exit 1
        fi
        TEMPLATE="$2"
        shift 2
        ;;
      --template=*)
        TEMPLATE="${1#*=}"
        shift
        ;;
      --target)
        if [ -z "${2:-}" ]; then
          echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Missing target directory for $1${CLR_RESET}" >&2
          exit 1
        fi
        TARGET_DIR="$2"
        shift 2
        ;;
      --target=*)
        TARGET_DIR="${1#*=}"
        shift
        ;;
      -h|--help|help)
        echo "Usage: agy-sandbox [OPTIONS] [TARGET_DIR] [TEMPLATE]"
        echo "       agy-sandbox -t <template> --target <dir>"
        echo "       agy-sandbox --review [TARGET_DIR] [BRANCH]"
        echo ""
        echo "Without arguments in interactive terminal, launches the Antigravity TUI."
        echo ""
        echo "Options:"
        echo "  -i, --interactive              Launch interactive terminal user interface"
        echo "  -t, --template <name>          Specify sandbox template (e.g. 'default', 'math-labs', 'affine-mcp')"
        echo "  --target <dir>                 Specify target project directory"
        echo "  -w, --worktree, --isolate      Create and run sandbox inside an isolated Git clone"
        echo "  --worktree-branch <name>       Git branch for sandbox clone (default: 'agy-sandbox', implies --worktree)"
        echo "  -r, --review [DIR] [BRANCH]    Safely fetch and review sandbox changes in main repository"
        echo "  --mount <host:container[:ro|rw]> Bind mount host path into container (default mode: ro)"
        echo "  -v, --agy-version <tag>        Pin specific Antigravity CLI version (e.g. '1.5.3', 'latest')"
        echo "  --pin, --pinned                Force version pinning (locks binary chmod 555, disables auto-update)"
        echo "  --no-pin, --unpinned           Disable pinning (uses 'latest' unless -v specified, auto-update enabled)"
        echo "  --patch                        Apply QNIX-Dev eligibility patch to CLI binary (default)"
        echo "  --no-patch, --skip-patch       Disable patch, keep clean official binary (maintains 1.5.3 pinning)"
        echo "  --patcher-commit <sha>         Pin specific 40-character Git commit SHA for eligibility patcher"
        echo "  --shared-config <mode>         Shared auth/config mount mode (readonly|rw|isolated|none, default: readonly)"
        echo "  --shared-cache                 Share package and binary cache across sandboxes"
        echo "  --no-shared-cache              Isolate package cache per sandbox (default: isolated)"
        echo "  -l, --list                     List available sandbox templates"
        echo "  -d, --diagnose, diagnose       Run security audit & boundary diagnostics"
        echo "  -c, --clean, --prune           Clean up residual/orphaned containers and build artifacts"
        echo "  --service [COMMAND]            Manage systemd persistence (status|enable|disable|install)"
        echo "  --install-bin                  Symlink agy-sandbox into ~/.local/bin"
        echo "  -h, --help                     Show this help message"
        echo ""
        echo "Examples:"
        echo "  agy-sandbox /path/to/project default"
        echo "  agy-sandbox --worktree /path/to/project math-labs"
        echo "  agy-sandbox --worktree --worktree-branch experiment-1 /path/to/project"
        echo "  agy-sandbox --review /path/to/project agy-sandbox"
        echo "  agy-sandbox --mount /srv/datasets:/data:ro /path/to/project"
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

  # Resolve CLI version and pinning if not explicitly passed via -v
  if [ "$CLI_VERSION_SET" = false ]; then
    if [ "$CLI_PINNED_SET" = false ]; then
      CLI_PINNED="${DEFAULT_AGY_PINNED}"
    fi
    if [ "${CLI_PINNED}" = "true" ] || [ "${CLI_PINNED}" = "1" ] || [ "${CLI_PINNED}" = "yes" ]; then
      CLI_VERSION="${PINNED_STABLE_VERSION}"
    else
      CLI_VERSION="latest"
    fi
  fi

  if [ "$FORCE_INTERACTIVE" = true ]; then
    run_tui
    exit 0
  fi

  # If no arguments provided:
  if [ -z "$TARGET_DIR" ]; then
    if [ -t 0 ] && [ -t 1 ] && [ "$CLI_WORKTREE" != true ] && [ ${#CLI_MOUNTS[@]} -eq 0 ]; then
      run_tui
      exit 0
    else
      echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Target directory is required in non-interactive mode or with flags.${CLR_RESET}" >&2
      echo -e "    Usage: agy-sandbox <target_dir> [template] [options]" >&2
      echo -e "    Example: agy-sandbox ~/projects/my-app" >&2
      exit 1
    fi
  fi

  # Positional arguments provided: agy-sandbox <target_dir> [template]
  TEMPLATE="${TEMPLATE:-default}"
  if ! do_init_sandbox "${TARGET_DIR}" "${TEMPLATE}" "prompt" "${CLI_VERSION}" "${CLI_PATCH}" "${CLI_WORKTREE}" "${CLI_WORKTREE_BRANCH}" "${CLI_PATCHER_COMMIT}" "${DEFAULT_PATCHER_REPO}" "${CLI_SHARED_CONFIG}" "${CLI_SHARED_CACHE}"; then
    exit 1
  fi
fi
