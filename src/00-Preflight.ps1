<#
.SYNOPSIS
Pre-flight readiness check (doctor) for the VMware to Hyper-V migration toolkit.

.DESCRIPTION
Validates the technician workstation / migration worker before any migration runs.
Checks PowerShell version, required modules, environment variables, configuration file,
output directories writability, conversion tool availability, and optional network
connectivity to vCenter and Hyper-V. Produces a human-readable summary and a JSON report.

Run this FIRST on any new machine. It is read-only and safe.

.PARAMETER ConfigFile
Path to the migration JSON config.

.PARAMETER TestConnections
Also perform network connectivity tests (ping) to vCenter and Hyper-V hosts.

.PARAMETER ReportDir
Directory for the readiness JSON report. Defaults to config.report_dir or C:\Migration\Reports.

.EXAMPLE
.\00-Preflight.ps1 -ConfigFile "C:\Migration\config.json"

.EXAMPLE
.\00-Preflight.ps1 -ConfigFile "C:\Migration\config.json" -TestConnections

.NOTES
Version: 1.0.0
Author: GitHub Copilot
Exit codes:
  0 = READY (no blocking issue)
  2 = BLOCKED (at least one blocking issue)
  3 = WARNING only (no blocker, advisories present)
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = "C:\Migration\config.json",
    [switch]$TestConnections,
    [string]$ReportDir
)

Set-StrictMode -Version 2.0
$script:PhaseName = 'PREFLIGHT'
$script:checks = New-Object System.Collections.Generic.List[object]

function Write-MigLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][$script:PhaseName] $Message"
}

function Add-PreflightCheck {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Detail,
        [string]$Remediation = ''
    )
    $script:checks.Add([ordered]@{
        id = $Id
        name = $Name
        status = $Status
        detail = $Detail
        remediation = $Remediation
    }) | Out-Null
}

$config = $null

#region PS-VERSION
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -ge 7) {
    Add-PreflightCheck -Id 'PF_01' -Name 'PowerShell version' -Status 'PASS' -Detail "PowerShell $psVersion"
}
elseif ($psVersion.Major -eq 5 -and $psVersion.Minor -ge 1) {
    Add-PreflightCheck -Id 'PF_01' -Name 'PowerShell version' -Status 'WARN' -Detail "PowerShell $psVersion (5.1 supported, 7.2+ recommended)" -Remediation 'Install PowerShell 7: winget install Microsoft.PowerShell'
}
else {
    Add-PreflightCheck -Id 'PF_01' -Name 'PowerShell version' -Status 'FAIL' -Detail "Unsupported PowerShell $psVersion" -Remediation 'Install PowerShell 7.2+: winget install Microsoft.PowerShell'
}
#endregion

