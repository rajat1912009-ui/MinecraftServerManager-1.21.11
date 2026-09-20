#!/usr/bin/env python3
"""Minecraft Server Manager HTTP/JSON API.

This is intentionally a thin adapter around the existing ./server manager.
The Bash scripts remain the source of truth for Minecraft/server operations.

Run from the project tree as:
    python3 api/server.py

The API also serves gui/ so the browser and API share the same origin.
"""

from __future__ import annotations

import json
import os
import queue
import re
import signal
import subprocess
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


# ---------------------------------------------------------------------------
# Paths / configuration
# ---------------------------------------------------------------------------

API_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = Path(
    os.environ.get("MCSM_ROOT", API_DIR.parent)
).expanduser().resolve()
GUI_DIR = Path(
    os.environ.get("MCSM_GUI_DIR", PROJECT_ROOT / "gui")
).expanduser().resolve()
MANAGER = PROJECT_ROOT / "server"
WORLDS_DIR = PROJECT_ROOT / "worlds"
BACKUPS_DIR = PROJECT_ROOT / "backups"
SELF_TEST = PROJECT_ROOT / "scripts" / "self-test.sh"

HOST = os.environ.get("MCSM_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCSM_PORT", "8080"))
REQUEST_TIMEOUT = float(os.environ.get("MCSM_COMMAND_TIMEOUT", "30"))
SELF_TEST_TIMEOUT = float(os.environ.get("MCSM_SELF_TEST_TIMEOUT", "900"))
MAX_JSON_BYTES = 1_000_000
MAX_CONSOLE_COMMAND = 4096
CONSOLE_BACKLOG = 500

WORLD_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
BACKUP_RE = re.compile(r"^[A-Za-z0-9._-]+\.tar\.gz$")
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
DONE_RE = re.compile(r"\bDone\s*\(")
PLAYER_LIST_RE = re.compile(
    r"There are\s+(?P<online>\d+)\s+of\s+a\s+max(?:imum)?\s+of\s+(?P<max>\d+)",
    re.IGNORECASE,
)
MEMORY_RE = re.compile(r"^-Xmx(?P<value>\d+)(?P<unit>[gGmMkK])$")


# ---------------------------------------------------------------------------
# Generic response helpers
# ---------------------------------------------------------------------------


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def ok(data: Any) -> dict[str, Any]:
    return {"ok": True, "data": data, "error": None}


def fail(code: str, message: str) -> dict[str, Any]:
    return {
        "ok": False,
        "data": None,
        "error": {"code": code, "message": message},
    }


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def json_bool(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"'{name}' must be a boolean.")
    return value


def json_int(value: Any, name: str, minimum: int = 0) -> int:
    # bool is a subclass of int, so reject it explicitly.
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"'{name}' must be an integer.")
    if value < minimum:
        raise ValueError(f"'{name}' must be at least {minimum}.")
    return value


# ---------------------------------------------------------------------------
# Console streaming
# ---------------------------------------------------------------------------


class ConsoleHub:
    """In-memory Minecraft/manager output fan-out for the web console."""

    def __init__(self, backlog_size: int = CONSOLE_BACKLOG) -> None:
        self._lock = threading.Lock()
        self._backlog: deque[dict[str, Any]] = deque(maxlen=backlog_size)
        self._clients: set[queue.Queue[dict[str, Any] | None]] = set()

    def publish(self, output: str, stream: str = "stdout") -> None:
        if output is None:
            return
        line = output.rstrip("\n")
        if not line:
            return

        event = {
            "output": line,
            "stream": stream,
            "timestamp": utc_now(),
        }

        with self._lock:
            self._backlog.append(event)
            clients = list(self._clients)

        for client in clients:
            try:
                client.put_nowait(event)
            except queue.Full:
                # A slow browser should not block Minecraft output.
                pass

    def connect(self) -> tuple[queue.Queue[dict[str, Any] | None], list[dict[str, Any]]]:
        client: queue.Queue[dict[str, Any] | None] = queue.Queue(maxsize=200)
        with self._lock:
            backlog = list(self._backlog)
            self._clients.add(client)
        return client, backlog

    def disconnect(self, client: queue.Queue[dict[str, Any] | None]) -> None:
        with self._lock:
            self._clients.discard(client)


