import XCTest

@testable import InstantSpaceSwitcher

final class WorkspaceMoveTests: XCTestCase {
  private let laptop = CGRect(x: 0, y: 25, width: 1512, height: 920)
  private let monitor = CGRect(x: 1512, y: 25, width: 2560, height: 1415)

  func testALeftHalfStaysALeftHalfOnABiggerDisplay() {
    let leftHalf = CGRect(x: 0, y: 25, width: 756, height: 920)
    XCTAssertEqual(
      VirtualWorkspaces.translate(leftHalf, from: laptop, to: monitor),
      CGRect(x: 1512, y: 25, width: 1280, height: 1415))
  }

  func testAWindowKeepsItsPlaceRelativeToTheScreen() {
    let window = CGRect(x: 378, y: 255, width: 756, height: 460)
    let moved = VirtualWorkspaces.translate(window, from: laptop, to: monitor)
    XCTAssertEqual(moved.minX - monitor.minX, monitor.width / 4, accuracy: 1)
    XCTAssertEqual(moved.width, monitor.width / 2, accuracy: 1)
    XCTAssertEqual(moved.midY - monitor.minY, monitor.height / 2, accuracy: 1)
  }

  private func withStore(_ body: (StackingStore) -> Void) {
    let suite = "WorkspaceMoveTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(StackingStore(defaults: defaults))
  }

  func testAMovedWorkspaceTakesItsBindingsAndPauseWithIt() {
    withStore { store in
      store.bindApp(on: "workspace:a:2", bundleID: "com.apple.Safari", appName: "Safari", zone: .leftHalf)
      store.setPaused(true, spaceKey: "workspace:a:2")
      store.moveLayout(from: "workspace:a:2", to: "workspace:b:2")
      XCTAssertTrue(store.bindings(on: "workspace:a:2").isEmpty)
      XCTAssertEqual(store.bindings(on: "workspace:b:2").map(\.bundleID), ["com.apple.Safari"])
      XCTAssertFalse(store.isPaused("workspace:a:2"))
      XCTAssertTrue(store.isPaused("workspace:b:2"))
    }
  }

  func testTheMovedAppBindingReplacesOneForTheSameAppThere() {
    withStore { store in
      store.bindApp(on: "workspace:b:2", bundleID: "com.apple.Safari", appName: "Safari", zone: .rightHalf)
      store.bindApp(on: "workspace:b:2", bundleID: "com.apple.Mail", appName: "Mail", zone: .full)
      store.bindApp(on: "workspace:a:2", bundleID: "com.apple.Safari", appName: "Safari", zone: .leftHalf)
      store.moveLayout(from: "workspace:a:2", to: "workspace:b:2")
      let there = store.bindings(on: "workspace:b:2")
      XCTAssertEqual(there.filter { $0.bundleID == "com.apple.Safari" }.map(\.zone), [.leftHalf])
      XCTAssertEqual(there.filter { $0.bundleID == "com.apple.Mail" }.count, 1)
    }
  }

  // MARK: - Which workspace a binding points at

  private let screens = [
    VirtualWorkspaces.Screen(uuid: "AAAA-1111", id: 1, name: "Built-in", bounds: .zero),
    VirtualWorkspaces.Screen(uuid: "BBBB-2222", id: 2, name: "Studio", bounds: .zero),
  ]

  func testABindingKeyNamesItsDisplayAndWorkspace() {
    let home = VirtualWorkspaces.workspace(forKey: VirtualWorkspaces.key("BBBB-2222", 2), on: screens, count: 9)
    XCTAssertEqual(home?.display, "BBBB-2222")
    XCTAssertEqual(home?.index, 2)
  }

  func testABindingOnADisconnectedDisplayOrAMissingWorkspacePointsNowhere() {
    XCTAssertNil(VirtualWorkspaces.workspace(forKey: "workspace:cccc-3333:1", on: screens, count: 9))
    XCTAssertNil(VirtualWorkspaces.workspace(forKey: "workspace:aaaa-1111:12", on: screens, count: 9))
    XCTAssertNil(VirtualWorkspaces.workspace(forKey: "space:AAAA", on: screens, count: 9))
  }
}
