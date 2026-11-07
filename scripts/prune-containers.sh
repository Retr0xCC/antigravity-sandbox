#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Antigravity Sandbox Container & Artifact Pruner
# Selectively inspects and cleans residual, stopped, dead, and orphaned containers,
# preserving active workspaces and allowing selective management of exited projects.
# ==============================================================================

# Resolve symlinks to find real script location
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

if [ -f "${SCRIPT_DIR}/sandbox.conf" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/sandbox.conf"
fi

[ -n "${_ENV_NET}" ] && NETWORK_NAME="${_ENV_NET}"

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_RED="\033[1;31m"
CLR_DIM="\033[2m"

DRY_RUN=false
FORCE=false
PRUNE_IMAGES=false
ORPHANED_ONLY=false
ALL_STOPPED=false

usage() {
  echo -e "${CLR_BOLD}Usage: agy-sandbox --clean [OPTIONS]${CLR_RESET}"
  echo "       or ./scripts/prune-containers.sh [OPTIONS]"
  echo ""
  echo "Selectively cleans up residual and orphaned containers from previous builds,"
  echo "allowing you to preserve stopped project containers you plan to resume later."
  echo ""
  echo "Options:"
  echo "  -o, --orphaned     Clean ONLY defunct/orphaned containers (deleted folders, dead builds)"
  echo "  -a, --all          Select all stopped and orphaned containers for cleanup"
  echo "  -f, --force        Perform selected cleanup non-interactively without prompts"
  echo "  -i, --images       Also prune dangling intermediate build images (<none>:<none>)"
  echo "  -d, --dry-run      Show container classification without deleting anything"
  echo "  -h, --help         Show this help message"
  echo ""
  echo "When run without flags in an interactive terminal, launches an interactive selector."
  echo ""
  exit 0
}

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--orphaned)
      ORPHANED_ONLY=true
      shift
      ;;
    -a|--all)
      ALL_STOPPED=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -i|--images)
      PRUNE_IMAGES=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}" >&2
      usage
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo -e "${CLR_RED}==> [antigravity-sandbox] Error: docker CLI is not installed or not in PATH.${CLR_RESET}" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo -e "${CLR_RED}==> [antigravity-sandbox] Error: Docker daemon is not accessible or not running.${CLR_RESET}" >&2
  exit 1
fi

echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}    🛡️  ANTIGRAVITY SANDBOX CONTAINER CLEANUP & PRUNER        ${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo ""

# Scan for all containers attached to agy_net or with sandbox metadata
all_cids=$(docker ps -a --filter "network=${NETWORK_NAME}" --format '{{.ID}}' 2>/dev/null || true)
title_cids=$(docker ps -a --filter "label=org.opencontainers.image.title=antigravity-sandbox" --format '{{.ID}}' 2>/dev/null || true)

combined_cids=$(printf "%s\n%s\n" "${all_cids}" "${title_cids}" | sed '/^[[:space:]]*$/d' | sort -u)

if [ -z "${combined_cids}" ]; then
  echo -e "${CLR_GREEN}✓ No Antigravity Sandbox containers found on this host.${CLR_RESET}"
  exit 0
fi

ACTIVE_CONTAINERS=()
STOPPED_PROJECT_CONTAINERS=()
ORPHANED_CONTAINERS=()

# Categorize containers
while IFS= read -r cid; do
  [ -z "${cid}" ] && continue
  
  c_info=$(docker inspect "${cid}" 2>/dev/null || true)
  [ -z "${c_info}" ] && continue

  state_status=$(echo "${c_info}" | jq -r '.[0].State.Status // "unknown"')
  c_name=$(echo "${c_info}" | jq -r '.[0].Name // "unknown"' | sed 's|^/||')
  local_folder=$(echo "${c_info}" | jq -r '.[0].Config.Labels["devcontainer.local_folder"] // .[0].Config.Labels["vsch.local.folder"] // ""')

  if [ "${state_status}" = "running" ]; then
    if [ -n "${local_folder}" ] && [ ! -d "${local_folder}" ]; then
      ACTIVE_CONTAINERS+=("${cid}|${c_name}|running (unmounted workspace)|${local_folder}")
    else
      ACTIVE_CONTAINERS+=("${cid}|${c_name}|${state_status}|${local_folder:-active}")
    fi
  elif [ "${state_status}" = "created" ] || [ "${state_status}" = "dead" ]; then
    ORPHANED_CONTAINERS+=("${cid}|${c_name}|${state_status}|${local_folder:-N/A}")
  else
    # Exited / stopped container
    if [ -n "${local_folder}" ] && [ ! -d "${local_folder}" ]; then
      ORPHANED_CONTAINERS+=("${cid}|${c_name}|exited (orphaned)|${local_folder}")
    else
      STOPPED_PROJECT_CONTAINERS+=("${cid}|${c_name}|${state_status}|${local_folder:-N/A}")
    fi
  fi
done <<< "${combined_cids}"

# Section 1: Active Running Containers (Always preserved)
echo -e "${CLR_BOLD}1. Active Project Containers (Currently Running — Preserved):${CLR_RESET}"
if [ ${#ACTIVE_CONTAINERS[@]} -eq 0 ]; then
  echo -e "  ${CLR_DIM}(None running currently)${CLR_RESET}"
else
  printf "  ${CLR_CYAN}%-14s %-32s %-12s %s${CLR_RESET}\n" "CONTAINER ID" "NAME" "STATUS" "WORKSPACE FOLDER"
  for item in "${ACTIVE_CONTAINERS[@]}"; do
    IFS="|" read -r cid name st folder <<< "${item}"
    printf "  %-14s %-32s ${CLR_GREEN}%-12s${CLR_RESET} %s\n" "${cid:0:12}" "${name:0:32}" "${st}" "${folder}"
  done
fi
echo ""

# Section 2: Defunct / Orphaned Containers (Folder missing on disk or dead build)
echo -e "${CLR_BOLD}2. Defunct & Orphaned Containers (Deleted folders / failed builds):${CLR_RESET}"
if [ ${#ORPHANED_CONTAINERS[@]} -eq 0 ]; then
  echo -e "  ${CLR_GREEN}✓ No orphaned or dead containers.${CLR_RESET}"
else
  printf "  ${CLR_RED}%-14s %-32s %-12s %s${CLR_RESET}\n" "CONTAINER ID" "NAME" "STATUS" "MISSING / FAILED PATH"
  for item in "${ORPHANED_CONTAINERS[@]}"; do
    IFS="|" read -r cid name st folder <<< "${item}"
    printf "  %-14s %-32s ${CLR_RED}%-12s${CLR_RESET} %s\n" "${cid:0:12}" "${name:0:32}" "${st}" "${folder}"
  done
fi
echo ""

# Section 3: Stopped Workspace Containers (Exited — Folder exists on host)
echo -e "${CLR_BOLD}3. Stopped Workspace Containers (Exited — Folder exists on host):${CLR_RESET}"
if [ ${#STOPPED_PROJECT_CONTAINERS[@]} -eq 0 ]; then
  echo -e "  ${CLR_DIM}(None)${CLR_RESET}"
else
  printf "  ${CLR_YELLOW}%-4s %-14s %-32s %-12s %s${CLR_RESET}\n" "NUM" "CONTAINER ID" "NAME" "STATUS" "WORKSPACE FOLDER"
  idx=1
  for item in "${STOPPED_PROJECT_CONTAINERS[@]}"; do
    IFS="|" read -r cid name st folder <<< "${item}"
    printf "  ${CLR_BOLD}[%d]${CLR_RESET} %-14s %-32s ${CLR_YELLOW}%-12s${CLR_RESET} %s\n" "${idx}" "${cid:0:12}" "${name:0:32}" "${st}" "${folder}"
    idx=$(( idx + 1 ))
  done
fi
echo ""

TOTAL_DEFUNCT=${#ORPHANED_CONTAINERS[@]}
TOTAL_STOPPED=${#STOPPED_PROJECT_CONTAINERS[@]}

# If nothing to clean at all
if [ "${TOTAL_DEFUNCT}" -eq 0 ] && [ "${TOTAL_STOPPED}" -eq 0 ]; then
  echo -e "${CLR_GREEN}✓ Environment is clean! Only active running containers exist.${CLR_RESET}"
  exit 0
fi

# Dry run mode
if [ "${DRY_RUN}" = "true" ]; then
  echo -e "${CLR_YELLOW}[DRY-RUN] Found ${TOTAL_DEFUNCT} defunct/orphaned container(s) and ${TOTAL_STOPPED} stopped project container(s).${CLR_RESET}"
  echo -e "${CLR_YELLOW}[DRY-RUN] No changes were made.${CLR_RESET}"
  exit 0
fi

TARGET_CIDS_TO_REMOVE=()

# CLI flag dispatch
if [ "${ORPHANED_ONLY}" = "true" ]; then
  for item in "${ORPHANED_CONTAINERS[@]}"; do
    IFS="|" read -r cid _ _ _ <<< "${item}"
    TARGET_CIDS_TO_REMOVE+=("${cid}")
  done
elif [ "${ALL_STOPPED}" = "true" ]; then
  for item in "${ORPHANED_CONTAINERS[@]}" "${STOPPED_PROJECT_CONTAINERS[@]}"; do
    IFS="|" read -r cid _ _ _ <<< "${item}"
    TARGET_CIDS_TO_REMOVE+=("${cid}")
  done
else
  # Interactive mode selection
  echo -e "${CLR_BOLD}Choose a cleanup action:${CLR_RESET}"
  echo -e "  ${CLR_BOLD}[1] 🧹 Clean only defunct/orphaned containers (${TOTAL_DEFUNCT} items)${CLR_RESET}"
  echo -e "      ${CLR_DIM}Preserves all stopped project containers for folders that exist on disk.${CLR_RESET}"
  echo -e "  ${CLR_BOLD}[2] 🎯 Selectively pick stopped containers to delete (from list above)${CLR_RESET}"
  echo -e "      ${CLR_DIM}Enter specific numbers to remove only unwanted past builds.${CLR_RESET}"
  echo -e "  ${CLR_BOLD}[3] 💥 Clean ALL stopped & orphaned containers ($(( TOTAL_DEFUNCT + TOTAL_STOPPED )) items)${CLR_RESET}"
  echo -e "      ${CLR_DIM}Full reset of stopped environments.${CLR_RESET}"
  echo -e "  ${CLR_BOLD}[4] ❌ Cancel (Do nothing)${CLR_RESET}"
  echo ""
  
  read -r -p "Select option [1-4]: " menu_choice
  case "${menu_choice}" in
    1)
      for item in "${ORPHANED_CONTAINERS[@]}"; do
        IFS="|" read -r cid _ _ _ <<< "${item}"
        TARGET_CIDS_TO_REMOVE+=("${cid}")
      done
      ;;
    2)
      if [ "${TOTAL_STOPPED}" -eq 0 ]; then
        echo "No stopped project containers available for selective removal."
        exit 0
      fi
      echo ""
      read -r -p "Enter numbers to remove (e.g. '1, 3' or 'all', 'q' to cancel): " selection
      if [[ "${selection}" =~ ^[Qq]$ ]] || [ -z "${selection}" ]; then
        echo "Cancelled."
        exit 0
      fi

      if [ "${selection}" = "all" ]; then
        for item in "${STOPPED_PROJECT_CONTAINERS[@]}"; do
          IFS="|" read -r cid _ _ _ <<< "${item}"
          TARGET_CIDS_TO_REMOVE+=("${cid}")
        done
      else
        IFS=',' read -ra NUMS <<< "${selection}"
        for num in "${NUMS[@]}"; do
          num=$(echo "${num}" | tr -d ' ')
          if [[ "${num}" =~ ^[0-9]+$ ]] && [ "${num}" -ge 1 ] && [ "${num}" -le "${TOTAL_STOPPED}" ]; then
            idx_zero=$(( num - 1 ))
            IFS="|" read -r cid _ _ _ <<< "${STOPPED_PROJECT_CONTAINERS[${idx_zero}]}"
            TARGET_CIDS_TO_REMOVE+=("${cid}")
          else
            echo -e "${CLR_YELLOW}Warning: Ignoring invalid selection '${num}'.${CLR_RESET}"
          fi
        done
      fi
      ;;
    3)
      for item in "${ORPHANED_CONTAINERS[@]}" "${STOPPED_PROJECT_CONTAINERS[@]}"; do
        IFS="|" read -r cid _ _ _ <<< "${item}"
        TARGET_CIDS_TO_REMOVE+=("${cid}")
      done
      ;;
    4|q|Q|*)
      echo "Cleanup cancelled."
      exit 0
      ;;
  esac
fi

# Remove duplicates
UNIQUE_CIDS=($(printf "%s\n" "${TARGET_CIDS_TO_REMOVE[@]:-}" | sort -u | sed '/^$/d'))

if [ ${#UNIQUE_CIDS[@]} -eq 0 ] && [ "${PRUNE_IMAGES}" = "false" ]; then
  echo -e "${CLR_YELLOW}No containers selected for removal.${CLR_RESET}"
  exit 0
fi

# Confirmation prompt if not forced
if [ "${FORCE}" != "true" ]; then
  echo ""
  echo -e "${CLR_BOLD}Confirmation:${CLR_RESET} Will remove ${#UNIQUE_CIDS[@]} container(s)."
  read -r -p "Proceed with deletion? [Y/n]: " confirm
  confirm="${confirm:-y}"
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# Perform removal
REMOVED_COUNT=0
for cid in "${UNIQUE_CIDS[@]}"; do
  c_name=$(docker inspect "${cid}" --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || echo "${cid:0:12}")
  echo -n "Removing container ${c_name} (${cid:0:12})... "
  if docker rm -f "${cid}" >/dev/null 2>&1; then
    echo -e "${CLR_GREEN}done.${CLR_RESET}"
    REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
  else
    echo -e "${CLR_RED}failed.${CLR_RESET}"
  fi
done

# Prune intermediate images if requested
if [ "${PRUNE_IMAGES}" = "true" ]; then
  echo -n "Pruning dangling build images... "
  docker image prune -f --filter "dangling=true" >/dev/null 2>&1 || true
  docker image prune -a -f --filter "label=org.opencontainers.image.title=antigravity-sandbox" >/dev/null 2>&1 || true
  echo -e "${CLR_GREEN}done.${CLR_RESET}"
fi

echo ""
echo -e "${CLR_GREEN}${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✓ Pruning complete: removed ${REMOVED_COUNT} container(s).${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}  ✓ Active and preserved project containers remain intact.${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}═════════════════════════════════════════════════════════════${CLR_RESET}"
