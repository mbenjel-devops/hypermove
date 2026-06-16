<#
.SYNOPSIS
Orchestrates VMware to Hyper-V migration pipeline.

.DESCRIPTION
Runs PRE, EXEC, POST, and optional ROLLBACK phases for one or many VMs.
Supports multiple operation modes (single VM, batch list, manifests discovery),
centralized logging, retry policy for EXEC, dry-run, and JSON summary output.

.PARAMETER VMName
Single VM name (used in SINGLE mode).

.PARAMETER ConfigFile
Path to JSON config.

.PARAMETER Phase
Single phase or full pipeline.

.PARAMETER Mode
Execution mode:
- SINGLE: one VM via -VMName
- BATCH: many VMs from -VMNames or -VMListPath CSV
- FROM_MANIFESTS: discover VM names from manifest files in output_dir

.PARAMETER VMListPath
CSV path for BATCH mode. Requires column VMName.

.PARAMETER VMNames
Array of VM names for BATCH mode.

.PARAMETER DryRun
Simulate execution without running child scripts.

.PARAMETER AutoRollback
Automatically invoke rollback when EXEC/POST fails critically in FULL mode.

.PARAMETER RestoreSourceOnFail
Pass restore switch to rollback when auto-triggered.

.PARAMETER ConversionTool
Preferred conversion tool for EXEC.

.PARAMETER StartVMAfterMigration
Start VM after EXEC creation.

.PARAMETER ContinueOnError
In multi-VM mode, continue processing next VM after a failure.

.PARAMETER MaxExecRetries
Maximum retry count for EXEC failures.

.PARAMETER RetryWaitSeconds
Wait in seconds between EXEC retries.

.PARAMETER SkipPrereqChecks
Skip module and environment prechecks.

.EXAMPLE
.\00-Orchestrator.ps1 -VMName "SRVWEB01" -Mode SINGLE -Phase FULL -AutoRollback

.EXAMPLE
.\00-Orchestrator.ps1 -Mode BATCH -VMListPath "C:\Migration\input\vm-list.csv" -Phase FULL -ContinueOnError

.EXAMPLE
.\00-Orchestrator.ps1 -Mode FROM_MANIFESTS -Phase POST

.EXAMPLE
.\00-Orchestrator.ps1 -VMNames "SRVWEB01","SRVAPP02" -Mode BATCH -DryRun

.NOTES
Version: 2.0.0
Author: GitHub Copilot
#>
[CmdletBinding()]
param(
    [string]$VMName,
    [string]$ConfigFile = "C:\Migration\config.json",
    [ValidateSet('PRE', 'EXEC', 'POST', 'ROLLBACK', 'FULL')][string]$Phase = 'FULL',
    [ValidateSet('SINGLE', 'BATCH', 'FROM_MANIFESTS')][string]$Mode = 'SINGLE',
    [string]$VMListPath,
    [string[]]$VMNames,
    [switch]$DryRun,
    [switch]$AutoRollback,
    [switch]$RestoreSourceOnFail,
    [string]$ConversionTool = 'StarWindV2V',
    [switch]$StartVMAfterMigration,
    [switch]$ContinueOnError,
    [int]$MaxExecRetries = 1,
    [int]$RetryWaitSeconds = 60,
    [switch]$SkipPrereqChecks
)

Set-StrictMode -Version 2.0
$script:PhaseName = 'ORCHESTRATOR'

function Write-MigLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][$script:PhaseName] $Message"
}

function Start-PhaseBanner {
    param([string]$Name)
    Write-Output ("======== [{0}] DEBUT {1} ========" -f $Name, (Get-Date))
}

function Stop-PhaseBanner {
    param([string]$Name, [int]$ExitCode)
    Write-Output ("======== [{0}] FIN   {1} - Exit: {2} ========" -f $Name, (Get-Date), $ExitCode)
}

function New-PhaseState {
    [ordered]@{
        status = 'SKIPPED'
        exit_code = 0
        duration_s = 0
        retries = 0
    }
}

