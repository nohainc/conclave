#!/usr/bin/env bash
# Entrypoint for local development and testing with production D1 database
exec "$(dirname "$0")/scripts/start-local.sh" "$@"
