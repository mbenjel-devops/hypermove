# Runbook

## 1. Install prerequisites

```powershell
winget install Microsoft.PowerShell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
Install-Module -Name Pester -Force -SkipPublisherCheck
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell
```

## 2. Configure environment

Populate variables based on .env.example:

- VCENTER_HOST
- VCENTER_USER
- VCENTER_PASS
- HYPERV_HOST
- HYPERV_VM_PATH
- HYPERV_VHDX_PATH
- HYPERV_SWITCH

## 3. Create config file

Copy config.example.json to C:\Migration\config.json and set the values
(vcenter_host, hyperv_host, hyperv_vm_path, hyperv_vhdx_path, hyperv_switch,
output_dir, report_dir, log_dir, conversion_tool, critical_services).

## 3.b Pre-flight readiness check (run first on every new worker)

```powershell
.\src\00-Preflight.ps1 -ConfigFile "C:\Migration\config.json" -TestConnections
```

Interpret the result:

- READY (exit 0): environment is good to go.
- WARNING (exit 3): advisories only; review remediation hints, then proceed.
- BLOCKED (exit 2): fix every FAIL item (shown with a "Fix:" hint) before migrating.

A JSON report is written to the configured report_dir for audit.

## 3.c Interactive launcher (recommended for technicians)

```powershell
.\Start-Migration.ps1
```

Follow the menu: option 1 runs pre-flight; options 2-6 cover discovery, full
migration, batch, post-validation and rollback with guided prompts.

## 4. Run phases manually

```powershell
.\src\01-PRE-Discovery.ps1 -VMName "SRVWEB01" -OutputDir "C:\Migration\Manifests" -Force
.\src\02-EXEC-Migration.ps1 -VMName "SRVWEB01" -ManifestPath "C:\Migration\Manifests\manifest-SRVWEB01.json"
.\src\03-POST-Validation.ps1 -VMName "SRVWEB01" -ManifestPath "C:\Migration\Manifests\manifest-SRVWEB01.json"
```

Handling problem VMs during PRE:

```powershell
# Forgotten snapshots: consolidate them first (you will be asked to confirm)
.\src\01-PRE-Discovery.ps1 -VMName "SRVWEB01" -RemoveSnapshots -Force

# Legacy OS (2000/2003/2008/2008 R2): proceed with explicit, audited approval
.\src\01-PRE-Discovery.ps1 -VMName "SRVOLD01" -ApproveLegacyOS -Force
```

## 5. Run full pipeline

```powershell
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -Mode SINGLE -Phase FULL -RunPreflight -AutoRollback -RestoreSourceOnFail
```

## 5.b Run in batch mode (multiple VMs)

Create a CSV file with at least a VMName column, for example:

```csv
VMName
SRVWEB01
SRVAPP02
```

Then run:

```powershell
.\src\00-Orchestrator.ps1 -Mode BATCH -VMListPath ".\docs\vm-list.example.csv" -Phase FULL -AutoRollback -ContinueOnError -MaxExecRetries 3 -RetryWaitSeconds 300
```

Alternative: run with a direct list:

```powershell
.\src\00-Orchestrator.ps1 -Mode BATCH -VMNames "SRVWEB01","SRVAPP02" -Phase FULL -ContinueOnError
```

Process all VMs from generated manifests:

```powershell
.\src\00-Orchestrator.ps1 -Mode FROM_MANIFESTS -Phase POST
```

## 6. Rollback manually

```powershell
.\src\04-ROLLBACK.ps1 -VMName "SRVWEB01" -RollbackScope Full -Force -RestoreSourceVM
```

## 7. Run tests

Run the whole suite (recommended before any change is committed):

```powershell
.\tests\Invoke-Tests.ps1
```

Run a single file with detailed output:

```powershell
Invoke-Pester -Path .\tests\PRE.Tests.ps1 -Output Detailed
```

> The suite requires Pester 5+. If `Install-Module -Name Pester -Force -SkipPublisherCheck`
> fails without admin rights (NuGet provider bootstrap), install side-by-side instead:
> `Save-Module -Name Pester -Path "$env:LOCALAPPDATA\PesterLocal"` then
> `Import-Module "$env:LOCALAPPDATA\PesterLocal\Pester\<version>\Pester.psd1" -Force`.

## 8. Exit code reference

Every phase script returns a deterministic exit code. The orchestrator records
them per VM in its JSON summary and uses them to drive auto-rollback.

### PRE (`01-PRE-Discovery.ps1`)

| Code | Meaning | Operator action |
|------|---------|-----------------|
| 0 | READY or WARNING — manifest generated | Proceed to EXEC |
| 1 | Unexpected error | Read the log, fix, retry |
| 2 | Blocking check failed (snapshot / RDM / no guest IP / legacy OS) | Remediate the flagged item; use `-RemoveSnapshots` or `-ApproveLegacyOS` if appropriate |
| 3 | vCenter connection failed | Check `VCENTER_HOST`/credentials/network |

### EXEC (`02-EXEC-Migration.ps1`)

| Code | Meaning | Operator action |
|------|---------|-----------------|
| 0 | Migration succeeded | Proceed to POST |
| 1 | Unexpected error | Read the log, retry |
| 2 | Manifest missing / BLOCKED / unsupported schema | Re-run PRE, verify manifest |
| 3 | Incomplete Hyper-V target settings (host/path/switch) | Fix config / env variables |
| 4 | No disk was converted | Check converter tool + source VMDK access |
| 5 | Hyper-V VM creation / disk attach failed | Inspect Hyper-V host; rollback recommended |

### POST (`03-POST-Validation.ps1`)

