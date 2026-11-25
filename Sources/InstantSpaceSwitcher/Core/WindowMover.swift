import AppKit
import ApplicationServices

/// Finds windows through Accessibility: the focused one, the one under a point, and their frames.
@MainActor
enum WindowMover {
  struct Target {
    let window: AXUIElement
    let windowID: UInt32
    let frame: CGRect  // top-left-origin screen coordinates, as AX and CGEvent use
    let pid: pid_t

    /// Middle of the title bar, where the window is grabbed and where Space lookups put the cursor.
    var anchor: CGPoint { CGPoint(x: frame.midX, y: frame.minY + 8) }

    var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Window" }

    var title: String {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return "" }
      return value as? String ?? ""
    }

    /// "Terminal — zsh", or just the app's name when the window has no title of its own.
    var displayName: String {
      let title = title.trimmingCharacters(in: .whitespaces)
      return title.isEmpty || title == appName ? appName : "\(appName) — \(title)"
    }
  }

  static func focusedWindow() -> Target? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return target(for: value as! AXUIElement)
  }

  /// The window under `point` (top-left-origin screen coordinates), or nil over the desktop, the Dock or Cubicle.
  static func window(at point: CGPoint) -> Target? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
      let hit
    else { return nil }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
    let window: AXUIElement
    if role as? String == kAXWindowRole as String {
      window = hit
    } else {
      // Usually a control inside the window.
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success,
        let value, CFGetTypeID(value) == AXUIElementGetTypeID()
      else { return nil }
      window = value as! AXUIElement
    }
    guard let target = target(for: window), target.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
    return target
  }

  static func target(for window: AXUIElement) -> Target? {
    var pid: pid_t = 0
    guard let windowID = WindowServer.windowID(of: window),
      AXUIElementGetPid(window, &pid) == .success,
      let frame = frame(of: window)
    else { return nil }
    return Target(window: window, windowID: windowID, frame: frame, pid: pid)
  }

  static func frame(of window: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
      let positionValue, let sizeValue
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
  }
}
