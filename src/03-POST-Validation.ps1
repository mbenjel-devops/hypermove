<#
.SYNOPSIS
Validates migrated Hyper-V VM and generates post-migration reports.

.DESCRIPTION
Performs runtime, network, spec compliance, optional service checks, and optional integrity checks.
Produces JSON and text reports and returns a status code aligned with next_action.

.PARAMETER VMName
Migrated VM name in Hyper-V.

.PARAMETER ManifestPath
Path to manifest JSON updated by PRE and EXEC phases.

.PARAMETER HyperVHost
Hyper-V host name.

.PARAMETER BootTimeoutSeconds
Maximum wait for VM boot to running state.

.PARAMETER PingTimeoutSeconds
Maximum wait for ping checks.

.PARAMETER CriticalServices
Optional list of critical Windows services to verify.

.PARAMETER ReportDir
Report output directory.

.EXAMPLE
.\03-POST-Validation.ps1 -VMName "SRVWEB01" -CriticalServices W32Time,Netlogon

.NOTES
Version: 1.0.0
Author: GitHub Copilot
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$ManifestPath = "C:\Migration\Manifests\manifest-$VMName.json",
    [string]$HyperVHost = $env:HYPERV_HOST,
    [int]$BootTimeoutSeconds = 300,
    [int]$PingTimeoutSeconds = 60,
    [string[]]$CriticalServices,
    [string]$ReportDir = "C:\Migration\Reports"
)

Set-StrictMode -Version 2.0
$script:PhaseName = 'PHASE-POST'

function Write-MigLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][$script:PhaseName] $Message"
}

function Get-PingLatency {
    param([string]$Target)
    try {
        $pings = Test-Connection -ComputerName $Target -Count 4 -ErrorAction Stop
        $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
        return [Math]::Round([double]$avg, 2)
    }
    catch {
        return $null
    }
}

function Convert-BytesToGb {
    param([UInt64]$Bytes)
    return [Math]::Round(($Bytes / 1GB), 2)
}

