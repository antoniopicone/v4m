# v4m VSCode Extension Installation

## Installation Steps

1. **Install Dependencies**:
   ```bash
   npm install -g @vscode/vsce
   ```

2. **Package the Extension**:
   ```bash
   cd vscode-v4m
   npm install
   npm run compile
   vsce package
   ```

3. **Install in VSCode**:
   - Open VS Code
   - Go to Extensions panel (Ctrl+Shift+X)
   - Click the "..." menu → "Install from VSIX..."
   - Select the generated `.vsix` file
   - Reload VS Code when prompted

4. **Usage**:
   - The extension will automatically activate when you open a workspace with v4m
   - Look for the "v4m Virtual Machines" panel in the Explorer sidebar
   - Use the refresh button to update VM status
   - Right-click VMs for management options

## Features

- ✅ VM tree view with status indicators
- ✅ Context menu actions (start, stop, delete)
- ✅ Console connection
- ✅ SSH integration
- ✅ Image management view
- ✅ Real-time status updates

## Requirements

- v4m command-line tool must be installed and in PATH
- VSCode 1.74.0 or higher