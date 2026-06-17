# Requires -Version 7.2
# Requires -Modules Pester

Set-StrictMode -Version 2.0

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $here
    $scriptUnderTest = Join-Path -Path $projectRoot -ChildPath 'src\05-Report-Generator.ps1'

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptUnderTest, [ref]$tokens, [ref]$parseErrors)
    $funcDef = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -eq 'Generate-MigrationHtmlReport' } | Select-Object -First 1
    . ([scriptblock]::Create($funcDef.Extent.Text))
}

Describe '05-Report-Generator.ps1' {
    Context 'Generate-MigrationHtmlReport' {
        It 'throws when no inputs provided' {
            { Generate-MigrationHtmlReport } | Should -Throw
        }

        It 'throws when manifests dir missing' {
            $d = Join-Path -Path $TestDrive -ChildPath 'no-manifests'
            { Generate-MigrationHtmlReport -ManifestsDir $d } | Should -Throw '*not found*'
        }

        It 'generates a small HTML from manifests' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'manfs'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $m1 = [ordered]@{ schema_version='1.0'; overall_status='READY'; source=[ordered]@{ vm_name='A' }; migration_id = [guid]::NewGuid().Guid }
            $m2 = [ordered]@{ schema_version='1.0'; overall_status='WARNING'; source=[ordered]@{ vm_name='B' }; migration_id = [guid]::NewGuid().Guid }
            $m1 | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir 'manifest-A.json') -Encoding UTF8
            $m2 | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir 'manifest-B.json') -Encoding UTF8

            $out = Join-Path -Path $TestDrive -ChildPath 'sum.html'
            $res = Generate-MigrationHtmlReport -ManifestsDir $dir -OutputPath $out -Overwrite
            $res.Total | Should -Be 2
            (Test-Path -Path $res.OutputPath) | Should -BeTrue
            (Get-Content -Path $res.OutputPath -Raw) | Should -Match 'Migration Summary'
        }

        It 'includes recent audit events when provided' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'manfs2'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $m = [ordered]@{ schema_version='1.0'; overall_status='READY'; source=[ordered]@{ vm_name='C' }; migration_id = [guid]::NewGuid().Guid }
            $m | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir 'manifest-C.json') -Encoding UTF8
            $audit = Join-Path -Path $TestDrive -ChildPath 'audit.jsonl'
            '{"event":"pipeline.start","pipeline_id":"x"}' | Set-Content -Path $audit -Encoding UTF8

            $out = Join-Path -Path $TestDrive -ChildPath 'sum2.html'
            $res = Generate-MigrationHtmlReport -ManifestsDir $dir -AuditFile $audit -OutputPath $out -Overwrite
            $res.Total | Should -Be 1
            (Get-Content -Path $res.OutputPath -Raw) | Should -Match 'Recent events'
        }
    }
}
