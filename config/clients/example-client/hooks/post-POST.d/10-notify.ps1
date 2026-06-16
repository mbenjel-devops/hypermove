<#
.SYNOPSIS
Example post-POST hook: notify an external system after successful validation.

.DESCRIPTION
Hook contract:
- Receives the migration context as a JSON file via -ContextPath (and the
  MIG_HOOK_CONTEXT_PATH environment variable).
- post-* hooks are NON-BLOCKING: a non-zero exit is logged as a warning only.

This sample writes a notification payload to disk. Replace the body with a real
integration (webhook, e-mail, ITSM transition, monitoring un-mute, etc.).
#>
[CmdletBinding()]
param(
    [string]$ContextPath = $env:MIG_HOOK_CONTEXT_PATH
)

Set-StrictMode -Version 2.0

function Write-HookLog {
    param([string]$Level = 'INFO', [string]$Message)
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][HOOK:post-POST] $Message"
}

$context = $null
if ($ContextPath -and (Test-Path -Path $ContextPath)) {
    try { $context = Get-Content -Path $ContextPath -Raw | ConvertFrom-Json } catch { }
}

$vmName = if ($context) { [string]$context.vm_name } else { '<unknown>' }
$client = if ($context) { [string]$context.client } else { '<unknown>' }

$payload = [ordered]@{
    event = 'migration.post.validated'
    client = $client
    vm = $vmName
    at = (Get-Date).ToString('o')
}

# --- Replace this block with a real notification ---------------------------
Write-HookLog -Message ("Notification payload: {0}" -f ($payload | ConvertTo-Json -Compress))
# ---------------------------------------------------------------------------

exit 0
