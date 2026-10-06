#!/usr/bin/env bash
# ==============================================================================
# Conclave AX Deterministic Branding Asset Pipeline
#
# Responsibilities:
# 1. Validate master SVGs contain real mathematical vector paths.
# 2. Verify SVGs do NOT contain embedded base64 rasters (<image>, data:image/*).
# 3. Verify rendered outputs preserve transparent backgrounds.
# 4. Generate transparent PNG variants (32px, 64px, 128px, 192px, 512px, 1024px).
# 5. Generate web favicons (SVG and 32px PNG).
# 6. Generate PWA icons (192px, 512px, maskable variants).
# 7. Generate desktop macOS AppIcon sets (16px to 1024px).
# 8. Synchronize all canonical vector masters and generated rasters to app destinations.
# 9. Support `--check` mode for CI/CD drift detection.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_DIR="$ROOT/assets/branding"
MASTER_MARK_SVG="$CANONICAL_DIR/conclave_mark.svg"
MASTER_MARK_PNG="$CANONICAL_DIR/conclave_logo.png"

CHECK_ONLY=false
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=true
fi

echo "================================================================="
echo " Conclave AX Branding Asset Pipeline"
echo " Mode: $( [ "$CHECK_ONLY" = true ] && echo "Verification (--check)" || echo "Build & Synchronize" )"
echo " Canonical Source: assets/branding/"
echo "================================================================="

# ------------------------------------------------------------------------------
# 1. Validate Vector Purity on all Master SVGs
# ------------------------------------------------------------------------------
echo "==> Validating vector purity of canonical SVG masters..."

REQUIRED_SVGS=(
  "$CANONICAL_DIR/conclave_mark.svg"
  "$CANONICAL_DIR/conclave_mark_dark.svg"
  "$CANONICAL_DIR/conclave_mark_monochrome.svg"
  "$CANONICAL_DIR/conclave_mark_twotone.svg"
  "$CANONICAL_DIR/conclave_wordmark.svg"
  "$CANONICAL_DIR/conclave_wordmark_dark.svg"
  "$CANONICAL_DIR/conclave_logo.svg"
)

for svg in "${REQUIRED_SVGS[@]}"; do
  if [ ! -f "$svg" ]; then
    echo "ERROR: Required vector master missing: $svg" >&2
    exit 1
  fi

  # Check for embedded rasters / data URIs
  if grep -qiE "data:image/|<image[[:space:]]|xlink:href=\"data:" "$svg"; then
    echo "ERROR: Vector purity violation in $svg!" >&2
    echo "       Detected embedded raster content (<image> or data:image/base64)." >&2
    echo "       Conclave brand marks must be 100% pure mathematical vector paths." >&2
    exit 1
  fi

  # Check that SVG contains valid path or geometry elements
  if ! grep -qiE "<path|<defs|<use" "$svg"; then
    echo "ERROR: Vector geometry missing in $svg!" >&2
    exit 1
  fi
done

echo "    [PASS] All canonical SVGs verified as 100% pure vector paths (no raster embeddings)."

# ------------------------------------------------------------------------------
# 2. Rendering & Transparency Helpers
# ------------------------------------------------------------------------------
render_png() {
  local size="$1" output="$2"
  mkdir -p "$(dirname "$output")"
  if command -v magick >/dev/null 2>&1; then
    magick -background none "$MASTER_MARK_SVG" -filter Lanczos -resize "${size}x${size}" -gravity center -extent "${size}x${size}" -define png:color-type=6 "$output"
  elif command -v sips >/dev/null 2>&1 && [ -f "$MASTER_MARK_PNG" ]; then
    sips -z "$size" "$size" "$MASTER_MARK_PNG" --out "$output" >/dev/null
  else
    echo "ERROR: 'magick' tool (ImageMagick) is required to rasterize master SVG." >&2
    exit 1
  fi
}

verify_transparency() {
  local png="$1"
  if command -v magick >/dev/null 2>&1; then
    local is_opaque
    is_opaque=$(magick "$png" -format "%[opaque]" info: 2>/dev/null || echo "False")
    if [ "$is_opaque" = "True" ]; then
      echo "ERROR: Transparency check failed for $png (image is completely opaque)." >&2
      exit 1
    fi

    local corner_alpha
    corner_alpha=$(magick "${png}[1x1+0+0]" -format "%[fx:a]" info: 2>/dev/null || echo "0")
    if [ "$corner_alpha" != "0" ]; then
      echo "ERROR: Corner alpha check failed for $png (expected 0, got $corner_alpha)." >&2
      exit 1
    fi
  fi
}

sync_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ "$CHECK_ONLY" = true ]; then
    if [ ! -f "$dest" ]; then
      echo "ERROR: Destination file missing: $dest" >&2
      exit 1
    fi
    if ! cmp -s "$src" "$dest"; then
      echo "ERROR: Drift detected between $src and $dest" >&2
      exit 1
    fi
  else
    cp "$src" "$dest"
  fi
}

