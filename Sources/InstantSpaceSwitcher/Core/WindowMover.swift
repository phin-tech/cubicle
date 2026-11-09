import AppKit
import ApplicationServices
import ISS

/// Moves a window to another Space on its display: by holding its title bar while the display switches, or by
/// parking it on another display meanwhile. The window server's own move calls are ignored on macOS 27; see
/// docs/moving-windows-between-spaces.md.
@MainActor
enum WindowMover {
  enum Method: String { case direct, compat, drag }

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

  private static func target(for window: AXUIElement) -> Target? {
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

  /// Holds the window by its title bar and steps to the target with the system "Move left/right a space"
  /// shortcuts (Ctrl+arrow), then lets go. macOS ignores Cubicle's synthetic swipe while a mouse button is down,
  /// but a held window rides along with a keyboard switch. Calls `completion` with whether the window ended up on
  /// `spaceID`.
  static func moveByDragging(
    _ target: Target, from currentIndex: Int, toIndex index: Int, spaceID: UInt64, quickSwitch: Bool = false,
    completion: @escaping (Bool) -> Void
  ) {
    let savedCursor = CGEvent(source: nil)?.location ?? .zero
    // Middle of the title bar. Tab-strip apps (Chrome, Safari) may need a smarter point.
    let grab = CGPoint(x: target.frame.midX, y: target.frame.minY + 8)
    let steps = abs(index - currentIndex)
    let arrow: CGKeyCode = index > currentIndex ? 124 : 123  // right : left
    // Timings follow Keyboard Maestro's "Desktop Spaces" macros, which needed a long hold before switching and a
    // long wait before letting go: the system switch animates and the window server must settle the drag.
    let holdBeforeSwitch = 0.5
    let stepDelay = 0.8
    let holdAfterSwitch = 1.2

    post(.mouseMoved, at: grab)
    post(.leftMouseDown, at: grab)
    post(.leftMouseDragged, at: CGPoint(x: grab.x + 1, y: grab.y))
    post(.leftMouseDragged, at: grab)

    var switchReport = "\(steps) Ctrl+arrow step(s)"
    if quickSwitch {
      DispatchQueue.main.asyncAfter(deadline: .now() + holdBeforeSwitch) {
        let posted = iss_switch_to_index(UInt32(index))
        switchReport = "instant switch posted=\(posted), active while held=\(activeSpaceID())"
      }
    }
    for step in 0..<(quickSwitch ? 0 : steps) {
      DispatchQueue.main.asyncAfter(deadline: .now() + holdBeforeSwitch + Double(step) * stepDelay) {
        pressControlArrow(arrow)
      }
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + holdBeforeSwitch + Double(quickSwitch ? 0 : max(steps - 1, 0)) * stepDelay + holdAfterSwitch) {
      let activeWhileHeld = activeSpaceID()
      post(.leftMouseUp, at: grab)
      CGWarpMouseCursorPosition(savedCursor)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let after = WindowServer.space(ofWindow: target.windowID)
        lastDragReport = "\(switchReport); active before release=\(activeWhileHeld), active Space after=\(activeSpaceID()), window Space after=\(after)"
        completion(after == spaceID)
      }
    }
  }

