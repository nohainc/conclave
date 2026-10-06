#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PNG="$ROOT/assets/branding/conclave_logo.png"
SOURCE_SVG="$ROOT/assets/branding/conclave_logo.svg"

if [ ! -f "$SOURCE_PNG" ]; then
  echo "Master source image $SOURCE_PNG not found." >&2
  exit 1
fi

echo "Generating canonical SVG from $SOURCE_PNG..."
B64=$(base64 < "$SOURCE_PNG" | tr -d '\n')
cat <<EOF > "$SOURCE_SVG"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="100%" height="100%">
  <image href="data:image/png;base64,$B64" width="1024" height="1024"/>
</svg>
EOF

render() {
  local size="$1" output="$2"
  mkdir -p "$(dirname "$output")"
  if command -v sips >/dev/null 2>&1; then
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$output" >/dev/null
  elif command -v magick >/dev/null 2>&1; then
    magick "$SOURCE_PNG" -background none -filter Lanczos -resize "${size}x${size}" -gravity center -extent "${size}x${size}" -define png:color-type=6 "$output"
  else
    echo "Error: neither 'sips' nor 'magick' found." >&2
    exit 1
  fi
}

echo "Rendering brand PNG assets with preserved alpha transparency..."
for app in app workspace profile_lab; do
  dir="$ROOT/apps/$app/assets/branding"
  render 1024 "$dir/conclave_logo.png"
  for size in 32 64 128 192 512; do
    render "$size" "$dir/conclave_logo_${size}.png"
  done
  cp "$SOURCE_SVG" "$dir/conclave_logo.svg"
done

render 1024 "$ROOT/apps/site/public/conclave_logo.png"
render 32 "$ROOT/apps/site/public/favicon.png"
cp "$SOURCE_SVG" "$ROOT/apps/site/public/favicon.svg"

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
cp "$SOURCE_SVG" "$ROOT/apps/app/web/conclave_logo.svg"

# Update social preview image
if [ -f "$ROOT/apps/site/public/social-preview.png" ] && command -v magick >/dev/null 2>&1; then
  magick "$ROOT/apps/site/public/social-preview.png" \( "$SOURCE_PNG" -background none -resize 48x48 \) -geometry +72+68 -composite "$ROOT/apps/site/public/social-preview.png"
fi

echo "Conclave AX brand assets successfully regenerated with transparent background!"
