[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IsoPath = 'C:\Users\Lorenzo\Downloads\Windows isos\Windows 11 Enterprise\en-us_windows_11_business_editions_version_26h1_updated_march_2026_x64_dvd_f163b1c8.iso',

    [string]$SourceVMName = 'WIN11-WSL2',

    [string]$VMName = 'WIN11-INTUNE',

    [string]$TemplateVMName = 'WIN11-INTUNE-TEMPLATE',

    [string]$VMRoot = '',

    [string]$TemplateSpecPath = '',

    [switch]$CreateTemplateVM
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-ObjectPropertyValue {
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

function Add-ParameterIfPresent {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters,

        [Parameter(Mandatory)]
        [string]$Name,

        [object]$Value
    )

    if ($null -eq $Value) {
        return
    }

    if (($Value -is [string]) -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $Parameters[$Name] = $Value
}

function Copy-VMNetworkAdapterVlanConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$SourceVMName,

        [Parameter(Mandatory)]
        [string]$SourceAdapterName,

        [Parameter(Mandatory)]
        [string]$TargetVMName,

        [Parameter(Mandatory)]
        [string]$TargetAdapterName
    )

    $vlan = Get-VMNetworkAdapterVlan -VMName $SourceVMName -VMNetworkAdapterName $SourceAdapterName -ErrorAction SilentlyContinue
    if (-not $vlan) {
        return
    }

    switch ($vlan.OperationMode.ToString()) {
        'Untagged' {
            Set-VMNetworkAdapterVlan -VMName $TargetVMName -VMNetworkAdapterName $TargetAdapterName -Untagged
        }
        'Access' {
            Set-VMNetworkAdapterVlan -VMName $TargetVMName -VMNetworkAdapterName $TargetAdapterName -Access -VlanId $vlan.AccessVlanId
        }
        'Trunk' {
            Set-VMNetworkAdapterVlan -VMName $TargetVMName -VMNetworkAdapterName $TargetAdapterName -Trunk -NativeVlanId $vlan.NativeVlanId -AllowedVlanIdList $vlan.AllowedVlanIdList
        }
        'Isolated' {
            Set-VMNetworkAdapterVlan -VMName $TargetVMName -VMNetworkAdapterName $TargetAdapterName -Isolated -PrimaryVlanId $vlan.PrimaryVlanId -SecondaryVlanId $vlan.SecondaryVlanId
        }
        'Community' {
            Set-VMNetworkAdapterVlan -VMName $TargetVMName -VMNetworkAdapterName $TargetAdapterName -Community -PrimaryVlanId $vlan.PrimaryVlanId -SecondaryVlanId $vlan.SecondaryVlanId
        }
        'Promiscuous' {
            Set-VMNetworkAdapterVlan -VMName $TargetVMName -VMNetworkAdapterName $TargetAdapterName -Promiscuous -PrimaryVlanId $vlan.PrimaryVlanId -SecondaryVlanIdList $vlan.SecondaryVlanIdList
        }
        default {
            Write-Warning "VLAN mode '$($vlan.OperationMode)' on adapter '$SourceAdapterName' was not copied."
        }
    }
}

function Copy-VMIntegrationServices {
    param(
        [Parameter(Mandatory)]
        [string]$SourceVMName,

        [Parameter(Mandatory)]
        [string]$TargetVMName
    )

    foreach ($service in Get-VMIntegrationService -VMName $SourceVMName) {
        $targetService = Get-VMIntegrationService -VMName $TargetVMName -Name $service.Name -ErrorAction SilentlyContinue
        if (-not $targetService) {
            continue
        }

        if ($service.Enabled) {
            Enable-VMIntegrationService -VMName $TargetVMName -Name $service.Name
        }
        else {
            Disable-VMIntegrationService -VMName $TargetVMName -Name $service.Name
        }
    }
}

