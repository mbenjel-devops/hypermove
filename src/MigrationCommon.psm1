<#
.SYNOPSIS
Shared helpers for the VMware to Hyper-V migration toolkit.

.DESCRIPTION
Provides enterprise building blocks reused across the pipeline:
- Multi-client configuration profiles (defaults + per-client overrides, deep-merged).
- Secret resolution via Microsoft.PowerShell.SecretManagement (secret:// references).
- A pre/post hook framework so each client/infrastructure can plug custom scripts and
  integrate with external systems without modifying the core pipeline.

Designed for PowerShell 7.2+. No Write-Host; structured logging via Write-MigCommonLog.

.NOTES
Version: 1.0.0
Author: GitHub Copilot
#>

Set-StrictMode -Version 2.0

function Write-MigCommonLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Phase = 'COMMON'
    )
    Write-Output "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')][$Level][$Phase] $Message"
}

function ConvertTo-MigHashtableDeep {
    <#
    .SYNOPSIS
    Recursively converts a PSCustomObject (e.g. from ConvertFrom-Json) into ordered hashtables.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $copy = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $copy[$key] = ConvertTo-MigHashtableDeep -InputObject $InputObject[$key]
            }
            return $copy
        }

        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $copy = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $copy[$prop.Name] = ConvertTo-MigHashtableDeep -InputObject $prop.Value
            }
            return $copy
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($item in $InputObject) {
                $list.Add((ConvertTo-MigHashtableDeep -InputObject $item)) | Out-Null
            }
            return $list.ToArray()
        }

        return $InputObject
    }
}

function Merge-MigHashtable {
    <#
    .SYNOPSIS
    Deep-merges $Override onto $Base. Override wins. Nested hashtables merge recursively;
    arrays and scalars are replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Base,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Override
    )

    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }

    foreach ($key in $Override.Keys) {
        $overrideValue = $Override[$key]
        if ($result.Contains($key) -and
            $result[$key] -is [System.Collections.IDictionary] -and
            $overrideValue -is [System.Collections.IDictionary]) {
            $result[$key] = Merge-MigHashtable -Base $result[$key] -Override $overrideValue
        }
        else {
            $result[$key] = $overrideValue
        }
    }

    return $result
}

function Resolve-MigSecretValue {
    <#
    .SYNOPSIS
    Resolves a single value. Strings shaped 'secret://<Vault>/<Name>' are looked up via
    Microsoft.PowerShell.SecretManagement and replaced with the plaintext value.
    #>
    [CmdletBinding()]
    param([Parameter()]$Value)

    if ($Value -is [string] -and $Value -match '^secret://([^/]+)/(.+)$') {
        $vaultName = $Matches[1]
        $secretName = $Matches[2]

        if (-not (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue)) {
            Write-MigCommonLog -Level WARN -Message "SecretManagement not available; cannot resolve secret '$secretName' from vault '$vaultName'. Leaving reference unresolved."
            return $Value
        }

        try {
            $secret = Get-Secret -Name $secretName -Vault $vaultName -AsPlainText -ErrorAction Stop
            Write-MigCommonLog -Level INFO -Message "Resolved secret '$secretName' from vault '$vaultName'."
            return $secret
        }
        catch {
            Write-MigCommonLog -Level ERROR -Message "Failed to resolve secret '$secretName' from vault '$vaultName': $($_.Exception.Message)"
            throw
        }
    }

    return $Value
}

function Resolve-MigSecretsInTree {
    <#
    .SYNOPSIS
    Walks a hashtable/array tree and resolves any secret:// references in string leaves.
    #>
    [CmdletBinding()]
    param([Parameter()]$Node)

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $Node[$key] = Resolve-MigSecretsInTree -Node $Node[$key]
        }
        return $Node
    }

    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $newList = @()
        foreach ($item in $Node) {
            $newList += , (Resolve-MigSecretsInTree -Node $item)
        }
        return $newList
    }

    return (Resolve-MigSecretValue -Value $Node)
}

