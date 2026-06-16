"""Core migration execution engine."""

import csv
import io
import os
import re
import sqlite3
import subprocess
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

STEPS = [
    ("01_pre_migration.ps1", "pre-migration", "pre-failed"),
    ("02_v2v_conversion.ps1", "v2v-conversion", "conv-failed"),
    ("03_post_migration.ps1", "post-migration", "post-failed"),
    ("04_validation.ps1", "validation", "post-failed"),
]

LEGACY_OS_PATTERNS = ("2000", "2003", "2008")

STATUSES_DONE = {"done"}
STATUSES_FAILED = {"pre-failed", "conv-failed", "post-failed", "rolled-back"}
STATUSES_SKIP = STATUSES_DONE | {"excluded"}


class Orchestrator:
    def __init__(self, config_path: str = "config.yaml"):
        self.config_path = os.path.abspath(config_path)
        self.base_dir = os.path.dirname(self.config_path)
        self.config = self._load_config()
        self._resolve_paths()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._state = "idle"
        self._pause_requested = False
        self._stop_requested = False
        self._current_vm: str | None = None
        self._current_step: str | None = None
        self._ensure_dirs()
        self.init_db()

    def _load_config(self) -> dict:
        with open(self.config_path, encoding="utf-8") as f:
            return yaml.safe_load(f)

    def _resolve_paths(self) -> None:
        orch = self.config["orchestrator"]
        for key in ("scripts_path", "log_path", "db_path"):
            value = orch[key]
            if not os.path.isabs(value):
                orch[key] = os.path.normpath(os.path.join(self.base_dir, value))

    def _ensure_dirs(self) -> None:
        log_path = Path(self.config["orchestrator"]["log_path"])
        log_path.parent.mkdir(parents=True, exist_ok=True)

    @property
    def db_path(self) -> str:
        return self.config["orchestrator"]["db_path"]

    @property
    def log_path(self) -> str:
        return self.config["orchestrator"]["log_path"]

    @contextmanager
    def _db(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def init_db(self) -> None:
        with self._db() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS vms (
                    id INTEGER PRIMARY KEY,
                    vm_name TEXT UNIQUE NOT NULL,
                    source_host TEXT,
                    target_host TEXT,
                    os_version TEXT,
                    owner TEXT,
                    maintenance_window TEXT,
                    status TEXT DEFAULT 'pending',
                    current_step TEXT,
                    retry_count INTEGER DEFAULT 0,
                    started_at DATETIME,
                    finished_at DATETIME,
                    duration_seconds INTEGER,
                    error_message TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )

    def get_state(self) -> dict:
        with self._lock:
            return {
                "state": self._state,
                "current_vm": self._current_vm,
                "current_step": self._current_step,
                "pause_requested": self._pause_requested,
                "stop_requested": self._stop_requested,
            }

    def _set_state(self, state: str) -> None:
        with self._lock:
            self._state = state

    def _is_legacy_os(self, os_version: str) -> bool:
        return any(p in os_version for p in LEGACY_OS_PATTERNS)

    def _now_iso(self) -> str:
        return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    def _write_log(
        self,
        vm_name: str,
        step: str,
        stdout: str,
        stderr: str,
        exit_code: int | None = None,
    ) -> None:
        ts = self._now_iso()
        parts = [f"[{ts}] VM={vm_name} Step={step}"]
        if exit_code is not None:
            parts.append(f"ExitCode={exit_code}")
        if stdout.strip():
            parts.append(f"STDOUT:\n{stdout.strip()}")
        if stderr.strip():
            parts.append(f"STDERR:\n{stderr.strip()}")
        line = " | ".join(parts) + "\n"
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(line)

    def _write_system_log(self, message: str) -> None:
        ts = self._now_iso()
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(f"[{ts}] SYSTEM: {message}\n")

    def import_csv(self, csv_content: str) -> dict:
        reader = csv.DictReader(io.StringIO(csv_content))
        required = {
            "VMName",
            "SourceHost",
            "TargetHost",
            "OSVersion",
            "Owner",
            "MaintenanceWindow",
        }
        if not reader.fieldnames or not required.issubset(set(reader.fieldnames)):
            missing = required - set(reader.fieldnames or [])
            return {"success": False, "error": f"Missing CSV columns: {', '.join(sorted(missing))}"}

        rows = list(reader)
        names = [r["VMName"].strip() for r in rows if r.get("VMName", "").strip()]
        if not names:
            return {"success": False, "error": "CSV contains no VM rows"}

        seen: set[str] = set()
        duplicates: list[str] = []
        for name in names:
            if name in seen:
                duplicates.append(name)
            seen.add(name)
        if duplicates:
            return {
                "success": False,
                "error": f"Duplicate VM names in CSV: {', '.join(sorted(set(duplicates)))}",
            }

        imported = 0
        with self._db() as conn:
            for row in rows:
                vm_name = row["VMName"].strip()
                if not vm_name:
                    continue
                status = "excluded" if self._is_legacy_os(row["OSVersion"]) else "pending"
                conn.execute(
                    """
                    INSERT INTO vms (
                        vm_name, source_host, target_host, os_version,
                        owner, maintenance_window, status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(vm_name) DO UPDATE SET
                        source_host=excluded.source_host,
                        target_host=excluded.target_host,
                        os_version=excluded.os_version,
                        owner=excluded.owner,
                        maintenance_window=excluded.maintenance_window,
                        status=excluded.status,
                        current_step=NULL,
                        retry_count=0,
                        started_at=NULL,
                        finished_at=NULL,
                        duration_seconds=NULL,
                        error_message=NULL
                    """,
                    (
                        vm_name,
                        row["SourceHost"].strip(),
                        row["TargetHost"].strip(),
                        row["OSVersion"].strip(),
                        row["Owner"].strip(),
                        row["MaintenanceWindow"].strip(),
                        status,
                    ),
                )
                imported += 1

        self._write_system_log(f"Imported {imported} VM(s) from CSV")
        return {"success": True, "imported": imported}

    def list_vms(self) -> list[dict]:
        with self._db() as conn:
            rows = conn.execute("SELECT * FROM vms ORDER BY id").fetchall()
        return [dict(r) for r in rows]

    def get_vm(self, vm_name: str) -> dict | None:
        with self._db() as conn:
            row = conn.execute("SELECT * FROM vms WHERE vm_name = ?", (vm_name,)).fetchone()
        return dict(row) if row else None

    def get_vm_logs(self, vm_name: str) -> str:
        if not os.path.exists(self.log_path):
            return ""
        pattern = re.compile(rf"VM={re.escape(vm_name)}\b")
        lines = []
        with open(self.log_path, encoding="utf-8") as f:
            for line in f:
                if pattern.search(line) or f"VM={vm_name}" in line:
                    lines.append(line.rstrip("\n"))
        return "\n".join(lines)

    def approve_vm(self, vm_name: str) -> dict:
        vm = self.get_vm(vm_name)
        if not vm:
            return {"success": False, "error": "VM not found"}
        if vm["status"] != "excluded":
            return {"success": False, "error": "VM is not excluded"}
        with self._db() as conn:
            conn.execute(
                "UPDATE vms SET status = 'pending', error_message = NULL WHERE vm_name = ?",
                (vm_name,),
            )
        self._write_system_log(f"VM {vm_name} manually approved for migration")
        return {"success": True}

    def retry_vm(self, vm_name: str) -> dict:
        vm = self.get_vm(vm_name)
        if not vm:
            return {"success": False, "error": "VM not found"}
        if vm["status"] not in STATUSES_FAILED:
            return {"success": False, "error": "VM is not in a failed state"}
        with self._db() as conn:
            conn.execute(
                """
                UPDATE vms SET
                    status = 'pending',
                    current_step = NULL,
                    retry_count = 0,
                    started_at = NULL,
                    finished_at = NULL,
                    duration_seconds = NULL,
                    error_message = NULL
                WHERE vm_name = ?
                """,
                (vm_name,),
            )
        self._write_system_log(f"VM {vm_name} queued for manual retry")
        return {"success": True}

    def get_report(self) -> dict:
        vms = self.list_vms()
        total = len(vms)
        done = sum(1 for v in vms if v["status"] == "done")
        failed = sum(1 for v in vms if v["status"] in STATUSES_FAILED)
        pending = sum(
            1
            for v in vms
            if v["status"] in ("pending", "running", "excluded")
        )
        total_duration = sum(v["duration_seconds"] or 0 for v in vms)
        return {
            "total": total,
            "done": done,
            "failed": failed,
            "pending": pending,
            "total_duration_seconds": total_duration,
            "by_status": _count_by_status(vms),
        }

    def start(self) -> dict:
        with self._lock:
            if self._state == "running":
                return {"success": False, "error": "Orchestrator is already running"}
            if self._thread and self._thread.is_alive():
                return {"success": False, "error": "Orchestrator thread is still active"}
            self._pause_requested = False
            self._stop_requested = False
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        return {"success": True}

    def pause(self) -> dict:
        with self._lock:
            if self._state != "running":
                return {"success": False, "error": "Orchestrator is not running"}
            self._pause_requested = True
        self._write_system_log("Pause requested — will stop after current VM finishes")
        return {"success": True}

    def stop(self) -> dict:
        with self._lock:
            if self._state not in ("running", "paused"):
                return {"success": False, "error": "Orchestrator is not active"}
            self._stop_requested = True
        self._write_system_log("Stop requested — will stop after current step finishes")
        return {"success": True}

    def _should_stop_after_step(self) -> bool:
        with self._lock:
            return self._stop_requested

    def _should_pause_after_vm(self) -> bool:
        with self._lock:
            return self._pause_requested

    def _update_vm(self, vm_name: str, **fields: Any) -> None:
        if not fields:
            return
        cols = ", ".join(f"{k} = ?" for k in fields)
        values = list(fields.values()) + [vm_name]
        with self._db() as conn:
            conn.execute(f"UPDATE vms SET {cols} WHERE vm_name = ?", values)

    def _run_powershell(
        self,
        script_file: str,
        vm: dict,
        step_label: str,
    ) -> tuple[int, str, str]:
        scripts_path = self.config["orchestrator"]["scripts_path"]
        script_path = os.path.join(scripts_path, script_file)
        timeout = self.config["orchestrator"]["vm_timeout_seconds"]

        cmd = [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script_path,
            "-VMName",
            vm["vm_name"],
            "-SourceHost",
            vm["source_host"],
            "-TargetHost",
            vm["target_host"],
            "-OSVersion",
            vm["os_version"],
        ]

        with self._lock:
            self._current_step = step_label

        self._update_vm(vm["vm_name"], current_step=step_label)

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=os.path.dirname(os.path.abspath(script_path)) or None,
            )
            return result.returncode, result.stdout or "", result.stderr or ""
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout or "" if exc.stdout else ""
            stderr = (exc.stderr or "") + f"\nScript timed out after {timeout} seconds"
            return -1, stdout, stderr
        except Exception as exc:
            return -1, "", str(exc)

    def _process_vm(self, vm: dict) -> bool:
        """Process a single VM. Returns False if orchestrator should stop."""
        vm_name = vm["vm_name"]
        started = self._now_iso()
        start_ts = time.time()

        with self._lock:
            self._current_vm = vm_name

        self._update_vm(
            vm_name,
            status="running",
            started_at=started,
            finished_at=None,
            duration_seconds=None,
            error_message=None,
        )
        self._write_system_log(f"Starting migration for {vm_name}")

        max_retries = self.config["orchestrator"]["max_retries"]
        retry_wait = self.config["orchestrator"]["retry_wait_seconds"]

        for script_file, step_label, fail_status in STEPS:
            if self._should_stop_after_step():
                self._update_vm(
                    vm_name,
                    status="pending",
                    current_step=None,
                )
                self._write_system_log(f"Stopped before step {step_label} on {vm_name}")
                return False

            exit_code, stdout, stderr = self._run_powershell(script_file, vm, step_label)
            self._write_log(vm_name, step_label, stdout, stderr, exit_code)

            if exit_code != 0:
                self._write_system_log(
                    f"Step {step_label} failed for {vm_name} (exit {exit_code})"
                )

                if fail_status == "conv-failed":
                    with self._db() as conn:
                        row = conn.execute(
                            "SELECT retry_count FROM vms WHERE vm_name = ?",
                            (vm_name,),
                        ).fetchone()
                        retry_count = row["retry_count"] if row else 0

                    while exit_code != 0 and retry_count < max_retries:
                        retry_count += 1
                        self._update_vm(
                            vm_name,
                            status="conv-failed",
                            retry_count=retry_count,
                            error_message=stderr or stdout or f"Exit code {exit_code}",
                        )
                        self._write_system_log(
                            f"Conversion failed for {vm_name}, retry {retry_count}/{max_retries} "
                            f"in {retry_wait}s"
                        )
                        time.sleep(retry_wait)

                        if self._should_stop_after_step():
                            return False

                        exit_code, stdout, stderr = self._run_powershell(
                            script_file, vm, step_label
                        )
                        self._write_log(vm_name, step_label, stdout, stderr, exit_code)

                    if exit_code == 0:
                        continue

                duration = int(time.time() - start_ts)
                self._update_vm(
                    vm_name,
                    status=fail_status,
                    current_step=None,
                    finished_at=self._now_iso(),
                    duration_seconds=duration,
                    error_message=stderr or stdout or f"Exit code {exit_code}",
                )
                return True

        duration = int(time.time() - start_ts)
        self._update_vm(
            vm_name,
            status="done",
            current_step=None,
            finished_at=self._now_iso(),
            duration_seconds=duration,
            error_message=None,
        )
        self._write_system_log(f"Completed migration for {vm_name} in {duration}s")
        return True

    def _run(self) -> None:
        self._set_state("running")
        self._write_system_log("Orchestrator started")

        try:
            with self._db() as conn:
                pending = conn.execute(
                    """
                    SELECT * FROM vms
                    WHERE status NOT IN ('done', 'excluded', 'running')
                    ORDER BY id
                    """
                ).fetchall()

            for row in pending:
                vm = dict(row)
                if vm["status"] in STATUSES_SKIP:
                    continue
                if vm["status"] == "running":
                    self._update_vm(vm["vm_name"], status="pending")

                if not self._process_vm(vm):
                    break

                if self._should_pause_after_vm():
                    self._set_state("paused")
                    self._write_system_log("Paused after current VM")
                    with self._lock:
                        self._current_vm = None
                        self._current_step = None
                    return

                if self._should_stop_after_step():
                    break

            with self._lock:
                if self._stop_requested:
                    final_state = "stopped"
                elif self._pause_requested:
                    final_state = "paused"
                else:
                    final_state = "idle"
                self._current_vm = None
                self._current_step = None

            self._set_state(final_state)
            self._write_system_log(f"Orchestrator finished (state={final_state})")
        except Exception as exc:
            self._write_system_log(f"Orchestrator error: {exc}")
            self._set_state("idle")
            with self._lock:
                self._current_vm = None
                self._current_step = None


def _count_by_status(vms: list[dict]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for vm in vms:
        status = vm["status"]
        counts[status] = counts.get(status, 0) + 1
    return counts
