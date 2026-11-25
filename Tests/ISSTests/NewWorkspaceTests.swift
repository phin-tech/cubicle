import XCTest

@testable import InstantSpaceSwitcher

final class NewWorkspaceTests: XCTestCase {
  func testTakesTheFirstWorkspaceWithNoWindowsNameOrLayout() {
    XCTAssertEqual(
      VirtualWorkspaces.unusedWorkspace(count: 9, occupied: [0, 1], used: [2], showing: 0), 3)
  }

  func testNeverTakesTheWorkspaceThatIsShowing() {
    XCTAssertEqual(VirtualWorkspaces.unusedWorkspace(count: 3, occupied: [1], used: [], showing: 0), 2)
  }

  func testAddsOneWhenEveryWorkspaceIsInUse() {
    XCTAssertEqual(
      VirtualWorkspaces.unusedWorkspace(count: 3, occupied: [0, 1], used: [2], showing: 0), 3)
  }

  func testKeepsAddingPastSixteen() {
    XCTAssertEqual(
      VirtualWorkspaces.unusedWorkspace(count: 16, occupied: Set(0..<16), used: [], showing: 0), 16)
  }
}
