<#
.SYNOPSIS
Example pre-EXEC hook: validate a backup exists before conversion starts.

.DESCRIPTION
Hook contract:
- Receives the migration context as a JSON file via -ContextPath (and the
  MIG_HOOK_CONTEXT_PATH environment variable).
- Exit code 0 = success/continue. For pre-* hooks, a non-zero exit BLOCKS the phase.

This sample only reads the context and demonstrates a gate. Replace the body with a
real check (backup API call, CMDB lookup, change-window validation, etc.).
#>
[CmdletBinding()]
param(
    [string]$ContextPath = $env:MIG_HOOK_CONTEXT_PATH
)

Set-StrictMode -Version 2.0

function Write-HookLog {
    param([string]$Level = 'INFO', [string]$Message)
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][HOOK:pre-EXEC] $Message"
}

$context = $null
if ($ContextPath -and (Test-Path -Path $ContextPath)) {
    try { $context = Get-Content -Path $ContextPath -Raw | ConvertFrom-Json } catch { }
}

$vmName = if ($context) { [string]$context.vm_name } else { '<unknown>' }
Write-HookLog -Message "Validating backup precondition for VM '$vmName'."

# --- Replace this block with a real verification ----------------------------
$backupVerified = $true
# ---------------------------------------------------------------------------

if (-not $backupVerified) {
    Write-HookLog -Level 'ERROR' -Message "No recent backup found for '$vmName'. Blocking migration."
    exit 1
}

Write-HookLog -Message "Backup precondition satisfied for '$vmName'."
exit 0