function Get-VMTPMState {
    param(
        [Parameter(Mandatory)]
        [string]$VMName
    )

    $getVmTpmCommand = Get-Command Get-VMTPM -ErrorAction SilentlyContinue
    if ($getVmTpmCommand) {
        return Get-VMTPM -VMName $VMName -ErrorAction SilentlyContinue
    }

    $getVmSecurityCommand = Get-Command Get-VMSecurity -ErrorAction SilentlyContinue
    if ($getVmSecurityCommand) {
        $security = Get-VMSecurity -VMName $VMName -ErrorAction SilentlyContinue
        if ($security) {
            foreach ($propertyName in @('TpmEnabled', 'TPMEnabled', 'TrustedPlatformModuleEnabled')) {
                $propertyValue = Get-ObjectPropertyValue -InputObject $security -Name $propertyName
                if ($null -ne $propertyValue) {
                    return [pscustomobject]@{
                        Enabled  = [bool]$propertyValue
                        Source   = 'Get-VMSecurity'
                        Property = $propertyName
                    }
                }
            }
        }
    }

    $getKeyProtectorCommand = Get-Command Get-VMKeyProtector -ErrorAction SilentlyContinue
    if ($getKeyProtectorCommand) {
        $keyProtector = Get-VMKeyProtector -VMName $VMName -ErrorAction SilentlyContinue
        if ($keyProtector) {
            return [pscustomobject]@{
                Enabled  = $true
                Source   = 'Get-VMKeyProtector'
                Property = 'KeyProtector'
            }
        }
    }

    Write-Warning "Could not determine TPM state for '$VMName' from this Hyper-V module. Enabling TPM for the new Windows 11 Generation 2 VM."
    return [pscustomobject]@{
        Enabled  = $true
        Source   = 'Default'
        Property = 'Windows11Generation2'
    }
}

function New-VHDLikeSourceDisk {
    param(
        [Parameter(Mandatory)]
        [object]$SourceDrive,

        [Parameter(Mandatory)]
        [string]$TargetVMName,

        [Parameter(Mandatory)]
        [string]$VhdDirectory,

        [Parameter(Mandatory)]
        [int]$DiskIndex,

        [Parameter(Mandatory)]
        [int]$DiskCount
    )

    if ([string]::IsNullOrWhiteSpace($SourceDrive.Path)) {
        throw "Source disk on controller $($SourceDrive.ControllerType) $($SourceDrive.ControllerNumber):$($SourceDrive.ControllerLocation) is not file-backed. Pass-through disks are not copied by this script."
    }

    $sourceVhd = Get-VHD -Path $SourceDrive.Path
    $extension = if ($sourceVhd.VhdFormat -eq 'VHD') { 'vhd' } else { 'vhdx' }
    $diskFileName = if ($DiskCount -eq 1) { "$TargetVMName.$extension" } else { "$TargetVMName-Disk$DiskIndex.$extension" }
    $targetVhdPath = Join-Path $VhdDirectory $diskFileName

    $newVhdParams = @{
        Path      = $targetVhdPath
        SizeBytes = [UInt64]$sourceVhd.Size
    }

    if ($sourceVhd.VhdType -eq 'Fixed') {
        $newVhdParams['Fixed'] = $true
    }
    else {
        $newVhdParams['Dynamic'] = $true
    }

    Add-ParameterIfPresent -Parameters $newVhdParams -Name 'BlockSizeBytes' -Value $sourceVhd.BlockSize
    Add-ParameterIfPresent -Parameters $newVhdParams -Name 'LogicalSectorSizeBytes' -Value $sourceVhd.LogicalSectorSize
    Add-ParameterIfPresent -Parameters $newVhdParams -Name 'PhysicalSectorSizeBytes' -Value $sourceVhd.PhysicalSectorSize

    New-VHD @newVhdParams | Out-Null

    $addDiskParams = @{
        VMName             = $TargetVMName
        ControllerType     = $SourceDrive.ControllerType
        ControllerNumber   = $SourceDrive.ControllerNumber
        ControllerLocation = $SourceDrive.ControllerLocation
        Path               = $targetVhdPath
    }

    Add-ParameterIfPresent -Parameters $addDiskParams -Name 'MinimumIOPS' -Value (Get-ObjectPropertyValue -InputObject $SourceDrive -Name 'MinimumIOPS')
    Add-ParameterIfPresent -Parameters $addDiskParams -Name 'MaximumIOPS' -Value (Get-ObjectPropertyValue -InputObject $SourceDrive -Name 'MaximumIOPS')
    Add-ParameterIfPresent -Parameters $addDiskParams -Name 'QoSPolicyID' -Value (Get-ObjectPropertyValue -InputObject $SourceDrive -Name 'QoSPolicyID')

    if (Get-ObjectPropertyValue -InputObject $SourceDrive -Name 'SupportPersistentReservations') {
        $addDiskParams['SupportPersistentReservations'] = $true
    }

    Add-VMHardDiskDrive @addDiskParams

    return [ordered]@{
        Path               = $targetVhdPath
        SizeBytes          = [UInt64]$sourceVhd.Size
        VhdType            = $sourceVhd.VhdType.ToString()
        VhdFormat          = $sourceVhd.VhdFormat.ToString()
        ControllerType     = $SourceDrive.ControllerType.ToString()
        ControllerNumber   = $SourceDrive.ControllerNumber
        ControllerLocation = $SourceDrive.ControllerLocation
    }
}

