# Cubicle icon

The app icon is a polished brass porthole set in a walnut wood-grain tile, looking down an endless row of cubicles
(slate-blue fabric walls with brass trim) that shrink to an amber glow at the vanishing point: infinite cubicles. It
is a sibling of the Phin Tech Store's icon (walnut and a brass porthole) and echoes the store's airbrushed 1990s box art.

It was chosen from several directions generated with OpenAI's built-in image generation tool, using the store's box art
and the other apps' icons as style references: a single cubicle with a glowing monitor (the previous icon, in git
history), index tabs, a flat 2x2 grid, and three "infinite cubicles" takes (this porthole, a tunnel, a pencil sketch).
The first icon (an isometric 2x2 grid of cubicles under clouds) is in git history too.

- `AppIcon-1024.png` is the master: 1024x1024 RGBA, in the macOS squircle with transparent corners.
- `../Resources/AppIcon.icns` is built from it by `just icons` (`dist/make-icns.sh`).
- `../alfred/icon.png` is the same art at 512 px, for the Alfred workflow.
- `../Resources/MenuBarGlyph.png` is a separate single-colour template image (a 2x2 grid with one cell filled),
  drawn by `render-menubar.swift`; `swift assets/render-menubar.swift out.png` redraws it.

Generated art has its own terms; check they suit how the app is distributed.
