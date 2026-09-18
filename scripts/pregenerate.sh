#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"
RADIUS="$2"

if [ -z "$WORLD_ID" ] || [ -z "$RADIUS" ]; then
    echo "Usage: ./pregenerate.sh <world-id> <radius>"
    exit 1
fi

if ! [[ "$RADIUS" =~ ^[0-9]+$ ]]; then
    echo "Radius must be a positive integer."
    exit 1
fi

if [ "$RADIUS" -le 0 ]; then
    echo "Radius must be greater than 0."
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

if ! find "$SERVER_DIR/mods" -maxdepth 1 -type f -name 'Chunky-Fabric-*.jar' | grep -q .; then
    echo "Chunky-Fabric was not found in mods/."
    exit 1
fi

if [ -f "$SERVER_DIR/.server-task" ]; then
    echo "Another task is already active:"
    cat "$SERVER_DIR/.server-task"
    exit 1
fi

"$SERVER_DIR/scripts/task.sh" start pregeneration "$WORLD_ID" || exit 1

cleanup_on_failure() {
    "$SERVER_DIR/scripts/task.sh" end >/dev/null 2>&1 || true
}

trap cleanup_on_failure ERR

if ! pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is stopped. Starting $WORLD_ID..."

    "$SERVER_DIR/scripts/start.sh" "$WORLD_ID" \
        > "$SERVER_DIR/logs/pregeneration-start.log" 2>&1 &

    START_PID=$!

    for i in {1..30}; do
        if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
            break
        fi

        if ! kill -0 "$START_PID" 2>/dev/null; then
            echo "Server failed to start."
            exit 1
        fi

        sleep 1
    done
fi

ACTIVE="$("$SERVER_DIR/scripts/common.sh" 2>/dev/null || true)"

if [ -L "$SERVER_DIR/world" ]; then
    CURRENT_WORLD="$(readlink -f "$SERVER_DIR/world")"
    EXPECTED_WORLD="$(readlink -f "$WORLD_DIR")"

    if [ "$CURRENT_WORLD" != "$EXPECTED_WORLD" ]; then
        echo "Another world is active."
        echo "Active:  $CURRENT_WORLD"
        echo "Wanted:  $EXPECTED_WORLD"
        exit 1
    fi
else
    echo "Runtime world symlink is missing."
    exit 1
fi

echo "Queueing Chunky pregeneration..."
echo "World:  $WORLD_ID"
echo "Radius: $RADIUS"
echo

"$SERVER_DIR/scripts/console.sh" "chunky center 0 0"
"$SERVER_DIR/scripts/console.sh" "chunky radius $RADIUS"
"$SERVER_DIR/scripts/console.sh" "chunky start"

echo
echo "Pregeneration started."
echo
echo "Check progress with:"
echo "  ./server console \"chunky progress\""
echo
echo "When Chunky is finished, clear the task with:"
echo "  ./server task end"
