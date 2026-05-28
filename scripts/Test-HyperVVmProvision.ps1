[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')]
    [string]$VMName,

    [string]$SourceVMName = 'WIN11-WSL2',

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IsoPath = 'C:\Users\Lorenzo\Downloads\Windows isos\Windows 11 Enterprise\en-us_windows_11_business_editions_version_26h1_updated_march_2026_x64_dvd_f163b1c8.iso',

    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-OnValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    return ($Value -eq $true) -or ($Value -eq 1) -or ($Value.ToString() -eq 'On')
}

function Get-VMTPMState {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $getVmTpmCommand = Get-Command Get-VMTPM -ErrorAction SilentlyContinue
    if ($getVmTpmCommand) {
        $tpm = Get-VMTPM -VMName $Name -ErrorAction SilentlyContinue
        if ($tpm) {
            return [bool](Get-PropertyValue -InputObject $tpm -Name 'Enabled')
        }
    }

    $getVmSecurityCommand = Get-Command Get-VMSecurity -ErrorAction SilentlyContinue
    if ($getVmSecurityCommand) {
        $security = Get-VMSecurity -VMName $Name -ErrorAction SilentlyContinue
        if ($security) {
            foreach ($propertyName in @('TpmEnabled', 'TPMEnabled', 'TrustedPlatformModuleEnabled')) {
                $propertyValue = Get-PropertyValue -InputObject $security -Name $propertyName
                if ($null -ne $propertyValue) {
                    return [bool]$propertyValue
                }
            }
        }
    }

    $getKeyProtectorCommand = Get-Command Get-VMKeyProtector -ErrorAction SilentlyContinue
    if ($getKeyProtectorCommand) {
        $keyProtector = Get-VMKeyProtector -VMName $Name -ErrorAction SilentlyContinue
        return [bool]$keyProtector
    }

    return $false
}

function Add-Check {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [object]$Expected,

        [object]$Actual,

        [string]$Detail = ''
    )

    $check = [pscustomobject][ordered]@{
        Name     = $Name
        Passed   = $Passed
        Expected = $Expected
        Actual   = $Actual
        Detail   = $Detail
    }
    $script:checks.Add($check) | Out-Null

    if ($Passed) {
        Write-Host "PASS: $Name"
    }
    else {
        Write-Warning "FAIL: $Name"
    }
}

function Add-EqualityCheck {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [object]$Expected,

        [object]$Actual,

        [string]$Detail = ''
    )

    Add-Check -Name $Name -Passed ($Expected -eq $Actual) -Expected $Expected -Actual $Actual -Detail $Detail
}

function Resolve-SourceVM {
    param([string]$Name)

    try {
        return Get-VM -Name $Name -ErrorAction Stop
    }
    catch {
        if ($Name -eq 'WIN11-WSL2') {
            $fallback = Get-VM -Name 'WIN11-WLS2' -ErrorAction SilentlyContinue
            if ($fallback) {
                Write-Warning "Source VM 'WIN11-WSL2' was not found. Using fallback source VM 'WIN11-WLS2'."
                $script:SourceVMName = 'WIN11-WLS2'
                return $fallback
            }
        }

        throw
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session on the Hyper-V host.'
}

Import-Module Hyper-V -ErrorAction Stop

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportDirectory = Join-Path $projectRoot 'reports'
    $ReportPath = Join-Path $reportDirectory ("Provision-{0}-{1}.validation.json" -f $VMName, $timestamp)
}

New-Item -ItemType Directory -Path (Split-Path -Parent $ReportPath) -Force | Out-Null

$checks = [System.Collections.Generic.List[object]]::new()

$sourceVM = Resolve-SourceVM -Name $SourceVMName
$targetVM = Get-VM -Name $VMName -ErrorAction Stop

Add-Check -Name 'Target VM exists' -Passed ($null -ne $targetVM) -Expected $VMName -Actual $targetVM.Name
Add-EqualityCheck -Name 'Target VM is powered off after provisioning' -Expected 'Off' -Actual $targetVM.State.ToString() -Detail 'This validation is intended to run immediately after provisioning, before the first VM start.'
Add-Check -Name 'Target VM has a unique Hyper-V VM ID' -Passed ($targetVM.Id -ne $sourceVM.Id) -Expected "Not $($sourceVM.Id.Guid)" -Actual $targetVM.Id.Guid
Add-EqualityCheck -Name 'Generation matches source VM' -Expected $sourceVM.Generation -Actual $targetVM.Generation
Add-EqualityCheck -Name 'VM version matches source VM' -Expected $sourceVM.Version.ToString() -Actual $targetVM.Version.ToString()
Add-EqualityCheck -Name 'Checkpoint type matches source VM' -Expected $sourceVM.CheckpointType.ToString() -Actual $targetVM.CheckpointType.ToString()
Add-EqualityCheck -Name 'Automatic checkpoints match source VM' -Expected $sourceVM.AutomaticCheckpointsEnabled -Actual $targetVM.AutomaticCheckpointsEnabled
Add-EqualityCheck -Name 'Automatic start action matches source VM' -Expected $sourceVM.AutomaticStartAction.ToString() -Actual $targetVM.AutomaticStartAction.ToString()
Add-EqualityCheck -Name 'Automatic stop action matches source VM' -Expected $sourceVM.AutomaticStopAction.ToString() -Actual $targetVM.AutomaticStopAction.ToString()
Add-Check -Name 'VM folder name carries target VM name' -Passed ((Split-Path -Path $targetVM.Path -Leaf) -ieq $VMName) -Expected $VMName -Actual (Split-Path -Path $targetVM.Path -Leaf)

