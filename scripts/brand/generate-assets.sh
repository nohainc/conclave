#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_DIR="$ROOT/assets/branding"
SOURCE_SVG="$CANONICAL_DIR/conclave_mark.svg"
SOURCE_PNG="$CANONICAL_DIR/conclave_logo.png"

if [ ! -f "$SOURCE_SVG" ]; then
  echo "Error: Canonical source vector $SOURCE_SVG not found." >&2
  exit 1
fi

CHECK_ONLY=false
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=true
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

sync_vector() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ "$CHECK_ONLY" = true ]; then
    if [ ! -f "$dest" ] || ! cmp -s "$src" "$dest"; then
      echo "Drift detected: $dest does not match canonical source $src" >&2
      exit 1
    fi
  else
    cp "$src" "$dest"
  fi
}

echo "Canonical branding source: assets/branding/"
if [ "$CHECK_ONLY" = true ]; then
  echo "Checking synchronization of branding derivatives..."
else
  echo "Generating canonical raster masters from vector SVG..."
  render 1024 "$SOURCE_PNG"
  for size in 32 64 128 192 512; do
    render "$size" "$CANONICAL_DIR/conclave_logo_${size}.png"
  done
fi

# Synchronize vector masters and render raster derivatives for apps
for app in app workspace profile_lab; do
  dir="$ROOT/apps/$app/assets/branding"
  mkdir -p "$dir"

  # Sync all canonical vector masters
  sync_vector "$CANONICAL_DIR/conclave_mark.svg" "$dir/conclave_mark.svg"
  sync_vector "$CANONICAL_DIR/conclave_mark_dark.svg" "$dir/conclave_mark_dark.svg"
  sync_vector "$CANONICAL_DIR/conclave_mark_monochrome.svg" "$dir/conclave_mark_monochrome.svg"
  if [ -f "$CANONICAL_DIR/conclave_mark_twotone.svg" ]; then
    sync_vector "$CANONICAL_DIR/conclave_mark_twotone.svg" "$dir/conclave_mark_twotone.svg"
  fi
  if [ -f "$CANONICAL_DIR/conclave_wordmark.svg" ]; then
    sync_vector "$CANONICAL_DIR/conclave_wordmark.svg" "$dir/conclave_wordmark.svg"
  fi
  if [ -f "$CANONICAL_DIR/conclave_wordmark_dark.svg" ]; then
    sync_vector "$CANONICAL_DIR/conclave_wordmark_dark.svg" "$dir/conclave_wordmark_dark.svg"
  fi
  sync_vector "$CANONICAL_DIR/conclave_logo.svg" "$dir/conclave_logo.svg"

  if [ "$CHECK_ONLY" = false ]; then
    render 1024 "$dir/conclave_logo.png"
    for size in 32 64 128 192 512; do
      render "$size" "$dir/conclave_logo_${size}.png"
    done
  fi
done

# Sync landing site public branding
site_dir="$ROOT/apps/site/public"
mkdir -p "$site_dir"
sync_vector "$CANONICAL_DIR/conclave_mark.svg" "$site_dir/conclave_mark.svg"
sync_vector "$CANONICAL_DIR/conclave_mark_dark.svg" "$site_dir/conclave_mark_dark.svg"
sync_vector "$CANONICAL_DIR/conclave_mark_monochrome.svg" "$site_dir/conclave_mark_monochrome.svg"
sync_vector "$CANONICAL_DIR/conclave_logo.svg" "$site_dir/conclave_logo.svg"
sync_vector "$CANONICAL_DIR/conclave_logo.svg" "$site_dir/favicon.svg"
if [ -f "$CANONICAL_DIR/conclave_wordmark.svg" ]; then
  sync_vector "$CANONICAL_DIR/conclave_wordmark.svg" "$site_dir/conclave_wordmark.svg"
fi
if [ -f "$CANONICAL_DIR/conclave_wordmark_dark.svg" ]; then
  sync_vector "$CANONICAL_DIR/conclave_wordmark_dark.svg" "$site_dir/conclave_wordmark_dark.svg"
fi

if [ "$CHECK_ONLY" = false ]; then
  render 1024 "$site_dir/conclave_logo.png"
  render 32 "$site_dir/favicon.png"
fi

# Sync macOS AppIcon sets
for app in workspace profile_lab; do
  icon_dir="$ROOT/apps/$app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$icon_dir"
  if [ "$CHECK_ONLY" = false ]; then
    for size in 16 32 64 128 256 512 1024; do
      render "$size" "$icon_dir/app_icon_${size}.png"
    done
  fi
done

# Sync Web PWA and Favicons
web_dir="$ROOT/apps/app/web"
mkdir -p "$web_dir"
sync_vector "$CANONICAL_DIR/conclave_logo.svg" "$web_dir/conclave_logo.svg"
if [ "$CHECK_ONLY" = false ]; then
  render 192 "$web_dir/icons/Icon-192.png"
  render 512 "$web_dir/icons/Icon-512.png"
  render 192 "$web_dir/icons/Icon-maskable-192.png"
  render 512 "$web_dir/icons/Icon-maskable-512.png"
  render 32 "$web_dir/favicon.png"
fi

# Update social preview image
if [ "$CHECK_ONLY" = false ] && [ -f "$site_dir/social-preview.png" ] && command -v magick >/dev/null 2>&1; then
  magick "$site_dir/social-preview.png" \( "$SOURCE_PNG" -background none -resize 48x48 \) -geometry +72+68 -composite "$site_dir/social-preview.png"
fi

if [ "$CHECK_ONLY" = true ]; then
  echo "All branding derivatives are in sync with assets/branding/."
else
  echo "Successfully synchronized and rendered all branding derivatives from assets/branding/!"
fi
