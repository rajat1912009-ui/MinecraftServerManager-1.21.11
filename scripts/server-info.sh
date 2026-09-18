#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORLDS_DIR="$SERVER_DIR/worlds"
MODS_DIR="$SERVER_DIR/mods"
JAR="$(find "$SERVER_DIR" -maxdepth 1 -type f -name 'fabric-server-*.jar' | head -n1)"

echo "======================================"
echo " Minecraft Server Manager"
echo "======================================"
echo

echo "Server directory:"
echo "  $SERVER_DIR"
echo

echo "Server status:"
if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "  RUNNING"
else
    echo "  STOPPED"
fi
echo

echo "Active world:"
if [ -L "$SERVER_DIR/world" ]; then
    echo "  $(readlink -f "$SERVER_DIR/world")"
else
    echo "  none"
fi
echo

echo "Java:"
if [ -x /usr/lib/jvm/java-21-openjdk/bin/java ]; then
    /usr/lib/jvm/java-21-openjdk/bin/java -version 2>&1 | head -n1 | sed 's/^/  /'
else
    echo "  Java 21 not found"
fi
echo

echo "Fabric server:"
if [ -n "$JAR" ]; then
    echo "  $(basename "$JAR")"
else
    echo "  not found"
fi
echo

echo "Worlds:"
if [ -d "$WORLDS_DIR" ]; then
    find "$WORLDS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | sed 's/^/  /'
else
    echo "  0"
fi
echo

echo "Mods:"
if [ -d "$MODS_DIR" ]; then
    find "$MODS_DIR" -maxdepth 1 -type f -name '*.jar' | wc -l | sed 's/^/  /'
else
    echo "  0"
fi
echo

echo "Disk:"
df -h "$SERVER_DIR" | tail -n1 | awk '{printf "  Used: %s / %s (%s), Free: %s\n", $3, $2, $5, $4}'
echo

echo "Task:"
if [ -f "$SERVER_DIR/.server-task" ]; then
    sed 's/^/  /' "$SERVER_DIR/.server-task"
else
    echo "  none"
fi
echo

echo "Key server properties:"
grep -E '^(online-mode|server-port|max-players|view-distance|simulation-distance|pause-when-empty-seconds)=' \
    "$SERVER_DIR/server.properties" 2>/dev/null | sed 's/^/  /'
