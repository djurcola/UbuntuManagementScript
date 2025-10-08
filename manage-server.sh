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

# --- Action: Install Dockge ---
function install_dockge() {
    echo -e "\n${GREEN}--- Starting Dockge Installation ---${NC}"

    # Prerequisite check: Ensure Docker is installed and running
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed. Please install Docker first (Option 4).${NC}"
        return 1
    fi
    if ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker daemon is not running. Please start Docker.${NC}"
        return 1
    fi

    echo "Creating directories for stacks and Dockge configuration..."
    mkdir -p /opt/stacks /opt/dockge

    echo "Downloading Dockge compose.yaml to /opt/dockge/..."
    # Using full path for output is safer than using 'cd'
    curl -fsSL https://raw.githubusercontent.com/louislam/dockge/master/compose.yaml --output /opt/dockge/compose.yaml

    echo "Starting Dockge server via Docker Compose..."
    # Use -f to specify the compose file path explicitly    
    docker compose -f /opt/dockge/compose.yaml up -d

    echo -e "\nDockge has been started successfully."
    echo -e "You should be able to access it at: ${YELLOW}http://<your-server-ip>:5001${NC}"
    echo -e "${GREEN}--- Dockge Installation Complete ---${NC}"
}

# --- Action: Update Dockge ---
function update_dockge() {
    echo -e "\n${GREEN}--- Updating Dockge ---${NC}"
    local DOCKGE_DIR="/opt/dockge"
    local DOCKGE_COMPOSE_FILE="${DOCKGE_DIR}/compose.yaml"

    # Prerequisite check
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or running.${NC}"; return 1;
    fi
    if [ ! -f "${DOCKGE_COMPOSE_FILE}" ]; then
        echo -e "${RED}Error: Dockge compose file not found at '${DOCKGE_COMPOSE_FILE}'. Is Dockge installed?${NC}"; return 1;
    fi

    echo "Pulling the latest Dockge image..."
    # Use --project-directory for safety; it avoids 'cd'
    docker compose --project-directory "${DOCKGE_DIR}" pull

    echo "Recreating the Dockge container with the new image..."
    docker compose --project-directory "${DOCKGE_DIR}" up -d
    
    echo -e "${GREEN}--- Dockge update complete ---${NC}"
    echo -e "${YELLOW}Note: Old images may still exist. You can clean them up using the 'Docker System Prune' option.${NC}"
}

# --- Action: Docker System Prune ---
function docker_system_prune() {
    echo -e "\n${GREEN}--- Docker System Prune ---${NC}"
    
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or running.${NC}"; return 1;
    fi

    echo -e "${YELLOW}This will remove all unused Docker data, including:"
    echo "  - All stopped containers"
    echo "  - All networks not used by at least one container"
    echo "  - All build cache"
    echo "  - All dangling images (and optionally all unused images)"
    echo -e "${NC}"
    read -rp "Do you want to remove ALL unused images (not just dangling ones)? This is more thorough. [y/N]: " prune_all
    
    if [[ "$prune_all" =~ ^[Yy]$ ]]; then
        echo "Pruning all unused images and other data..."
        docker system prune -a -f
    else
        echo "Pruning dangling images and other data..."
        docker system prune -f
    fi
    
    echo -e "${GREEN}--- Docker prune complete ---${NC}"
}

# --- Action: Install Tailscale ---
function install_tailscale() {
    echo -e "\n${GREEN}--- Starting Tailscale Installation ---${NC}"

    # Check if Tailscale is already installed
    if command -v tailscale &> /dev/null; then
        echo -e "${YELLOW}Tailscale is already installed. Proceeding to connect...${NC}"
    else
        echo "Tailscale not found. Installing for Ubuntu 24.04 (Noble)..."
        
        # 1. Add Tailscale's GPG key and repository
        echo "Adding Tailscale's repository..."
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

        # 2. Install Tailscale
        echo "Updating package list and installing Tailscale..."
        apt-get update -y
        apt-get install -y tailscale
        echo -e "${GREEN}Tailscale package installed successfully.${NC}"
    fi

    # 3. Connect the machine to your Tailnet (interactive part)
    echo -e "\n${YELLOW}---> ACTION REQUIRED <---${NC}"
    echo "The next step will generate a URL to authenticate this server."
    echo "Please copy the URL, paste it into a browser, and log in to your Tailscale account."
    
    # Run the command that prompts for authentication
    tailscale up

    # 4. Wait for user confirmation
    echo ""
    read -rp "After you have successfully authenticated in your browser, press [Enter] to continue..."

    # 5. Print the Tailscale IP address
    echo -e "\nFetching your Tailscale IP address..."
    TS_IP=$(tailscale ip -4)
    echo -e "Successfully connected! Your Tailscale IPv4 address is: ${YELLOW}${TS_IP}${NC}"
    echo -e "${GREEN}--- Tailscale Setup Complete ---${NC}"
}

