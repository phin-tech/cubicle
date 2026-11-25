import ApplicationServices
import Foundation

/// The private window-server calls Cubicle makes.
///
/// Each symbol is looked up at runtime, so one that disappears in a macOS update turns its feature off instead of
/// stopping the app from launching.
enum WindowServer {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?
  private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
  private static let copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
  private static let getWindow = symbol("_AXUIElementGetWindow", as: GetWindow.self)
  private typealias UpdateToggle = @convention(c) (Int32) -> Int32
  private static let disableUpdate = symbol("SLSDisableUpdate", as: UpdateToggle.self)
  private static let reenableUpdate = symbol("SLSReenableUpdate", as: UpdateToggle.self)

  /// Runs `body` between SLSDisableUpdate and SLSReenableUpdate. These defer this connection's own drawing; Tessel
  /// measured them freezing nothing on macOS 27 when the moved windows belong to other apps, so this is only kept to
  /// compare (`cubicle switch-style freeze`). Without the symbols, `body` just runs.
  static func withScreenUpdatesDisabled<T>(_ body: () -> T) -> T {
    guard let connection, let disableUpdate, let reenableUpdate else { return body() }
    _ = disableUpdate(connection)
    defer { _ = reenableUpdate(connection) }
    return body()
  }

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    // RTLD_DEFAULT: every image already loaded. SkyLight and HIServices come in with AppKit.
    guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  private static var connection: Int32? {
    guard let id = mainConnection?(), id != 0 else { return nil }
    return id
  }

  /// How many macOS desktops there are beyond the first on each display, added up. Cubicle's workspaces replace
  /// Spaces, and Accessibility can't see windows on a Space that isn't showing, so onboarding asks you to remove
  /// the extras. Full-screen Spaces don't count.
  static func extraMacSpaces() -> Int {
    guard let connection, let copy = copyManagedDisplaySpaces,
      let displays = copy(connection, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return 0 }
    return displays.reduce(0) { total, display in
      let desktops = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? NSNumber)?.intValue == 0 }
      return total + max(desktops.count - 1, 0)
    }
  }

  /// The window number behind an Accessibility window element.
  static func windowID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
    return id
  }
}
