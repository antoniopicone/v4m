#!/bin/bash
# v4m - Core functions and utilities

# Load configuration
load_config() {
    local config_file="$SCRIPT_DIR/config.ini"
    
    if [ ! -f "$config_file" ]; then
        echo "Error: Configuration file not found at $config_file" >&2
        exit 1
    fi
    
    # Parse INI file and export variables
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ $key =~ ^[[:space:]]*$ ]] && continue
        [[ $key =~ ^\[.*\]$ ]] && continue
        
        # Clean key and value
        key=$(echo "$key" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')
        
        # Skip if key is empty
        [ -z "$key" ] && continue
        
        # Evaluate variables like $HOME
        value=$(eval echo "$value" 2>/dev/null || echo "$value")
        
        export "$key"="$value"
    done < "$config_file"
}

cleanup() {
    tput cnorm 2>/dev/null || true
}

show_spinner() {
    local message="$1"
    local duration="${2:-30}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_length=${#spin}
    
    tput civis >&2
    for i in $(seq 1 $duration); do
        local spinner_char=$((i % spin_length))
        printf "\r${BLUE}${spin:$spinner_char:1}${NC} $message " >&2
        sleep 0.033
    done
    tput cnorm >&2
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This operation requires sudo privileges"
        exit 1
    fi
}

init_dirs() {
    mkdir -p "$IMAGES_DIR" "$VMS_DIR"
}

generate_vm_name() {
    local adjectives=($adjectives)
    local nouns=($nouns)
    local adj=${adjectives[$RANDOM % ${#adjectives[@]}]}
    local noun=${nouns[$RANDOM % ${#nouns[@]}]}
    local num=$((RANDOM % 100))
    echo "${adj}-${noun}-${num}"
}

generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

sanitize_vm_name() {
    local name="$1"
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g'
}

generate_mac() {
    printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Generate IP address from MAC address last octet
mac_to_ip() {
    local mac="$1"
    
    # Extract last octet from MAC (format: 52:54:00:xx:xx:xx)
    local last_octet=$(echo "$mac" | cut -d':' -f6)
    
    # Convert hex to decimal
    local decimal_octet=$((16#$last_octet))
    
    # Ensure IP is in valid range (10-254) to avoid conflicts with gateway (1) and broadcast (255)
    # If the octet is 0-9, add 10. If it's 255, use 254
    if [ $decimal_octet -lt 10 ]; then
        decimal_octet=$((decimal_octet + 10))
    elif [ $decimal_octet -eq 255 ]; then
        decimal_octet=254
    fi
    
    # Return full IP address
    echo "${base_ip}.${decimal_octet}"
}

hash_password() {
    local password="$1"
    openssl passwd -6 "$password"
}

get_vm_ip() {
    local vm_name="$1"
    
    # Try mDNS resolution first (most reliable with avahi-daemon)
    local ip=""
    if ping -c 1 -W 1000 "$vm_name.local" >/dev/null 2>&1; then
        ip=$(ping -c 1 "$vm_name.local" 2>/dev/null | head -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
        if [ -n "$ip" ]; then
            echo "$ip"
            return
        fi
    fi
    
    # Fallback: try to find VM's MAC address and look it up in ARP table
    local vm_dir="$VMS_DIR/$vm_name"
    if [ -f "$vm_dir/vm-info.json" ]; then
        local vm_mac=$(grep '"mac"' "$vm_dir/vm-info.json" | cut -d'"' -f4)
        if [ -n "$vm_mac" ]; then
            # Look up MAC address in ARP table
            ip=$(arp -a | grep -i "$vm_mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            if [ -n "$ip" ]; then
                echo "$ip"
                return
            fi
        fi
    fi
    
    # No IP found
    echo ""
}

get_vm_disk_info() {
    local vm_dir="$1"
    local vm_disk="$vm_dir/disk.qcow2"
    local size_info=""
    local usage_info=""
    
    if [ -f "$vm_disk" ]; then
        # Get actual disk size (allocated)
        usage_info=$(du -h "$vm_disk" 2>/dev/null | cut -f1)
        
        # Get virtual disk size using qemu-img info
        if command -v qemu-img >/dev/null 2>&1; then
            size_info=$(qemu-img info "$vm_disk" 2>/dev/null | grep 'virtual size' | cut -d'(' -f2 | cut -d' ' -f1)
            # Convert bytes to human readable if it's just a number
            if [[ "$size_info" =~ ^[0-9]+$ ]]; then
                size_info=$(echo "$size_info" | awk '{print ($1/1024/1024/1024)"G"}')
            fi
        fi
        
        # Fallback to configured size if qemu-img fails
        if [ -z "$size_info" ]; then
            size_info="20G"  # Default size
        fi
    else
        size_info="-"
        usage_info="-"
    fi
    
    echo "$size_info|$usage_info"
}

show_help() {
    echo "v4m - VM Manager for macOS"
    echo
    echo "Usage: v4m <command> [options]"
    echo
    echo "Setup Commands:"
    echo "  v4m_init [--deps-only] [--dhcp-only] [--check]  Complete setup with options"
    echo "  init                        Initialize socket_vmnet only (basic setup)"
    echo
    echo "VM Commands:"
    echo "  vm create [--name NAME] [--image IMAGE] [--user USER] [--pass PASS]"
    echo "  vm list                     List all VMs with status and IPs"
    echo "  vm start <name>             Start a VM (no sudo required after init)"
    echo "  vm stop <name>              Stop a VM"
    echo "  vm delete <name>            Delete a VM"
    echo "  vm ip <name>                Get VM IP address"
    echo "  vm console <name>           Connect to VM console (Ctrl+C to exit)"
    echo
    echo "Image Commands:"
    echo "  image list                  List available images"
    echo "  image pull <image>          Download an image"
    echo "  image delete <image>        Delete an image"
    echo
    echo "Cleanup Commands:"
    echo "  purge                       Delete ALL VMs and images (requires confirmation)"
    echo
    echo "Available images: debian12, ubuntu22, ubuntu24"
    echo
    echo "DHCP Fix Explanation:"
    echo "  v4m_init fixes macOS firewall blocking DHCP by:"
    echo "  - Allowing bootpd (DHCP server) through firewall"
    echo "  - Restarting macOS DHCP service"
    echo "  - Configuring socket_vmnet properly"
    echo "  This ensures VMs get IPv4 addresses automatically"
    echo
    echo "Examples:"
    echo "  v4m v4m_init                          # Complete setup (recommended first run)"
    echo "  v4m v4m_init --check                  # Check current setup status"
    echo "  v4m vm create                         # Create VM with random name (auto-setup if needed)"
    echo "  v4m vm create --name myvm --image debian12  # Create VM with specific name and image"
    echo "  v4m vm list                           # List all VMs with IPs"
    echo "  v4m vm console myvm                   # Connect to VM console (auto-setup if needed)"
    echo "  v4m purge                             # Delete everything (requires 'DELETE ALL')"
    echo "  ssh user01@myvm.local                 # SSH to VM (after setup)"
}