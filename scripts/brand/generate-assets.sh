#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SVG="$ROOT/assets/branding/conclave_mark.svg"
SOURCE_PNG="$ROOT/assets/branding/conclave_logo.png"

if [ ! -f "$SOURCE_SVG" ]; then
  echo "Master source vector $SOURCE_SVG not found." >&2
  exit 1
fi

render() {
  local size="$1" output="$2"
  mkdir -p "$(dirname "$output")"
  if command -v magick >/dev/null 2>&1; then
    magick -background none "$SOURCE_SVG" -filter Lanczos -resize "${size}x${size}" -gravity center -extent "${size}x${size}" -define png:color-type=6 "$output"
  elif command -v sips >/dev/null 2>&1 && [ -f "$SOURCE_PNG" ]; then
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$output" >/dev/null
  else
    echo "Error: 'magick' tool is required to rasterize master SVG." >&2
    exit 1
  fi
}

echo "Rendering 1024x1024 master raster PNG from canonical vector SVG..."
render 1024 "$SOURCE_PNG"

echo "Rendering brand PNG assets and synchronizing vector variants with preserved alpha transparency..."
for app in app workspace profile_lab; do
  dir="$ROOT/apps/$app/assets/branding"
  mkdir -p "$dir"
  render 1024 "$dir/conclave_logo.png"
  for size in 32 64 128 192 512; do
    render "$size" "$dir/conclave_logo_${size}.png"
  done
  cp "$SOURCE_SVG" "$dir/conclave_mark.svg"
  cp "$ROOT/assets/branding/conclave_mark_dark.svg" "$dir/conclave_mark_dark.svg"
  cp "$ROOT/assets/branding/conclave_mark_monochrome.svg" "$dir/conclave_mark_monochrome.svg"
  cp "$ROOT/assets/branding/conclave_logo.svg" "$dir/conclave_logo.svg"
done

render 1024 "$ROOT/apps/site/public/conclave_logo.png"
render 32 "$ROOT/apps/site/public/favicon.png"
cp "$SOURCE_SVG" "$ROOT/apps/site/public/conclave_mark.svg"
cp "$ROOT/assets/branding/conclave_mark_dark.svg" "$ROOT/apps/site/public/conclave_mark_dark.svg"
cp "$ROOT/assets/branding/conclave_mark_monochrome.svg" "$ROOT/apps/site/public/conclave_mark_monochrome.svg"
cp "$ROOT/assets/branding/conclave_logo.svg" "$ROOT/apps/site/public/conclave_logo.svg"
cp "$ROOT/assets/branding/conclave_logo.svg" "$ROOT/apps/site/public/favicon.svg"

for app in workspace profile_lab; do
  dir="$ROOT/apps/$app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$dir"
  for size in 16 32 64 128 256 512 1024; do
    render "$size" "$dir/app_icon_${size}.png"
  done
done

render 192 "$ROOT/apps/app/web/icons/Icon-192.png"
render 512 "$ROOT/apps/app/web/icons/Icon-512.png"
render 192 "$ROOT/apps/app/web/icons/Icon-maskable-192.png"
render 512 "$ROOT/apps/app/web/icons/Icon-maskable-512.png"
render 32 "$ROOT/apps/app/web/favicon.png"
cp "$ROOT/assets/branding/conclave_logo.svg" "$ROOT/apps/app/web/conclave_logo.svg"

# Update social preview image
if [ -f "$ROOT/apps/site/public/social-preview.png" ] && command -v magick >/dev/null 2>&1; then
  magick "$ROOT/apps/site/public/social-preview.png" \( "$SOURCE_PNG" -background none -resize 48x48 \) -geometry +72+68 -composite "$ROOT/apps/site/public/social-preview.png"
fi

echo "Conclave AX brand vector marks and raster assets successfully generated with transparent background!"
