# Conclave AX Branding

The approved logo supplied on October 7, 2026 is preserved byte-for-byte in
`assets/branding/conclave_source.png` (1268 × 1240, transparent RGBA).
It is the canonical product identity across all apps and the public site.

## Asset generation

Run `scripts/branding/build-brand-assets.sh` with Python 3 and ImageMagick 7.
The generator resamples directly from the source using Lanczos, preserves aspect
ratio, centers the mark, and keeps transparent backgrounds. Standard square
icons have 5% clear space per edge. The 1024px PNG is a derivative, not the source.
The supplied gradients and folded appearance are preserved without redrawing.

SVG files are self-contained wrappers embedding the exact approved PNG; they
are not resolution-independent vector artwork. Existing light, dark, monochrome,
and two-tone filenames now retain the same approved full-color mark. Wordmarks
retain light/dark text colors and incorporate the new artwork.

Outputs cover Flutter app asset bundles, website marks and wordmarks, PNG/SVG/ICO
favicons, web manifest icons, social preview artwork, and Workspace/Profile Lab
macOS icons at 16–1024px. Maskable icons use an opaque dark background and a
centered mark occupying 60% of the square to stay inside the circular safe zone.

## Verification

`pnpm brand:check` checks required assets, synchronized copies, approved raster
embeddings, and existing brand color rules. `scripts/branding/build-brand-assets.sh
--check` regenerates every derivative without writing and compares exact bytes,
including desktop icons, maskable icons and the social card. Use the same
ImageMagick version for deterministic byte comparisons across machines.

Never independently edit app copies. Replace the canonical source and regenerate.
Preserve the negative-space center, transparency and original colors. Decorative
marketing artwork remains separate; the approved folded logo is now the official
product identity and supersedes the previous flat-vector-only rule.
