# Shared application icon

The selected icon is the **light OR monogram**: soft-white letters and a mint
green capsule on a transparent canvas. It is the light variant of the original
OR design, approved for both release packages on 2026-10-18. The transparent `openrayneo.png` is the shared source for macOS
and Android. Background removal used the built-in imagegen tool, without an API
key. Letter interiors, gaps and surrounding canvas are transparent.

Run `sh scripts/build-icons.sh` on macOS after changing the source. Commit the
source and exported files together:

- `OpenRayneo.icns`: standard 16–1024 pixel representations, copied into the Mac
  bundle by `scripts/build-app.sh` and referenced by `CFBundleIconFile`.
- `android/app/src/main/res/drawable-nodpi/ic_brand_mark.png`: 432 pixel
  transparent foreground, inset by `ic_brand_foreground.xml` for adaptive masks.

Android supplies a separate charcoal adaptive background so the white letters
remain visible. The README uses a dark-background preview for legibility. The system themed icon uses the same foreground alpha. The PNG
and ICNS artwork themselves remain transparent. Generated platform sizes use
native `sips` and `iconutil`; intermediates stay in `.build/icons/`.

Exact background-removal prompt (built-in imagegen, transparent output):

> Remove only the off-white background from this exact OR monogram image. Preserve the black O and R shapes, their exact proportions and positions and the mint green capsule at the left opening of the O. All white/off-white areas must become genuine alpha transparency, including the O interior, R interior, narrow gap between letters, and outer canvas. Do not redesign, recolor, add a container, add outlines, add shadows, or add any text. Preserve crisp antialiased edges. Return the same square composition as a transparent PNG.

Exact light-variant prompt (built-in imagegen, transparent output):

> Create a light-colored variant of this exact transparent OR monogram. Change ONLY the dark charcoal O and R letter fills to uniform soft white (#F5F5F2), intended to be clearly visible on dark backgrounds. Preserve the mint green capsule exactly, preserve the precise silhouettes, proportions, alignment, negative spaces, canvas size and margins. Keep the outer background, letter interiors, and letter gaps genuinely alpha transparent. Flat crisp logo artwork, smooth antialiased edges, no gradient, no texture, no glow, no shadow, no outline, no background tile, no additional objects or text. This is a recolor of the supplied logo, not a redesign.
