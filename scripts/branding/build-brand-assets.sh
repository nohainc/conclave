#!/usr/bin/env bash
# Requires Python 3 (standard library only) and ImageMagick 7.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$ROOT/scripts/branding/build-brand-assets.py" "$@"
