#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"
BACKUP_DIR="$SERVER_DIR/backups"

ARCHIVE="$1"

if [ -z "$ARCHIVE" ]; then
    echo "Usage: ./restore-backup.sh <backup.tar.gz>"
    exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
    if [ -f "$BACKUP_DIR/$ARCHIVE" ]; then
        ARCHIVE="$BACKUP_DIR/$ARCHIVE"
    else
        echo "Backup not found: $ARCHIVE"
        exit 1
    fi
fi

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is running. Stop it before restoring a backup."
    exit 1
fi

if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    echo "Invalid or corrupted archive."
    exit 1
fi

WORLD_ID="$(tar -tzf "$ARCHIVE" | awk -F/ 'NF > 1 {print $1; exit}')"

if [ -z "$WORLD_ID" ]; then
    echo "Could not determine world ID from archive."
    exit 1
fi

WORLD_DIR="$WORLDS_DIR/$WORLD_ID"
TEMP_DIR="$SERVER_DIR/.restore-temp-$$"
ACTIVE=0

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

echo "Backup: $(basename "$ARCHIVE")"
echo "World:  $WORLD_ID"
echo

mkdir -p "$TEMP_DIR"

tar -xzf "$ARCHIVE" -C "$TEMP_DIR"

RESTORED_DIR="$TEMP_DIR/$WORLD_ID"

if [ ! -d "$RESTORED_DIR" ]; then
    echo "Archive does not contain expected world directory: $WORLD_ID"
    exit 1
fi

if [ ! -f "$RESTORED_DIR/world.json" ]; then
    echo "Restored world is missing world.json."
    exit 1
fi

if ! python -m json.tool "$RESTORED_DIR/world.json" >/dev/null 2>&1; then
    echo "Restored world has invalid world.json."
    exit 1
fi

if [ ! -f "$RESTORED_DIR/level.dat" ]; then
    echo "Restored world is missing level.dat."
    exit 1
fi

if [ ! -d "$RESTORED_DIR/region" ]; then
    echo "Restored world is missing region/."
    exit 1
fi

if [ -L "$SERVER_DIR/world" ]; then
    TARGET="$(readlink -f "$SERVER_DIR/world")"

    if [ "$TARGET" = "$(readlink -f "$WORLD_DIR")" ]; then
        ACTIVE=1
        rm "$SERVER_DIR/world"
    fi
fi

if [ -d "$WORLD_DIR" ]; then
    echo "Creating safety backup of current world..."

    "$SERVER_DIR/scripts/backup.sh" "$WORLD_ID" || {
        echo "Could not create safety backup."
        exit 1
    }

    rm -rf "$WORLD_DIR"
fi

mv "$RESTORED_DIR" "$WORLD_DIR"

if [ "$ACTIVE" -eq 1 ]; then
    ln -s "worlds/$WORLD_ID" "$SERVER_DIR/world"
fi

echo
echo "World restored successfully: $WORLD_ID"
