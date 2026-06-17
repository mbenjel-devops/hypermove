<#
.SYNOPSIS
Generate an HTML summary from migration manifests and optional audit events.

.DESCRIPTION
Provides `Generate-MigrationHtmlReport` which aggregates manifest files
(manifest-*.json) into a single HTML report with a VM table and optional
recent audit events (JSONL). The script contains only functions and does not
execute any pipeline logic at top-level so it is safe to dot-source from tests.

.PARAMETER ManifestPaths
Array of explicit manifest file paths.

.PARAMETER ManifestsDir
Directory containing manifest-*.json files.

.PARAMETER AuditFile
Optional audit JSONL file (one JSON object per line) to include recent events.

.PARAMETER OutputPath
Path to the generated HTML file. Defaults to ./migration-summary.html

.PARAMETER Overwrite
If set, overwrite an existing output file.
#>

function Generate-MigrationHtmlReport {
    [CmdletBinding()]
    param(
        [string[]]$ManifestPaths,
        [string]$ManifestsDir,
        [string]$AuditFile,
        [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'migration-summary.html'),
        [switch]$Overwrite
    )

    # Resolve manifest files
    if ($ManifestPaths -and $ManifestPaths.Count -gt 0) {
        $files = @()
        foreach ($p in $ManifestPaths) {
            if (-not (Test-Path -Path $p)) { throw "Manifest path not found: $p" }
            $files += (Get-Item -Path $p).FullName
        }
    }
    elseif ($ManifestsDir) {
        if (-not (Test-Path -Path $ManifestsDir)) { throw "Manifests directory not found: $ManifestsDir" }
        $files = Get-ChildItem -Path $ManifestsDir -Filter 'manifest-*.json' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }
    else {
        throw 'Either ManifestPaths or ManifestsDir must be provided.'
    }

    if (-not $files -or $files.Count -eq 0) { throw 'No manifests found.' }

    $vms = @()
    foreach ($f in $files) {
        try {
            $m = Get-Content -Path $f -Raw | ConvertFrom-Json
        }
        catch {
            # Skip broken manifests but continue
            continue
        }

        $vmName = if ($m.source -and $m.source.vm_name) { $m.source.vm_name } elseif ($m.vm_name) { $m.vm_name } else { [System.IO.Path]::GetFileNameWithoutExtension($f) -replace '^manifest-','' }
        $status = if ($m.overall_status) { $m.overall_status } elseif ($m.overallStatus) { $m.overallStatus } else { 'UNKNOWN' }
        $checks = if ($m.checks) { ($m.checks).Count } else { 0 }
        $vms += [pscustomobject]@{
            name = $vmName
            status = $status
            checks = $checks
            migration_id = $m.migration_id
            path = $f
        }
    }

    $counts = @{}
    foreach ($x in $vms) {
        if (-not $counts.ContainsKey($x.status)) { $counts[$x.status] = 0 }
        $counts[$x.status]++
    }
    $total = $vms.Count

    $now = Get-Date -Format 'u'

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("<!doctype html>")
    $null = $sb.AppendLine("<html>")
    $null = $sb.AppendLine("<head><meta charset='utf-8'><title>Migration Summary</title>")
    $null = $sb.AppendLine("<style>body{font-family:Segoe UI,Arial;margin:16px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:8px;text-align:left}th{background:#f3f3f3}thead th{position:sticky;top:0;background:#f3f3f3}</style>")
    $null = $sb.AppendLine("</head>")
    $null = $sb.AppendLine("<body>")
    $null = $sb.AppendLine(("<h1>Migration Summary</h1>"))
    $null = $sb.AppendLine(("<p>Generated at: {0}</p>" -f $now))
    $null = $sb.AppendLine(("<p>Total VMs: {0}</p>" -f $total))

    $null = $sb.AppendLine('<ul>')
    foreach ($k in $counts.Keys) {
        $null = $sb.AppendLine(("<li>{0}: {1}</li>" -f [System.Net.WebUtility]::HtmlEncode($k), $counts[$k]))
    }
    $null = $sb.AppendLine('</ul>')

    $null = $sb.AppendLine('<table>')
    $null = $sb.AppendLine('<thead><tr><th>VM</th><th>Status</th><th>Checks</th><th>Manifest</th></tr></thead>')
    $null = $sb.AppendLine('<tbody>')
    foreach ($vm in $vms) {
        $nameEnc = [System.Net.WebUtility]::HtmlEncode($vm.name)
        $statusEnc = [System.Net.WebUtility]::HtmlEncode($vm.status)
        $pathEnc = [System.Net.WebUtility]::HtmlEncode((Split-Path $vm.path -Leaf))
        $null = $sb.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>" -f $nameEnc, $statusEnc, $vm.checks, $pathEnc))
    }
    $null = $sb.AppendLine('</tbody>')
    $null = $sb.AppendLine('</table>')

    if ($AuditFile -and (Test-Path -Path $AuditFile)) {
        try {
            $lines = Get-Content -Path $AuditFile -ErrorAction Stop
            if ($lines -and $lines.Count -gt 0) {
                $last = $lines | Select-Object -Last 20
                $encoded = [System.Net.WebUtility]::HtmlEncode(($last -join "`n"))
                $null = $sb.AppendLine('<h2>Recent events</h2>')
                $null = $sb.AppendLine(("<pre>{0}</pre>" -f $encoded))
            }
        }
        catch { }
    }

    $null = $sb.AppendLine('</body>')
    $null = $sb.AppendLine('</html>')

    if ((Test-Path -Path $OutputPath) -and -not $Overwrite) {
        throw "Output file exists: $OutputPath (use -Overwrite)"
    }

    Set-Content -Path $OutputPath -Value $sb.ToString() -Encoding UTF8

    return [pscustomobject]@{
        OutputPath = (Get-Item -Path $OutputPath).FullName
        Total = $total
        Counts = $counts
    }
}
