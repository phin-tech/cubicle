import Foundation
import XCTest
@testable import InstantSpaceSwitcher

final class SpaceNamesTests: XCTestCase {
  private let workUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
  private let personalUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

  private func space(_ id: Int, uuid: String = "", type: Int = 0) -> [String: Any] {
    ["id64": id, "uuid": uuid, "type": type]
  }

  private func record(_ spaces: [Any], index: Int = 0) -> SpaceRecord {
    let records = SpaceCatalog.records(in: spaces)
    XCTAssertTrue(records.indices.contains(index))
    return records[index]
  }

  private func key(_ spaces: [Any], index: Int = 0, display: String = "monitor-a") -> String? {
    SpaceIdentity(displayIdentifier: display, record: record(spaces, index: index)).key
  }

  private func withStore(_ body: (SpaceNameStore, UserDefaults) -> Void) {
    let suite = "SpaceNamesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(SpaceNameStore(defaults: defaults), defaults)
  }

  func testNamesPersistAndClearingRestoresNumber() {
    withStore { store, defaults in
      let workKey = key([space(10, uuid: workUUID)])!
      store.setName("  Работа  ", for: workKey)
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), "Работа")
      store.setName(" \n ", for: workKey)
      XCTAssertNil(SpaceNameStore(defaults: defaults).name(for: workKey))
    }
  }

  func testNameAtCharacterLimitPersistsAndCanBeSubmittedAgain() {
    withStore { store, defaults in
      let workKey = key([space(10, uuid: workUUID)])!
      let name = String(repeating: "я", count: 512)
      XCTAssertEqual(SpaceNameStore.maximumNameLength, 512)
      XCTAssertTrue(store.setName(name, for: workKey))
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), name)
      XCTAssertTrue(store.setName(name, for: workKey))
    }
  }

  func testOverlongNameCannotReplaceOrCreateSavedName() {
    withStore { store, defaults in
      let workKey = key([space(10, uuid: workUUID)])!
      let personalKey = key([space(20, uuid: personalUUID)])!
      XCTAssertTrue(store.setName("Work", for: workKey))
      let savedNames = defaults.dictionary(forKey: "customSpaceNames") as? [String: String]
      let observer = NotificationCenter.default.addObserver(
        forName: .spaceNamesDidChange, object: store, queue: nil
      ) { _ in
        XCTFail("Rejected names must not announce a name change")
      }
      defer { NotificationCenter.default.removeObserver(observer) }

      let name = String(repeating: "я", count: 513)
      XCTAssertFalse(store.setName(name, for: workKey))
      XCTAssertFalse(store.setName(name, for: personalKey))
      XCTAssertEqual(store.name(for: workKey), "Work")
      XCTAssertNil(store.name(for: personalKey))
      XCTAssertEqual(defaults.dictionary(forKey: "customSpaceNames") as? [String: String], savedNames)
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), "Work")
      XCTAssertNil(SpaceNameStore(defaults: defaults).name(for: personalKey))
    }
  }

  func testNameLimitCountsEmojiAndDecomposedLettersAsCharacters() {
    withStore { store, defaults in
      let workKey = key([space(10, uuid: workUUID)])!
      let name = String(repeating: "👩🏽‍💻e\u{301}", count: 256)
      XCTAssertEqual(name.count, 512)
      XCTAssertGreaterThan(name.utf16.count, 512)
      XCTAssertTrue(store.setName(name, for: workKey))
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), name)
      XCTAssertFalse(store.setName(name + "🚀", for: workKey))
      XCTAssertEqual(store.name(for: workKey), name)
    }
  }

  func testPreviouslySavedLongNamesRemainUntilReplacedOrCleared() {
    withStore { _, defaults in
      let workKey = key([space(10, uuid: workUUID)])!
      let personalKey = key([space(20, uuid: personalUUID)])!
      let oldName = String(repeating: "я", count: 1024)
      defaults.set([workKey: oldName, personalKey: oldName], forKey: "customSpaceNames")
      let store = SpaceNameStore(defaults: defaults)
      XCTAssertEqual(store.name(for: workKey), oldName)
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: personalKey), oldName)
      XCTAssertFalse(store.setName(oldName + "!", for: workKey))
      XCTAssertEqual(store.name(for: workKey), oldName)

      XCTAssertTrue(store.setName("Work", for: workKey))
      XCTAssertTrue(store.setName("", for: personalKey))
      let reloaded = SpaceNameStore(defaults: defaults)
      XCTAssertEqual(reloaded.name(for: workKey), "Work")
      XCTAssertNil(reloaded.name(for: personalKey))
    }
  }

  func testNameLimitIncludesWhitespaceBeforeTrimming() {
    withStore { store, defaults in
      let workKey = key([space(10, uuid: workUUID)])!
      let trimmedName = String(repeating: "я", count: 511)
      XCTAssertTrue(store.setName(" " + trimmedName, for: workKey))
      XCTAssertEqual(store.name(for: workKey), trimmedName)
      XCTAssertFalse(store.setName(" " + trimmedName + " ", for: workKey))
      XCTAssertFalse(store.setName(String(repeating: " ", count: 513), for: workKey))
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), trimmedName)
      XCTAssertTrue(store.setName(String(repeating: " ", count: 512), for: workKey))
      XCTAssertNil(SpaceNameStore(defaults: defaults).name(for: workKey))
    }
  }

  func testUUIDFollowsReorderDisplayMoveAndNewRuntimeID() {
    let original = key([space(10, uuid: workUUID), space(20, uuid: personalUUID)])
    let moved = key(
      [space(90, uuid: personalUUID), space(99, uuid: workUUID.lowercased())], index: 1, display: "monitor-b")
    XCTAssertEqual(original, moved)
    withStore { store, _ in
      store.setName("Work", for: original!)
      XCTAssertEqual(store.name(for: moved), "Work")
    }
  }

  func testSameIndexOnTwoMonitorsHasIndependentNames() {
    let first = key([space(10, uuid: workUUID)], display: "monitor-a")!
    let second = key([space(20, uuid: personalUUID)], display: "monitor-b")!
    withStore { store, _ in
      store.setName("Work", for: first)
      store.setName("Personal", for: second)
      XCTAssertEqual(store.name(for: first), "Work")
      XCTAssertEqual(store.name(for: second), "Personal")
    }
  }

  func testDefaultDesktopNamesAreScopedToDisplay() {
    let first = key([space(1)], display: "monitor-a")
    let second = key([space(2)], display: "monitor-b")
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first, key([space(100)], display: "MONITOR-A"))
    XCTAssertNil(key([space(1)], display: ""))
  }

  func testDefaultDesktopFollowsReorderingWithinDisplay() {
    let original = key([space(1), space(2, uuid: workUUID)])
    let reordered = key([space(2, uuid: workUUID), space(1)], index: 1)
    XCTAssertEqual(original, reordered)
  }

  func testAmbiguousUnnamedDesktopsHaveNoNameKey() {
    let spaces = [space(1), space(2)]
    XCTAssertNil(key(spaces))
    XCTAssertNil(key(spaces, index: 1))
  }

  func testFullscreenDoesNotTakeDefaultDesktopName() {
    let spaces = [space(1), space(2, type: 4)]
    XCTAssertNotNil(key(spaces))
    XCTAssertNil(key(spaces, index: 1))
    XCTAssertNotNil(key([space(3, uuid: workUUID, type: 4)]))
  }

  func testMalformedEntriesDoNotShiftValidSpaceIndices() {
    let spaces: [Any] = ["invalid", ["uuid": personalUUID], ["id64": "invalid"],
      space(10, uuid: workUUID), NSNull(), space(20, uuid: personalUUID)]
    XCTAssertEqual(SpaceCatalog.records(in: spaces).map(\.spaceID), [10, 20])
  }

  func testInvalidUUIDCannotBorrowDefaultDesktopName() {
    XCTAssertNil(key([space(1, uuid: "broken-uuid")]))
    XCTAssertNil(key([space(1, uuid: String(repeating: "x", count: 200))]))
    XCTAssertNil(key([["id64": 1, "uuid": 42, "type": 0]]))
    XCTAssertNil(key([["id64": 1, "uuid": ""]]))
  }

  func testMissingUUIDCanIdentifyOnlyDefaultDesktop() {
    XCTAssertNotNil(key([["id64": 1, "type": 0]]))
    XCTAssertNil(key([["id64": 1, "type": 4]]))
  }

  func testSwitchMessageUsesCapturedTarget() {
    withStore { store, _ in
      let spaces = [space(10, uuid: workUUID), space(20, uuid: personalUUID)]
      store.setName("Work", for: key(spaces)!)
      store.setName("Personal", for: key(spaces, index: 1)!)
      let personal = SpaceIdentity(displayIdentifier: "monitor-a", record: record(spaces, index: 1))
      XCTAssertEqual(store.message(forTargetIndex: 1, identity: personal), "Personal")
      XCTAssertEqual(store.message(forTargetIndex: 1, identity: nil), "2")
    }
  }

  func testRecreatedSpaceDoesNotInheritDeletedSpaceName() {
    withStore { store, _ in
      store.setName("Work", for: key([space(10, uuid: workUUID)])!)
      XCTAssertNil(store.name(for: key([space(10, uuid: personalUUID)])))
    }
  }

  func testCatalogGroupsDisplaysAndKeepsValidIndices() {
    let raw: [[String: Any]] = [
      ["Display Identifier": "monitor-a", "Spaces": [space(10, uuid: workUUID)]],
      ["Display Identifier": "monitor-b", "Spaces": ["invalid", space(20, uuid: personalUUID)]],
      ["Spaces": []],
    ]
    let catalog = SpaceCatalog.parse(raw, screenNames: ["monitor-a": "Built-in"], separateSpaces: true)
    XCTAssertEqual(catalog.map(\.name), ["Built-in", "Display 2"])
    XCTAssertEqual(catalog[1].spaces.map(\.index), [0])
    XCTAssertEqual(catalog[0].spaces[0].identity.key, key([space(10, uuid: workUUID)]))
    XCTAssertNotEqual(catalog[0].spaces[0].identity, catalog[1].spaces[0].identity)
  }

  func testSharedSpacesUseOneDisplayGroup() {
    let raw: [[String: Any]] = [["Display Identifier": "Main", "Spaces": [space(1), space(2, uuid: workUUID)]]]
    let catalog = SpaceCatalog.parse(raw, screenNames: [:], separateSpaces: false)
    XCTAssertEqual(catalog.map(\.name), ["All Displays"])
    XCTAssertEqual(catalog[0].spaces.count, 2)
    XCTAssertNotEqual(catalog[0].spaces[0].identity.key, key([space(1)], display: "monitor-a"))
  }

  func testDisconnectedDisplayKeepsNamesForReconnection() {
    withStore { store, defaults in
      let raw: [[String: Any]] = [["Display Identifier": "monitor-a", "Spaces": [space(10, uuid: workUUID)]]]
      let connected = SpaceCatalog.parse(raw, screenNames: [:], separateSpaces: true)
      store.setName("Work", for: connected[0].spaces[0].identity.key!)
      XCTAssertTrue(SpaceCatalog.parse([], screenNames: [:], separateSpaces: true).isEmpty)
      let reconnected = SpaceCatalog.parse(raw, screenNames: [:], separateSpaces: true)
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: reconnected[0].spaces[0].identity.key), "Work")
    }
  }

  // MARK: - Which display a switch acts on (ISS's rule)

  private func display(_ identifier: String, current: UInt64?) -> SpaceDisplay {
    SpaceDisplay(
      identifier: identifier, name: identifier,
      spaces: SpaceCatalog.parse(
        [["Display Identifier": identifier, "Spaces": [space(1), space(2, uuid: workUUID)]]],
        screenNames: [:], separateSpaces: true)[0].spaces,
      currentSpaceID: current)
  }

  func testSwitchingUsesTheDisplayWithTheCursorsUUID() {
    let displays = [display("A", current: 1), display("B", current: 2)]
    let picked = SpaceCatalog.select(displays, uuid: "B", screenID: 7)
    XCTAssertEqual(picked?.display.identifier, "B")
    XCTAssertEqual(picked?.currentIndex, 1)
    XCTAssertEqual(picked?.screenID, 7)
    XCTAssertEqual(picked?.matched, true)
  }

  func testAnUncatalogedDisplayFallsBackToTheFirstButIsMarkedSo() {
    let picked = SpaceCatalog.select([display("A", current: 1), display("B", current: 2)], uuid: "C", screenID: 7)
    XCTAssertEqual(picked?.display.identifier, "A")
    XCTAssertEqual(picked?.matched, false)
  }

  func testADisplayWhoseCurrentSpaceIsMissingCannotBeUsed() {
    XCTAssertNil(SpaceCatalog.select([display("A", current: 99)], uuid: "A", screenID: 7))
    XCTAssertNil(SpaceCatalog.select([display("A", current: nil)], uuid: "A", screenID: 7))
  }

  func testCurrentSpaceIsReadFromID64() {
    let raw: [[String: Any]] = [["Display Identifier": "A", "Spaces": [space(1), space(2)], "Current Space": ["id64": 2]]]
    XCTAssertEqual(SpaceCatalog.parse(raw, screenNames: [:], separateSpaces: true)[0].currentSpaceID, 2)
  }
}
