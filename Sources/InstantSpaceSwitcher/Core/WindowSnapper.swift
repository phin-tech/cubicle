import AppKit
import ApplicationServices
import CubicleIPC

/// Applies snaps (see CONTEXT.md) to other apps' windows through Accessibility. The frame maths is in
/// `SnapGeometry`; this finds the window, writes its frame and remembers what Restore needs.
///
/// The approach follows Rectangle (MIT, Copyright (c) 2019-2026 Ryan Hanson; based on Spectacle, Copyright (c)
/// 2017 Eric Czarny): size → position → size, Enhanced User Interface switched off while moving, and windows that
/// refuse a size lined up against the region's display edges.
@MainActor
enum WindowSnapper {
  struct Outcome {
    var ok: Bool
    var message: String
  }

  /// Which window a command acts on.
  enum Selector {
    case focused
    case app(String)
    case window(UInt32)
    case previous
  }

  // MARK: - Settings

  static let gapKey = "snapGap"
  static let maximumGap = 100

  /// Points kept between snapped windows and around the display's edges. Zero by default.
  static var gap: Int {
    get { min(max(UserDefaults.standard.integer(forKey: gapKey), 0), maximumGap) }
    set { UserDefaults.standard.set(min(max(newValue, 0), maximumGap), forKey: gapKey) }
  }

  // MARK: - Snapping

  private static var history = SnapHistory()

  /// Snaps the window `selector` picks. Beeps when it fails and `beep` is set (shortcuts and menus beep; the CLI
  /// prints the message instead).
  @discardableResult
  static func snap(_ action: SnapAction, _ selector: Selector = .focused, beep: Bool = false) -> Outcome {
    let outcome: Outcome
    switch resolve(selector) {
    case .success(let window): outcome = snap(action, window)
    case .failure(let failure): outcome = Outcome(ok: false, message: failure.message)
    }
    if beep && !outcome.ok { NSSound.beep() }
    return outcome
  }

  static func snap(_ action: SnapAction, _ window: WindowMover.Target) -> Outcome {
    guard AXIsProcessTrusted() else { return Outcome(ok: false, message: "Accessibility is not granted to Cubicle.") }
    setTimeout(on: window)
    if let refusal = refusal(for: window.window) { return Outcome(ok: false, message: refusal) }
    guard let current = WindowMover.frame(of: window.window) else {
      return Outcome(ok: false, message: "Could not read the window's frame.")
    }
    let name = window.displayName

    if action == .restore {
      guard let restore = history.takeRestore(window.windowID) else {
        return Outcome(ok: true, message: "\(name) has not been snapped, so there is nothing to restore.")
      }
      // A restore can take a window back to another display, so it goes through the resizing path as is.
      apply(restore, to: window, visible: visibleFrame(containing: restore) ?? restore, gap: 0, align: false)
      return Outcome(ok: true, message: "Restored \(name).")
    }

    guard let visible = visibleFrame(containing: current) else {
      return Outcome(ok: false, message: "Could not find the display \(name) is on.")
    }
    let gap = CGFloat(action == .center ? 0 : Self.gap)
    guard let target = SnapGeometry.frame(for: action, window: current, visible: visible, gap: gap) else {
      return Outcome(ok: false, message: "\(action.displayName) has no frame.")
    }
    // Pressing a snap again does nothing.
    if SnapGeometry.roughlyEqual(current, target) {
      return Outcome(ok: true, message: "\(name) is already there.")
    }

    history.willSnap(window.windowID, from: current)
    let result = apply(target, to: window, visible: visible, gap: gap, align: true)
    history.didSnap(window.windowID, to: result ?? target)
    pruneHistory()

    guard let result else { return Outcome(ok: false, message: "\(name) did not move.") }
    if abs(result.width - target.width) >= SnapGeometry.tolerance
      || abs(result.height - target.height) >= SnapGeometry.tolerance
    {
      return Outcome(ok: true, message: "\(action.displayName): \(name) kept its own size (\(Int(result.width))×\(Int(result.height))).")
    }
    return Outcome(ok: true, message: "\(action.displayName): \(name).")
  }

  /// Why Cubicle won't touch this window, if it won't.
  private static func refusal(for window: AXUIElement) -> String? {
    if string(window, kAXRoleAttribute) == kAXSheetRole as String { return "That is a sheet; snap its window instead." }
    if bool(window, "AXFullScreen") == true { return "The window is in full screen." }
    if bool(window, kAXMinimizedAttribute) == true { return "The window is minimized." }
    return nil
  }