# ------------------------------------------------------------------------------
# 3. Build / Verify Canonical Raster Master & Derivatives
# ------------------------------------------------------------------------------
if [ "$CHECK_ONLY" = false ]; then
  echo "==> Rendering canonical raster masters in assets/branding/..."
  render_png 1024 "$MASTER_MARK_PNG"
  verify_transparency "$MASTER_MARK_PNG"

  for size in 32 64 128 192 512; do
    render_png "$size" "$CANONICAL_DIR/conclave_logo_${size}.png"
  done
else
  echo "==> Verifying canonical raster master transparency..."
  verify_transparency "$MASTER_MARK_PNG"
fi

# ------------------------------------------------------------------------------
# 4. Synchronize Client Applications
# ------------------------------------------------------------------------------
echo "==> Processing application asset destinations..."

for app in app workspace profile_lab; do
  dir="$ROOT/apps/$app/assets/branding"
  mkdir -p "$dir"

  # Sync all vector masters
  for svg_file in conclave_mark.svg conclave_mark_dark.svg conclave_mark_monochrome.svg conclave_mark_twotone.svg conclave_wordmark.svg conclave_wordmark_dark.svg conclave_logo.svg; do
    if [ -f "$CANONICAL_DIR/$svg_file" ]; then
      sync_file "$CANONICAL_DIR/$svg_file" "$dir/$svg_file"
    fi
  done

  # Render / sync raster bundles
  if [ "$CHECK_ONLY" = false ]; then
    render_png 1024 "$dir/conclave_logo.png"
    for size in 32 64 128 192 512; do
      render_png "$size" "$dir/conclave_logo_${size}.png"
    done
  fi
done

# ------------------------------------------------------------------------------
# 5. Synchronize Landing Site Branding & Favicons
# ------------------------------------------------------------------------------
echo "==> Processing landing site public assets..."
site_dir="$ROOT/apps/site/public"
mkdir -p "$site_dir"

for svg_file in conclave_mark.svg conclave_mark_dark.svg conclave_mark_monochrome.svg conclave_logo.svg conclave_wordmark.svg conclave_wordmark_dark.svg; do
  if [ -f "$CANONICAL_DIR/$svg_file" ]; then
    sync_file "$CANONICAL_DIR/$svg_file" "$site_dir/$svg_file"
  fi
done
sync_file "$CANONICAL_DIR/conclave_logo.svg" "$site_dir/favicon.svg"

if [ "$CHECK_ONLY" = false ]; then
  render_png 1024 "$site_dir/conclave_logo.png"
  render_png 32 "$site_dir/favicon.png"
  verify_transparency "$site_dir/favicon.png"

  if [ -f "$site_dir/social-preview.png" ] && command -v magick >/dev/null 2>&1; then
    magick "$site_dir/social-preview.png" \( "$MASTER_MARK_PNG" -background none -resize 48x48 \) -geometry +72+68 -composite "$site_dir/social-preview.png"
  fi
fi

# ------------------------------------------------------------------------------
# 6. Synchronize Desktop macOS AppIcon Sets
# ------------------------------------------------------------------------------
echo "==> Processing macOS AppIcon sets..."
for app in workspace profile_lab; do
  icon_dir="$ROOT/apps/$app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$icon_dir"
  if [ "$CHECK_ONLY" = false ]; then
    for size in 16 32 64 128 256 512 1024; do
      render_png "$size" "$icon_dir/app_icon_${size}.png"
    done
    verify_transparency "$icon_dir/app_icon_1024.png"
  fi
done

# ------------------------------------------------------------------------------
# 7. Synchronize Web App PWA & Favicons
# ------------------------------------------------------------------------------
echo "==> Processing web application PWA & favicon assets..."
web_dir="$ROOT/apps/app/web"
mkdir -p "$web_dir"
sync_file "$CANONICAL_DIR/conclave_logo.svg" "$web_dir/conclave_logo.svg"

if [ "$CHECK_ONLY" = false ]; then
  render_png 192 "$web_dir/icons/Icon-192.png"
  render_png 512 "$web_dir/icons/Icon-512.png"
  render_png 192 "$web_dir/icons/Icon-maskable-192.png"
  render_png 512 "$web_dir/icons/Icon-maskable-512.png"
  render_png 32 "$web_dir/favicon.png"
  verify_transparency "$web_dir/favicon.png"
fi

# ------------------------------------------------------------------------------
# Completion Status
# ------------------------------------------------------------------------------
echo "================================================================="
if [ "$CHECK_ONLY" = true ]; then
  echo " SUCCESS: All branding assets verified (vector purity, transparency, sync)."
else
  echo " SUCCESS: All branding derivatives deterministically built and synced!"
fi
echo "================================================================="
