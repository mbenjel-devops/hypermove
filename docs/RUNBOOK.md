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

Create C:\Migration\config.json and set output_dir/report_dir/log_dir paths.

## 4. Run phases manually

```powershell
.\src\01-PRE-Discovery.ps1 -VMName "SRVWEB01" -OutputDir "C:\Migration\Manifests" -Force
.\src\02-EXEC-Migration.ps1 -VMName "SRVWEB01" -ManifestPath "C:\Migration\Manifests\manifest-SRVWEB01.json"
.\src\03-POST-Validation.ps1 -VMName "SRVWEB01" -ManifestPath "C:\Migration\Manifests\manifest-SRVWEB01.json"
```

## 5. Run full pipeline

```powershell
.\src\00-Orchestrator.ps1 -VMName "SRVWEB01" -Mode SINGLE -Phase FULL -AutoRollback -RestoreSourceOnFail
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
