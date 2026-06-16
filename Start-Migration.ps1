<#
.SYNOPSIS
Interactive launcher for the VMware to Hyper-V migration toolkit.

.DESCRIPTION
Guided menu for technicians. Wraps the pre-flight check and the orchestrator so a
migration can be run without memorizing parameters. Designed to be the single entry
point on a migration workstation.

.PARAMETER ConfigFile
Path to the migration JSON config. Defaults to .\config.json next to this script,
falling back to C:\Migration\config.json.

.PARAMETER NonInteractive
Guard for automation: refuses to launch the menu (which requires a console).

.EXAMPLE
.\Start-Migration.ps1

.EXAMPLE
.\Start-Migration.ps1 -ConfigFile "C:\Migration\config.json"

.NOTES
Version: 1.0.0
Author: GitHub Copilot
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0

$ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$SrcDir = Join-Path -Path $ScriptRoot -ChildPath 'src'
$OrchestratorPath = Join-Path -Path $SrcDir -ChildPath '00-Orchestrator.ps1'
$PreflightPath = Join-Path -Path $SrcDir -ChildPath '00-Preflight.ps1'
$PrePath = Join-Path -Path $SrcDir -ChildPath '01-PRE-Discovery.ps1'

function Write-Banner {
    Write-Output ''
    Write-Output '=============================================================='
    Write-Output '  VMware -> Hyper-V Migration Toolkit'
    Write-Output ('  Config : {0}' -f $ConfigFile)
    Write-Output '=============================================================='
}

function Resolve-ConfigFile {
    param([string]$Provided)
    if (-not [string]::IsNullOrWhiteSpace($Provided)) { return $Provided }
    $local = Join-Path -Path $ScriptRoot -ChildPath 'config.json'
    if (Test-Path -Path $local) { return $local }
    return 'C:\Migration\config.json'
}

function Read-NonEmpty {
    param([string]$Prompt)
    while ($true) {
        $value = Read-Host -Prompt $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Output '  Value required. Please try again.'
    }
}

function Confirm-Action {
    param([string]$Prompt)
    $answer = Read-Host -Prompt ("{0} [y/N]" -f $Prompt)
    return ($answer -match '^(y|yes|o|oui)$')
}

function Invoke-Child {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Arguments
    )
    if (-not (Test-Path -Path $Path)) {
        Write-Output ("  ERROR: Script not found: {0}" -f $Path)
        return 1
    }
    & $Path @Arguments
    return $LASTEXITCODE
}

if ($NonInteractive) {
    Write-Output 'Start-Migration is interactive and cannot run with -NonInteractive. Use src\00-Orchestrator.ps1 directly.'
    exit 1
}

$ConfigFile = Resolve-ConfigFile -Provided $ConfigFile

