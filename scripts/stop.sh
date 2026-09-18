#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIPE="$SERVER_DIR/server.stdin"

if ! pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is already stopped."
    exit 0
fi

if [ ! -p "$PIPE" ]; then
    echo "Server input pipe is missing."
    exit 1
fi

echo "Stopping server..."

printf 'stop\n' > "$PIPE"

for i in {1..30}; do
    if ! pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
        echo "Server stopped."
        exit 0
    fi

    sleep 1
done

echo "Server did not stop within 30 seconds."
exit 1
