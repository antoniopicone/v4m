#!/bin/bash

# v4m_init.sh - VM Manager Setup Script for macOS
# This script handles dependency installation and DHCP configuration fixes

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo "${GREEN}✓${NC} $1"
}

log_warning() {
    echo "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo "${RED}✗${NC} $1"
}

show_help() {
    echo "v4m_init.sh - VM Manager Setup Script"
    echo
    echo "Usage: ./v4m_init.sh [options]"
    echo
    echo "Options:"
    echo "  --deps-only     Install dependencies only (no DHCP fixes)"
    echo "  --dhcp-only     Apply DHCP fixes only (skip dependency check)"
    echo "  --check         Check current setup status"
    echo "  -h, --help      Show this help"
    echo
    echo "What this script does:"
    echo "  1. Installs required dependencies:"
    echo "     - QEMU (ARM64 virtualization)"
    echo "     - socket_vmnet (bridged networking)"
    echo "     - socat (console access)"
    echo "  2. Fixes macOS DHCP issues:"
    echo "     - Configures firewall to allow bootpd (DHCP server)"
    echo "     - Restarts macOS DHCP service"
    echo "     - Starts socket_vmnet service"
    echo
    echo "DHCP Fix Details:"
    echo "  The fix resolves VMs getting only IPv6 addresses by:"
    echo "  - Unblocking bootpd from macOS firewall"
    echo "  - Restarting system DHCP service"
    echo "  - Ensuring socket_vmnet can provide IPv4 DHCP"
}

check_setup() {
    echo "Checking v4m setup status..."
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
    if pgrep -f socket_vmnet >/dev/null 2>&1; then
        local brew_prefix
        if command -v brew >/dev/null 2>&1; then
            brew_prefix=$(brew --prefix)
        else
            brew_prefix="/opt/homebrew"
        fi
        
        if [ -S "$brew_prefix/var/run/socket_vmnet" ]; then
            log_success "socket_vmnet service running and socket accessible"
        else
            log_warning "socket_vmnet process running but socket not accessible"
            issues=$((issues + 1))
        fi
    else
        log_error "socket_vmnet service not running"
        issues=$((issues + 1))
    fi
    
    echo
    if [ $issues -eq 0 ]; then
        log_success "All checks passed! v4m should work properly."
    else
        log_warning "Found $issues issue(s). Run without --check to fix."
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
    
    # Get homebrew prefix
    local brew_prefix
    if command -v brew >/dev/null 2>&1; then
        brew_prefix=$(brew --prefix)
    else
        brew_prefix="/opt/homebrew"
    fi
    
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

main() {
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
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    if [ "$check_only" = true ]; then
        check_setup
        exit $?
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

# Check if running directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi