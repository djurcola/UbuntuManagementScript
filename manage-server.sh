#!/bin/bash

# ==============================================================================
# Ubuntu Server Management Script
#
# A menu-driven script to perform common server maintenance tasks.
# To add a new action:
#   1. Create a new function for your action (e.g., my_new_action()).
#   2. Add an option for it in the main_menu() function's 'echo' block.
#   3. Add a case for it in the main_menu() function's 'case' statement.
#   4. If you want it to run as part of "Run All", add it to run_all_actions().
# ==============================================================================

# --- Script Configuration & Safety ---

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Exit status of a pipeline is the status of the last command to exit with a
# non-zero status, or zero if no command exited with a non-zero status.
set -o pipefail

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Prerequisite Check ---

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root. Please use sudo.${NC}"
   exit 1
fi


# ==============================================================================
# --- ACTION FUNCTIONS ---
# Each function represents a specific action the user can choose.
# ==============================================================================

# --- Action: Update the system ---
function update_system() {
    echo -e "\n${GREEN}--- Starting System Update ---${NC}"
    echo "Updating package lists..."
    apt-get update -y
    
    echo "Upgrading installed packages..."
    # Use DEBIAN_FRONTEND to avoid interactive prompts during upgrade
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    
    echo "Cleaning up unused packages..."
    apt-get autoremove -y
    apt-get clean
    echo -e "${GREEN}--- System Update Complete ---${NC}"
}

# --- Action: Set the system to run unattended upgrades ---
function setup_unattended_upgrades() {
    echo -e "\n${GREEN}--- Setting Up Unattended Upgrades ---${NC}"
    echo "Updating package lists..."
    apt-get update -y
    
    echo "Installing unattended-upgrades package..."
    apt-get install -y unattended-upgrades
    
    echo "Configuring unattended-upgrades to run automatically..."
    # The DEBIAN_FRONTEND variable prevents the configuration dialog from appearing
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure --priority=low unattended-upgrades
    
    echo "Unattended upgrades configuration complete. Checking status:"
    # Use --no-pager to print status directly to the console without opening a pager
    systemctl status unattended-upgrades --no-pager
    echo -e "${GREEN}--- Unattended Upgrades Setup Complete ---${NC}"
}

# --- Action: Install Docker ---
function install_docker() {
    echo -e "\n${GREEN}--- Starting Docker Installation ---${NC}"

    # 1. Remove conflicting packages
    echo "Removing any conflicting old Docker packages..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        if dpkg -l | grep -q -w "$pkg"; then
            apt-get remove -y "$pkg"
        else
            echo "Package $pkg not found, skipping."
        fi
    done
    apt-get autoremove -y

    # 2. Setup Docker's APT Repository
    echo "Setting up Docker's APT repository..."
    apt-get update -y
    apt-get install -y ca-certificates curl
    
    install -m 0755 -d /etc/apt/keyrings
    # Use -f to overwrite if file exists, ensures idempotency
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources, overwriting if it exists
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y

    # 3. Install Docker Engine
    echo "Installing Docker packages..."
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # 4. Verify installation and start service
    echo "Verifying Docker service status..."
    if ! systemctl is-active --quiet docker; then
        echo "Docker service is not running. Starting and enabling it now..."
        systemctl start docker
        systemctl enable docker
    else
        echo "Docker service is already running."
    fi
    
    echo "Current Docker status:"
    systemctl status docker --no-pager
    echo -e "${GREEN}--- Docker Installation Complete ---${NC}"
}

# --- Action: Run all actions ---
function run_all_actions() {
    echo -e "\n${YELLOW}===== RUNNING ALL ACTIONS =====${NC}"
    update_system
    setup_unattended_upgrades
    install_docker
    echo -e "\n${YELLOW}===== ALL ACTIONS COMPLETED =====${NC}"
}


# ==============================================================================
# --- MENU AND SCRIPT LOGIC ---
# ==============================================================================

function main_menu() {
    while true; do
        # Clear the screen for a clean menu display
        clear
        echo "========================================"
        echo "      Ubuntu Server Management"
        echo "========================================"
        echo -e "${YELLOW}1) Run All Actions${NC}"
        echo "----------------------------------------"
        echo "2) Update the System"
        echo "3) Setup Unattended Upgrades"
        echo "4) Install Docker"
        echo "----------------------------------------"
        echo -e "${RED}q) Quit${NC}"
        echo "========================================"
        read -rp "Enter your choice: " choice

        case $choice in
            1)
                run_all_actions
                ;;
            2)
                update_system
                ;;
            3)
                setup_unattended_upgrades
                ;;
            4)
                install_docker
                ;;
            q|Q)
                break
                ;;
            *)
                echo -e "\n${RED}Invalid option. Please try again.${NC}"
                ;;
        esac

        # Pause and wait for the user to press Enter before showing the menu again
        echo ""
        read -rp "Press [Enter] to return to the menu..."
    done
}

# --- Script Entry Point ---
main_menu
echo -e "\n${GREEN}Exiting script. Goodbye!${NC}\n"
exit 0