# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\03-POST-Validation.ps1'

    # Extract pure helpers via the AST; the script body performs live validation
    # at top-level and must not run during unit tests.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$parseErrors)
    $wanted = @('Convert-BytesToGb', 'Get-PingLatency')
    $funcDefs = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    ) | Where-Object { $wanted -contains $_.Name }
    $combined = ($funcDefs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    . ([scriptblock]::Create($combined))
}

Describe '03-POST-Validation.ps1' {
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

    Context 'Convert-BytesToGb' {
        It 'converts exactly one gigabyte' {
            Convert-BytesToGb -Bytes 1GB | Should -Be 1
        }

        It 'rounds to two decimals' {
            Convert-BytesToGb -Bytes ([UInt64](1.5 * 1GB)) | Should -Be 1.5
        }

        It 'returns zero for zero bytes' {
            Convert-BytesToGb -Bytes 0 | Should -Be 0
        }
    }

    Context 'Get-PingLatency' {
        It 'returns the rounded average response time' {
            Mock -CommandName Test-Connection -MockWith {
                @(
                    [pscustomobject]@{ ResponseTime = 10 },
                    [pscustomobject]@{ ResponseTime = 20 },
                    [pscustomobject]@{ ResponseTime = 30 },
                    [pscustomobject]@{ ResponseTime = 40 }
                )
            }
            Get-PingLatency -Target '10.0.0.10' | Should -Be 25
        }

        It 'returns null when the target is unreachable' {
            Mock -CommandName Test-Connection -MockWith { throw 'unreachable' }
            Get-PingLatency -Target '10.0.0.254' | Should -Be $null
        }
    }
}
