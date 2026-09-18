#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./start.sh <world-id>"
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

if ! python -m json.tool "$WORLD_DIR/world.json" >/dev/null 2>&1; then
    echo "Invalid world.json: $WORLD_ID"
    exit 1
fi

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is already running."
    exit 1
fi

"$SERVER_DIR/scripts/activate-world.sh" "$WORLD_ID" || exit 1

"$SERVER_DIR/scripts/apply-world-config.sh" "$WORLD_ID" || exit 1

echo "Starting world: $WORLD_ID"

cd "$SERVER_DIR" || exit 1

exec 3<> "$SERVER_DIR/server.stdin"

exec /usr/lib/jvm/java-21-openjdk/bin/java \
    -Xmx3G \
    -jar fabric-server-mc.1.21.11-loader.0.19.5-launcher.1.1.2.jar \
    nogui <&3
