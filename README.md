# v4m - VMs for macOS

A quick provisioning tool to spin up Linux VMs on macOS using QEMU and cloud-init.

## Quick Start

1. **Setup the VM** (one-time):
   ```bash
   ./vm-debian-cloud.sh setup
   ```

2. **Start the VM**:
   ```bash
   ./vm-debian-cloud.sh start
   ```

3. **Connect via SSH**:
   ```bash
   ssh antonio@<VM_IP>
   ```
   Use `./vm-debian-cloud.sh status` to find the VM's IP address.

## Commands

- `setup` - Download Debian image and prepare VM
- `start` - Start VM in background
- `status` - Show VM status and IP address
- `stop` - Gracefully shutdown VM
- `clean` - Stop VM and remove all files

## Configuration

The VM uses cloud-init for automatic configuration:

- **user-data.yaml** - User accounts, SSH keys, packages
- **meta-data.yaml** - VM hostname and metadata

Copy `user-data.example.yaml` to `user-data.yaml` and customize as needed.

## VM Specifications

- **OS**: Debian 12 (ARM64)
- **Memory**: 4GB
- **CPUs**: 4 cores
- **Disk**: 20GB
- **Network**: DHCP via host network

## Requirements

- macOS with Apple Silicon
- QEMU (install via `brew install qemu`)
- VM gets IP from host network automatically