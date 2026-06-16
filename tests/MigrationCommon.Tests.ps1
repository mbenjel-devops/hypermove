# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $modulePath = Join-Path -Path $projectRoot -ChildPath 'src\MigrationCommon.psm1'
    if (-not (Test-Path -Path $modulePath)) {
        throw "Module under test not found: $modulePath"
    }
    Import-Module -Name $modulePath -Force
}

Describe 'MigrationCommon module' {

    Context 'ConvertTo-MigHashtableDeep' {
        It 'converts nested PSCustomObject to ordered hashtables' {
            $obj = [pscustomobject]@{ a = 1; nested = [pscustomobject]@{ b = 2 } }
            $result = ConvertTo-MigHashtableDeep -InputObject $obj
            $result | Should -BeOfType ([System.Collections.IDictionary])
            $result['nested'] | Should -BeOfType ([System.Collections.IDictionary])
            $result['nested']['b'] | Should -Be 2
        }

        It 'preserves arrays of scalars' {
            $obj = [pscustomobject]@{ list = @('x', 'y', 'z') }
            $result = ConvertTo-MigHashtableDeep -InputObject $obj
            @($result['list']).Count | Should -Be 3
            $result['list'][1] | Should -Be 'y'
        }
    }

    Context 'Merge-MigHashtable' {
        It 'override wins for scalar keys' {
            $base = [ordered]@{ a = 1; b = 2 }
            $over = [ordered]@{ b = 99 }
            $merged = Merge-MigHashtable -Base $base -Override $over
            $merged['a'] | Should -Be 1
            $merged['b'] | Should -Be 99
        }

        It 'adds keys present only in override' {
            $base = [ordered]@{ a = 1 }
            $over = [ordered]@{ c = 3 }
            $merged = Merge-MigHashtable -Base $base -Override $over
            $merged['c'] | Should -Be 3
        }

        It 'deep-merges nested hashtables' {
            $base = [ordered]@{ net = [ordered]@{ switch = 'A'; vlan = 10 } }
            $over = [ordered]@{ net = [ordered]@{ switch = 'B' } }
            $merged = Merge-MigHashtable -Base $base -Override $over
            $merged['net']['switch'] | Should -Be 'B'
            $merged['net']['vlan'] | Should -Be 10
        }

        It 'replaces arrays rather than merging them' {
            $base = [ordered]@{ svc = @('a', 'b') }
            $over = [ordered]@{ svc = @('c') }
            $merged = Merge-MigHashtable -Base $base -Override $over
            @($merged['svc']).Count | Should -Be 1
            $merged['svc'][0] | Should -Be 'c'
        }
    }

    Context 'Resolve-MigSecretValue' {
        It 'passes through non-secret strings unchanged' {
            Resolve-MigSecretValue -Value 'plain-value' | Should -Be 'plain-value'
        }

        It 'passes through non-string values unchanged' {
            Resolve-MigSecretValue -Value 42 | Should -Be 42
        }

        It 'returns the reference unchanged when SecretManagement is unavailable' {
            Mock -CommandName Get-Command -ModuleName MigrationCommon -MockWith { $null } -ParameterFilter { $Name -eq 'Get-Secret' }
            $ref = 'secret://MyVault/MySecret'
            Resolve-MigSecretValue -Value $ref | Should -Be $ref
        }
    }

    Context 'Get-MigrationConfig (client profile mode)' {
        BeforeAll {
            $cfgRoot = Join-Path -Path $TestDrive -ChildPath 'config'
            New-Item -Path (Join-Path $cfgRoot 'clients\acme') -ItemType Directory -Force | Out-Null
            @{ hyperv_switch = 'Default'; critical_services = @('W32Time') } | ConvertTo-Json | Set-Content -Path (Join-Path $cfgRoot 'defaults.json')
            @{ vcenter_host = 'vc.acme.local'; hyperv_switch = 'Acme-Ext' } | ConvertTo-Json | Set-Content -Path (Join-Path $cfgRoot 'clients\acme\profile.json')
        }

        It 'merges profile over defaults' {
            $cfg = Get-MigrationConfig -Client 'acme' -ConfigRoot $cfgRoot -ResolveSecrets $false
            $cfg['vcenter_host'] | Should -Be 'vc.acme.local'
            $cfg['hyperv_switch'] | Should -Be 'Acme-Ext'
            $cfg['critical_services'][0] | Should -Be 'W32Time'
            $cfg['client'] | Should -Be 'acme'
        }

        It 'throws when the client profile does not exist' {
            { Get-MigrationConfig -Client 'ghost' -ConfigRoot $cfgRoot -ResolveSecrets $false } | Should -Throw
        }
    }

    Context 'Get-MigrationConfig (single file mode)' {
        It 'loads a single JSON config file' {
            $file = Join-Path -Path $TestDrive -ChildPath 'single.json'
            @{ vcenter_host = 'vc.local'; output_dir = 'C:\Out' } | ConvertTo-Json | Set-Content -Path $file
            $cfg = Get-MigrationConfig -ConfigFile $file -ResolveSecrets $false
            $cfg['vcenter_host'] | Should -Be 'vc.local'
        }

        It 'throws when the file is missing' {
            { Get-MigrationConfig -ConfigFile (Join-Path $TestDrive 'nope.json') -ResolveSecrets $false } | Should -Throw
        }
    }

    Context 'New-MigHookContext' {
        It 'builds a context with the expected fields' {
            $ctx = New-MigHookContext -HookName 'pre-EXEC' -Client 'acme' -Phase 'FULL' -VMName 'SRV01'
            $ctx['hook'] | Should -Be 'pre-EXEC'
            $ctx['client'] | Should -Be 'acme'
            $ctx['vm_name'] | Should -Be 'SRV01'
            $ctx['timestamp'] | Should -Not -BeNullOrEmpty
        }

        It 'includes extra fields' {
            $ctx = New-MigHookContext -HookName 'on-failure' -Extra @{ reason = 'exec-fail' }
            $ctx['reason'] | Should -Be 'exec-fail'
        }
    }

    Context 'Invoke-MigrationHook' {
        BeforeAll {
            $hooksRoot = Join-Path -Path $TestDrive -ChildPath 'hooks'
        }

        It 'returns an empty outcome when the hook directory is absent' {
            $r = Invoke-MigrationHook -HookName 'pre-EXEC' -HooksRoot (Join-Path $TestDrive 'no-hooks')
            $r.Executed | Should -Be 0
            $r.Blocked | Should -BeFalse
        }

        It 'runs a successful hook (exit 0)' {
            $dir = Join-Path $hooksRoot 'pre-EXEC.d'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $dir '10-ok.ps1') -Value 'param([string]$ContextPath) exit 0'
            $r = Invoke-MigrationHook -HookName 'pre-EXEC' -HooksRoot $hooksRoot
            $r.Executed | Should -Be 1
            $r.Failed | Should -Be 0
            $r.Blocked | Should -BeFalse
        }

        It 'blocks on a failing pre-* hook' {
            $dir = Join-Path $hooksRoot 'pre-pipeline.d'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $dir '10-fail.ps1') -Value 'exit 3'
            $r = Invoke-MigrationHook -HookName 'pre-pipeline' -HooksRoot $hooksRoot
            $r.Failed | Should -Be 1
            $r.Blocked | Should -BeTrue
        }

        It 'does not block on a failing post-* hook' {
            $dir = Join-Path $hooksRoot 'post-POST.d'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $dir '10-fail.ps1') -Value 'exit 1'
            $r = Invoke-MigrationHook -HookName 'post-POST' -HooksRoot $hooksRoot
            $r.Failed | Should -Be 1
            $r.Blocked | Should -BeFalse
        }

        It 'lists but does not execute hooks in dry-run' {
            $dir = Join-Path $hooksRoot 'pre-PRE.d'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $marker = Join-Path $TestDrive 'marker.txt'
            Set-Content -Path (Join-Path $dir '10-side-effect.ps1') -Value "Set-Content -Path '$marker' -Value 'ran'; exit 0"
            $r = Invoke-MigrationHook -HookName 'pre-PRE' -HooksRoot $hooksRoot -DryRun
            (Test-Path $marker) | Should -BeFalse
            $r.Results[0].DryRun | Should -BeTrue
        }
    }

    Context 'Test-MigrationSchema' {
        It 'passes a valid object' {
            $schema = [ordered]@{ a = @{ Required = $true; Type = 'string' } }
            $r = Test-MigrationSchema -InputObject ([ordered]@{ a = 'x' }) -Schema $schema
            $r.IsValid | Should -BeTrue
        }

        It 'flags missing required fields' {
            $schema = [ordered]@{ a = @{ Required = $true; Type = 'string' } }
            $r = Test-MigrationSchema -InputObject ([ordered]@{}) -Schema $schema
            $r.IsValid | Should -BeFalse
            $r.Errors | Should -Contain 'Missing required field: a'
        }

        It 'enforces allowed values' {
            $schema = [ordered]@{ tool = @{ Required = $true; Type = 'string'; Values = @('A', 'B') } }
            $r = Test-MigrationSchema -InputObject ([ordered]@{ tool = 'C' }) -Schema $schema
            $r.IsValid | Should -BeFalse
        }

        It 'enforces numeric min/max' {
            $schema = [ordered]@{ n = @{ Required = $true; Type = 'int'; Min = 1; Max = 10 } }
            (Test-MigrationSchema -InputObject ([ordered]@{ n = 0 }) -Schema $schema).IsValid | Should -BeFalse
            (Test-MigrationSchema -InputObject ([ordered]@{ n = 5 }) -Schema $schema).IsValid | Should -BeTrue
        }
    }

    Context 'Test-MigrationConfig' {
        It 'accepts a complete config' {
            $cfg = [ordered]@{
                vcenter_host = 'v'; hyperv_host = 'h'; hyperv_vm_path = 'p'; hyperv_vhdx_path = 'q'
                hyperv_switch = 's'; output_dir = 'o'; report_dir = 'r'; log_dir = 'l'; conversion_tool = 'StarWindV2V'
            }
            (Test-MigrationConfig -Config $cfg).IsValid | Should -BeTrue
        }

        It 'rejects an unknown conversion tool' {
            $cfg = [ordered]@{
                vcenter_host = 'v'; hyperv_host = 'h'; hyperv_vm_path = 'p'; hyperv_vhdx_path = 'q'
                hyperv_switch = 's'; output_dir = 'o'; report_dir = 'r'; log_dir = 'l'; conversion_tool = 'Bogus'
            }
            (Test-MigrationConfig -Config $cfg).IsValid | Should -BeFalse
        }
    }

    Context 'Migration state store' {
        It 'records and detects a completed phase' {
            $out = Join-Path $TestDrive 'st1'
            Set-MigrationPhaseState -OutputDir $out -VMName 'SRV1' -Phase 'PRE' -Status 'SUCCESS' | Out-Null
            Test-PhaseCompleted -OutputDir $out -VMName 'SRV1' -Phase 'PRE' | Should -BeTrue
            Test-PhaseCompleted -OutputDir $out -VMName 'SRV1' -Phase 'EXEC' | Should -BeFalse
        }

        It 'treats a failed phase as not completed' {
            $out = Join-Path $TestDrive 'st2'
            Set-MigrationPhaseState -OutputDir $out -VMName 'SRV2' -Phase 'EXEC' -Status 'FAILED' -ExitCode 4 | Out-Null
            Test-PhaseCompleted -OutputDir $out -VMName 'SRV2' -Phase 'EXEC' | Should -BeFalse
        }

        It 'resets state' {
            $out = Join-Path $TestDrive 'st3'
            Set-MigrationPhaseState -OutputDir $out -VMName 'SRV3' -Phase 'PRE' -Status 'SUCCESS' | Out-Null
            Reset-MigrationState -OutputDir $out -VMName 'SRV3'
            Test-PhaseCompleted -OutputDir $out -VMName 'SRV3' -Phase 'PRE' | Should -BeFalse
        }

        It 'sanitizes VM names in the state file path' {
            $out = Join-Path $TestDrive 'st4'
            $path = Get-MigrationStatePath -OutputDir $out -VMName 'srv/with:bad*chars'
            (Split-Path -Path $path -Leaf) | Should -Be 'srv_with_bad_chars.state.json'
        }
    }

    Context 'Test-TargetHostCapacity' {
        It 'returns FAIL when the manifest is missing' {
            $r = Test-TargetHostCapacity -ManifestPath (Join-Path $TestDrive 'nope.json') -HyperVHost 'h'
            $r.Status | Should -Be 'FAIL'
        }

        It 'computes required disk from manifest and degrades gracefully without Hyper-V' {
            $man = Join-Path $TestDrive 'm.json'
            @{ compute = @{ vcpu = 2; ram_mb = 4096 }; disks = @(@{ size_gb = 30 }, @{ size_gb = 20 }) } | ConvertTo-Json -Depth 5 | Set-Content $man
            $r = Test-TargetHostCapacity -ManifestPath $man -HyperVHost 'unreachable-host'
            $r.RequiredDiskGB | Should -Be 50
            $r.Status | Should -BeIn @('PASS', 'WARN')
        }
    }

    Context 'Send-MigrationEvent' {
        It 'appends an event to the audit log' {
            $audit = Join-Path $TestDrive 'audit'
            Send-MigrationEvent -EventType 'unit.test' -Data @{ k = 'v' } -AuditDir $audit | Out-Null
            $file = Get-ChildItem -Path $audit -Filter 'events-*.jsonl' | Select-Object -First 1
            $file | Should -Not -BeNullOrEmpty
            (Get-Content $file.FullName -Raw) | Should -Match 'unit.test'
        }
    }
}

