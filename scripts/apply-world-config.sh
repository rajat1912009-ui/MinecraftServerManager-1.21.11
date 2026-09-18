#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"

if [ -z "$WORLD_ID" ]; then
    echo "Usage: ./apply-world-config.sh <world-id>"
    exit 1
fi

WORLD_JSON="$WORLDS_DIR/$WORLD_ID/world.json"

if [ ! -f "$WORLD_JSON" ]; then
    echo "World metadata missing: $WORLD_ID"
    exit 1
fi

if ! python -m json.tool "$WORLD_JSON" >/dev/null 2>&1; then
    echo "Invalid world.json: $WORLD_ID"
    exit 1
fi

python - "$WORLD_JSON" "$SERVER_DIR/server.properties" <<'PY'
import json
import sys

world_json = sys.argv[1]
properties = sys.argv[2]

with open(world_json) as f:
    config = json.load(f)

seed = config.get("seed")

wanted = {
    "gamemode": str(config["gamemode"]),
    "difficulty": str(config["difficulty"]),
    "hardcore": str(config["hardcore"]).lower(),
    "generate-structures": str(config["generate_structures"]).lower(),
    "max-players": str(config["max_players"]),
    "view-distance": str(config["view_distance"]),
    "simulation-distance": str(config["simulation_distance"]),
    "pvp": str(config["pvp"]).lower(),
    "level-seed": "" if seed is None else str(seed),
}

with open(properties) as f:
    lines = f.readlines()

found = set()
output = []

for line in lines:
    stripped = line.strip()

    if "=" in stripped and not stripped.startswith("#"):
        key = stripped.split("=", 1)[0]

        if key in wanted:
            output.append(f"{key}={wanted[key]}\n")
            found.add(key)
            continue

    output.append(line)

for key, value in wanted.items():
    if key not in found:
        output.append(f"{key}={value}\n")

with open(properties, "w") as f:
    f.writelines(output)

print(f"Applied configuration for: {config['name']}")
PY
