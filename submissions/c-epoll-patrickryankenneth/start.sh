#!/usr/bin/env bash
# Foreground server. Config comes only from SQLITE_PATH, JWT_SECRET, HOST, PORT.
exec "$(dirname "$0")/bin/server"
