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
        $profileObj = ConvertTo-MigHashtableDeep -InputObject $profileRaw

        $effective = Merge-MigHashtable -Base $base -Override $profileObj
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

#region Schema validation

function Test-MigrationSchema {
    <#
    .SYNOPSIS
    Validates a hashtable against a lightweight schema descriptor.

    .DESCRIPTION
    The schema is a hashtable of field -> rule. Each rule supports:
      Required (bool), Type ('string'|'int'|'number'|'bool'|'array'|'object'),
      AllowEmpty (bool, strings/arrays), Values (allowed set), Min/Max (numbers).
    Returns an object with IsValid (bool) and Errors (string[]).

    .PARAMETER InputObject
    The hashtable to validate.

    .PARAMETER Schema
    The schema descriptor hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$InputObject,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Schema
    )

    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($field in $Schema.Keys) {
        $rule = $Schema[$field]
        $present = $InputObject.Contains($field)
        $value = if ($present) { $InputObject[$field] } else { $null }

        $required = [bool]($rule['Required'])
        if (-not $present) {
            if ($required) { $errors.Add("Missing required field: $field") | Out-Null }
            continue
        }

        $allowEmpty = $rule.Contains('AllowEmpty') -and [bool]$rule['AllowEmpty']
        if (-not $allowEmpty) {
            if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
                $errors.Add("Field '$field' must not be empty.") | Out-Null
                continue
            }
            if (($value -is [System.Collections.IEnumerable]) -and ($value -isnot [string]) -and (@($value).Count -eq 0)) {
                $errors.Add("Field '$field' must not be an empty array.") | Out-Null
                continue
            }
        }

        $type = [string]$rule['Type']
        if (-not [string]::IsNullOrWhiteSpace($type)) {
            $typeOk = switch ($type) {
                'string' { $value -is [string] }
                'int' { ($value -is [int]) -or ($value -is [long]) -or ($value -is [double] -and [Math]::Floor($value) -eq $value) }
                'number' { ($value -is [int]) -or ($value -is [long]) -or ($value -is [double]) -or ($value -is [decimal]) }
                'bool' { $value -is [bool] }
                'array' { ($value -is [System.Collections.IEnumerable]) -and ($value -isnot [string]) }
                'object' { $value -is [System.Collections.IDictionary] }
                default { $true }
            }
            if (-not $typeOk) {
                $errors.Add("Field '$field' should be of type '$type'.") | Out-Null
                continue
            }
        }

        if ($rule.Contains('Values')) {
            $allowed = @($rule['Values'])
            if ($allowed -notcontains $value) {
                $errors.Add("Field '$field' has invalid value '$value'. Allowed: $($allowed -join ', ').") | Out-Null
            }
        }

        if ($rule.Contains('Min') -and ($value -is [int] -or $value -is [double] -or $value -is [long])) {
            if ($value -lt $rule['Min']) { $errors.Add("Field '$field' is below minimum $($rule['Min']).") | Out-Null }
        }
        if ($rule.Contains('Max') -and ($value -is [int] -or $value -is [double] -or $value -is [long])) {
            if ($value -gt $rule['Max']) { $errors.Add("Field '$field' is above maximum $($rule['Max']).") | Out-Null }
        }
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors = @($errors)
    }
}

function Get-MigrationConfigSchema {
    <#
    .SYNOPSIS
    Returns the schema descriptor for a migration configuration.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        vcenter_host = @{ Required = $true; Type = 'string' }
        hyperv_host = @{ Required = $true; Type = 'string' }
        hyperv_vm_path = @{ Required = $true; Type = 'string' }
        hyperv_vhdx_path = @{ Required = $true; Type = 'string' }
        hyperv_switch = @{ Required = $true; Type = 'string' }
        output_dir = @{ Required = $true; Type = 'string' }
        report_dir = @{ Required = $true; Type = 'string' }
        log_dir = @{ Required = $true; Type = 'string' }
        conversion_tool = @{ Required = $true; Type = 'string'; Values = @('StarWindV2V', 'MVMC', 'QemuImg') }
        critical_services = @{ Required = $false; Type = 'array' }
    }
}

