# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\03-POST-Validation.ps1'
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
}