  /// Writes `frame` and returns where the window ended up. A window that won't take the size is moved so it sits
  /// against the region's display edges (or in its middle) at the size it kept.
  @discardableResult
  private static func apply(
    _ frame: CGRect, to window: WindowMover.Target, visible: CGRect, gap: CGFloat, align: Bool
  ) -> CGRect? {
    let element = window.window
    let app = AXUIElementCreateApplication(window.pid)
    // With Enhanced User Interface on (VoiceOver, some apps turn it on themselves) apps animate AX resizes, and
    // the position and size writes fight each other.
    let enhanced = bool(app, "AXEnhancedUserInterface") == true
    if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
    defer {
      if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    var settable: DarwinBoolean = true
    let sizeSettable = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) != .success
      || settable.boolValue
    // System dialogs report a settable size but don't want one.
    let fixed = !sizeSettable || string(element, kAXSubroleAttribute) == kAXSystemDialogSubrole as String

    if !fixed {
      // Size first so the move isn't clamped by the old size, then again because macOS clamps a size to the
      // display the window was on when it was set.
      setSize(element, frame.size)
      setPosition(element, frame.origin)
      setSize(element, frame.size)
    }
    guard var result = WindowMover.frame(of: element) else { return nil }
    if align && (fixed || !SnapGeometry.roughlyEqual(CGRect(origin: frame.origin, size: result.size), frame)) {
      let placed = SnapGeometry.aligned(result.size, in: frame, visible: visible, gap: gap)
      setPosition(element, placed.origin)
      result = WindowMover.frame(of: element) ?? placed
    } else if fixed {
      setPosition(element, frame.origin)
      result = WindowMover.frame(of: element) ?? result
    }
    return result
  }

  private static func setSize(_ element: AXUIElement, _ size: CGSize) {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
  }