  /// Experimental: park on a second display so the original display can switch without dragging.
  static func moveViaDisplay(
    _ target: Target, toIndex index: Int, spaceID: UInt64, stagingDisplayID: CGDirectDisplayID? = nil, returnToIndex: Int? = nil,
    completion: @escaping (Bool, String) -> Void
  ) {
    guard NSScreen.screensHaveSeparateSpaces else {
      return completion(false, "Requires Displays have separate Spaces.")
    }
    let bounds = NSScreen.screens.compactMap { screen -> CGRect? in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      return CGDisplayBounds(number.uint32Value)
    }
    let anchor = CGPoint(x: target.frame.midX, y: target.frame.minY + 8)
    guard let source = bounds.first(where: { $0.contains(anchor) }),
      let staging = bounds.first(where: { $0 != source && (stagingDisplayID == nil || $0 == CGDisplayBounds(stagingDisplayID!)) }) else {
      return completion(false, "Staging display is not available as a separate extended desktop. Visible display bounds: \(bounds)")
    }
    guard staging.width > 100, staging.height > 120 else {
      return completion(false, "Staging display is too small: \(staging)")
    }
    let cursor = CGEvent(source: nil)?.location ?? .zero
    let originalSpace = WindowServer.space(ofWindow: target.windowID)
    func position(_ point: CGPoint) -> AXError {
      var point = point
      guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
      return AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, value)
    }
    func resize(_ size: CGSize) -> AXError {
      var size = size
      guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
      return AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, value)
    }
    let smallSize = CGSize(width: min(target.frame.width, staging.width - 80),
                           height: min(target.frame.height, staging.height - 100))
    let needsResize = smallSize != target.frame.size
    let shrink = needsResize ? resize(smallSize) : .success
    func restoreGeometry() -> String {
      let positionResult = position(target.frame.origin)
      let sizeResult = needsResize ? resize(target.frame.size) : .success
      // Some apps adjust their origin while resizing.
      let finalPosition = position(target.frame.origin)
      return "position AX=\(positionResult.rawValue)/\(finalPosition.rawValue), size AX=\(sizeResult.rawValue)"
    }
    guard shrink == .success else {
      let recovery = restoreGeometry()
      return completion(false, "Could not shrink window: AX=\(shrink.rawValue); restore: \(recovery)")
    }
    let started = ProcessInfo.processInfo.systemUptime
    var timings: [String] = []
    func mark(_ step: String) {
      timings.append("\(step)=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))ms")
    }
    func finish(_ moved: Bool, _ report: String) {
      CGWarpMouseCursorPosition(cursor)
      mark("total")
      completion(moved, report + "\n" + timings.joined(separator: ", "))
    }
    func geometryMatches() -> Bool {
      guard let actual = frame(of: target.window) else { return false }
      return abs(actual.minX - target.frame.minX) <= 2 && abs(actual.minY - target.frame.minY) <= 2
        && abs(actual.width - target.frame.width) <= 2 && abs(actual.height - target.frame.height) <= 2
    }
    func onSource() -> Bool {
      frame(of: target.window).map { source.contains(CGPoint(x: $0.midX, y: $0.minY + 8)) } == true
    }
    // Recovery also waits for the display transition before expanding the window.
    func recover(_ reason: String) {
      _ = position(target.frame.origin)
      waitUntil({ onSource() }) { _ in
        _ = restoreGeometry()
        finish(false, reason + "; attempted to restore original frame")
      }
    }
    guard position(CGPoint(x: staging.minX + 20, y: staging.minY + 40)) == .success else {
      return recover("Parking position rejected")
    }
    waitUntil({
      let parkedSpace = WindowServer.space(ofWindow: target.windowID)
      return parkedSpace != 0 && parkedSpace != originalSpace
        && frame(of: target.window).map { staging.contains($0) } == true
    }) { parked in
      mark("parked")
      guard parked else { return recover("Timed out parking window") }
      CGWarpMouseCursorPosition(anchor)
      guard iss_switch_to_index(UInt32(index)) else { return recover("Switch rejected") }
      waitUntil({
        CGWarpMouseCursorPosition(anchor)
        return activeSpaceID() == spaceID
      }) { switched in
        mark("destination")
        guard switched else { return recover("Timed out switching to destination") }
        guard position(target.frame.origin) == .success else { return recover("Return position rejected") }
        waitUntil({ WindowServer.space(ofWindow: target.windowID) == spaceID && onSource() }) { returned in
          mark("window returned")
          guard returned else { return recover("Timed out returning window from staging") }
          // AX may acknowledge geometry before the app updates its display constraints.
          // Retry expansion at 50ms intervals until the actual frame matches.
          var lastResize = -Double.infinity
          waitUntil({
            if geometryMatches() { return true }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastResize >= 0.05 {
              _ = restoreGeometry()
              lastResize = now
            }
            return false
          }) { restored in
            mark("geometry")
            let report = "geometry restored=\(restored), window Space=\(WindowServer.space(ofWindow: target.windowID))"
              + (restored ? "" : "\nWarning: original frame \(target.frame); actual \(String(describing: frame(of: target.window))).")
            guard let returnToIndex, WindowServer.space(ofWindow: target.windowID) == spaceID else {
              return finish(WindowServer.space(ofWindow: target.windowID) == spaceID, report)
            }
            CGWarpMouseCursorPosition(anchor)
            let posted = iss_switch_to_index(UInt32(returnToIndex))
            waitUntil({
              CGWarpMouseCursorPosition(anchor)
              return activeSpaceID() == originalSpace
            }) { stayed in
              let finalSpace = WindowServer.space(ofWindow: target.windowID)
              finish(finalSpace == spaceID,
                report + "\nReturn to starting Space=\(posted && stayed), window Space=\(finalSpace)")
            }
          }
        }
      }
    }
  }

  /// Nonblocking checks, with a bounded deadline for each transition.
  static func waitUntil(
    _ condition: @escaping () -> Bool, timeout: TimeInterval = 1.5,
    completion: @escaping (Bool) -> Void
  ) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    func poll() {
      if condition() { return completion(true) }
      if ProcessInfo.processInfo.systemUptime >= deadline { return completion(false) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
    }
    poll()
  }

  private static func pressControlArrow(_ keyCode: CGKeyCode) {
    // Arrow keys carry the fn and numeric-pad flags; the system shortcut is registered with them.
    let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }

  static var lastDragReport = ""

  /// The Space showing on the display under the cursor.
  static func activeSpaceID() -> UInt64 {
    SpaceCatalog.shared.spacesUnderCursor()?.display.currentSpaceID ?? 0
  }

  private static func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }
}

