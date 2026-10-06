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

## 3. Single Canonical Source & Deterministic Asset Pipeline

`assets/branding/` is the **single canonical source** for all branding assets in the repository. Do not independently edit or redraw copies in `apps/`.

To build, validate, and synchronize all derivative raster PNGs, macOS app icons, and web PWA icons from `assets/branding/`, run:

```bash
scripts/branding/build-brand-assets.sh
```

To verify vector purity (no base64 rasters or `<image>` elements), alpha transparency, and asset synchronization in CI:

```bash
scripts/branding/build-brand-assets.sh --check
```

### Deterministic Pipeline Guarantees
1. **Vector Purity Verification:** Confirms all master SVGs consist of 100% pure mathematical vector paths with zero embedded rasters (`data:image/*`, `<image>`).
2. **Transparency Verification:** Tests master renders to guarantee 100% transparent backgrounds with 0 alpha in edge/corner pixels.
3. **Automated Multi-Scale Rasterization:** Generates pixel-crisp PNGs at standard sizes: `32px`, `64px`, `128px`, `192px`, `512px`, `1024px`.
4. **App Synchronization:** Distributes vector masters and raster iconsets across:
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


