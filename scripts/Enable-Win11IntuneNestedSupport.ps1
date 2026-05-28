[CmdletBinding()]
param(
    [string]$VMName = 'WIN11-INTUNE'
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session on the Hyper-V host.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDirectory = Join-Path $projectRoot 'logs'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDirectory "Enable-Nested-$VMName-$timestamp.log"

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$exitCode = 0
try {
    Start-Transcript -Path $logPath -Force | Out-Null
    Import-Module Hyper-V -ErrorAction Stop

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        throw "VM '$VMName' must be Off before nested virtualization and adapter settings are changed. Current state: $($vm.State)."
    }

    Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true

    $adapters = @(Get-VMNetworkAdapter -VMName $VMName)
    foreach ($adapter in $adapters) {
        Set-VMNetworkAdapter -VMName $VMName -Name $adapter.Name -MacAddressSpoofing On
    }

    Write-Host "Nested virtualization and MAC address spoofing enabled for '$VMName'."
    Get-VMProcessor -VMName $VMName | Select-Object VMName,Count,ExposeVirtualizationExtensions | Format-List
    Get-VMNetworkAdapter -VMName $VMName | Select-Object VMName,Name,SwitchName,MacAddressSpoofing,Status | Format-Table -AutoSize
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