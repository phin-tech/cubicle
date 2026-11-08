import XCTest

@testable import InstantSpaceSwitcher

final class MenuBarLabelTests: XCTestCase {
  func testNoNameMeansNoLabel() {
    XCTAssertNil(MenuBarLabel.title(forName: nil))
    XCTAssertNil(MenuBarLabel.title(forName: ""))
    XCTAssertNil(MenuBarLabel.title(forName: "   \n  "))
  }

  func testShortNamesAreKeptAsIs() {
    XCTAssertEqual(MenuBarLabel.title(forName: "Main"), "Main")
    XCTAssertEqual(MenuBarLabel.title(forName: "  Innopts  "), "Innopts")
  }

  func testMultilineNamesBecomeOneLine() {
    XCTAssertEqual(MenuBarLabel.title(forName: "Mail\nand chat"), "Mail and chat")
  }

  func testLongNamesAreShortenedWithAnEllipsis() {
    let long = String(repeating: "a", count: 40)
    let title = MenuBarLabel.title(forName: long, maximumLength: 10)
    XCTAssertEqual(title, String(repeating: "a", count: 9) + "…")
    XCTAssertEqual(title?.count, 10)
  }

  func testNameExactlyAtTheLimitIsNotShortened() {
    XCTAssertEqual(MenuBarLabel.title(forName: "abcdefghij", maximumLength: 10), "abcdefghij")
  }

  func testNoSpaceBeforeTheEllipsis() {
    XCTAssertEqual(MenuBarLabel.title(forName: "ab cdefghijk", maximumLength: 4), "ab…")
  }

  func testEmojiCountAsOneCharacter() {
    XCTAssertEqual(MenuBarLabel.title(forName: "🧑‍💻🧑‍💻🧑‍💻", maximumLength: 3), "🧑‍💻🧑‍💻🧑‍💻")
  }
}
