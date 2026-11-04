#!/usr/bin/env bash
# Runs the server in the foreground, configured by SQLITE_PATH, JWT_SECRET, HOST and PORT.
exec "$(dirname "$0")/bin/server"
