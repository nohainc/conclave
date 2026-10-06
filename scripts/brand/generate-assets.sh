#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/assets/branding/conclave_logo.svg"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick 7 (magick) is required to render PNG brand assets." >&2
  exit 1
fi

render() {
  local size="$1" output="$2"
  mkdir -p "$(dirname "$output")"
  magick -background none -density 384 "$SOURCE" -resize "${size}x${size}" -gravity center -extent "${size}x${size}" "$output"
}

for app in app workspace profile_lab; do
  dir="$ROOT/apps/$app/assets/branding"
  render 1024 "$dir/conclave_logo.png"
  for size in 32 64 128 192 512; do
    render "$size" "$dir/conclave_logo_${size}.png"
  done
done

render 1024 "$ROOT/apps/site/public/conclave_logo.png"
render 32 "$ROOT/apps/site/public/favicon.png"

for app in workspace profile_lab; do
  dir="$ROOT/apps/$app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
  for size in 16 32 64 128 256 512 1024; do
    render "$size" "$dir/app_icon_${size}.png"
  done
done

render 192 "$ROOT/apps/app/web/icons/Icon-192.png"
render 512 "$ROOT/apps/app/web/icons/Icon-512.png"
render 192 "$ROOT/apps/app/web/icons/Icon-maskable-192.png"
render 512 "$ROOT/apps/app/web/icons/Icon-maskable-512.png"
render 32 "$ROOT/apps/app/web/favicon.png"

echo "Conclave AX brand assets regenerated from assets/branding/conclave_logo.svg"
