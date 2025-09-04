#!/bin/bash
# v4m - Cloud-init configuration management

create_cloud_init() {
    local vm_name="$1"
    local username="$2"
    local password="$3"
    local vm_dir="$4"
    
    local hashed_pass=$(hash_password "$password")
    
    # Convert packages string to array for YAML formatting
    local packages_array=""
    if [ -n "$packages" ]; then
        for pkg in $packages; do
            packages_array="$packages_array  - $pkg\n"
        done
    else
        # Fallback packages if config is empty
        packages_array="  - openssh-server\n  - sudo\n  - curl\n  - wget\n  - vim\n  - net-tools\n  - htop\n  - avahi-daemon\n  - avahi-utils\n"
    fi
    
    cat > "$vm_dir/user-data" << EOF
#cloud-config

hostname: $vm_name
fqdn: $vm_name.local
timezone: $timezone

ssh_pwauth: true
disable_root: false

network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false

users:
  - name: $username
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, users]
    shell: /bin/bash
    lock_passwd: false
    passwd: $hashed_pass
  - name: root
    lock_passwd: false
    passwd: $hashed_pass

packages:
$(echo -e "$packages_array")

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable avahi-daemon
  - systemctl start avahi-daemon
  - echo "VM is ready!" > /tmp/vm-ready

final_message: "VM $vm_name is ready! SSH available on port 22."
EOF

    cat > "$vm_dir/meta-data" << EOF
instance-id: $vm_name-$(date +%s)
local-hostname: $vm_name
EOF
}