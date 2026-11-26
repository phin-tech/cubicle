import AppKit

/// The colour of an app's sticky-note Tab: picked from its icon, unless you chose one for it from the Tab's menu.
enum StashNoteColor: String, CaseIterable {
  case yellow, orange, pink, purple, blue, mint, green, gray

  static let overridesKey = "stashNoteColors"

  var displayName: String { rawValue.capitalized }

  /// Post-it shades: light enough for black text.
  var color: NSColor {
    switch self {
    case .yellow: return NSColor(srgbRed: 1.00, green: 0.91, blue: 0.45, alpha: 1)
    case .orange: return NSColor(srgbRed: 1.00, green: 0.74, blue: 0.45, alpha: 1)
    case .pink: return NSColor(srgbRed: 1.00, green: 0.66, blue: 0.78, alpha: 1)
    case .purple: return NSColor(srgbRed: 0.80, green: 0.70, blue: 1.00, alpha: 1)
    case .blue: return NSColor(srgbRed: 0.62, green: 0.82, blue: 1.00, alpha: 1)
    case .mint: return NSColor(srgbRed: 0.62, green: 0.95, blue: 0.86, alpha: 1)
    case .green: return NSColor(srgbRed: 0.72, green: 0.93, blue: 0.55, alpha: 1)
    case .gray: return NSColor(srgbRed: 0.86, green: 0.86, blue: 0.84, alpha: 1)
    }
  }

  // MARK: - Per app

  /// The colour you chose for an app, if you chose one.
  static func chosen(for bundleID: String?) -> StashNoteColor? {
    guard let bundleID,
      let name = (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String])?[bundleID]
    else { return nil }
    return StashNoteColor(rawValue: name)
  }

  /// Sets (or, with nil, clears) the colour of an app's notes.
  static func choose(_ color: StashNoteColor?, for bundleID: String) {
    var all = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
    all[bundleID] = color?.rawValue
    UserDefaults.standard.set(all, forKey: overridesKey)
  }

  /// The note colour for an app: the one you chose, else its icon's own colour made sticky-note light.
  @MainActor
  static func color(for app: NSRunningApplication?) -> NSColor {
    if let chosen = chosen(for: app?.bundleIdentifier) { return chosen.color }
    let key = app?.bundleIdentifier ?? app?.localizedName ?? ""
    if let cached = cache[key] { return cached }
    let color = app?.icon.flatMap(iconColor).map(noteShade) ?? StashNoteColor.yellow.color
    cache[key] = color
    return color
  }

  @MainActor private static var cache: [String: NSColor] = [:]

  /// The main colour of an icon: the hue that covers the most of it, weighted by how strong the colour is. Nil for
  /// an icon that's mostly grey.
  static func iconColor(_ image: NSImage) -> NSColor? {
    let side = 24
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    let bins = 12
    var weight = [CGFloat](repeating: 0, count: bins)
    var sums = [(h: CGFloat, s: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: bins)
    var total: CGFloat = 0
    for x in 0..<side {
      for y in 0..<side {
        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.5 else {
          continue
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        pixel.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        total += 1
        let w = s * b
        guard w > 0.15 else { continue }
        let bin = min(Int(h * CGFloat(bins)), bins - 1)
        weight[bin] += w
        sums[bin].h += h * w
        sums[bin].s += s * w
        sums[bin].b += b * w
      }
    }
    guard total > 0, let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
      weight[best] / total > 0.08
    else { return nil }
    let w = weight[best]
    return NSColor(hue: sums[best].h / w, saturation: sums[best].s / w, brightness: sums[best].b / w, alpha: 1)
  }

  /// A colour made into a sticky-note shade of itself: light and soft, keeping its hue.
  static func noteShade(_ color: NSColor) -> NSColor {
    let c = color.usingColorSpace(.deviceRGB) ?? color
    return NSColor(
      hue: c.hueComponent, saturation: min(max(c.saturationComponent, 0.35), 0.6),
      brightness: max(c.brightnessComponent, 0.93), alpha: 1)
  }

  /// A note colour for dark mode: the same hue, deep and muted, for light text.
  static func darkShade(_ color: NSColor) -> NSColor {
    let c = color.usingColorSpace(.deviceRGB) ?? color
    let saturation = c.saturationComponent < 0.08 ? c.saturationComponent : min(max(c.saturationComponent, 0.4), 0.6)
    return NSColor(hue: c.hueComponent, saturation: saturation, brightness: 0.34, alpha: 1)
  }

  /// Black or white, whichever reads better on `color`.
  static func text(on color: NSColor) -> NSColor {
    let c = color.usingColorSpace(.sRGB) ?? color
    let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    return luminance > 0.55 ? NSColor(white: 0.12, alpha: 1) : .white
  }
}
