# Cubicle icon

The mark is a lightly isometric 2×2 office-partition grid: three slate-blue cubicles and one warm brass/amber cubicle identify the current Space. The twilight squircle, fabric texture, brass rails, and soft glow echo the supplied 1990s software-box references while keeping the silhouette readable at small sizes.

`AppIcon-1024.png` was generated with OpenAI's built-in image generation tool using the three `refs/` images as style references, with an explicit transparent macOS-squircle composition and no text, characters, or UI chrome. The generated RGBA PNG was resized to exactly 1024×1024 with macOS `sips`; `alfred-icon.png` was derived from that master with `sips -z 512 512`.

`menubar-template.png` was drawn directly as a black RGBA glyph by `render-menubar.swift` using AppKit. Reproduce it from this directory with: `SWIFT_MODULECACHE_PATH=/tmp/cubicle-swift-cache CLANG_MODULE_CACHE_PATH=/tmp/cubicle-swift-cache swift out/render-menubar.swift out/menubar-template.png`.
