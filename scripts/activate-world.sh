#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./activate-world.sh <world-id>"
    exit 1
fi

WORLD_DIR="$WORLDS_DIR/$WORLD_ID"

if [ ! -d "$WORLD_DIR" ]; then
    echo "World not found: $WORLD_ID"
    exit 1
fi

if [ ! -f "$WORLD_DIR/world.json" ]; then
    echo "World metadata missing: $WORLD_ID"
    exit 1
fi

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is already running."
    exit 1
fi

if [ -e "$SERVER_DIR/world" ] || [ -L "$SERVER_DIR/world" ]; then
    rm "$SERVER_DIR/world"
fi

ln -s "worlds/$WORLD_ID" "$SERVER_DIR/world"

echo "Activated world: $WORLD_ID"
echo "Runtime path: $(readlink -f "$SERVER_DIR/world")"
