import XCTest

@testable import InstantSpaceSwitcher

final class ShortcutChoiceTests: XCTestCase {
  private var defaults: [(HotkeyIdentifier, HotkeyCombination)] {
    HotkeyIdentifier.allCases.map { ($0, $0.defaultCombination) }
  }

  func testNoTwoActionsShareADefaultShortcut() {
    let all = defaults
    for i in all.indices {
      for j in all.indices where j > i {
        XCTAssertNotEqual(all[i].1, all[j].1, "\(all[i].0) and \(all[j].0) share a default shortcut")
      }
    }
  }

  func testSpaceDefaultsMatchTheirNumber() {
    for number in 1...16 {
      let identifier = HotkeyIdentifier(rawValue: "space\(number)")
      XCTAssertEqual(identifier?.defaultCombination, .defaultForSpace(number))
    }
  }

  func testNamedDefaults() {
    XCTAssertEqual(HotkeyIdentifier.left.defaultCombination, .defaultLeft)
    XCTAssertEqual(HotkeyIdentifier.right.defaultCombination, .defaultRight)
    XCTAssertEqual(HotkeyIdentifier.showGrid.defaultCombination, .defaultShowGrid)
    XCTAssertEqual(HotkeyIdentifier.lastSpace.defaultCombination, .defaultLastSpace)
  }

  func testConflictFindsTheActionAlreadyUsingAShortcut() {
    let all = defaults
    XCTAssertEqual(
      HotkeyConflict.identifier(using: .defaultLeft, among: all, excluding: .showGrid), .left)
  }

  func testAnActionDoesNotConflictWithItself() {
    XCTAssertNil(HotkeyConflict.identifier(using: .defaultLeft, among: defaults, excluding: .left))
  }

  func testAnUnusedShortcutHasNoConflict() {
    let unused = HotkeyCombination(keyCode: 0, modifiers: 0, displayKey: "A", keyEquivalent: "a")
    XCTAssertNil(HotkeyConflict.identifier(using: unused, among: defaults, excluding: .showGrid))
  }
}

/// The Alfred workflow is shipped inside the app, so a bad edit to it would ship too.
final class AlfredWorkflowTests: XCTestCase {
  private var workflowDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("alfred")
  }

  private func infoPlist() throws -> [String: Any] {
    let data = try Data(contentsOf: workflowDirectory.appendingPathComponent("info.plist"))
    return try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
  }

  func testWorkflowHasItsIconAndBundleID() throws {
    XCTAssertTrue(FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("icon.png").path))
    XCTAssertEqual(try infoPlist()["bundleid"] as? String, "tech.phin.cubicle.alfred")
  }

  func testScriptFilterUsesTheAtKeywordWithoutASpace() throws {
    let objects = try XCTUnwrap(try infoPlist()["objects"] as? [[String: Any]])
    let filter = try XCTUnwrap(objects.first { $0["type"] as? String == "alfred.workflow.input.scriptfilter" })
    let config = try XCTUnwrap(filter["config"] as? [String: Any])
    XCTAssertEqual(config["keyword"] as? String, "@")
    XCTAssertEqual(config["withspace"] as? Bool, false)
    XCTAssertTrue((config["script"] as? String ?? "").contains("list --alfred"))
  }

  func testEveryConnectionPointsAtARealObject() throws {
    let plist = try infoPlist()
    let objects = try XCTUnwrap(plist["objects"] as? [[String: Any]])
    let uids = Set(objects.compactMap { $0["uid"] as? String })
    let connections = try XCTUnwrap(plist["connections"] as? [String: [[String: Any]]])
    for (source, targets) in connections {
      XCTAssertTrue(uids.contains(source), "connection from unknown object \(source)")
      for target in targets {
        XCTAssertTrue(uids.contains(target["destinationuid"] as? String ?? ""), "connection to unknown object")
      }
    }
  }
}
