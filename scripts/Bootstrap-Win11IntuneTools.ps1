[CmdletBinding()]
param(
    [string[]]$AzCliExtensions = @('log-analytics', 'kusto'),
    [string[]]$VSCodeExtensions = @(
        'ms-vscode.powershell',
        'ms-python.python',
        'ms-azuretools.vscode-azurecli',
        'ms-vscode.azure-account',
        'ms-kusto.kusto'
    )
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-Host "Installing $Name..."
    winget install --id $Id --exact --silent --accept-source-agreements --accept-package-agreements
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session inside the VM.'
}

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget was not found. Install or update App Installer from Microsoft Store, then rerun this script.'
}

$packages = @(
    @{ Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7' },
    @{ Id = 'Python.Python.3.13'; Name = 'Python 3.13' },
    @{ Id = 'Microsoft.AzureCLI'; Name = 'Azure CLI' },
    @{ Id = 'Git.Git'; Name = 'Git' },
    @{ Id = 'GitHub.cli'; Name = 'GitHub CLI' },
    @{ Id = 'OpenJS.NodeJS'; Name = 'Node.js current' },
    @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code' }
)

foreach ($package in $packages) {
    Install-WinGetPackage -Id $package.Id -Name $package.Name
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$machinePath;$userPath"

$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh)) {
    throw 'PowerShell 7 was not found after installation. Restart the shell and rerun this script.'
}

Write-Host 'Installing Az PowerShell module for PowerShell 7...'
& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module Az -Scope AllUsers -Force -AllowClobber"

if (Get-Command az.cmd -ErrorAction SilentlyContinue) {
    Write-Host 'Updating Azure CLI extensions...'
    az config set extension.use_dynamic_install=yes_without_prompt | Out-Null
    foreach ($extension in $AzCliExtensions) {
        Write-Host "Installing Azure CLI extension: $extension"
        az extension add --name $extension --upgrade 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Azure CLI extension '$extension' was not installed. Check whether this extension name is available in your Azure CLI version."
        }
    }
}
else {
    Write-Warning 'Azure CLI was installed but az.cmd is not available in this shell yet. Restart PowerShell and run az extension add commands manually.'
}

$codeCommand = Get-Command code.cmd -ErrorAction SilentlyContinue
if ($codeCommand) {
    foreach ($extension in $VSCodeExtensions) {
        Write-Host "Installing VS Code extension: $extension"
        code --install-extension $extension --force
    }
}
else {
    Write-Warning 'VS Code was installed but code.cmd is not available in this shell yet. Restart PowerShell and install the listed extensions manually.'
}

Write-Host 'Installed tool versions:'
$versionCommands = @(
    @{ Name = 'PowerShell 7'; Command = { & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' } },
    @{ Name = 'Python'; Command = { python --version } },
    @{ Name = 'Azure CLI'; Command = { az version --output table } },
    @{ Name = 'GitHub CLI'; Command = { gh --version } },
    @{ Name = 'Node.js'; Command = { node --version } },
    @{ Name = 'npm'; Command = { npm --version } },
    @{ Name = 'VS Code'; Command = { code --version } }
)

foreach ($item in $versionCommands) {
    Write-Host "--- $($item.Name)"
    try {
        & $item.Command
    }
    catch {
        Write-Warning $_.Exception.Message
    }
}

Write-Host 'Bootstrap complete. Restart the VM before Intune enrollment if installers requested it.'