function New-SpecMatchedVM {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$SourceVM,

        [Parameter(Mandatory)]
        [object]$SourceMemory,

        [Parameter(Mandatory)]
        [object]$SourceProcessor,

        [Parameter(Mandatory)]
        [object[]]$SourceHardDisks,

        [Parameter(Mandatory)]
        [object[]]$SourceNetworkAdapters,

        [object]$SourceFirmware,

        [object]$SourceTpm,

        [Parameter(Mandatory)]
        [string]$SourceVMName,

        [Parameter(Mandatory)]
        [string]$VMRoot,

        [Parameter(Mandatory)]
        [string]$IsoPath
    )

    $vmPath = Join-Path $VMRoot $Name
    $vhdDirectory = Join-Path $vmPath 'Virtual Hard Disks'
    $snapshotDirectory = Join-Path $vmPath 'Snapshots'
    $smartPagingDirectory = Join-Path $vmPath 'Smart Paging'
    New-Item -ItemType Directory -Path $vhdDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $smartPagingDirectory -Force | Out-Null

    $newVMParams = @{
        Name               = $Name
        Generation         = [int16]$SourceVM.Generation
        MemoryStartupBytes = [Int64]$SourceMemory.Startup
        NoVHD              = $true
        Path               = $vmPath
    }
    Add-ParameterIfPresent -Parameters $newVMParams -Name 'Version' -Value $SourceVM.Version

    New-VM @newVMParams | Out-Null

    foreach ($defaultAdapter in Get-VMNetworkAdapter -VMName $Name) {
        Remove-VMNetworkAdapter -VMNetworkAdapter $defaultAdapter
    }

    $setVMParams = @{
        Name                        = $Name
        AutomaticCheckpointsEnabled = $SourceVM.AutomaticCheckpointsEnabled
        AutomaticStartAction        = $SourceVM.AutomaticStartAction
        AutomaticStopAction         = $SourceVM.AutomaticStopAction
        AutomaticStartDelay         = $SourceVM.AutomaticStartDelay
        CheckpointType              = $SourceVM.CheckpointType
    }
    Add-ParameterIfPresent -Parameters $setVMParams -Name 'AutomaticCriticalErrorAction' -Value (Get-ObjectPropertyValue -InputObject $SourceVM -Name 'AutomaticCriticalErrorAction')
    Add-ParameterIfPresent -Parameters $setVMParams -Name 'AutomaticCriticalErrorActionTimeout' -Value (Get-ObjectPropertyValue -InputObject $SourceVM -Name 'AutomaticCriticalErrorActionTimeout')
    Add-ParameterIfPresent -Parameters $setVMParams -Name 'EnhancedSessionTransportType' -Value (Get-ObjectPropertyValue -InputObject $SourceVM -Name 'EnhancedSessionTransportType')
    Add-ParameterIfPresent -Parameters $setVMParams -Name 'SmartPagingFilePath' -Value $smartPagingDirectory
    Add-ParameterIfPresent -Parameters $setVMParams -Name 'SnapshotFileLocation' -Value $snapshotDirectory
    Set-VM @setVMParams

    $memoryParams = @{
        VMName                = $Name
        DynamicMemoryEnabled  = [bool]$SourceMemory.DynamicMemoryEnabled
        StartupBytes          = [Int64]$SourceMemory.Startup
    }
    Add-ParameterIfPresent -Parameters $memoryParams -Name 'Buffer' -Value (Get-ObjectPropertyValue -InputObject $SourceMemory -Name 'Buffer')
    Add-ParameterIfPresent -Parameters $memoryParams -Name 'Priority' -Value (Get-ObjectPropertyValue -InputObject $SourceMemory -Name 'Priority')

    if ($SourceMemory.DynamicMemoryEnabled) {
        Add-ParameterIfPresent -Parameters $memoryParams -Name 'MinimumBytes' -Value ([Int64]$SourceMemory.Minimum)
        Add-ParameterIfPresent -Parameters $memoryParams -Name 'MaximumBytes' -Value ([Int64]$SourceMemory.Maximum)
    }
    Set-VMMemory @memoryParams

    $processorParams = @{
        VMName = $Name
        Count  = [long]$SourceProcessor.Count
    }
    foreach ($propertyName in @(
        'CompatibilityForMigrationEnabled',
        'CompatibilityForOlderOperatingSystemsEnabled',
        'HwThreadCountPerCore',
        'Maximum',
        'Reserve',
        'RelativeWeight',
        'ExposeVirtualizationExtensions'
    )) {
        Add-ParameterIfPresent -Parameters $processorParams -Name $propertyName -Value (Get-ObjectPropertyValue -InputObject $SourceProcessor -Name $propertyName)
    }
    Set-VMProcessor @processorParams
    Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true

    $createdDisks = @()
    for ($index = 0; $index -lt $SourceHardDisks.Count; $index++) {
        $createdDisks += New-VHDLikeSourceDisk -SourceDrive $SourceHardDisks[$index] -TargetVMName $Name -VhdDirectory $vhdDirectory -DiskIndex $index -DiskCount $SourceHardDisks.Count
    }

    foreach ($adapter in $SourceNetworkAdapters) {
        $adapterParams = @{
            VMName            = $Name
            Name              = $adapter.Name
            DynamicMacAddress = $true
        }

        Add-ParameterIfPresent -Parameters $adapterParams -Name 'SwitchName' -Value $adapter.SwitchName
        Add-ParameterIfPresent -Parameters $adapterParams -Name 'IsLegacy' -Value (Get-ObjectPropertyValue -InputObject $adapter -Name 'IsLegacy')
        Add-ParameterIfPresent -Parameters $adapterParams -Name 'DeviceNaming' -Value (Get-ObjectPropertyValue -InputObject $adapter -Name 'DeviceNaming')

        Add-VMNetworkAdapter @adapterParams

        $networkParams = @{
            VMName            = $Name
            Name              = $adapter.Name
            DynamicMacAddress = $true
        }
        foreach ($propertyName in @(
            'MacAddressSpoofing',
            'DhcpGuard',
            'RouterGuard',
            'PortMirroring',
            'IeeePriorityTag',
            'NumaAwarePlacement',
            'VmqWeight',
            'IovQueuePairsRequested',
            'IovInterruptModeration',
            'IovWeight',
            'IPsecOffloadMaximumSecurityAssociation',
            'MaximumBandwidth',
            'MinimumBandwidthAbsolute',
            'MinimumBandwidthWeight',
            'VirtualSubnetId',
            'AllowTeaming',
            'NotMonitoredInCluster',
            'StormLimit',
            'DynamicIPAddressLimit',
            'DeviceNaming',
            'FixSpeed10G',
            'VrssEnabled',
            'VmmqEnabled',
            'RscEnabled'
        )) {
            Add-ParameterIfPresent -Parameters $networkParams -Name $propertyName -Value (Get-ObjectPropertyValue -InputObject $adapter -Name $propertyName)
        }
        Set-VMNetworkAdapter @networkParams
        Set-VMNetworkAdapter -VMName $Name -Name $adapter.Name -MacAddressSpoofing On
        Copy-VMNetworkAdapterVlanConfiguration -SourceVMName $SourceVMName -SourceAdapterName $adapter.Name -TargetVMName $Name -TargetAdapterName $adapter.Name
    }

    if ($SourceFirmware) {
        $firmwareParams = @{
            VMName           = $Name
            EnableSecureBoot = $SourceFirmware.SecureBoot
        }
        Add-ParameterIfPresent -Parameters $firmwareParams -Name 'SecureBootTemplate' -Value $SourceFirmware.SecureBootTemplate
        Add-ParameterIfPresent -Parameters $firmwareParams -Name 'PreferredNetworkBootProtocol' -Value $SourceFirmware.PreferredNetworkBootProtocol
        Add-ParameterIfPresent -Parameters $firmwareParams -Name 'ConsoleMode' -Value $SourceFirmware.ConsoleMode
        Add-ParameterIfPresent -Parameters $firmwareParams -Name 'PauseAfterBootFailure' -Value $SourceFirmware.PauseAfterBootFailure
        Set-VMFirmware @firmwareParams
    }

    if ($SourceTpm -and (Get-ObjectPropertyValue -InputObject $SourceTpm -Name 'Enabled')) {
        Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
        Enable-VMTPM -VMName $Name
    }

    Copy-VMIntegrationServices -SourceVMName $SourceVMName -TargetVMName $Name

    $dvd = Add-VMDvdDrive -VMName $Name -Path $IsoPath -Passthru
    if ($SourceVM.Generation -eq 2) {
        Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
    }

    return [ordered]@{
        Name       = $Name
        Path       = $vmPath
        VhdPath    = $vhdDirectory
        HardDisks  = $createdDisks
        IsoPath    = $IsoPath
        MacAddress = 'Dynamic per VM for uniqueness'
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session on the Hyper-V host.'
}

