# Minecraft Server Manager — Python API

This is the HTTP/JSON glue layer for the existing Minecraft manager.

The intended architecture is:

```text
Browser
  ↓ HTTP/JSON
Python API
  ↓ subprocess
./server
  ↓
existing manager scripts
  ↓
Minecraft
```

Python does **not** reimplement the Bash manager.

## Files

```text
api/
├── server.py
└── README.md
```

Put `api/server.py` in the project root alongside the existing `server`, `gui/`, `worlds/`, `backups/`, and `scripts/` directories.

## Run

From the project root:

```bash
python3 api/server.py
```

It serves both the GUI and API on the same origin:

```text
http://127.0.0.1:8080/
```

That replaces the temporary:

```bash
python3 -m http.server 8080
```

The backend expects the existing executable:

```text
./server
```

and the existing paths:

```text
gui/
worlds/
backups/
scripts/self-test.sh
```

## API

```text
GET    /api/status
GET    /api/worlds
GET    /api/world/:id

POST   /api/activate
POST   /api/create-world
PUT    /api/world/:id

POST   /api/start
POST   /api/stop

POST   /api/console
GET    /api/console/stream

POST   /api/backup
GET    /api/backups
POST   /api/restore

POST   /api/pregenerate
POST   /api/delete-world

POST   /api/self-test
```

All JSON responses use:

```json
{
  "ok": true,
  "data": {},
  "error": null
}
```

or:

```json
{
  "ok": false,
  "data": null,
  "error": {
    "code": "...",
    "message": "..."
  }
}
```

## Lifecycle behavior

`POST /api/start` returns `STARTING` immediately.

Python watches the existing `./server start <id>` output. A Minecraft output line containing `Done (` changes the internal state to `RUNNING`.

`POST /api/stop` returns `STOPPING`. The state becomes `STOPPED` after the manager stop operation and Minecraft process have exited.

Minecraft stdout/stderr is fanned out to `/api/console/stream` as Server-Sent Events.

## Notes about world creation

The architecture document explicitly documents these `./server create` options:

```text
--name
--seed
--gamemode
--difficulty
--structures
--max-players
--view-distance
--simulation-distance
--pvp
```

It does not document a `--hardcore` option, so `server.py` deliberately does not invent one. Hardcore remains part of the JSON model and update path. Once `create-world.sh` itself is available for inspection, the real CLI option can be wired in without changing the HTTP contract.

## Configuration

Optional environment variables:

```text
MCSM_ROOT
MCSM_GUI_DIR
MCSM_HOST
MCSM_PORT
MCSM_COMMAND_TIMEOUT
MCSM_SELF_TEST_TIMEOUT
```

The default root is the directory containing the parent of `api/server.py`.