# ---------------------------------------------------------------------------
# Manager bridge
# ---------------------------------------------------------------------------


class ManagerBridge:
    """Owns process state and translates API operations into ./server calls."""

    def __init__(self) -> None:
        self.hub = ConsoleHub()
        self._lock = threading.RLock()
        self.start_process: subprocess.Popen[str] | None = None
        self.start_world: str | None = None
        self.server_state = "STOPPED"
        self.started_at: float | None = None
        self.stop_thread: threading.Thread | None = None
        self.operation_threads: set[threading.Thread] = set()
        self.players_online = 0
        self.players_max: int | None = None

    # ----- validation / filesystem ----------------------------------------

    @staticmethod
    def validate_world_id(world_id: Any) -> str:
        if not isinstance(world_id, str) or not WORLD_ID_RE.fullmatch(world_id):
            raise ValueError(
                "World ID must start with a letter or number and contain only "
                "letters, numbers, '.', '_' or '-'."
            )
        return world_id

    @staticmethod
    def validate_backup_name(name: Any) -> str:
        if not isinstance(name, str) or not BACKUP_RE.fullmatch(name):
            raise ValueError("Invalid backup filename.")
        return name

    def world_dir(self, world_id: str) -> Path:
        self.validate_world_id(world_id)
        return WORLDS_DIR / world_id

    def world_json_path(self, world_id: str) -> Path:
        return self.world_dir(world_id) / "world.json"

    def ensure_manager(self) -> None:
        if not MANAGER.is_file():
            raise RuntimeError(f"Manager command not found: {MANAGER}")
        if not os.access(MANAGER, os.X_OK):
            raise RuntimeError(f"Manager command is not executable: {MANAGER}")

    def ensure_world_exists(self, world_id: str) -> Path:
        directory = self.world_dir(world_id)
        metadata = directory / "world.json"
        if not directory.is_dir() or not metadata.is_file():
            raise FileNotFoundError(f"World '{world_id}' does not exist.")
        return metadata

    def read_world(self, world_id: str) -> dict[str, Any]:
        path = self.ensure_world_exists(world_id)
        try:
            with path.open("r", encoding="utf-8") as handle:
                data = json.load(handle)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"World '{world_id}' has invalid world.json: {exc}") from exc
        if not isinstance(data, dict):
            raise RuntimeError(f"World '{world_id}' world.json must contain an object.")
        return data

    def active_world_id(self) -> str | None:
        runtime_world = PROJECT_ROOT / "world"
        try:
            target = runtime_world.resolve(strict=True)
        except FileNotFoundError:
            return None

        try:
            relative = target.relative_to(WORLDS_DIR.resolve())
        except ValueError:
            return None

        if len(relative.parts) != 1:
            return None
        world_id = relative.parts[0]
        return world_id if WORLD_ID_RE.fullmatch(world_id) else None

    # ----- subprocess ------------------------------------------------------

    def _run(
        self,
        args: list[str],
        *,
        input_text: str | None = None,
        timeout: float = REQUEST_TIMEOUT,
        publish_output: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        self.ensure_manager()
        process = subprocess.run(
            args,
            cwd=PROJECT_ROOT,
            text=True,
            input=input_text,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

        if publish_output:
            self._publish_block(process.stdout, "stdout")
            self._publish_block(process.stderr, "stderr")

        return process

    def _publish_block(self, text: str | None, stream: str) -> None:
        if not text:
            return
        for line in text.splitlines():
            self._process_console_line(line, stream)

    def _process_console_line(self, line: str, stream: str) -> None:
        clean = strip_ansi(line)
        self.hub.publish(clean, stream)

        match = PLAYER_LIST_RE.search(clean)
        if match:
            with self._lock:
                self.players_online = int(match.group("online"))
                self.players_max = int(match.group("max"))

        if DONE_RE.search(clean):
            with self._lock:
                if self.server_state == "STARTING":
                    self.server_state = "RUNNING"
                    self.started_at = self.started_at or time.time()

    # ----- world operations ------------------------------------------------

    def list_worlds(self) -> list[dict[str, Any]]:
        if not WORLDS_DIR.is_dir():
            return []

        active = self.active_world_id()
        worlds: list[dict[str, Any]] = []
        for directory in sorted(WORLDS_DIR.iterdir(), key=lambda path: path.name.lower()):
            if not directory.is_dir() or not WORLD_ID_RE.fullmatch(directory.name):
                continue
            metadata = directory / "world.json"
            if not metadata.is_file():
                continue
            try:
                data = self.read_world(directory.name)
            except (RuntimeError, FileNotFoundError):
                continue

            worlds.append(
                {
                    "id": directory.name,
                    "name": data.get("name", directory.name),
                    "gamemode": data.get("gamemode"),
                    "difficulty": data.get("difficulty"),
                    "active": directory.name == active,
                }
            )
        return worlds

    def create_world(self, config: dict[str, Any]) -> dict[str, Any]:
        config = self.validate_world_config(config, require_id=True)
        world_id = config["id"]
        self.validate_world_id(world_id)

        if (WORLDS_DIR / world_id).exists():
            raise FileExistsError(f"World '{world_id}' already exists.")

        args = [
            str(MANAGER),
            "create",
            world_id,
            "--name",
            config["name"],
            "--gamemode",
            config["gamemode"],
            "--difficulty",
            config["difficulty"],
            "--structures",
            "on" if config["generate_structures"] else "off",
            "--max-players",
            str(config["max_players"]),
            "--view-distance",
            str(config["view_distance"]),
            "--simulation-distance",
            str(config["simulation_distance"]),
            "--pvp",
            "on" if config["pvp"] else "off",
        ]

        if config["seed"] is not None:
            args.extend(["--seed", config["seed"]])

        # The architecture document does not document a --hardcore create
        # option, so do not invent one here.  Once create-world.sh is available
        # to inspect, this can be added using its real CLI.
        result = self._run(args, timeout=REQUEST_TIMEOUT, publish_output=True)
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)

        return self.read_world(world_id)

    @staticmethod
    def validate_world_config(config: Any, *, require_id: bool) -> dict[str, Any]:
        if not isinstance(config, dict):
            raise ValueError("Request body must be a JSON object.")

        required = ["name", "gamemode", "difficulty", "max_players", "view_distance", "simulation_distance"]
        if require_id:
            required.insert(0, "id")

        for field in required:
            if field not in config:
                raise ValueError(f"Missing required field '{field}'.")

        if require_id:
            world_id = ManagerBridge.validate_world_id(config["id"])
        else:
            world_id = config.get("id")

        if not isinstance(config["name"], str) or not config["name"].strip():
            raise ValueError("'name' must be a non-empty string.")

        gamemode = config["gamemode"]
        difficulty = config["difficulty"]
        if gamemode not in {"survival", "creative", "adventure", "spectator"}:
            raise ValueError("Invalid gamemode.")
        if difficulty not in {"peaceful", "easy", "normal", "hard"}:
            raise ValueError("Invalid difficulty.")

        seed = config.get("seed")
        if seed is not None and not isinstance(seed, str):
            raise ValueError("'seed' must be a string or null.")

        return {
            "id": world_id,
            "name": config["name"].strip(),
            "seed": seed,
            "gamemode": gamemode,
            "difficulty": difficulty,
            "hardcore": json_bool(config.get("hardcore", False), "hardcore"),
            "generate_structures": json_bool(
                config.get("generate_structures", config.get("structures", True)),
                "generate_structures",
            ),
            "max_players": json_int(config["max_players"], "max_players", 1),
            "view_distance": json_int(config["view_distance"], "view_distance", 1),
            "simulation_distance": json_int(config["simulation_distance"], "simulation_distance", 1),
            "pvp": json_bool(config.get("pvp", True), "pvp"),
        }

    def update_world(self, world_id: str, patch: dict[str, Any]) -> dict[str, Any]:
        self.ensure_world_exists(world_id)
        current = self.read_world(world_id)
        merged = {**current, **patch, "id": world_id}
        config = self.validate_world_config(merged, require_id=False)

        # The manager owns world.json creation, but a PUT is specifically the
        # API's configuration update operation.  We only write the manager-owned
        # metadata, then reuse the existing apply-config script for Minecraft
        # properties.  Unknown existing metadata is preserved above.
        current.update(config)
        path = self.world_json_path(world_id)
        temporary = path.with_suffix(".json.tmp")
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(current, handle, indent=2)
            handle.write("\n")
        temporary.replace(path)

        result = self._run([str(MANAGER), "apply-config", world_id], publish_output=True)
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)

        return self.read_world(world_id)

    def activate(self, world_id: str) -> None:
        self.ensure_world_exists(world_id)
        result = self._run([str(MANAGER), "activate", world_id], publish_output=True)
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)

    # ----- server lifecycle -----------------------------------------------

    def _stream_process(self, process: subprocess.Popen[str], stream_name: str) -> None:
        stream = process.stdout if stream_name == "stdout" else process.stderr
        if stream is None:
            return
        try:
            for line in stream:
                self._process_console_line(line, stream_name)
        except (ValueError, OSError):
            return

    def _watch_start_process(self, process: subprocess.Popen[str], world_id: str) -> None:
        return_code = process.wait()
        with self._lock:
            is_current = self.start_process is process
            current_state = self.server_state

            if is_current:
                self.start_process = None
                self.start_world = None
                self.started_at = None if current_state != "RUNNING" else self.started_at

                if current_state in {"STARTING", "STOPPING"}:
                    self.server_state = "STOPPED"
                    self.players_online = 0
                elif current_state == "RUNNING":
                    # Minecraft exited unexpectedly.
                    self.server_state = "STOPPED"
                    self.players_online = 0

        if return_code != 0:
            self.hub.publish(
                f"[manager] ./server start exited with code {return_code}.",
                "stderr",
            )

    def start(self, world_id: str) -> None:
        self.ensure_world_exists(world_id)
        self.ensure_manager()

        with self._lock:
            if self.server_state in {"STARTING", "RUNNING", "STOPPING"}:
                raise RuntimeError(f"Server is currently {self.server_state.lower()}.")

            process = subprocess.Popen(
                [str(MANAGER), "start", world_id],
                cwd=PROJECT_ROOT,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            self.start_process = process
            self.start_world = world_id
            self.server_state = "STARTING"
            self.started_at = time.time()
            self.players_online = 0
            self.players_max = None

        threading.Thread(
            target=self._stream_process,
            args=(process, "stdout"),
            name="mc-stdout",
            daemon=True,
        ).start()
        threading.Thread(
            target=self._stream_process,
            args=(process, "stderr"),
            name="mc-stderr",
            daemon=True,
        ).start()
        threading.Thread(
            target=self._watch_start_process,
            args=(process, world_id),
            name="mc-watch",
            daemon=True,
        ).start()

    def _run_stop(self) -> None:
        try:
            result = self._run([str(MANAGER), "stop"], timeout=REQUEST_TIMEOUT, publish_output=True)
        except subprocess.TimeoutExpired:
            self.hub.publish("[manager] Stop command timed out.", "stderr")
            with self._lock:
                self.server_state = "STOPPING"
            return
        except Exception as exc:  # noqa: BLE001 - background worker must not die silently.
            self.hub.publish(f"[manager] Stop command failed: {exc}", "stderr")
            return

        with self._lock:
            process = self.start_process

        if process is not None:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass

        with self._lock:
            if self.start_process is None or (process is not None and process.poll() is not None):
                self.server_state = "STOPPED"
                self.started_at = None
                self.players_online = 0

        if result.returncode != 0:
            self.hub.publish(
                f"[manager] ./server stop exited with code {result.returncode}.",
                "stderr",
            )

    def stop(self) -> None:
        self.ensure_manager()
        with self._lock:
            if self.server_state == "STOPPED":
                return
            if self.stop_thread and self.stop_thread.is_alive():
                return
            self.server_state = "STOPPING"
            thread = threading.Thread(target=self._run_stop, name="mc-stop", daemon=True)
            self.stop_thread = thread
            thread.start()

    # ----- status ----------------------------------------------------------

    @staticmethod
    def _status_text_to_state(stdout: str, stderr: str) -> str | None:
        text = strip_ansi(f"{stdout}\n{stderr}").lower()
        # Test stopped first because "server is not running" contains "running".
        if re.search(r"\b(?:stopped|not running|offline|down)\b", text):
            return "STOPPED"
        if re.search(r"\b(?:running|online)\b", text):
            return "RUNNING"
        return None

    def _sync_shell_status(self) -> str | None:
        try:
            result = self._run([str(MANAGER), "status"], timeout=5)
        except (OSError, subprocess.TimeoutExpired, RuntimeError):
            return None
        return self._status_text_to_state(result.stdout, result.stderr)

    def _proc_memory(self, pid: int | None) -> tuple[int | None, int | None]:
        if pid is None or pid <= 0:
            return None, None
        try:
            status_path = Path(f"/proc/{pid}/status")
            rss_mb = None
            for line in status_path.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("VmRSS:"):
                    rss_mb = int(line.split()[1]) // 1024
                    break

            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="ignore")
            allocated_mb = None
            for arg in cmdline.split():
                match = MEMORY_RE.fullmatch(arg)
                if not match:
                    continue
                value = int(match.group("value"))
                unit = match.group("unit").lower()
                allocated_mb = {
                    "k": max(1, value // 1024),
                    "m": value,
                    "g": value * 1024,
                }[unit]
                break
            return rss_mb, allocated_mb
        except (FileNotFoundError, PermissionError, ValueError, OSError):
            return None, None

    def status(self) -> dict[str, Any]:
        with self._lock:
            state = self.server_state
            process = self.start_process
            started_at = self.started_at
            world_id = self.start_world
            cached_online = self.players_online
            cached_max = self.players_max

        if state == "STOPPED":
            shell_state = self._sync_shell_status()
            if shell_state == "RUNNING":
                state = "RUNNING"
                with self._lock:
                    self.server_state = "RUNNING"
            elif shell_state == "STOPPED":
                state = "STOPPED"

        if process is not None and process.poll() is not None:
            with self._lock:
                if self.start_process is process:
                    self.start_process = None
                    self.start_world = None
                    self.server_state = "STOPPED"
                    self.started_at = None
                    self.players_online = 0
            state = "STOPPED"

        active_id = self.active_world_id()
        active_data: dict[str, Any] | None = None
        if active_id:
            try:
                world = self.read_world(active_id)
                active_data = {
                    "id": active_id,
                    "name": world.get("name", active_id),
                }
                if world_id is None:
                    world_id = active_id
                if cached_max is None:
                    cached_max = world.get("max_players")
            except (RuntimeError, FileNotFoundError):
                pass

        if state in {"RUNNING", "STARTING"}:
            running_world = world_id or active_id
            if running_world:
                try:
                    world = self.read_world(running_world)
                    if cached_max is None:
                        cached_max = world.get("max_players")
                    if state == "RUNNING" and active_data is None:
                        active_data = {
                            "id": running_world,
                            "name": world.get("name", running_world),
                        }
                except (RuntimeError, FileNotFoundError):
                    pass

        used_mb, allocated_mb = self._proc_memory(process.pid if process else None)
        uptime = None
        if state == "RUNNING" and started_at is not None:
            uptime = max(0, int(time.time() - started_at))

        return {
            "state": state,
            "active_world": active_data,
            "players": {
                "online": cached_online,
                "max": cached_max or 0,
            },
            "uptime_seconds": uptime,
            "ram": {
                "used_mb": used_mb,
                "allocated_mb": allocated_mb,
            },
        }

    # ----- misc manager operations ---------------------------------------

    def console(self, command: str) -> subprocess.CompletedProcess[str]:
        if not isinstance(command, str) or not command.strip():
            raise ValueError("'command' must be a non-empty string.")
        if len(command) > MAX_CONSOLE_COMMAND:
            raise ValueError(f"Console command is limited to {MAX_CONSOLE_COMMAND} characters.")
        result = self._run(
            [str(MANAGER), "console", command],
            timeout=REQUEST_TIMEOUT,
            publish_output=True,
        )
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)
        return result

    def backups(self) -> list[dict[str, Any]]:
        if not BACKUPS_DIR.is_dir():
            return []
        result: list[dict[str, Any]] = []
        for path in BACKUPS_DIR.iterdir():
            if not path.is_file() or not BACKUP_RE.fullmatch(path.name):
                continue
            stat = path.stat()
            world_id = None
            for candidate in sorted(
                (
                    p.name
                    for p in WORLDS_DIR.iterdir()
                    if p.is_dir() and WORLD_ID_RE.fullmatch(p.name)
                ),
                key=len,
                reverse=True,
            ):
                if path.name.startswith(candidate + "-"):
                    world_id = candidate
                    break
            result.append(
                {
                    "filename": path.name,
                    "world_id": world_id,
                    "size_bytes": stat.st_size,
                    "created_at": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(timespec="seconds"),
                }
            )
        result.sort(key=lambda item: item["created_at"], reverse=True)
        return result

    def backup(self, world_id: str) -> subprocess.CompletedProcess[str]:
        self.ensure_world_exists(world_id)
        result = self._run([str(MANAGER), "backup", world_id], timeout=REQUEST_TIMEOUT, publish_output=True)
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)
        return result

    def restore(self, backup_name: str) -> subprocess.CompletedProcess[str]:
        backup_name = self.validate_backup_name(backup_name)
        backup_path = BACKUPS_DIR / backup_name
        if not backup_path.is_file():
            raise FileNotFoundError(f"Backup '{backup_name}' does not exist.")
        result = self._run([str(MANAGER), "restore", backup_name], timeout=REQUEST_TIMEOUT, publish_output=True)
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)
        return result

    def pregenerate(self, world_id: str, radius: int) -> int:
        self.ensure_world_exists(world_id)
        radius = json_int(radius, "radius", 1)
        self.ensure_manager()

        process = subprocess.Popen(
            [str(MANAGER), "pregenerate", world_id, str(radius)],
            cwd=PROJECT_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        def worker() -> None:
            threading.Thread(
                target=self._stream_process,
                args=(process, "stdout"),
                daemon=True,
            ).start()
            threading.Thread(
                target=self._stream_process,
                args=(process, "stderr"),
                daemon=True,
            ).start()
            code = process.wait()
            if code != 0:
                self.hub.publish(
                    f"[manager] ./server pregenerate exited with code {code}.",
                    "stderr",
                )

        thread = threading.Thread(target=worker, name="pregenerate", daemon=True)
        self.operation_threads.add(thread)
        thread.start()
        return process.pid

    def delete_world(self, world_id: str) -> subprocess.CompletedProcess[str]:
        self.ensure_world_exists(world_id)
        if self.active_world_id() == world_id:
            raise RuntimeError("The active world cannot be deleted.")
        result = self._run(
            [str(MANAGER), "delete-world", world_id],
            input_text=f"{world_id}\n",
            timeout=REQUEST_TIMEOUT,
            publish_output=True,
        )
        if result.returncode != 0:
            raise CommandFailure(result.returncode, result.stdout, result.stderr)
        return result

    def self_test(self) -> subprocess.CompletedProcess[str]:
        if not SELF_TEST.is_file():
            raise RuntimeError(f"Self-test script not found: {SELF_TEST}")
        result = subprocess.run(
            [str(SELF_TEST)],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            timeout=SELF_TEST_TIMEOUT,
            check=False,
        )
        self._publish_block(result.stdout, "stdout")
        self._publish_block(result.stderr, "stderr")
        return result


class CommandFailure(RuntimeError):
    def __init__(self, returncode: int, stdout: str, stderr: str) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        detail = stderr.strip() or stdout.strip() or f"command exited with code {returncode}"
        super().__init__(detail)


BRIDGE = ManagerBridge()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class APIHandler(SimpleHTTPRequestHandler):
    """Static GUI server + /api JSON endpoints."""

    # The base class accepts a directory argument when instantiated.
    server_version = "MinecraftServerManagerAPI/0.1"

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(GUI_DIR), **kwargs)

    # ----- HTTP helpers ----------------------------------------------------

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        # Keep the terminal usable while still logging requests.
        super().log_message(format, *args)

    def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.end_headers()
        self.wfile.write(encoded)

    def send_error_json(self, status: int, code: str, message: str) -> None:
        self.send_json(fail(code, message), status)

    def read_json_body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("Invalid Content-Length header.") from exc

        if length < 0 or length > MAX_JSON_BYTES:
            raise ValueError("JSON request body is too large.")

        raw = self.rfile.read(length)
        if not raw:
            return {}

        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("Request body must contain valid JSON.") from exc

        if not isinstance(data, dict):
            raise ValueError("Request body must be a JSON object.")
        return data

    def api_exception(self, exc: Exception) -> tuple[int, str, str]:
        if isinstance(exc, FileNotFoundError):
            return HTTPStatus.NOT_FOUND, "NOT_FOUND", str(exc)
        if isinstance(exc, FileExistsError):
            return HTTPStatus.CONFLICT, "ALREADY_EXISTS", str(exc)
        if isinstance(exc, ValueError):
            return HTTPStatus.BAD_REQUEST, "INVALID_REQUEST", str(exc)
        if isinstance(exc, CommandFailure):
            return (
                HTTPStatus.BAD_GATEWAY,
                "COMMAND_FAILED",
                str(exc),
            )
        if isinstance(exc, RuntimeError):
            return HTTPStatus.CONFLICT, "MANAGER_ERROR", str(exc)
        if isinstance(exc, subprocess.TimeoutExpired):
            return HTTPStatus.GATEWAY_TIMEOUT, "COMMAND_TIMEOUT", "Manager command timed out."
        return HTTPStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR", str(exc)

    def dispatch(self, method: str, path: str) -> None:
        parsed = urlparse(path)
        if not parsed.path.startswith("/api/"):
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        route = parsed.path.rstrip("/")
        parts = [unquote(part) for part in route.split("/") if part]

        try:
            data: dict[str, Any]
            if method == "GET" and route == "/api/status":
                self.send_json(ok(BRIDGE.status()))
                return

            if method == "GET" and route == "/api/worlds":
                self.send_json(ok({"worlds": BRIDGE.list_worlds()}))
                return

            if method == "GET" and len(parts) == 2 and parts[1] == "api":
                self.send_error_json(HTTPStatus.NOT_FOUND, "NOT_FOUND", "API route not found.")
                return

            if method == "GET" and len(parts) == 2 and parts[1] == "world":
                self.send_error_json(HTTPStatus.BAD_REQUEST, "INVALID_REQUEST", "World ID is required.")
                return

            if method == "GET" and len(parts) == 3 and parts[0] == "api" and parts[1] == "world":
                world_id = BRIDGE.validate_world_id(parts[2])
                self.send_json(ok({"world": BRIDGE.read_world(world_id)}))
                return

            if method == "PUT" and len(parts) == 3 and parts[0] == "api" and parts[1] == "world":
                world_id = BRIDGE.validate_world_id(parts[2])
                data = self.read_json_body()
                world = BRIDGE.update_world(world_id, data)
                self.send_json(ok({"world": world}))
                return

            if method == "POST" and route == "/api/activate":
                data = self.read_json_body()
                world_id = BRIDGE.validate_world_id(data.get("id"))
                BRIDGE.activate(world_id)
                self.send_json(ok({"active_world": world_id}))
                return

            if method == "POST" and route == "/api/create-world":
                data = self.read_json_body()
                world = BRIDGE.create_world(data)
                self.send_json(ok({"world": world}), HTTPStatus.CREATED)
                return

            if method == "POST" and route == "/api/start":
                data = self.read_json_body()
                world_id = BRIDGE.validate_world_id(data.get("id"))
                BRIDGE.start(world_id)
                self.send_json(ok({"state": "STARTING", "world": world_id}), HTTPStatus.ACCEPTED)
                return

            if method == "POST" and route == "/api/stop":
                self.read_json_body()
                BRIDGE.stop()
                self.send_json(ok({"state": "STOPPING"}), HTTPStatus.ACCEPTED)
                return

            if method == "POST" and route == "/api/console":
                data = self.read_json_body()
                result = BRIDGE.console(data.get("command"))
                self.send_json(
                    ok(
                        {
                            "exit_code": result.returncode,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        }
                    )
                )
                return

            if method == "GET" and route == "/api/backups":
                self.send_json(ok({"backups": BRIDGE.backups()}))
                return

            if method == "POST" and route == "/api/backup":
                data = self.read_json_body()
                world_id = BRIDGE.validate_world_id(data.get("id"))
                result = BRIDGE.backup(world_id)
                self.send_json(
                    ok(
                        {
                            "world": world_id,
                            "exit_code": result.returncode,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        }
                    )
                )
                return

            if method == "POST" and route == "/api/restore":
                data = self.read_json_body()
                backup = BRIDGE.validate_backup_name(data.get("backup"))
                result = BRIDGE.restore(backup)
                self.send_json(
                    ok(
                        {
                            "backup": backup,
                            "exit_code": result.returncode,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        }
                    )
                )
                return

            if method == "POST" and route == "/api/pregenerate":
                data = self.read_json_body()
                world_id = BRIDGE.validate_world_id(data.get("id"))
                radius = json_int(data.get("radius"), "radius", 1)
                pid = BRIDGE.pregenerate(world_id, radius)
                self.send_json(
                    ok(
                        {
                            "started": True,
                            "pid": pid,
                            "world": world_id,
                            "radius": radius,
                        }
                    ),
                    HTTPStatus.ACCEPTED,
                )
                return

            if method == "POST" and route == "/api/delete-world":
                data = self.read_json_body()
                world_id = BRIDGE.validate_world_id(data.get("id"))
                result = BRIDGE.delete_world(world_id)
                self.send_json(
                    ok(
                        {
                            "world": world_id,
                            "exit_code": result.returncode,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        }
                    )
                )
                return

            if method == "POST" and route == "/api/self-test":
                self.read_json_body()
                result = BRIDGE.self_test()
                self.send_json(
                    ok(
                        {
                            "passed": result.returncode == 0,
                            "exit_code": result.returncode,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        }
                    )
                )
                return

            if method == "GET" and route == "/api/console/stream":
                self.handle_console_stream()
                return

            self.send_error_json(HTTPStatus.NOT_FOUND, "NOT_FOUND", "API route not found.")

        except Exception as exc:  # noqa: BLE001 - convert all API errors to JSON.
            status, code, message = self.api_exception(exc)
            self.send_error_json(status, code, message)

    # ----- request methods -------------------------------------------------

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/api/"):
            self.dispatch("GET", self.path)
            return
        super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        self.dispatch("POST", self.path)

    def do_PUT(self) -> None:  # noqa: N802
        self.dispatch("PUT", self.path)

    # ----- SSE -------------------------------------------------------------

    def handle_console_stream(self) -> None:
        client, backlog = BRIDGE.hub.connect()

        try:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.flush()

            for event in backlog:
                self._write_sse(event)

            heartbeat_deadline = time.monotonic() + 15
            while True:
                timeout = max(0.1, heartbeat_deadline - time.monotonic())
                try:
                    event = client.get(timeout=timeout)
                except queue.Empty:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    heartbeat_deadline = time.monotonic() + 15
                    continue

                if event is None:
                    break
                self._write_sse(event)
                heartbeat_deadline = time.monotonic() + 15

        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            pass
        finally:
            BRIDGE.hub.disconnect(client)

    def _write_sse(self, event: dict[str, Any]) -> None:
        payload = json.dumps(event, ensure_ascii=False).replace("\r", "\\r").replace("\n", "\\n")
        self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
        self.wfile.flush()


# ---------------------------------------------------------------------------
# Server startup / shutdown
# ---------------------------------------------------------------------------


class APIHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    if not MANAGER.exists():
        print(f"[api] WARNING: manager not found at {MANAGER}")
    if not GUI_DIR.is_dir():
        print(f"[api] WARNING: GUI directory not found at {GUI_DIR}")

    server = APIHTTPServer((HOST, PORT), APIHandler)

    def shutdown(*_: Any) -> None:
        print("\n[api] Shutting down...")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print(f"[api] Project root: {PROJECT_ROOT}")
    print(f"[api] GUI:          {GUI_DIR}")
    print(f"[api] Manager:      {MANAGER}")
    print(f"[api] Listening:    http://{HOST}:{PORT}")

    try:
        server.serve_forever()
    finally:
        server.server_close()
        print("[api] Stopped.")


if __name__ == "__main__":
    main()
