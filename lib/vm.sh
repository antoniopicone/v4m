#!/bin/bash
# v4m - VM management functions

vm_create() {
    ensure_v4m_setup
    
    local vm_name=""
    local image="$DEFAULT_IMAGE"
    local username="$DEFAULT_USER"
    local password=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name) vm_name="$2"; shift 2 ;;
            --image) image="$2"; shift 2 ;;
            --user) username="$2"; shift 2 ;;
            --pass) password="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    
    if [ -z "$vm_name" ]; then
        vm_name=$(generate_vm_name)
    else
        local original_name="$vm_name"
        vm_name=$(sanitize_vm_name "$vm_name")
        if [ "$original_name" != "$vm_name" ]; then
            log_warning "VM name sanitized: '$original_name' → '$vm_name'"
        fi
    fi
    
    if [ -z "$password" ]; then
        password=$(generate_password)
    fi
    
    init_dirs
    create_vm_internal "$vm_name" "$image" "$username" "$password"
}

vm_list() {
    init_dirs
    echo -e "\n${YELLOW}Virtual Machines:${NC}\n"
    
    if [ ! "$(ls -A "$VMS_DIR" 2>/dev/null)" ]; then
        echo "  No VMs found"
        return
    fi
    
    # Table header
    printf "%-15s %-10s %-5s %-8s %-10s %-10s %-15s %-10s\n" "NAME" "IMAGE" "CPUS" "MEMORY" "DISK SIZE" "DISK USED" "IP" "STATUS"
    printf "%-15s %-10s %-5s %-8s %-10s %-10s %-15s %-10s\n" "----" "-----" "-----" "------" "---------" "---------" "--" "------"
    
    for vm_dir in "$VMS_DIR"/*; do
        if [ -d "$vm_dir" ]; then
            local vm_name=$(basename "$vm_dir")
            local vm_info="$vm_dir/vm-info.json"
            local pid_file="$vm_dir/vm.pid"
            
            if [ -f "$vm_info" ]; then
                local image=$(grep '"image"' "$vm_info" | cut -d'"' -f4)
                local cpus=$(grep '"cpus"' "$vm_info" | cut -d'"' -f4)
                local memory_mb=$(grep '"memory"' "$vm_info" | cut -d'"' -f4)
                local ip="-"
                local status="stopped"
                
                # Convert memory from MB to GB
                local memory_gb=$((memory_mb / 1024))
                if [ $memory_gb -eq 0 ]; then
                    memory_gb="<1GB"
                else
                    memory_gb="${memory_gb}GB"
                fi
                
                # Get disk information
                local disk_info=$(get_vm_disk_info "$vm_dir")
                local disk_size=$(echo "$disk_info" | cut -d'|' -f1)
                local disk_usage=$(echo "$disk_info" | cut -d'|' -f2)
                
                if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                    status="${GREEN}running${NC}"
                    ip=$(get_vm_ip "$vm_name")
                    [ -z "$ip" ] && ip="-"
                else
                    status="${GRAY}stopped${NC}"
                fi
                
                printf "%-15s %-10s %-5s %-8s %-10s %-10s %-15s %b\n" "$vm_name" "$image" "$cpus" "$memory_gb" "$disk_size" "$disk_usage" "$ip" "$status"
            fi
        fi
    done
}

vm_start() {
    ensure_v4m_setup
    
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi
    
    local vm_dir="$VMS_DIR/$vm_name"
    if [ ! -d "$vm_dir" ]; then
        log_error "VM '$vm_name' not found"
        exit 1
    fi
    
    local pid_file="$vm_dir/vm.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log_warning "VM '$vm_name' is already running"
        return
    fi
    
    local vm_info="$vm_dir/vm-info.json"
    local vm_mac=$(grep '"mac"' "$vm_info" | cut -d'"' -f4)
    
    start_vm_internal "$vm_name" "$vm_mac" "$vm_dir"
}

vm_stop() {
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi
    
    local vm_dir="$VMS_DIR/$vm_name"
    local pid_file="$vm_dir/vm.pid"
    
    if [ ! -f "$pid_file" ]; then
        log_warning "VM '$vm_name' is not running"
        return
    fi
    
    local pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$pid_file"
        log_success "VM '$vm_name' stopped"
    else
        rm -f "$pid_file"
        log_warning "VM '$vm_name' was not running"
    fi
}

vm_delete() {
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi
    
    local vm_dir="$VMS_DIR/$vm_name"
    if [ ! -d "$vm_dir" ]; then
        log_error "VM '$vm_name' not found"
        exit 1
    fi
    
    # Check if VM is running
    local pid_file="$vm_dir/vm.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log_warning "VM '$vm_name' is currently running"
        printf "Stop and delete VM '$vm_name'? This action cannot be undone (y/N): "
        read -r confirm
        
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            log_info "Stopping VM '$vm_name'..."
            vm_stop "$vm_name"
        else
            log_info "Delete cancelled"
            exit 0
        fi
    else
        printf "Delete VM '$vm_name'? This action cannot be undone (y/N): "
        read -r confirm
        
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Delete cancelled"
            exit 0
        fi
    fi
    
    rm -rf "$vm_dir"
    log_success "VM '$vm_name' deleted"
}

vm_ip() {
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi
    
    local vm_dir="$VMS_DIR/$vm_name"
    if [ ! -d "$vm_dir" ]; then
        log_error "VM '$vm_name' not found"
        exit 1
    fi
    
    local pid_file="$vm_dir/vm.pid"
    if [ ! -f "$pid_file" ] || ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log_error "VM '$vm_name' is not running"
        exit 1
    fi
    
    local ip=$(get_vm_ip "$vm_name")
    if [ -n "$ip" ]; then
        echo "$ip"
    else
        log_error "Could not determine IP for VM '$vm_name'. Try: ssh user@$vm_name.local"
        exit 1
    fi
}

vm_console() {
    ensure_v4m_setup
    
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi
    
    local vm_dir="$VMS_DIR/$vm_name"
    if [ ! -d "$vm_dir" ]; then
        log_error "VM '$vm_name' not found"
        exit 1
    fi
    
    local pid_file="$vm_dir/vm.pid"
    if [ ! -f "$pid_file" ] || ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log_error "VM '$vm_name' is not running"
        exit 1
    fi
    
    local console_sock="$vm_dir/console.sock"
    if [ ! -S "$console_sock" ]; then
        log_error "Console socket not found for VM '$vm_name'"
        exit 1
    fi
    
    log_info "Connecting to console for VM '$vm_name'"
    log_info "Press Ctrl+C to disconnect"
    echo
    
    socat - UNIX-CONNECT:"$console_sock"
}

purge() {
    init_dirs
    
    local vm_count=0
    local image_count=0
    local running_vms=0
    
    # Count VMs
    if [ -d "$VMS_DIR" ] && [ "$(ls -A "$VMS_DIR" 2>/dev/null)" ]; then
        vm_count=$(ls -1 "$VMS_DIR" | wc -l | tr -d ' ')
        
        # Count running VMs
        for vm_dir in "$VMS_DIR"/*; do
            if [ -d "$vm_dir" ]; then
                local pid_file="$vm_dir/vm.pid"
                if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                    running_vms=$((running_vms + 1))
                fi
            fi
        done
    fi
    
    # Count images
    if [ -d "$IMAGES_DIR" ] && [ "$(ls -A "$IMAGES_DIR" 2>/dev/null)" ]; then
        image_count=$(ls -1 "$IMAGES_DIR" | wc -l | tr -d ' ')
    fi
    
    if [ "$vm_count" -eq 0 ] && [ "$image_count" -eq 0 ]; then
        log_info "No VMs or images found to purge"
        return
    fi
    
    echo
    log_warning "PURGE ALL DATA"
    echo "This will permanently delete:"
    if [ "$vm_count" -gt 0 ]; then
        echo "  • $vm_count VM(s) (including $running_vms running)"
    fi
    if [ "$image_count" -gt 0 ]; then
        echo "  • $image_count image(s)"
    fi
    echo "  • All VM data and configurations"
    echo
    log_error "This action cannot be undone!"
    echo
    
    printf "Type 'DELETE ALL' to confirm purge: "
    read -r confirm
    
    if [ "$confirm" != "DELETE ALL" ]; then
        log_info "Purge cancelled"
        exit 0
    fi
    
    echo
    log_info "Purging all VMs and images..."
    
    # Stop and delete all VMs
    if [ "$vm_count" -gt 0 ]; then
        log_info "Stopping and deleting $vm_count VM(s)..."
        for vm_dir in "$VMS_DIR"/*; do
            if [ -d "$vm_dir" ]; then
                local vm_name=$(basename "$vm_dir")
                local pid_file="$vm_dir/vm.pid"
                
                # Stop VM if running
                if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                    local pid=$(cat "$pid_file")
                    kill "$pid" 2>/dev/null
                    log_info "  Stopped VM '$vm_name'"
                fi
                
                # Delete VM directory
                rm -rf "$vm_dir"
                log_info "  Deleted VM '$vm_name'"
            fi
        done
    fi
    
    # Delete all images
    if [ "$image_count" -gt 0 ]; then
        log_info "Deleting $image_count image(s)..."
        rm -rf "$IMAGES_DIR"/*
        log_info "  Deleted all images"
    fi
    
    echo
    log_success "Purge completed successfully"
    log_info "All VMs and images have been removed"
}

# Internal VM functions
create_vm_internal() {
    local vm_name="$1"
    local image="$2"
    local username="$3"
    local password="$4"
    
    local image_path=$(ensure_image "$image")
    
    local vm_dir="$VMS_DIR/$vm_name"
    if [ -d "$vm_dir" ]; then
        log_error "VM $vm_name already exists"
        exit 1
    fi
    mkdir -p "$vm_dir"
    
    local vm_disk="$vm_dir/disk.qcow2"
    cp "$image_path" "$vm_disk"
    qemu-img resize "$vm_disk" "$DEFAULT_DISK_SIZE" >/dev/null
    
    local vm_mac=$(generate_mac)
    
    local brew_prefix=$(get_brew_prefix)
    local efi_vars="$vm_dir/efi-vars.fd"
    if [ -f "$brew_prefix/share/qemu/edk2-aarch64-vars.fd" ]; then
        cp "$brew_prefix/share/qemu/edk2-aarch64-vars.fd" "$efi_vars"
    else
        dd if=/dev/zero of="$efi_vars" bs=1M count=64 >/dev/null 2>&1
    fi
    
    create_cloud_init "$vm_name" "$username" "$password" "$vm_dir"
    
    local cloud_init_iso="$vm_dir/cloud-init.iso"
    local temp_dir="/tmp/cloud-init-$$"
    mkdir -p "$temp_dir"
    cp "$vm_dir/user-data" "$vm_dir/meta-data" "$temp_dir/"
    
    if ! hdiutil makehybrid -iso -joliet -default-volume-name "cidata" -o "$cloud_init_iso" "$temp_dir" >/dev/null 2>&1; then
        log_error "Failed to create cloud-init ISO"
        rm -rf "$temp_dir" "$vm_dir"
        exit 1
    fi
    rm -rf "$temp_dir"
    
    cat > "$vm_dir/vm-info.json" << EOF
{
    "name": "$vm_name",
    "image": "$image",
    "username": "$username",
    "password": "$password",
    "mac": "$vm_mac",
    "memory": "$DEFAULT_MEMORY",
    "cpus": "$DEFAULT_CPUS",
    "disk_size": "$DEFAULT_DISK_SIZE",
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    start_vm_internal "$vm_name" "$vm_mac" "$vm_dir"
}

start_vm_internal() {
    local vm_name="$1"
    local vm_mac="$2"
    local vm_dir="$3"
    
    local vm_disk="$vm_dir/disk.qcow2"
    local cloud_init_iso="$vm_dir/cloud-init.iso"
    local efi_vars="$vm_dir/efi-vars.fd"
    local log_file="$vm_dir/console.log"
    local pid_file="$vm_dir/vm.pid"
    
    > "$log_file"
    
    local brew_prefix=$(get_brew_prefix)
    local socket_vmnet_sock="$brew_prefix/var/run/socket_vmnet"
    local socket_vmnet_client="$brew_prefix/opt/socket_vmnet/bin/socket_vmnet_client"
    
    # Verify socket_vmnet_client exists
    if [ ! -x "$socket_vmnet_client" ]; then
        log_error "socket_vmnet_client not found at $socket_vmnet_client"
        log_info "Install with: brew install socket_vmnet"
        exit 1
    fi
    
    # Verify socket exists
    if [ ! -S "$socket_vmnet_sock" ]; then
        log_error "socket_vmnet socket not found at $socket_vmnet_sock"
        log_info "Make sure socket_vmnet daemon is running: sudo brew services start socket_vmnet"
        exit 1
    fi
    
    # Build QEMU arguments for socket_vmnet_client
    local qemu_args=(
        -machine virt,highmem=on
        -cpu host
        -accel hvf
        -smp "$DEFAULT_CPUS"
        -m "$DEFAULT_MEMORY"
        -drive "if=pflash,format=raw,file=$brew_prefix/share/qemu/edk2-aarch64-code.fd,readonly=on"
        -drive "if=pflash,format=raw,file=$efi_vars"
        -drive "file=$vm_disk,format=qcow2,if=virtio"
        -netdev "socket,id=net0,fd=3"
        -device "virtio-net-device,netdev=net0,mac=$vm_mac"
        -serial "unix:$vm_dir/console.sock,server,nowait"
        -nographic
    )
    
    # Add cloud-init ISO only for first boot
    if [ ! -f "$vm_dir/.first_boot_complete" ]; then
        qemu_args+=(-drive "file=$cloud_init_iso,media=cdrom,if=virtio,readonly=on")
        touch "$vm_dir/.first_boot_complete"
    fi
    
    # Start QEMU with socket_vmnet_client wrapper
    nohup "$socket_vmnet_client" "$socket_vmnet_sock" qemu-system-aarch64 "${qemu_args[@]}" > "$log_file" 2>&1 &
    
    local qemu_pid=$!
    echo $qemu_pid > "$pid_file"
    disown $qemu_pid
    
    local boot_time=200
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_length=${#spin}
    
    tput civis
    for i in $(seq 1 $boot_time); do
        local spinner_char=$((i % spin_length))
        printf "\r${BLUE}${spin:$spinner_char:1}${NC} Starting VM $vm_name (may take up to 1 minute)..."
        sleep 0.1
        
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            printf "\r\033[K"
            tput cnorm
            log_error "VM $vm_name stopped unexpectedly"
            log_info "Check log: $log_file"
            exit 1
        fi
    done
    tput cnorm
    
    printf "\r\033[K"
    log_success "VM $vm_name is ready!"
    
    show_vm_info "$vm_name" "$vm_dir"
}

show_vm_info() {
    local vm_name="$1"
    local vm_dir="$2"
    local vm_info="$vm_dir/vm-info.json"
    
    if [ ! -f "$vm_info" ]; then
        log_error "VM info file not found"
        return
    fi
    
    local username=$(grep '"username"' "$vm_info" | cut -d'"' -f4)
    local password=$(grep '"password"' "$vm_info" | cut -d'"' -f4)
    
    echo
    echo -e "${YELLOW}VM Information:${NC}"
    echo "  🖥️  Name: $vm_name"
    echo "  💾 Memory: ${DEFAULT_MEMORY}MB"
    echo "  🔧 CPUs: $DEFAULT_CPUS"
    echo
    echo -e "${YELLOW}Login Credentials:${NC}"
    echo "  👤 Username: $username"
    echo "  🔑 Password: $password"
    echo "  👑 Root password: $password (same as user)"
    echo "  📺 SSH: ssh $username@$vm_name.local"
    echo
    echo -e "${YELLOW}VM Management:${NC}"
    echo "  ⏹️  Stop: v4m vm stop $vm_name"
    echo
}