import XCTest

@testable import CubicleIPC

final class LazySusanTests: XCTestCase {
  private let cli = "/Applications/Cubicle.app/Contents/Helpers/cubicle"

  private func spaces(_ count: Int, current: Int = 1, names: [Int: String] = [:]) -> [CubicleSpaceEntry] {
    (1...count).map { CubicleSpaceEntry(display: "Built-in", index: $0, name: names[$0], isCurrent: $0 == current) }
  }

  func testGoItemsAreKeyedByNumberAndRunTheQuotedCLI() {
    let items = LazySusan.goItems(spaces(2, names: [1: "Mail"]), cli: cli)
    XCTAssertEqual(items, [
      .command("1", "Mail", "\"\(cli)\" go 1"),
      .command("2", "Workspace 2", "\"\(cli)\" go 2"),
    ])
  }

  func testTenthWorkspaceIsZeroAndLaterOnesLeaveTheKeyToLazySusan() {
    let keys = LazySusan.goItems(spaces(12), cli: cli).map(\.key)
    XCTAssertEqual(keys, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", nil, nil])
  }

  func testSendLeavesOutTheCurrentWorkspace() {
    let items = LazySusan.sendItems(spaces(3, current: 2), cli: cli)
    XCTAssertEqual(items.map(\.value), ["\"\(cli)\" send 1", "\"\(cli)\" send 3"])
    XCTAssertEqual(items.map(\.key), ["1", "3"])
  }

  func testBlankNameFallsBackToNumber() {
    XCTAssertEqual(LazySusan.goItems(spaces(1, names: [1: "  "]), cli: cli).first?.label, "Workspace 1")
  }

  func testQuotingEscapesWhatShellsExpandInsideDoubleQuotes() {
    XCTAssertEqual(LazySusan.quoted("/Users/a b/Cubicle.app"), "\"/Users/a b/Cubicle.app\"")
    XCTAssertEqual(LazySusan.quoted(#"/x/$HOME/"q"\z"#), #""/x/\$HOME/\"q\"\\z""#)
  }

  func testItemsEncodeWithoutNullsOrEscapedSlashes() throws {
    let json = LazySusan.json(LazySusan.goItems(spaces(1), cli: cli))
    XCTAssertFalse(json.contains("null"))
    XCTAssertFalse(json.contains("\\/"))
    let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]
    XCTAssertEqual(decoded?.first, ["key": "1", "type": "command", "label": "Workspace 1", "value": "\"\(cli)\" go 1"])
  }

  func testWindowAndStashedItemsTargetTheWindowByID() {
    var window = CubicleWindowEntry(
      id: 42, app: "Safari", bundleID: nil, title: "Docs", x: 0, y: 0, width: 1, height: 1, isFocused: false,
      isMinimized: false)
    window.workspace = 2
    window.workspaceName = "Web"
    XCTAssertEqual(LazySusan.windowItems([window], cli: cli), [.command(nil, "Safari — Docs (Web)", "\"\(cli)\" focus --window 42")])

    let stashed = CubicleStashedEntry(id: 7, app: "Slack", title: "Slack", name: nil, edge: "left", isOut: false, badge: nil)
    XCTAssertEqual(LazySusan.stashedItems([stashed], cli: cli), [.command(nil, "Slack", "\"\(cli)\" open-stashed --window 7")])
  }

  func testInstallGroupHasUniqueKeysAndDynamicSources() {
    let group = LazySusan.installGroup(cli: cli)
    XCTAssertEqual(group.key, LazySusan.groupKey)
    XCTAssertEqual(group.type, "group")
    func check(_ items: [LazySusan.Item]) {
      let keys = items.compactMap(\.key)
      XCTAssertEqual(keys.count, items.count, "every installed item has a key")
      XCTAssertEqual(Set(keys).count, keys.count, "keys are unique: \(keys)")
      for item in items {
        XCTAssertEqual(item.key?.count, 1)
        XCTAssertEqual([item.value, item.source].compactMap { $0 }.count + (item.actions == nil ? 0 : 1), 1)
        if let command = item.value ?? item.source { XCTAssertTrue(command.hasPrefix("\"\(cli)\""), command) }
        if let actions = item.actions { check(actions) }
      }
    }
    check(group.actions ?? [])
    let sources = (group.actions ?? []).compactMap(\.source)
    XCTAssertEqual(sources, LazySusan.lists.map { "\"\(cli)\" leader \($0)" })
  }

  func testInstallURLPercentEncodesThePath() {
    let url = LazySusan.installURL(forFile: "/Users/a b/Library/Application Support/Cubicle/x&y=z+1.json")
    XCTAssertEqual(
      url?.absoluteString,
      "lazysusan://install?file=/Users/a%20b/Library/Application%20Support/Cubicle/x%26y%3Dz%2B1.json")
    let file = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "file" }?.value
    XCTAssertEqual(file, "/Users/a b/Library/Application Support/Cubicle/x&y=z+1.json")
  }
}