function Get-MigrationConfig {
    <#
    .SYNOPSIS
    Loads a migration configuration, either from a single JSON file or from a client profile
    merged over shared defaults. Resolves secret:// references.

    .PARAMETER ConfigFile
    Path to a single JSON config (legacy / single-tenant mode).

    .PARAMETER Client
    Client name. Loads <ConfigRoot>/clients/<Client>/profile.json merged over
    <ConfigRoot>/defaults.json (profile wins).

    .PARAMETER ConfigRoot
    Root of the multi-client config tree. Defaults to a 'config' folder next to this module.

    .PARAMETER ResolveSecrets
    Resolve secret:// references via SecretManagement. Default true.

    .OUTPUTS
    [ordered] hashtable of the effective configuration.
    #>
    [CmdletBinding(DefaultParameterSetName = 'File')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string]$ConfigFile,

        [Parameter(Mandatory, ParameterSetName = 'Client')]
        [string]$Client,

        [Parameter(ParameterSetName = 'Client')]
        [string]$ConfigRoot,

        [bool]$ResolveSecrets = $true
    )

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not (Test-Path -Path $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }
        $raw = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        $effective = ConvertTo-MigHashtableDeep -InputObject $raw
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
            $ConfigRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\config'
        }
        $ConfigRoot = (Resolve-Path -Path $ConfigRoot -ErrorAction SilentlyContinue)?.Path ?? $ConfigRoot

        $defaultsPath = Join-Path -Path $ConfigRoot -ChildPath 'defaults.json'
        $profilePath = Join-Path -Path $ConfigRoot -ChildPath ("clients\{0}\profile.json" -f $Client)

        if (-not (Test-Path -Path $profilePath)) {
            throw "Client profile not found: $profilePath"
        }

        $base = [ordered]@{}
        if (Test-Path -Path $defaultsPath) {
            $defaultsRaw = Get-Content -Path $defaultsPath -Raw | ConvertFrom-Json
            $base = ConvertTo-MigHashtableDeep -InputObject $defaultsRaw
        }

        $profileRaw = Get-Content -Path $profilePath -Raw | ConvertFrom-Json
        $profile = ConvertTo-MigHashtableDeep -InputObject $profileRaw

        $effective = Merge-MigHashtable -Base $base -Override $profile
        $effective['client'] = $Client
        $effective['config_root'] = $ConfigRoot
    }

    if ($ResolveSecrets) {
        $effective = Resolve-MigSecretsInTree -Node $effective
    }

    return $effective
}

function New-MigHookContext {
    <#
    .SYNOPSIS
    Builds a standard context object passed to hook scripts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HookName,
        [string]$Client = '',
        [string]$Phase = '',
        [string]$VMName = '',
        [string]$ManifestPath = '',
        [hashtable]$Extra
    )

    $context = [ordered]@{
        hook = $HookName
        client = $Client
        phase = $Phase
        vm_name = $VMName
        manifest_path = $ManifestPath
        timestamp = (Get-Date).ToString('o')
        machine = $env:COMPUTERNAME
    }

    if ($Extra) {
        foreach ($key in $Extra.Keys) { $context[$key] = $Extra[$key] }
    }

    return $context
}