/// Keeps staging alive across a short burst of moves, then releases it when safe.
@MainActor
enum VirtualDisplaySession {
  static var automaticShutdown: Bool {
    get { UserDefaults.standard.object(forKey: "stagingAutomaticShutdown") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "stagingAutomaticShutdown"); settingsChanged() }
  }
  static var idleSeconds: Int {
    get {
      let value = UserDefaults.standard.object(forKey: "stagingIdleSeconds") as? Int ?? 10
      return min(3600, max(1, value))
    }
    set { UserDefaults.standard.set(min(3600, max(1, newValue)), forKey: "stagingIdleSeconds"); settingsChanged() }
  }
  static func settingsChanged() {
    cancelCleanup()
    if !moving { scheduleCleanup() }
  }
  static private(set) var moving = false
  private static var cleanup: DispatchWorkItem?
  private static var generation = 0
  private static var protectedWindows: [UInt32: WindowMover.Target] = [:]

  static func begin() -> Bool {
    guard !moving else { return false }
    cancelCleanup()
    moving = true
    return true
  }

  static func cancelCleanup() {
    generation += 1
    cleanup?.cancel()
    cleanup = nil
  }

  static func end(window: WindowMover.Target, display: CGDirectDisplayID) {
    moving = false
    guard display != 0 else { return }
    protectedWindows[window.windowID] = window
    scheduleCleanup()
  }

  private static func scheduleCleanup() {
    cancelCleanup()
    let display = VirtualDisplay.id
    guard automaticShutdown, !moving, display != 0 else { return }
    let token = generation
    let work = DispatchWorkItem {
      guard token == generation, !moving, VirtualDisplay.id == display else { return }
      let bounds = CGDisplayBounds(display)
      // Keep the display attached if recovery left a window there or its location is unknown.
      for target in protectedWindows.values {
        guard let frame = WindowMover.frame(of: target.window), !bounds.intersects(frame) else { return }
      }
      VirtualDisplay.remove()
      protectedWindows.removeAll()
      cleanup = nil
    }
    cleanup = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(idleSeconds), execute: work)
  }
}
