import Foundation
import XCTest
@testable import InstantSpaceSwitcher

final class SpaceNamesTests: XCTestCase {
  private func withStore(_ body: (SpaceNameStore, UserDefaults) -> Void) {
    let suite = "SpaceNamesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(SpaceNameStore(defaults: defaults), defaults)
  }

  func testNamesPersistAndClearingRestoresNumber() {
    withStore { store, defaults in
      let workKey = VirtualWorkspaces.key("monitor-a", 0)
      store.setName("  Работа  ", for: workKey)
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), "Работа")
      store.setName(" \n ", for: workKey)
      XCTAssertNil(SpaceNameStore(defaults: defaults).name(for: workKey))
    }
  }

  func testNameAtCharacterLimitPersistsAndCanBeSubmittedAgain() {
    withStore { store, defaults in
      let workKey = VirtualWorkspaces.key("monitor-a", 0)
      let name = String(repeating: "я", count: 512)
      XCTAssertEqual(SpaceNameStore.maximumNameLength, 512)
      XCTAssertTrue(store.setName(name, for: workKey))
      XCTAssertEqual(SpaceNameStore(defaults: defaults).name(for: workKey), name)
      XCTAssertTrue(store.setName(name, for: workKey))
    }
  }

  func testOverlongNameCannotReplaceOrCreateSavedName() {
    withStore { store, defaults in
      let workKey = VirtualWorkspaces.key("monitor-a", 0)
      let personalKey = VirtualWorkspaces.key("monitor-a", 1)
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
      let workKey = VirtualWorkspaces.key("monitor-a", 0)
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
      let workKey = VirtualWorkspaces.key("monitor-a", 0)
      let personalKey = VirtualWorkspaces.key("monitor-a", 1)
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
      let workKey = VirtualWorkspaces.key("monitor-a", 0)
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

  func testSameWorkspaceNumberOnTwoDisplaysHasIndependentNames() {
    withStore { store, _ in
      store.setName("Work", for: VirtualWorkspaces.key("monitor-a", 0))
      XCTAssertEqual(store.name(for: VirtualWorkspaces.key("monitor-a", 0)), "Work")
      XCTAssertNil(store.name(for: VirtualWorkspaces.key("monitor-b", 0)))
      XCTAssertNil(store.name(for: VirtualWorkspaces.key("monitor-a", 1)))
    }
  }

  func testWorkspaceKeysIgnoreTheDisplayUUIDsCase() {
    XCTAssertEqual(VirtualWorkspaces.key("ABC-DEF", 2), VirtualWorkspaces.key("abc-def", 2))
    XCTAssertEqual(VirtualWorkspaces.key("ABC-DEF", 2), "workspace:abc-def:3")
  }

  func testSwitchMessageUsesCapturedTarget() {
    withStore { store, _ in
      store.setName("Personal", for: VirtualWorkspaces.key("monitor-a", 1))
      let personal = SpaceIdentity(key: VirtualWorkspaces.key("monitor-a", 1))
      XCTAssertEqual(store.message(forTargetIndex: 1, identity: personal), "Personal")
      XCTAssertEqual(store.message(forTargetIndex: 1, identity: nil), "2")
    }
  }

  // MARK: - Which display a switch acts on

  private func display(_ identifier: String, current: UInt64?) -> SpaceDisplay {
    SpaceDisplay(
      identifier: identifier, name: identifier,
      spaces: (0..<2).map { index in
        SpaceDescription(
          index: UInt32(index), identity: SpaceIdentity(key: VirtualWorkspaces.key(identifier, index)),
          spaceID: UInt64(index + 1))
      },
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
}
