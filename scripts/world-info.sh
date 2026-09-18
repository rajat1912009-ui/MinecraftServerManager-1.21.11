#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"
WORLD_DIR="$WORLDS_DIR/$WORLD_ID"
WORLD_JSON="$WORLD_DIR/world.json"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./world-info.sh <world-id>"
    exit 1
fi

if [ ! -d "$WORLD_DIR" ]; then
    echo "World not found: $WORLD_ID"
    exit 1
fi

if [ ! -f "$WORLD_JSON" ]; then
    echo "World metadata missing: $WORLD_ID"
    exit 1
fi

if ! python -m json.tool "$WORLD_JSON" >/dev/null 2>&1; then
    echo "Invalid world.json: $WORLD_ID"
    exit 1
fi

echo "World: $WORLD_ID"
echo

python -m json.tool "$WORLD_JSON"
