#!/usr/bin/env bash
# ==============================================================================
# AFFiNE MCP Onboarding and Diagnostics Wizard
# Configures Model Context Protocol connection to AFFiNE Cloud or Self-Hosted
# ==============================================================================

set -e

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_RED="\033[1;31m"

print_header() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "================================================================================"
    echo "         AFFiNE MCP Configuration Wizard — Antigravity Sandbox                 "
    echo "================================================================================"
    echo -e "${CLR_RESET}"
}

check_dependencies() {
    if ! command -v affine-mcp >/dev/null 2>&1; then
        echo -e "${CLR_RED}Error: affine-mcp is not installed or not in PATH.${CLR_RESET}" >&2
        echo "Please verify that the affine-mcp container image was built properly." >&2
        exit 1
    fi
}

show_status() {
    echo -e "${CLR_BOLD}Current Connection Status:${CLR_RESET}"
    affine-mcp status 2>/dev/null || echo -e "${CLR_YELLOW}No active AFFiNE connection configured yet.${CLR_RESET}"
    echo ""
}

setup_affine_cloud() {
    echo -e "\n${CLR_YELLOW}${CLR_BOLD}--- AFFiNE Cloud Setup (https://app.affine.pro) ---${CLR_RESET}"
    echo -e "AFFiNE Cloud uses Cloudflare Turnstile protection, requiring a browser session Cookie.\n"
    echo -e "${CLR_BOLD}How to extract your Cookie header:${CLR_RESET}"
    echo "  1. Open your browser and navigate to https://app.affine.pro"
    echo "  2. Sign in to your AFFiNE account."
    echo "  3. Press F12 to open Developer Tools, then switch to the 'Network' tab."
    echo "  4. Click on any document or refresh the page to capture network requests."
    echo "  5. Select any request targeting 'app.affine.pro' (e.g. /graphql or workspace API)."
    echo "  6. In 'Request Headers', find and copy the entire 'Cookie' string (affine_session=...)."
    echo ""

    read -r -p "Launch interactive login now? [Y/n]: " choice
    choice="${choice:-y}"

    if [[ "${choice}" =~ ^[Yy]$ ]]; then
        echo -e "\n${CLR_CYAN}Starting interactive login... When prompted, enter 'https://app.affine.pro' and paste your Cookie.${CLR_RESET}"
        affine-mcp login
    else
        echo -e "\nEnter Cookie directly (input will be hidden):"
        read -r -s cookie_val
        echo ""

        if [ -z "${cookie_val}" ]; then
            echo -e "${CLR_RED}Error: Empty cookie provided. Aborted.${CLR_RESET}" >&2
            return 1
        fi

        read -r -p "Enter Workspace ID (press Enter to auto-discover): " ws_id
        if [ -n "${ws_id}" ]; then
            printf "%s" "${cookie_val}" | affine-mcp login --url "https://app.affine.pro" --cookie-stdin --workspace-id "${ws_id}" --force
        else
            printf "%s" "${cookie_val}" | affine-mcp login --url "https://app.affine.pro" --cookie-stdin --force
        fi
    fi

    echo -e "\n${CLR_CYAN}Running diagnostics to verify connectivity...${CLR_RESET}"
    affine-mcp doctor
    echo -e "\n${CLR_GREEN}✓ AFFiNE Cloud connection configured successfully!${CLR_RESET}"
}

setup_self_hosted() {
    echo -e "\n${CLR_YELLOW}${CLR_BOLD}--- Self-Hosted AFFiNE Setup ---${CLR_RESET}"
    echo "You will be prompted for your external AFFiNE instance URL and credentials."
    echo "Example URL: https://affine.your-domain.com"
    echo ""
    affine-mcp login
    echo -e "\n${CLR_CYAN}Running diagnostics to verify connectivity...${CLR_RESET}"
    affine-mcp doctor
    echo -e "\n${CLR_GREEN}✓ Self-Hosted AFFiNE connection configured successfully!${CLR_RESET}"
}

switch_workspace() {
    echo -e "\n${CLR_CYAN}${CLR_BOLD}Available Workspaces:${CLR_RESET}"
    affine-mcp workspaces || true
    echo ""
    read -r -p "Enter Workspace ID to switch default scope (or press Enter to cancel): " target_ws
    if [ -n "${target_ws}" ]; then
        affine-mcp workspace "${target_ws}"
        echo -e "${CLR_GREEN}✓ Active workspace updated!${CLR_RESET}"
    fi
}

run_diagnostics() {
    echo -e "\n${CLR_CYAN}${CLR_BOLD}Running AFFiNE Doctor Check:${CLR_RESET}"
    affine-mcp doctor
}

show_menu() {
    while true; do
        print_header
        show_status
        echo -e "${CLR_BOLD}Choose an action:${CLR_RESET}"
        echo "  1) Connect to AFFiNE Cloud (https://app.affine.pro) [Recommended]"
        echo "  2) Connect to Self-Hosted AFFiNE"
        echo "  3) Run Connectivity Diagnostics (affine-mcp doctor)"
        echo "  4) List / Switch Workspaces"
        echo "  5) Show Configuration Details"
        echo "  6) Exit"
        echo ""
        read -r -p "Enter selection [1-6]: " opt
        case "${opt}" in
            1)
                setup_affine_cloud
                read -r -p "Press Enter to return to menu..."
                ;;
            2)
                setup_self_hosted
                read -r -p "Press Enter to return to menu..."
                ;;
            3)
                run_diagnostics
                read -r -p "Press Enter to return to menu..."
                ;;
            4)
                switch_workspace
                read -r -p "Press Enter to return to menu..."
                ;;
            5)
                echo -e "\n${CLR_CYAN}${CLR_BOLD}Configuration Details:${CLR_RESET}"
                affine-mcp show-config
                read -r -p "Press Enter to return to menu..."
                ;;
            6|q|Q)
                echo "Exiting wizard."
                break
                ;;
            *)
                echo -e "${CLR_RED}Invalid selection.${CLR_RESET}"
                sleep 1
                ;;
        esac
    done
}

check_dependencies

if [ "$1" = "--doctor" ]; then
    run_diagnostics
elif [ "$1" = "--cloud" ]; then
    setup_affine_cloud
elif [ "$1" = "--self-hosted" ]; then
    setup_self_hosted
elif [ "$1" = "--status" ]; then
    show_status
elif [ "$1" = "--workspaces" ]; then
    switch_workspace
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: affine-setup [OPTION]"
    echo "Options:"
    echo "  --cloud        Connect to AFFiNE Cloud"
    echo "  --self-hosted  Connect to Self-Hosted AFFiNE"
    echo "  --status       Show current connection status"
    echo "  --doctor       Run connectivity diagnostics"
    echo "  --workspaces   List or switch default workspace"
    echo "  --help         Show this help message"
    echo "  (no arguments) Launch interactive wizard menu"
else
    show_menu
fi