Import-Module Hyper-V -ErrorAction Stop

try {
    $sourceVM = Get-VM -Name $SourceVMName -ErrorAction Stop
}
catch {
    if ($SourceVMName -eq 'WIN11-WSL2') {
        $fallbackSourceVM = Get-VM -Name 'WIN11-WLS2' -ErrorAction SilentlyContinue
        if ($fallbackSourceVM) {
            Write-Warning "Source VM 'WIN11-WSL2' was not found. Using fallback source VM 'WIN11-WLS2'."
            $SourceVMName = 'WIN11-WLS2'
            $sourceVM = $fallbackSourceVM
        }
        else {
            throw
        }
    }
    else {
        throw
    }
}

if ($sourceVM.State -ne 'Off') {
    Write-Warning "Source VM '$SourceVMName' is $($sourceVM.State). Specs can be read while it is running, but shut it down first if you want a quieter capture."
}

$targetVMNames = @()
if ($CreateTemplateVM) {
    $targetVMNames += $TemplateVMName
}
$targetVMNames += $VMName
$targetVMNames = $targetVMNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

foreach ($targetVMName in $targetVMNames) {
    if ($targetVMName -eq $SourceVMName) {
        throw "Target VM name '$targetVMName' cannot match the source VM name."
    }

    if (Get-VM -Name $targetVMName -ErrorAction SilentlyContinue) {
        throw "A Hyper-V VM named '$targetVMName' already exists. Choose another name or remove the existing VM intentionally."
    }
}

