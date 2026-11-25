import XCTest

@testable import InstantSpaceSwitcher
import CubicleIPC

final class ZoneTests: XCTestCase {
  func testZonesCoverTheSnapRectangles() {
    for zone in Zone.allCases {
      XCTAssertEqual(zone.snapAction.zone, zone)
    }
    XCTAssertNil(SnapAction.center.zone)
    XCTAssertNil(SnapAction.restore.zone)
    XCTAssertEqual(Zone(name: "full"), .full)
    XCTAssertEqual(Zone(name: "maximize"), .full)
    XCTAssertEqual(Zone(name: "left"), .leftHalf)
    XCTAssertNil(Zone(name: "center"))
  }

  func testNeighboursPairUp() {
    for zone in Zone.allCases {
      for direction in Zone.Direction.allCases {
        guard let other = zone.neighbour(direction) else { continue }
        let back: Zone.Direction = [.left: .right, .right: .left, .up: .down, .down: .up][direction]!
        XCTAssertEqual(other.neighbour(back), zone, "\(zone) \(direction)")
      }
    }
    XCTAssertEqual(Zone.leftHalf.neighbour(.right), .rightHalf)
    XCTAssertNil(Zone.leftHalf.neighbour(.left))
    XCTAssertNil(Zone.full.neighbour(.right))
  }
}

final class StackPlannerTests: XCTestCase {
  private let space = "space:A"

  private func window(_ id: UInt32, _ bundle: String, opened: Int? = nil, title: String = "", document: String? = nil)
    -> LiveWindow
  {
    LiveWindow(id: id, bundleID: bundle, document: document, title: title, opened: opened ?? Int(id))
  }

  private func app(_ bundle: String, _ zone: Zone?) -> StackBinding {
    StackBinding(spaceKey: space, bundleID: bundle, appName: bundle, zone: zone)
  }

  func testBoundAppsStackInBindingOrderThenOpenOrder() {
    let windows = [window(1, "b"), window(2, "a"), window(3, "b", opened: 0), window(4, "c")]
    let plan = StackPlanner.plan(
      windows: windows, bindings: [app("a", .leftHalf), app("b", .leftHalf), app("c", .rightHalf)],
      ignored: [], membership: StackMembership())
    XCTAssertEqual(plan.stacks[.leftHalf], [2, 3, 1])
    XCTAssertEqual(plan.stacks[.rightHalf], [4])
  }

  func testSnappedWindowsFollowTheBoundOnes() {
    var membership = StackMembership()
    membership.join(9, zone: .leftHalf, home: nil)
    membership.join(8, zone: .leftHalf, home: nil)
    let plan = StackPlanner.plan(
      windows: [window(8, "x"), window(9, "y"), window(1, "a")], bindings: [app("a", .leftHalf)],
      ignored: [], membership: membership)
    XCTAssertEqual(plan.stacks[.leftHalf], [1, 9, 8])
  }

  func testPulledOutAndSnappedElsewhere() {
    var membership = StackMembership()
    membership.pullOut(1)
    membership.join(2, zone: .rightHalf, home: .leftHalf)
    let plan = StackPlanner.plan(
      windows: [window(1, "a"), window(2, "a"), window(3, "a")], bindings: [app("a", .leftHalf)],
      ignored: [], membership: membership)
    XCTAssertEqual(plan.stacks[.leftHalf], [3])
    XCTAssertEqual(plan.stacks[.rightHalf], [2])
    XCTAssertNil(plan.zone(of: 1))
    // Snapping it back into its own zone puts it home, in its bound place.
    membership.join(2, zone: .leftHalf, home: .leftHalf)
    membership.join(1, zone: .leftHalf, home: .leftHalf)
    let again = StackPlanner.plan(
      windows: [window(1, "a"), window(2, "a"), window(3, "a")], bindings: [app("a", .leftHalf)],
      ignored: [], membership: membership)
    XCTAssertEqual(again.stacks[.leftHalf], [1, 2, 3])
  }

  func testIgnoredAppsAndSpaceOnlyBindingsJoinNothing() {
    var membership = StackMembership()
    membership.join(2, zone: .full, home: nil)
    let plan = StackPlanner.plan(
      windows: [window(1, "a"), window(2, "i"), window(3, "s")],
      bindings: [app("a", .full), app("s", nil)], ignored: ["i"], membership: membership)
    XCTAssertEqual(plan.stacks[.full], [1])
    XCTAssertEqual(plan.home[3]?.bundleID, "s")
    XCTAssertNil(plan.zone(of: 3))
  }

  func testWindowBindingWinsOverAppBinding() {
    var notes = app("a", .rightHalf)
    notes.window = WindowMatch(document: "file:///notes.md", title: "notes.md", index: 5)
    let windows = [window(1, "a", title: "x"), window(2, "a", title: "notes.md", document: "file:///notes.md")]
    let plan = StackPlanner.plan(
      windows: windows, bindings: [app("a", .leftHalf), notes], ignored: [], membership: StackMembership())
    XCTAssertEqual(plan.stacks[.leftHalf], [1])
    XCTAssertEqual(plan.stacks[.rightHalf], [2])
  }

