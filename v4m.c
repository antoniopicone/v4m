#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <ctype.h>
#include <dirent.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/route.h>

#define MAX_PATH 1024
#define MAX_LINE 4096
#define MAX_NAME 256
#define MAX_URL 512

// Configuration
#define DEFAULT_DISTRO "debian12"
#define DEFAULT_USER "user01"
#define DEFAULT_MEMORY "4096"
#define DEFAULT_CPUS "4"
#define DEFAULT_DISK_SIZE "20G"

// Colors
#define RED     "\033[0;31m"
#define GREEN   "\033[0;32m"
#define YELLOW  "\033[1;33m"
#define BLUE    "\033[0;34m"
#define CYAN    "\033[0;36m"
#define NC      "\033[0m"

typedef struct {
    char name[MAX_NAME];
    char distro[MAX_NAME];
    char username[MAX_NAME];
    char password[MAX_NAME];
    char mac[18];
    char memory[16];
    char cpus[16];
    char disk_size[16];
    char created[64];
} VMInfo;

// Function prototypes
void log_info(const char *message);
void log_success(const char *message);
void log_warning(const char *message);
void log_error(const char *message);
int check_root();
void init_dirs();
void generate_vm_name(char *name, size_t size);
void generate_password(char *password, size_t size);
const char *get_distro_url(const char *distro);
int ensure_distro(const char *distro, char *distro_path, size_t size);
void generate_mac(char *mac, size_t size);
int hash_password(const char *password, char *hashed, size_t size);
int create_cloud_init(const char *vm_name, const char *username, 
                     const char *password, const char *vm_dir);
int create_vm(const char *vm_name, const char *distro, 
             const char *username, const char *password);
int start_vm(const char *vm_name, const char *vm_mac, const char *vm_dir);
void show_vm_info(const char *vm_name, const char *vm_dir);
int execute_command(const char *command, char *output, size_t output_size);
int file_exists(const char *path);
int dir_exists(const char *path);
int copy_file(const char *src, const char *dest);
int get_default_interface(char *interface, size_t size);

int main(int argc, char *argv[]) {
    char vm_name[MAX_NAME] = "";
    char distro[MAX_NAME] = DEFAULT_DISTRO;
    char username[MAX_NAME] = DEFAULT_USER;
    char password[MAX_NAME] = "";
    
    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--name") == 0 && i + 1 < argc) {
            strncpy(vm_name, argv[i + 1], sizeof(vm_name) - 1);
            i++;
        } else if (strcmp(argv[i], "--distro") == 0 && i + 1 < argc) {
            strncpy(distro, argv[i + 1], sizeof(distro) - 1);
            i++;
        } else if (strcmp(argv[i], "--user") == 0 && i + 1 < argc) {
            strncpy(username, argv[i + 1], sizeof(username) - 1);
            i++;
        } else if (strcmp(argv[i], "--pass") == 0 && i + 1 < argc) {
            strncpy(password, argv[i + 1], sizeof(password) - 1);
            i++;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: sudo %s [OPTIONS]\n\n", argv[0]);
            printf("Options:\n");
            printf("  --name NAME     VM name (default: random)\n");
            printf("  --distro DIST   Distribution (default: debian12)\n");
            printf("  --user USER     Username (default: user01)\n");
            printf("  --pass PASS     Password (default: auto-generated)\n\n");
            printf("Available distros: debian12, ubuntu22, ubuntu24\n\n");
            printf("Examples:\n");
            printf("  sudo %s                                    # Create VM with all defaults\n", argv[0]);
            printf("  sudo %s --name myvm --user john            # Create VM 'myvm' with user 'john'\n", argv[0]);
            printf("  sudo %s --distro ubuntu22 --pass secret123 # Create Ubuntu VM with custom password\n", argv[0]);
            return 0;
        } else {
            log_error("Unknown option");
            return 1;
        }
    }
    
    // Generate defaults if not provided
    if (strlen(vm_name) == 0) {
        generate_vm_name(vm_name, sizeof(vm_name));
    }
    
    if (strlen(password) == 0) {
        generate_password(password, sizeof(password));
    }
    
    // Check requirements
    if (check_root() != 0) {
        return 1;
    }
    
    init_dirs();
    
    // Check if QEMU is available
    if (system("command -v qemu-system-aarch64 >/dev/null 2>&1") != 0) {
        log_error("QEMU not found. Please install QEMU:");
        log_error("  brew install qemu");
        return 1;
    }
    
    // Create and start VM
    if (create_vm(vm_name, distro, username, password) != 0) {
        return 1;
    }
    
    return 0;
}

