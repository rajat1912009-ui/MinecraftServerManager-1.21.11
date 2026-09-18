#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_ID="__selftest-$(date +%Y%m%d-%H%M%S)"
TEST_DIR="$SERVER_DIR/worlds/$TEST_ID"
TEST_JSON="$TEST_DIR/world.json"

TEST_LOG="$SERVER_DIR/logs/self-test-$TEST_ID.log"
PROPERTIES_BACKUP="$SERVER_DIR/.selftest-server.properties"

BACKUP_DIR="$SERVER_DIR/backups"

ORIGINAL_WORLD_LINK=""
ORIGINAL_WORLD_WAS_PRESENT=0

fail() {
    echo
    echo "======================================"
    echo " SELF-TEST FAILED"
    echo "======================================"
    echo
    echo "$1"
    echo
    echo "Test log:"
    echo "  $TEST_LOG"
    echo
    exit 1
}

cleanup() {
    echo
    echo "Cleaning up self-test..."

    # Stop the server if it is still running.
    if pgrep -f '[f]abric-server-mc.*launcher' >/dev/null; then
        "$SERVER_DIR/scripts/stop.sh" >/dev/null 2>&1 || true
    fi

    # Remove the test world's runtime symlink.
    if [ -L "$SERVER_DIR/world" ]; then
        TARGET="$(readlink -f "$SERVER_DIR/world" 2>/dev/null || true)"
        TEST_TARGET="$(readlink -f "$TEST_DIR" 2>/dev/null || true)"

        if [ -n "$TARGET" ] && [ -n "$TEST_TARGET" ] && [ "$TARGET" = "$TEST_TARGET" ]; then
            rm "$SERVER_DIR/world"
        fi
    fi

    # Remove the disposable world.
    rm -rf "$TEST_DIR"

    # Remove self-test backups.
    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name "${TEST_ID}-*.tar.gz" \
        -delete 2>/dev/null || true

    # Restore original server.properties.
    if [ -f "$PROPERTIES_BACKUP" ]; then
        mv "$PROPERTIES_BACKUP" "$SERVER_DIR/server.properties"
    fi

    # Restore original world symlink if one existed.
    if [ "$ORIGINAL_WORLD_WAS_PRESENT" -eq 1 ]; then
        if [ ! -e "$SERVER_DIR/world" ] && [ ! -L "$SERVER_DIR/world" ]; then
            ln -s "$ORIGINAL_WORLD_LINK" "$SERVER_DIR/world"
        fi
    fi
}

trap cleanup EXIT

echo "======================================"
echo " Minecraft Server Manager Self-Test"
echo "======================================"
echo
echo "Test ID: $TEST_ID"
echo

# ------------------------------------------------------------
# 1. Preconditions
# ------------------------------------------------------------

echo "[1/10] Checking preconditions..."

if pgrep -f '[f]abric-server-mc.*launcher' >/dev/null; then
    fail "Server is already running. Stop it before running the self-test."
fi

if [ -e "$SERVER_DIR/world" ] && [ ! -L "$SERVER_DIR/world" ]; then
    fail "$SERVER_DIR/world exists as a real directory. Expected the manager's world symlink."
fi

if [ -L "$SERVER_DIR/world" ]; then
    ORIGINAL_WORLD_WAS_PRESENT=1
    ORIGINAL_WORLD_LINK="$(readlink "$SERVER_DIR/world")"
fi

if [ ! -f "$SERVER_DIR/server.properties" ]; then
    fail "server.properties not found."
fi

mkdir -p "$SERVER_DIR/logs" "$BACKUP_DIR"

cp -a "$SERVER_DIR/server.properties" "$PROPERTIES_BACKUP" || \
    fail "Could not back up server.properties."

echo "  Preconditions OK."
echo

# ------------------------------------------------------------
# 2. Syntax check
# ------------------------------------------------------------

echo "[2/10] Checking shell syntax..."

if ! bash -n "$SERVER_DIR/server"; then
    fail "Top-level ./server has a syntax error."
fi

