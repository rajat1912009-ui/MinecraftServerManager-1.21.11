#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"
WORLD_DIR="$WORLDS_DIR/$WORLD_ID"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./validate-world.sh <world-id>"
    exit 1
fi

if [ ! -d "$WORLD_DIR" ]; then
    echo "World not found: $WORLD_ID"
    exit 1
fi

if [ ! -f "$WORLD_DIR/world.json" ]; then
    echo "Missing world.json"
    exit 1
fi

if ! python -m json.tool "$WORLD_DIR/world.json" >/dev/null 2>&1; then
    echo "Invalid world.json"
    exit 1
fi

if [ ! -f "$WORLD_DIR/level.dat" ]; then
    echo "Missing level.dat"
    exit 1
fi

if [ ! -d "$WORLD_DIR/region" ]; then
    echo "Missing region directory"
    exit 1
fi

echo "World is valid: $WORLD_ID"
