# VMware-HyperV-Migration

Pipeline PowerShell de migration VMware vers Hyper-V, structuré en 4 phases + orchestrateur.

## Structure

- Start-Migration.ps1 (interactive launcher / menu for technicians)
- config.example.json (copy to your config path and edit)
- src/00-Orchestrator.ps1
- src/00-Preflight.ps1 (readiness / doctor check)
- src/01-PRE-Discovery.ps1
- src/02-EXEC-Migration.ps1
- src/03-POST-Validation.ps1
- src/04-ROLLBACK.ps1
- tests/PRE.Tests.ps1
- tests/EXEC.Tests.ps1
- tests/POST.Tests.ps1

## Prerequisites

- Windows Server 2022 worker (recommended)
- PowerShell 7.2+ (compatible 5.1 where possible)
- VMware.PowerCLI module
- Hyper-V PowerShell module
- Pester v5

## Quick start

Easiest path for technicians: use the interactive launcher.

```powershell
.\Start-Migration.ps1
```

The launcher guides you through pre-flight, discovery, full migration, batch, post-validation and rollback.

Manual path:

1. Copy config.example.json to your config path (default C:\Migration\config.json) and edit the values.
2. Configure environment variables from .env.example.
3. Run the pre-flight readiness check on the worker machine:

```powershell
.\src\00-Preflight.ps1 -ConfigFile "C:\Migration\config.json" -TestConnections
```

4. Run PRE phase first on a dev VM:

```powershell
.\src\01-PRE-Discovery.ps1 -VMName "TEST-VM" -OutputDir "C:\Migration\Manifests" -Force
```

5. Run full orchestrated migration (single VM mode):

```powershell
.\src\00-Orchestrator.ps1 -VMName "TEST-VM" -Mode SINGLE -Phase FULL -RunPreflight -AutoRollback -StartVMAfterMigration
```

## Orchestrator modes

- SINGLE: one VM via -VMName
- BATCH: multiple VMs via -VMNames and/or CSV file with VMName column (-VMListPath)
- FROM_MANIFESTS: discovers VMs from manifest-*.json in config.output_dir

### Batch examples

```powershell
# Batch from CSV
.\src\00-Orchestrator.ps1 -Mode BATCH -VMListPath ".\docs\vm-list.example.csv" -Phase FULL -AutoRollback -ContinueOnError

# Batch from explicit list
.\src\00-Orchestrator.ps1 -Mode BATCH -VMNames "SRVWEB01","SRVAPP02" -Phase FULL -ContinueOnError

# Process all existing manifests for POST only
.\src\00-Orchestrator.ps1 -Mode FROM_MANIFESTS -Phase POST
```

### Retry and resilience options

- -RunPreflight: run the readiness check before the pipeline; abort on blocking issues
- -MaxExecRetries: retry EXEC phase for a VM before marking failure
- -RetryWaitSeconds: wait between retries
- -ContinueOnError: in batch modes, continue with next VM after a failure
- -SkipPrereqChecks: skip module/env checks (useful in controlled CI)

## Handling real-world issues

Common field problems and how the toolkit handles them:

- Forgotten snapshots: PRE blocks by default (CHECK_01). Add `-RemoveSnapshots` to PRE to
  consolidate them first (opt-in, prompts via ShouldProcess).
- Legacy guest OS (2000/2003/2008/2008 R2/NT): PRE blocks by default (CHECK_08). Add
  `-ApproveLegacyOS` to proceed with an explicit, audited approval.
- First-run environment gaps (missing modules, env vars, unwritable folders, missing
  conversion tool): run `src\00-Preflight.ps1` (the doctor) to get a clear PASS/WARN/FAIL
  report with remediation hints before migrating.

## Tests

```powershell
Invoke-Pester -Path .\tests\PRE.Tests.ps1 -Output Detailed
```

## Exit codes summary

- PRE: 0 success/warning, 1 unexpected, 2 blocking check, 3 vCenter connection error
- EXEC: 0 success, 1 unexpected, 2 manifest invalid, 3 connection/settings, 4 conversion, 5 VM creation
- POST: 0 validated, 1 unexpected, 2 rollback recommended, 3 investigate
- ROLLBACK: 0 complete, 1 partial
- ORCHESTRATOR: 0 success, 1 prereq/unexpected, 2 failed/rolled back, 3 partial investigate
