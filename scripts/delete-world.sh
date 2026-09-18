#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"
WORLD_DIR="$WORLDS_DIR/$WORLD_ID"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./delete-world.sh <world-id>"
    exit 1
fi

if [ "$WORLD_ID" = "." ] || [ "$WORLD_ID" = ".." ]; then
    echo "Invalid world ID."
    exit 1
fi

if [ ! -d "$WORLD_DIR" ]; then
    echo "World not found: $WORLD_ID"
    exit 1
fi

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is running. Stop it before deleting a world."
    exit 1
fi

if [ -L "$SERVER_DIR/world" ]; then
    TARGET="$(readlink -f "$SERVER_DIR/world")"

    if [ "$TARGET" = "$(readlink -f "$WORLD_DIR")" ]; then
        echo "This world is currently active."
        echo "Activate another world before deleting it."
        exit 1
    fi
fi

echo "WARNING: This permanently deletes:"
echo "  $WORLD_DIR"
echo

read -r -p "Type '$WORLD_ID' to confirm deletion: " CONFIRM

if [ "$CONFIRM" != "$WORLD_ID" ]; then
    echo "Deletion cancelled."
    exit 1
fi

rm -rf "$WORLD_DIR"

echo "World deleted: $WORLD_ID"
