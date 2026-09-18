#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPE="$SERVER_DIR/server.stdin"
LOG="$SERVER_DIR/logs/latest.log"

if ! pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is already stopped."
    exit 0
fi

if [ -f "$SERVER_DIR/.server-task" ]; then
    echo "Active server task detected. Idle stop skipped."
    exit 0
fi

if [ ! -p "$PIPE" ]; then
    echo "Server input pipe is missing."
    exit 1
fi

if [ ! -f "$LOG" ]; then
    echo "Minecraft log not found."
    exit 1
fi

BEFORE_LINES="$(wc -l < "$LOG")"

printf 'list\n' > "$PIPE"

PLAYERS=""

for i in {1..10}; do
    sleep 1

    LINE="$(tail -n +$((BEFORE_LINES + 1)) "$LOG" 2>/dev/null \
        | grep -E 'There are [0-9]+ of a max of [0-9]+ players online:' \
        | tail -n1 || true)"

    if [ -n "$LINE" ]; then
        PLAYERS="$(printf '%s\n' "$LINE" | sed -nE 's/.*There are ([0-9]+) of a max.*/\1/p')"
        break
    fi
done

if [ -z "$PLAYERS" ]; then
    echo "Could not determine player count."
    exit 1
fi

echo "Players online: $PLAYERS"

if [ "$PLAYERS" -eq 0 ]; then
    echo "Server is idle. Stopping..."
    "$SERVER_DIR/scripts/stop.sh"
else
    echo "Server remains running."
fi
