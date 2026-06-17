# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\02-EXEC-Migration.ps1'

    # Extract the pure helpers via the AST; the script body performs live
    # conversion/Hyper-V work at top-level and must not run during unit tests.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$parseErrors)
    $wanted = @('Get-StarWindExe', 'Invoke-Conversion')
    $funcDefs = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    ) | Where-Object { $wanted -contains $_.Name }
    $combined = ($funcDefs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    . ([scriptblock]::Create($combined))
}

Describe '02-EXEC-Migration.ps1' {
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
        $cmd.Parameters.Keys | Should -Contain 'VMName'
        $cmd.Parameters.Keys | Should -Contain 'ManifestPath'
    }

    Context 'Invoke-Conversion error handling' {
        It 'throws when the StarWind converter is not installed' {
            # Force the "not found" path deterministically across environments.
            function Get-StarWindExe { $null }
            $src = Join-Path -Path $TestDrive -ChildPath 'src.vmdk'
            $dst = Join-Path -Path $TestDrive -ChildPath 'dst.vhdx'
            $log = Join-Path -Path $TestDrive -ChildPath 'conv.log'
            'x' | Set-Content -Path $src -Encoding UTF8
            { Invoke-Conversion -Source $src -Destination $dst -Tool 'StarWindV2V' -LogPath $log } |
                Should -Throw '*StarWind*not found*'
        }
    }
}