function Resolve-TargetVMs {
    param(
        [Parameter(Mandatory)][string]$ResolvedMode,
        [string]$SingleVmName,
        [string]$CsvPath,
        [string[]]$ArrayVmNames,
        [string]$ManifestDirectory
    )

    $result = New-Object System.Collections.Generic.List[string]

    switch ($ResolvedMode) {
        'SINGLE' {
            if ([string]::IsNullOrWhiteSpace($SingleVmName)) {
                throw 'VMName is mandatory in SINGLE mode.'
            }
            $result.Add($SingleVmName) | Out-Null
        }
        'BATCH' {
            if ($ArrayVmNames -and $ArrayVmNames.Count -gt 0) {
                foreach ($n in $ArrayVmNames) {
                    if (-not [string]::IsNullOrWhiteSpace($n)) {
                        $result.Add($n.Trim()) | Out-Null
                    }
                }
            }

            if ($CsvPath) {
                if (-not (Test-Path -Path $CsvPath)) {
                    throw "VM list CSV not found: $CsvPath"
                }
                $rows = Import-Csv -Path $CsvPath
                foreach ($r in $rows) {
                    if ($r.PSObject.Properties.Name -contains 'VMName') {
                        $name = [string]$r.VMName
                        if (-not [string]::IsNullOrWhiteSpace($name)) {
                            $result.Add($name.Trim()) | Out-Null
                        }
                    }
                }
            }

            if ($result.Count -eq 0) {
                throw 'BATCH mode requires -VMNames and/or -VMListPath with VMName column.'
            }
        }
        'FROM_MANIFESTS' {
            if ([string]::IsNullOrWhiteSpace($ManifestDirectory)) {
                throw 'Manifest output directory is empty in config.'
            }
            if (-not (Test-Path -Path $ManifestDirectory)) {
                throw "Manifest directory not found: $ManifestDirectory"
            }

            $files = Get-ChildItem -Path $ManifestDirectory -Filter 'manifest-*.json' -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                if ($f.BaseName -match '^manifest-(.+)$') {
                    $result.Add($Matches[1]) | Out-Null
                }
            }

            if ($result.Count -eq 0) {
                throw "No manifest-*.json files found in $ManifestDirectory"
            }
        }
    }

    return @($result | Select-Object -Unique)
}

function Invoke-PhaseScript {
    param(
        [Parameter(Mandatory)][string]$PhaseDisplayName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    Start-PhaseBanner -Name $PhaseDisplayName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($DryRun) {
        Write-MigLog -Level INFO -Message "[DRY-RUN] Would execute: $ScriptPath"
        Write-MigLog -Level INFO -Message "[DRY-RUN] Parameters: $($Parameters | ConvertTo-Json -Compress)"
        $exitCode = 0
    }
    else {
        & $ScriptPath @Parameters
        $exitCode = $LASTEXITCODE
    }

    $sw.Stop()
    Stop-PhaseBanner -Name $PhaseDisplayName -ExitCode $exitCode

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        DurationSeconds = [double]([Math]::Round($sw.Elapsed.TotalSeconds, 2))
    }
}

function Invoke-SafeSleep {
    param([int]$Seconds)
    if ($Seconds -gt 0 -and -not $DryRun) {
        Start-Sleep -Seconds $Seconds
    }
}

