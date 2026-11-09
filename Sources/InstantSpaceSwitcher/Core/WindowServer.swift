import ApplicationServices
import Foundation

/// The private window-server calls Cubicle makes itself. ISS, the C switching engine shared with upstream
/// InstantSpaceSwitcher, has its own; Cubicle's additions live here so that code stays identical to upstream.
///
/// Each symbol is looked up at runtime, so one that disappears in a macOS update turns its feature off instead of
/// stopping the app from launching.
enum WindowServer {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?
  private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
  private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
  private static let copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
  private static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
  private static let getWindow = symbol("_AXUIElementGetWindow", as: GetWindow.self)

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    // RTLD_DEFAULT: every image already loaded. SkyLight and HIServices come in with AppKit.
    guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  private static var connection: Int32? {
    guard let id = mainConnection?(), id != 0 else { return nil }
    return id
  }

  /// Every display's Spaces, in the window server's order, one entry per display.
  static func managedDisplaySpaces() -> [[String: Any]]? {
    guard let connection, let copy = copyManagedDisplaySpaces else { return nil }
    return copy(connection, nil)?.takeRetainedValue() as? [[String: Any]]
  }

  /// The window number behind an Accessibility window element.
  static func windowID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
    return id
  }

  /// The first Space a window is on, or 0 if unknown.
  static func space(ofWindow id: CGWindowID) -> UInt64 {
    guard let connection, let copy = copySpacesForWindows else { return 0 }
    // 7: the current, other and user Spaces.
    let spaces = copy(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
    return spaces?.first?.uint64Value ?? 0
  }
}
