[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')]
    [string]$VMName,

    [string]$SourceVMName = 'WIN11-WSL2',

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IsoPath = 'C:\Users\Lorenzo\Downloads\Windows isos\Windows 11 Enterprise\en-us_windows_11_business_editions_version_26h1_updated_march_2026_x64_dvd_f163b1c8.iso',

    [string]$VMRoot = '',

    [switch]$CreateTemplateVM,

    [switch]$NoSelfElevate
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory)][string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Enable-NestedSupportWhileOff {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        throw "VM '$Name' must be Off before enabling nested virtualization and nested networking. Current state: $($vm.State)."
    }

    Write-Host "Enabling nested virtualization for '$Name' while the VM is Off."
    Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true

    $adapters = @(Get-VMNetworkAdapter -VMName $Name)
    if ($adapters.Count -eq 0) {
        throw "VM '$Name' has no network adapters to configure for nested networking."
    }

    foreach ($adapter in $adapters) {
        Write-Host "Enabling MAC address spoofing for adapter '$($adapter.Name)' on '$Name'."
        Set-VMNetworkAdapter -VMName $Name -Name $adapter.Name -MacAddressSpoofing On
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$safeVMName = $VMName -replace '[^A-Za-z0-9_.-]', '_'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDirectory = Join-Path $projectRoot 'logs'
$reportDirectory = Join-Path $projectRoot 'reports'
$templateDirectory = Join-Path $projectRoot 'templates'
$logPath = Join-Path $logDirectory ("Provision-$safeVMName-$timestamp.log")
$reportPath = Join-Path $reportDirectory ("Provision-$safeVMName-$timestamp.validation.json")
$templateSpecPath = Join-Path $templateDirectory ("$safeVMName.hyperv-template.json")

if (-not (Test-IsAdministrator)) {
    if ($NoSelfElevate) {
        throw 'This provisioning entrypoint requires an elevated PowerShell session on the Hyper-V host.'
    }

    Write-Host "Elevated Hyper-V access is needed to create '$VMName', create its VHDX, attach the ISO, configure TPM, enable nested virtualization, and enable MAC address spoofing."
    Write-Host 'Approve the Windows UAC prompt to continue.'

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (ConvertTo-CommandLineArgument -Value $PSCommandPath),
        '-VMName',
        (ConvertTo-CommandLineArgument -Value $VMName),
        '-SourceVMName',
        (ConvertTo-CommandLineArgument -Value $SourceVMName),
        '-IsoPath',
        (ConvertTo-CommandLineArgument -Value $IsoPath),
        '-NoSelfElevate'
    )

    if (-not [string]::IsNullOrWhiteSpace($VMRoot)) {
        $arguments += @('-VMRoot', (ConvertTo-CommandLineArgument -Value $VMRoot))
    }

    if ($CreateTemplateVM) {
        $arguments += '-CreateTemplateVM'
    }

    try {
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ($arguments -join ' ') -Verb RunAs -Wait -PassThru
        Write-Host "Elevated provisioning exit code: $($process.ExitCode)"
        exit $process.ExitCode
    }
    catch {
        throw "Elevated provisioning launch failed: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $templateDirectory -Force | Out-Null
Set-Location $projectRoot

$exitCode = 0
try {
    Start-Transcript -Path $logPath -Force | Out-Null
    Import-Module Hyper-V -ErrorAction Stop

    if ($VMName -eq $SourceVMName) {
        throw "Target VM name '$VMName' cannot match source VM name '$SourceVMName'."
    }

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "A Hyper-V VM named '$VMName' already exists. Provisioning is intentionally non-destructive; choose a new name or remove the existing VM intentionally."
    }

    Get-VM -Name $SourceVMName -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "ISO path was not found: $IsoPath"
    }

    $createParameters = @{
        VMName           = $VMName
        SourceVMName     = $SourceVMName
        IsoPath          = $IsoPath
        TemplateSpecPath = $templateSpecPath
        TemplateVMName   = "$VMName-TEMPLATE"
    }

    if (-not [string]::IsNullOrWhiteSpace($VMRoot)) {
        $createParameters['VMRoot'] = $VMRoot
    }

    if ($CreateTemplateVM) {
        $createParameters['CreateTemplateVM'] = $true
    }

    Write-Host "Provisioning Hyper-V VM '$VMName' from source '$SourceVMName'."
    Write-Host "Provisioning log: $logPath"
    Write-Host "Validation report: $reportPath"
    Write-Host "Template spec: $templateSpecPath"

    .\scripts\New-Win11IntuneVM.ps1 @createParameters
    Enable-NestedSupportWhileOff -Name $VMName
    .\scripts\Test-HyperVVmProvision.ps1 -VMName $VMName -SourceVMName $SourceVMName -IsoPath $IsoPath -ReportPath $reportPath

    Write-Host "Provisioning completed and validated for '$VMName'."
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