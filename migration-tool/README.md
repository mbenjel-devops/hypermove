# Migration Orchestrator

Local migration orchestration tool for VMware to Hyper-V migrations via SCVMM. Runs on a Windows jump server with no cloud dependency.

The operator provides a VM list (CSV). The tool executes pre-defined PowerShell scripts on each VM in order, tracks status in SQLite, and produces a report.

## Requirements

- **Python** 3.10 or later
- **Flask** and **PyYAML** (see `requirements.txt`)
- **PowerShell** 5.1 or later (Windows)
- Network access to vCenter and SCVMM from the jump server

## Installation

```powershell
cd migration-tool
pip install -r requirements.txt
```

## Configuration

Edit `config.yaml` before running:

```yaml
vcenter:
  url: "https://vcenter01.local"
  username: "admin@vsphere.local"
  password: "your-password"

scvmm:
  server: "scvmm01.local"
  username: "DOMAIN\\scvmm-admin"
  password: "your-password"

orchestrator:
  max_retries: 3
  retry_wait_seconds: 300
  vm_timeout_seconds: 28800
  scripts_path: "./scripts"
  log_path: "./logs/migration.log"
  db_path: "./migration.db"
```

Credentials are read by the PowerShell scripts at runtime (when you add real logic). They are **never** written to logs.

## Running

```powershell
python app.py
```

Open **http://127.0.0.1:5000** in a browser on the jump server.

## Workflow

### 1. Prepare the VM list

Create or edit `input/vm_list.csv`:

```csv
VMName,SourceHost,TargetHost,OSVersion,Owner,MaintenanceWindow
VM-PRD-001,vcenter01.local,hyperv01.local,2019,teamA,22:00-06:00
VM-PRD-002,vcenter01.local,hyperv02.local,2008R2,teamB,22:00-06:00
```

VMs with legacy OS versions (2000, 2003, 2008 in `OSVersion`) are automatically marked **excluded** and require manual approval before migration.

### 2. Import and start

1. Click **Import CSV** and select your file.
2. Review the VM table — check status badges and excluded VMs.
3. Click **Approve** on any excluded legacy VM you want to migrate.
4. Click **Start** to begin sequential processing.

### 3. Monitor

- The dashboard auto-refreshes every 5 seconds.
- Use **Pause** to stop after the current VM finishes.
- Use **Stop** to stop after the current script step finishes.
- Click **View Logs** on any VM for its full log history.
- Click **Retry** on failed VMs to re-queue them.

### 4. Report

```powershell
curl http://127.0.0.1:5000/api/report
```

Returns JSON with totals for done, failed, pending, and total duration.

## Execution Order

For each VM (one at a time):

1. `01_pre_migration.ps1`
2. `02_v2v_conversion.ps1`
3. `03_post_migration.ps1`
4. `04_validation.ps1`

Each script receives: `-VMName`, `-SourceHost`, `-TargetHost`, `-OSVersion`.

On failure, the VM is marked with the appropriate status (`pre-failed`, `conv-failed`, `post-failed`) and the orchestrator moves to the next VM. The source VM is never modified by the orchestrator itself.

Conversion failures (`conv-failed`) are retried automatically up to 3 times with a 5-minute wait between attempts.

## Adding Real PowerShell Logic

The scripts in `scripts/` are stubs. Replace the `# TODO` sections with your environment-specific logic:

| Script | Purpose |
|--------|---------|
| `01_pre_migration.ps1` | Pre-checks, snapshots, maintenance window validation |
| `02_v2v_conversion.ps1` | SCVMM `New-SCV2V` or equivalent conversion cmdlet |
| `03_post_migration.ps1` | Integration Services, network, monitoring registration |
| `04_validation.ps1` | Health checks, connectivity, config verification |

Read credentials from `config.yaml` in your scripts if needed:

```powershell
# Example: load config in a script (add as needed)
$configPath = Join-Path (Split-Path $PSScriptRoot -Parent) "config.yaml"
# Parse with ConvertFrom-Yaml or manual regex — or pass via env vars from Python
```

Keep stub `Start-Sleep` and `exit 0` behavior until real logic is ready. Return a non-zero exit code on failure so the orchestrator records the correct status.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Web UI |
| GET | `/api/vms` | List all VMs |
| GET | `/api/vms/<vm_name>` | VM detail + logs |
| POST | `/api/import` | Import CSV (multipart file or raw body) |
| POST | `/api/start` | Start orchestrator (background thread) |
| POST | `/api/pause` | Pause after current VM |
| POST | `/api/stop` | Stop after current step |
| POST | `/api/vm/<vm_name>/approve` | Approve excluded legacy VM |
| POST | `/api/vm/<vm_name>/retry` | Re-queue failed VM |
| GET | `/api/status` | Orchestrator state |
| GET | `/api/report` | JSON summary report |

## Safety

- Source VMs are never touched by the orchestrator after pre-migration starts unless a script explicitly does so.
- Pause and Stop wait for the current step/VM to finish cleanly.
- All database writes are transactional.
- Config credentials are never logged.
- Every script execution is logged with timestamp, VM name, step, and exit code.
- Duplicate VM names in a CSV import are rejected.

## Project Layout

```
migration-tool/
├── app.py
├── orchestrator.py
├── config.yaml
├── requirements.txt
├── migration.db          # auto-created on first run
├── scripts/
├── templates/
├── logs/
└── input/
```