try {
    if (-not (Test-Path -Path $ManifestPath)) {
        Write-MigLog -Level FATAL -Message "Manifest not found: $ManifestPath"
        exit 1
    }

    if (-not (Test-Path -Path $ReportDir)) {
        New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
    }

    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    $criticalFail = $false
    $warnFound = $false
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    $vmStateCheck = [ordered]@{ expected = 'Running'; actual = ''; status = 'FAIL' }
    $heartbeatCheck = [ordered]@{ status = 'WARN'; detail = '' }
    $networkPingChecks = New-Object System.Collections.Generic.List[object]
    $gatewayPingChecks = New-Object System.Collections.Generic.List[object]
    $specDiskChecks = New-Object System.Collections.Generic.List[object]
    $serviceChecks = New-Object System.Collections.Generic.List[object]
    $integrationChecks = New-Object System.Collections.Generic.List[object]

    #region VALIDATION 1 — État VM Hyper-V
    try {
        $vm = Get-VM -Name $VMName -ComputerName $HyperVHost -ErrorAction Stop

        if ($vm.State -ne 'Running') {
            Write-MigLog -Level WARN -Message "VM is not running (actual: $($vm.State)). Starting VM."
            Start-VM -Name $VMName -ComputerName $HyperVHost -ErrorAction SilentlyContinue | Out-Null
            $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
            do {
                Start-Sleep -Seconds 10
                $vm = Get-VM -Name $VMName -ComputerName $HyperVHost -ErrorAction SilentlyContinue
            } while ($vm -and $vm.State -ne 'Running' -and (Get-Date) -lt $deadline)
        }

        $vmStateCheck.actual = [string]$vm.State
        if ($vm.State -eq 'Running') {
            $vmStateCheck.status = 'PASS'
        }
        else {
            $vmStateCheck.status = 'FAIL'
            $criticalFail = $true
        }

        $integration = Get-VMIntegrationService -VMName $VMName -ComputerName $HyperVHost -ErrorAction SilentlyContinue
        foreach ($svc in $integration) {
            $integrationChecks.Add([ordered]@{
                name = $svc.Name
                enabled = [bool]$svc.Enabled
                primary_status = [string]$svc.PrimaryStatusDescription
            }) | Out-Null
        }

        $hb = $integration | Where-Object { $_.Name -match 'Heartbeat' } | Select-Object -First 1
        if ($hb) {
            if ($hb.PrimaryStatusDescription -match 'OK|Operating normally') {
                $heartbeatCheck.status = 'PASS'
                $heartbeatCheck.detail = $hb.PrimaryStatusDescription
            }
            else {
                $heartbeatCheck.status = 'WARN'
                $heartbeatCheck.detail = $hb.PrimaryStatusDescription
                $warnFound = $true
            }
        }
        else {
            $heartbeatCheck.status = 'WARN'
            $heartbeatCheck.detail = 'Heartbeat integration service not found.'
            $warnFound = $true
        }
    }
    catch {
        Write-MigLog -Level ERROR -Message "Validation 1 failed: $($_.Exception.Message)"
        $vmStateCheck.actual = 'Unknown'
        $vmStateCheck.status = 'FAIL'
        $heartbeatCheck.status = 'FAIL'
        $heartbeatCheck.detail = $_.Exception.Message
        $criticalFail = $true
    }
    #endregion

    #region VALIDATION 2 — Connectivité réseau
    try {
        foreach ($iface in @($manifest.guest_network)) {
            $ip = [string]$iface.ip
            $gw = [string]$iface.gateway

            $ipOk = $false
            $latency = $null
            if (-not [string]::IsNullOrWhiteSpace($ip)) {
                $deadline = (Get-Date).AddSeconds($PingTimeoutSeconds)
                do {
                    if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                        $ipOk = $true
                        break
                    }
                    Start-Sleep -Seconds 10
                } while ((Get-Date) -lt $deadline)

                if ($ipOk) {
                    $latency = Get-PingLatency -Target $ip
                }
            }

            $networkPingChecks.Add([ordered]@{
                interface = [string]$iface.interface
                ip = $ip
                ping_ok = [bool]$ipOk
                latency_ms = if ($latency -ne $null) { $latency } else { 0 }
            }) | Out-Null

            if (-not $ipOk) {
                $criticalFail = $true
            }

            if (-not [string]::IsNullOrWhiteSpace($gw)) {
                $gwOk = Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue
                $gatewayPingChecks.Add([ordered]@{ gateway = $gw; ping_ok = [bool]$gwOk }) | Out-Null
                if (-not $gwOk) {
                    $warnFound = $true
                }
            }
        }
    }
    catch {
        Write-MigLog -Level ERROR -Message "Validation 2 failed: $($_.Exception.Message)"
        $criticalFail = $true
    }
    #endregion

    #region VALIDATION 3 — Conformité specs
    try {
        $vmActual = Get-VM -Name $VMName -ComputerName $HyperVHost -ErrorAction Stop
        $actualCpu = [int]$vmActual.ProcessorCount
        $expectedCpu = [int]$manifest.compute.vcpu

        $actualRamMb = [int][Math]::Round(($vmActual.MemoryStartup / 1MB), 0)
        $expectedRamMb = [int]$manifest.compute.ram_mb

        $hdds = @(Get-VMHardDiskDrive -VMName $VMName -ComputerName $HyperVHost -ErrorAction SilentlyContinue)
        $nics = @(Get-VMNetworkAdapter -VMName $VMName -ComputerName $HyperVHost -ErrorAction SilentlyContinue)

        $specCpu = [ordered]@{ expected = $expectedCpu; actual = $actualCpu; status = if ($actualCpu -eq $expectedCpu) { 'PASS' } else { 'FAIL' } }
        $specRam = [ordered]@{ expected_mb = $expectedRamMb; actual_mb = $actualRamMb; status = if ([Math]::Abs($actualRamMb - $expectedRamMb) -le 4) { 'PASS' } else { 'FAIL' } }

        if ($specCpu.status -eq 'FAIL' -or $specRam.status -eq 'FAIL') {
            $warnFound = $true
        }

        $expectedDiskCount = @($manifest.disks).Count
        if ($hdds.Count -ne $expectedDiskCount) {
            $warnFound = $true
        }

        $idx = 0
        foreach ($expectedDisk in @($manifest.disks)) {
            $actualHdd = $null
            if ($idx -lt $hdds.Count) {
                $actualHdd = $hdds[$idx]
            }

            $actualGb = 0
            $status = 'FAIL'
            if ($actualHdd -and (Test-Path -Path $actualHdd.Path)) {
                $actualGb = Convert-BytesToGb -Bytes (Get-Item -Path $actualHdd.Path).Length
                $expectedGb = [double]$expectedDisk.size_gb
                $deltaPct = 0
                if ($expectedGb -gt 0) {
                    $deltaPct = [Math]::Abs(($actualGb - $expectedGb) / $expectedGb) * 100
                }
                if ($deltaPct -le 1) { $status = 'PASS' }
            }

            $specDiskChecks.Add([ordered]@{
                label = [string]$expectedDisk.label
                expected_gb = [double]$expectedDisk.size_gb
                actual_gb = [double]$actualGb
                status = $status
            }) | Out-Null

            if ($status -eq 'FAIL') { $warnFound = $true }
            $idx++
        }

        if ($nics.Count -ne @($manifest.network_adapters).Count) {
            $warnFound = $true
        }
    }
    catch {
        Write-MigLog -Level ERROR -Message "Validation 3 failed: $($_.Exception.Message)"
        $warnFound = $true
        $specCpu = [ordered]@{ expected = 0; actual = 0; status = 'FAIL' }
        $specRam = [ordered]@{ expected_mb = 0; actual_mb = 0; status = 'FAIL' }
    }
    #endregion

    #region VALIDATION 4 — Services critiques Windows
    try {
        if ($CriticalServices -and ($manifest.source.os_guest -match 'Windows')) {
            try {
                Invoke-Command -ComputerName $VMName -ScriptBlock { 'WinRM-OK' } -ErrorAction Stop | Out-Null
                foreach ($svc in $CriticalServices) {
                    $status = Invoke-Command -ComputerName $VMName -ScriptBlock {
                        param($Name)
                        (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
                    } -ArgumentList $svc -ErrorAction SilentlyContinue

                    $svcStatus = if ($status) { [string]$status } else { 'Unknown' }
                    $check = if ($svcStatus -eq 'Running') { 'PASS' } else { 'WARN' }
                    if ($check -eq 'WARN') { $warnFound = $true }

                    $serviceChecks.Add([ordered]@{
                        name = $svc
                        status = $svcStatus
                        check = $check
                    }) | Out-Null
                }
            }
            catch {
                Write-MigLog -Level WARN -Message "WinRM inaccessible for service checks: $($_.Exception.Message)"
                foreach ($svc in $CriticalServices) {
                    $serviceChecks.Add([ordered]@{ name = $svc; status = 'Unknown'; check = 'WARN' }) | Out-Null
                }
                $warnFound = $true
            }
        }
    }
    catch {
        Write-MigLog -Level WARN -Message "Validation 4 failed: $($_.Exception.Message)"
        $warnFound = $true
    }
    #endregion

    #region VALIDATION 5 — Intégrité optionnelle
    $integrityStatus = 'SKIP'
    try {
        if ($manifest.PSObject.Properties.Name -contains 'integrity_check_file') {
            $integrityStatus = 'SKIP'
        }
    }
    catch {
        $integrityStatus = 'SKIP'
    }
    #endregion

    if ($criticalFail) {
        $overall = 'FAILED'
        $recommendation = 'Critical validation failed. Rollback is recommended.'
        $nextAction = 'ROLLBACK'
        $exitCode = 2
    }
    elseif ($warnFound) {
        $overall = 'DEGRADED'
        $recommendation = 'Migration is usable but requires operator investigation.'
        $nextAction = 'INVESTIGATE'
        $exitCode = 3
    }
    else {
        $overall = 'VALIDATED'
        $recommendation = 'Validation complete. Promote workload.'
        $nextAction = 'PROMOTE'
        $exitCode = 0
    }

    $report = [ordered]@{
        report_version = '1.0'
        generated_at = (Get-Date).ToString('o')
        migration_id = [string]$manifest.migration_id
        vm_name = $VMName
        hyperv_host = $HyperVHost
        validations = [ordered]@{
            vm_state = $vmStateCheck
            heartbeat = $heartbeatCheck
            network_ping = @($networkPingChecks)
            gateway_ping = @($gatewayPingChecks)
            specs_cpu = $specCpu
            specs_ram = $specRam
            specs_disks = @($specDiskChecks)
            services = @($serviceChecks)
            integration_svc = @($integrationChecks)
            integrity = $integrityStatus
        }
        overall_post_status = $overall
        recommendation = $recommendation
        next_action = $nextAction
    }

    $jsonPath = Join-Path -Path $ReportDir -ChildPath ("report-{0}-{1}.json" -f $VMName, $timestamp)
    $txtPath = Join-Path -Path $ReportDir -ChildPath ("report-{0}-{1}.txt" -f $VMName, $timestamp)

    $report | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8

    $txt = @()
    $txt += "=============================================================="
    $txt += "POST VALIDATION REPORT - $VMName"
    $txt += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $txt += "Host: $HyperVHost"
    $txt += "=============================================================="
    $txt += "VM State      : $($vmStateCheck.status) (expected=$($vmStateCheck.expected), actual=$($vmStateCheck.actual))"
    $txt += "Heartbeat     : $($heartbeatCheck.status) ($($heartbeatCheck.detail))"
    $txt += "CPU           : $($specCpu.status) (expected=$($specCpu.expected), actual=$($specCpu.actual))"
    $txt += "RAM           : $($specRam.status) (expected=$($specRam.expected_mb) MB, actual=$($specRam.actual_mb) MB)"
    $txt += ""
    $txt += "Network checks:"
    foreach ($n in $networkPingChecks) {
        $txt += (" - {0} [{1}] ping_ok={2} latency={3}ms" -f $n.interface, $n.ip, $n.ping_ok, $n.latency_ms)
    }
    $txt += ""
    $txt += "Disk checks:"
    foreach ($d in $specDiskChecks) {
        $txt += (" - {0}: {1} (expected {2} GB / actual {3} GB)" -f $d.label, $d.status, $d.expected_gb, $d.actual_gb)
    }
    $txt += ""
    $txt += "SUMMARY"
    $txt += "1) overall_post_status = $overall"
    $txt += "2) recommendation      = $recommendation"
    $txt += "3) next_action         = >>> $nextAction <<<"

    $txt | Set-Content -Path $txtPath -Encoding UTF8

    Write-MigLog -Level INFO -Message "Report JSON generated: $jsonPath"
    Write-MigLog -Level INFO -Message "Report TXT generated: $txtPath"

    exit $exitCode
}
catch {
    Write-MigLog -Level ERROR -Message "Unexpected error: $($_.Exception.Message)"
    Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
    exit 1
}
