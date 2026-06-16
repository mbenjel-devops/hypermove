<#
.SYNOPSIS
Runs the toolkit test suite locally (syntax validation + Pester).

.DESCRIPTION
Convenience wrapper for developers and technicians. Requires Pester 5.5+.

.EXAMPLE
.\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tests')
)

Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Output 'Step 1/2: Syntax validation...'
$files = Get-ChildItem -Path (Join-Path $repoRoot 'src'), (Join-Path $repoRoot 'tests') -Include '*.ps1', '*.psm1' -Recurse -File
$hadError = $false
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $hadError = $true
        Write-Output ("  FAIL: {0}" -f $f.Name)
        $errors | ForEach-Object { Write-Output ("    {0} (line {1})" -f $_.Message, $_.Extent.StartLineNumber) }
    }
}
if ($hadError) {
    Write-Output 'Syntax errors found. Aborting.'
    exit 1
}
Write-Output '  All scripts parse cleanly.'

Write-Output 'Step 2/2: Pester tests...'
$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5.0' } | Select-Object -First 1
if (-not $pester) {
    Write-Output '  Pester 5.5+ not found. Install with: Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck'
    exit 2
}

Import-Module Pester -MinimumVersion 5.5.0 -Force
$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
