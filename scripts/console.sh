#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIPE="$SERVER_DIR/server.stdin"

if [ -z "$1" ]; then
    echo "Usage: ./console.sh <command>"
    exit 1
fi

if ! pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is not running."
    exit 1
fi

if [ ! -p "$PIPE" ]; then
    echo "Server input pipe is missing."
    exit 1
fi

printf '%s\n' "$*" > "$PIPE"
echo "Sent: $*"