$exitMenu = $false
while (-not $exitMenu) {
    Write-Banner
    Write-Output '  1) Pre-flight readiness check (run this first)'
    Write-Output '  2) Discovery only (PRE) for a single VM'
    Write-Output '  3) Full migration (PRE+EXEC+POST) for a single VM'
    Write-Output '  4) Batch migration (FULL) from a CSV list'
    Write-Output '  5) Post-validation (POST) from existing manifests'
    Write-Output '  6) Rollback / cleanup a single VM'
    Write-Output '  7) Change config file path'
    Write-Output '  0) Quit'
    Write-Output ''
    $choice = Read-Host -Prompt 'Select an option'

    switch ($choice) {
        '1' {
            $testConn = Confirm-Action -Prompt 'Also test network connectivity to vCenter/Hyper-V?'
            $childArgs = @{ ConfigFile = $ConfigFile }
            if ($testConn) { $childArgs['TestConnections'] = $true }
            $rc = Invoke-Child -Path $PreflightPath -Arguments $childArgs
            Write-Output ("  Pre-flight exit code: {0}" -f $rc)
        }
        '2' {
            $vm = Read-NonEmpty -Prompt 'VM name'
            $childArgs = @{ VMName = $vm }
            if (Confirm-Action -Prompt 'Consolidate (remove) existing snapshots before discovery?') { $childArgs['RemoveSnapshots'] = $true }
            if (Confirm-Action -Prompt 'Approve legacy OS (2000/2003/2008/2008 R2) if detected?') { $childArgs['ApproveLegacyOS'] = $true }
            if (Confirm-Action -Prompt 'Overwrite an existing manifest (-Force)?') { $childArgs['Force'] = $true }
            $rc = Invoke-Child -Path $PrePath -Arguments $childArgs
            Write-Output ("  PRE exit code: {0}" -f $rc)
        }
        '3' {
            $vm = Read-NonEmpty -Prompt 'VM name'
            $childArgs = @{ VMName = $vm; ConfigFile = $ConfigFile; Mode = 'SINGLE'; Phase = 'FULL' }
            if (Confirm-Action -Prompt 'Run pre-flight readiness check first?') { $childArgs['RunPreflight'] = $true }
            if (Confirm-Action -Prompt 'Enable auto-rollback on critical failure?') { $childArgs['AutoRollback'] = $true }
            if (Confirm-Action -Prompt 'Start the VM after migration?') { $childArgs['StartVMAfterMigration'] = $true }
            if (Confirm-Action -Prompt 'Dry-run (simulate, no changes)?') { $childArgs['DryRun'] = $true }
            $rc = Invoke-Child -Path $OrchestratorPath -Arguments $childArgs
            Write-Output ("  Pipeline exit code: {0}" -f $rc)
        }
        '4' {
            $csv = Read-NonEmpty -Prompt 'Path to CSV list (column: VMName)'
            $childArgs = @{ ConfigFile = $ConfigFile; Mode = 'BATCH'; Phase = 'FULL'; VMListPath = $csv }
            if (Confirm-Action -Prompt 'Run pre-flight readiness check first?') { $childArgs['RunPreflight'] = $true }
            if (Confirm-Action -Prompt 'Continue with next VM if one fails?') { $childArgs['ContinueOnError'] = $true }
            if (Confirm-Action -Prompt 'Enable auto-rollback on critical failure?') { $childArgs['AutoRollback'] = $true }
            if (Confirm-Action -Prompt 'Dry-run (simulate, no changes)?') { $childArgs['DryRun'] = $true }
            $rc = Invoke-Child -Path $OrchestratorPath -Arguments $childArgs
            Write-Output ("  Batch exit code: {0}" -f $rc)
        }
        '5' {
            $childArgs = @{ ConfigFile = $ConfigFile; Mode = 'FROM_MANIFESTS'; Phase = 'POST' }
            $rc = Invoke-Child -Path $OrchestratorPath -Arguments $childArgs
            Write-Output ("  POST exit code: {0}" -f $rc)
        }
        '6' {
            $vm = Read-NonEmpty -Prompt 'VM name to rollback'
            if (Confirm-Action -Prompt ("Confirm rollback/cleanup for '{0}'?" -f $vm)) {
                $childArgs = @{ VMName = $vm; ConfigFile = $ConfigFile; Mode = 'SINGLE'; Phase = 'ROLLBACK' }
                if (Confirm-Action -Prompt 'Restore/power-on the source VM?') { $childArgs['RestoreSourceOnFail'] = $true }
                $rc = Invoke-Child -Path $OrchestratorPath -Arguments $childArgs
                Write-Output ("  Rollback exit code: {0}" -f $rc)
            }
            else {
                Write-Output '  Rollback cancelled.'
            }
        }
        '7' {
            $ConfigFile = Read-NonEmpty -Prompt 'New config file path'
        }
        '0' {
            $exitMenu = $true
        }
        default {
            Write-Output '  Invalid option. Please choose a number from the menu.'
        }
    }

    if (-not $exitMenu) {
        Write-Output ''
        [void](Read-Host -Prompt 'Press Enter to return to the menu')
    }
}

Write-Output 'Goodbye.'
exit 0
