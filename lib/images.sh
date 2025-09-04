#!/bin/bash
# v4m - Image management functions

get_image_url() {
    local image="$1"
    
    # Read from config.ini using grep
    local url=$(grep "^$image=" "$SCRIPT_DIR/config.ini" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    echo "$url"
}

ensure_image() {
    local image="$1"
    local url=$(get_image_url "$image")
    
    if [ -z "$url" ]; then
        log_error "Unknown image: $image"
        log_info "Available images: debian12, debian13, ubuntu22, ubuntu24"
        exit 1
    fi
    
    local filename=$(basename "$url")
    local image_dir="$IMAGES_DIR/$image"
    local image_path="$image_dir/$filename"
    
    if [ -f "$image_path" ]; then
        echo "$image_path"
        return
    fi
    
    # Redirect spinner output to stderr to avoid interfering with return value
    show_spinner "Downloading $image" 100 >&2 &
    local spinner_pid=$!
    mkdir -p "$image_dir"
    if curl -L -o "$image_path" "$url" --silent; then
        kill $spinner_pid 2>/dev/null
        printf "\r\033[K" >&2
        log_success "Downloaded $image" >&2
        echo "$image_path"
    else
        kill $spinner_pid 2>/dev/null
        printf "\r\033[K" >&2
        log_error "Failed to download $image" >&2
        rm -f "$image_path"
        exit 1
    fi
}

image_list() {
    init_dirs
    echo -e "${YELLOW}Available Images:${NC}"
    
    if [ ! "$(ls -A "$IMAGES_DIR" 2>/dev/null)" ]; then
        echo "  No images found"
        return
    fi
    
    for image_dir in "$IMAGES_DIR"/*; do
        if [ -d "$image_dir" ]; then
            local image_name=$(basename "$image_dir")
            local image_file=$(ls "$image_dir"/*.qcow2 "$image_dir"/*.img 2>/dev/null | head -1)
            
            if [ -n "$image_file" ]; then
                local size=$(du -h "$image_file" | cut -f1)
                echo "  📦 $image_name ($size)"
            fi
        fi
    done
}

image_pull() {
    local image="$1"
    if [ -z "$image" ]; then
        log_error "Image name required (debian12, debian13, ubuntu22, ubuntu24)"
        exit 1
    fi
    
    init_dirs
    ensure_image "$image" >/dev/null
}

image_delete() {
    local image="$1"
    if [ -z "$image" ]; then
        log_error "Image name required"
        exit 1
    fi
    
    local image_dir="$IMAGES_DIR/$image"
    if [ ! -d "$image_dir" ]; then
        log_error "Image '$image' not found"
        exit 1
    fi
    
    rm -rf "$image_dir"
    log_success "Image '$image' deleted"
}