function Test-MigrationConfig {
    <#
    .SYNOPSIS
    Validates an effective migration config hashtable against the config schema.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    return Test-MigrationSchema -InputObject $Config -Schema (Get-MigrationConfigSchema)
}

#endregion

#region Idempotence / resume state

function Get-MigrationStatePath {
    <#
    .SYNOPSIS
    Returns the path of the per-VM state file under <OutputDir>\state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$VMName
    )

    $stateDir = Join-Path -Path $OutputDir -ChildPath 'state'
    if (-not (Test-Path -Path $stateDir)) {
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
    }
    $safeName = ($VMName -replace '[^A-Za-z0-9._-]', '_')
    return Join-Path -Path $stateDir -ChildPath ("$safeName.state.json")
}

function Get-MigrationState {
    <#
    .SYNOPSIS
    Loads (or initializes) the persisted migration state for a VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$VMName
    )

    $path = Get-MigrationStatePath -OutputDir $OutputDir -VMName $VMName
    if (Test-Path -Path $path) {
        try {
            $raw = Get-Content -Path $path -Raw | ConvertFrom-Json
            return ConvertTo-MigHashtableDeep -InputObject $raw
        }
        catch {
            Write-MigCommonLog -Level WARN -Message "State file unreadable for '$VMName', reinitializing: $($_.Exception.Message)" -Phase 'STATE'
        }
    }

    return [ordered]@{
        vm_name = $VMName
        created_at = (Get-Date).ToString('o')
        updated_at = (Get-Date).ToString('o')
        phases = [ordered]@{}
    }
}

function Set-MigrationPhaseState {
    <#
    .SYNOPSIS
    Records the result of a phase in the persisted state and saves it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][ValidateSet('PRE', 'EXEC', 'POST', 'ROLLBACK')][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('SUCCESS', 'FAILED', 'PARTIAL')][string]$Status,
        [int]$ExitCode = 0
    )

    $state = Get-MigrationState -OutputDir $OutputDir -VMName $VMName
    if (-not ($state['phases'] -is [System.Collections.IDictionary])) {
        $state['phases'] = [ordered]@{}
    }
    $state['phases'][$Phase] = [ordered]@{
        status = $Status
        exit_code = $ExitCode
        at = (Get-Date).ToString('o')
    }
    $state['updated_at'] = (Get-Date).ToString('o')

    $path = Get-MigrationStatePath -OutputDir $OutputDir -VMName $VMName
    try {
        $state | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    }
    catch {
        Write-MigCommonLog -Level WARN -Message "Could not persist state for '$VMName': $($_.Exception.Message)" -Phase 'STATE'
    }
    return $state
}

function Test-PhaseCompleted {
    <#
    .SYNOPSIS
    Returns $true if the given phase was previously completed successfully.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][ValidateSet('PRE', 'EXEC', 'POST', 'ROLLBACK')][string]$Phase
    )

    $state = Get-MigrationState -OutputDir $OutputDir -VMName $VMName
    if ($state['phases'] -is [System.Collections.IDictionary] -and $state['phases'].Contains($Phase)) {
        return ([string]$state['phases'][$Phase]['status'] -eq 'SUCCESS')
    }
    return $false
}

