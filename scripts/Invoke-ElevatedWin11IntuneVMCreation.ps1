[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDirectory = Join-Path $projectRoot 'logs'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDirectory "Create-WIN11-INTUNE-$timestamp.log"

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Set-Location $projectRoot

$exitCode = 0
try {
    Start-Transcript -Path $logPath -Force | Out-Null
    Write-Host "Provisioning WIN11-INTUNE from WIN11-WSL2 specs..."
    Write-Host "Log path: $logPath"
    .\scripts\Provision-Win11HyperVVM.ps1 -VMName 'WIN11-INTUNE' -NoSelfElevate
    Write-Host 'WIN11-INTUNE provisioning entrypoint completed.'
}
catch {
    $exitCode = 1
    Write-Error $_
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}

exit $exitCode