#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"
BACKUP_DIR="$SERVER_DIR/backups"

WORLD_ID="$1"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./backup.sh <world-id>"
    exit 1
fi

WORLD_DIR="$WORLDS_DIR/$WORLD_ID"

if [ ! -d "$WORLD_DIR" ]; then
    echo "World not found: $WORLD_ID"
    exit 1
fi

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is running. Stop it before creating a backup."
    exit 1
fi

"$SERVER_DIR/scripts/validate-world.sh" "$WORLD_ID" || exit 1

mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/${WORLD_ID}-${TIMESTAMP}.tar.gz"

echo "Creating backup..."
tar -czf "$ARCHIVE" -C "$WORLDS_DIR" "$WORLD_ID"

echo "Backup created:"
echo "$ARCHIVE"