function Reset-MigrationState {
    <#
    .SYNOPSIS
    Deletes the persisted state file for a VM (fresh start).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$VMName
    )

    $path = Get-MigrationStatePath -OutputDir $OutputDir -VMName $VMName
    if (Test-Path -Path $path) {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Target host capacity

function Test-TargetHostCapacity {
    <#
    .SYNOPSIS
    Checks whether a target Hyper-V host can accommodate the required resources.

    .DESCRIPTION
    Reads required vCPU / RAM / disk from a manifest and compares against the target host
    capacity queried via Hyper-V / storage cmdlets. Degrades gracefully when the cmdlets
    or host are not reachable (returns WARN-level findings, never throws).

    .PARAMETER ManifestPath
    Path to the PRE manifest JSON.

    .PARAMETER HyperVHost
    Target Hyper-V host name.

    .PARAMETER VHDXPath
    Target path where VHDX files will be created (used to find the destination volume).

    .OUTPUTS
    [pscustomobject] with Status ('PASS'|'WARN'|'FAIL') and Findings (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$HyperVHost,
        [string]$VHDXPath
    )

    $findings = New-Object System.Collections.Generic.List[string]
    $status = 'PASS'

    if (-not (Test-Path -Path $ManifestPath)) {
        return [pscustomobject]@{ Status = 'FAIL'; Findings = @("Manifest not found: $ManifestPath") }
    }

    try {
        $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{ Status = 'FAIL'; Findings = @("Manifest unreadable: $($_.Exception.Message)") }
    }

    $reqVcpu = 0
    $reqRamMB = 0
    try { $reqVcpu = [int]$manifest.compute.vcpu } catch { }
    try { $reqRamMB = [int]$manifest.compute.ram_mb } catch { }

    $reqDiskGB = 0.0
    try {
        foreach ($d in @($manifest.disks)) {
            if ($d -and $d.size_gb) { $reqDiskGB += [double]$d.size_gb }
        }
    }
    catch { }

    # CPU / RAM via Hyper-V host.
    if (Get-Command -Name Get-VMHost -ErrorAction SilentlyContinue) {
        try {
            $vmHost = Get-VMHost -ComputerName $HyperVHost -ErrorAction Stop
            $hostLps = [int]$vmHost.LogicalProcessorCount
            if ($hostLps -gt 0 -and $reqVcpu -gt $hostLps) {
                $findings.Add("Requested vCPU ($reqVcpu) exceeds host logical processors ($hostLps).") | Out-Null
                $status = 'WARN'
            }

            if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
                try {
                    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $HyperVHost -ErrorAction Stop
                    $freeRamMB = [int]([double]$os.FreePhysicalMemory / 1024)
                    if ($reqRamMB -gt 0 -and $freeRamMB -gt 0 -and $reqRamMB -gt $freeRamMB) {
                        $findings.Add("Requested RAM ($reqRamMB MB) exceeds host free memory ($freeRamMB MB).") | Out-Null
                        $status = 'WARN'
                    }
                }
                catch {
                    $findings.Add("Could not read host memory: $($_.Exception.Message)") | Out-Null
                    if ($status -eq 'PASS') { $status = 'WARN' }
                }
            }
        }
        catch {
            $findings.Add("Could not query Hyper-V host '$HyperVHost': $($_.Exception.Message)") | Out-Null
            if ($status -eq 'PASS') { $status = 'WARN' }
        }
    }
    else {
        $findings.Add('Hyper-V cmdlets not available on this machine; CPU/RAM capacity not verified.') | Out-Null
        if ($status -eq 'PASS') { $status = 'WARN' }
    }

    # Disk capacity on destination volume.
    if (-not [string]::IsNullOrWhiteSpace($VHDXPath)) {
        $driveLetter = $null
        if ($VHDXPath -match '^([A-Za-z]):') { $driveLetter = $Matches[1] }

        if ($driveLetter -and (Get-Command -Name Get-Volume -ErrorAction SilentlyContinue)) {
            try {
                $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
                $freeGB = [double]$vol.SizeRemaining / 1GB
                # Require destination free space >= required disk + 10% headroom.
                $needed = $reqDiskGB * 1.10
                if ($reqDiskGB -gt 0 -and $freeGB -lt $needed) {
                    $findings.Add(("Destination volume {0}: free {1:N0} GB < required {2:N0} GB (+10% headroom)." -f $driveLetter, $freeGB, $needed)) | Out-Null
                    $status = 'FAIL'
                }
            }
            catch {
                $findings.Add("Could not read destination volume '$driveLetter': $($_.Exception.Message)") | Out-Null
                if ($status -eq 'PASS') { $status = 'WARN' }
            }
        }
        else {
            $findings.Add('Volume cmdlets not available or path not drive-rooted; disk capacity not verified.') | Out-Null
            if ($status -eq 'PASS') { $status = 'WARN' }
        }
    }

    if ($findings.Count -eq 0) {
        $findings.Add("Capacity OK: vCPU=$reqVcpu, RAM=$reqRamMB MB, disk=$([Math]::Round($reqDiskGB,1)) GB.") | Out-Null
    }

    return [pscustomobject]@{
        Status = $status
        Findings = @($findings)
        RequiredVcpu = $reqVcpu
        RequiredRamMB = $reqRamMB
        RequiredDiskGB = [Math]::Round($reqDiskGB, 1)
    }
}

