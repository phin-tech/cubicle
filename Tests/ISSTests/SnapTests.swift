import CoreGraphics
import XCTest

@testable import InstantSpaceSwitcher
import CubicleIPC

final class SnapGeometryTests: XCTestCase {
  // A 1440×875 usable area below a 25 pt menu bar.
  private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
  private let window = CGRect(x: 100, y: 100, width: 600, height: 400)

  private func frame(_ action: SnapAction, gap: CGFloat = 0, visible: CGRect? = nil) -> CGRect? {
    SnapGeometry.frame(for: action, window: window, visible: visible ?? self.visible, gap: gap)
  }

  func testHalves() {
    XCTAssertEqual(frame(.leftHalf), CGRect(x: 0, y: 25, width: 720, height: 875))
    XCTAssertEqual(frame(.rightHalf), CGRect(x: 720, y: 25, width: 720, height: 875))
    XCTAssertEqual(frame(.topHalf), CGRect(x: 0, y: 25, width: 1440, height: 437))
    XCTAssertEqual(frame(.bottomHalf), CGRect(x: 0, y: 462, width: 1440, height: 438))
  }

  func testOddSizesLeaveNoSeam() {
    let odd = CGRect(x: 0, y: 0, width: 1441, height: 901)
    let left = frame(.leftHalf, visible: odd)!
    let right = frame(.rightHalf, visible: odd)!
    XCTAssertEqual(left.maxX, right.minX)
    XCTAssertEqual(right.maxX, odd.maxX)
    let top = frame(.topLeft, visible: odd)!
    let bottom = frame(.bottomLeft, visible: odd)!
    XCTAssertEqual(top.maxY, bottom.minY)
    XCTAssertEqual(bottom.maxY, odd.maxY)
  }

  func testQuartersTileTheScreen() {
    let quarters: [SnapAction] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    let area = quarters.compactMap { frame($0) }.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
    XCTAssertEqual(area, visible.width * visible.height)
    XCTAssertEqual(frame(.bottomRight), CGRect(x: 720, y: 462, width: 720, height: 438))
  }

  func testMaximizeFillsTheUsableArea() {
    XCTAssertEqual(frame(.maximize), visible)
  }

  func testCenterKeepsTheSize() {
    XCTAssertEqual(frame(.center), CGRect(x: 420, y: 263, width: 600, height: 400))
  }

  func testCenterKeepsAnOversizedWindowOnScreen() {
    let big = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let centered = SnapGeometry.frame(for: .center, window: big, visible: visible, gap: 0)!
    XCTAssertEqual(centered.origin, visible.origin)
  }

  func testRestoreHasNoFrameOfItsOwn() {
    XCTAssertNil(frame(.restore))
  }

  func testGapIsFullAtScreenEdgesAndHalfOnSharedEdges() {
    let left = frame(.leftHalf, gap: 10)!
    let right = frame(.rightHalf, gap: 10)!
    XCTAssertEqual(left, CGRect(x: 10, y: 35, width: 705, height: 855))
    XCTAssertEqual(right.minX - left.maxX, 10)
    XCTAssertEqual(visible.maxX - right.maxX, 10)
    XCTAssertEqual(frame(.maximize, gap: 10), visible.insetBy(dx: 10, dy: 10))
  }

  func testOddGapStillSeparatesNeighboursByOneGap() {
    let left = frame(.leftHalf, gap: 5)!
    let right = frame(.rightHalf, gap: 5)!
    XCTAssertEqual(right.minX - left.maxX, 5)
    XCTAssertEqual(left.minX, 5)
  }

  func testGapDoesNotApplyToCenter() {
    XCTAssertEqual(frame(.center, gap: 10), frame(.center))
  }

  func testOversizedGapIsIgnored() {
    XCTAssertEqual(frame(.topLeft, gap: 2000), frame(.topLeft))
  }

  func testWindowThatWontShrinkStaysAgainstTheScreenEdge() {
    let target = frame(.leftHalf)!
    let placed = SnapGeometry.aligned(CGSize(width: 800, height: 600), in: target, visible: visible)
    XCTAssertEqual(placed.minX, 0)
    // Neither vertical edge is special for a half, so it is centred top to bottom.
    XCTAssertEqual(placed.midY, target.midY, accuracy: 1)

    let corner = SnapGeometry.aligned(CGSize(width: 800, height: 600), in: frame(.bottomRight)!, visible: visible)
    XCTAssertEqual(corner.maxX, visible.maxX)
    XCTAssertEqual(corner.maxY, visible.maxY)
  }

