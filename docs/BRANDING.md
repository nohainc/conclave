# Conclave AX brand mark

The canonical Conclave AX source mark is `assets/branding/conclave_logo.png` (master transparent raster) and `assets/branding/conclave_logo.svg` (canonical vector wrapper).

## Design

The mark uses four identical elements with four-fold rotational symmetry. Their convergence creates a four-point sparkle as **negative space**; the sparkle is not a painted fifth element. This represents independent AI workers coordinating into an emergent result.

The canonical mark has a transparent background and remains readable and sharp at all sizes (16–1024 px).

## Source of truth

Do not hand-edit generated PNGs. To refresh assets, place or update `assets/branding/conclave_logo.png`, then run:

```bash
scripts/brand/generate-assets.sh
```

The generator refreshes:

- `assets/branding/conclave_logo.svg` (canonical SVG wrapper with embedded high-resolution data)
- Conclave AX web-app branding PNGs and PWA icons (`apps/app`)
- Workspace branding PNGs and macOS AppIcon set (`apps/workspace`)
- Profile Lab branding PNGs and macOS AppIcon set (`apps/profile_lab`)
- landing-site PNG/favicons and social preview images (`apps/site`)

ImageMagick 7 is required for raster generation and export.

## Usage

Prefer the transparent standalone mark. Do not add a hexagonal container, painted center sparkle, letter, or glow to the canonical mark. Product surfaces may place the mark on their own dark/light container.

Keep clear space around the mark and avoid shrinking below 16 px.