void log_info(const char *message) {
    printf(BLUE "[INFO]" NC " %s\n", message);
}

void log_success(const char *message) {
    printf(GREEN "[SUCCESS]" NC " %s\n", message);
}

void log_warning(const char *message) {
    printf(YELLOW "[WARNING]" NC " %s\n", message);
}

void log_error(const char *message) {
    printf(RED "[ERROR]" NC " %s\n", message);
}

int check_root() {
    if (geteuid() != 0) {
        log_error("This script requires sudo privileges for vmnet-bridged networking");
        log_info("Please run with sudo");
        return 1;
    }
    return 0;
}

void init_dirs() {
    char v4m_dir[MAX_PATH];
    char distros_dir[MAX_PATH];
    char vms_dir[MAX_PATH];
    
    snprintf(v4m_dir, sizeof(v4m_dir), "%s/.v4m", getenv("HOME"));
    snprintf(distros_dir, sizeof(distros_dir), "%s/distros", v4m_dir);
    snprintf(vms_dir, sizeof(vms_dir), "%s/vms", v4m_dir);
    
    mkdir(v4m_dir, 0755);
    mkdir(distros_dir, 0755);
    mkdir(vms_dir, 0755);
}

void generate_vm_name(char *name, size_t size) {
    const char *adjectives[] = {"fast", "quick", "smart", "bright", "cool", 
                               "swift", "agile", "sharp", "clever", "rapid"};
    const char *nouns[] = {"vm", "box", "node", "server", "instance", 
                          "machine", "host", "system", "unit", "engine"};
    
    srand(time(NULL));
    int adj_index = rand() % 10;
    int noun_index = rand() % 10;
    int num = rand() % 100;
    
    snprintf(name, size, "%s-%s-%d", adjectives[adj_index], nouns[noun_index], num);
}

void generate_password(char *password, size_t size) {
    FILE *fp = popen("openssl rand -base64 12 | tr -d \"=+/\" | cut -c1-12", "r");
    if (fp != NULL) {
        if (fgets(password, size, fp) != NULL) {
            // Remove newline
            password[strcspn(password, "\n")] = 0;
        }
        pclose(fp);
    } else {
        // Fallback if openssl is not available
        srand(time(NULL));
        const char *chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        for (int i = 0; i < 12; i++) {
            password[i] = chars[rand() % 62];
        }
        password[12] = '\0';
    }
}

const char *get_distro_url(const char *distro) {
    if (strcmp(distro, "debian12") == 0) {
        return "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2";
    } else if (strcmp(distro, "ubuntu22") == 0) {
        return "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-arm64.img";
    } else if (strcmp(distro, "ubuntu24") == 0) {
        return "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img";
    }
    return NULL;
}

int ensure_distro(const char *distro, char *distro_path, size_t size) {
    const char *url = get_distro_url(distro);
    if (url == NULL) {
        log_error("Unknown distro");
        return 1;
    }
    
    char v4m_dir[MAX_PATH];
    char distro_dir[MAX_PATH];
    snprintf(v4m_dir, sizeof(v4m_dir), "%s/.v4m", getenv("HOME"));
    snprintf(distro_dir, sizeof(distro_dir), "%s/distros/%s", v4m_dir, distro);
    
    const char *filename = strrchr(url, '/');
    if (filename == NULL) filename = url;
    else filename++;
    
    snprintf(distro_path, size, "%s/%s", distro_dir, filename);
    
    if (file_exists(distro_path)) {
        return 0;
    }
    
    log_info("Downloading distro...");
    mkdir(distro_dir, 0755);
    
    char command[MAX_PATH * 3];
    snprintf(command, sizeof(command), "curl -L -o \"%s\" \"%s\" --progress-bar", distro_path, url);
    
    if (system(command) != 0) {
        log_error("Failed to download distro");
        remove(distro_path);
        return 1;
    }
    
    log_success("Downloaded distro");
    return 0;
}

