import * as vscode from 'vscode';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

interface VMInfo {
    name: string;
    image: string;
    cpus: string;
    memory: string;
    diskSize: string;
    diskUsed: string;
    ip: string;
    status: 'running' | 'stopped';
}

interface ImageInfo {
    name: string;
    size: string;
}

export function activate(context: vscode.ExtensionContext) {
    const vmProvider = new VMProvider();
    const imageProvider = new ImageProvider();
    
    // Register tree data providers
    vscode.window.registerTreeDataProvider('v4mExplorer', vmProvider);
    vscode.window.registerTreeDataProvider('v4mImages', imageProvider);

    // Register VM commands
    context.subscriptions.push(
        vscode.commands.registerCommand('v4m.refreshVMs', () => vmProvider.refresh()),
        vscode.commands.registerCommand('v4m.refreshImages', () => imageProvider.refresh()),
        vscode.commands.registerCommand('v4m.init', () => runV4MInit()),
        vscode.commands.registerCommand('v4m.checkStatus', () => checkV4MStatus()),
        vscode.commands.registerCommand('v4m.createVM', () => createVM(vmProvider)),
        vscode.commands.registerCommand('v4m.startVM', (vm: VMItem) => startVM(vm, vmProvider)),
        vscode.commands.registerCommand('v4m.stopVM', (vm: VMItem) => stopVM(vm, vmProvider)),
        vscode.commands.registerCommand('v4m.deleteVM', (vm: VMItem) => deleteVM(vm, vmProvider)),
        vscode.commands.registerCommand('v4m.connectConsole', (vm: VMItem) => connectConsole(vm)),
        vscode.commands.registerCommand('v4m.openSSH', (vm: VMItem) => openSSH(vm)),
        vscode.commands.registerCommand('v4m.pullImage', () => pullImage(imageProvider))
    );
}

class VMProvider implements vscode.TreeDataProvider<VMItem> {
    private _onDidChangeTreeData: vscode.EventEmitter<VMItem | undefined | null | void> = new vscode.EventEmitter<VMItem | undefined | null | void>();
    readonly onDidChangeTreeData: vscode.Event<VMItem | undefined | null | void> = this._onDidChangeTreeData.event;

    refresh(): void {
        this._onDidChangeTreeData.fire();
    }

    getTreeItem(element: VMItem): vscode.TreeItem {
        return element;
    }

    async getChildren(element?: VMItem): Promise<VMItem[]> {
        if (element) {
            return [];
        }
        return this.getVMs();
    }

