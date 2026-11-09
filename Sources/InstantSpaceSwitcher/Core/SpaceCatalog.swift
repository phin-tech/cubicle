import AppKit
import Combine

struct SpaceDescription: Equatable {
  let index: UInt32
  let identity: SpaceIdentity
  var spaceID: UInt64 = 0
}

struct SpaceDisplay: Equatable {
  let identifier: String
  let name: String
  let spaces: [SpaceDescription]
  var currentSpaceID: UInt64? = nil
}

/// One display's Spaces as switching sees them: which display, which Space is showing, and the physical screen.
struct DisplaySpaces: Equatable {
  let display: SpaceDisplay
  let currentIndex: Int
  /// The physical display the lookup point is on, for placing the grid and OSD.
  let screenID: CGDirectDisplayID
  /// False when the point's display wasn't in the catalog and this is the first display instead, as ISS does.
  let matched: Bool
}

/// A Space's entry in the window server's list, in Space order.
struct SpaceRecord: Equatable {
  let spaceID: UInt64
  let uuid: String
  /// The display's only desktop without a UUID (macOS gives the original desktop none).
  let isDefaultDesktop: Bool
}

@MainActor
final class SpaceCatalog {
  static let shared = SpaceCatalog()
  @Published private(set) var displays: [SpaceDisplay] = []
  private var refreshWorkItem: DispatchWorkItem?
  private var cancellables = Set<AnyCancellable>()

  func startObserving() {
    guard cancellables.isEmpty else { return }
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .merge(with: NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.activeSpaceDidChangeNotification))
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    refresh()
  }

  func scheduleRefresh() {
    refreshWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    refreshWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  func refresh() {
    refreshWorkItem?.cancel()
    refreshWorkItem = nil
    guard let raw = WindowServer.managedDisplaySpaces() else {
      if !displays.isEmpty { displays = [] }
      return
    }
    let names = Self.screenNames()
    let updated = Self.parse(raw, screenNames: names, separateSpaces: NSScreen.screensHaveSeparateSpaces)
    if updated != displays { displays = updated }
  }

  func identity(displayIdentifier: String, index: UInt32) -> SpaceIdentity? {
    displays.first { $0.identifier == displayIdentifier }?.spaces.first { $0.index == index }?.identity
  }

  /// The Spaces of the display at `point` (top-left-origin global coordinates), freshly read. Space switches act on
  /// the display under the cursor, so this is the display a switch from there would change.
  func spaces(at point: CGPoint) -> DisplaySpaces? {
    refresh()
    var screenID: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &screenID, &count) == .success, count > 0 else { return nil }
    let uuid = CGDisplayCreateUUIDFromDisplayID(screenID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    return Self.select(displays, uuid: uuid, screenID: screenID)
  }

  func spacesUnderCursor() -> DisplaySpaces? {
    spaces(at: CGEvent(source: nil)?.location ?? .zero)
  }

  /// ISS's rule: the display whose identifier is `uuid`, otherwise the first display. Its current Space must be in
  /// its list.
  nonisolated static func select(_ displays: [SpaceDisplay], uuid: String?, screenID: CGDirectDisplayID) -> DisplaySpaces? {
    let exact = displays.first { $0.identifier == uuid }
    guard let display = exact ?? displays.first,
      let current = display.spaces.firstIndex(where: { $0.spaceID == display.currentSpaceID })
    else { return nil }
    return DisplaySpaces(display: display, currentIndex: current, screenID: screenID, matched: exact != nil)
  }

  /// The valid Spaces in a display's "Spaces" list, in order; entries without a numeric id64 don't count, so they
  /// can't shift the index of the ones after them.
  nonisolated static func records(in spaces: [Any]) -> [SpaceRecord] {
    let entries = spaces.compactMap { entry -> (id: UInt64, uuid: Any?, type: Int)? in
      guard let space = entry as? [String: Any], let id = space["id64"] as? NSNumber
      else { return nil }
      return (id.uint64Value, space["uuid"], (space["type"] as? NSNumber)?.intValue ?? -1)
    }
    // A desktop with no UUID is the original one; with more than one, none can be told apart.
    let defaults = entries.map { $0.type == 0 && ($0.uuid == nil || ($0.uuid as? String)?.isEmpty == true) }
    let unique = defaults.filter { $0 }.count == 1
    return zip(entries, defaults).map { entry, isDefault in
      SpaceRecord(spaceID: entry.id, uuid: entry.uuid as? String ?? "", isDefaultDesktop: isDefault && unique)
    }
  }

  nonisolated static func parse(
    _ raw: [[String: Any]], screenNames: [String: String], separateSpaces: Bool
  ) -> [SpaceDisplay] {
    raw.enumerated().compactMap { offset, display in
      guard let identifier = display["Display Identifier"] as? String,
        let spaces = display["Spaces"] as? [Any] else { return nil }
      let descriptions = records(in: spaces).enumerated().map { index, record in
        SpaceDescription(
          index: UInt32(index), identity: SpaceIdentity(displayIdentifier: identifier, record: record),
          spaceID: record.spaceID)
      }
      return SpaceDisplay(
        identifier: identifier,
        name: separateSpaces ? (screenNames[identifier.lowercased()] ?? "Display \(offset + 1)") : "All Displays",
        spaces: descriptions,
        // ISS reads id64; ManagedSpaceID is the same number.
        currentSpaceID: (display["Current Space"] as? [String: Any])
          .flatMap { (($0["id64"] ?? $0["ManagedSpaceID"]) as? NSNumber)?.uint64Value })
    }
  }

  private static func screenNames() -> [String: String] {
    var names: [String: String] = [:]
    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
        let identifier = CFUUIDCreateString(nil, uuid) as String? else { continue }
      names[identifier.lowercased()] = screen.localizedName
    }
    return names
  }
}
