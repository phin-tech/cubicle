import CoreGraphics
import CubicleIPC

/// How a stash Tab looks: the app's icon alone, the icon and the window's title, or a sticky note in the app's
/// colour with its name written along the edge, either neat or torn off a pad.
enum StashTabLook: String, CaseIterable {
  case icon
  case labelled
  case note
  case torn

  /// A note of either kind: coloured, with the app's name along it.
  var isNote: Bool { self == .note || self == .torn }

  static let defaultsKey = "stashTabLook"

  var displayName: String {
    switch self {
    case .icon: return "Icon only"
    case .labelled: return "Icon and title"
    case .note: return "Sticky note"
    case .torn: return "Torn paper"
    }
  }
}

/// What brings a stashed window out of its Tab.
enum StashOpen: String, CaseIterable {
  case hover
  case click
  /// Clicking, with a preview of the window while you point at its Tab.
  case peek

  static let defaultsKey = "stashOpenOn"

  var displayName: String {
    switch self {
    case .hover: return "Pointing at its Tab"
    case .click: return "Clicking its Tab"
    case .peek: return "Clicking its Tab, with a preview"
    }
  }

  var isClick: Bool { self != .hover }
}

/// What tucks a popped-out window away again (besides clicking its Tab).
enum StashHide: String, CaseIterable {
  case mouseOut
  case clickOut

  static let defaultsKey = "stashHideWhen"

  var displayName: String {
    switch self {
    case .mouseOut: return "The mouse leaves it"
    case .clickOut: return "You click somewhere else"
    }
  }
}

/// Where stash Tabs and popped-out windows go on one edge of one display. Pure maths, in top-left-origin global
/// coordinates as Accessibility uses, so it can be tested without windows.
struct StashLayout {
  let edge: StashEdge
  let look: StashTabLook
  /// The display's usable area (no menu bar or Dock).
  let visible: CGRect

  static let spacing: CGFloat = 4
  /// How far the Tabs at the start or end of an edge keep from its corners.
  static let margin: CGFloat = 12
  /// How far a Tab stands out from the edge: what a popped-out window leaves free beside it.
  var thickness: CGFloat {
    switch look {
    case .icon: return edge.isVertical ? 32 : 30
    case .labelled: return edge.isVertical ? 168 : 30
    case .note, .torn: return 30
    }
  }
  /// A Tab's length along the edge. A note's name runs along it.
  var length: CGFloat {
    switch look {
    case .icon: return edge.isVertical ? 38 : 40
    case .labelled: return edge.isVertical ? 38 : 168
    case .note, .torn: return 104
    }
  }

  var tabSize: CGSize {
    edge.isVertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
  }

  /// The strip holding `count` Tabs in `slot`, against the edge: from the start, centred, or up to the end.
  func strip(count: Int, slot: StashSlot = .middle) -> CGRect {
    strip(count: count, at: slot.position)
  }

  /// The strip holding `count` Tabs centred at `position` along the edge (0 its start, 1 its end), kept `margin`
  /// from the corners.
  func strip(count: Int, at position: CGFloat) -> CGRect {
    let n = CGFloat(max(count, 1))
    let along = n * length + (n - 1) * Self.spacing
    let (low, high) = range
    let centre = low + (high - low) * min(max(position, 0), 1)
    let start = max(low + Self.margin, min(centre - along / 2, high - Self.margin - along))
    return rect(start: start, along: along)
  }

  /// The strips for several places on this edge, each as near its position as it can be without overlapping the
  /// others. `places` are (number of Tabs, position); the strips come back in the same order.
  func strips(_ places: [(count: Int, position: CGFloat)]) -> [CGRect] {
    var strips = places.map { strip(count: $0.count, at: $0.position) }
    let order = strips.indices.sorted { start(of: strips[$0]) < start(of: strips[$1]) }
    // Push each one past the one before it, then pull them back from the far end if that ran over.
    for (a, b) in zip(order, order.dropFirst()) where start(of: strips[b]) < end(of: strips[a]) + Self.spacing {
      strips[b] = rect(start: end(of: strips[a]) + Self.spacing, along: size(of: strips[b]))
    }
    if let last = order.last, end(of: strips[last]) > range.high - Self.margin {
      strips[last] = rect(start: range.high - Self.margin - size(of: strips[last]), along: size(of: strips[last]))
      for (b, a) in zip(order.reversed(), order.reversed().dropFirst())
      where end(of: strips[a]) + Self.spacing > start(of: strips[b]) {
        strips[a] = rect(start: start(of: strips[b]) - Self.spacing - size(of: strips[a]), along: size(of: strips[a]))
      }
    }
    return strips
  }

  /// Where along the edge `point` is: 0 at its start, 1 at its end.
  func position(at point: CGPoint) -> CGFloat {
    let (low, high) = range
    let value = edge.isVertical ? point.y : point.x
    return min(max((value - low) / (high - low), 0), 1)
  }

  /// The slot a Tab dropped at `point` goes to: whichever third of the edge it's in.
  func slot(at point: CGPoint) -> StashSlot {
    let p = position(at: point)
    return p < 1.0 / 3 ? .start : p > 2.0 / 3 ? .end : .middle
  }

  /// How far from every edge a dragged Tab has to be to tear off, unstashing its window where it's let go.
  static let tearOff: CGFloat = 120

