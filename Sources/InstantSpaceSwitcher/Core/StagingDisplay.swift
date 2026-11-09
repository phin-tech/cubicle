import AppKit

/// Where window moves park a window while its own display switches Spaces: Cubicle's virtual display (the default),
/// or a real display you pick, such as a spare small monitor.
///
/// The choice is saved by display UUID, which stays the same across reconnects and restarts; display numbers don't.
@MainActor
enum StagingDisplay {
  struct Choice: Equatable {
    let uuid: String
    let name: String
  }

  private static let uuidKey = "stagingDisplayUUID"
  private static let nameKey = "stagingDisplayName"

  /// The real display you picked, or nil for the virtual display.
  static var choice: Choice? {
    get {
      guard let uuid = UserDefaults.standard.string(forKey: uuidKey) else { return nil }
      return Choice(uuid: uuid, name: UserDefaults.standard.string(forKey: nameKey) ?? "Display")
    }
    set {
      UserDefaults.standard.set(newValue?.uuid, forKey: uuidKey)
      UserDefaults.standard.set(newValue?.name, forKey: nameKey)
    }
  }

  /// Connected real displays that could stage, in screen order. Cubicle's own virtual display isn't one.
  static func realDisplays() -> [(id: CGDirectDisplayID, choice: Choice)] {
    NSScreen.screens.compactMap { screen in
      guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
        id != VirtualDisplay.id, let uuid = uuid(of: id)
      else { return nil }
      return (id, Choice(uuid: uuid, name: screen.localizedName))
    }
  }

  /// The picked real display, if it is connected.
  static var connectedChoiceID: CGDirectDisplayID? {
    guard let choice else { return nil }
    return realDisplays().first { $0.choice.uuid == choice.uuid }?.id
  }

  /// The real display to stage `window` on, or nil to use the virtual display: when none is picked, when the picked
  /// one is unplugged, or when the window is on it (a window can't park on its own display).
  static func realDisplay(for window: WindowMover.Target) -> CGDirectDisplayID? {
    guard let id = connectedChoiceID, !CGDisplayBounds(id).contains(window.anchor) else { return nil }
    return id
  }

  static func uuid(of id: CGDirectDisplayID) -> String? {
    CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
  }
}
