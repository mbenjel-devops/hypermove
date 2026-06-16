# Requires -Version 5.1
# Requires -Modules Pester

Set-StrictMode -Version 2.0

Describe '01-PRE-Discovery.ps1' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $projectRoot = Split-Path -Parent $here
        $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\01-PRE-Discovery.ps1'

        if (-not (Test-Path -Path $scriptUnderTest)) {
            throw "Script under test not found: $scriptUnderTest"
        }

        # Define stub functions for PowerCLI cmdlets when the module is not installed
        # (e.g. in CI), so Pester can mock them. Real PowerCLI takes precedence if present.
        # They MUST be global so the separately-invoked script under test (& $scriptUnderTest)
        # can resolve them; a script-scoped function would be invisible to that child scope.
        $script:stubbedCommands = @()
        $powerCliCommands = @(
            'Get-VIServer', 'Connect-VIServer', 'Disconnect-VIServer', 'Get-VM',
            'Get-HardDisk', 'Get-NetworkAdapter', 'Get-Snapshot', 'Get-VMGuest', 'Invoke-VMScript'
        )
        foreach ($cmdName in $powerCliCommands) {
            if (-not (Get-Command -Name $cmdName -ErrorAction SilentlyContinue)) {
                Set-Item -Path ("function:global:{0}" -f $cmdName) -Value { param() }
                $script:stubbedCommands += $cmdName
            }
        }

        # Provide non-interactive vCenter credentials via env so the script never calls
        # Get-Credential (which would hang/fail in CI). Connect-VIServer is mocked per test.
        $script:savedVcHost = $env:VCENTER_HOST
        $script:savedVcUser = $env:VCENTER_USER
        $script:savedVcPass = $env:VCENTER_PASS
        $env:VCENTER_HOST = 'vcsa01.local'
        $env:VCENTER_USER = 'svc-migration'
        $env:VCENTER_PASS = 'dummy-pass'
    }

    AfterAll {
        foreach ($cmdName in $script:stubbedCommands) {
            $p = "function:global:$cmdName"
            if (Test-Path -Path $p) { Remove-Item -Path $p -Force -ErrorAction SilentlyContinue }
        }
        $env:VCENTER_HOST = $script:savedVcHost
        $env:VCENTER_USER = $script:savedVcUser
        $env:VCENTER_PASS = $script:savedVcPass
    }

    BeforeEach {
        $global:LASTEXITCODE = $null

        Mock -CommandName Get-VIServer -MockWith { @() }
        Mock -CommandName Connect-VIServer -MockWith { [pscustomobject]@{ Name = 'vcsa01.local' } }
        Mock -CommandName Disconnect-VIServer -MockWith { }

        Mock -CommandName Get-VM -MockWith {
            [pscustomobject]@{
                Name = 'TEST-VM'
                NumCpu = 4
                MemoryMB = 8192
                PowerState = 'PoweredOn'
                HardwareVersion = 'vmx-14'
                Guest = [pscustomobject]@{
                    ToolsVersion = '12345'
                    GuestFullName = 'Microsoft Windows Server 2019 (64-bit)'
                }
                ExtensionData = [pscustomobject]@{
                    Config = [pscustomobject]@{
                        Firmware = 'bios'
                        BootOptions = [pscustomobject]@{
                            EfiSecureBootEnabled = $false
                        }
                    }
                }
            }
        }

        Mock -CommandName Get-HardDisk -MockWith {
            @(
                [pscustomobject]@{
                    Name = 'Hard disk 1'
                    CapacityGB = 100
                    Filename = 'C:\Fake\disk1.vmdk'
                    Parent = [pscustomobject]@{
                        ExtensionData = [pscustomobject]@{
                            Config = [pscustomobject]@{
                                Hardware = [pscustomobject]@{
                                    Device = @(
                                        [pscustomobject]@{
                                            Key = 1000
                                            PSTypeName = 'VirtualLsiLogicController'
                                        }
                                    )
                                }
                            }
                        }
                    }
                    ExtensionData = [pscustomobject]@{
                        ControllerKey = 1000
                        Backing = [pscustomobject]@{
                            ThinProvisioned = $true
                            EagerlyScrub = $false
                            Sharing = 'sharingNone'
                            PSTypeName = 'VirtualDiskFlatVer2BackingInfo'
                        }
                    }
                },
                [pscustomobject]@{
                    Name = 'Hard disk 2'
                    CapacityGB = 200
                    Filename = 'C:\Fake\disk2.vmdk'
                    Parent = [pscustomobject]@{
                        ExtensionData = [pscustomobject]@{
                            Config = [pscustomobject]@{
                                Hardware = [pscustomobject]@{
                                    Device = @(
                                        [pscustomobject]@{
                                            Key = 1000
                                            PSTypeName = 'VirtualLsiLogicController'
                                        }
                                    )
                                }
                            }
                        }
                    }
                    ExtensionData = [pscustomobject]@{
                        ControllerKey = 1000
                        Backing = [pscustomobject]@{
                            ThinProvisioned = $true
                            EagerlyScrub = $false
                            Sharing = 'sharingNone'
                            PSTypeName = 'VirtualDiskFlatVer2BackingInfo'
                        }
                    }
                }
            )
        }

        Mock -CommandName Get-NetworkAdapter -MockWith {
            @(
                [pscustomobject]@{
                    Name = 'Network adapter 1'
                    NetworkName = 'VLAN-Prod'
                    MacAddress = '00:50:56:AA:BB:CC'
                    Type = 'VMXNET3'
                    ConnectionState = [pscustomobject]@{ StartConnected = $true }
                    ExtensionData = [pscustomobject]@{ }
                }
            )
        }

        Mock -CommandName Get-Snapshot -MockWith { @() }

        Mock -CommandName Get-VMGuest -MockWith {
            [pscustomobject]@{
                IPAddress = @('192.168.1.10')
            }
        }

        Mock -CommandName Invoke-VMScript -MockWith {
            [pscustomobject]@{
                ScriptOutput = "Ethernet|192.168.1.10|24|192.168.1.1|8.8.8.8,1.1.1.1"
            }
        }
    }

    Context 'SCENARIO 1 - VM valide READY' {
        It 'returns exit code 0 and creates READY manifest' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-1'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 0

            $manifest = Get-Content -Path (Join-Path $outDir 'manifest-TEST-VM.json') -Raw | ConvertFrom-Json
            $manifest.overall_status | Should -Be 'READY'
            (@($manifest.checks | Where-Object { $_.status -eq 'PASS' })).Count | Should -BeGreaterThan 0
        }
    }

    Context 'SCENARIO 2 - CHECK_01 FAIL (snapshots)' {
        BeforeEach {
            Mock -CommandName Get-Snapshot -MockWith {
                @([pscustomobject]@{ Name = 'snap-1' }, [pscustomobject]@{ Name = 'snap-2' })
            }
        }

        It 'returns exit code 2' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-2'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 2
        }
    }

    Context 'SCENARIO 3 - CHECK_02 FAIL (RDM)' {
        BeforeEach {
            Mock -CommandName Get-HardDisk -MockWith {
                @(
                    [pscustomobject]@{
                        Name = 'Hard disk 1'
                        CapacityGB = 100
                        Filename = 'C:\Fake\disk1.vmdk'
                        Parent = [pscustomobject]@{
                            ExtensionData = [pscustomobject]@{
                                Config = [pscustomobject]@{
                                    Hardware = [pscustomobject]@{ Device = @() }
                                }
                            }
                        }
                        ExtensionData = [pscustomobject]@{
                            ControllerKey = 1000
                            Backing = [pscustomobject]@{
                                Sharing = 'sharingNone'
                                PSTypeName = 'RawVirtualDisk'
                            }
                        }
                    }
                )
            }
        }

        It 'returns exit code 2' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-3'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 2
        }
    }

    Context 'SCENARIO 4 - CHECK_03 FAIL (pas d IP)' {
        BeforeEach {
            Mock -CommandName Invoke-VMScript -MockWith { throw 'tools failure' }
            Mock -CommandName Get-VMGuest -MockWith {
                [pscustomobject]@{ IPAddress = $null }
            }
        }

        It 'returns exit code 2' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-4'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 2
        }
    }

    Context 'SCENARIO 5 - UEFI + Hardware warning' {
        BeforeEach {
            Mock -CommandName Get-VM -MockWith {
                [pscustomobject]@{
                    Name = 'TEST-VM'
                    NumCpu = 4
                    MemoryMB = 8192
                    PowerState = 'PoweredOn'
                    HardwareVersion = 'vmx-10'
                    Guest = [pscustomobject]@{
                        ToolsVersion = '12345'
                        GuestFullName = 'Microsoft Windows Server 2019 (64-bit)'
                    }
                    ExtensionData = [pscustomobject]@{
                        Config = [pscustomobject]@{
                            Firmware = 'efi'
                            BootOptions = [pscustomobject]@{ EfiSecureBootEnabled = $true }
                        }
                    }
                }
            }
        }

        It 'returns exit code 0 and WARNING status' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-5'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 0

            $manifest = Get-Content -Path (Join-Path $outDir 'manifest-TEST-VM.json') -Raw | ConvertFrom-Json
            $manifest.overall_status | Should -Be 'WARNING'
            ($manifest.checks | Where-Object { $_.check_id -eq 'CHECK_04' }).status | Should -Be 'WARN'
        }
    }

    Context 'SCENARIO 6 - IP fallback VMware Tools (WARN)' {
        BeforeEach {
            Mock -CommandName Invoke-VMScript -MockWith { throw 'invoke failed' }
            Mock -CommandName Get-VMGuest -MockWith {
                [pscustomobject]@{ IPAddress = @('192.168.1.10') }
            }
        }

        It 'returns exit code 0 and fallback source' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-6'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 0

            $manifest = Get-Content -Path (Join-Path $outDir 'manifest-TEST-VM.json') -Raw | ConvertFrom-Json
            ($manifest.checks | Where-Object { $_.check_id -eq 'CHECK_03' }).status | Should -Be 'WARN'
            $manifest.guest_network[0].source | Should -Be 'vmware-tools-fallback'
        }
    }

    Context 'SCENARIO 7 - Echec connexion vCenter' {
        BeforeEach {
            Mock -CommandName Connect-VIServer -MockWith { throw 'Connection refused' }
        }

        It 'returns exit code 3' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-7'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 3
        }
    }

    Context 'SCENARIO 8 - Disque > 2 To (WARN)' {
        BeforeEach {
            Mock -CommandName Get-HardDisk -MockWith {
                @(
                    [pscustomobject]@{
                        Name = 'Hard disk 1'
                        CapacityGB = 3000
                        Filename = 'C:\Fake\disk-big.vmdk'
                        Parent = [pscustomobject]@{
                            ExtensionData = [pscustomobject]@{
                                Config = [pscustomobject]@{
                                    Hardware = [pscustomobject]@{ Device = @() }
                                }
                            }
                        }
                        ExtensionData = [pscustomobject]@{
                            ControllerKey = 1000
                            Backing = [pscustomobject]@{
                                ThinProvisioned = $true
                                EagerlyScrub = $false
                                Sharing = 'sharingNone'
                                PSTypeName = 'VirtualDiskFlatVer2BackingInfo'
                            }
                        }
                    }
                )
            }
        }

        It 'marks CHECK_06 as WARN' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-8'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 0

            $manifest = Get-Content -Path (Join-Path $outDir 'manifest-TEST-VM.json') -Raw | ConvertFrom-Json
            ($manifest.checks | Where-Object { $_.check_id -eq 'CHECK_06' }).status | Should -Be 'WARN'
        }
    }

    Context 'SCENARIO 9 - NIC non VMXNET3 (WARN)' {
        BeforeEach {
            Mock -CommandName Get-NetworkAdapter -MockWith {
                @(
                    [pscustomobject]@{
                        Name = 'Network adapter 1'
                        NetworkName = 'VLAN-Prod'
                        MacAddress = '00:50:56:AA:BB:CC'
                        Type = 'E1000e'
                        ConnectionState = [pscustomobject]@{ StartConnected = $true }
                        ExtensionData = [pscustomobject]@{ }
                    }
                )
            }
        }

        It 'marks CHECK_07 as WARN' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-9'
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -Force
            $LASTEXITCODE | Should -Be 0

            $manifest = Get-Content -Path (Join-Path $outDir 'manifest-TEST-VM.json') -Raw | ConvertFrom-Json
            ($manifest.checks | Where-Object { $_.check_id -eq 'CHECK_07' }).status | Should -Be 'WARN'
        }
    }

    Context 'SCENARIO 10 - Manifest deja existant sans -Force' {
        It 'uses ShouldProcess and avoids overwrite when denied' {
            $outDir = Join-Path -Path $TestDrive -ChildPath 'manifests-10'
            New-Item -Path $outDir -ItemType Directory -Force | Out-Null
            $existing = Join-Path -Path $outDir -ChildPath 'manifest-TEST-VM.json'
            Set-Content -Path $existing -Value '{"seed":true}'

            # Simulate user invoking WhatIf behavior to exercise ShouldProcess flow.
            & $scriptUnderTest -VMName 'TEST-VM' -OutputDir $outDir -WhatIf
            $LASTEXITCODE | Should -Be 0

            (Get-Content -Path $existing -Raw) | Should -Match 'seed'
        }
    }
}