    private async getVMs(): Promise<VMItem[]> {
        try {
            const { stdout } = await execAsync('/Users/antonio/Developer/antoniopicone/vm_tests/v4m/v4m vm list 2>/dev/null || echo ""');
            
            // Remove ANSI escape codes
            const cleanOutput = stdout.replace(/\u001b\[[0-9;]*m/g, '').replace(/\[\?[0-9]+[hl]/g, '');
            const lines = cleanOutput.trim().split('\n');
            
            console.log('Raw v4m output lines:', lines.length);
            lines.forEach((line, i) => console.log(`Line ${i}: "${line}"`));
            
            // Skip header lines and empty lines
            const vmLines = lines.filter(line => {
                const trimmed = line.trim();
                return trimmed && 
                       !trimmed.includes('Virtual Machines:') && 
                       !trimmed.includes('NAME') && 
                       !trimmed.includes('----') &&
                       !trimmed.includes('No VMs found') &&
                       trimmed.length > 10; // Ensure it's a data line
            });
            
            console.log('Filtered VM lines:', vmLines.length);
            vmLines.forEach((line, i) => console.log(`VM Line ${i}: "${line}"`));

            return vmLines.map(line => {
                try {
                    // Parse fixed-width columns based on the header positions
                    const trimmed = line.trim();
                    if (trimmed.length < 20) return null;
                    
                    // Extract fields by position (approximated from header)
                    const name = trimmed.substring(0, 16).trim();
                    const image = trimmed.substring(16, 27).trim() || 'unknown';
                    const cpus = trimmed.substring(27, 33).trim();
                    const memory = trimmed.substring(33, 42).trim();
                    const diskSize = trimmed.substring(42, 53).trim();
                    const diskUsed = trimmed.substring(53, 64).trim();
                    const ip = trimmed.substring(64, 80).trim();
                    const statusPart = trimmed.substring(80).trim();
                    const status = statusPart.toLowerCase().includes('running') ? 'running' : 'stopped';
                    
                    if (name && name !== '----') {
                        return new VMItem({
                            name, image, cpus, memory, diskSize, diskUsed, ip, status
                        });
                    }
                } catch (e) {
                    console.error('Error parsing line:', line, e);
                }
                return null;
            }).filter(vm => vm !== null) as VMItem[];
        } catch (error) {
            console.error('Failed to get VMs:', error);
            return [];
        }
    }
}

class ImageProvider implements vscode.TreeDataProvider<ImageItem> {
    private _onDidChangeTreeData: vscode.EventEmitter<ImageItem | undefined | null | void> = new vscode.EventEmitter<ImageItem | undefined | null | void>();
    readonly onDidChangeTreeData: vscode.Event<ImageItem | undefined | null | void> = this._onDidChangeTreeData.event;

    refresh(): void {
        this._onDidChangeTreeData.fire();
    }

    getTreeItem(element: ImageItem): vscode.TreeItem {
        return element;
    }

    async getChildren(element?: ImageItem): Promise<ImageItem[]> {
        if (element) {
            return [];
        }
        return this.getImages();
    }

    private async getImages(): Promise<ImageItem[]> {
        try {
            const { stdout } = await execAsync('/Users/antonio/Developer/antoniopicone/vm_tests/v4m/v4m image list 2>/dev/null || echo ""');
            
            // Remove ANSI escape codes
            const cleanOutput = stdout.replace(/\u001b\[[0-9;]*m/g, '').replace(/\[\?[0-9]+[hl]/g, '');
            const lines = cleanOutput.trim().split('\n');
            
            const images: ImageItem[] = [];
            for (const line of lines) {
                // Match the emoji and image info: "  📦 debian12 (417M)"
                const match = line.match(/📦\s+(\S+)\s+\(([^)]+)\)/);
                if (match) {
                    const name = match[1];
                    const size = match[2];
                    images.push(new ImageItem({ name, size }));
                }
            }
            
            return images;
        } catch (error) {
            console.error('Failed to get images:', error);
            return [];
        }
    }
}

class VMItem extends vscode.TreeItem {
    constructor(public readonly vmInfo: VMInfo) {
        super(vmInfo.name, vscode.TreeItemCollapsibleState.None);
        
        this.tooltip = `${vmInfo.name} (${vmInfo.image})
Status: ${vmInfo.status}
IP: ${vmInfo.ip}
CPUs: ${vmInfo.cpus}, Memory: ${vmInfo.memory}
Disk: ${vmInfo.diskUsed}/${vmInfo.diskSize}`;
        
        this.description = `${vmInfo.status} • ${vmInfo.ip}`;
        this.contextValue = `vm-${vmInfo.status}`;
        
        // Set icon based on status
        if (vmInfo.status === 'running') {
            this.iconPath = new vscode.ThemeIcon('vm-running', new vscode.ThemeColor('charts.green'));
        } else {
            this.iconPath = new vscode.ThemeIcon('vm-outline', new vscode.ThemeColor('charts.red'));
        }
    }
}

class ImageItem extends vscode.TreeItem {
    constructor(public readonly imageInfo: ImageInfo) {
        super(imageInfo.name, vscode.TreeItemCollapsibleState.None);
        
        this.tooltip = `${imageInfo.name} image (${imageInfo.size})`;
        this.description = imageInfo.size;
        this.contextValue = 'image';
        this.iconPath = new vscode.ThemeIcon('package');
    }
}

async function runV4MInit() {
    const terminal = vscode.window.createTerminal('v4m Init');
    terminal.sendText('v4m v4m_init');
    terminal.show();
}

async function checkV4MStatus() {
    try {
        const { stdout } = await execAsync('/Users/antonio/Developer/antoniopicone/vm_tests/v4m/v4m v4m_init --check');
        vscode.window.showInformationMessage(`v4m Status: ${stdout.includes('All checks passed') ? 'Ready' : 'Needs Setup'}`);
    } catch (error) {
        vscode.window.showErrorMessage('Failed to check v4m status');
    }
}

async function createVM(provider: VMProvider) {
    const name = await vscode.window.showInputBox({
        prompt: 'Enter VM name (optional)',
        placeHolder: 'Leave empty for random name'
    });

    const image = await vscode.window.showQuickPick([
        'debian12',
        'debian13', 
        'ubuntu22',
        'ubuntu24'
    ], {
        placeHolder: 'Select image'
    });

    if (!image) {
        return;
    }

    const username = await vscode.window.showInputBox({
        prompt: 'Enter username (optional)',
        placeHolder: 'user01',
        value: 'user01'
    });

    let command = `v4m vm create --image "${image}"`;
    if (name) {
        command += ` --name "${name}"`;
    }
    if (username) {
        command += ` --user "${username}"`;
    }

    const terminal = vscode.window.createTerminal('v4m Create VM');
    terminal.sendText(command);
    terminal.show();

    // Refresh VMs after a delay
    setTimeout(() => provider.refresh(), 3000);
}

async function startVM(vm: VMItem, provider: VMProvider) {
    const terminal = vscode.window.createTerminal(`v4m Start ${vm.vmInfo.name}`);
    terminal.sendText(`v4m vm start "${vm.vmInfo.name}"`);
    terminal.show();

    setTimeout(() => provider.refresh(), 2000);
}

async function stopVM(vm: VMItem, provider: VMProvider) {
    const terminal = vscode.window.createTerminal(`v4m Stop ${vm.vmInfo.name}`);
    terminal.sendText(`v4m vm stop "${vm.vmInfo.name}"`);
    terminal.show();

    setTimeout(() => provider.refresh(), 2000);
}

async function deleteVM(vm: VMItem, provider: VMProvider) {
    const result = await vscode.window.showWarningMessage(
        `Are you sure you want to delete VM '${vm.vmInfo.name}'?`,
        { modal: true },
        'Delete',
        'Cancel'
    );

    if (result === 'Delete') {
        const terminal = vscode.window.createTerminal(`v4m Delete ${vm.vmInfo.name}`);
        terminal.sendText(`v4m vm delete "${vm.vmInfo.name}"`);
        terminal.show();

        setTimeout(() => provider.refresh(), 2000);
    }
}

async function connectConsole(vm: VMItem) {
    const terminal = vscode.window.createTerminal(`Console: ${vm.vmInfo.name}`);
    terminal.sendText(`v4m vm console "${vm.vmInfo.name}"`);
    terminal.show();
}

async function openSSH(vm: VMItem) {
    if (vm.vmInfo.ip === '-' || !vm.vmInfo.ip) {
        vscode.window.showErrorMessage('VM IP address not available');
        return;
    }

    // Extract username from vm info or ask user
    const config = vscode.workspace.getConfiguration('v4m');
    const defaultUsername = config.get<string>('defaultUsername', 'user01');
    
    const username = await vscode.window.showInputBox({
        prompt: 'Enter SSH username',
        placeHolder: defaultUsername,
        value: defaultUsername
    });

    if (!username) {
        return;
    }

    const terminal = vscode.window.createTerminal(`SSH: ${vm.vmInfo.name}`);
    terminal.sendText(`ssh ${username}@${vm.vmInfo.name}.local`);
    terminal.show();
}

async function pullImage(provider: ImageProvider) {
    const image = await vscode.window.showQuickPick([
        'debian12',
        'debian13',
        'ubuntu22', 
        'ubuntu24'
    ], {
        placeHolder: 'Select image to pull'
    });

    if (!image) {
        return;
    }

    const terminal = vscode.window.createTerminal(`v4m Pull ${image}`);
    terminal.sendText(`v4m image pull "${image}"`);
    terminal.show();

    setTimeout(() => provider.refresh(), 5000);
}

export function deactivate() {}