function Invoke-VmPipeline {
    param(
        [Parameter(Mandatory)][string]$CurrentVM,
        [Parameter(Mandatory)]$ConfigObj,
        [Parameter(Mandatory)][string]$PreScript,
        [Parameter(Mandatory)][string]$ExecScript,
        [Parameter(Mandatory)][string]$PostScript,
        [Parameter(Mandatory)][string]$RollbackScript
    )

    $manifestPathLocal = Join-Path -Path ([string]$ConfigObj.output_dir) -ChildPath ("manifest-$CurrentVM.json")
    $vmSummary = [ordered]@{
        vm_name = $CurrentVM
        manifest_path = $manifestPathLocal
        started_at = (Get-Date).ToString('o')
        completed_at = ''
        phases = [ordered]@{
            pre = (New-PhaseState)
            exec = (New-PhaseState)
            post = (New-PhaseState)
            rollback = (New-PhaseState)
        }
        overall_result = 'FAILED'
        final_exit_code = 1
        notes = @()
    }

    if ($DryRun) {
        $vmSummary.notes += 'Dry-run mode active.'
    }

    if ($Phase -in @('PRE', 'FULL')) {
        $preParams = @{
            VMName = $CurrentVM
            vCenterServer = [string]$ConfigObj.vcenter_host
            vCenterUser = [string]$ConfigObj.vcenter_user
            OutputDir = [string]$ConfigObj.output_dir
            Force = $true
        }

        $preResult = Invoke-PhaseScript -PhaseDisplayName "PHASE-PRE:$CurrentVM" -ScriptPath $PreScript -Parameters $preParams
        $vmSummary.phases.pre.duration_s = $preResult.DurationSeconds
        $vmSummary.phases.pre.exit_code = $preResult.ExitCode
        $vmSummary.phases.pre.status = if ($preResult.ExitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }

        if ($preResult.ExitCode -ne 0) {
            $vmSummary.overall_result = 'FAILED'
            $vmSummary.final_exit_code = $preResult.ExitCode
            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }

        if ($Phase -eq 'PRE') {
            $vmSummary.overall_result = 'SUCCESS'
            $vmSummary.final_exit_code = 0
            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }
    }

    if ($Phase -in @('EXEC', 'FULL')) {
        $maxRetry = if ($MaxExecRetries -lt 1) { 1 } else { $MaxExecRetries }
        $attempt = 0
        $execExit = 1
        $execDuration = 0.0

        do {
            $attempt++
            $execParams = @{
                VMName = $CurrentVM
                ManifestPath = $manifestPathLocal
                HyperVHost = [string]$ConfigObj.hyperv_host
                VMStoragePath = [string]$ConfigObj.hyperv_vm_path
                VHDXPath = [string]$ConfigObj.hyperv_vhdx_path
                SwitchName = [string]$ConfigObj.hyperv_switch
                ConversionTool = if ($ConversionTool) { $ConversionTool } else { [string]$ConfigObj.conversion_tool }
                StartVMAfterMigration = $StartVMAfterMigration
            }

            $execResult = Invoke-PhaseScript -PhaseDisplayName "PHASE-EXEC:$CurrentVM" -ScriptPath $ExecScript -Parameters $execParams
            $execExit = $execResult.ExitCode
            $execDuration += $execResult.DurationSeconds

            if ($execExit -ne 0 -and $attempt -lt $maxRetry) {
                Write-MigLog -Level WARN -Message "EXEC failed for $CurrentVM (attempt $attempt/$maxRetry). Retry in $RetryWaitSeconds second(s)."
                Invoke-SafeSleep -Seconds $RetryWaitSeconds
            }
        }
        while ($execExit -ne 0 -and $attempt -lt $maxRetry)

        $vmSummary.phases.exec.duration_s = [Math]::Round($execDuration, 2)
        $vmSummary.phases.exec.exit_code = $execExit
        $vmSummary.phases.exec.retries = [Math]::Max($attempt - 1, 0)
        $vmSummary.phases.exec.status = if ($execExit -eq 0) { 'SUCCESS' } else { 'FAILED' }

        if ($execExit -ne 0) {
            if ($AutoRollback -and $Phase -eq 'FULL') {
                $env:ROLLBACK_TRIGGER = 'auto-exec-fail'
                $rbParams = @{
                    VMName = $CurrentVM
                    ManifestPath = $manifestPathLocal
                    HyperVHost = [string]$ConfigObj.hyperv_host
                    Force = $true
                    RestoreSourceVM = $RestoreSourceOnFail
                }
                $rbResult = Invoke-PhaseScript -PhaseDisplayName "PHASE-ROLLBACK:$CurrentVM" -ScriptPath $RollbackScript -Parameters $rbParams
                $vmSummary.phases.rollback.duration_s = $rbResult.DurationSeconds
                $vmSummary.phases.rollback.exit_code = $rbResult.ExitCode
                $vmSummary.phases.rollback.status = if ($rbResult.ExitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }
                $vmSummary.overall_result = 'ROLLED_BACK'
                $vmSummary.final_exit_code = 2
            }
            else {
                $vmSummary.overall_result = 'FAILED'
                $vmSummary.final_exit_code = $execExit
            }

            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }

        if ($Phase -eq 'EXEC') {
            $vmSummary.overall_result = 'SUCCESS'
            $vmSummary.final_exit_code = 0
            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }
    }

    if ($Phase -in @('POST', 'FULL')) {
        $postParams = @{
            VMName = $CurrentVM
            ManifestPath = $manifestPathLocal
            HyperVHost = [string]$ConfigObj.hyperv_host
            CriticalServices = @($ConfigObj.critical_services)
            ReportDir = [string]$ConfigObj.report_dir
        }

        $postResult = Invoke-PhaseScript -PhaseDisplayName "PHASE-POST:$CurrentVM" -ScriptPath $PostScript -Parameters $postParams
        $vmSummary.phases.post.duration_s = $postResult.DurationSeconds
        $vmSummary.phases.post.exit_code = $postResult.ExitCode
        $vmSummary.phases.post.status = if ($postResult.ExitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }

        if ($postResult.ExitCode -eq 0) {
            $vmSummary.overall_result = 'SUCCESS'
            $vmSummary.final_exit_code = 0
            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }

        if ($postResult.ExitCode -eq 3) {
            $vmSummary.overall_result = 'PARTIAL'
            $vmSummary.final_exit_code = 3
            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }

        if (($postResult.ExitCode -eq 2) -and $AutoRollback -and ($Phase -eq 'FULL')) {
            $env:ROLLBACK_TRIGGER = 'auto-post-fail'
            $rbParams = @{
                VMName = $CurrentVM
                ManifestPath = $manifestPathLocal
                HyperVHost = [string]$ConfigObj.hyperv_host
                Force = $true
                RestoreSourceVM = $RestoreSourceOnFail
            }
            $rbResult = Invoke-PhaseScript -PhaseDisplayName "PHASE-ROLLBACK:$CurrentVM" -ScriptPath $RollbackScript -Parameters $rbParams
            $vmSummary.phases.rollback.duration_s = $rbResult.DurationSeconds
            $vmSummary.phases.rollback.exit_code = $rbResult.ExitCode
            $vmSummary.phases.rollback.status = if ($rbResult.ExitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }
            $vmSummary.overall_result = 'ROLLED_BACK'
            $vmSummary.final_exit_code = 2
            $vmSummary.completed_at = (Get-Date).ToString('o')
            return $vmSummary
        }

        $vmSummary.overall_result = 'FAILED'
        $vmSummary.final_exit_code = 2
        $vmSummary.completed_at = (Get-Date).ToString('o')
        return $vmSummary
    }

    if ($Phase -eq 'ROLLBACK') {
        $env:ROLLBACK_TRIGGER = 'manual'
        $rbParams = @{
            VMName = $CurrentVM
            ManifestPath = $manifestPathLocal
            HyperVHost = [string]$ConfigObj.hyperv_host
            Force = $true
            RestoreSourceVM = $RestoreSourceOnFail
        }
        $rbResult = Invoke-PhaseScript -PhaseDisplayName "PHASE-ROLLBACK:$CurrentVM" -ScriptPath $RollbackScript -Parameters $rbParams
        $vmSummary.phases.rollback.duration_s = $rbResult.DurationSeconds
        $vmSummary.phases.rollback.exit_code = $rbResult.ExitCode
        $vmSummary.phases.rollback.status = if ($rbResult.ExitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }
        $vmSummary.overall_result = if ($rbResult.ExitCode -eq 0) { 'ROLLED_BACK' } else { 'FAILED' }
        $vmSummary.final_exit_code = $rbResult.ExitCode
        $vmSummary.completed_at = (Get-Date).ToString('o')
        return $vmSummary
    }

    $vmSummary.overall_result = 'FAILED'
    $vmSummary.final_exit_code = 1
    $vmSummary.completed_at = (Get-Date).ToString('o')
    return $vmSummary
}