void generate_mac(char *mac, size_t size) {
    srand(time(NULL));
    snprintf(mac, size, "52:54:00:%02x:%02x:%02x", 
             rand() % 256, rand() % 256, rand() % 256);
}

int hash_password(const char *password, char *hashed, size_t size) {
    char command[MAX_PATH * 2];
    snprintf(command, sizeof(command), "openssl passwd -6 \"%s\"", password);
    
    FILE *fp = popen(command, "r");
    if (fp == NULL) {
        return 1;
    }
    
    if (fgets(hashed, size, fp) == NULL) {
        pclose(fp);
        return 1;
    }
    
    // Remove newline
    hashed[strcspn(hashed, "\n")] = 0;
    pclose(fp);
    return 0;
}

int create_cloud_init(const char *vm_name, const char *username, 
                     const char *password, const char *vm_dir) {
    char user_data_path[MAX_PATH];
    char meta_data_path[MAX_PATH];
    char hashed_pass[MAX_PATH];
    
    snprintf(user_data_path, sizeof(user_data_path), "%s/user-data", vm_dir);
    snprintf(meta_data_path, sizeof(meta_data_path), "%s/meta-data", vm_dir);
    
    if (hash_password(password, hashed_pass, sizeof(hashed_pass)) != 0) {
        log_error("Failed to hash password");
        return 1;
    }
    
    // Create user-data file
    FILE *user_data = fopen(user_data_path, "w");
    if (user_data == NULL) {
        log_error("Failed to create user-data file");
        return 1;
    }
    
    fprintf(user_data, "#cloud-config\n\n");
    fprintf(user_data, "# System settings\n");
    fprintf(user_data, "hostname: %s\n", vm_name);
    fprintf(user_data, "fqdn: %s.local\n", vm_name);
    fprintf(user_data, "timezone: Europe/Rome\n\n");
    fprintf(user_data, "# Enable SSH password authentication\n");
    fprintf(user_data, "ssh_pwauth: true\n");
    fprintf(user_data, "disable_root: false\n\n");
    fprintf(user_data, "# Network configuration for DHCP\n");
    fprintf(user_data, "network:\n");
    fprintf(user_data, "  version: 2\n");
    fprintf(user_data, "  ethernets:\n");
    fprintf(user_data, "    enp0s1:\n");
    fprintf(user_data, "      dhcp4: true\n");
    fprintf(user_data, "      dhcp6: true\n\n");
    fprintf(user_data, "# Users\n");
    fprintf(user_data, "users:\n");
    fprintf(user_data, "  - name: %s\n", username);
    fprintf(user_data, "    sudo: ALL=(ALL) NOPASSWD:ALL\n");
    fprintf(user_data, "    groups: [sudo, users]\n");
    fprintf(user_data, "    shell: /bin/bash\n");
    fprintf(user_data, "    lock_passwd: false\n");
    fprintf(user_data, "    passwd: %s\n", hashed_pass);
    fprintf(user_data, "  - name: root\n");
    fprintf(user_data, "    lock_passwd: false\n");
    fprintf(user_data, "    passwd: %s\n\n", hashed_pass);
    fprintf(user_data, "# Packages to install\n");
    fprintf(user_data, "packages:\n");
    fprintf(user_data, "  - openssh-server\n");
    fprintf(user_data, "  - sudo\n");
    fprintf(user_data, "  - curl\n");
    fprintf(user_data, "  - wget\n");
    fprintf(user_data, "  - vim\n");
    fprintf(user_data, "  - net-tools\n");
    fprintf(user_data, "  - htop\n");
    fprintf(user_data, "  - avahi-daemon\n");
    fprintf(user_data, "  - avahi-utils\n\n");
    fprintf(user_data, "# Commands to run after boot\n");
    fprintf(user_data, "runcmd:\n");
    fprintf(user_data, "  - systemctl enable ssh\n");
    fprintf(user_data, "  - systemctl start ssh\n");
    fprintf(user_data, "  - systemctl enable avahi-daemon\n");
    fprintf(user_data, "  - systemctl start avahi-daemon\n");
    fprintf(user_data, "  - echo \"VM is ready!\" > /tmp/vm-ready\n\n");
    fprintf(user_data, "# Final message\n");
    fprintf(user_data, "final_message: \"VM %s is ready! SSH available on port 22.\"\n", vm_name);
    
    fclose(user_data);
    
    // Create meta-data file
    FILE *meta_data = fopen(meta_data_path, "w");
    if (meta_data == NULL) {
        log_error("Failed to create meta-data file");
        return 1;
    }
    
    fprintf(meta_data, "instance-id: %s-%ld\n", vm_name, time(NULL));
    fprintf(meta_data, "local-hostname: %s\n", vm_name);
    
    fclose(meta_data);
    return 0;
}

