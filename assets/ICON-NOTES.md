# Cubicle icon

The app icon is a single open-front cubicle: slate-blue fabric walls with brass trim, a wooden desk and a warm amber
monitor glowing on a deep violet tile. It echoes the store's brass-and-wood look (the Phin Tech Store icon) and the
airbrushed 1990s box art.

It was chosen from three directions (one cubicle, a fan of index tabs, a flat 2x2 grid) generated with OpenAI's
built-in image generation tool, using the store's box art as style references. The first icon (an isometric 2x2 grid of
cubicles under clouds) is in git history.

- `AppIcon-1024.png` is the master: 1024x1024 RGBA, in the macOS squircle with transparent corners.
- `../Resources/AppIcon.icns` is built from it by `just icons` (`dist/make-icns.sh`).
- `../alfred/icon.png` is the same art at 512 px, for the Alfred workflow.
- `../Resources/MenuBarGlyph.png` is a separate single-colour template image (a 2x2 grid with one cell filled),
  drawn by `render-menubar.swift`; `swift assets/render-menubar.swift out.png` redraws it.

Generated art has its own terms; check they suit how the app is distributed.
