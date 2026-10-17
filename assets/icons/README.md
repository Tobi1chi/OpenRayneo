# Shared application icon

Selected concept **A (minimal glasses)**, approved on 2026-10-18. The transparent
`openrayneo.png` is the shared source for macOS and Android. It was generated and
background-removed with the built-in imagegen tool; both lens interiors and the
surrounding canvas have an alpha channel. No API key was used.

The editing prompt preserved the off-white geometric frame, side tabs and mint
signal rectangle, removed the charcoal background including the lens interiors,
and requested clean antialiased edges without a shadow or a container.

Run `sh scripts/build-icons.sh` on macOS after changing the source. Commit the
source and exported files together:

- `OpenRayneo.icns`: standard 16–1024 pixel representations, copied into the Mac
  bundle by `scripts/build-app.sh` and referenced by `CFBundleIconFile`.
- `android/app/src/main/res/drawable-nodpi/ic_glasses_mark.png`: 432 pixel
  transparent foreground, inset by the Android drawable for adaptive icon masks.

Android supplies a separate charcoal adaptive background so the white frame is
visible. The system themed icon uses the same foreground alpha. The PNG and ICNS
artwork themselves remain transparent. Generated platform sizes use native
`sips` and `iconutil`; build intermediates stay in `.build/icons/`.

Exact background-removal prompt (built-in imagegen, transparent output):

> Edit the supplied selected app icon A. Remove ALL charcoal/black background to actual alpha transparency, including both lens interiors, space around the glasses, and small gaps near the hinges. Preserve the existing exact silhouette, proportions, positions, off-white glasses frame, two white side tabs and mint green small rectangular signal in the right lens. No redesign, no new shapes, no container, no shadow, no checkerboard baked in. Clean antialiased edges, flat uniform off-white and mint fills, centered on a square transparent canvas. This is a transparent brand mark for macOS and Android icons.
