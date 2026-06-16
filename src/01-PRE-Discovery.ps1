<#
.SYNOPSIS
Discovers VMware VM metadata and produces a migration manifest for Hyper-V execution.

.DESCRIPTION
This script is the PRE phase of a VMware to Hyper-V migration pipeline.
It discovers compute, storage, network, guest networking, and snapshots from a source VM,
runs mandatory and advisory checks, and generates manifest-<VMName>.json.

.PARAMETER VMName
Source VMware VM name.

.PARAMETER vCenterServer
vCenter hostname or FQDN. Defaults to VCENTER_HOST environment variable.

.PARAMETER vCenterUser
vCenter user. Defaults to VCENTER_USER environment variable.

.PARAMETER vCenterPass
Secure password for vCenter. If not provided, credential prompt can be used.

.PARAMETER OutputDir
Directory where manifest JSON is written.

.PARAMETER Force
Overwrite existing manifest without confirmation.

.EXAMPLE
.\01-PRE-Discovery.ps1 -VMName "SRVWEB01" -OutputDir "C:\Migration\Manifests"

.EXAMPLE
.\01-PRE-Discovery.ps1 -VMName "SRVWEB01" -WhatIf

.NOTES
Version: 1.0.0
Author: GitHub Copilot
Changelog:
- 1.0.0 Initial version with checks CHECK_01..CHECK_07
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [string]$vCenterServer = $env:VCENTER_HOST,
    [string]$vCenterUser = $env:VCENTER_USER,
    [SecureString]$vCenterPass,
    [string]$OutputDir = "C:\Migration\Manifests",
    [switch]$Force,

    # Opt-in: consolidate/remove existing snapshots before discovery (destructive on source).
    [switch]$RemoveSnapshots,

    # Opt-in: explicitly approve migration of a legacy guest OS (2000/2003/2008/2008 R2/NT).
    [switch]$ApproveLegacyOS
)

Set-StrictMode -Version 2.0

$script:PhaseName = 'PHASE-PRE'
$script:sessionCreatedHere = $false
$script:checks = New-Object System.Collections.Generic.List[object]
$script:overallExitCode = 0

function Write-MigLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    Write-Output "[$ts][$Level][$script:PhaseName] $Message"
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )

    $script:checks.Add([pscustomobject]@{
        check_id = $Id
        status = $Status
        detail = $Detail
    }) | Out-Null
}

function Convert-HardwareVersionToInt {
    param([string]$HardwareVersion)
    if ([string]::IsNullOrWhiteSpace($HardwareVersion)) {
        return 0
    }
    if ($HardwareVersion -match 'vmx-(\d+)') {
        return [int]$Matches[1]
    }
    return 0
}

function Get-ProvisioningType {
    param($HardDisk)
    try {
        $typeName = $HardDisk.ExtensionData.Backing.GetType().Name
        if ($typeName -match 'FlatVer2BackingInfo') {
            if ($HardDisk.ExtensionData.Backing.EagerlyScrub -eq $true) {
                return 'Thick Eager'
            }
            if ($HardDisk.ExtensionData.Backing.ThinProvisioned -eq $true) {
                return 'Thin'
            }
            return 'Thick Lazy'
        }
        return 'Unknown'
    }
    catch {
        return 'Unknown'
    }
}

function Get-BusType {
    param($HardDisk)
    try {
        $ctrlKey = $HardDisk.ExtensionData.ControllerKey
        $controllers = $HardDisk.Parent.ExtensionData.Config.Hardware.Device | Where-Object { $_.Key -eq $ctrlKey }
        if (-not $controllers) { return 'Unknown' }
        $ctrlType = $controllers[0].GetType().Name
        if ($ctrlType -match 'ParaVirtualSCSI|VirtualLsiLogicSAS|VirtualLsiLogicController|VirtualBusLogicController') { return 'SCSI' }
        if ($ctrlType -match 'VirtualSATAController') { return 'SATA' }
        if ($ctrlType -match 'VirtualIDEController') { return 'IDE' }
        return $ctrlType
    }
    catch {
        return 'Unknown'
    }
}

