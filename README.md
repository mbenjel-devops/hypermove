# VMware-HyperV-Migration

Pipeline PowerShell de migration VMware vers Hyper-V, structuré en 4 phases + orchestrateur.

## Structure

- Start-Migration.ps1 (interactive launcher / menu for technicians)
- config.example.json (copy to your config path and edit)
- config/defaults.json + config/clients/<client>/profile.json (multi-client profiles)
- config/clients/<client>/hooks/ (pre/post hook scripts)
- src/00-Orchestrator.ps1
- src/00-Preflight.ps1 (readiness / doctor check)
- src/MigrationCommon.psm1 (profiles, hooks, secrets)
- src/01-PRE-Discovery.ps1
- src/02-EXEC-Migration.ps1
- src/03-POST-Validation.ps1
- src/04-ROLLBACK.ps1
- tests/PRE.Tests.ps1
- tests/EXEC.Tests.ps1
- tests/POST.Tests.ps1
- tests/MigrationCommon.Tests.ps1
- .github/workflows/ci.yml (syntax + Pester CI)

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

## Enterprise: multi-client, hooks, secrets

### Multi-client profiles

Run the same toolkit against many clients/infrastructures without editing the core.
Configuration lives under `config/`:

```
config/
  defaults.json                     # shared defaults
  clients/
    <client>/profile.json           # per-client overrides (merged over defaults)
    <client>/hooks/                 # per-client hook scripts
```

```powershell
# Use a client profile instead of a single config file
.\src\00-Orchestrator.ps1 -Client "example-client" -Mode SINGLE -VMName "SRV01" -Phase FULL
```

The effective config is `defaults.json` deep-merged with the client `profile.json`
(profile wins). Manifests/reports/logs paths can be isolated per client.

### Pre/post hook framework

Plug custom scripts and integrate with external systems at defined points, without
touching the pipeline. Hooks are `*.ps1` files inside `<hook>.d` folders, run in
alphabetical order:

| Hook point | When | Blocking |
|------------|------|----------|
| `pre-pipeline` | once before any VM | yes |
| `pre-PRE` / `post-PRE` | around discovery | pre only |
| `pre-EXEC` / `post-EXEC` | around conversion | pre only |
| `pre-POST` / `post-POST` | around validation | pre only |
| `on-failure` | a VM failed/rolled back | no |
| `post-pipeline` | once after all VMs | no |

Each hook receives a JSON context (VM, client, phase, manifest path) via a
`-ContextPath` parameter and the `MIG_HOOK_CONTEXT_PATH` environment variable. A
non-zero exit from a `pre-*` hook aborts that phase; `post-*` / `on-failure` failures
are logged but non-blocking. See `config/clients/example-client/hooks/` for samples
(backup gate, notification). Disable with `-SkipHooks`.

### Secrets

Values shaped `secret://<Vault>/<Name>` in a profile are resolved at load time via
`Microsoft.PowerShell.SecretManagement`. Store credentials in a registered vault and
reference them instead of hard-coding. Example: `"vcenter_pass": "secret://MigrationVault/clientA-vcenter"`.

## Enterprise: operational robustness

### Configuration validation

Validate the effective config against a schema before any work runs. Catches missing
or malformed fields and unknown `conversion_tool` values early:

```powershell
.\src\00-Orchestrator.ps1 -Client "example-client" -Mode SINGLE -VMName "SRV01" -Phase FULL -ValidateConfig
```

Errors abort the run before touching infrastructure.

### Idempotent resume

Each VM phase result is persisted under `<output_dir>/state/<vm>.state.json`. With
`-Resume`, phases already completed successfully (`PRE`, `EXEC`, `POST`) are skipped,
so a re-run after an interruption continues where it stopped instead of redoing work:

```powershell
.\src\00-Orchestrator.ps1 -Client "example-client" -Mode BATCH -VMListPath .\vms.csv -Phase FULL -Resume
```

### Target capacity pre-check

`-CheckTargetCapacity` compares each VM's manifest requirements (vCPU, RAM, disk) to
the Hyper-V host's available resources before conversion. Insufficient disk
(including a 10% headroom) aborts that VM with exit code 3. Missing Hyper-V access
degrades gracefully to a warning rather than failing.

```powershell
.\src\00-Orchestrator.ps1 -Client "example-client" -Mode SINGLE -VMName "SRV01" -Phase FULL -CheckTargetCapacity
```

### Audit events and webhooks

Pipeline and per-VM events (`pipeline.start`, `vm.success`, `vm.failed`,
`pipeline.end`, ...) are appended to a vendor-neutral audit log at
`<report_dir>/audit/events-YYYYMMDD.jsonl`. Set `"event_webhook"` in the config to
also POST each event as JSON to an external system (SIEM, ITSM, chat). Delivery
failures never interrupt the migration.

## Tests

Local run (requires Pester 5.5+):

```powershell
.\tests\Invoke-Tests.ps1
```

Or directly:

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

CI runs syntax validation + the full Pester suite on every push/PR
(see `.github/workflows/ci.yml`).

## Exit codes summary

- PRE: 0 success/warning, 1 unexpected, 2 blocking check, 3 vCenter connection error
- EXEC: 0 success, 1 unexpected, 2 manifest invalid, 3 connection/settings, 4 conversion, 5 VM creation
- POST: 0 validated, 1 unexpected, 2 rollback recommended, 3 investigate
- ROLLBACK: 0 complete, 1 partial
- ORCHESTRATOR: 0 success, 1 prereq/unexpected, 2 failed/rolled back, 3 partial investigate