int create_vm(const char *vm_name, const char *distro, 
             const char *username, const char *password) {
    char distro_path[MAX_PATH];
    char vm_dir[MAX_PATH];
    char vm_disk[MAX_PATH];
    char vm_mac[18];
    
    snprintf(vm_dir, sizeof(vm_dir), "%s/.v4m/vms/%s", getenv("HOME"), vm_name);
    snprintf(vm_disk, sizeof(vm_disk), "%s/disk.qcow2", vm_dir);
    
    log_info("Creating VM...");
    
    // Check if VM already exists
    if (dir_exists(vm_dir)) {
        log_error("VM already exists");
        return 1;
    }
    
    mkdir(vm_dir, 0755);
    
    // Ensure distro is available
    if (ensure_distro(distro, distro_path, sizeof(distro_path)) != 0) {
        return 1;
    }
    
    // Copy and resize disk
    log_info("Setting up VM disk...");
    if (copy_file(distro_path, vm_disk) != 0) {
        log_error("Failed to copy disk image");
        return 1;
    }
    
    char resize_cmd[MAX_PATH * 2];
    snprintf(resize_cmd, sizeof(resize_cmd), "qemu-img resize \"%s\" %s >/dev/null", 
             vm_disk, DEFAULT_DISK_SIZE);
    if (system(resize_cmd) != 0) {
        log_error("Failed to resize disk");
        return 1;
    }
    
    // Generate MAC address
    generate_mac(vm_mac, sizeof(vm_mac));
    
    // Create EFI vars (simplified version)
    char efi_vars[MAX_PATH];
    snprintf(efi_vars, sizeof(efi_vars), "%s/efi-vars.fd", vm_dir);
    
    char efi_cmd[MAX_PATH];
    snprintf(efi_cmd, sizeof(efi_cmd), "dd if=/dev/zero of=\"%s\" bs=1M count=64 >/dev/null 2>&1", efi_vars);
    system(efi_cmd);
    
    // Create cloud-init files
    log_info("Configuring cloud-init...");
    if (create_cloud_init(vm_name, username, password, vm_dir) != 0) {
        return 1;
    }
    
    // Create cloud-init ISO
    char cloud_init_iso[MAX_PATH];
    char temp_dir[MAX_PATH];
    snprintf(cloud_init_iso, sizeof(cloud_init_iso), "%s/cloud-init.iso", vm_dir);
    snprintf(temp_dir, sizeof(temp_dir), "/tmp/cloud-init-%d", getpid());
    
    mkdir(temp_dir, 0755);
    
    char user_data_src[MAX_PATH], user_data_dest[MAX_PATH];
    char meta_data_src[MAX_PATH], meta_data_dest[MAX_PATH];
    
    snprintf(user_data_src, sizeof(user_data_src), "%s/user-data", vm_dir);
    snprintf(user_data_dest, sizeof(user_data_dest), "%s/user-data", temp_dir);
    snprintf(meta_data_src, sizeof(meta_data_src), "%s/meta-data", vm_dir);
    snprintf(meta_data_dest, sizeof(meta_data_dest), "%s/meta-data", temp_dir);
    
    copy_file(user_data_src, user_data_dest);
    copy_file(meta_data_src, meta_data_dest);
    
    char iso_cmd[MAX_PATH * 2];
    snprintf(iso_cmd, sizeof(iso_cmd), 
             "hdiutil makehybrid -iso -joliet -default-volume-name \"cidata\" -o \"%s\" \"%s\" >/dev/null 2>&1", 
             cloud_init_iso, temp_dir);
    
    if (system(iso_cmd) != 0) {
        log_error("Failed to create cloud-init ISO");
        char rm_cmd[MAX_PATH * 2];
        snprintf(rm_cmd, sizeof(rm_cmd), "rm -rf \"%s\" \"%s\"", temp_dir, vm_dir);
        system(rm_cmd);
        return 1;
    }
    
    // Clean up temp directory
    char rm_temp_cmd[MAX_PATH];
    snprintf(rm_temp_cmd, sizeof(rm_temp_cmd), "rm -rf \"%s\"", temp_dir);
    system(rm_temp_cmd);
    
    // Save VM info
    char vm_info_path[MAX_PATH];
    snprintf(vm_info_path, sizeof(vm_info_path), "%s/vm-info.json", vm_dir);
    
    FILE *vm_info = fopen(vm_info_path, "w");
    if (vm_info != NULL) {
        time_t now = time(NULL);
        struct tm *tm_info = gmtime(&now);
        char created[64];
        strftime(created, sizeof(created), "%Y-%m-%dT%H:%M:%SZ", tm_info);
        
        fprintf(vm_info, "{\n");
        fprintf(vm_info, "    \"name\": \"%s\",\n", vm_name);
        fprintf(vm_info, "    \"distro\": \"%s\",\n", distro);
        fprintf(vm_info, "    \"username\": \"%s\",\n", username);
        fprintf(vm_info, "    \"password\": \"%s\",\n", password);
        fprintf(vm_info, "    \"mac\": \"%s\",\n", vm_mac);
        fprintf(vm_info, "    \"memory\": \"%s\",\n", DEFAULT_MEMORY);
        fprintf(vm_info, "    \"cpus\": \"%s\",\n", DEFAULT_CPUS);
        fprintf(vm_info, "    \"disk_size\": \"%s\",\n", DEFAULT_DISK_SIZE);
        fprintf(vm_info, "    \"created\": \"%s\"\n", created);
        fprintf(vm_info, "}\n");
        
        fclose(vm_info);
    }
    
    log_success("VM created successfully");
    
    // Start VM
    return start_vm(vm_name, vm_mac, vm_dir);
}

