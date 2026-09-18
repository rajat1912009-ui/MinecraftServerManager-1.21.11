#!/bin/bash

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

echo "Available worlds:"
echo

for world in "$WORLDS_DIR"/*/; do
    [ -d "$world" ] || continue

    name="$(basename "$world")"

    if [ -f "$world/world.json" ]; then
        display_name="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$world/world.json")"
        gamemode="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["gamemode"])' "$world/world.json")"
        difficulty="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["difficulty"])' "$world/world.json")"

        printf '%-20s %-12s %-10s %s\n' "$display_name" "$gamemode" "$difficulty" "[$name]"
    else
        echo "$name (no metadata)"
    fi
done
