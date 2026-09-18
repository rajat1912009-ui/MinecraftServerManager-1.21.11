#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"

WORLD_ID="$1"
shift || true

if [ -z "$WORLD_ID" ]; then
    echo "Usage:"
    echo "  ./create-world.sh <id> [options]"
    echo
    echo "Options:"
    echo "  --name <name>"
    echo "  --seed <seed>"
    echo "  --random-seed"
    echo "  --gamemode <survival|creative|adventure|spectator>"
    echo "  --difficulty <peaceful|easy|normal|hard>"
    echo "  --hardcore"
    echo "  --structures <on|off>"
    echo "  --max-players <number>"
    echo "  --view-distance <number>"
    echo "  --simulation-distance <number>"
    echo "  --pvp <on|off>"
    exit 1
fi

if [[ ! "$WORLD_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid world ID."
    echo "Use only letters, numbers, '_' and '-'."
    exit 1
fi

WORLD_DIR="$WORLDS_DIR/$WORLD_ID"
WORLD_JSON="$WORLD_DIR/world.json"

if [ -e "$WORLD_DIR" ]; then
    echo "World already exists: $WORLD_ID"
    exit 1
fi

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server is running. Stop it before creating a world."
    exit 1
fi

NAME="$WORLD_ID"
SEED=""
GAMEMODE="survival"
DIFFICULTY="easy"
HARDCORE=false
STRUCTURES=true
MAX_PLAYERS=2
VIEW_DISTANCE=12
SIMULATION_DISTANCE=8
PVP=true

while [ $# -gt 0 ]; do
    case "$1" in

        --name)
            NAME="$2"
            shift 2
            ;;

        --seed)
            SEED="$2"
            shift 2
            ;;

        --random-seed)
            SEED=""
            shift
            ;;

        --gamemode)
            GAMEMODE="$2"
            shift 2
            ;;

        --difficulty)
            DIFFICULTY="$2"
            shift 2
            ;;

        --hardcore)
            HARDCORE=true
            shift
            ;;

        --structures)
            case "$2" in
                on) STRUCTURES=true ;;
                off) STRUCTURES=false ;;
                *) echo "structures must be on or off"; exit 1 ;;
            esac
            shift 2
            ;;

        --max-players)
            MAX_PLAYERS="$2"
            shift 2
            ;;

        --view-distance)
            VIEW_DISTANCE="$2"
            shift 2
            ;;

        --simulation-distance)
            SIMULATION_DISTANCE="$2"
            shift 2
            ;;

        --pvp)
            case "$2" in
                on) PVP=true ;;
                off) PVP=false ;;
                *) echo "pvp must be on or off"; exit 1 ;;
            esac
            shift 2
            ;;

        *)
            echo "Unknown option: $1"
            exit 1
            ;;

    esac
done

case "$GAMEMODE" in
    survival|creative|adventure|spectator) ;;
    *)
        echo "Invalid gamemode: $GAMEMODE"
        exit 1
        ;;
esac

case "$DIFFICULTY" in
    peaceful|easy|normal|hard) ;;
    *)
        echo "Invalid difficulty: $DIFFICULTY"
        exit 1
        ;;
esac

[[ "$MAX_PLAYERS" =~ ^[0-9]+$ ]] || { echo "max-players must be numeric."; exit 1; }
[[ "$VIEW_DISTANCE" =~ ^[0-9]+$ ]] || { echo "view-distance must be numeric."; exit 1; }
[[ "$SIMULATION_DISTANCE" =~ ^[0-9]+$ ]] || { echo "simulation-distance must be numeric."; exit 1; }

mkdir -p "$WORLD_DIR"

python - "$WORLD_JSON" "$WORLD_ID" "$NAME" "$SEED" "$GAMEMODE" "$DIFFICULTY" \
    "$HARDCORE" "$STRUCTURES" "$MAX_PLAYERS" "$VIEW_DISTANCE" \
    "$SIMULATION_DISTANCE" "$PVP" <<'PY'
import json
import sys

(
    path,
    world_id,
    name,
    seed,
    gamemode,
    difficulty,
    hardcore,
    structures,
    max_players,
    view_distance,
    simulation_distance,
    pvp,
) = sys.argv[1:]

def boolean(value):
    return value.lower() == "true"

config = {
    "id": world_id,
    "name": name,
    "seed": seed if seed else None,
    "gamemode": gamemode,
    "difficulty": difficulty,
    "hardcore": boolean(hardcore),
    "generate_structures": boolean(structures),
    "max_players": int(max_players),
    "view_distance": int(view_distance),
    "simulation_distance": int(simulation_distance),
    "pvp": boolean(pvp),
}

with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY

echo "Created world definition: $WORLD_ID"
echo
python -m json.tool "$WORLD_JSON"
echo
echo "World data will be generated when you start it."