#endregion

#region Event dispatch (generic integration)

function Send-MigrationEvent {
    <#
    .SYNOPSIS
    Emits a structured migration event to a generic, vendor-neutral sink.

    .DESCRIPTION
    Always appends the event to an audit JSON-Lines file. Optionally POSTs the event as
    JSON to a webhook URL when one is configured. Never throws on delivery failure.

    .PARAMETER EventType
    Dot-namespaced event type, e.g. 'pipeline.start', 'vm.success', 'vm.failed'.

    .PARAMETER Data
    Hashtable payload describing the event.

    .PARAMETER AuditDir
    Directory for the audit log file (events-YYYYMMDD.jsonl).

    .PARAMETER WebhookUrl
    Optional generic webhook URL to POST the event to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventType,
        [hashtable]$Data = @{},
        [string]$AuditDir,
        [string]$WebhookUrl
    )

    $event = [ordered]@{
        event = $EventType
        timestamp = (Get-Date).ToString('o')
        machine = $env:COMPUTERNAME
        data = $Data
    }
    $json = $event | ConvertTo-Json -Depth 10 -Compress

    if (-not [string]::IsNullOrWhiteSpace($AuditDir)) {
        try {
            if (-not (Test-Path -Path $AuditDir)) {
                New-Item -Path $AuditDir -ItemType Directory -Force | Out-Null
            }
            $auditFile = Join-Path -Path $AuditDir -ChildPath ("events-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
            Add-Content -Path $auditFile -Value $json -Encoding UTF8
        }
        catch {
            Write-MigCommonLog -Level WARN -Message "Could not write audit event: $($_.Exception.Message)" -Phase 'EVENT'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop | Out-Null
            Write-MigCommonLog -Level INFO -Message "Event '$EventType' delivered to webhook." -Phase 'EVENT'
        }
        catch {
            Write-MigCommonLog -Level WARN -Message "Webhook delivery failed for '$EventType': $($_.Exception.Message)" -Phase 'EVENT'
        }
    }

    return [pscustomobject]@{ Event = $EventType; Json = $json }
}

#endregion

Export-ModuleMember -Function @(
    'Write-MigCommonLog',
    'ConvertTo-MigHashtableDeep',
    'Merge-MigHashtable',
    'Resolve-MigSecretValue',
    'Resolve-MigSecretsInTree',
    'Get-MigrationConfig',
    'New-MigHookContext',
    'Invoke-MigrationHook',
    'Test-MigrationSchema',
    'Get-MigrationConfigSchema',
    'Test-MigrationConfig',
    'Get-MigrationStatePath',
    'Get-MigrationState',
    'Set-MigrationPhaseState',
    'Test-PhaseCompleted',
    'Reset-MigrationState',
    'Test-TargetHostCapacity',
    'Send-MigrationEvent'
)