int start_vm(const char *vm_name, const char *vm_mac, const char *vm_dir) {
    char vm_disk[MAX_PATH];
    char cloud_init_iso[MAX_PATH];
    char efi_vars[MAX_PATH];
    char log_file[MAX_PATH];
    char monitor_socket[MAX_PATH];
    char pid_file[MAX_PATH];
    char bridge_interface[16] = "en0"; // Default
    
    snprintf(vm_disk, sizeof(vm_disk), "%s/disk.qcow2", vm_dir);
    snprintf(cloud_init_iso, sizeof(cloud_init_iso), "%s/cloud-init.iso", vm_dir);
    snprintf(efi_vars, sizeof(efi_vars), "%s/efi-vars.fd", vm_dir);
    snprintf(log_file, sizeof(log_file), "%s/console.log", vm_dir);
    snprintf(monitor_socket, sizeof(monitor_socket), "%s/monitor.sock", vm_dir);
    snprintf(pid_file, sizeof(pid_file), "%s/vm.pid", vm_dir);
    
    // Try to get default interface
    get_default_interface(bridge_interface, sizeof(bridge_interface));
    
    log_info("Starting VM...");
    
    // Clean up old files
    FILE *log_fp = fopen(log_file, "w");
    if (log_fp != NULL) fclose(log_fp);
    remove(monitor_socket);
    
    // Build QEMU command
    char qemu_cmd[MAX_PATH * 10];
    snprintf(qemu_cmd, sizeof(qemu_cmd),
        "nohup qemu-system-aarch64 "
        "-machine virt "
        "-cpu host "
        "-accel hvf "
        "-smp %s "
        "-m %s "
        "-drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on "
        "-drive if=pflash,format=raw,file=\"%s\" "
        "-drive file=\"%s\",format=qcow2,if=virtio "
        "-drive file=\"%s\",media=cdrom,if=virtio,readonly=on "
        "-netdev vmnet-bridged,id=net0,ifname=%s "
        "-device virtio-net,netdev=net0,mac=%s "
        "-global PIIX4_PM.disable_s3=1 "
        "-monitor unix:\"%s\",server,nowait "
        "-serial unix:\"%s/console.sock\",server,nowait "
        "-device virtio-serial "
        "-chardev socket,path=\"%s/qga.sock\",server=on,wait=off,id=qga0 "
        "-device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 "
        "-nographic > \"%s\" 2>&1 &",
        DEFAULT_CPUS, DEFAULT_MEMORY, efi_vars, vm_disk, cloud_init_iso,
        bridge_interface, vm_mac, monitor_socket, vm_dir, vm_dir, log_file);
    
    int result = system(qemu_cmd);
    if (result != 0) {
        log_error("Failed to start QEMU");
        return 1;
    }
    
    // Get PID (simplified)
    char pid_cmd[MAX_PATH];
    snprintf(pid_cmd, sizeof(pid_cmd), "echo $! > \"%s\"", pid_file);
    system(pid_cmd);
    
    log_success("VM started");
    
    // Wait for VM to boot (simplified)
    log_info("Waiting for VM to boot...");
    sleep(60);
    
    show_vm_info(vm_name, vm_dir);
    return 0;
}