$sourceMemory = Get-VMMemory -VMName $SourceVMName
$targetMemory = Get-VMMemory -VMName $VMName
Add-EqualityCheck -Name 'Dynamic memory mode matches source VM' -Expected $sourceMemory.DynamicMemoryEnabled -Actual $targetMemory.DynamicMemoryEnabled
Add-EqualityCheck -Name 'Startup memory matches source VM' -Expected ([int64]$sourceMemory.Startup) -Actual ([int64]$targetMemory.Startup)
Add-EqualityCheck -Name 'Minimum memory matches source VM' -Expected ([int64]$sourceMemory.Minimum) -Actual ([int64]$targetMemory.Minimum)
Add-EqualityCheck -Name 'Maximum memory matches source VM' -Expected ([int64]$sourceMemory.Maximum) -Actual ([int64]$targetMemory.Maximum)

$sourceProcessor = Get-VMProcessor -VMName $SourceVMName
$targetProcessor = Get-VMProcessor -VMName $VMName
Add-EqualityCheck -Name 'Processor count matches source VM' -Expected ([int64]$sourceProcessor.Count) -Actual ([int64]$targetProcessor.Count)
Add-Check -Name 'Nested virtualization is enabled' -Passed ([bool]$targetProcessor.ExposeVirtualizationExtensions) -Expected $true -Actual ([bool]$targetProcessor.ExposeVirtualizationExtensions)

$sourceHardDisks = @(Get-VMHardDiskDrive -VMName $SourceVMName | Sort-Object ControllerType, ControllerNumber, ControllerLocation)
$targetHardDisks = @(Get-VMHardDiskDrive -VMName $VMName | Sort-Object ControllerType, ControllerNumber, ControllerLocation)
Add-EqualityCheck -Name 'Virtual hard disk count matches source VM' -Expected $sourceHardDisks.Count -Actual $targetHardDisks.Count

for ($index = 0; $index -lt $targetHardDisks.Count; $index++) {
    $sourceDisk = $sourceHardDisks[$index]
    $targetDisk = $targetHardDisks[$index]
    $sourceVhd = Get-VHD -Path $sourceDisk.Path
    $targetVhd = Get-VHD -Path $targetDisk.Path
    $diskLabel = "Disk $index"

    Add-Check -Name "$diskLabel VHD path carries target VM name" -Passed (([IO.Path]::GetFileNameWithoutExtension($targetDisk.Path)).StartsWith($VMName, [StringComparison]::OrdinalIgnoreCase)) -Expected "$VMName*" -Actual ([IO.Path]::GetFileName($targetDisk.Path))
    Add-Check -Name "$diskLabel VHD is unique to target VM" -Passed ($targetDisk.Path -ne $sourceDisk.Path) -Expected "Not $($sourceDisk.Path)" -Actual $targetDisk.Path
    Add-EqualityCheck -Name "$diskLabel controller type matches source VM" -Expected $sourceDisk.ControllerType.ToString() -Actual $targetDisk.ControllerType.ToString()
    Add-EqualityCheck -Name "$diskLabel controller number matches source VM" -Expected $sourceDisk.ControllerNumber -Actual $targetDisk.ControllerNumber
    Add-EqualityCheck -Name "$diskLabel controller location matches source VM" -Expected $sourceDisk.ControllerLocation -Actual $targetDisk.ControllerLocation
    Add-EqualityCheck -Name "$diskLabel VHD size matches source VM" -Expected ([uint64]$sourceVhd.Size) -Actual ([uint64]$targetVhd.Size)
    Add-EqualityCheck -Name "$diskLabel VHD type matches source VM" -Expected $sourceVhd.VhdType.ToString() -Actual $targetVhd.VhdType.ToString()
    Add-EqualityCheck -Name "$diskLabel VHD format matches source VM" -Expected $sourceVhd.VhdFormat.ToString() -Actual $targetVhd.VhdFormat.ToString()
}

$dvdDrives = @(Get-VMDvdDrive -VMName $VMName)
Add-Check -Name 'Windows ISO is attached' -Passed (($dvdDrives | Where-Object { $_.Path -eq $IsoPath }).Count -gt 0) -Expected $IsoPath -Actual ($dvdDrives.Path -join '; ')

