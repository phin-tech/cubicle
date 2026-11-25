import AppKit
import CoreGraphics
import XCTest

@testable import InstantSpaceSwitcher
import CubicleIPC

final class StashLayoutTests: XCTestCase {
  // A 1440×875 usable area below a 25 pt menu bar.
  private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

  private func layout(_ edge: StashEdge, _ look: StashTabLook = .icon) -> StashLayout {
    StashLayout(edge: edge, look: look, visible: visible)
  }

  func testEdgeNames() {
    XCTAssertEqual(StashEdge(name: "Left"), .left)
    XCTAssertEqual(StashEdge(name: "up"), .top)
    XCTAssertNil(StashEdge(name: "bottom"))
    XCTAssertEqual(StashEdge.matching("top"), [.top])
    XCTAssertEqual(StashEdge.matching(""), StashEdge.allCases)
  }

  func testTabsSitAgainstTheirEdgeCentred() {
    let left = layout(.left).strip(count: 3)
    XCTAssertEqual(left.minX, visible.minX)
    XCTAssertEqual(left.midY, visible.midY)
    let right = layout(.right).strip(count: 1)
    XCTAssertEqual(right.maxX, visible.maxX)
    let top = layout(.top).strip(count: 2)
    XCTAssertEqual(top.minY, visible.minY)
    XCTAssertEqual(top.midX, visible.midX)
  }

  func testTabsDontOverlap() {
    let l = layout(.right)
    let tabs = (0..<4).map { l.tab($0, of: 4) }
    for (a, b) in zip(tabs, tabs.dropFirst()) {
      XCTAssertFalse(a.intersects(b))
      XCTAssertEqual(b.minY - a.maxY, StashLayout.spacing)
    }
    XCTAssertEqual(tabs.first!.minY, l.strip(count: 4).minY)
    XCTAssertEqual(tabs.last!.maxY, l.strip(count: 4).maxY)
  }

  func testPoppedWindowSitsBesideItsTab() {
    let l = layout(.left)
    let tab = l.tab(0, of: 1)
    let frame = l.popped(CGSize(width: 600, height: 400), from: tab)
    XCTAssertEqual(frame.minX, visible.minX + l.thickness)
    XCTAssertEqual(frame.midY, tab.midY)
    XCTAssertEqual(frame.size, CGSize(width: 600, height: 400))

    let r = layout(.right, .labelled)
    let rightFrame = r.popped(CGSize(width: 600, height: 400), from: r.tab(0, of: 1))
    XCTAssertEqual(rightFrame.maxX, visible.maxX - r.thickness)

    let t = layout(.top)
    let topFrame = t.popped(CGSize(width: 800, height: 500), from: t.tab(0, of: 1))
    XCTAssertEqual(topFrame.minY, visible.minY + t.thickness)
    XCTAssertEqual(topFrame.midX, visible.midX)
  }

  func testPoppedWindowStaysOnTheDisplay() {
    let l = layout(.right)
    // A tall window against a Tab near the bottom is pushed up, and one too big is shrunk.
    let frame = l.popped(CGSize(width: 2000, height: 2000), from: l.tab(3, of: 4))
    XCTAssertTrue(visible.contains(frame))
    XCTAssertEqual(frame.width, visible.width - l.thickness)
    XCTAssertEqual(frame.height, visible.height)
  }

  func testSlotsPutTabsAtTheEnds() {
    let l = layout(.right)
    XCTAssertEqual(l.strip(count: 2, slot: .start).minY, visible.minY + StashLayout.margin)
    XCTAssertEqual(l.strip(count: 2, slot: .end).maxY, visible.maxY - StashLayout.margin)
    XCTAssertEqual(l.strip(count: 2, slot: .middle).midY, visible.midY)
    let t = layout(.top, .note)
    XCTAssertEqual(t.strip(count: 1, slot: .start).minX, visible.minX + StashLayout.margin)
    XCTAssertEqual(t.strip(count: 1, slot: .end).maxX, visible.maxX - StashLayout.margin)
  }

  func testDroppingPicksTheThirdOfTheEdge() {
    let l = layout(.left)
    XCTAssertEqual(l.slot(at: CGPoint(x: 5, y: visible.minY + 10)), .start)
    XCTAssertEqual(l.slot(at: CGPoint(x: 5, y: visible.midY)), .middle)
    XCTAssertEqual(l.slot(at: CGPoint(x: 5, y: visible.maxY - 10)), .end)
    XCTAssertEqual(layout(.top).slot(at: CGPoint(x: visible.maxX - 10, y: 30)), .end)
  }