  func testAlignmentAllowsForTheGap() {
    let target = frame(.rightHalf, gap: 10)!
    let placed = SnapGeometry.aligned(CGSize(width: 500, height: 300), in: target, visible: visible, gap: 10)
    XCTAssertEqual(placed.maxX, target.maxX)
  }

  func testScreenPicking() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let side = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
    XCTAssertEqual(SnapGeometry.screenIndex(for: CGRect(x: 10, y: 10, width: 100, height: 100), screens: [main, side]), 0)
    // Mostly on the second display.
    XCTAssertEqual(SnapGeometry.screenIndex(for: CGRect(x: 1400, y: 10, width: 400, height: 100), screens: [main, side]), 1)
    // Off every display.
    XCTAssertEqual(SnapGeometry.screenIndex(for: CGRect(x: -5000, y: 0, width: 10, height: 10), screens: [main, side], fallback: 1), 1)
    XCTAssertNil(SnapGeometry.screenIndex(for: .zero, screens: []))
  }

  func testFlipUsesThePrimaryDisplay() {
    // A display above a 900 pt primary display, in AppKit coordinates.
    let appKit = CGRect(x: 0, y: 900, width: 1920, height: 1080)
    XCTAssertEqual(SnapGeometry.flipped(appKit, primaryHeight: 900), CGRect(x: 0, y: -1080, width: 1920, height: 1080))
  }

  func testActionNames() {
    XCTAssertEqual(SnapAction(name: "left-half"), .leftHalf)
    XCTAssertEqual(SnapAction(name: "Left_Half"), .leftHalf)
    XCTAssertEqual(SnapAction(name: "full"), .maximize)
    XCTAssertEqual(SnapAction(name: "top"), .topHalf)
    XCTAssertNil(SnapAction(name: "thirds"))
    XCTAssertEqual(Set(SnapAction.allCases.map(\.displayName)).count, SnapAction.allCases.count)
  }
}

final class SnapHistoryTests: XCTestCase {
  private let original = CGRect(x: 100, y: 100, width: 600, height: 400)
  private let left = CGRect(x: 0, y: 25, width: 720, height: 875)
  private let corner = CGRect(x: 0, y: 25, width: 720, height: 437)

  func testRestoreGoesBackToTheFrameBeforeTheFirstSnap() {
    var history = SnapHistory()
    history.willSnap(7, from: original)
    history.didSnap(7, to: left)
    history.willSnap(7, from: left)
    history.didSnap(7, to: corner)
    XCTAssertEqual(history.takeRestore(7), original)
  }

  func testMovingByHandStartsAgain() {
    var history = SnapHistory()
    history.willSnap(7, from: original)
    history.didSnap(7, to: left)
    let moved = CGRect(x: 300, y: 300, width: 500, height: 500)
    history.willSnap(7, from: moved)
    history.didSnap(7, to: corner)
    XCTAssertEqual(history.takeRestore(7), moved)
  }

  func testSmallDifferencesStillCountAsTheSnappedFrame() {
    var history = SnapHistory()
    history.willSnap(7, from: original)
    history.didSnap(7, to: left)
    history.willSnap(7, from: left.offsetBy(dx: 1, dy: 0))
    XCTAssertEqual(history.takeRestore(7), original)
  }

  func testRestoreLetsGo() {
    var history = SnapHistory()
    history.willSnap(7, from: original)
    history.didSnap(7, to: left)
    XCTAssertNotNil(history.takeRestore(7))
    XCTAssertNil(history.takeRestore(7))
  }

  func testUnknownWindowHasNothingToRestore() {
    var history = SnapHistory()
    XCTAssertNil(history.takeRestore(1))
  }

  func testPruneDropsClosedWindows() {
    var history = SnapHistory()
    history.willSnap(1, from: original)
    history.willSnap(2, from: original)
    history.prune(keeping: [2])
    XCTAssertEqual(Array(history.entries.keys), [2])
  }
}
