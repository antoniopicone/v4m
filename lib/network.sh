#!/bin/bash
# v4m - Network and Socket VMNet Management

get_brew_prefix() {
    if command -v brew >/dev/null 2>&1; then
        brew --prefix
    else
        echo "/opt/homebrew"  # fallback
    fi
}

socket_vmnet_status() {
    local brew_prefix=$(get_brew_prefix)
    local socket_path="$brew_prefix/var/run/socket_vmnet"
    
    # Check if socket_vmnet process is running
    if pgrep -f socket_vmnet >/dev/null 2>&1; then
        # Also verify the socket file exists and is accessible
        if [ -S "$socket_path" ]; then
            return 0
        else
            log_warning "socket_vmnet process running but socket not accessible at $socket_path"
            return 1
        fi
    fi
    
    return 1
}

socket_vmnet_start() {
    if ! socket_vmnet_status; then
        log_info "Starting socket_vmnet daemon (requires sudo for initial setup)..."
        
        local brew_prefix=$(get_brew_prefix)
        
        # Ensure the run directory exists with correct permissions
        local run_dir="$brew_prefix/var/run"
        if [ ! -d "$run_dir" ]; then
            sudo mkdir -p "$run_dir"
            sudo chown "$(whoami):$(id -gn)" "$run_dir"
            sudo chmod 755 "$run_dir"
        fi
        
        if sudo brew services start socket_vmnet; then
            log_success "socket_vmnet daemon started"
            sleep 3  # Give it more time to start and create socket
            
            # Verify socket was created
            local socket_path="$brew_prefix/var/run/socket_vmnet"
            if [ ! -S "$socket_path" ]; then
                log_warning "Socket not created after startup, waiting longer..."
                sleep 2
                if [ ! -S "$socket_path" ]; then
                    log_error "socket_vmnet daemon started but socket not available at $socket_path"
                    exit 1
                fi
            fi
        else
            log_error "Failed to start socket_vmnet daemon"
            exit 1
        fi
    fi
}

socket_vmnet_init() {
    if ! socket_vmnet_status; then
        log_warning "socket_vmnet daemon not running"
        log_info "This is required for bridged networking without sudo on each VM start"
        printf "Start socket_vmnet daemon? (requires sudo once) (y/N): "
        read -r confirm
        
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            socket_vmnet_start
        else
            log_info "You can start it later with: sudo brew services start socket_vmnet"
            log_info "Or use: v4m v4m_init"
            exit 1
        fi
    fi
}