  func testTabsGoWhereverTheyAreDropped() {
    let l = layout(.left)
    let point = CGPoint(x: 5, y: visible.minY + visible.height * 0.3)
    XCTAssertEqual(l.position(at: point), 0.3, accuracy: 0.0001)
    XCTAssertEqual(l.strip(count: 1, at: 0.3).midY, point.y, accuracy: 0.0001)
    // Past the ends, they stop short of the corners.
    XCTAssertEqual(l.strip(count: 1, at: 0).minY, visible.minY + StashLayout.margin)
    XCTAssertEqual(l.position(at: CGPoint(x: 5, y: 5000)), 1)
  }

  func testPlacesCloseTogetherPushApart() {
    let l = layout(.right)
    let strips = l.strips([(2, 0.5), (1, 0.52), (1, 0.0), (3, 1.0), (1, 0.99)])
    let sorted = strips.sorted { $0.minY < $1.minY }
    for (a, b) in zip(sorted, sorted.dropFirst()) {
      XCTAssertGreaterThanOrEqual(b.minY - a.maxY, StashLayout.spacing - 0.0001, "\(a) and \(b) overlap")
    }
    XCTAssertGreaterThanOrEqual(sorted.first!.minY, visible.minY)
    XCTAssertLessThanOrEqual(sorted.last!.maxY, visible.maxY - StashLayout.margin + 0.0001)
    // One on its own is left where it was put.
    XCTAssertEqual(l.strips([(1, 0.3)]), [l.strip(count: 1, at: 0.3)])
  }

  func testDraggingNearAnEdgePicksIt() {
    XCTAssertEqual(StashLayout.nearestEdge(to: CGPoint(x: 10, y: 400), in: visible), .left)
    XCTAssertEqual(StashLayout.nearestEdge(to: CGPoint(x: 1400, y: 500), in: visible), .right)
    XCTAssertEqual(StashLayout.nearestEdge(to: CGPoint(x: 700, y: 40), in: visible), .top)
    // Near the bottom, it's whichever side is nearer.
    XCTAssertEqual(StashLayout.nearestEdge(to: CGPoint(x: 300, y: 890), in: visible), .left)
  }

  func testSlotNames() {
    XCTAssertEqual(StashSlot(name: "bottom"), .end)
    XCTAssertEqual(StashSlot(name: "Left"), .start)
    XCTAssertEqual(StashSlot(name: "center"), .middle)
    XCTAssertNil(StashSlot(name: "sideways"))
    XCTAssertEqual(StashSlot.start.displayName(on: .right), "Top")
    XCTAssertEqual(StashSlot.end.displayName(on: .top), "Right")
  }

  func testNotesRunAlongTheEdge() {
    let side = layout(.left, .note)
    XCTAssertGreaterThan(side.tabSize.height, side.tabSize.width)
    let top = layout(.top, .note)
    XCTAssertGreaterThan(top.tabSize.width, top.tabSize.height)
  }

  func testNoteShadesAreLightAndReadable() {
    let deepBlue = NSColor(srgbRed: 0.05, green: 0.2, blue: 0.7, alpha: 1)
    let shade = StashNoteColor.noteShade(deepBlue).usingColorSpace(.deviceRGB)!
    XCTAssertGreaterThanOrEqual(shade.brightnessComponent, 0.93)
    XCTAssertEqual(shade.hueComponent, deepBlue.usingColorSpace(.deviceRGB)!.hueComponent, accuracy: 0.01)
    for colour in StashNoteColor.allCases {
      XCTAssertNotEqual(StashNoteColor.text(on: colour.color), .white, "\(colour) wants dark text")
    }
  }

  func testIconColourFindsTheMainHue() {
    let red = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      NSColor.systemRed.setFill()
      rect.insetBy(dx: 4, dy: 4).fill()
      return true
    }
    let hue = StashNoteColor.iconColor(red)?.usingColorSpace(.deviceRGB)?.hueComponent
    XCTAssertNotNil(hue)
    XCTAssertTrue(hue! < 0.05 || hue! > 0.95, "found hue \(hue!)")
    let grey = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
      NSColor.gray.setFill()
      rect.fill()
      return true
    }
    XCTAssertNil(StashNoteColor.iconColor(grey))
  }

  func testStashShortcutsAreTheirOwn() {
    XCTAssertEqual(HotkeyIdentifier.stashTop.stashEdge, .top)
    XCTAssertTrue(HotkeyIdentifier.stashLeft.enabledByDefault)
    XCTAssertFalse(HotkeyIdentifier.windowShortcutGroup.contains(.stashRight))
    let combos = HotkeyIdentifier.allCases.map(\.defaultCombination)
    for stash in [HotkeyIdentifier.stashLeft, .stashRight, .stashTop] {
      XCTAssertEqual(combos.filter { $0 == stash.defaultCombination }.count, 1, "\(stash) shares its default key")
    }
  }
}
