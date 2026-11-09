import Carbon
import XCTest

@testable import InstantSpaceSwitcher

final class ClickBindingTests: XCTestCase {
  private let controlOptionCommand: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

  func testDefaultIsControlOptionCommandWithEitherButton() {
    let binding = ClickBinding.default
    XCTAssertTrue(binding.matches(eventType: .leftMouseDown, flags: controlOptionCommand))
    XCTAssertTrue(binding.matches(eventType: .rightMouseDown, flags: controlOptionCommand))
    XCTAssertEqual(binding.displayString, "⌃⌥⌘ Click")
  }

  func testModifiersMustMatchExactly() {
    let binding = ClickBinding.default
    XCTAssertFalse(binding.matches(eventType: .leftMouseDown, flags: [.maskControl, .maskCommand]))
    XCTAssertFalse(binding.matches(eventType: .leftMouseDown, flags: controlOptionCommand.union(.maskShift)))
    XCTAssertFalse(binding.matches(eventType: .leftMouseDown, flags: []))
  }

  func testCapsLockDoesNotGetInTheWay() {
    XCTAssertTrue(ClickBinding.default.matches(eventType: .leftMouseDown, flags: controlOptionCommand.union(.maskAlphaShift)))
  }

  func testRecordedClickKeepsItsButton() throws {
    let right = try XCTUnwrap(ClickBinding(eventType: .rightMouseDown, flags: [.maskAlternate, .maskShift]))
    XCTAssertEqual(right.button, .right)
    XCTAssertEqual(right.displayString, "⌥⇧ Right-click")
    XCTAssertTrue(right.matches(eventType: .rightMouseDown, flags: [.maskAlternate, .maskShift]))
    XCTAssertFalse(right.matches(eventType: .leftMouseDown, flags: [.maskAlternate, .maskShift]))
    XCTAssertNil(ClickBinding(eventType: .otherMouseDown, flags: [.maskAlternate, .maskShift]))
  }

  func testFewerThanTwoModifiersIsRejected() {
    XCTAssertFalse(ClickBinding(modifiers: 0, button: .left).isValid)
    XCTAssertFalse(ClickBinding(modifiers: UInt32(controlKey), button: .left).isValid)
    XCTAssertFalse(ClickBinding(modifiers: UInt32(shiftKey), button: .any).isValid)
    XCTAssertTrue(ClickBinding(modifiers: UInt32(controlKey | optionKey), button: .left).isValid)
  }

  func testSurvivesSaving() throws {
    let binding = ClickBinding(modifiers: UInt32(optionKey | cmdKey), button: .right)
    let data = try JSONEncoder().encode(binding)
    XCTAssertEqual(try JSONDecoder().decode(ClickBinding.self, from: data), binding)
  }
}