  /// The edge a window being dragged is pushed against: the mouse at the very edge of a display, where there's no
  /// other display to carry on into. `display` and `others` are full display frames.
  static func pushedEdge(_ mouse: CGPoint, on display: CGRect, among others: [CGRect]) -> StashEdge? {
    let reach: CGFloat = 2
    func open(_ point: CGPoint) -> Bool { !others.contains { $0.contains(point) } }
    if mouse.x <= display.minX + reach, open(CGPoint(x: display.minX - reach - 1, y: mouse.y)) { return .left }
    if mouse.x >= display.maxX - reach - 1, open(CGPoint(x: display.maxX + reach, y: mouse.y)) { return .right }
    if mouse.y <= display.minY + reach, open(CGPoint(x: mouse.x, y: display.minY - reach - 1)) { return .top }
    return nil
  }

  /// Whether a Tab dragged to `point` has come away from the edges: farther than `tearOff` from the left, right and
  /// top of `visible`.
  static func isTornOff(_ point: CGPoint, in visible: CGRect) -> Bool {
    min(abs(point.x - visible.minX), abs(visible.maxX - point.x), abs(point.y - visible.minY)) > tearOff
  }

  /// Where a window of `size` goes when its Tab is torn off and let go at `point`: its title bar under the mouse,
  /// kept on the display and shrunk to fit it.
  static func torn(_ size: CGSize, at point: CGPoint, in visible: CGRect) -> CGRect {
    let width = min(size.width, visible.width)
    let height = min(size.height, visible.height)
    let x = max(visible.minX, min(point.x - width / 2, visible.maxX - width))
    let y = max(visible.minY, min(point.y - 14, visible.maxY - height))
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// The edge of `visible` nearest `point`. The bottom is never one: a point nearest it goes to whichever of the
  /// others is nearer.
  static func nearestEdge(to point: CGPoint, in visible: CGRect) -> StashEdge {
    let distances: [(StashEdge, CGFloat)] = [
      (.left, abs(point.x - visible.minX)), (.right, abs(visible.maxX - point.x)), (.top, abs(point.y - visible.minY)),
    ]
    return distances.min { $0.1 < $1.1 }!.0
  }

  /// Tab `index` of `count` in `slot`, top to bottom or left to right.
  func tab(_ index: Int, of count: Int, slot: StashSlot = .middle) -> CGRect {
    tab(index, in: strip(count: count, slot: slot))
  }

  /// Tab `index` in `strip`.
  func tab(_ index: Int, in strip: CGRect) -> CGRect {
    let offset = CGFloat(index) * (length + Self.spacing)
    return edge.isVertical
      ? CGRect(x: strip.minX, y: strip.minY + offset, width: thickness, height: length)
      : CGRect(x: strip.minX + offset, y: strip.minY, width: length, height: thickness)
  }

  /// One Tab centred at `point`'s place along the edge, as it's drawn while being dragged.
  func tab(following point: CGPoint) -> CGRect {
    let (low, high) = range
    let value = edge.isVertical ? point.y : point.x
    return rect(start: min(max(value - length / 2, low), high - length), along: length)
  }

  private var range: (low: CGFloat, high: CGFloat) {
    edge.isVertical ? (visible.minY, visible.maxY) : (visible.minX, visible.maxX)
  }

  private func rect(start: CGFloat, along: CGFloat) -> CGRect {
    switch edge {
    case .left: return CGRect(x: visible.minX, y: start, width: thickness, height: along)
    case .right: return CGRect(x: visible.maxX - thickness, y: start, width: thickness, height: along)
    case .top: return CGRect(x: start, y: visible.minY, width: along, height: thickness)
    }
  }

  private func start(of strip: CGRect) -> CGFloat { edge.isVertical ? strip.minY : strip.minX }
  private func end(of strip: CGRect) -> CGFloat { edge.isVertical ? strip.maxY : strip.maxX }
  private func size(of strip: CGRect) -> CGFloat { edge.isVertical ? strip.height : strip.width }

  /// Where a window of `size` sits when it pops out of `tab`: beside the Tabs, against the edge, centred on its Tab
  /// as far as the display allows. A window too big for the room left is shrunk to fit.
  func popped(_ size: CGSize, from tab: CGRect) -> CGRect {
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(value, high)) }
    switch edge {
    case .left, .right:
      let width = min(size.width, visible.width - thickness)
      let height = min(size.height, visible.height)
      let x = edge == .left ? visible.minX + thickness : visible.maxX - thickness - width
      let y = clamp(tab.midY - height / 2, visible.minY, visible.maxY - height)
      return CGRect(x: x, y: y, width: width, height: height)
    case .top:
      let width = min(size.width, visible.width)
      let height = min(size.height, visible.height - thickness)
      let x = clamp(tab.midX - width / 2, visible.minX, visible.maxX - width)
      return CGRect(x: x, y: visible.minY + thickness, width: width, height: height)
    }
  }
}

extension StashSlot {
  /// Where along its edge this slot puts Tabs: the start, the middle or the end.
  var position: CGFloat {
    switch self {
    case .start: return 0
    case .middle: return 0.5
    case .end: return 1
    }
  }

  /// The slot at exactly `position`, if it's one of theirs.
  init?(position: CGFloat) {
    guard let slot = StashSlot.allCases.first(where: { $0.position == position }) else { return nil }
    self = slot
  }
}