| Code | Meaning | `next_action` | Operator action |
|------|---------|---------------|-----------------|
| 0 | VALIDATED | PROMOTE | Migration usable; promote workload |
| 2 | FAILED (critical) | ROLLBACK | Trigger rollback |
| 3 | DEGRADED (warnings) | INVESTIGATE | Usable but inspect warnings before promoting |
| 1 | Manifest missing / unexpected error | — | Read the log, retry |

### ROLLBACK (`04-ROLLBACK.ps1`)

| Code | Meaning | Operator action |
|------|---------|-----------------|
| 0 | All rollback actions succeeded (or skipped) | Source restored as requested |
| 1 | At least one rollback action failed | Inspect rollback report; finish manually |

## 9. Enterprise operations

### 9.a Multi-client / multi-infrastructure profiles

Instead of a single `config.json`, load a merged profile
(`config/clients/<Client>/profile.json` over `config/defaults.json`):

```powershell
.\src\00-Orchestrator.ps1 -Client "acme-prod" -ConfigRoot ".\config" -VMName "SRVWEB01" -Mode SINGLE -Phase FULL
```

The client profile always wins over the defaults. Use a different `-Client`
per customer/site so logs, reports and state stay isolated.

### 9.b Validate the configuration before running

```powershell
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -ValidateConfig -Phase FULL
```

The effective configuration is checked against the schema (required fields,
allowed `conversion_tool` values, numeric bounds). The run aborts on any error.

### 9.c Pre-validate target host capacity

```powershell
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -CheckTargetCapacity -Phase FULL
```

CPU / RAM / disk demand from the manifest is compared against the Hyper-V host.
A capacity FAIL (including the +10% disk headroom) aborts EXEC before any change.

### 9.d Resume an interrupted pipeline (idempotence)

Each phase result is persisted per VM. To restart and skip phases that already
completed successfully:

```powershell
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -Resume -Phase FULL
```

State is stored at `<output_dir>\state\<vm-name>.state.json`. To force a clean
re-run, delete that file (or use the module helper `Reset-MigrationState`).

### 9.e Hooks (custom site-specific steps)

Drop scripts into `<hooks_root>\<point>.d\` folders. Hook points:
`pre-pipeline`, `pre-PRE`/`post-PRE`, `pre-EXEC`/`post-EXEC`,
`pre-POST`/`post-POST`, `on-failure`, `post-pipeline`.

- `pre-*` hooks are **blocking**: a non-zero exit aborts the phase.
- `post-*` and `on-failure` hooks are non-blocking (failures are logged only).

```powershell
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -HooksRoot ".\hooks" -Phase FULL
# Disable hooks for a run:
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -SkipHooks -Phase FULL
```

### 9.f Audit events and webhook notifications

When `report_dir` is set, the orchestrator appends a JSONL audit trail to
`<report_dir>\audit\events-YYYYMMDD.jsonl` (pipeline.start/end and per-VM
results). Set `"event_webhook"` in the config to also POST each event to an
external endpoint (Teams/Slack/SIEM). Event emission never blocks the pipeline.

## 10. Where to find artifacts

| Artifact | Location |
|----------|----------|
| Manifests | `output_dir` (e.g. `C:\Migration\Manifests\manifest-<VM>.json`) |
| Phase / orchestrator logs | `log_dir` (e.g. `C:\Migration\Logs\`) |
| POST + preflight reports | `report_dir` |
| Audit events | `<report_dir>\audit\events-YYYYMMDD.jsonl` |
| Resume state | `<output_dir>\state\<VM>.state.json` |

## 11. Recommended day-of-migration sequence

1. Run pre-flight on the worker: `00-Preflight.ps1 -TestConnections` → expect READY.
2. Discover the VM: `01-PRE-Discovery.ps1` → expect manifest with `READY` (or `WARNING`).
3. Resolve any blocking PRE item (exit 2) before continuing.
4. Run the full pipeline with safety nets:
   ```powershell
   .\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -Mode SINGLE -Phase FULL `
       -RunPreflight -ValidateConfig -CheckTargetCapacity `
       -AutoRollback -RestoreSourceOnFail
   ```
5. Read the orchestrator JSON summary and the POST `next_action`
   (PROMOTE / INVESTIGATE / ROLLBACK).
6. If interrupted, re-run with `-Resume` to continue where it stopped.

## 12. Troubleshooting

| Symptom | Likely cause | Resolution |
|---------|-------------|------------|
| PRE exit 3 | vCenter unreachable / bad credentials | Verify `VCENTER_HOST`, `VCENTER_USER`, `VCENTER_PASS`, firewall |
| PRE exit 2 "Snapshots" | Forgotten snapshots | Re-run with `-RemoveSnapshots` (consolidates after confirmation) |
| PRE exit 2 "Legacy OS" | Unsupported guest OS | Re-run with `-ApproveLegacyOS` only after sign-off |
| EXEC exit 3 | Missing Hyper-V target settings | Set `hyperv_host`/`hyperv_vm_path`/`hyperv_vhdx_path`/`hyperv_switch` |
| EXEC exit 4 | Converter not found / source unreadable | Install the converter; check `conversion_tool`; verify VMDK access |
| EXEC exit 5 | Hyper-V creation/attach failure | Inspect Hyper-V host; run `04-ROLLBACK.ps1` |
| POST exit 2 (FAILED) | Critical validation failed | Trigger rollback (auto with `-AutoRollback`) |
| POST exit 3 (DEGRADED) | Non-critical warnings | Investigate report before promoting |
| Orchestrator aborts "module missing" | PowerCLI / Hyper-V not installed | Install modules, or use `-SkipPrereqChecks` for dry runs only |
| Interactive password prompt in automation | `VCENTER_PASS` not set | Export the env variable before running |

