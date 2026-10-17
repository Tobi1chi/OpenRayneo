# Shared application icon

The user selected the **OR monogram** by its exact source filename on 2026-10-18:
`exec-68bcd8bd-5567-4f8b-ae63-dfb821894f16.png`. This supersedes the earlier glasses
icon selection. The transparent `openrayneo.png` is the shared source for macOS
and Android. Background removal used the built-in imagegen tool, without an API
key. Letter interiors, gaps and surrounding canvas are transparent.

Run `sh scripts/build-icons.sh` on macOS after changing the source. Commit the
source and exported files together:

- `OpenRayneo.icns`: standard 16–1024 pixel representations, copied into the Mac
  bundle by `scripts/build-app.sh` and referenced by `CFBundleIconFile`.
- `android/app/src/main/res/drawable-nodpi/ic_brand_mark.png`: 432 pixel
  transparent foreground, inset by `ic_brand_foreground.xml` for adaptive masks.

Android supplies a separate off-white adaptive background so the black letters
remain visible. The system themed icon uses the same foreground alpha. The PNG
and ICNS artwork themselves remain transparent. Generated platform sizes use
native `sips` and `iconutil`; intermediates stay in `.build/icons/`.

Exact background-removal prompt (built-in imagegen, transparent output):

> Remove only the off-white background from this exact OR monogram image. Preserve the black O and R shapes, their exact proportions and positions and the mint green capsule at the left opening of the O. All white/off-white areas must become genuine alpha transparency, including the O interior, R interior, narrow gap between letters, and outer canvas. Do not redesign, recolor, add a container, add outlines, add shadows, or add any text. Preserve crisp antialiased edges. Return the same square composition as a transparent PNG.
