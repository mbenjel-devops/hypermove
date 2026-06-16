<#
.SYNOPSIS
Performs rollback and cleanup actions for VMware to Hyper-V migration.

.DESCRIPTION
Designed to continue on errors and record each action result. Can be run manually
or automatically by orchestrator after EXEC/POST failures.

.PARAMETER VMName
Target VM name.

.PARAMETER ManifestPath
Path to migration manifest JSON.

.PARAMETER HyperVHost
Hyper-V host.

.PARAMETER TempDir
Temporary local export directory.

.PARAMETER RollbackScope
Scope of rollback operations.

.PARAMETER Force
Skip interactive confirmation.

.PARAMETER RestoreSourceVM
Attempt to start source VMware VM if it was stopped during migration.

.EXAMPLE
.\04-ROLLBACK.ps1 -VMName "SRVWEB01" -Force -RestoreSourceVM

.NOTES
Version: 1.0.0
Author: GitHub Copilot
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$ManifestPath = "C:\Migration\Manifests\manifest-$VMName.json",
    [string]$HyperVHost = $env:HYPERV_HOST,
    [string]$TempDir = "$env:TEMP\Migration\$VMName",
    [ValidateSet('Full', 'HyperVOnly', 'TempFiles', 'SourceVM')][string]$RollbackScope = 'Full',
    [switch]$Force,
    [switch]$RestoreSourceVM
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0
$script:PhaseName = 'PHASE-ROLLBACK'

function Write-MigLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][$script:PhaseName] $Message"
}

$actions = New-Object System.Collections.Generic.List[object]
$anyFailed = $false
$manifest = $null
$sourceVmIp = ''
$tempFreedGb = 0
$hypervDeleted = $false
$snapshotRemoved = $false
$sourceRestored = $false

function Add-ActionResult {
    param(
        [string]$Action,
        [ValidateSet('SUCCESS', 'FAILED', 'SKIPPED')][string]$Status,
        [string]$Detail
    )
    $actions.Add([ordered]@{
        action = $Action
        status = $Status
        detail = $Detail
        timestamp = (Get-Date).ToString('o')
    }) | Out-Null

    if ($Status -eq 'FAILED') {
        $script:anyFailed = $true
    }
}

