# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\04-ROLLBACK.ps1'

    # Extract the pure helper via the AST (the script body performs rollback work
    # at top-level and must not run during unit tests).
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$parseErrors)
    $funcDef = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    ) | Where-Object { $_.Name -eq 'Add-ActionResult' } | Select-Object -First 1
    . ([scriptblock]::Create($funcDef.Extent.Text))
}

Describe '04-ROLLBACK.ps1' {

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
            foreach ($p in @('VMName', 'ManifestPath', 'RollbackScope', 'Force', 'RestoreSourceVM')) {
                $cmd.Parameters.Keys | Should -Contain $p
            }
        }

        It 'restricts RollbackScope to the supported set' {
            $cmd = Get-Command -Name $scriptUnderTest -CommandType ExternalScript
            $validate = $cmd.Parameters['RollbackScope'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validate.ValidValues | Should -Contain 'Full'
            $validate.ValidValues | Should -Contain 'HyperVOnly'
            $validate.ValidValues | Should -Contain 'TempFiles'
            $validate.ValidValues | Should -Contain 'SourceVM'
        }
    }

    Context 'Add-ActionResult' {
        BeforeEach {
            $script:actions = New-Object System.Collections.Generic.List[object]
            $script:anyFailed = $false
        }

        It 'records an action with the expected shape' {
            Add-ActionResult -Action 'delete-hyperv-vm' -Status 'SUCCESS' -Detail 'removed'
            $script:actions.Count | Should -Be 1
            $entry = $script:actions[0]
            $entry.action | Should -Be 'delete-hyperv-vm'
            $entry.status | Should -Be 'SUCCESS'
            $entry.detail | Should -Be 'removed'
            $entry.timestamp | Should -Not -BeNullOrEmpty
        }

        It 'flags anyFailed when an action fails' {
            Add-ActionResult -Action 'remove-temp' -Status 'FAILED' -Detail 'locked'
            $script:anyFailed | Should -BeTrue
        }

        It 'does not flag anyFailed for skipped actions' {
            Add-ActionResult -Action 'restore-source' -Status 'SKIPPED' -Detail 'not requested'
            $script:anyFailed | Should -BeFalse
        }

        It 'accumulates multiple actions in order' {
            Add-ActionResult -Action 'a' -Status 'SUCCESS' -Detail '1'
            Add-ActionResult -Action 'b' -Status 'SKIPPED' -Detail '2'
            $script:actions.Count | Should -Be 2
            $script:actions[0].action | Should -Be 'a'
            $script:actions[1].action | Should -Be 'b'
        }
    }
}
