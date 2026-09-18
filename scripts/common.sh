#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"
BACKUP_DIR="$SERVER_DIR/backups"
PIPE="$SERVER_DIR/server.stdin"
TASK_FILE="$SERVER_DIR/.server-task"

server_running() {
    pgrep -f '[f]abric-server-mc.*launcher' >/dev/null
}

active_world_id() {
    if [ ! -L "$SERVER_DIR/world" ]; then
        return 1
    fi

    local target
    target="$(readlink -f "$SERVER_DIR/world")"

    case "$target" in
        "$WORLDS_DIR"/*)
            basename "$target"
            ;;
        *)
            return 1
            ;;
    esac
}

task_active() {
    [ -f "$TASK_FILE" ]
}

die() {
    echo "Error: $*"
    exit 1
}
