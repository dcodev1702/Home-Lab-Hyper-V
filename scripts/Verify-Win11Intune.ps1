[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

Write-Host '--- Computer name'
$env:COMPUTERNAME

Write-Host '--- Installed tool versions'
$checks = @(
    @{ Name = 'PowerShell 7'; Command = 'pwsh'; Arguments = @('-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') },
    @{ Name = 'Python'; Command = 'python'; Arguments = @('--version') },
    @{ Name = 'Azure CLI'; Command = 'az'; Arguments = @('--version') },
    @{ Name = 'GitHub CLI'; Command = 'gh'; Arguments = @('--version') },
    @{ Name = 'Node.js'; Command = 'node'; Arguments = @('--version') },
    @{ Name = 'VS Code'; Command = 'code'; Arguments = @('--version') }
)

foreach ($check in $checks) {
    Write-Host "--- $($check.Name)"
    $command = Get-Command $check.Command -ErrorAction SilentlyContinue
    if ($command) {
        & $command.Source @($check.Arguments)
    }
    else {
        Write-Warning "$($check.Command) was not found on PATH."
    }
}

Write-Host '--- Entra ID and MDM status'
if (Get-Command dsregcmd.exe -ErrorAction SilentlyContinue) {
    dsregcmd /status
}
else {
    Write-Warning 'dsregcmd.exe was not found.'
}

Write-Host '--- Azure CLI extensions'
if (Get-Command az.cmd -ErrorAction SilentlyContinue) {
    az extension list --output table
}
else {
    Write-Warning 'Azure CLI was not found on PATH.'
}