if ($targetVM.Generation -eq 2) {
    $sourceFirmware = Get-VMFirmware -VMName $SourceVMName
    $targetFirmware = Get-VMFirmware -VMName $VMName
    Add-EqualityCheck -Name 'Secure Boot state matches source VM' -Expected $sourceFirmware.SecureBoot.ToString() -Actual $targetFirmware.SecureBoot.ToString()
    Add-EqualityCheck -Name 'Secure Boot template matches source VM' -Expected $sourceFirmware.SecureBootTemplate -Actual $targetFirmware.SecureBootTemplate
    Add-Check -Name 'TPM is enabled for Windows 11' -Passed (Get-VMTPMState -Name $VMName) -Expected $true -Actual (Get-VMTPMState -Name $VMName)
}

$sourceAdapters = @(Get-VMNetworkAdapter -VMName $SourceVMName | Sort-Object Name)
$targetAdapters = @(Get-VMNetworkAdapter -VMName $VMName | Sort-Object Name)
Add-EqualityCheck -Name 'Network adapter count matches source VM' -Expected $sourceAdapters.Count -Actual $targetAdapters.Count

foreach ($sourceAdapter in $sourceAdapters) {
    $targetAdapter = $targetAdapters | Where-Object { $_.Name -eq $sourceAdapter.Name } | Select-Object -First 1
    Add-Check -Name "Network adapter '$($sourceAdapter.Name)' exists" -Passed ($null -ne $targetAdapter) -Expected $sourceAdapter.Name -Actual $(if ($targetAdapter) { $targetAdapter.Name } else { $null })
    if (-not $targetAdapter) {
        continue
    }

    Add-EqualityCheck -Name "Network adapter '$($sourceAdapter.Name)' switch matches source VM" -Expected $sourceAdapter.SwitchName -Actual $targetAdapter.SwitchName
    Add-Check -Name "Network adapter '$($sourceAdapter.Name)' uses a unique MAC address" -Passed ($targetAdapter.MacAddress -ne $sourceAdapter.MacAddress) -Expected "Not $($sourceAdapter.MacAddress)" -Actual $targetAdapter.MacAddress
    Add-Check -Name "Network adapter '$($sourceAdapter.Name)' MAC address spoofing is enabled" -Passed (Test-OnValue -Value $targetAdapter.MacAddressSpoofing) -Expected 'On' -Actual $targetAdapter.MacAddressSpoofing.ToString()

    $sourceVlan = Get-VMNetworkAdapterVlan -VMName $SourceVMName -VMNetworkAdapterName $sourceAdapter.Name
    $targetVlan = Get-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName $targetAdapter.Name
    Add-EqualityCheck -Name "Network adapter '$($sourceAdapter.Name)' VLAN mode matches source VM" -Expected $sourceVlan.OperationMode.ToString() -Actual $targetVlan.OperationMode.ToString()

    if ($sourceVlan.OperationMode.ToString() -eq 'Access') {
        Add-EqualityCheck -Name "Network adapter '$($sourceAdapter.Name)' access VLAN matches source VM" -Expected $sourceVlan.AccessVlanId -Actual $targetVlan.AccessVlanId
    }

    if ($sourceVlan.OperationMode.ToString() -eq 'Trunk') {
        Add-EqualityCheck -Name "Network adapter '$($sourceAdapter.Name)' native VLAN matches source VM" -Expected $sourceVlan.NativeVlanId -Actual $targetVlan.NativeVlanId
        Add-EqualityCheck -Name "Network adapter '$($sourceAdapter.Name)' allowed VLANs match source VM" -Expected $sourceVlan.AllowedVlanIdList.ToString() -Actual $targetVlan.AllowedVlanIdList.ToString()
    }
}

$sourceServices = @(Get-VMIntegrationService -VMName $SourceVMName | Sort-Object Name)
$targetServices = @(Get-VMIntegrationService -VMName $VMName | Sort-Object Name)
foreach ($sourceService in $sourceServices) {
    $targetService = $targetServices | Where-Object { $_.Name -eq $sourceService.Name } | Select-Object -First 1
    if ($targetService) {
        Add-EqualityCheck -Name "Integration service '$($sourceService.Name)' enabled state matches source VM" -Expected $sourceService.Enabled -Actual $targetService.Enabled
    }
}

$failedChecks = @($checks | Where-Object { -not $_.Passed })
$report = [pscustomobject][ordered]@{
    CapturedAt   = (Get-Date).ToString('o')
    VMName       = $VMName
    SourceVMName = $SourceVMName
    IsoPath      = $IsoPath
    Passed       = ($failedChecks.Count -eq 0)
    CheckCount   = $checks.Count
    FailedCount  = $failedChecks.Count
    ReportPath   = $ReportPath
    Checks       = @($checks)
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    Write-Warning "Provisioning validation failed with $($failedChecks.Count) failed check(s). Report: $ReportPath"
    throw "Provisioning validation failed for '$VMName'."
}

Write-Host "Provisioning validation passed for '$VMName'. Report: $ReportPath"