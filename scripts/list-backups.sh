#!/usr/bin/env bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$SERVER_DIR/backups"

mkdir -p "$BACKUP_DIR"

BACKUPS="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' | sort -nr)"

if [ -z "$BACKUPS" ]; then
    echo "No backups found."
    exit 0
fi

echo "Backups:"
echo

while read -r timestamp path; do
    size="$(du -h "$path" | cut -f1)"
    printf '%-36s %-10s %s\n' "$(basename "$path")" "$size" "$(date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S')"
done <<< "$BACKUPS"