if ([string]::IsNullOrWhiteSpace($VMRoot)) {
    $sourcePathLeaf = Split-Path -Path $sourceVM.Path -Leaf
    if ($sourcePathLeaf -ieq $SourceVMName) {
        $VMRoot = Split-Path -Path $sourceVM.Path -Parent
    }
    else {
        $VMRoot = $sourceVM.Path
    }
}

if ([string]::IsNullOrWhiteSpace($TemplateSpecPath)) {
    $templateDirectory = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'templates'
    $TemplateSpecPath = Join-Path $templateDirectory "$VMName.hyperv-template.json"
}

$sourceMemory = Get-VMMemory -VMName $SourceVMName
$sourceProcessor = Get-VMProcessor -VMName $SourceVMName
$sourceHardDisks = @(Get-VMHardDiskDrive -VMName $SourceVMName | Sort-Object ControllerType, ControllerNumber, ControllerLocation)
$sourceNetworkAdapters = @(Get-VMNetworkAdapter -VMName $SourceVMName | Sort-Object Name)
$sourceFirmware = if ($sourceVM.Generation -eq 2) { Get-VMFirmware -VMName $SourceVMName } else { $null }
$sourceTpm = if ($sourceVM.Generation -eq 2) { Get-VMTPMState -VMName $SourceVMName } else { $null }