$globalSW = [System.Diagnostics.Stopwatch]::StartNew()
$pipelineId = [guid]::NewGuid().Guid
$startedAt = Get-Date
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcriptStarted = $false
$config = $null

$summary = [ordered]@{
    pipeline_id = $pipelineId
    mode = $Mode
    phase = $Phase
    started_at = $startedAt.ToString('o')
    completed_at = ''
    total_duration_minutes = 0
    vm_total = 0
    vm_done = 0
    vm_failed = 0
    vm_partial = 0
    vm_rolled_back = 0
    vms = @()
    overall_result = 'FAILED'
    config_file = $ConfigFile
    summary_generated_at = ''
}

try {
    if (-not (Test-Path -Path $ConfigFile)) {
        Write-MigLog -Level FATAL -Message "Config file not found: $ConfigFile"
        exit 1
    }

    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    $logDir = [string]$config.log_dir
    if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = 'C:\Migration\Logs' }
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $logFile = Join-Path -Path $logDir -ChildPath ("migration-orchestrator-{0}.log" -f $timestamp)
    if (-not $DryRun) {
        Start-Transcript -Path $logFile -Force | Out-Null
        $transcriptStarted = $true
    }

    if (-not $SkipPrereqChecks) {
        $requiredModules = @('VMware.PowerCLI', 'Hyper-V')
        foreach ($m in $requiredModules) {
            if (-not (Get-Module -ListAvailable -Name $m)) {
                Write-MigLog -Level FATAL -Message "Required module missing: $m"
                exit 1
            }
        }

        if (-not $env:VCENTER_HOST -or -not $env:HYPERV_HOST) {
            Write-MigLog -Level FATAL -Message 'Critical environment variables are missing (VCENTER_HOST and/or HYPERV_HOST).'
            exit 1
        }
    }

    foreach ($dirCandidate in @($config.output_dir, $config.report_dir, $config.log_dir)) {
        if (-not [string]::IsNullOrWhiteSpace($dirCandidate)) {
            if (-not (Test-Path -Path $dirCandidate)) {
                New-Item -Path $dirCandidate -ItemType Directory -Force | Out-Null
            }
        }
    }

    $preScript = Join-Path -Path $PSScriptRoot -ChildPath '01-PRE-Discovery.ps1'
    $execScript = Join-Path -Path $PSScriptRoot -ChildPath '02-EXEC-Migration.ps1'
    $postScript = Join-Path -Path $PSScriptRoot -ChildPath '03-POST-Validation.ps1'
    $rollbackScript = Join-Path -Path $PSScriptRoot -ChildPath '04-ROLLBACK.ps1'

    foreach ($scriptPath in @($preScript, $execScript, $postScript, $rollbackScript)) {
        if (-not (Test-Path -Path $scriptPath)) {
            Write-MigLog -Level FATAL -Message "Required child script not found: $scriptPath"
            exit 1
        }
    }

    $targetVms = Resolve-TargetVMs -ResolvedMode $Mode -SingleVmName $VMName -CsvPath $VMListPath -ArrayVmNames $VMNames -ManifestDirectory ([string]$config.output_dir)
    $summary.vm_total = $targetVms.Count

    Write-MigLog -Level INFO -Message "Execution mode: $Mode | Target VMs: $($targetVms.Count) | Phase: $Phase"

    if ($DryRun) {
        Write-MigLog -Level INFO -Message "Dry-run VM list: $($targetVms -join ', ')"
    }

    $vmResults = New-Object System.Collections.Generic.List[object]

    foreach ($current in $targetVms) {
        Write-MigLog -Level INFO -Message "Starting VM pipeline: $current"

        $oneResult = Invoke-VmPipeline -CurrentVM $current -ConfigObj $config -PreScript $preScript -ExecScript $execScript -PostScript $postScript -RollbackScript $rollbackScript
        $vmResults.Add($oneResult) | Out-Null

        switch ([string]$oneResult.overall_result) {
            'SUCCESS' { $summary.vm_done++ }
            'PARTIAL' { $summary.vm_partial++ }
            'ROLLED_BACK' { $summary.vm_rolled_back++; $summary.vm_failed++ }
            default { $summary.vm_failed++ }
        }

        if (([string]$oneResult.overall_result -in @('FAILED', 'ROLLED_BACK')) -and (-not $ContinueOnError) -and ($targetVms.Count -gt 1)) {
            Write-MigLog -Level WARN -Message "Stopping batch after failure on VM '$current' because ContinueOnError is disabled."
            break
        }
    }

    $summary.vms = @($vmResults)

    if ($summary.vm_failed -gt 0) {
        if ($summary.vm_rolled_back -gt 0 -and $summary.vm_done -eq 0 -and $summary.vm_partial -eq 0) {
            $summary.overall_result = 'ROLLED_BACK'
            $finalExit = 2
        }
        else {
            $summary.overall_result = 'FAILED'
            $finalExit = 2
        }
    }
    elseif ($summary.vm_partial -gt 0) {
        $summary.overall_result = 'PARTIAL'
        $finalExit = 3
    }
    else {
        $summary.overall_result = 'SUCCESS'
        $finalExit = 0
    }

    exit $finalExit
}
catch {
    Write-MigLog -Level ERROR -Message "Unexpected orchestrator error: $($_.Exception.Message)"
    Write-MigLog -Level ERROR -Message "$($_.ScriptStackTrace)"
    $summary.overall_result = 'FAILED'
    exit 1
}
finally {
    $globalSW.Stop()
    $summary.completed_at = (Get-Date).ToString('o')
    $summary.total_duration_minutes = [Math]::Round($globalSW.Elapsed.TotalMinutes, 2)
    $summary.summary_generated_at = (Get-Date).ToString('o')

    try {
        $summaryDir = if ($config -and $config.report_dir) { [string]$config.report_dir } else { 'C:\Migration\Reports' }
        if (-not (Test-Path -Path $summaryDir)) {
            New-Item -Path $summaryDir -ItemType Directory -Force | Out-Null
        }

        $summaryPath = Join-Path -Path $summaryDir -ChildPath ("pipeline-summary-{0}.json" -f $timestamp)
        $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryPath -Encoding UTF8
        Write-MigLog -Level INFO -Message "Pipeline summary generated: $summaryPath"
    }
    catch {
        Write-MigLog -Level WARN -Message "Could not write pipeline summary: $($_.Exception.Message)"
    }

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