function Invoke-MigrationHook {
    <#
    .SYNOPSIS
    Executes all *.ps1 hook scripts inside <HooksRoot>/<HookName>.d in alphabetical order.

    .DESCRIPTION
    Each hook receives the context as a JSON file path (-ContextPath, if the script declares it)
    and via the MIG_HOOK_CONTEXT_PATH environment variable. Hooks signal success with exit code 0.

    For 'pre-*' hooks, a non-zero exit is BLOCKING by default (the caller should stop the phase).
    For 'post-*' and 'on-failure' hooks, a non-zero exit is logged as a warning and is non-blocking.

    .PARAMETER HookName
    Logical hook point, e.g. pre-pipeline, pre-EXEC, post-POST, on-failure, post-pipeline.

    .PARAMETER HooksRoot
    Directory containing the <HookName>.d sub-folders.

    .PARAMETER Context
    Hashtable context to serialize and pass to hooks.

    .PARAMETER DryRun
    If set, hooks are listed but not executed.

    .OUTPUTS
    [pscustomobject] with Blocked (bool), Executed (int), Failed (int), Results (array).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HookName,
        [string]$HooksRoot,
        [hashtable]$Context = @{},
        [switch]$DryRun
    )

    $outcome = [pscustomobject]@{
        HookName = $HookName
        Blocked = $false
        Executed = 0
        Failed = 0
        Results = @()
    }

    if ([string]::IsNullOrWhiteSpace($HooksRoot)) {
        return $outcome
    }

    $hookDir = Join-Path -Path $HooksRoot -ChildPath ("{0}.d" -f $HookName)
    if (-not (Test-Path -Path $hookDir)) {
        return $outcome
    }

    $scripts = @(Get-ChildItem -Path $hookDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($scripts.Count -eq 0) {
        return $outcome
    }

    $isBlockingPoint = $HookName -like 'pre-*'

    # Serialize context to a temp JSON file the hook can read.
    $contextPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("mig-hook-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        ($Context | ConvertTo-Json -Depth 12) | Set-Content -Path $contextPath -Encoding UTF8
    }
    catch {
        Write-MigCommonLog -Level WARN -Message "Could not serialize hook context for '$HookName': $($_.Exception.Message)" -Phase 'HOOK'
    }

    $previousContextEnv = $env:MIG_HOOK_CONTEXT_PATH
    $env:MIG_HOOK_CONTEXT_PATH = $contextPath

    try {
        foreach ($script in $scripts) {
            if ($DryRun) {
                Write-MigCommonLog -Level INFO -Message "[DRY-RUN] Would run hook '$HookName': $($script.Name)" -Phase 'HOOK'
                $outcome.Results += [pscustomobject]@{ Script = $script.Name; ExitCode = 0; DryRun = $true }
                continue
            }

            Write-MigCommonLog -Level INFO -Message "Running hook '$HookName': $($script.Name)" -Phase 'HOOK'
            $exitCode = 0
            try {
                $declaresContextParam = $false
                try {
                    $cmd = Get-Command -Name $script.FullName -CommandType ExternalScript -ErrorAction Stop
                    $declaresContextParam = $cmd.Parameters.ContainsKey('ContextPath')
                }
                catch {
                    $declaresContextParam = $false
                }

                if ($declaresContextParam) {
                    & $script.FullName -ContextPath $contextPath
                }
                else {
                    & $script.FullName
                }
                $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
            }
            catch {
                Write-MigCommonLog -Level ERROR -Message "Hook '$($script.Name)' threw: $($_.Exception.Message)" -Phase 'HOOK'
                $exitCode = 1
            }

            $outcome.Executed++
            $outcome.Results += [pscustomobject]@{ Script = $script.Name; ExitCode = $exitCode; DryRun = $false }

            if ($exitCode -ne 0) {
                $outcome.Failed++
                if ($isBlockingPoint) {
                    Write-MigCommonLog -Level ERROR -Message "Blocking hook '$($script.Name)' failed (exit $exitCode). Stopping '$HookName'." -Phase 'HOOK'
                    $outcome.Blocked = $true
                    break
                }
                else {
                    Write-MigCommonLog -Level WARN -Message "Non-blocking hook '$($script.Name)' failed (exit $exitCode). Continuing." -Phase 'HOOK'
                }
            }
        }
    }
    finally {
        $env:MIG_HOOK_CONTEXT_PATH = $previousContextEnv
        Remove-Item -Path $contextPath -Force -ErrorAction SilentlyContinue
    }

    return $outcome
}

Export-ModuleMember -Function @(
    'Write-MigCommonLog',
    'ConvertTo-MigHashtableDeep',
    'Merge-MigHashtable',
    'Resolve-MigSecretValue',
    'Resolve-MigSecretsInTree',
    'Get-MigrationConfig',
    'New-MigHookContext',
    'Invoke-MigrationHook'
)
