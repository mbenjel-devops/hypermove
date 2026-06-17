# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\00-Orchestrator.ps1'

    # The orchestrator runs its pipeline body at top-level, so it cannot be
    # dot-sourced safely. Instead, extract the pure helper functions via the AST
    # and define them in the test scope for isolated unit testing.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$parseErrors)
    $wanted = @('Resolve-TargetVMs', 'New-PhaseState')
    $funcDefs = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    ) | Where-Object { $wanted -contains $_.Name }
    $combined = ($funcDefs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    . ([scriptblock]::Create($combined))
}

Describe '00-Orchestrator.ps1' {

    Context 'Script integrity' {
        It 'exists' {
            Test-Path -Path $scriptUnderTest | Should -BeTrue
        }

        It 'has no syntax errors' {
            $errors = $null
            $tokens = $null
            [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }

        It 'declares the expected core parameters' {
            $cmd = Get-Command -Name $scriptUnderTest -CommandType ExternalScript
            foreach ($p in @('VMName', 'Mode', 'Phase', 'Resume', 'ValidateConfig', 'CheckTargetCapacity', 'Client')) {
                $cmd.Parameters.Keys | Should -Contain $p
            }
        }
    }

    Context 'New-PhaseState' {
        It 'returns a fresh skipped phase state' {
            $state = New-PhaseState
            $state.status | Should -Be 'SKIPPED'
            $state.exit_code | Should -Be 0
            $state.duration_s | Should -Be 0
            $state.retries | Should -Be 0
        }
    }

    Context 'Resolve-TargetVMs - SINGLE mode' {
        It 'returns the single VM name' {
            $vms = @(Resolve-TargetVMs -ResolvedMode 'SINGLE' -SingleVmName 'SRVWEB01')
            $vms.Count | Should -Be 1
            $vms[0] | Should -Be 'SRVWEB01'
        }

        It 'throws when the VM name is missing' {
            { Resolve-TargetVMs -ResolvedMode 'SINGLE' -SingleVmName '' } | Should -Throw '*mandatory*'
        }
    }

    Context 'Resolve-TargetVMs - BATCH mode' {
        It 'returns trimmed names from an array' {
            $vms = Resolve-TargetVMs -ResolvedMode 'BATCH' -ArrayVmNames @(' SRVWEB01 ', 'SRVAPP02')
            @($vms) | Should -Contain 'SRVWEB01'
            @($vms) | Should -Contain 'SRVAPP02'
        }

        It 'reads the VMName column from a CSV' {
            $csv = Join-Path -Path $TestDrive -ChildPath 'vmlist.csv'
            "VMName`nSRVDB01`nSRVDB02" | Set-Content -Path $csv -Encoding UTF8
            $vms = Resolve-TargetVMs -ResolvedMode 'BATCH' -CsvPath $csv
            @($vms).Count | Should -Be 2
            @($vms) | Should -Contain 'SRVDB01'
            @($vms) | Should -Contain 'SRVDB02'
        }

        It 'merges array and CSV inputs and removes duplicates' {
            $csv = Join-Path -Path $TestDrive -ChildPath 'vmlist-dup.csv'
            "VMName`nSRVDB01`nSHARED" | Set-Content -Path $csv -Encoding UTF8
            $vms = Resolve-TargetVMs -ResolvedMode 'BATCH' -ArrayVmNames @('SHARED', 'SRVAPP02') -CsvPath $csv
            @($vms).Count | Should -Be 3
            @($vms | Where-Object { $_ -eq 'SHARED' }).Count | Should -Be 1
        }

        It 'throws when no VMs are provided' {
            { Resolve-TargetVMs -ResolvedMode 'BATCH' } | Should -Throw '*requires*'
        }

        It 'throws when the CSV file is missing' {
            $missing = Join-Path -Path $TestDrive -ChildPath 'nope.csv'
            { Resolve-TargetVMs -ResolvedMode 'BATCH' -CsvPath $missing } | Should -Throw '*not found*'
        }
    }

    Context 'Resolve-TargetVMs - FROM_MANIFESTS mode' {
        It 'extracts VM names from manifest-*.json files' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'manifests-fm'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            '{}' | Set-Content -Path (Join-Path $dir 'manifest-SRVWEB01.json') -Encoding UTF8
            '{}' | Set-Content -Path (Join-Path $dir 'manifest-SRVAPP02.json') -Encoding UTF8
            '{}' | Set-Content -Path (Join-Path $dir 'unrelated.json') -Encoding UTF8
            $vms = Resolve-TargetVMs -ResolvedMode 'FROM_MANIFESTS' -ManifestDirectory $dir
            @($vms).Count | Should -Be 2
            @($vms) | Should -Contain 'SRVWEB01'
            @($vms) | Should -Contain 'SRVAPP02'
        }

        It 'throws when the manifest directory is empty' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'manifests-empty'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            { Resolve-TargetVMs -ResolvedMode 'FROM_MANIFESTS' -ManifestDirectory $dir } | Should -Throw '*No manifest*'
        }

        It 'throws when the manifest directory does not exist' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'manifests-absent'
            { Resolve-TargetVMs -ResolvedMode 'FROM_MANIFESTS' -ManifestDirectory $dir } | Should -Throw '*not found*'
        }
    }
}