  func testWindowBindingFallsBackFromDocumentToTitleToIndex() {
    func bound(_ match: WindowMatch, _ windows: [LiveWindow]) -> UInt32? {
      var binding = app("a", .full)
      binding.window = match
      return StackPlanner.assignWindowBindings([binding], to: windows).keys.first
    }
    let windows = [window(1, "a", title: "one"), window(2, "a", title: "two"), window(3, "b", title: "two")]
    XCTAssertEqual(bound(WindowMatch(document: "gone", title: "two", index: 0), windows), 2)
    XCTAssertEqual(bound(WindowMatch(document: nil, title: "gone", index: 1), windows), 2)
    XCTAssertEqual(bound(WindowMatch(document: nil, title: nil, index: 0), windows), 1)
    XCTAssertNil(bound(WindowMatch(document: nil, title: nil, index: 4), windows))
  }

  func testTwoWindowBindingsNeverShareAWindow() {
    var first = app("a", .leftHalf)
    first.window = WindowMatch(document: nil, title: "same", index: 0)
    var second = app("a", .rightHalf)
    second.window = WindowMatch(document: nil, title: "same", index: 0)
    let assigned = StackPlanner.assignWindowBindings(
      [first, second], to: [window(1, "a", title: "same"), window(2, "a", title: "same")])
    XCTAssertEqual(assigned[1]?.id, first.id)
    XCTAssertEqual(assigned[2]?.id, second.id)
  }

  func testMatchRecordsPlaceInOpenOrder() {
    let windows = [window(5, "a", opened: 10), window(6, "a", opened: 3), window(7, "b", opened: 1)]
    XCTAssertEqual(StackPlanner.match(for: windows[0], among: windows).index, 1)
  }

  func testCycleWraps() {
    XCTAssertEqual(StackPlanner.cycle([1, 2, 3], from: 3, forward: true), 1)
    XCTAssertEqual(StackPlanner.cycle([1, 2, 3], from: 1, forward: false), 3)
    XCTAssertNil(StackPlanner.cycle([1], from: 1, forward: true))
    XCTAssertNil(StackPlanner.cycle([1, 2], from: 9, forward: true))
  }

  func testSwapTradesStacksAndKeepsOrder() {
    var membership = StackMembership()
    membership.join(9, zone: .rightHalf, home: nil)
    let bindings = [app("a", .leftHalf)]
    let windows = [window(1, "a"), window(2, "a"), window(9, "x")]
    let before = StackPlanner.plan(windows: windows, bindings: bindings, ignored: [], membership: membership)
    membership.swap(.leftHalf, .rightHalf, in: before)
    let after = StackPlanner.plan(windows: windows, bindings: bindings, ignored: [], membership: membership)
    XCTAssertEqual(after.stacks[.rightHalf], [1, 2])
    XCTAssertEqual(after.stacks[.leftHalf], [9])
    // Swapping back sends the bound windows home.
    membership.swap(.leftHalf, .rightHalf, in: after)
    let back = StackPlanner.plan(windows: windows, bindings: bindings, ignored: [], membership: membership)
    XCTAssertEqual(back.stacks[.leftHalf], [1, 2])
    XCTAssertEqual(back.stacks[.rightHalf], [9])
  }
}

final class StackingStoreTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    defaults = UserDefaults(suiteName: "StackingStoreTests")
    defaults.removePersistentDomain(forName: "StackingStoreTests")
  }

  func testRebindingAnAppReplacesItsBindingOnThatSpaceOnly() {
    let store = StackingStore(defaults: defaults)
    store.bindApp(on: "A", bundleID: "x", appName: "X", zone: .leftHalf)
    store.bindApp(on: "B", bundleID: "x", appName: "X", zone: .full)
    store.bindApp(on: "A", bundleID: "y", appName: "Y", zone: .leftHalf)
    store.bindApp(on: "A", bundleID: "x", appName: "X", zone: .rightHalf)
    XCTAssertEqual(store.bindings(on: "A").map(\.bundleID), ["y", "x"])
    XCTAssertEqual(store.appBinding(on: "A", bundleID: "x")?.zone, .rightHalf)
    XCTAssertEqual(store.appBinding(on: "B", bundleID: "x")?.zone, .full)
    // Saved.
    XCTAssertEqual(StackingStore(defaults: defaults).settings, store.settings)
  }

  func testIgnoringAnAppDropsItsBindings() {
    let store = StackingStore(defaults: defaults)
    store.bindApp(on: "A", bundleID: "x", appName: "X", zone: .leftHalf)
    store.setIgnored(true, bundleID: "x", appName: "X")
    XCTAssertTrue(store.isIgnored("x"))
    XCTAssertTrue(store.bindings(on: "A").isEmpty)
  }

  func testPauses() {
    let store = StackingStore(defaults: defaults)
    store.setPaused(true, spaceKey: "A")
    XCTAssertTrue(store.isPaused("A"))
    XCTAssertFalse(store.isPaused("B"))
    store.setPausedEverywhere(true)
    XCTAssertTrue(store.isPaused("B"))
    store.setPausedEverywhere(false)
    // The global pause leaves each Space's own setting alone.
    XCTAssertTrue(store.isPaused("A"))
  }
}
