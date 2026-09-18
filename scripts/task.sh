#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_FILE="$SERVER_DIR/.server-task"

case "$1" in

    start)
        TYPE="$2"
        WORLD="$3"

        if [ -z "$TYPE" ]; then
            echo "Usage: ./task.sh start <type> [world]"
            exit 1
        fi

        if [ -f "$TASK_FILE" ]; then
            echo "A task is already active:"
            cat "$TASK_FILE"
            exit 1
        fi

        cat > "$TASK_FILE" <<EOF
type=$TYPE
world=$WORLD
started=$(date '+%Y-%m-%d %H:%M:%S')
pid=$$
EOF

        echo "Task started: $TYPE"
        ;;

    status)
        if [ ! -f "$TASK_FILE" ]; then
            echo "No active task."
            exit 0
        fi

        echo "Active task:"
        cat "$TASK_FILE"
        ;;

    active)
        [ -f "$TASK_FILE" ]
        ;;

    end)
        if [ ! -f "$TASK_FILE" ]; then
            echo "No active task."
            exit 0
        fi

        rm -f "$TASK_FILE"
        echo "Task ended."
        ;;

    guard)
        if [ -f "$TASK_FILE" ]; then
            echo "A server task is currently active:"
            cat "$TASK_FILE"
            exit 1
        fi

        exit 0
        ;;

    *)
        echo "Usage:"
        echo "  ./task.sh start <type> [world]"
        echo "  ./task.sh status"
        echo "  ./task.sh active"
        echo "  ./task.sh end"
        echo "  ./task.sh guard"
        exit 1
        ;;

esac
