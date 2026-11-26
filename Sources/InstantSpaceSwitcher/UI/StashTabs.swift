import AppKit
import CubicleIPC
import SwiftUI

/// The Tabs on one edge of one display: a borderless panel over ordinary windows, on every workspace, that never
/// takes the keyboard (after Slaps' edge Tabs). `Stash` works it by where the mouse is, so it needs no buttons.
final class StashPanel: NSPanel {
  private let host = NSHostingView(rootView: StashTabsView(items: [], edge: .right, look: .icon, tabSize: .zero))

  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    acceptsMouseMovedEvents = true
    becomesKeyOnlyIfNeeded = true
    title = "Cubicle stash"
    contentView = host
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// `frame` is in Cocoa's bottom-left-origin coordinates.
  func show(_ view: StashTabsView, frame: CGRect) {
    host.rootView = view
    setFrame(frame, display: true)
    if !isVisible { orderFrontRegardless() }
  }
}

struct StashTabsView: View {
  struct Item: Identifiable {
    let id: UInt32
    let icon: NSImage?
    let title: String
    /// The app's name, which a sticky note shows.
    let appName: String
    /// A sticky note's colour.
    let color: NSColor
    /// Which of its app's stashed windows on this edge it is, when there's more than one.
    let number: Int?
    let isOut: Bool
    /// The app's Dock badge (an unread count, say), if it has one.
    var badge: String?
    /// Being dragged along the edge: drawn lifted, and the rest of the edge left alone.
    var isDragged = false
  }

  let items: [Item]
  let edge: StashEdge
  let look: StashTabLook
  let tabSize: CGSize

  var body: some View {
    let tabs = ForEach(items) { item in
      Group {
        if look.isNote {
          StashNote(item: item, edge: edge, length: edge.isVertical ? tabSize.height : tabSize.width,
                    thickness: edge.isVertical ? tabSize.width : tabSize.height, torn: look == .torn)
        } else {
          StashTab(item: item, edge: edge, look: look)
        }
      }
      .frame(width: tabSize.width, height: tabSize.height)
      .opacity(item.isDragged ? 0.85 : 1)
    }
    if edge.isVertical {
      VStack(spacing: StashLayout.spacing) { tabs }
    } else {
      HStack(spacing: StashLayout.spacing) { tabs }
    }
  }
}

private struct StashTab: View {
  let item: StashTabsView.Item
  let edge: StashEdge
  let look: StashTabLook

  var body: some View {
    let shape = EdgeTabShape(edge: edge, radius: 8)
    HStack(spacing: 6) {
      icon
      if look == .labelled {
        Text(item.title)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, look == .labelled ? 8 : 0)
    // The side against the edge is flush; keep the icon off the rounded side a little.
    .padding(edge == .left ? .trailing : edge == .right ? .leading : .bottom, look == .icon ? 2 : 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
    .overlay(shape.stroke(item.isOut ? Color.accentColor : Color.black.opacity(0.18), lineWidth: item.isOut ? 2 : 0.5))
    .clipShape(shape)
    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    .help(item.title)
  }

  private var icon: some View {
    ZStack(alignment: .bottomTrailing) {
      if let image = item.icon {
        Image(nsImage: image).resizable().interpolation(.high).frame(width: 22, height: 22)
      } else {
        Image(systemName: "macwindow").frame(width: 22, height: 22)
      }
      if let number = item.number {
        Text("\(number)")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white)
          .padding(.horizontal, 3)
          .background(Capsule().fill(Color.accentColor))
          .offset(x: 3, y: 3)
      }
    }
    .overlay(alignment: .topTrailing) {
      if let badge = item.badge { StashBadge(text: badge).offset(x: 5, y: -5) }
    }
  }
}

/// An app's Dock badge, drawn as the Dock draws it: white on red.
struct StashBadge: View {
  let text: String

  var body: some View {
    Text(text.count > 4 ? String(text.prefix(3)) + "…" : text)
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 4)
      .frame(minWidth: 14, minHeight: 14)
      .background(Capsule().fill(Color.red))
      .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
      .fixedSize()
  }
}

/// A sticky note in the app's colour, its name written along the edge: turned to read upwards on the left edge and
/// downwards on the right, flat along the top. It leans a touch, as a note stuck on by hand does. A torn note's
/// outer side is ragged, as if ripped off a pad, with the paper's paler fibres showing along the tear.
///
/// It's drawn flat, as on the top edge, and turned for the sides: its bottom is always the side facing the screen.
private struct StashNote: View {
  let item: StashTabsView.Item
  let edge: StashEdge
  let length: CGFloat
  let thickness: CGFloat
  var torn = false