try {
    if (Test-Path -Path $ManifestPath) {
        try {
            $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-MigLog -Level WARN -Message "Could not parse manifest: $($_.Exception.Message)"
        }
    }

    if ((-not $Force) -and [Environment]::UserInteractive -and (-not $env:CI)) {
        Write-MigLog -Level INFO -Message "Rollback scope: $RollbackScope"
        $answer = Read-Host 'Confirmer le rollback ? (O/N)'
        if ($answer -notin @('O', 'o')) {
            Write-MigLog -Level INFO -Message 'Rollback canceled by operator.'
            exit 0
        }
    }

    $doHyperV = $RollbackScope -in @('Full', 'HyperVOnly')
    $doTemp = $RollbackScope -in @('Full', 'TempFiles')
    $doSource = $RollbackScope -in @('Full', 'SourceVM')

    # ACTION 1
    if ($doHyperV) {
        try {
            Write-MigLog -Level INFO -Message "[AUDIT] Attempting Hyper-V VM removal for $VMName on $HyperVHost"
            $hvm = Get-VM -Name $VMName -ComputerName $HyperVHost -ErrorAction SilentlyContinue
            if ($hvm) {
                if ($hvm.State -eq 'Running') {
                    Stop-VM -Name $VMName -ComputerName $HyperVHost -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Remove-VM -Name $VMName -ComputerName $HyperVHost -Force -ErrorAction SilentlyContinue
                $hypervDeleted = $true

                if ($manifest -and $manifest.exec_result -and $manifest.exec_result.vhdx_files) {
                    foreach ($v in @($manifest.exec_result.vhdx_files)) {
                        if ($v.path -and (Test-Path -Path $v.path)) {
                            Write-MigLog -Level INFO -Message "[AUDIT] Deleting VHDX: $($v.path)"
                            Remove-Item -Path $v.path -Force -ErrorAction SilentlyContinue
                        }
                    }
                }

                Add-ActionResult -Action 'remove_hyperv_vm' -Status 'SUCCESS' -Detail 'Hyper-V VM and known VHDX files removed if present.'
            }
            else {
                Add-ActionResult -Action 'remove_hyperv_vm' -Status 'SKIPPED' -Detail 'Hyper-V VM not found.'
            }
        }
        catch {
            Write-MigLog -Level ERROR -Message "Hyper-V cleanup failed: $($_.Exception.Message)"
            Add-ActionResult -Action 'remove_hyperv_vm' -Status 'FAILED' -Detail $_.Exception.Message
        }
    }
    else {
        Add-ActionResult -Action 'remove_hyperv_vm' -Status 'SKIPPED' -Detail 'Scope excludes Hyper-V actions.'
    }

    # ACTION 2
    if ($doTemp) {
        try {
            if (Test-Path -Path $TempDir) {
                $items = Get-ChildItem -Path $TempDir -Recurse -File -ErrorAction SilentlyContinue
                $size = ($items | Measure-Object -Property Length -Sum).Sum
                if (-not $size) { $size = 0 }
                $tempFreedGb = [Math]::Round(($size / 1GB), 2)

                Write-MigLog -Level INFO -Message "[AUDIT] Removing temp directory: $TempDir"
                Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
                Add-ActionResult -Action 'cleanup_temp_files' -Status 'SUCCESS' -Detail "Temp directory removed. Freed ${tempFreedGb} GB"
            }
            else {
                Add-ActionResult -Action 'cleanup_temp_files' -Status 'SKIPPED' -Detail 'Temp directory not found.'
            }
        }
        catch {
            Write-MigLog -Level ERROR -Message "Temp cleanup failed: $($_.Exception.Message)"
            Add-ActionResult -Action 'cleanup_temp_files' -Status 'FAILED' -Detail $_.Exception.Message
        }
    }
    else {
        Add-ActionResult -Action 'cleanup_temp_files' -Status 'SKIPPED' -Detail 'Scope excludes temp cleanup.'
    }

    # ACTION 3
    if ($doSource) {
        try {
            $migrationId = if ($manifest) { [string]$manifest.migration_id } else { '' }
            $targetSnapName = if ($manifest -and $manifest.exec_result -and $manifest.exec_result.migration_snapshot_name) {
                [string]$manifest.exec_result.migration_snapshot_name
            }
            elseif ($migrationId) {
                "MIG-EXPORT-$migrationId"
            }
            else {
                $null
            }

            if ($targetSnapName) {
                $srcVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                if ($srcVm) {
                    $snaps = @(Get-Snapshot -VM $srcVm -Name 'MIG-EXPORT-*' -ErrorAction SilentlyContinue)
                    $toRemove = $snaps | Where-Object { $_.Name -eq $targetSnapName }
                    if ($toRemove) {
                        Write-MigLog -Level INFO -Message "[AUDIT] Removing VMware migration snapshot: $targetSnapName"
                        Remove-Snapshot -Snapshot $toRemove -Confirm:$false -RunAsync:$false -ErrorAction SilentlyContinue | Out-Null
                        $snapshotRemoved = $true
                        Add-ActionResult -Action 'cleanup_vmware_snapshot' -Status 'SUCCESS' -Detail "Snapshot removed: $targetSnapName"
                    }
                    else {
                        Add-ActionResult -Action 'cleanup_vmware_snapshot' -Status 'SKIPPED' -Detail 'No matching migration snapshot found.'
                    }
                }
                else {
                    Add-ActionResult -Action 'cleanup_vmware_snapshot' -Status 'SKIPPED' -Detail 'Source VMware VM not found.'
                }
            }
            else {
                Add-ActionResult -Action 'cleanup_vmware_snapshot' -Status 'SKIPPED' -Detail 'No migration snapshot name available.'
            }
        }
        catch {
            Write-MigLog -Level ERROR -Message "Snapshot cleanup failed: $($_.Exception.Message)"
            Add-ActionResult -Action 'cleanup_vmware_snapshot' -Status 'FAILED' -Detail $_.Exception.Message
        }
    }
    else {
        Add-ActionResult -Action 'cleanup_vmware_snapshot' -Status 'SKIPPED' -Detail 'Scope excludes source cleanup.'
    }

    # ACTION 4
    if ($doSource -and $RestoreSourceVM) {
        try {
            $sourceVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if ($sourceVm) {
                if ($sourceVm.PowerState -eq 'PoweredOff') {
                    Write-MigLog -Level INFO -Message "[AUDIT] Starting source VMware VM: $VMName"
                    Start-VM -VM $sourceVm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                }

                $deadline = (Get-Date).AddMinutes(3)
                do {
                    Start-Sleep -Seconds 10
                    $guest = Get-VMGuest -VM $sourceVm -ErrorAction SilentlyContinue
                } while (($guest.ToolsRunningStatus -ne 'guestToolsRunning') -and ((Get-Date) -lt $deadline))

                if ($guest -and $guest.IPAddress) {
                    $sourceVmIp = (@($guest.IPAddress) | Select-Object -First 1)
                }

                $sourceRestored = $true
                if ($guest.ToolsRunningStatus -eq 'guestToolsRunning') {
                    Add-ActionResult -Action 'restore_source_vm' -Status 'SUCCESS' -Detail "Source VM restored. IP=$sourceVmIp"
                }
                else {
                    Add-ActionResult -Action 'restore_source_vm' -Status 'SUCCESS' -Detail 'Source VM started but VMware Tools timeout reached.'
                    Write-MigLog -Level WARN -Message 'VMware Tools did not report running state within timeout.'
                }
            }
            else {
                Add-ActionResult -Action 'restore_source_vm' -Status 'SKIPPED' -Detail 'Source VM not found.'
            }
        }
        catch {
            Write-MigLog -Level ERROR -Message "Source restore failed: $($_.Exception.Message)"
            Add-ActionResult -Action 'restore_source_vm' -Status 'FAILED' -Detail $_.Exception.Message
        }
    }
    elseif ($RestoreSourceVM) {
        Add-ActionResult -Action 'restore_source_vm' -Status 'SKIPPED' -Detail 'Scope excludes source VM actions.'
    }
    else {
        Add-ActionResult -Action 'restore_source_vm' -Status 'SKIPPED' -Detail 'RestoreSourceVM not requested.'
    }

    # ACTION 5
    try {
        $reportDir = 'C:\Migration\Reports'
        if (-not (Test-Path -Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }

        $trigger = 'manual'
        if ($env:ROLLBACK_TRIGGER) {
            $trigger = [string]$env:ROLLBACK_TRIGGER
        }

        $incident = [ordered]@{
            incident_id = [guid]::NewGuid().Guid
            migration_id = if ($manifest) { [string]$manifest.migration_id } else { '' }
            timestamp = (Get-Date).ToString('o')
            trigger = $trigger
            rollback_scope = $RollbackScope
            actions_performed = @($actions)
            hyperv_vm_deleted = [bool]$hypervDeleted
            temp_files_cleaned_gb = [double]$tempFreedGb
            migration_snapshot_removed = [bool]$snapshotRemoved
            source_vm_restored = [bool]$sourceRestored
            source_vm_ip_confirmed = $sourceVmIp
            incident_status = if ($anyFailed) { 'PARTIAL' } else { 'RESOLVED' }
        }

        $incidentFile = Join-Path -Path $reportDir -ChildPath ("incident-{0}-{1}.json" -f $VMName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $incident | ConvertTo-Json -Depth 12 | Set-Content -Path $incidentFile -Encoding UTF8
        Add-ActionResult -Action 'write_incident_report' -Status 'SUCCESS' -Detail "Report generated: $incidentFile"

        # ACTION 6
        if ($env:ALERTING_WEBHOOK) {
            try {
                $format = if ($env:ALERTING_FORMAT) { $env:ALERTING_FORMAT } else { 'generic' }
                $payload = $null

                switch ($format.ToLowerInvariant()) {
                    'teams' {
                        $payloadObj = [ordered]@{
                            type = 'message'
                            attachments = @([ordered]@{
                                contentType = 'application/vnd.microsoft.card.adaptive'
                                content = [ordered]@{
                                    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                                    type = 'AdaptiveCard'
                                    version = '1.4'
                                    body = @(
                                        [ordered]@{ type = 'TextBlock'; weight = 'Bolder'; size = 'Medium'; text = "Rollback incident: $VMName" },
                                        [ordered]@{ type = 'TextBlock'; text = "Incident ID: $($incident.incident_id)" },
                                        [ordered]@{ type = 'TextBlock'; text = "Actions count: $($actions.Count)" }
                                    )
                                }
                            })
                        }
                        $payload = ($payloadObj | ConvertTo-Json -Depth 12)
                    }
                    'slack' {
                        $payloadObj = [ordered]@{
                            text = "Rollback incident for $VMName"
                            attachments = @([ordered]@{
                                color = 'danger'
                                fields = @(
                                    [ordered]@{ title = 'Incident'; value = $incident.incident_id; short = $false },
                                    [ordered]@{ title = 'Actions'; value = [string]$actions.Count; short = $true }
                                )
                            })
                        }
                        $payload = ($payloadObj | ConvertTo-Json -Depth 12)
                    }
                    default {
                        $payload = ($incident | ConvertTo-Json -Depth 12)
                    }
                }

                Invoke-RestMethod -Uri $env:ALERTING_WEBHOOK -Method POST -Body $payload -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Add-ActionResult -Action 'alerting_webhook' -Status 'SUCCESS' -Detail 'Webhook notification sent.'
            }
            catch {
                Write-MigLog -Level WARN -Message "Webhook call failed: $($_.Exception.Message)"
                Add-ActionResult -Action 'alerting_webhook' -Status 'FAILED' -Detail $_.Exception.Message
            }
        }
        else {
            Add-ActionResult -Action 'alerting_webhook' -Status 'SKIPPED' -Detail 'ALERTING_WEBHOOK not defined.'
        }
    }
    catch {
        Write-MigLog -Level ERROR -Message "Incident report generation failed: $($_.Exception.Message)"
        Add-ActionResult -Action 'write_incident_report' -Status 'FAILED' -Detail $_.Exception.Message
    }

    if ($anyFailed) {
        exit 1
    }

    exit 0
}
catch {
    Write-MigLog -Level ERROR -Message "Unexpected rollback error: $($_.Exception.Message)"
    exit 1
}
