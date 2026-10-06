# Conclave AX brand assets

The canonical vector mark is `assets/branding/conclave_logo.svg`.

All committed raster assets are reviewed exports. They are **not generated during build or by a repository script**. This avoids renderer-specific blank/transparent output and makes the exact shipped artwork reviewable in Git.

## Required surfaces

- Conclave AX: Flutter branding asset, browser favicon, PWA icons and maskable icons.
- Workspace: Flutter branding asset and complete macOS AppIcon set.
- Profile Lab: Flutter branding asset and complete macOS AppIcon set.
- Site: SVG favicon / navigation mark and PNG fallback.

## Rules

- Use the transparent logo for in-product branding.
- Use the opaque rounded-square application icon for OS launchers and maskable PWA surfaces.
- Keep the central opening transparent in the standalone mark.
- Do not regenerate or rewrite these files as part of a build.
- Any future brand update must replace the committed files deliberately and visually verify 16, 32, 64, 128, 192, 256, 512 and 1024 px outputs.
