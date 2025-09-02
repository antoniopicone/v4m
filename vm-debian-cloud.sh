#!/bin/bash

# Script to run Debian VMs with cloud-init on macOS
# Uses your user-data.yaml and meta-data.yaml files

set -e

# Configuration
VM_NAME="debian-vm"
VM_MEMORY="4096"
VM_CPUS="4"
VM_DISK_SIZE="20G"
VM_MAC_FILE=".vm_mac"
VM_LOG_FILE="${VM_NAME}-console.log"
VM_MONITOR_SOCKET=".vm_monitor"

# File paths - Use stable Debian 12 instead of unstable 13 (trixie)
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2"
CLOUD_IMAGE="debian-12-generic-arm64.qcow2"
VM_DISK="${VM_NAME}.qcow2"
CLOUD_INIT_ISO="${VM_NAME}-cloud-init.iso"

# Cloud-init files directory
USER_DATA_FILE="./user-data.yaml"
META_DATA_FILE="./meta-data.yaml"

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Generate random MAC address
generate_mac_address() {
    printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Get or generate MAC address
get_vm_mac() {
    if [ -f "$VM_MAC_FILE" ]; then
        cat "$VM_MAC_FILE"
    else
        local mac=$(generate_mac_address)
        echo "$mac" > "$VM_MAC_FILE"
        echo "$mac"
    fi
}

# Boot spinner
show_spinner() {
    local pid=$1
    local message=$2
    local spin='|/-\'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${BLUE}[INFO]${NC} $message ${spin:$i:1}"
        sleep 0.1
    done
    printf "\r${GREEN}[SUCCESS]${NC} $message ✓\n"
}

# Extract IP from VM log
extract_ip_from_log() {
    local log_file=$1
    local ip=""
    
    # Look for cloud-init Net device info format first
    # Example: | enp0s1 | True |       192.168.68.15        | 255.255.255.0 | global | 52:54:00:45:f7:82 |
    if grep -q "Net device info" "$log_file" 2>/dev/null; then
        # Find line with enp0s1 (or eth0) containing the main IP
        ip=$(grep -E '\|\s*(enp0s1|eth0)\s*\|\s*True\s*\|' "$log_file" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '255\.255\.255' | head -1)
    fi
    
    # Try alternative patterns if not found with cloud-init
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    fi
    
    # DHCP pattern
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'bound to ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | head -1 | cut -d' ' -f3)
    fi
    
    # Generic IP address pattern
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'IP address: ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | head -1 | cut -d':' -f2 | tr -d ' ')
    fi
    
    # Address pattern (excluding localhost)
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'address ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    fi
    
    echo "$ip"
}

# Send QEMU command via monitor
send_qemu_command() {
    local command="$1"
    
    if [ ! -S "$VM_MONITOR_SOCKET" ]; then
        log_error "QEMU monitor socket not found: $VM_MONITOR_SOCKET"
        return 1
    fi
    
    # Use socat to send commands to monitor socket
    if command -v socat >/dev/null 2>&1; then
        echo "$command" | socat - "UNIX-CONNECT:$VM_MONITOR_SOCKET" 2>/dev/null
        return $?
    else
        # Fallback to nc if socat unavailable
        if command -v nc >/dev/null 2>&1; then
            echo "$command" | nc -U "$VM_MONITOR_SOCKET" 2>/dev/null
            return $?
        else
            log_error "Neither socat nor nc available for QEMU monitor communication"
            return 1
        fi
    fi
}

# Graceful shutdown via QEMU monitor
qemu_graceful_shutdown() {
    # Send system_powerdown command (equivalent to pressing power button)
    if send_qemu_command "system_powerdown"; then
        return 0
    else
        return 1
    fi
}

# Find or configure SSH key
get_ssh_key() {
    # Use saved key if available
    if [ -f "$VM_SSH_KEY_FILE" ]; then
        local saved_key=$(cat "$VM_SSH_KEY_FILE")
        if [ -f "$saved_key" ]; then
            echo "$saved_key"
            return 0
        else
            rm -f "$VM_SSH_KEY_FILE"
        fi
    fi
    
    # Auto-detect SSH keys in common locations
    # Use original user's home if running under sudo
    local user_home="$HOME"
    if [ -n "$SUDO_USER" ]; then
        user_home=$(eval echo "~$SUDO_USER")
    fi
    
    local common_keys=(
        "$user_home/.ssh/id_ed25519"
        "$user_home/.ssh/id_rsa"
        "$user_home/.ssh/id_ecdsa"
        "$user_home/.ssh/vm_key"
        "$user_home/.ssh/debian_vm"
    )
    
    for key in "${common_keys[@]}"; do
        if [ -f "$key" ]; then
            echo "$key" > "$VM_SSH_KEY_FILE"
            echo "$key"
            return 0
        fi
    done
    
    return 1
}

# Configure SSH key interactively
configure_ssh_key() {
    # Check if running non-interactively
    if [ ! -t 0 ] || [ -n "$SUDO_USER" ]; then
        log_error "Cannot configure SSH key in non-interactive mode"
        log_info "Run without sudo or manually configure:"
        log_info "   echo '/path/to/your/ssh/key' > $VM_SSH_KEY_FILE"
        return 1
    fi
    
    echo
    log_info "SSH key configuration needed for graceful shutdown"
    echo "Common SSH key paths:"
    echo "  ~/.ssh/id_ed25519"
    echo "  ~/.ssh/id_rsa"
    echo "  ~/.ssh/vm_key"
    echo
    
    while true; do
        printf "Enter your SSH private key path: "
        read -r ssh_key_path
        
        # Expand ~ if present
        ssh_key_path="${ssh_key_path/#\~/$HOME}"
        
        if [ -f "$ssh_key_path" ]; then
            # Verify it's a valid SSH private key
            if timeout 5 ssh-keygen -l -f "$ssh_key_path" >/dev/null 2>&1; then
                echo "$ssh_key_path" > "$VM_SSH_KEY_FILE"
                log_success "SSH key configured: $ssh_key_path"
                echo "$ssh_key_path"
                return 0
            else
                log_error "File doesn't appear to be a valid SSH key"
            fi
        else
            log_error "File not found: $ssh_key_path"
        fi
        
        printf "Retry? (y/n): "
        read -r retry
        if [ "$retry" != "y" ] && [ "$retry" != "Y" ]; then
            return 1
        fi
    done
}

# Check QEMU availability
check_qemu() {
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        log_error "QEMU not found. Please install QEMU:"
        log_error "  brew install qemu"
        exit 1
    fi
}

# Download cloud image if needed
download_cloud_image() {
    if [ ! -f "$CLOUD_IMAGE" ]; then
        log_info "Downloading Debian cloud image..."
        wget -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
        log_success "Cloud image downloaded: $CLOUD_IMAGE"
    else
        log_info "Cloud image already present: $CLOUD_IMAGE"
    fi
}

# Create VM disk from cloud image
create_vm_disk() {
    if [ -f "$VM_DISK" ]; then
        log_warning "Removing existing VM disk: $VM_DISK"
        rm -f "$VM_DISK"
    fi
    
    log_info "Creating VM disk from cloud image..."
    cp "$CLOUD_IMAGE" "$VM_DISK"
    qemu-img resize "$VM_DISK" "$VM_DISK_SIZE"
    log_success "VM disk created: $VM_DISK"
}

# Create EFI variables file
create_efi_vars() {
    local efi_vars_file="/tmp/edk2-aarch64-vars-${VM_NAME}.fd"
    
    if [ ! -f "$efi_vars_file" ]; then
        if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-vars.fd" ]; then
            cp "/opt/homebrew/share/qemu/edk2-aarch64-vars.fd" "$efi_vars_file"
        else
            dd if=/dev/zero of="$efi_vars_file" bs=1M count=64 2>/dev/null
        fi
    fi
}

# Create cloud-init ISO
create_cloud_init_iso() {
    if [ ! -f "$USER_DATA_FILE" ] || [ ! -f "$META_DATA_FILE" ]; then
        log_error "Missing cloud-init files:"
        log_error "  user-data: $USER_DATA_FILE"
        log_error "  meta-data: $META_DATA_FILE"
        exit 1
    fi
    
    log_info "Creating cloud-init ISO..."
    
    temp_dir="/tmp/cloud-init-$$"
    mkdir -p "$temp_dir"
    
    # Copy cloud-init files (renaming without .yaml)
    cp "$USER_DATA_FILE" "$temp_dir/user-data"
    cp "$META_DATA_FILE" "$temp_dir/meta-data"
    
    rm -f "$CLOUD_INIT_ISO"
    
    # Create ISO with hdiutil (macOS)
    if command -v hdiutil >/dev/null 2>&1; then
        if hdiutil makehybrid -iso -joliet -default-volume-name "cidata" -o "${VM_NAME}-cloud-init" "$temp_dir" >/dev/null 2>&1; then
            # Move resulting file
            if [ -f "${VM_NAME}-cloud-init.iso" ]; then
                mv "${VM_NAME}-cloud-init.iso" "$CLOUD_INIT_ISO"
            elif [ -f "${VM_NAME}-cloud-init.dmg" ]; then
                mv "${VM_NAME}-cloud-init.dmg" "$CLOUD_INIT_ISO"
            elif [ -f "${VM_NAME}-cloud-init.cdr" ]; then
                mv "${VM_NAME}-cloud-init.cdr" "$CLOUD_INIT_ISO"
            fi
            log_success "Cloud-init ISO created: $CLOUD_INIT_ISO"
        else
            log_error "Failed to create ISO with hdiutil"
            rm -rf "$temp_dir"
            exit 1
        fi
    else
        log_error "hdiutil not available"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    rm -rf "$temp_dir"
}

# Start VM
start_vm() {
    local vm_mac=$(get_vm_mac)
    
    log_info "Starting VM: $VM_NAME"
    log_info "VM will get IP via DHCP from host network"
    
    # Check if required files exist
    if [ ! -f "$VM_DISK" ]; then
        log_error "VM disk not found: $VM_DISK"
        exit 1
    fi
    
    if [ ! -f "$CLOUD_INIT_ISO" ]; then
        log_error "Cloud-init ISO not found: $CLOUD_INIT_ISO"
        exit 1
    fi
    
    > "$VM_LOG_FILE"
    rm -f "$VM_MONITOR_SOCKET"
    
    # Start QEMU detached with monitor enabled
    nohup qemu-system-aarch64 \
      -machine virt \
      -cpu host \
      -accel hvf \
      -smp $VM_CPUS \
      -m $VM_MEMORY \
      -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on \
      -drive if=pflash,format=raw,file=/tmp/edk2-aarch64-vars-${VM_NAME}.fd \
      -drive file=$VM_DISK,format=qcow2,if=virtio \
      -drive file=$CLOUD_INIT_ISO,media=cdrom,if=virtio,readonly=on \
      -netdev vmnet-shared,id=net0 \
      -device virtio-net,netdev=net0,mac=$vm_mac \
      -monitor unix:$VM_MONITOR_SOCKET,server,nowait \
      -nographic > "$VM_LOG_FILE" 2>&1 &
    
    local qemu_pid=$!
    echo $qemu_pid > ".vm_pid"
    disown $qemu_pid
    
    # Wait for VM to boot and get IP
    local boot_ready=false
    local boot_attempts=0
    local max_boot_attempts=120
    local vm_ip=""
    
    log_info "Waiting for VM to complete boot and get IP..."
    
    while [ $boot_attempts -lt $max_boot_attempts ] && [ $boot_ready = false ]; do
        # Check if QEMU is still running
        if ! kill -0 $qemu_pid 2>/dev/null; then
            log_error "QEMU stopped unexpectedly"
            tail -20 "$VM_LOG_FILE"
            exit 1
        fi
        
        # Check if boot is complete (login prompt)
        if grep -q "login:" "$VM_LOG_FILE" 2>/dev/null; then
            boot_ready=true
            vm_ip=$(extract_ip_from_log "$VM_LOG_FILE")
        else
            # Show progress every 5 seconds
            if [ $((boot_attempts % 5)) -eq 0 ]; then
                printf "\r${BLUE}[INFO]${NC} Booting... [$boot_attempts/$max_boot_attempts]"
                local temp_ip=$(extract_ip_from_log "$VM_LOG_FILE")
                if [ -n "$temp_ip" ]; then
                    printf " (IP detected: $temp_ip)"
                fi
            fi
            sleep 1
            boot_attempts=$((boot_attempts + 1))
        fi
    done
    
    printf "\r\033[K"
    
    if [ $boot_ready = true ]; then
        log_success "VM started and ready for login!"
        
        # Final IP extraction attempt if not found during boot
        if [ -z "$vm_ip" ]; then
            vm_ip=$(extract_ip_from_log "$VM_LOG_FILE")
        fi
        
        if [ -n "$vm_ip" ]; then
            echo
            log_success "=== VM READY ==="
            echo "  SSH: ssh antonio@$vm_ip"
            echo "  MAC: $vm_mac"
            echo "  Log: $VM_LOG_FILE"
            echo "  PID: $qemu_pid"
            echo
        else
            echo
            log_success "=== VM READY ==="
            echo "  MAC: $vm_mac"
            echo "  Log: $VM_LOG_FILE"
            echo "  PID: $qemu_pid"
            echo
            log_info "IP not found. Check log: $VM_LOG_FILE or use: arp -a | grep $vm_mac"
        fi
        
        log_info "VM running in background. Use '$0 status' to check status."
    else
        log_error "Timeout: VM not ready after $max_boot_attempts seconds"
        kill $qemu_pid
        exit 1
    fi
}

# Show VM status
show_vm_status() {
    log_info "VM Status:"
    echo
    
    if [ -f ".vm_pid" ]; then
        local pid=$(cat ".vm_pid")
        if kill -0 "$pid" 2>/dev/null; then
            local vm_mac=$(get_vm_mac)
            local vm_ip=$(extract_ip_from_log "$VM_LOG_FILE" 2>/dev/null || echo "")
            
            log_success "VM $VM_NAME running"
            echo "  PID: $pid"
            echo "  MAC: $vm_mac"
            if [ -n "$vm_ip" ]; then
                echo "  IP: $vm_ip"
                echo "  SSH: ssh antonio@$vm_ip"
            else
                echo "  IP: not detected"
            fi
            echo "  Log: $VM_LOG_FILE"
            echo "  Memory: ${VM_MEMORY}MB"
            echo "  CPU: $VM_CPUS"
            echo
        else
            log_warning "PID file found but process not running"
            rm -f ".vm_pid"
        fi
    else
        log_info "No VM running"
    fi
    
    # Show any orphaned qemu processes
    local all_qemu_pids=$(pgrep -f "qemu-system-aarch64.*$VM_NAME" 2>/dev/null || true)
    local main_pid=""
    if [ -f ".vm_pid" ]; then
        main_pid=$(cat ".vm_pid")
    fi
    
    local orphan_pids=""
    for qpid in $all_qemu_pids; do
        if [ "$qpid" != "$main_pid" ]; then
            orphan_pids="$orphan_pids $qpid"
        fi
    done
    
    if [ -n "$orphan_pids" ]; then
        echo
        log_warning "Orphaned QEMU processes found:"
        for opid in $orphan_pids; do
            echo "  PID: $opid"
        done
        log_info "Use '$0 stop' to terminate them"
    fi
}

# Stop VM gracefully
stop_vm() {
    local stopped=false
    
    # Stop main VM if PID file exists
    if [ -f ".vm_pid" ]; then
        local pid=$(cat ".vm_pid")
        if kill -0 "$pid" 2>/dev/null; then
            # Try graceful shutdown via QEMU monitor first
            if qemu_graceful_shutdown; then
                log_info "Waiting for VM to shutdown via QEMU monitor..."
                
                # Wait for process to stop (max 30 seconds)
                local wait_attempts=0
                while [ $wait_attempts -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
                    sleep 1
                    wait_attempts=$((wait_attempts + 1))
                    if [ $((wait_attempts % 5)) -eq 0 ]; then
                        printf "\r${BLUE}[INFO]${NC} Waiting for graceful shutdown... [$wait_attempts/30]"
                    fi
                done
                printf "\r\033[K"
                
                if kill -0 "$pid" 2>/dev/null; then
                    log_warning "QEMU monitor shutdown failed, trying SSH..."
                else
                    log_success "Graceful shutdown via QEMU monitor completed"
                    stopped=true
                fi
            else
                log_warning "QEMU monitor unavailable, forcing termination..."
            fi
        fi
            
        # Force terminate if graceful shutdown failed
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Terminating QEMU process (PID: $pid)..."
            kill "$pid"
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            stopped=true
        fi
        rm -f ".vm_pid"
    fi
    
    # Find and stop any orphaned QEMU processes
    local all_qemu_pids=$(pgrep -f "qemu-system-aarch64.*$VM_NAME" 2>/dev/null || true)
    local orphan_pids=""
    for qpid in $all_qemu_pids; do
        orphan_pids="$orphan_pids $qpid"
    done
    
    if [ -n "$orphan_pids" ]; then
        log_info "Stopping orphaned QEMU processes..."
        for opid in $orphan_pids; do
            kill "$opid" 2>/dev/null
            sleep 1
            if kill -0 "$opid" 2>/dev/null; then
                kill -9 "$opid" 2>/dev/null
            fi
        done
        stopped=true
    fi
    
    if [ "$stopped" = true ]; then
        log_success "VM stopped"
    else
        log_info "No VM running to stop"
    fi
}

# Main function
main() {
    case "${1:-help}" in
        "setup")
            log_info "Setting up Debian VM with cloud-init"
            check_qemu
            download_cloud_image
            create_vm_disk
            create_efi_vars
            create_cloud_init_iso
            # Generate MAC address if it doesn't exist
            local mac=$(get_vm_mac)
            log_success "Setup completed!"
            log_info "MAC address assigned: $mac"
            log_info "Now run: $0 start"
            ;;
        "start")
            check_qemu
            start_vm
            ;;
        "status")
            show_vm_status
            ;;
        "stop")
            stop_vm
            ;;
        "clean")
            log_info "Cleaning up VM files..."
            # Stop VM before cleaning
            stop_vm
            rm -f "$VM_DISK" "$CLOUD_INIT_ISO" "/tmp/edk2-aarch64-vars-${VM_NAME}.fd"
            rm -f "$VM_MAC_FILE" "$VM_LOG_FILE" "$VM_MONITOR_SOCKET"
            log_success "VM files removed"
            ;;
        *)
            echo "Debian VM with Cloud-Init for macOS"
            echo "Uses your user-data.yaml and meta-data.yaml files"
            echo
            echo "Usage: $0 {setup|start|status|stop|clean}"
            echo
            echo "Commands:"
            echo "  setup    - Download image and prepare VM"
            echo "  start    - Start VM in background"
            echo "  status   - Show running VM status"
            echo "  stop     - Stop VM with graceful shutdown"
            echo "  clean    - Stop VM and remove all files"
            echo
            echo "Workflow:"
            echo "  1. $0 setup    # Prepare VM (one time)"
            echo "  2. $0 start    # Start VM"
            echo "  3. $0 status   # Check status and IP"
            echo "  4. $0 stop     # Stop VM when done"
            echo
            echo "Connection info:"
            echo "  VM will get DHCP IP from host network"
            echo "  SSH: ssh antonio@<VM_IP> (use 'status' to see IP)"
            echo "  Password: configured in user-data.yaml"
            echo "  Console log: ${VM_NAME}-console.log"
            echo
            ;;
    esac
}

main "$@"