import XCTest

@testable import InstantSpaceSwitcher

final class StrandedWindowTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 3360, height: 1890)
  private let usable = CGRect(x: 0, y: 31, width: 3360, height: 1859)

  func testAWindowInAParkingCornerLooksParked() {
    // Where Cubicle parks, and where macOS clamps a parked window's height.
    XCTAssertTrue(VirtualWorkspaces.looksParked(CGRect(x: 3359, y: 1889, width: 920, height: 436), screens: [screen]))
    XCTAssertTrue(VirtualWorkspaces.looksParked(CGRect(x: 3359, y: 1838, width: 920, height: 436), screens: [screen]))
    XCTAssertTrue(VirtualWorkspaces.looksParked(CGRect(x: 3359, y: 49, width: 800, height: 600), screens: [screen]))
  }

  func testAWindowOnScreenDoesNotLookParked() {
    XCTAssertFalse(VirtualWorkspaces.looksParked(CGRect(x: 100, y: 100, width: 800, height: 600), screens: [screen]))
    // Half off the edge is still a window you can see.
    XCTAssertFalse(VirtualWorkspaces.looksParked(CGRect(x: 3000, y: 100, width: 800, height: 600), screens: [screen]))
  }

  func testAStrandedWindowComesBackIntoTheCornerItWasParkedIn() {
    let back = VirtualWorkspaces.rescued(CGRect(x: 3359, y: 1838, width: 920, height: 436), into: usable)
    XCTAssertEqual(back, CGRect(x: 2440, y: 1454, width: 920, height: 436))
  }

  func testAWindowBiggerThanTheDisplayComesBackToItsTopLeft() {
    let back = VirtualWorkspaces.rescued(CGRect(x: 3359, y: 1889, width: 4000, height: 2000), into: usable)
    XCTAssertEqual(back.origin, usable.origin)
  }
}