void show_vm_info(const char *vm_name, const char *vm_dir) {
    char vm_info_path[MAX_PATH];
    snprintf(vm_info_path, sizeof(vm_info_path), "%s/vm-info.json", vm_dir);
    
    FILE *fp = fopen(vm_info_path, "r");
    if (fp == NULL) {
        return;
    }
    
    char line[MAX_LINE];
    char username[MAX_NAME] = "";
    char password[MAX_NAME] = "";
    char mac[18] = "";
    
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, "\"username\"")) {
            sscanf(line, "    \"username\": \"%[^\"]\",", username);
        } else if (strstr(line, "\"password\"")) {
            sscanf(line, "    \"password\": \"%[^\"]\",", password);
        } else if (strstr(line, "\"mac\"")) {
            sscanf(line, "    \"mac\": \"%[^\"]\",", mac);
        }
    }
    fclose(fp);
    
    printf("\n" CYAN "═══════════════════════════════════════════════════════════" NC "\n");
    printf(CYAN "                        VM READY                            " NC "\n");
    printf(CYAN "═══════════════════════════════════════════════════════════" NC "\n\n");
    printf(YELLOW "VM Information:" NC "\n");
    printf("  Name: %s\n", vm_name);
    printf("  Memory: %sMB\n", DEFAULT_MEMORY);
    printf("  CPUs: %s\n", DEFAULT_CPUS);
    printf("\n" YELLOW "Login Credentials:" NC "\n");
    printf("  Username: %s\n", username);
    printf("  Password: %s\n", password);
    printf("  Root password: %s (same as user)\n", password);
    printf("  SSH: ssh %s@%s.local\n", username, vm_name);
    printf("\n" YELLOW "VM Management:" NC "\n");
    printf("  Stop: kill $(cat %s/vm.pid)\n", vm_dir);
    printf("\n");
}

// Utility functions
int execute_command(const char *command, char *output, size_t output_size) {
    FILE *fp = popen(command, "r");
    if (fp == NULL) {
        return -1;
    }
    
    if (output != NULL && output_size > 0) {
        if (fgets(output, output_size, fp) == NULL) {
            pclose(fp);
            return -1;
        }
        // Remove trailing newline
        output[strcspn(output, "\n")] = 0;
    }
    
    int status = pclose(fp);
    return WEXITSTATUS(status);
}

int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

int dir_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

int copy_file(const char *src, const char *dest) {
    char command[MAX_PATH * 3];
    snprintf(command, sizeof(command), "cp \"%s\" \"%s\"", src, dest);
    return system(command);
}

int get_default_interface(char *interface, size_t size) {
    // Simplified implementation - returns en0 by default
    // In a real implementation, you'd use getifaddrs() or similar
    strncpy(interface, "en0", size);
    return 0;
}