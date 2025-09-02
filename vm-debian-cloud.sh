#!/bin/bash

# Script per avviare VM Debian con cloud-init su macOS
# Usa i tuoi file user-data.yaml e meta-data.yaml

set -e

# Configurazione
VM_NAME="debian-vm"
VM_MEMORY="4096"
VM_CPUS="4"
VM_DISK_SIZE="20G"
SSH_PORT="2222"

# Percorsi file - Usa Debian 12 stabile invece di 13 (trixie) che è instabile
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2"
CLOUD_IMAGE="debian-12-generic-arm64.qcow2"
VM_DISK="${VM_NAME}.qcow2"
CLOUD_INIT_ISO="${VM_NAME}-cloud-init.iso"

# Directory dei tuoi file cloud-init
USER_DATA_FILE="/Users/antonio/Developer/antoniopicone/vm_tests/user-data.yaml"
META_DATA_FILE="/Users/antonio/Developer/antoniopicone/vm_tests/meta-data.yaml"

# Colori per output
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

# Scarica cloud image se necessario
download_cloud_image() {
    if [ ! -f "$CLOUD_IMAGE" ]; then
        log_info "Scaricando Debian cloud image..."
        wget -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
        log_success "Cloud image scaricata: $CLOUD_IMAGE"
    else
        log_info "Cloud image già presente: $CLOUD_IMAGE"
    fi
}

# Crea disco VM da cloud image
create_vm_disk() {
    if [ -f "$VM_DISK" ]; then
        log_warning "Disco VM esistente, lo rimuovo: $VM_DISK"
        rm -f "$VM_DISK"
    fi
    
    log_info "Creando disco VM da cloud image..."
    cp "$CLOUD_IMAGE" "$VM_DISK"
    qemu-img resize "$VM_DISK" "$VM_DISK_SIZE"
    log_success "Disco VM creato: $VM_DISK"
}

# Crea EFI variables file
create_efi_vars() {
    local efi_vars_file="/tmp/edk2-aarch64-vars-${VM_NAME}.fd"
    
    if [ ! -f "$efi_vars_file" ]; then
        log_info "Creando EFI variables file..."
        if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-vars.fd" ]; then
            cp "/opt/homebrew/share/qemu/edk2-aarch64-vars.fd" "$efi_vars_file"
            log_success "EFI variables file creato: $efi_vars_file"
        else
            log_warning "Template EFI variables non trovato, creo file vuoto"
            dd if=/dev/zero of="$efi_vars_file" bs=1M count=64 2>/dev/null
        fi
    else
        log_info "EFI variables file già presente: $efi_vars_file"
    fi
}

# Crea cloud-init ISO
create_cloud_init_iso() {
    if [ ! -f "$USER_DATA_FILE" ] || [ ! -f "$META_DATA_FILE" ]; then
        log_error "File cloud-init mancanti:"
        log_error "  user-data: $USER_DATA_FILE"
        log_error "  meta-data: $META_DATA_FILE"
        exit 1
    fi
    
    log_info "Creando cloud-init ISO..."
    
    # Crea directory temporanea
    temp_dir="/tmp/cloud-init-$$"
    mkdir -p "$temp_dir"
    
    # Copia i file cloud-init (rinominandoli senza .yaml)
    cp "$USER_DATA_FILE" "$temp_dir/user-data"
    cp "$META_DATA_FILE" "$temp_dir/meta-data"
    
    # Rimuovi ISO esistente
    rm -f "$CLOUD_INIT_ISO"
    
    # Crea ISO con hdiutil (macOS) usando formato ISO9660 standard
    if command -v hdiutil >/dev/null 2>&1; then
        if hdiutil makehybrid -iso -joliet -default-volume-name "cidata" -o "${VM_NAME}-cloud-init" "$temp_dir" >/dev/null 2>&1; then
            # Sposta il file risultante
            if [ -f "${VM_NAME}-cloud-init.iso" ]; then
                mv "${VM_NAME}-cloud-init.iso" "$CLOUD_INIT_ISO"
            elif [ -f "${VM_NAME}-cloud-init.dmg" ]; then
                mv "${VM_NAME}-cloud-init.dmg" "$CLOUD_INIT_ISO"
            elif [ -f "${VM_NAME}-cloud-init.cdr" ]; then
                mv "${VM_NAME}-cloud-init.cdr" "$CLOUD_INIT_ISO"
            fi
            log_success "Cloud-init ISO creata: $CLOUD_INIT_ISO"
        else
            log_error "Fallimento creazione ISO con hdiutil"
            rm -rf "$temp_dir"
            exit 1
        fi
    else
        log_error "hdiutil non disponibile"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Pulizia
    rm -rf "$temp_dir"
}

# Avvia VM
start_vm() {
    log_info "Avviando VM: $VM_NAME"
    log_info "SSH sarà disponibile su porta $SSH_PORT"
    log_info "Utente: antonio (come configurato nel user-data.yaml)"
    
    # Controlla se i file necessari esistono
    if [ ! -f "$VM_DISK" ]; then
        log_error "Disco VM non trovato: $VM_DISK"
        exit 1
    fi
    
    if [ ! -f "$CLOUD_INIT_ISO" ]; then
        log_error "Cloud-init ISO non trovata: $CLOUD_INIT_ISO"
        exit 1
    fi
    
    log_info "Avvio VM con QEMU ottimizzato per Apple Silicon..."
    log_warning "Console sarà disponibile qui. Per uscire: Ctrl+A, poi X"
    echo
    
    # Comando QEMU con EFI firmware per ARM64/Apple Silicon
    qemu-system-aarch64 \
      -machine virt \
      -cpu host \
      -accel hvf \
      -smp $VM_CPUS \
      -m $VM_MEMORY \
      -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on \
      -drive if=pflash,format=raw,file=/tmp/edk2-aarch64-vars-${VM_NAME}.fd \
      -drive file=$VM_DISK,format=qcow2,if=virtio \
      -drive file=$CLOUD_INIT_ISO,media=cdrom,if=virtio,readonly=on \
      -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
      -device virtio-net,netdev=net0 \
      -nographic
}

# Funzione principale
main() {
    case "${1:-help}" in
        "setup")
            log_info "Setup VM Debian con cloud-init"
            download_cloud_image
            create_vm_disk
            create_efi_vars
            create_cloud_init_iso
            log_success "Setup completato!"
            log_info "Ora esegui: $0 start"
            ;;
        "start")
            start_vm
            ;;
        "clean")
            log_info "Pulizia file VM..."
            rm -f "$VM_DISK" "$CLOUD_INIT_ISO" "/tmp/edk2-aarch64-vars-${VM_NAME}.fd"
            log_success "File VM rimossi"
            ;;
        *)
            echo "VM Debian con Cloud-Init per macOS"
            echo "Usa i tuoi file user-data.yaml e meta-data.yaml"
            echo
            echo "Usage: $0 {setup|start|clean}"
            echo
            echo "Comandi:"
            echo "  setup  - Scarica immagine e prepara VM"
            echo "  start  - Avvia la VM"
            echo "  clean  - Rimuovi file VM"
            echo
            echo "Dopo l'avvio:"
            echo "  SSH: ssh -p $SSH_PORT antonio@localhost"
            echo "  Password: configurata nel user-data.yaml"
            echo
            ;;
    esac
}

main "$@"