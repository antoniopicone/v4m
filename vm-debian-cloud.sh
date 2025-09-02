#!/bin/bash

# Script per avviare VM Debian con cloud-init su macOS
# Usa i tuoi file user-data.yaml e meta-data.yaml

set -e

# Configurazione
VM_NAME="debian-vm"
VM_MEMORY="4096"
VM_CPUS="4"
VM_DISK_SIZE="20G"
VM_MAC_FILE=".vm_mac"  # File per salvare il MAC address generato
VM_LOG_FILE="${VM_NAME}-console.log"  # File di log per la console
VM_SSH_KEY_FILE=".vm_ssh_key"  # File per salvare il percorso della chiave SSH
VM_MONITOR_SOCKET=".vm_monitor"  # Socket per controllo QEMU monitor

# Percorsi file - Usa Debian 12 stabile invece di 13 (trixie) che è instabile
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2"
CLOUD_IMAGE="debian-12-generic-arm64.qcow2"
VM_DISK="${VM_NAME}.qcow2"
CLOUD_INIT_ISO="${VM_NAME}-cloud-init.iso"

# Directory dei tuoi file cloud-init
USER_DATA_FILE="./user-data.yaml"
META_DATA_FILE="./meta-data.yaml"

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

# Genera MAC address casuale
generate_mac_address() {
    printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Ottieni o genera MAC address
get_vm_mac() {
    if [ -f "$VM_MAC_FILE" ]; then
        cat "$VM_MAC_FILE"
    else
        local mac=$(generate_mac_address)
        echo "$mac" > "$VM_MAC_FILE"
        echo "$mac"
    fi
}

# Spinner per il boot
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

# Estrae l'IP dal log della VM
extract_ip_from_log() {
    local log_file=$1
    local ip=""
    
    # Cerca prima il formato specifico di cloud-init Net device info
    # Esempio: | enp0s1 | True |       192.168.68.15        | 255.255.255.0 | global | 52:54:00:45:f7:82 |
    if grep -q "Net device info" "$log_file" 2>/dev/null; then
        # Trova la riga con enp0s1 (o eth0) che contiene l'IP principale
        ip=$(grep -E '\|\s*(enp0s1|eth0)\s*\|\s*True\s*\|' "$log_file" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '255\.255\.255' | head -1)
    fi
    
    # Se non trovato con cloud-init, prova pattern alternativi
    if [ -z "$ip" ]; then
        # Cerca pattern comuni per IP nel log (inet, network manager, systemd-networkd, etc.)
        ip=$(grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    fi
    
    # Pattern per DHCP
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'bound to ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | head -1 | cut -d' ' -f3)
    fi
    
    # Pattern generico per IP address
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'IP address: ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | head -1 | cut -d':' -f2 | tr -d ' ')
    fi
    
    # Pattern per address (escludendo localhost)
    if [ -z "$ip" ]; then
        ip=$(grep -oE 'address ([0-9]{1,3}\.){3}[0-9]{1,3}' "$log_file" | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2)
    fi
    
    echo "$ip"
}

# Invia comando QEMU via monitor
send_qemu_command() {
    local command="$1"
    
    if [ ! -S "$VM_MONITOR_SOCKET" ]; then
        log_error "Socket monitor QEMU non trovato: $VM_MONITOR_SOCKET"
        return 1
    fi
    
    log_info "Inviando comando QEMU: $command"
    # Usa socat per inviare comandi al socket monitor
    if command -v socat >/dev/null 2>&1; then
        echo "$command" | socat - "UNIX-CONNECT:$VM_MONITOR_SOCKET" 2>/dev/null
        return $?
    else
        # Fallback con nc se socat non disponibile
        if command -v nc >/dev/null 2>&1; then
            echo "$command" | nc -U "$VM_MONITOR_SOCKET" 2>/dev/null
            return $?
        else
            log_error "Né socat né nc sono disponibili per comunicare con QEMU monitor"
            return 1
        fi
    fi
}

# Shutdown graceful via QEMU monitor
qemu_graceful_shutdown() {
    log_info "Tentativo shutdown graceful via QEMU monitor..."
    
    # Invia comando system_powerdown (equivalente a premere il tasto power)
    if send_qemu_command "system_powerdown"; then
        log_info "Comando system_powerdown inviato alla VM"
        return 0
    else
        log_warning "Comando QEMU monitor fallito"
        return 1
    fi
}

# Trova o configura la chiave SSH
get_ssh_key() {
    log_info "[DEBUG] Inizio get_ssh_key"
    
    # Se abbiamo già una chiave salvata, usala
    if [ -f "$VM_SSH_KEY_FILE" ]; then
        log_info "[DEBUG] File chiave salvata trovato: $VM_SSH_KEY_FILE"
        local saved_key=$(cat "$VM_SSH_KEY_FILE")
        log_info "[DEBUG] Chiave salvata: $saved_key"
        if [ -f "$saved_key" ]; then
            log_info "[DEBUG] Chiave salvata esiste, la uso"
            echo "$saved_key"
            return 0
        else
            log_warning "Chiave SSH salvata non esiste più: $saved_key"
            rm -f "$VM_SSH_KEY_FILE"
        fi
    fi
    
    # Auto-detect chiavi SSH in posizioni comuni
    log_info "[DEBUG] Cercando chiavi SSH in posizioni comuni..."
    log_info "[DEBUG] HOME attuale: $HOME"
    log_info "[DEBUG] SUDO_USER: ${SUDO_USER:-'non impostato'}"
    
    # Se siamo in sudo, usa la home dell'utente originale
    local user_home="$HOME"
    if [ -n "$SUDO_USER" ]; then
        user_home=$(eval echo "~$SUDO_USER")
        log_info "[DEBUG] Usando home dell'utente sudo: $user_home"
    fi
    
    local common_keys=(
        "$user_home/.ssh/id_ed25519"
        "$user_home/.ssh/id_rsa"
        "$user_home/.ssh/id_ecdsa"
        "$user_home/.ssh/vm_key"
        "$user_home/.ssh/debian_vm"
    )
    
    for key in "${common_keys[@]}"; do
        log_info "[DEBUG] Controllando: $key"
        if [ -f "$key" ]; then
            log_info "Trovata chiave SSH: $key"
            log_info "[DEBUG] Salvando chiave nel file di configurazione"
            echo "$key" > "$VM_SSH_KEY_FILE"
            log_info "[DEBUG] Chiave salvata, ritorno $key"
            echo "$key"
            return 0
        fi
    done
    
    log_info "[DEBUG] Nessuna chiave trovata"
    # Nessuna chiave trovata
    return 1
}

# Configura chiave SSH interattivamente
configure_ssh_key() {
    log_info "[DEBUG] Inizio configure_ssh_key"
    
    # Controlla se siamo in modalità non-interattiva (sudo, script, etc.)
    if [ ! -t 0 ] || [ -n "$SUDO_USER" ]; then
        log_warning "[DEBUG] Modalità non-interattiva rilevata (sudo o script)"
        log_error "Impossibile configurare chiave SSH in modalità non-interattiva"
        log_info "Suggerimenti:"
        log_info "1. Esegui senza sudo: ./vm-debian-cloud.sh ssh-test"
        log_info "2. Oppure configura manualmente la chiave SSH:"
        log_info "   echo '/path/to/your/ssh/key' > $VM_SSH_KEY_FILE"
        return 1
    fi
    
    echo
    log_info "Configurazione chiave SSH necessaria per shutdown graceful"
    echo "Percorsi comuni delle chiavi SSH:"
    echo "  ~/.ssh/id_ed25519"
    echo "  ~/.ssh/id_rsa"
    echo "  ~/.ssh/vm_key"
    echo
    
    while true; do
        printf "Inserisci il percorso della tua chiave SSH privata: "
        read -r ssh_key_path
        log_info "[DEBUG] Utente ha inserito: $ssh_key_path"
        
        # Espandi ~ se presente
        ssh_key_path="${ssh_key_path/#\~/$HOME}"
        log_info "[DEBUG] Percorso espanso: $ssh_key_path"
        
        if [ -f "$ssh_key_path" ]; then
            log_info "[DEBUG] File esiste, verifico che sia una chiave SSH"
            # Verifica che sia una chiave privata SSH (con timeout per evitare blocchi)
            if timeout 5 ssh-keygen -l -f "$ssh_key_path" >/dev/null 2>&1; then
                log_info "[DEBUG] Chiave valida, salvo la configurazione"
                echo "$ssh_key_path" > "$VM_SSH_KEY_FILE"
                log_success "Chiave SSH configurata: $ssh_key_path"
                log_info "[DEBUG] Ritorno il percorso della chiave"
                echo "$ssh_key_path"
                return 0
            else
                log_error "Il file non sembra essere una chiave SSH valida"
            fi
        else
            log_error "File non trovato: $ssh_key_path"
        fi
        
        printf "Vuoi riprovare? (y/n): "
        read -r retry
        log_info "[DEBUG] Risposta retry: $retry"
        if [ "$retry" != "y" ] && [ "$retry" != "Y" ]; then
            log_info "[DEBUG] Utente ha scelto di non riprovare"
            return 1
        fi
    done
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
    local vm_mac=$(get_vm_mac)
    
    log_info "Avviando VM: $VM_NAME"
    log_info "VM MAC address: $vm_mac"
    log_info "VM otterrà IP via DHCP dalla rete host"
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
    
    # Pulisci log precedente
    > "$VM_LOG_FILE"
    
    log_info "Avvio VM con QEMU (output su $VM_LOG_FILE)..."
    
    # Rimuovi socket monitor precedente se esiste
    rm -f "$VM_MONITOR_SOCKET"
    
    # Avvia QEMU completamente detached con nohup e monitor abilitato
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
    
    # Dissocia il processo dal terminale padre
    disown $qemu_pid
    
    # Aspetta che la VM sia pronta e estrai l'IP dal log
    local boot_ready=false
    local boot_attempts=0
    local max_boot_attempts=120  # 2 minuti
    local vm_ip=""
    
    log_info "Aspettando che la VM completi il boot e ottenga un IP..."
    
    while [ $boot_attempts -lt $max_boot_attempts ] && [ $boot_ready = false ]; do
        # Controlla se QEMU è ancora in esecuzione
        if ! kill -0 $qemu_pid 2>/dev/null; then
            log_error "QEMU si è fermato inaspettatamente"
            log_info "Ultimi 20 righe del log:"
            tail -20 "$VM_LOG_FILE"
            exit 1
        fi
        
        # Controlla se il boot è completo (login prompt)
        if grep -q "login:" "$VM_LOG_FILE" 2>/dev/null; then
            boot_ready=true
            # Estrai l'IP dal log
            vm_ip=$(extract_ip_from_log "$VM_LOG_FILE")
        else
            # Mostra progresso ogni 5 secondi
            if [ $((boot_attempts % 5)) -eq 0 ]; then
                printf "\r${BLUE}[INFO]${NC} Boot in corso... [$boot_attempts/$max_boot_attempts]"
                # Prova a estrarre l'IP anche durante il boot
                local temp_ip=$(extract_ip_from_log "$VM_LOG_FILE")
                if [ -n "$temp_ip" ]; then
                    printf " (IP rilevato: $temp_ip)"
                fi
            fi
            sleep 1
            boot_attempts=$((boot_attempts + 1))
        fi
    done
    
    # Pulisci la riga di progresso
    printf "\r\033[K"
    
    if [ $boot_ready = true ]; then
        log_success "VM avviata e pronta per il login!"
        
        # Se l'IP non è stato trovato durante il boot, fai un ultimo tentativo
        if [ -z "$vm_ip" ]; then
            log_info "Estrazione finale dell'IP dal log..."
            vm_ip=$(extract_ip_from_log "$VM_LOG_FILE")
        fi
        
        if [ -n "$vm_ip" ]; then
            echo
            log_success "=== VM PRONTA ==="
            echo "  SSH: ssh antonio@$vm_ip"
            echo "  MAC: $vm_mac"
            echo "  Log: $VM_LOG_FILE"
            echo "  PID: $qemu_pid"
            echo
            log_info "Per fermare la VM: $0 stop"
        else
            echo
            log_success "=== VM PRONTA ==="
            echo "  MAC: $vm_mac"
            echo "  Log: $VM_LOG_FILE"
            echo "  PID: $qemu_pid"
            echo
            log_info "IP non trovato nel log. Controlla il log manualmente: $VM_LOG_FILE"
            log_info "Oppure usa: arp -a | grep $vm_mac"
            log_info "Per fermare la VM: $0 stop"
        fi
        
        # La VM ora gira in modo detached, non aspettare
        log_info "VM avviata in background. Usa '$0 status' per controllare lo stato."
    else
        log_error "Timeout: VM non pronta dopo $max_boot_attempts secondi"
        log_info "Controlla il log: $VM_LOG_FILE"
        kill $qemu_pid
        exit 1
    fi
}

# Mostra lo stato delle VM
show_vm_status() {
    log_info "Stato delle VM:"
    echo
    
    if [ -f ".vm_pid" ]; then
        local pid=$(cat ".vm_pid")
        if kill -0 "$pid" 2>/dev/null; then
            local vm_mac=$(get_vm_mac)
            local vm_ip=$(extract_ip_from_log "$VM_LOG_FILE" 2>/dev/null || echo "")
            
            log_success "VM $VM_NAME in esecuzione"
            echo "  PID: $pid"
            echo "  MAC: $vm_mac"
            if [ -n "$vm_ip" ]; then
                echo "  IP: $vm_ip"
                echo "  SSH: ssh antonio@$vm_ip"
            else
                echo "  IP: non rilevato"
            fi
            echo "  Log: $VM_LOG_FILE"
            echo "  Memoria: ${VM_MEMORY}MB"
            echo "  CPU: $VM_CPUS"
            echo
        else
            log_warning "File PID trovato ma processo non in esecuzione"
            rm -f ".vm_pid"
        fi
    else
        log_info "Nessuna VM in esecuzione"
    fi
    
    # Mostra solo eventuali processi qemu orfani (non quello principale)
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
        log_warning "Processi QEMU orfani trovati:"
        for opid in $orphan_pids; do
            echo "  PID: $opid"
        done
        log_info "Usa '$0 stop' per terminarli"
    fi
}

# Ferma la VM gracefully
stop_vm() {
    local stopped=false
    
    # Ferma la VM principale se il PID file esiste
    if [ -f ".vm_pid" ]; then
        local pid=$(cat ".vm_pid")
        if kill -0 "$pid" 2>/dev/null; then
            # Prova prima lo shutdown graceful via QEMU monitor
            if qemu_graceful_shutdown; then
                log_info "Aspettando che la VM si spenga via QEMU monitor..."
                
                # Aspetta che il processo si fermi (max 30 secondi)
                local wait_attempts=0
                while [ $wait_attempts -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
                    sleep 1
                    wait_attempts=$((wait_attempts + 1))
                    if [ $((wait_attempts % 5)) -eq 0 ]; then
                        printf "\r${BLUE}[INFO]${NC} Aspettando shutdown graceful... [$wait_attempts/30]"
                    fi
                done
                printf "\r\033[K"
                
                if kill -0 "$pid" 2>/dev/null; then
                    log_warning "Shutdown via QEMU monitor fallito, provo SSH..."
                else
                    log_success "Shutdown graceful via QEMU monitor completato"
                    stopped=true
                fi
            else
                log_warning "QEMU monitor non disponibile, provo SSH..."
            fi
            
            # Se QEMU monitor fallisce, prova SSH come fallback
            if [ "$stopped" != true ]; then
                local vm_ip=$(extract_ip_from_log "$VM_LOG_FILE" 2>/dev/null || echo "")
                
                if [ -n "$vm_ip" ]; then
                    log_info "Tentativo shutdown graceful via SSH ($vm_ip)..."
                    
                    # Trova o configura la chiave SSH
                    local ssh_key_path=""
                    if ! ssh_key_path=$(get_ssh_key); then
                        if ! ssh_key_path=$(configure_ssh_key); then
                            log_warning "Nessuna chiave SSH configurata, terminazione diretta..."
                            # Salta al kill diretto
                        else
                            log_info "Usando chiave SSH: $ssh_key_path"
                        fi
                    fi
                
                    if [ -n "$ssh_key_path" ]; then
                        # Prova diversi comandi di shutdown in ordine di preferenza
                        local shutdown_success=false
                        local ssh_base="ssh -i '$ssh_key_path' -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -o BatchMode=yes antonio@$vm_ip"
                    
                    # Prima testa la connessione SSH
                    log_info "Testando connessione SSH..."
                    if timeout 10 $ssh_base "echo 'SSH_TEST_OK'" 2>/dev/null | grep -q "SSH_TEST_OK"; then
                        log_success "Connessione SSH funzionante"
                        
                        # Testa sudo
                        log_info "Testando permessi sudo..."
                        if timeout 10 $ssh_base "sudo -n true" >/dev/null 2>&1; then
                            log_success "Sudo funzionante"
                            
                            # Metodo 1: systemctl poweroff (più moderno)
                            log_info "Tentativo con 'systemctl poweroff'..."
                            if timeout 10 $ssh_base "sudo systemctl poweroff" >/dev/null 2>&1; then
                                log_info "Comando 'systemctl poweroff' inviato..."
                                shutdown_success=true
                            # Metodo 2: shutdown command
                            else
                                log_info "Tentativo con 'shutdown -h now'..."
                                if timeout 10 $ssh_base "sudo shutdown -h now" >/dev/null 2>&1; then
                                    log_info "Comando 'shutdown -h now' inviato..."
                                    shutdown_success=true
                                # Metodo 3: poweroff command
                                else
                                    log_info "Tentativo con 'poweroff'..."
                                    if timeout 10 $ssh_base "sudo poweroff" >/dev/null 2>&1; then
                                        log_info "Comando 'poweroff' inviato..."
                                        shutdown_success=true
                                    # Metodo 4: halt command
                                    else
                                        log_info "Tentativo con 'halt'..."
                                        if timeout 10 $ssh_base "sudo halt" >/dev/null 2>&1; then
                                            log_info "Comando 'halt' inviato..."
                                            shutdown_success=true
                                        else
                                            log_warning "Tutti i comandi di shutdown falliti"
                                        fi
                                    fi
                                fi
                            fi
                        else
                            log_warning "Sudo non funziona (richiede password?)"
                        fi
                    else
                        log_warning "Connessione SSH fallita"
                    fi
                    
                    if [ "$shutdown_success" = true ]; then
                        log_info "Comando shutdown inviato, aspetto che la VM si fermi..."
                        
                        # Aspetta che il processo si fermi (max 30 secondi)
                        local wait_attempts=0
                        while [ $wait_attempts -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
                            sleep 1
                            wait_attempts=$((wait_attempts + 1))
                            if [ $((wait_attempts % 5)) -eq 0 ]; then
                                printf "\r${BLUE}[INFO]${NC} Aspettando shutdown graceful... [$wait_attempts/30]"
                            fi
                        done
                        printf "\r\033[K"
                        
                        if kill -0 "$pid" 2>/dev/null; then
                            log_warning "Shutdown graceful fallito, terminazione diretta..."
                        else
                            log_success "Shutdown graceful completato"
                            stopped=true
                        fi
                    else
                        log_warning "Shutdown graceful non riuscito, terminazione diretta..."
                    fi
                fi
            else
                log_warning "IP non trovato, terminazione diretta..."
            fi
        fi
            
            # Se lo shutdown graceful fallisce, termina il processo
            if kill -0 "$pid" 2>/dev/null; then
                log_info "Terminando processo QEMU (PID: $pid)..."
                kill "$pid"
                sleep 2
                if kill -0 "$pid" 2>/dev/null; then
                    log_warning "Terminazione forzata..."
                    kill -9 "$pid" 2>/dev/null
                fi
                stopped=true
            fi
        fi
        rm -f ".vm_pid"
    fi
    
    # Cerca e ferma eventuali processi QEMU orfani
    local all_qemu_pids=$(pgrep -f "qemu-system-aarch64.*$VM_NAME" 2>/dev/null || true)
    local orphan_pids=""
    for qpid in $all_qemu_pids; do
        orphan_pids="$orphan_pids $qpid"
    done
    
    if [ -n "$orphan_pids" ]; then
        log_info "Fermando processi QEMU orfani..."
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
        log_success "VM fermata"
    else
        log_info "Nessuna VM in esecuzione da fermare"
    fi
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
            # Genera MAC address se non esiste
            local mac=$(get_vm_mac)
            log_success "Setup completato!"
            log_info "MAC address assegnato: $mac"
            log_info "Ora esegui: $0 start"
            ;;
        "start")
            start_vm
            ;;
        "status")
            show_vm_status
            ;;
        "stop")
            stop_vm
            ;;
        "ssh-test")
            # Test connessione SSH (per debug)
            if [ -f ".vm_pid" ]; then
                local pid=$(cat ".vm_pid")
                if kill -0 "$pid" 2>/dev/null; then
                    local vm_ip=$(extract_ip_from_log "$VM_LOG_FILE" 2>/dev/null || echo "")
                    if [ -n "$vm_ip" ]; then
                        log_info "Test connessione SSH a $vm_ip"
                        
                        local ssh_key_path=""
                        log_info "[DEBUG] Chiamando get_ssh_key..."
                        if ssh_key_path=$(get_ssh_key); then
                            log_info "[DEBUG] get_ssh_key ha ritornato: $ssh_key_path"
                            log_info "Usando chiave: $ssh_key_path"
                        else
                            log_info "[DEBUG] get_ssh_key fallito, chiamando configure_ssh_key..."
                            if ssh_key_path=$(configure_ssh_key); then
                                log_info "[DEBUG] configure_ssh_key ha ritornato: $ssh_key_path"
                                log_info "Usando chiave: $ssh_key_path"
                            else
                                log_error "[DEBUG] Entrambe le funzioni SSH key fallite"
                                log_error "Nessuna chiave SSH configurata"
                                return 1
                            fi
                        fi
                        
                        log_info "[DEBUG] ssh_key_path finale: '$ssh_key_path'"
                        
                        local ssh_base="ssh -i '$ssh_key_path' -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -o BatchMode=yes antonio@$vm_ip"
                        
                        echo "Test 1: Connessione SSH base"
                        if timeout 10 $ssh_base "echo 'SSH funziona!'" 2>&1; then
                            echo "✓ SSH OK"
                        else
                            echo "✗ SSH fallito"
                        fi
                        
                        echo
                        echo "Test 2: Sudo senza password"  
                        if timeout 10 $ssh_base "sudo -n true" >/dev/null 2>&1; then
                            echo "✓ Sudo OK"
                        else
                            echo "✗ Sudo fallito (richiede password?)"
                        fi
                        
                        echo
                        echo "Test 3: Comando whoami"
                        timeout 10 $ssh_base "whoami && sudo whoami" 2>&1
                    else
                        log_error "IP non trovato"
                    fi
                else
                    log_error "VM non in esecuzione"
                fi
            else
                log_error "Nessuna VM avviata"
            fi
            ;;
        "clean")
            log_info "Pulizia file VM..."
            # Ferma la VM prima di pulire
            stop_vm
            rm -f "$VM_DISK" "$CLOUD_INIT_ISO" "/tmp/edk2-aarch64-vars-${VM_NAME}.fd"
            rm -f "$VM_MAC_FILE" "$VM_LOG_FILE" "$VM_SSH_KEY_FILE" "$VM_MONITOR_SOCKET"
            log_success "File VM rimossi"
            ;;
        *)
            echo "VM Debian con Cloud-Init per macOS"
            echo "Usa i tuoi file user-data.yaml e meta-data.yaml"
            echo
            echo "Usage: $0 {setup|start|status|stop|ssh-test|clean}"
            echo
            echo "Comandi:"
            echo "  setup    - Scarica immagine e prepara VM"
            echo "  start    - Avvia la VM in background"
            echo "  status   - Mostra stato delle VM in esecuzione"
            echo "  stop     - Ferma la VM con shutdown graceful"
            echo "  ssh-test - Testa la connessione SSH (debug)"
            echo "  clean    - Ferma la VM e rimuovi tutti i file"
            echo
            echo "Flusso di lavoro:"
            echo "  1. $0 setup    # Prepara la VM (una sola volta)"
            echo "  2. $0 start    # Avvia la VM"
            echo "  3. $0 status   # Controlla stato e IP"
            echo "  4. $0 stop     # Ferma la VM quando finito"
            echo
            echo "Info connessione:"
            echo "  La VM otterrà un IP DHCP dalla rete host"
            echo "  SSH: ssh antonio@<VM_IP> (usa 'status' per vedere l'IP)"
            echo "  Password: configurata nel user-data.yaml"
            echo "  Console log: ${VM_NAME}-console.log"
            echo
            ;;
    esac
}

main "$@"