if ($sourceHardDisks.Count -eq 0) {
    throw "Source VM '$SourceVMName' has no virtual hard disks to size the new VM disks from."
}

$sourceDiskSpecs = foreach ($sourceDrive in $sourceHardDisks) {
    $sourceVhd = Get-VHD -Path $sourceDrive.Path
    [ordered]@{
        SourcePath         = $sourceDrive.Path
        SizeBytes          = [UInt64]$sourceVhd.Size
        VhdType            = $sourceVhd.VhdType.ToString()
        VhdFormat          = $sourceVhd.VhdFormat.ToString()
        ControllerType     = $sourceDrive.ControllerType.ToString()
        ControllerNumber   = $sourceDrive.ControllerNumber
        ControllerLocation = $sourceDrive.ControllerLocation
    }
}

$sourceNetworkSpecs = foreach ($adapter in $sourceNetworkAdapters) {
    $vlan = Get-VMNetworkAdapterVlan -VMName $SourceVMName -VMNetworkAdapterName $adapter.Name -ErrorAction SilentlyContinue
    [ordered]@{
        Name                         = $adapter.Name
        SwitchName                   = $adapter.SwitchName
        MacAddressMode               = 'Dynamic on new VMs for uniqueness'
        SourceMacAddress             = $adapter.MacAddress
        VlanOperationMode            = if ($vlan) { $vlan.OperationMode.ToString() } else { $null }
        VlanAccessId                 = if ($vlan) { Get-ObjectPropertyValue -InputObject $vlan -Name 'AccessVlanId' } else { $null }
        VlanNativeId                 = if ($vlan) { Get-ObjectPropertyValue -InputObject $vlan -Name 'NativeVlanId' } else { $null }
        VlanAllowedList              = if ($vlan) { Get-ObjectPropertyValue -InputObject $vlan -Name 'AllowedVlanIdList' } else { $null }
        MacAddressSpoofing           = Get-ObjectPropertyValue -InputObject $adapter -Name 'MacAddressSpoofing'
        TargetMacAddressSpoofing     = 'On'
        DhcpGuard                    = Get-ObjectPropertyValue -InputObject $adapter -Name 'DhcpGuard'
        RouterGuard                  = Get-ObjectPropertyValue -InputObject $adapter -Name 'RouterGuard'
        PortMirroring                = Get-ObjectPropertyValue -InputObject $adapter -Name 'PortMirroring'
        IeeePriorityTag              = Get-ObjectPropertyValue -InputObject $adapter -Name 'IeeePriorityTag'
    }
}

$firmwareSpec = $null
if ($sourceFirmware) {
    $firmwareSpec = [ordered]@{
        SecureBoot                   = $sourceFirmware.SecureBoot.ToString()
        SecureBootTemplate           = $sourceFirmware.SecureBootTemplate
        PreferredNetworkBootProtocol = $sourceFirmware.PreferredNetworkBootProtocol.ToString()
        ConsoleMode                  = $sourceFirmware.ConsoleMode.ToString()
        PauseAfterBootFailure        = $sourceFirmware.PauseAfterBootFailure.ToString()
    }
}

$tpmEnabled = $false
if ($sourceTpm) {
    $tpmEnabled = [bool](Get-ObjectPropertyValue -InputObject $sourceTpm -Name 'Enabled')
}

