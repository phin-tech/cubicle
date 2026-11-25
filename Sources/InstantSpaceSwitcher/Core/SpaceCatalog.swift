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

/// One display's workspaces as switching sees them: which display, which workspace is showing, and the screen.
struct DisplaySpaces: Equatable {
  let display: SpaceDisplay
  let currentIndex: Int
  /// The physical display the lookup point is on, for placing the grid and OSD.
  let screenID: CGDirectDisplayID
  /// False when the point's display wasn't in the catalog and this is the first display instead.
  let matched: Bool
}

/// Every display's workspaces, in the shape the grid, names, menu and stacks read. `VirtualWorkspaces` owns them;
/// this republishes them whenever they change.
@MainActor
final class SpaceCatalog {
  static let shared = SpaceCatalog()
  @Published private(set) var displays: [SpaceDisplay] = []
  private var cancellables = Set<AnyCancellable>()

  func startObserving() {
    guard cancellables.isEmpty else { return }
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .merge(with: NotificationCenter.default.publisher(for: .virtualWorkspaceDidChange))
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
    refresh()
  }

  func refresh() {
    let updated = VirtualWorkspaces.shared.displays()
    if updated != displays { displays = updated }
  }

  /// The workspace a window is on, or 0 if Cubicle doesn't know the window.
  func space(ofWindow id: CGWindowID) -> UInt64 {
    VirtualWorkspaces.shared.spaceID(ofWindow: id)
  }

  /// The workspaces of the display at `point` (top-left-origin global coordinates). Switches act on the display
  /// under the cursor, so this is the display a switch from there would change.
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

  /// The display whose identifier is `uuid`, otherwise the first display. Its current workspace must be in its list.
  nonisolated static func select(_ displays: [SpaceDisplay], uuid: String?, screenID: CGDirectDisplayID) -> DisplaySpaces? {
    let exact = displays.first { $0.identifier == uuid }
    guard let display = exact ?? displays.first,
      let current = display.spaces.firstIndex(where: { $0.spaceID == display.currentSpaceID })
    else { return nil }
    return DisplaySpaces(display: display, currentIndex: current, screenID: screenID, matched: exact != nil)
  }
}
