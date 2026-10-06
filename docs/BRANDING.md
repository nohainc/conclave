# Conclave AX Brand Mark Specification

The canonical Conclave AX source mark is built entirely from pure mathematical vector paths defined in `assets/branding/conclave_mark.svg` (and `assets/branding/conclave_logo.svg`).

## 1. Design & Geometry

The mark uses four identical elements with **four-fold rotational symmetry** (`0°`, `90°`, `180°`, `270°`). Their convergence creates a radiant four-point sparkle strictly as **negative space**; the sparkle is never drawn as a separate fifth element. This symbolizes independent AI workers coordinating into an emergent result.

- **Background:** 100% transparent.
- **Structure:** Four smooth outer aerodynamic contours with sharp, concave inner facets creating the central negative star.
- **Visual Purity:** No 3D bevels, no specular highlights, no drop shadows, no neon glows, no raster-in-SVG embeddings.
- **Scalability:** Crystal-clear rendering across all resolutions (16px favicon to 1024px display).

---

## 2. Canonical Vector Variants

All variants are located in `assets/branding/` and synchronized across all client applications:

| Asset | Variant | Fill Color | Purpose |
|---|---|---|---|
| `conclave_mark.svg` | Primary Light-Background | `#5E4BD8` | Default mark for light mode surfaces and documents |
| `conclave_mark_dark.svg` | Dark-Background | `#B8A9FE` | High-contrast mark for dark mode viewports |
| `conclave_mark_monochrome.svg` | Monochrome | `currentColor` | Adapts dynamically to parent container text color |
| `conclave_mark_twotone.svg` | Two-Tone | `#5E4BD8` / `#4937BD` | Alternating brand purple tones for hero showcases |
| `conclave_logo.svg` | Canonical Vector Master | `#5E4BD8` | Drop-in vector replacement across web and apps |

---

## 3. Source of Truth & Asset Pipeline

Do not hand-edit raster PNG files. The vector master SVG is the single source of truth.

To regenerate all derivative raster PNGs, macOS app icons, and web PWA icons, run:

```bash
scripts/brand/generate-assets.sh
```

The asset generator automatically creates:
- `assets/branding/conclave_logo.png` (1024×1024 master raster with transparent background)
- Web application branding PNGs and PWA icons (`apps/app`)
- Workspace branding PNGs and macOS `AppIcon.appiconset` (`apps/workspace`)
- Profile Lab branding PNGs and macOS `AppIcon.appiconset` (`apps/profile_lab`)
- Landing site PNG/favicons and social preview images (`apps/site`)

---

## 4. Usage & Brand Governance

1. **Standalone Mark:** Prefer the transparent standalone mark.
2. **Forbidden Alterations:** Do not enclose the mark inside an arbitrary hexagonal or polygon container, do not paint a center star, do not apply outer glows or drop shadows, and do not overlay letters on the vector mark.
3. **Clear Space:** Maintain generous clear space around the mark (minimum 10% margin).
4. **Minimum Scale:** Do not render smaller than 16×16 px.
