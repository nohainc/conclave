# Conclave AX brand mark

The canonical Conclave AX mark is `assets/branding/conclave_logo.svg`.

## Design

The mark uses four identical elements with four-fold rotational symmetry. Their convergence creates a four-point sparkle as **negative space**; the sparkle is not a painted fifth element. This represents independent AI workers coordinating into an emergent result.

The canonical mark has a transparent background and must remain readable at 16–24 px.

## Source of truth

Do not hand-edit generated PNGs. Update the canonical SVG, then run:

```bash
scripts/brand/generate-assets.sh
```

The generator refreshes:

- Conclave AX web-app branding PNGs and PWA icons
- Workspace branding PNGs and macOS AppIcon set
- Profile Lab branding PNGs and macOS AppIcon set
- landing-site PNG/favicons

ImageMagick 7 is required for raster export.

## Usage

Prefer the transparent standalone mark. Do not add a hexagonal container, painted center sparkle, letter, or glow to the canonical mark. Product surfaces may place the mark on their own dark/light container.

Keep clear space around the mark and avoid shrinking below 16 px.
