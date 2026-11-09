import CoreGraphics
import CubicleIPC
import Foundation

/// Frame maths for snaps. Every rect here is in top-left-origin screen coordinates, the space Accessibility uses,
/// so nothing is flipped between calculating a frame and applying it.
enum SnapGeometry {
  /// Where `action` puts a window whose frame is `window`, on a display whose usable area is `visible`.
  /// Returns nil for Restore, which is answered by `SnapHistory`.
  static func frame(for action: SnapAction, window: CGRect, visible: CGRect, gap: CGFloat) -> CGRect? {
    if action == .center { return centered(window.size, in: visible) }
    guard let region = action.region else { return nil }
    return applyGap(rect(for: region, in: visible), visible: visible, gap: gap)
  }

  /// The region on whole points. Splits round the first part down and give the rest to the second, so two halves
  /// always meet without a seam or an overlap.
  static func rect(for region: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat), in visible: CGRect) -> CGRect {
    func edge(_ fraction: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat {
      fraction >= 1 ? start + length : start + (length * fraction).rounded(.down)
    }
    let minX = edge(region.x, visible.minX, visible.width)
    let maxX = edge(region.x + region.width, visible.minX, visible.width)
    let minY = edge(region.y, visible.minY, visible.height)
    let maxY = edge(region.y + region.height, visible.minY, visible.height)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// The full gap against the display's edges and half a gap on each side of an edge shared with a neighbouring
  /// region, so neighbours end up exactly one gap apart.
  static func applyGap(_ rect: CGRect, visible: CGRect, gap: CGFloat) -> CGRect {
    guard gap > 0 else { return rect }
    let gap = gap.rounded()
    // An odd gap splits unevenly (the far side takes the extra point) so neighbours stay on whole points and
    // exactly one gap apart.
    func inset(_ onScreenEdge: Bool, farSide: Bool) -> CGFloat {
      onScreenEdge ? gap : farSide ? (gap / 2).rounded(.up) : (gap / 2).rounded(.down)
    }
    let left = inset(abs(rect.minX - visible.minX) < 1, farSide: false)
    let right = inset(abs(rect.maxX - visible.maxX) < 1, farSide: true)
    let top = inset(abs(rect.minY - visible.minY) < 1, farSide: false)
    let bottom = inset(abs(rect.maxY - visible.maxY) < 1, farSide: true)
    let width = rect.width - left - right
    let height = rect.height - top - bottom
    // A gap larger than the region would turn it inside out (CGRect would quietly flip a negative size).
    guard width >= 1, height >= 1 else { return rect }
    return CGRect(x: rect.minX + left, y: rect.minY + top, width: width, height: height)
  }

  /// `size` moved to the middle of `visible`, kept on screen (a window larger than the display sits at its top-left).
  static func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
    let x = max(visible.minX, (visible.midX - size.width / 2).rounded())
    let y = max(visible.minY, (visible.midY - size.height / 2).rounded())
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// Where a window that kept `size` (it would not take the target size) goes in `target`. It stays against
  /// whichever of the target's edges are the display's, so a left-half window that can't shrink is still flush
  /// left; otherwise it is centred on that axis. It is then kept on the display where possible.
  static func aligned(_ size: CGSize, in target: CGRect, visible: CGRect, gap: CGFloat = 0) -> CGRect {
    // A region against the display's edge sits one gap in from it.
    let reach = max(gap, 0) + 1
    func position(start: CGFloat, end: CGFloat, length: CGFloat, screenStart: CGFloat, screenEnd: CGFloat) -> CGFloat {
      let atStart = abs(start - screenStart) < reach
      let atEnd = abs(end - screenEnd) < reach
      var value: CGFloat
      if atStart && !atEnd {
        value = start
      } else if atEnd && !atStart {
        value = end - length
      } else {
        value = ((start + end) / 2 - length / 2).rounded()
      }
      value = min(value, screenEnd - length)
      return max(value, screenStart)
    }
    let x = position(
      start: target.minX, end: target.maxX, length: size.width,
      screenStart: visible.minX, screenEnd: visible.maxX)
    let y = position(
      start: target.minY, end: target.maxY, length: size.height,
      screenStart: visible.minY, screenEnd: visible.maxY)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// Which display a window is on: the first whose frame holds all of it, else the one holding most of it, else
  /// `fallback` (an index into `screens`). `screens` are display frames in the same coordinates as `window`.
  static func screenIndex(for window: CGRect, screens: [CGRect], fallback: Int = 0) -> Int? {
    guard !screens.isEmpty else { return nil }
    if let index = screens.firstIndex(where: { $0.contains(window) }) { return index }
    var best: (index: Int, area: CGFloat)?
    for (index, screen) in screens.enumerated() {
      let overlap = screen.intersection(window)
      guard !overlap.isNull else { continue }
      let area = overlap.width * overlap.height
      if area > (best?.area ?? 0) { best = (index, area) }
    }
    return best?.index ?? min(max(fallback, 0), screens.count - 1)
  }

  /// Converts an AppKit rect (bottom-left origin) to top-left origin. Both spaces measure from the primary
  /// display, so one flip against its height works for every display, whatever their sizes.
  static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  /// Frames that differ by less than this are the same: apps round sizes to their own grid (terminals to cells).
  static let tolerance: CGFloat = 2

  static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
      && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
  }
}

/// What Restore needs: the frame each window had before Cubicle first snapped it.
struct SnapHistory {
  struct Entry: Equatable {
    /// Where Restore puts the window.
    var restore: CGRect
    /// The frame the window had right after Cubicle last moved it.
    var lastSet: CGRect
  }

  private(set) var entries: [UInt32: Entry] = [:]

  /// Call before snapping a window that is at `current`. The first snap records `current` as the frame to restore
  /// to; so does any snap after the window was moved or resized by hand. Chained snaps keep the original frame.
  mutating func willSnap(_ id: UInt32, from current: CGRect) {
    if let entry = entries[id], SnapGeometry.roughlyEqual(entry.lastSet, current) { return }
    entries[id] = Entry(restore: current, lastSet: current)
  }

  /// Call after the snap, with the frame the window actually ended up with.
  mutating func didSnap(_ id: UInt32, to frame: CGRect) {
    entries[id]?.lastSet = frame
  }

  /// The frame to restore to, if Cubicle has snapped this window. Restoring lets go of the window, so the entry
  /// is removed: a second Restore does nothing.
  mutating func takeRestore(_ id: UInt32) -> CGRect? {
    entries.removeValue(forKey: id)?.restore
  }

  /// Drops windows that no longer exist.
  mutating func prune(keeping live: Set<UInt32>) {
    entries = entries.filter { live.contains($0.key) }
  }
}
