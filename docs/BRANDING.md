# Conclave AX Brand Mark Specification

The canonical Conclave AX source mark is built entirely from pure mathematical vector paths defined in `assets/branding/conclave_mark.svg` (and `assets/branding/conclave_logo.svg`).

## 1. Design & Geometry

The mark uses four identical elements with **four-fold rotational symmetry** (`0°`, `90°`, `180°`, `270°`). Their convergence creates a radiant four-point sparkle strictly as **negative space**; the sparkle is never drawn as a separate fifth element. This symbolizes independent AI workers coordinating into an emergent result.

- **Background:** 100% transparent.
- **Structure:** Four smooth outer aerodynamic contours with sharp, concave inner facets creating the central negative star.
- **Visual Purity:** No 3D bevels, no specular highlights, no drop shadows, no neon glows, no raster-in-SVG embeddings.
- **Scalability:** Crystal-clear rendering across all resolutions (16px favicon to 1024px display).

---

## 2. Canonical Vector Variants & Marketing Artwork

All official product variants are located in `assets/branding/` and synchronized across all client applications. Optional decorative artwork is isolated in `assets/branding/marketing/`:

```
assets/branding/
    conclave_mark.svg              ← official product mark (primary light)
    conclave_mark_dark.svg         ← official product mark (dark mode)
    conclave_mark_monochrome.svg   ← official product mark (monochrome)
    conclave_mark_twotone.svg      ← official product mark (two-tone)
    conclave_wordmark.svg          ← official horizontal wordmark (light)
    conclave_wordmark_dark.svg     ← official horizontal wordmark (dark)
    conclave_logo.svg              ← official product vector master

    marketing/
        conclave_mark_3d.png       ← optional decorative marketing artwork
```

### Official Product Mark vs. Marketing Artwork Separation

The flat vector mark is the sole official product identity for Conclave AX.

**Prohibited Usage for 3D Marketing Artwork:**
The 3D decorative artwork (`conclave_mark_3d.png`) must **NEVER** be used for:
- Application sidebar
- Favicons (`favicon.ico`, `favicon.png`, `favicon.svg`)
- macOS AppIcon interior mark (`AppIcon.appiconset`)
- Profile Lab header
- Workspace header
- Small UI badges & bot indicators
- Web PWA manifest icons

All runtime surfaces, headers, favicons, and application icons exclusively render the engineered flat vector mark.

| Asset | Variant | Fill Color | Purpose |
|---|---|---|---|
| `conclave_mark.svg` | Primary Light-Background | `#5E4BD8` | Default mark for light mode surfaces and documents |
| `conclave_mark_dark.svg` | Dark-Background | `#B8A9FE` | High-contrast mark for dark mode viewports |
| `conclave_mark_monochrome.svg` | Monochrome | `currentColor` | Adapts dynamically to parent container text color |
| `conclave_mark_twotone.svg` | Two-Tone | `#5E4BD8` / `#4937BD` | Alternating brand purple tones for hero showcases |
| `conclave_wordmark.svg` | Horizontal Wordmark (Light) | `#5E4BD8` / `#20202A` | Standard lockup for web/doc headers |
| `conclave_wordmark_dark.svg` | Horizontal Wordmark (Dark) | `#B8A9FE` / `#F4F4F6` | Dark mode lockup for web/doc headers |
| `conclave_logo.svg` | Canonical Vector Master | `#5E4BD8` | Drop-in vector replacement across web and apps |
| `marketing/conclave_mark_3d.png` | 3D Decorative Artwork | Rendered 3D | Optional marketing illustration only |

---

## 3. Single Canonical Source & Asset Pipeline

`assets/branding/` is the **single canonical source** for all branding assets in the repository. Do not independently edit or redraw copies in `apps/`.

To regenerate and synchronize all derivative raster PNGs, macOS app icons, and web PWA icons from `assets/branding/`, run:

```bash
scripts/brand/generate-assets.sh
```

To verify in CI that all derivative copies in `apps/` are perfectly in sync with `assets/branding/` (no drift):

```bash
scripts/brand/generate-assets.sh --check
```

The asset generator automatically synchronizes and renders:
- **Canonical raster sizes:** `32.png`, `64.png`, `128.png`, `192.png`, `512.png`, `1024.png`
- **Web App (`apps/app`):** vector marks, raster bundles, `web/favicon.png`, `web/conclave_logo.svg`, and PWA `Icon-*.png`
- **Workspace (`apps/workspace`):** vector marks, raster bundles, and macOS `AppIcon.appiconset` (16–1024px)
- **Profile Lab (`apps/profile_lab`):** vector marks, raster bundles, and macOS `AppIcon.appiconset` (16–1024px)
- **Landing Site (`apps/site`):** vector marks, wordmarks, `favicon.svg`, `favicon.png`, and social preview assets

---

## 4. Usage & Brand Governance

1. **Official Product Identity:** The flat vector mark is the exclusive product identity.
2. **Forbidden Alterations:** Do not enclose the mark inside an arbitrary hexagonal or polygon container, do not paint a center star, do not apply outer glows or drop shadows, and do not overlay letters on the vector mark.
3. **Clear Space:** Maintain generous clear space around the mark (minimum 10% margin).
4. **Minimum Scale:** Do not render smaller than 16×16 px.


