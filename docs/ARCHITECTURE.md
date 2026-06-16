# Architecture

## Overview

The migration workflow is split into deterministic phases:

1. PRE discovery
2. EXEC conversion/import
3. POST validation/reporting
4. ROLLBACK cleanup/recovery

An orchestrator drives the phases and applies transition logic by exit code.

## Data Flow

- Input: VMName + environment/config settings
- PRE output: manifests/manifest-<VMName>.json
- EXEC input: PRE manifest
- EXEC output: updated manifest with exec_result
- POST input: updated manifest
- POST output: reports/report-*.json and report-*.txt
- ROLLBACK output: incident-*.json
- ORCHESTRATOR output: pipeline-summary-*.json and centralized logs

## Key Design Points

- Idempotent behavior where possible
- Explicit exit-code contract between phases
- Non-blocking rollback operations with per-action status tracking
- Structured logging with timestamp, level, and phase name
- Compatibility target: PowerShell 5.1 and 7.2+