  private static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
  }

  /// A hung app would otherwise block the main thread for the system default of about six seconds.
  private static func setTimeout(on window: WindowMover.Target) {
    AXUIElementSetMessagingTimeout(window.window, 0.5)
    AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(window.pid), 0.5)
  }

  private static func pruneHistory() {
    guard history.entries.count > 32 else { return }
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let live = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    history.prune(keeping: live)
  }

  // MARK: - Displays

  /// The usable area (no menu bar or Dock) of the display holding most of `rect`, in top-left-origin coordinates.
  static func visibleFrame(containing rect: CGRect) -> CGRect? {
    let screens = NSScreen.screens
    guard let primary = screens.first else { return nil }
    let height = primary.frame.height
    let frames = screens.map { SnapGeometry.flipped($0.frame, primaryHeight: height) }
    let fallback = NSScreen.main.flatMap { screens.firstIndex(of: $0) } ?? 0
    guard let index = SnapGeometry.screenIndex(for: rect, screens: frames, fallback: fallback) else { return nil }
    return SnapGeometry.flipped(screens[index].visibleFrame, primaryHeight: height)
  }

  // MARK: - Finding the window

  enum Failure: Error {
    case noApp(String)
    case noWindow(String)
    case unknownWindow(UInt32)
    case noPrevious

    var message: String {
      switch self {
      case .noApp(let name): return "No running app matches '\(name)'."
      case .noWindow(let name): return "\(name) has no window on this Space."
      case .unknownWindow(let id): return "No window \(id) on this Space. `cubicle windows` lists them."
      case .noPrevious: return "There is no previous app yet."
      }
    }
  }

  /// Launchers that run Cubicle commands. When one of them (or Cubicle) is in front, "the focused window" means
  /// the window of the app that was in front before it.
  private static let launcherBundleIDs: Set<String> = [
    "com.runningwithcrayons.Alfred", "com.raycast.macos",
  ]

  static func resolve(_ selector: Selector) -> Result<WindowMover.Target, Failure> {
    switch selector {
    case .focused:
      guard let front = NSWorkspace.shared.frontmostApplication else { return .failure(.noWindow("No app")) }
      let isLauncher = front.processIdentifier == ProcessInfo.processInfo.processIdentifier
        || launcherBundleIDs.contains(front.bundleIdentifier ?? "")
      if isLauncher {
        guard let previous = AppHistory.shared.previous(excluding: front.processIdentifier) else {
          return .failure(.noPrevious)
        }
        return window(of: previous)
      }
      return window(of: front)
    case .previous:
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
      guard let previous = AppHistory.shared.previous(excluding: front) else { return .failure(.noPrevious) }
      return window(of: previous)
    case .app(let name):
      guard let app = runningApp(named: name) else { return .failure(.noApp(name)) }
      return window(of: app)
    case .window(let id):
      for app in regularApps() {
        for element in windows(of: app) where WindowServer.windowID(of: element) == id {
          if let target = WindowMover.target(for: element) { return .success(target) }
        }
      }
      return .failure(.unknownWindow(id))
    }
  }

  /// The app's focused window, else its first window that isn't minimized.
  private static func window(of app: NSRunningApplication) -> Result<WindowMover.Target, Failure> {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.5)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
      let target = WindowMover.target(for: value as! AXUIElement)
    {
      return .success(target)
    }
    for window in windows(of: app) where bool(window, kAXMinimizedAttribute) != true {
      if let target = WindowMover.target(for: window) { return .success(target) }
    }
    return .failure(.noWindow(app.localizedName ?? "The app"))
  }

  /// Matches an app's name (case-insensitively, whole name first, then the start of it) or its bundle ID.
  static func runningApp(named name: String) -> NSRunningApplication? {
    let wanted = name.lowercased()
    let apps = regularApps()
    return apps.first { $0.bundleIdentifier?.lowercased() == wanted }
      ?? apps.first { $0.localizedName?.lowercased() == wanted }
      ?? apps.first { $0.localizedName?.lowercased().hasPrefix(wanted) == true }
  }

  private static func regularApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
  }

  /// The app's windows on the current Space (Accessibility can't see the others).
  private static func windows(of app: NSRunningApplication) -> [AXUIElement] {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }

  /// Every standard window on the current Space, front app first.
  static func listWindows() -> [CubicleWindowEntry] {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let apps = regularApps().sorted { ($0.processIdentifier == front ? 0 : 1) < ($1.processIdentifier == front ? 0 : 1) }
    var entries: [CubicleWindowEntry] = []
    for app in apps {
      let element = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(element, 0.5)
      var focused: CFTypeRef?
      AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused)
      let focusedID = focused.flatMap { value -> CGWindowID? in
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return WindowServer.windowID(of: value as! AXUIElement)
      }
      for window in windows(of: app) {
        guard string(window, kAXRoleAttribute) == kAXWindowRole as String,
          let target = WindowMover.target(for: window)
        else { continue }
        entries.append(
          CubicleWindowEntry(
            id: target.windowID, app: app.localizedName ?? "?", bundleID: app.bundleIdentifier,
            title: target.title, x: target.frame.minX, y: target.frame.minY, width: target.frame.width,
            height: target.frame.height,
            isFocused: app.processIdentifier == front && focusedID == target.windowID,
            isMinimized: bool(window, kAXMinimizedAttribute) == true))
      }
    }
    return entries
  }

  // MARK: - Attributes

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? Bool
  }
}

/// The order apps came to the front in, so "the previous app" means something.
@MainActor
final class AppHistory {
  static let shared = AppHistory()

  private var recent: [pid_t] = []
  private var observer: Any?

  func start() {
    guard observer == nil else { return }
    if let front = NSWorkspace.shared.frontmostApplication { recent = [front.processIdentifier] }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      let pid = app.processIdentifier
      MainActor.assumeIsolated { AppHistory.shared.activated(pid) }
    }
  }

  private func activated(_ pid: pid_t) {
    recent.removeAll { $0 == pid }
    recent.insert(pid, at: 0)
    if recent.count > 8 { recent.removeLast() }
  }

  /// The most recent app other than `excluding`, Cubicle and the launchers, that is still running.
  func previous(excluding pid: pid_t) -> NSRunningApplication? {
    let me = ProcessInfo.processInfo.processIdentifier
    for candidate in recent where candidate != pid && candidate != me {
      guard let app = NSRunningApplication(processIdentifier: candidate), !app.isTerminated,
        app.activationPolicy == .regular
      else { continue }
      if ["com.runningwithcrayons.Alfred", "com.raycast.macos"].contains(app.bundleIdentifier ?? "") { continue }
      return app
    }
    return nil
  }
}
