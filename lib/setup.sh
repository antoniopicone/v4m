#!/bin/bash
# v4m - Setup and dependency management

check_setup_status() {
    local issues=0
    
    # Check dependencies
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        issues=$((issues + 1))
    fi
    
    if ! brew list socket_vmnet >/dev/null 2>&1; then
        issues=$((issues + 1))
    fi
    
    if ! command -v socat >/dev/null 2>&1; then
        issues=$((issues + 1))
    fi
    
    # Check socket_vmnet service
    if ! socket_vmnet_status; then
        issues=$((issues + 1))
    fi
    
    return $issues
}

install_dependencies() {
    log_info "Checking and installing dependencies..."
    echo
    
    # Check and install QEMU
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        log_warning "QEMU not found"
        log_info "Installing QEMU..."
        brew install qemu
        log_success "QEMU installed"
    else
        log_success "QEMU already installed"
    fi
    
    # Check and install socket_vmnet
    if ! brew list socket_vmnet >/dev/null 2>&1; then
        log_warning "socket_vmnet not found"
        log_info "Installing socket_vmnet..."
        brew install socket_vmnet
        log_success "socket_vmnet installed"
    else
        log_success "socket_vmnet already installed"
    fi
    
    # Check and install socat
    if ! command -v socat >/dev/null 2>&1; then
        log_warning "socat not found"
        log_info "Installing socat..."
        brew install socat
        log_success "socat installed"
    else
        log_success "socat already installed"
    fi
}

apply_dhcp_fixes() {
    log_info "Configuring macOS for VM networking (DHCP fixes)..."
    echo
    
    # Fix macOS firewall blocking DHCP
    log_info "Configuring macOS firewall to allow bootpd (DHCP server)..."
    if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/bootpd 2>/dev/null; then
        log_success "Added bootpd to firewall"
    else
        log_info "bootpd already in firewall (or failed to add)"
    fi
    
    if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock /usr/libexec/bootpd 2>/dev/null; then
        log_success "Unblocked bootpd in firewall"
    else
        log_info "bootpd already unblocked (or failed to unblock)"
    fi
    
    # Restart DHCP service
    log_info "Restarting macOS DHCP service..."
    if sudo /bin/launchctl kickstart -kp system/com.apple.bootpd; then
        log_success "DHCP service restarted"
    else
        log_warning "Failed to restart DHCP service (may still work)"
    fi
    
    local brew_prefix=$(get_brew_prefix)
    
    # Ensure run directory exists with correct permissions
    local run_dir="$brew_prefix/var/run"
    if [ ! -d "$run_dir" ]; then
        log_info "Creating run directory..."
        sudo mkdir -p "$run_dir"
        sudo chown "$(whoami):$(id -gn)" "$run_dir"
        sudo chmod 755 "$run_dir"
    fi
    
    # Start socket_vmnet service
    log_info "Starting socket_vmnet service..."
    if sudo brew services start socket_vmnet; then
        log_success "socket_vmnet service started"
        sleep 2  # Give it time to create socket
        
        # Verify socket was created
        local socket_path="$brew_prefix/var/run/socket_vmnet"
        if [ -S "$socket_path" ]; then
            log_success "socket_vmnet socket created successfully"
        else
            log_warning "socket_vmnet service started but socket not found"
        fi
    else
        log_error "Failed to start socket_vmnet service"
        return 1
    fi
}

v4m_init() {
    local deps_only=false
    local dhcp_only=false
    local check_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --deps-only)
                deps_only=true
                shift
                ;;
            --dhcp-only)
                dhcp_only=true
                shift
                ;;
            --check)
                check_only=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [ "$check_only" = true ]; then
        log_info "Checking v4m setup status..."
        echo
        
        local issues=0
        
        # Check dependencies
        log_info "Dependency Status:"
        
        if command -v qemu-system-aarch64 >/dev/null 2>&1; then
            log_success "QEMU found: $(qemu-system-aarch64 --version | head -1)"
        else
            log_error "QEMU not found"
            issues=$((issues + 1))
        fi
        
        if brew list socket_vmnet >/dev/null 2>&1; then
            log_success "socket_vmnet found: $(brew list --versions socket_vmnet)"
        else
            log_error "socket_vmnet not found"
            issues=$((issues + 1))
        fi
        
        if command -v socat >/dev/null 2>&1; then
            log_success "socat found: $(socat -V | head -1)"
        else
            log_error "socat not found"
            issues=$((issues + 1))
        fi
        
        echo
        log_info "Service Status:"
        
        # Check socket_vmnet service
        if socket_vmnet_status; then
            log_success "socket_vmnet service running and socket accessible"
        else
            log_error "socket_vmnet service not running or not accessible"
            issues=$((issues + 1))
        fi
        
        echo
        if [ $issues -eq 0 ]; then
            log_success "All checks passed! v4m should work properly."
        else
            log_warning "Found $issues issue(s). Run 'v4m v4m_init' to fix."
        fi
        
        return $issues
    fi
    
    echo "🖥️  v4m Setup Script"
    echo "=================="
    echo
    
    if [ "$dhcp_only" = false ]; then
        install_dependencies
        echo
    fi
    
    if [ "$deps_only" = false ]; then
        apply_dhcp_fixes
        echo
    fi
    
    log_success "v4m setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  1. Create a VM: v4m vm create --name myvm"
    echo "  2. Connect to console: v4m vm console myvm"
    echo "  3. SSH to VM: ssh user01@myvm.local"
}

ensure_v4m_setup() {
    if ! check_setup_status; then
        log_warning "v4m is not properly set up"
        log_info "Running automatic setup..."
        echo
        v4m_init
        echo
    fi
}