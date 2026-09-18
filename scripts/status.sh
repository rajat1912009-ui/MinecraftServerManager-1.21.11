#!/usr/bin/env bash

if pgrep -f 'fabric-server-mc.*launcher' >/dev/null; then
    echo "Server: RUNNING"
else
    echo "Server: STOPPED"
fi
