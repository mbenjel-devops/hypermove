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

```powershell
Invoke-Pester -Path .\tests\PRE.Tests.ps1 -Output Detailed
```
