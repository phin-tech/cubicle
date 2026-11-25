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
    XCTAssertEqual(HotkeyIdentifier.sendWindow.defaultCombination, .defaultSendWindow)
  }

  func testSendWindowIsOffUntilTurnedOn() {
    let defaults = UserDefaults(suiteName: "ShortcutChoiceTests.\(UUID().uuidString)")!
    let store = HotkeyStore(defaults: defaults)
    XCTAssertFalse(store.isEnabled(.sendWindow))
    XCTAssertTrue(store.isEnabled(.showGrid))
    store.setEnabled(true, for: .sendWindow)
    XCTAssertTrue(HotkeyStore(defaults: defaults).isEnabled(.sendWindow))
  }

  func testConflictFindsTheActionAlreadyUsingAShortcut() {
    let all = defaults
    XCTAssertEqual(
      HotkeyConflict.identifier(using: .defaultLeft, among: all, excluding: .showGrid), .left)
  }

  func testAnActionDoesNotConflictWithItself() {
    XCTAssertNil(HotkeyConflict.identifier(using: .defaultLeft, among: defaults, excluding: .left))
  }

  /// Hyper+Space is "Send window to space…"'s default, but that action starts off, so it isn't using the key.
  func testATurnedOffShortcutIsFreeToReuse() {
    let store = HotkeyStore(defaults: UserDefaults(suiteName: "ShortcutChoiceTests.\(UUID().uuidString)")!)
    XCTAssertFalse(store.isEnabled(.sendWindow))
    XCTAssertNil(store.conflict(.defaultSendWindow, for: .showGrid))
    store.setEnabled(true, for: .sendWindow)
    XCTAssertEqual(store.conflict(.defaultSendWindow, for: .showGrid), .sendWindow)
  }

  func testTurningAShortcutOnChecksTheOnesAlreadyOn() {
    let store = HotkeyStore(defaults: UserDefaults(suiteName: "ShortcutChoiceTests.\(UUID().uuidString)")!)
    store.update(.defaultSendWindow, for: .showGrid)
    XCTAssertEqual(store.conflict(store.combination(for: .sendWindow), for: .sendWindow), .showGrid)
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

  private func scriptFilters() throws -> [[String: Any]] {
    let objects = try XCTUnwrap(try infoPlist()["objects"] as? [[String: Any]])
    return objects.filter { $0["type"] as? String == "alfred.workflow.input.scriptfilter" }
      .compactMap { $0["config"] as? [String: Any] }
  }

  /// The workflow is a shim: every keyword asks `cubicle alfred` for its items.
  func testEveryScriptFilterAsksCubicle() throws {
    let filters = try scriptFilters()
    XCTAssertEqual(filters.count, 3)
    for filter in filters {
      XCTAssertTrue((filter["script"] as? String ?? "").contains("alfred \""), "\(filter["keyword"] ?? "?")")
    }
  }

  /// Keywords come from Configure Workflow, with cb, @ and w as the defaults; @ needs no space (@mail).
  func testKeywordsAreSettingsWithTheirDefaults() throws {
    let settings = try XCTUnwrap(try infoPlist()["userconfigurationconfig"] as? [[String: Any]])
    var defaults: [String: String] = [:]
    for setting in settings {
      let variable = try XCTUnwrap(setting["variable"] as? String)
      defaults[variable] = (setting["config"] as? [String: Any])?["default"] as? String
    }
    var keywords: [String: Bool] = [:]
    for filter in try scriptFilters() {
      let keyword = try XCTUnwrap(filter["keyword"] as? String)
      XCTAssertTrue(keyword.hasPrefix("{var:") && keyword.hasSuffix("}"), keyword)
      let variable = String(keyword.dropFirst(5).dropLast())
      keywords[try XCTUnwrap(defaults[variable], "no setting for \(variable)")] = filter["withspace"] as? Bool
    }
    XCTAssertEqual(keywords, ["cb": true, "@": false, "w": true])
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