# --- Helper function for updating a single Docker Compose application ---
function perform_compose_update() {
    local app_dir="$1"
    local app_name
    app_name=$(basename "${app_dir}")
    
    echo -e "\n${GREEN}--- Updating application: ${app_name} ---${NC}"
    echo "Directory: ${app_dir}"

    echo "Pulling latest images..."
    docker compose --project-directory "${app_dir}" pull

    echo "Recreating containers with new images..."
    # --remove-orphans cleans up containers for services that no longer exist
    docker compose --project-directory "${app_dir}" up -d --remove-orphans
    
    echo -e "${GREEN}--- Update for ${app_name} complete ---${NC}"
}

# --- Action: Update Docker Applications ---
function update_docker_apps() {
    echo -e "\n${GREEN}--- Update Docker Compose Applications ---${NC}"
    
    # Prerequisite check
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or running. Please use Option 4 first.${NC}"; return 1;
    fi

    echo "Searching for running Docker Compose applications..."
    
    # Find all unique directories of running containers managed by docker-compose
    # This works by inspecting each running container for the 'com.docker.compose.project.working_dir' label
    local compose_dirs
    mapfile -t compose_dirs < <(docker ps -q | xargs docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null | grep -v '^$' | sort -u)

    if [ ${#compose_dirs[@]} -eq 0 ]; then
        echo -e "${YELLOW}No running Docker Compose applications found.${NC}"
        return
    fi
    
    echo "Found the following applications:"
    local options=("Update All" "${compose_dirs[@]}" "Cancel")

    # Present a dynamic menu to the user
    select opt in "${options[@]}"; do
        case $opt in
            "Update All")
                for dir in "${compose_dirs[@]}"; do
                    perform_compose_update "${dir}"
                done
                break
                ;;
            "Cancel")
                echo "Update cancelled."
                break
                ;;
            *)
                if [[ -n "$opt" ]]; then
                    perform_compose_update "${opt}"
                else
                    echo -e "${RED}Invalid selection. Please try again.${NC}"
                fi
                break
                ;;
        esac
    done
}

# --- Action: Run all actions ---
function run_all_actions() {
    echo -e "\n${YELLOW}===== RUNNING ALL ACTIONS =====${NC}"
    update_system
    setup_unattended_upgrades
    install_docker
    # Note: Application installs are not included in "Run All" by default.
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
        echo -e "  --- System & Maintenance ---"
        echo -e "${YELLOW}1) Run All Actions (Update, Unattended Upgrades, Docker)${NC}"
        echo "----------------------------------------"
        echo "2) Update the System"
        echo "3) Setup Unattended Upgrades"
        echo ""
        echo "  --- Docker Management ---"
        echo "4) Install Docker"
        echo "5) Install Dockge (Requires Docker)"
        echo "6) Update Dockge"
        echo "7) Update Other Docker Apps (Compose)"
        echo "8) Docker System Prune (Cleanup)"
        echo ""
        echo "  --- Network Tools ---"
        echo "9) Install/Connect Tailscale"
        echo "----------------------------------------"
        echo -e "${RED}q) Quit${NC}"
        echo "========================================"
        read -rp "Enter your choice: " choice

        case $choice in
            1) run_all_actions ;;
            2) update_system ;;
            3) setup_unattended_upgrades ;;
            4) install_docker ;;
            5) install_dockge ;;
            6) update_dockge ;;
            7) update_docker_apps ;;
            8) docker_system_prune ;;
            9) install_tailscale ;;
            q|Q) break ;;
            *) echo -e "\n${RED}Invalid option. Please try again.${NC}" ;;
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