$templateSpec = [ordered]@{
    CapturedAt       = (Get-Date).ToString('o')
    SourceVMName     = $SourceVMName
    TargetVMNames    = $targetVMNames
    IsoPath          = $IsoPath
    VMRoot           = $VMRoot
    Generation       = $sourceVM.Generation
    Version          = $sourceVM.Version.ToString()
    CheckpointType   = $sourceVM.CheckpointType.ToString()
    AutomaticActions = [ordered]@{
        StartAction                 = $sourceVM.AutomaticStartAction.ToString()
        StopAction                  = $sourceVM.AutomaticStopAction.ToString()
        StartDelaySeconds           = $sourceVM.AutomaticStartDelay
        AutomaticCheckpointsEnabled = $sourceVM.AutomaticCheckpointsEnabled
    }
    Memory           = [ordered]@{
        DynamicMemoryEnabled = [bool]$sourceMemory.DynamicMemoryEnabled
        StartupBytes         = [Int64]$sourceMemory.Startup
        MinimumBytes         = [Int64]$sourceMemory.Minimum
        MaximumBytes         = [Int64]$sourceMemory.Maximum
        Buffer               = Get-ObjectPropertyValue -InputObject $sourceMemory -Name 'Buffer'
        Priority             = Get-ObjectPropertyValue -InputObject $sourceMemory -Name 'Priority'
    }
    Processor        = [ordered]@{
        Count                             = [long]$sourceProcessor.Count
        CompatibilityForMigrationEnabled = Get-ObjectPropertyValue -InputObject $sourceProcessor -Name 'CompatibilityForMigrationEnabled'
        SourceExposeVirtualizationExtensions = Get-ObjectPropertyValue -InputObject $sourceProcessor -Name 'ExposeVirtualizationExtensions'
        TargetExposeVirtualizationExtensions = $true
        HwThreadCountPerCore              = Get-ObjectPropertyValue -InputObject $sourceProcessor -Name 'HwThreadCountPerCore'
        Maximum                           = Get-ObjectPropertyValue -InputObject $sourceProcessor -Name 'Maximum'
        Reserve                           = Get-ObjectPropertyValue -InputObject $sourceProcessor -Name 'Reserve'
        RelativeWeight                    = Get-ObjectPropertyValue -InputObject $sourceProcessor -Name 'RelativeWeight'
    }
    Firmware         = $firmwareSpec
    TpmEnabled       = $tpmEnabled
    HardDisks        = @($sourceDiskSpecs)
    NetworkAdapters  = @($sourceNetworkSpecs)
    Uniqueness       = [ordered]@{
        HyperVVMId      = 'Generated new by Hyper-V'
        WindowsSid      = 'Generated by fresh Windows install from ISO'
        MacAddresses    = 'Generated new by Hyper-V'
        MdeDeviceId     = 'Generated after MDE onboarding, not cloned'
        EntraIntuneId   = 'Generated after Entra join and Intune enrollment'
    }
}

$templateDirectoryPath = Split-Path -Path $TemplateSpecPath -Parent
New-Item -ItemType Directory -Path $templateDirectoryPath -Force | Out-Null
$templateSpec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $TemplateSpecPath -Encoding UTF8
Write-Host "Saved Hyper-V spec template to: $TemplateSpecPath"

$createdVMs = @()
foreach ($targetVMName in $targetVMNames) {
    if ($PSCmdlet.ShouldProcess($targetVMName, "Create Hyper-V VM from '$SourceVMName' specs")) {
        $createdVMs += New-SpecMatchedVM -Name $targetVMName -SourceVM $sourceVM -SourceMemory $sourceMemory -SourceProcessor $sourceProcessor -SourceHardDisks $sourceHardDisks -SourceNetworkAdapters $sourceNetworkAdapters -SourceFirmware $sourceFirmware -SourceTpm $sourceTpm -SourceVMName $SourceVMName -VMRoot $VMRoot -IsoPath $IsoPath
    }
}

if ($createdVMs.Count -gt 0) {
    Write-Host 'Created VM hardware:'
    Get-VM -Name $targetVMNames | Select-Object Name,Id,State,Generation,Version,ProcessorCount,MemoryStartup,Path | Format-Table -AutoSize
    Write-Host "Attached install ISO: $IsoPath"
    Write-Host "Start '$VMName' and install Windows 11 Enterprise from the ISO."
    if ($CreateTemplateVM) {
        Write-Host "Template VM '$TemplateVMName' was also created because -CreateTemplateVM was specified."
    }
}