function Parse-WindowsGuestNetwork {
    param([string]$Raw)

    $result = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $result
    }

    foreach ($line in ($Raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Count -lt 5) { continue }

        $iface = $parts[0]
        $ip = $parts[1]
        $prefix = 0
        [void][int]::TryParse($parts[2], [ref]$prefix)
        $gw = $parts[3]
        $dns = @()
        if (-not [string]::IsNullOrWhiteSpace($parts[4])) {
            $dns = @($parts[4] -split ',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }

        $result.Add([pscustomobject]@{
            interface = $iface
            ip = $ip
            prefix = $prefix
            gateway = $gw
            dns = $dns
            source = 'invoke-vmscript'
        }) | Out-Null
    }

    return $result
}

function Parse-LinuxGuestNetwork {
    param([string]$Raw)

    $result = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $result
    }

    $currentIf = $null
    $gateway = $null
    $dnsList = @()

    foreach ($line in ($Raw -split "`r?`n")) {
        if ($line -match '^default\s+via\s+([^\s]+)') {
            $gateway = $Matches[1]
        }
        elseif ($line -match '^\s*nameserver\s+([^\s]+)') {
            $dnsList += $Matches[1]
        }
        elseif ($line -match '^\d+:\s+([^:]+):') {
            $currentIf = $Matches[1]
        }
        elseif ($line -match '^\s+inet\s+([0-9\.]+)/(\d+)') {
            $ip = $Matches[1]
            $prefix = [int]$Matches[2]
            $result.Add([pscustomobject]@{
                interface = $currentIf
                ip = $ip
                prefix = $prefix
                gateway = $gateway
                dns = @($dnsList)
                source = 'invoke-vmscript'
            }) | Out-Null
        }
    }

    return $result
}

function Test-ValidIPv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -eq '127.0.0.1') { return $false }
    if ($Ip -eq '0.0.0.0') { return $false }

    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr)) {
        return $false
    }

    return $addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-LegacyOS {
    param([string]$OsName)
    if ([string]::IsNullOrWhiteSpace($OsName)) { return $false }
    # Match legacy Windows guest OS families that frequently break first-run migrations.
    $patterns = @(
        'Windows\s*2000',
        'Windows\s*Server\s*2003',
        'Windows\s*XP',
        'Windows\s*Server\s*2008(?!\s*R2)',
        'Windows\s*Server\s*2008\s*R2',
        'Windows\s*NT'
    )
    foreach ($p in $patterns) {
        if ($OsName -match $p) { return $true }
    }
    return $false
}

