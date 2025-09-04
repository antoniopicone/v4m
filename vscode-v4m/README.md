# v4m VM Manager Extension

A Visual Studio Code extension for managing v4m Virtual Machines directly from the VS Code interface.

## Features

- **VM Explorer**: View all your virtual machines in a tree view with status indicators
- **VM Management**: Start, stop, delete VMs with context menu actions
- **Console Access**: Connect to VM console directly from VS Code
- **SSH Integration**: Quick SSH connections to running VMs
- **Image Management**: View available VM images
- **Status Monitoring**: Real-time VM status with visual indicators

## Requirements

- v4m VM manager installed and in PATH
- macOS with QEMU and socket_vmnet configured

## Usage

1. Open VS Code in a workspace
2. The v4m VM Manager panel will appear in the Explorer sidebar
3. Use the refresh button to update VM status
4. Right-click on VMs for context menu options
5. Use the + button to create new VMs

## Commands

- `v4m.refreshVMs` - Refresh VM list
- `v4m.createVM` - Create new VM
- `v4m.startVM` - Start selected VM
- `v4m.stopVM` - Stop selected VM
- `v4m.deleteVM` - Delete selected VM
- `v4m.connectConsole` - Connect to VM console
- `v4m.openSSH` - Open SSH connection

## Icons

- 🟢 Running VMs
- 🔴 Stopped VMs
- 📦 VM Images

## Development

```bash
npm install
npm run compile
```

Press F5 to launch extension development host.