  var body: some View {
    let text = Color(nsColor: StashNoteColor.text(on: item.color))
    let paper = TornPaperShape(seed: item.id, depth: torn ? 3.5 : 0)
    let label = HStack(spacing: 4) {
      Text(item.appName)
        .font(.system(size: 12, weight: .semibold, design: torn ? .serif : .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
      if let number = item.number {
        Text("\(number)").font(.system(size: 10, weight: .bold, design: .rounded)).opacity(0.6)
      }
      if let badge = item.badge { StashBadge(text: badge) }
    }
    .foregroundStyle(text)
    .padding(.horizontal, 8)
    .padding(.bottom, torn ? 3 : 0)
    .frame(width: length, height: thickness)
    .background(
      ZStack {
        LinearGradient(
          colors: [Color(nsColor: item.color), Color(nsColor: item.color.blended(withFraction: 0.08, of: .black) ?? item.color)],
          startPoint: .top, endPoint: .bottom)
        if torn {
          // The fibres along the tear: paler paper, just inside the ragged edge.
          TornPaperShape(seed: item.id, depth: 3.5, tearOnly: true).stroke(Color.white.opacity(0.55), lineWidth: 2.5)
        }
      }
      .clipShape(paper))
    .overlay(alignment: .bottom) {
      // The note's out-edge, a line in the window's accent while it's popped out.
      if item.isOut { Rectangle().fill(Color.accentColor).frame(height: 3).padding(.bottom, torn ? 4 : 0) }
    }
    .rotationEffect(.degrees(item.isDragged ? 0 : lean), anchor: .bottom)
    .shadow(color: .black.opacity(item.isDragged ? 0.35 : 0.22), radius: item.isDragged ? 4 : 1.5, x: 0, y: 1)
    .help(item.title)
    // Sideways on the sides: the long way runs along the edge, the bottom of the text faces the screen's middle.
    label
      .rotationEffect(.degrees(edge == .left ? -90 : edge == .right ? 90 : 0))
      .frame(width: edge.isVertical ? thickness : length, height: edge.isVertical ? length : thickness)
  }

  /// Up to a degree either way, the same each time for a window; a torn scrap leans a little more.
  private var lean: Double { Double(Int(item.id % 5) - 2) * (torn ? 0.9 : 0.5) }
}

/// A strip of paper whose bottom is ripped: a jagged line of uneven teeth, the same for a window each time it's drawn.
/// With no `depth`, a plain rectangle. `tearOnly` gives just the ragged line, to draw along it.
struct TornPaperShape: Shape {
  var seed: UInt32
  var depth: CGFloat
  var tearOnly = false

  func path(in rect: CGRect) -> Path {
    var path = Path()
    if !tearOnly {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    }
    guard depth > 0 else {
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.closeSubpath()
      return path
    }
    var random = SeededRandom(seed: UInt64(seed) &+ 0x9E37_79B9)
    let start = CGPoint(x: rect.maxX, y: rect.maxY - random.next() * depth)
    if tearOnly { path.move(to: start) } else { path.addLine(to: start) }
    var x = rect.maxX
    while x > rect.minX {
      x = max(rect.minX, x - 2.5 - random.next() * 4.5)
      path.addLine(to: CGPoint(x: x, y: rect.maxY - random.next() * depth))
    }
    if !tearOnly { path.closeSubpath() }
    return path
  }
}

/// A small repeatable random sequence (SplitMix64), in 0..<1.
struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> CGFloat {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return CGFloat(z >> 11) / CGFloat(1 << 53)
  }
}

/// Rounded on the sides away from the screen's edge, square against it (Slaps' `EdgeShape`, with a top edge).
struct EdgeTabShape: Shape {
  var edge: StashEdge
  var radius: CGFloat

  func path(in rect: CGRect) -> Path {
    // Which corners are rounded: those not touching the edge.
    let (topLeft, topRight, bottomLeft, bottomRight): (Bool, Bool, Bool, Bool)
    switch edge {
    case .left: (topLeft, topRight, bottomLeft, bottomRight) = (false, true, false, true)
    case .right: (topLeft, topRight, bottomLeft, bottomRight) = (true, false, true, false)
    case .top: (topLeft, topRight, bottomLeft, bottomRight) = (false, false, true, true)
    }
    let r = min(radius, rect.width / 2, rect.height / 2)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + (topLeft ? r : 0), y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - (topRight ? r : 0), y: rect.minY))
    if topRight { path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY)) }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (bottomRight ? r : 0)))
    if bottomRight { path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY)) }
    path.addLine(to: CGPoint(x: rect.minX + (bottomLeft ? r : 0), y: rect.maxY))
    if bottomLeft { path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY)) }
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (topLeft ? r : 0)))
    if topLeft { path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY)) }
    path.closeSubpath()
    return path
  }
}