try {
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -Path $OutputDir -PathType Container)) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
        Write-MigLog -Level INFO -Message "Output directory created: $OutputDir"
    }

    $manifestPath = Join-Path -Path $OutputDir -ChildPath ("manifest-{0}.json" -f $VMName)
    if ((Test-Path -Path $manifestPath) -and (-not $Force)) {
        if (-not $PSCmdlet.ShouldProcess($manifestPath, 'Overwrite existing manifest')) {
            Write-MigLog -Level WARN -Message "Existing manifest not overwritten by user choice: $manifestPath"
            exit 0
        }
    }

    $viServer = $null

    try {
        $existingSessions = @(Get-VIServer -ErrorAction SilentlyContinue)
        if ($existingSessions.Count -gt 0) {
            if ($vCenterServer) {
                $viServer = $existingSessions | Where-Object { $_.Name -eq $vCenterServer } | Select-Object -First 1
            }
            if (-not $viServer) {
                $viServer = $existingSessions | Select-Object -First 1
            }
            Write-MigLog -Level INFO -Message "Reusing existing PowerCLI session: $($viServer.Name)"
        }
        else {
            if (-not $vCenterServer) {
                $vCenterServer = $env:VCENTER_HOST
            }
            if (-not $vCenterUser) {
                $vCenterUser = $env:VCENTER_USER
            }

            $credential = $null
            if ($vCenterUser -and $vCenterPass) {
                $credential = New-Object System.Management.Automation.PSCredential($vCenterUser, $vCenterPass)
            }
            elseif ($vCenterUser -and $env:VCENTER_PASS) {
                $secure = ConvertTo-SecureString -String $env:VCENTER_PASS -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($vCenterUser, $secure)
            }
            elseif ($vCenterUser) {
                $credential = Get-Credential -UserName $vCenterUser -Message 'Provide vCenter credentials'
            }
            else {
                $credential = Get-Credential -Message 'Provide vCenter credentials'
                $vCenterUser = $credential.UserName
            }

            if (-not $vCenterServer) {
                throw 'VCENTER_HOST is not defined and no server parameter was provided.'
            }

            $viServer = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop
            $script:sessionCreatedHere = $true
            Write-MigLog -Level INFO -Message "Connected to vCenter: $($viServer.Name)"
        }
    }
    catch {
        Write-MigLog -Level ERROR -Message "$($_.Exception.Message)"
        Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
        Write-Error "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][ERROR][PHASE-PRE] vCenter connection failed."
        exit 3
    }

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    Write-MigLog -Level INFO -Message "Discovered source VM: $VMName"

    $disks = @()
    $nics = @()
    $guestNetwork = @()
    $snapshots = @()

    #region BLOC A — Specs de base
    try {
        $cpu = [int]$vm.NumCpu
        $ramMB = [int]$vm.MemoryMB
        $firmware = [string]$vm.ExtensionData.Config.Firmware
        if ([string]::IsNullOrWhiteSpace($firmware)) { $firmware = 'bios' }

        $secureBoot = $false
        if ($firmware -eq 'efi') {
            $secureBoot = [bool]$vm.ExtensionData.Config.BootOptions.EfiSecureBootEnabled
        }

        $toolsVersion = $vm.Guest.ToolsVersion
        $guestFullName = $vm.Guest.GuestFullName
        $powerState = [string]$vm.PowerState
        $hardwareVersion = [string]$vm.HardwareVersion

        Write-MigLog -Level INFO -Message "Collected block A specs."
    }
    catch {
        Write-MigLog -Level ERROR -Message "Block A failed: $($_.Exception.Message)"
        Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
        throw
    }
    #endregion

    #region BLOC B — Stockage
    try {
        $hardDisks = @(Get-HardDisk -VM $vm -ErrorAction Stop)
        foreach ($hd in $hardDisks) {
            $isRdm = $false
            $backingType = $hd.ExtensionData.Backing.GetType().Name
            if ($backingType -match 'RawVirtualDisk|RawPhysicalDisk') {
                $isRdm = $true
            }

            $sharingMode = $hd.ExtensionData.Backing.Sharing
            $isShared = $false
            if ($sharingMode -and ($sharingMode -ne 'sharingNone')) {
                $isShared = $true
            }

            $disks += [pscustomobject]@{
                label = $hd.Name
                size_gb = [Math]::Round([double]$hd.CapacityGB, 2)
                provisioning = Get-ProvisioningType -HardDisk $hd
                vmdk_path = $hd.Filename
                bus_type = Get-BusType -HardDisk $hd
                is_rdm = $isRdm
                is_shared = $isShared
            }
        }
        Write-MigLog -Level INFO -Message "Collected block B storage details: $($disks.Count) disks."
    }
    catch {
        Write-MigLog -Level ERROR -Message "Block B failed: $($_.Exception.Message)"
        Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
        throw
    }
    #endregion

    #region BLOC C — Réseau
    try {
        $netAdapters = @(Get-NetworkAdapter -VM $vm -ErrorAction Stop)
        foreach ($nic in $netAdapters) {
            $type = $nic.Type
            if ([string]::IsNullOrWhiteSpace($type)) {
                $type = $nic.ExtensionData.GetType().Name
            }

            $nics += [pscustomobject]@{
                name = $nic.Name
                portgroup = $nic.NetworkName
                mac = $nic.MacAddress
                type = $type
                connect_at_power_on = [bool]$nic.ConnectionState.StartConnected
            }
        }
        Write-MigLog -Level INFO -Message "Collected block C network adapters: $($nics.Count) NICs."
    }
    catch {
        Write-MigLog -Level ERROR -Message "Block C failed: $($_.Exception.Message)"
        Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
        throw
    }
    #endregion

    #region BLOC D — Configuration IP In-Guest
    try {
        $guest = Get-VMGuest -VM $vm -ErrorAction Stop
        $isWindowsGuest = $false
        if ($guestFullName -match 'Windows') { $isWindowsGuest = $true }

        if ($isWindowsGuest) {
            $scriptText = @'
Get-NetIPConfiguration | ForEach-Object {
    $ifName = $_.InterfaceAlias
    $ip = $_.IPv4Address.IPAddress
    $prefix = $_.IPv4Address.PrefixLength
    $gw = $_.IPv4DefaultGateway.NextHop
    $dns = ($_.DNSServer.ServerAddresses -join ',')
    "{0}|{1}|{2}|{3}|{4}" -f $ifName,$ip,$prefix,$gw,$dns
}
'@
            $vmScriptResult = Invoke-VMScript -VM $vm -ScriptType Powershell -ScriptText $scriptText -ErrorAction Stop
            $guestNetwork = @(Parse-WindowsGuestNetwork -Raw $vmScriptResult.ScriptOutput)
        }
        else {
            $linuxScript = @'
ip addr show
ip route show
cat /etc/resolv.conf
'@
            $vmScriptResult = Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $linuxScript -ErrorAction Stop
            $guestNetwork = @(Parse-LinuxGuestNetwork -Raw $vmScriptResult.ScriptOutput)
        }

        Write-MigLog -Level INFO -Message "Collected block D guest IP details using Invoke-VMScript."
    }
    catch {
        Write-MigLog -Level WARN -Message "Invoke-VMScript failed, switching to VMware Tools fallback: $($_.Exception.Message)"
        try {
            $guest = Get-VMGuest -VM $vm -ErrorAction Stop
            $fallbackIps = @($guest.IPAddress) | Where-Object { Test-ValidIPv4 -Ip $_ }
            $guestNetwork = @()
            foreach ($ip in $fallbackIps) {
                $guestNetwork += [pscustomobject]@{
                    interface = 'unknown'
                    ip = $ip
                    prefix = 0
                    gateway = ''
                    dns = @()
                    source = 'vmware-tools-fallback'
                }
            }
        }
        catch {
            Write-MigLog -Level WARN -Message "Fallback Get-VMGuest failed: $($_.Exception.Message)"
            $guestNetwork = @()
        }
    }
    #endregion

    #region BLOC E — Snapshots
    try {
        $snapshots = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue)
        Write-MigLog -Level INFO -Message "Collected block E snapshots: $($snapshots.Count)."

        if ($snapshots.Count -ge 1 -and $RemoveSnapshots) {
            $snapNamesToRemove = ($snapshots | Select-Object -ExpandProperty Name) -join ', '
            if ($PSCmdlet.ShouldProcess($VMName, "Remove $($snapshots.Count) snapshot(s): $snapNamesToRemove")) {
                Write-MigLog -Level WARN -Message "RemoveSnapshots requested. Consolidating snapshots: $snapNamesToRemove"
                foreach ($snap in $snapshots) {
                    try {
                        Remove-Snapshot -Snapshot $snap -RemoveChildren -Confirm:$false -ErrorAction Stop
                        Write-MigLog -Level INFO -Message "Snapshot removed: $($snap.Name)"
                    }
                    catch {
                        Write-MigLog -Level ERROR -Message "Failed to remove snapshot '$($snap.Name)': $($_.Exception.Message)"
                    }
                }
                # Re-query after consolidation to reflect the new state.
                $snapshots = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue)
                Write-MigLog -Level INFO -Message "Post-consolidation snapshot count: $($snapshots.Count)."
            }
            else {
                Write-MigLog -Level WARN -Message 'Snapshot consolidation skipped (ShouldProcess declined).'
            }
        }
    }
    catch {
        Write-MigLog -Level ERROR -Message "Block E failed: $($_.Exception.Message)"
        Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
        throw
    }
    #endregion

    #region Checks
    $blockingFailure = $false

    # CHECK_01
    if ($snapshots.Count -ge 1) {
        $snapshotNames = ($snapshots | Select-Object -ExpandProperty Name) -join ', '
        Add-Check -Id 'CHECK_01' -Status 'FAIL' -Detail "Snapshots detected: $snapshotNames"
        Write-Error "[FATAL][CHECK_01] Snapshots detectes : $snapshotNames. Migration interdite."
        $blockingFailure = $true
    }
    else {
        Add-Check -Id 'CHECK_01' -Status 'PASS' -Detail 'No active snapshots detected.'
    }

    # CHECK_02
    $rdmOrShared = $disks | Where-Object { $_.is_rdm -or $_.is_shared }
    if ($rdmOrShared) {
        $labels = ($rdmOrShared | Select-Object -ExpandProperty label) -join ', '
        Add-Check -Id 'CHECK_02' -Status 'FAIL' -Detail "RDM/shared disk detected: $labels"
        Write-Error "[FATAL][CHECK_02] Disque RDM ou partage : $labels. Migration interdite."
        $blockingFailure = $true
    }
    else {
        Add-Check -Id 'CHECK_02' -Status 'PASS' -Detail 'No RDM/shared disks detected.'
    }

    # CHECK_03
    $validGuestIp = @($guestNetwork | Where-Object { Test-ValidIPv4 -Ip $_.ip })
    if ($validGuestIp.Count -eq 0) {
        Add-Check -Id 'CHECK_03' -Status 'FAIL' -Detail 'No valid in-guest IP could be retrieved.'
        Write-Error '[FATAL][CHECK_03] Aucune IP valide recuperee dans le guest. Migration interdite.'
        $blockingFailure = $true
    }
    else {
        $fallbackOnly = (@($validGuestIp | Where-Object { $_.source -eq 'vmware-tools-fallback' }).Count -eq $validGuestIp.Count)
        if ($fallbackOnly) {
            Add-Check -Id 'CHECK_03' -Status 'WARN' -Detail 'IP retrieved only via VMware Tools fallback.'
        }
        else {
            Add-Check -Id 'CHECK_03' -Status 'PASS' -Detail 'Guest IP retrieved via Invoke-VMScript.'
        }
    }

    # CHECK_04
    $hwVersionNumber = Convert-HardwareVersionToInt -HardwareVersion $hardwareVersion
    if ($hwVersionNumber -lt 13) {
        Add-Check -Id 'CHECK_04' -Status 'WARN' -Detail "Hardware version low: $hardwareVersion"
    }
    else {
        Add-Check -Id 'CHECK_04' -Status 'PASS' -Detail "Hardware version compatible: $hardwareVersion"
    }

    # CHECK_05
    if ([string]::IsNullOrWhiteSpace($toolsVersion) -or $toolsVersion -eq '0') {
        Add-Check -Id 'CHECK_05' -Status 'WARN' -Detail 'VMware Tools missing or unknown version.'
    }
    else {
        Add-Check -Id 'CHECK_05' -Status 'PASS' -Detail "VMware Tools version: $toolsVersion"
    }

    # CHECK_06
    $oversizedDisk = $disks | Where-Object { [double]$_.size_gb -gt 2048 }
    if ($oversizedDisk) {
        $labels = ($oversizedDisk | Select-Object -ExpandProperty label) -join ', '
        Add-Check -Id 'CHECK_06' -Status 'WARN' -Detail "Disk larger than 2 TB: $labels"
    }
    else {
        Add-Check -Id 'CHECK_06' -Status 'PASS' -Detail 'No disk larger than 2 TB.'
    }

    # CHECK_07
    $nonVmxnet = $nics | Where-Object { $_.type -notmatch 'VMXNET3' }
    if ($nonVmxnet) {
        $nicNames = ($nonVmxnet | Select-Object -ExpandProperty name) -join ', '
        Add-Check -Id 'CHECK_07' -Status 'WARN' -Detail "Non-VMXNET3 adapter(s): $nicNames"
    }
    else {
        Add-Check -Id 'CHECK_07' -Status 'PASS' -Detail 'All adapters are VMXNET3.'
    }

    # CHECK_08 — Legacy guest OS gating
    if (Test-LegacyOS -OsName $guestFullName) {
        if ($ApproveLegacyOS) {
            Add-Check -Id 'CHECK_08' -Status 'WARN' -Detail "Legacy guest OS approved for migration: $guestFullName"
            Write-MigLog -Level WARN -Message "Legacy OS '$guestFullName' explicitly approved (-ApproveLegacyOS). Proceed with caution."
        }
        else {
            Add-Check -Id 'CHECK_08' -Status 'FAIL' -Detail "Legacy guest OS not approved: $guestFullName"
            Write-Error "[FATAL][CHECK_08] Legacy OS detecte : $guestFullName. Utilisez -ApproveLegacyOS pour autoriser explicitement."
            $blockingFailure = $true
        }
    }
    else {
        Add-Check -Id 'CHECK_08' -Status 'PASS' -Detail "Guest OS not flagged as legacy: $guestFullName"
    }

    if ($blockingFailure) {
        $script:overallExitCode = 2
        exit 2
    }
    #endregion

    $hasWarn = @($script:checks | Where-Object { $_.status -eq 'WARN' }).Count -gt 0
    $overallStatus = if ($hasWarn) { 'WARNING' } else { 'READY' }

    $manifest = [ordered]@{
        schema_version = '1.2'
        generated_at = (Get-Date).ToString('o')
        migration_id = [guid]::NewGuid().Guid
        source = [ordered]@{
            vm_name = $VMName
            vcenter = if ($viServer) { $viServer.Name } else { $vCenterServer }
            power_state = $powerState
            os_guest = $guestFullName
            hardware_version = $hardwareVersion
            tools_version = [string]$toolsVersion
        }
        compute = [ordered]@{
            vcpu = $cpu
            ram_mb = $ramMB
            firmware = $firmware
            secure_boot = [bool]$secureBoot
        }
        disks = @($disks)
        network_adapters = @($nics)
        guest_network = @($guestNetwork)
        checks = @($script:checks)
        overall_status = $overallStatus
        exit_code = 0
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    Set-Content -Path $manifestPath -Value $manifestJson -Encoding UTF8

    Write-MigLog -Level INFO -Message "Manifest generated: $manifestPath"
    if ($overallStatus -eq 'WARNING') {
        Write-MigLog -Level WARN -Message 'Discovery completed with warnings.'
    }
    else {
        Write-MigLog -Level INFO -Message 'Discovery completed successfully.'
    }

    $ErrorActionPreference = 'Continue'
    exit 0
}
catch {
    Write-MigLog -Level ERROR -Message "Unexpected error: $($_.Exception.Message)"
    Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
    $ErrorActionPreference = 'Continue'
    if ($script:overallExitCode -eq 0) {
        exit 1
    }
    exit $script:overallExitCode
}
finally {
    $ErrorActionPreference = 'Continue'
    if ($script:sessionCreatedHere -and (Get-Command -Name Disconnect-VIServer -ErrorAction SilentlyContinue)) {
        try {
            Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-MigLog -Level INFO -Message 'Disconnected vCenter session created by this script.'
        }
        catch {
            Write-MigLog -Level WARN -Message "Could not disconnect vCenter session: $($_.Exception.Message)"
        }
    }
}