#region MODULES
$moduleMatrix = @(
    @{ Name = 'VMware.PowerCLI'; Blocking = $true; Hint = 'Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force' },
    @{ Name = 'Hyper-V'; Blocking = $true; Hint = 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell' },
    @{ Name = 'Pester'; Blocking = $false; Hint = 'Install-Module -Name Pester -Force -SkipPublisherCheck' }
)

$mIndex = 1
foreach ($m in $moduleMatrix) {
    $id = "PF_1$mIndex"
    $available = Get-Module -ListAvailable -Name $m.Name -ErrorAction SilentlyContinue
    if ($available) {
        $ver = ($available | Sort-Object Version -Descending | Select-Object -First 1).Version
        Add-PreflightCheck -Id $id -Name "Module $($m.Name)" -Status 'PASS' -Detail "Found version $ver"
    }
    elseif ($m.Blocking) {
        Add-PreflightCheck -Id $id -Name "Module $($m.Name)" -Status 'FAIL' -Detail 'Module not installed' -Remediation $m.Hint
    }
    else {
        Add-PreflightCheck -Id $id -Name "Module $($m.Name)" -Status 'WARN' -Detail 'Optional module not installed' -Remediation $m.Hint
    }
    $mIndex++
}
#endregion

#region ENV-VARS
$envMatrix = @(
    @{ Name = 'VCENTER_HOST'; Blocking = $true },
    @{ Name = 'VCENTER_USER'; Blocking = $false },
    @{ Name = 'VCENTER_PASS'; Blocking = $false },
    @{ Name = 'HYPERV_HOST'; Blocking = $true }
)

$eIndex = 1
foreach ($e in $envMatrix) {
    $id = "PF_2$eIndex"
    $val = [Environment]::GetEnvironmentVariable($e.Name)
    if (-not [string]::IsNullOrWhiteSpace($val)) {
        $display = if ($e.Name -eq 'VCENTER_PASS') { '*** (set)' } else { $val }
        Add-PreflightCheck -Id $id -Name "Env $($e.Name)" -Status 'PASS' -Detail $display
    }
    elseif ($e.Blocking) {
        Add-PreflightCheck -Id $id -Name "Env $($e.Name)" -Status 'FAIL' -Detail 'Not set' -Remediation "Set environment variable $($e.Name) (see .env.example)"
    }
    else {
        Add-PreflightCheck -Id $id -Name "Env $($e.Name)" -Status 'WARN' -Detail 'Not set (credential prompt will be used)' -Remediation "Optionally set $($e.Name)"
    }
    $eIndex++
}
#endregion

#region CONFIG
if (-not (Test-Path -Path $ConfigFile)) {
    Add-PreflightCheck -Id 'PF_30' -Name 'Config file' -Status 'FAIL' -Detail "Not found: $ConfigFile" -Remediation 'Copy config.example.json to the config path and edit values.'
}
else {
    try {
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        Add-PreflightCheck -Id 'PF_30' -Name 'Config file' -Status 'PASS' -Detail "Parsed: $ConfigFile"

        $requiredKeys = @('vcenter_host', 'hyperv_host', 'hyperv_vm_path', 'hyperv_vhdx_path', 'hyperv_switch', 'output_dir', 'report_dir', 'log_dir', 'conversion_tool')
        $missing = @()
        foreach ($k in $requiredKeys) {
            $hasKey = $config.PSObject.Properties.Name -contains $k
            if (-not $hasKey -or [string]::IsNullOrWhiteSpace([string]$config.$k)) {
                $missing += $k
            }
        }

        if ($missing.Count -gt 0) {
            Add-PreflightCheck -Id 'PF_31' -Name 'Config completeness' -Status 'FAIL' -Detail "Missing/empty keys: $($missing -join ', ')" -Remediation 'Fill all required keys in the config file (see config.example.json).'
        }
        else {
            Add-PreflightCheck -Id 'PF_31' -Name 'Config completeness' -Status 'PASS' -Detail 'All required keys present.'
        }
    }
    catch {
        Add-PreflightCheck -Id 'PF_30' -Name 'Config file' -Status 'FAIL' -Detail "Invalid JSON: $($_.Exception.Message)" -Remediation 'Fix JSON syntax. Validate with a JSON linter.'
    }
}
#endregion

#region DIRECTORIES
if ($config) {
    $dirKeys = @('output_dir', 'report_dir', 'log_dir', 'hyperv_vm_path', 'hyperv_vhdx_path')
    $dIndex = 1
    foreach ($dk in $dirKeys) {
        $id = "PF_4$dIndex"
        $path = [string]$config.$dk
        if ([string]::IsNullOrWhiteSpace($path)) {
            Add-PreflightCheck -Id $id -Name "Dir $dk" -Status 'WARN' -Detail 'Not configured' -Remediation "Set $dk in config."
            $dIndex++
            continue
        }

        try {
            if (-not (Test-Path -Path $path)) {
                New-Item -Path $path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $probe = Join-Path -Path $path -ChildPath (".preflight-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
            Set-Content -Path $probe -Value 'ok' -ErrorAction Stop
            Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
            Add-PreflightCheck -Id $id -Name "Dir $dk" -Status 'PASS' -Detail "Writable: $path"
        }
        catch {
            Add-PreflightCheck -Id $id -Name "Dir $dk" -Status 'FAIL' -Detail "Not writable: $path ($($_.Exception.Message))" -Remediation 'Grant write permission or change the configured path.'
        }
        $dIndex++
    }
}
#endregion

#region CONVERSION-TOOL
if ($config) {
    $tool = [string]$config.conversion_tool
    switch ($tool) {
        'StarWindV2V' {
            $candidates = @(
                'StarWindV2VConverter.exe',
                'C:\Program Files\StarWind Software\StarWind V2V Converter\StarWindV2VConverter.exe',
                'C:\Program Files\StarWind\StarWind V2V Converter\StarWindV2VConverter.exe'
            )
            $found = $null
            foreach ($c in $candidates) {
                if (Get-Command -Name $c -ErrorAction SilentlyContinue) { $found = $c; break }
                if (Test-Path -Path $c) { $found = $c; break }
            }
            if ($found) {
                Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'PASS' -Detail "StarWind found: $found"
            }
            else {
                Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'FAIL' -Detail 'StarWind V2V Converter not found' -Remediation 'Install StarWind V2V Converter, or set conversion_tool to MVMC/QemuImg.'
            }
        }
        'MVMC' {
            if (Get-Command -Name ConvertTo-MvmcVirtualHardDisk -ErrorAction SilentlyContinue) {
                Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'PASS' -Detail 'MVMC cmdlet available.'
            }
            else {
                Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'FAIL' -Detail 'ConvertTo-MvmcVirtualHardDisk not available' -Remediation 'Install Microsoft Virtual Machine Converter, or use another tool.'
            }
        }
        'QemuImg' {
            if (Get-Command -Name 'qemu-img.exe' -ErrorAction SilentlyContinue) {
                Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'PASS' -Detail 'qemu-img available in PATH.'
            }
            else {
                Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'FAIL' -Detail 'qemu-img.exe not in PATH' -Remediation 'Install qemu-img and add to PATH, or use another tool.'
            }
        }
        default {
            Add-PreflightCheck -Id 'PF_50' -Name 'Conversion tool' -Status 'WARN' -Detail "Unknown conversion_tool: $tool" -Remediation 'Set conversion_tool to StarWindV2V, MVMC, or QemuImg.'
        }
    }
}
#endregion

#region CONNECTIVITY
if ($TestConnections -and $config) {
    $hosts = @(
        @{ Label = 'vCenter'; Value = [string]$config.vcenter_host },
        @{ Label = 'Hyper-V'; Value = [string]$config.hyperv_host }
    )
    $cIndex = 1
    foreach ($h in $hosts) {
        $id = "PF_6$cIndex"
        if ([string]::IsNullOrWhiteSpace($h.Value)) {
            Add-PreflightCheck -Id $id -Name "Connectivity $($h.Label)" -Status 'WARN' -Detail 'Host not configured.'
            $cIndex++
            continue
        }
        try {
            $ok = Test-Connection -ComputerName $h.Value -Count 2 -Quiet -ErrorAction SilentlyContinue
            if ($ok) {
                Add-PreflightCheck -Id $id -Name "Connectivity $($h.Label)" -Status 'PASS' -Detail "Reachable: $($h.Value)"
            }
            else {
                Add-PreflightCheck -Id $id -Name "Connectivity $($h.Label)" -Status 'WARN' -Detail "No ICMP reply: $($h.Value)" -Remediation 'ICMP may be blocked; verify name resolution and firewall.'
            }
        }
        catch {
            Add-PreflightCheck -Id $id -Name "Connectivity $($h.Label)" -Status 'WARN' -Detail "Test failed: $($_.Exception.Message)"
        }
        $cIndex++
    }
}
#endregion

# Resolve report dir
if ([string]::IsNullOrWhiteSpace($ReportDir)) {
    if ($config -and $config.report_dir) { $ReportDir = [string]$config.report_dir }
    else { $ReportDir = 'C:\Migration\Reports' }
}

$failCount = @($script:checks | Where-Object { $_.status -eq 'FAIL' }).Count
$warnCount = @($script:checks | Where-Object { $_.status -eq 'WARN' }).Count
$passCount = @($script:checks | Where-Object { $_.status -eq 'PASS' }).Count

if ($failCount -gt 0) {
    $overall = 'BLOCKED'
    $exitCode = 2
}
elseif ($warnCount -gt 0) {
    $overall = 'WARNING'
    $exitCode = 3
}
else {
    $overall = 'READY'
    $exitCode = 0
}

# Console summary
Write-Output ''
Write-Output '=============================================================='
Write-Output ' PRE-FLIGHT READINESS CHECK'
Write-Output ('  Generated : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Output ('  Config    : {0}' -f $ConfigFile)
Write-Output '=============================================================='
foreach ($c in $script:checks) {
    Write-Output ('  [{0}] {1,-26} {2}' -f $c.status, $c.name, $c.detail)
    if ($c.status -ne 'PASS' -and -not [string]::IsNullOrWhiteSpace($c.remediation)) {
        Write-Output ('        -> Fix: {0}' -f $c.remediation)
    }
}
Write-Output '--------------------------------------------------------------'
Write-Output ('  PASS={0}  WARN={1}  FAIL={2}' -f $passCount, $warnCount, $failCount)
Write-Output ('  RESULT: {0}' -f $overall)
Write-Output '=============================================================='

# JSON report
try {
    if (-not (Test-Path -Path $ReportDir)) {
        New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
    }
    $report = [ordered]@{
        report_type = 'preflight'
        generated_at = (Get-Date).ToString('o')
        config_file = $ConfigFile
        machine = $env:COMPUTERNAME
        powershell = $psVersion.ToString()
        checks = @($script:checks)
        summary = [ordered]@{ pass = $passCount; warn = $warnCount; fail = $failCount }
        overall_status = $overall
    }
    $reportPath = Join-Path -Path $ReportDir -ChildPath ("preflight-{0}-{1}.json" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8
    Write-MigLog -Level INFO -Message "Preflight report written: $reportPath"
}
catch {
    Write-MigLog -Level WARN -Message "Could not write preflight report: $($_.Exception.Message)"
}

exit $exitCode