for script in "$SERVER_DIR"/scripts/*.sh; do
    [ -f "$script" ] || continue

    if ! bash -n "$script"; then
        fail "Syntax error in $(basename "$script")."
    fi
done

echo "  Shell syntax OK."
echo

# ------------------------------------------------------------
# 3. Basic manager smoke test
# ------------------------------------------------------------

echo "[3/10] Checking manager commands..."

"$SERVER_DIR/server" worlds >/dev/null 2>&1 || \
    fail "./server worlds failed."

"$SERVER_DIR/server" status >/dev/null 2>&1 || \
    fail "./server status failed."

"$SERVER_DIR/server" info >/dev/null 2>&1 || \
    fail "./server info failed."

"$SERVER_DIR/server" backups >/dev/null 2>&1 || \
    fail "./server backups failed."

echo "  Manager commands OK."
echo

# ------------------------------------------------------------
# 4. Create disposable test metadata
#
# Deliberately does NOT use create-world.sh.
# We already test that manually.
# ------------------------------------------------------------

echo "[4/10] Creating disposable test metadata..."

mkdir -p "$TEST_DIR"

cat > "$TEST_JSON" <<EOF
{
  "id": "$TEST_ID",
  "name": "Self Test World",
  "seed": null,
  "gamemode": "survival",
  "difficulty": "easy",
  "hardcore": false,
  "generate_structures": true,
  "max_players": 2,
  "view_distance": 8,
  "simulation_distance": 6,
  "pvp": true
}
EOF

if ! python -m json.tool "$TEST_JSON" >/dev/null 2>&1; then
    fail "Generated self-test world.json is invalid."
fi

echo "  Test metadata OK."
echo

# ------------------------------------------------------------
# 5. Start disposable world
# ------------------------------------------------------------

echo "[5/10] Starting disposable server..."

"$SERVER_DIR/server" start "$TEST_ID" > "$TEST_LOG" 2>&1 &
START_PID=$!

SERVER_READY=0

for i in {1..45}; do

    if grep -q 'Done (' "$TEST_LOG" 2>/dev/null; then
        SERVER_READY=1
        break
    fi

    if ! kill -0 "$START_PID" 2>/dev/null; then
        echo
        echo "Server process exited unexpectedly."
        echo
        tail -n 40 "$TEST_LOG" 2>/dev/null || true
        fail "Server failed during startup."
    fi

    sleep 1
done

if [ "$SERVER_READY" -ne 1 ]; then
    echo
    echo "Last 40 lines of server log:"
    tail -n 40 "$TEST_LOG" 2>/dev/null || true
    fail "Server did not reach the ready state within 45 seconds."
fi

if ! "$SERVER_DIR/server" status | grep -q 'RUNNING'; then
    fail "Server reached 'Done' but status.sh does not report RUNNING."
fi

echo "  Server started successfully."
echo

# ------------------------------------------------------------
# 6. Console test
# ------------------------------------------------------------

echo "[6/10] Testing server console..."

MARKER="SELFTEST-${TEST_ID}"

"$SERVER_DIR/server" console "say $MARKER" >/dev/null 2>&1 || \
    fail "Could not send command through server.stdin."

CONSOLE_OK=0

for i in {1..10}; do

    if grep -q "$MARKER" "$TEST_LOG" 2>/dev/null; then
        CONSOLE_OK=1
        break
    fi

    sleep 1
done

if [ "$CONSOLE_OK" -ne 1 ]; then
    fail "Console command was sent but was not observed in server output."
fi

echo "  Console OK."
echo

# ------------------------------------------------------------
# 7. Stop + validate generated save
# ------------------------------------------------------------

echo "[7/10] Stopping and validating world..."

"$SERVER_DIR/server" stop || \
    fail "Server failed to stop."

if pgrep -f '[f]abric-server-mc.*launcher' >/dev/null; then
    fail "Server is still running after stop."
fi

"$SERVER_DIR/scripts/validate-world.sh" "$TEST_ID" || \
    fail "Generated world failed validation."

echo "  World generation and validation OK."
echo

# ------------------------------------------------------------
# 8. Backup
# ------------------------------------------------------------

echo "[8/10] Testing backup..."

"$SERVER_DIR/server" backup "$TEST_ID" || \
    fail "Backup failed."

ARCHIVE="$(
    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name "${TEST_ID}-*.tar.gz" \
        -printf '%T@ %p\n' |
    sort -nr |
    head -n1 |
    cut -d' ' -f2-
)"

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    fail "Backup command succeeded but no backup archive was found."
fi

echo "  Backup OK:"
echo "    $(basename "$ARCHIVE")"
echo

# ------------------------------------------------------------
# 9. Restore
# ------------------------------------------------------------

echo "[9/10] Testing restore..."

python - "$TEST_JSON" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path) as f:
    data = json.load(f)

data["name"] = "SELFTEST TAMPERED"

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

"$SERVER_DIR/server" restore "$(basename "$ARCHIVE")" || \
    fail "Restore failed."

RESTORED_NAME="$(
    python - "$TEST_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    print(json.load(f)["name"])
PY
)"

if [ "$RESTORED_NAME" != "Self Test World" ]; then
    fail "Restore completed but original world metadata was not restored."
fi

echo "  Restore OK."
echo

# ------------------------------------------------------------
# 10. Delete disposable world
# ------------------------------------------------------------

echo "[10/10] Testing world deletion..."

# delete-world.sh correctly refuses to delete the active runtime world.
# Remove only the disposable test symlink first.
if [ -L "$SERVER_DIR/world" ]; then
    TARGET="$(readlink -f "$SERVER_DIR/world")"
    TEST_TARGET="$(readlink -f "$TEST_DIR")"

    if [ "$TARGET" = "$TEST_TARGET" ]; then
        rm "$SERVER_DIR/world"
    fi
fi

printf '%s\n' "$TEST_ID" |
    "$SERVER_DIR/server" delete-world "$TEST_ID" >/dev/null 2>&1 || \
    fail "World deletion failed."

if [ -e "$TEST_DIR" ]; then
    fail "World deletion reported success but the test world still exists."
fi

echo "  Delete OK."
echo

echo "======================================"
echo " SELF-TEST PASSED"
echo "======================================"
echo
echo "All core manager workflows passed."
echo
echo "Specialized operations such as pregeneration are intentionally"
echo "not part of this quick integration test."
echo
