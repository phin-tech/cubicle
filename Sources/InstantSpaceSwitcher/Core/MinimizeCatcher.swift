import AppKit
import CubicleIPC

/// Clicking a window's minimize button stashes it instead, against the edge chosen in Settings → Stash (off unless
/// one is chosen). A stashed window that's out tucks away again. Holding any modifier lets the button minimize as
/// usual.
///
/// Cubicle catches the click before the app does. Every plain left click is looked at, so the check is cheap first:
/// only a click in the top-left corner of a window, where its buttons are, asks the app what was clicked.
@MainActor
final class MinimizeCatcher {
  static let shared = MinimizeCatcher()

  static let defaultsKey = "stashOnMinimize"

  /// The edge the minimize button stashes to, or nil to leave it alone.
  static var edge: StashEdge? {
    get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(StashEdge.init(rawValue:)) }
    set {
      UserDefaults.standard.set(newValue?.rawValue, forKey: defaultsKey)
      shared.update()
    }
  }

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var retryScheduled = false
  /// The caught click's button-up is swallowed too, so the app never sees half a click.
  private var swallowUp = false
  private let systemWide: AXUIElement = {
    let element = AXUIElementCreateSystemWide()
    // A hung app mustn't hold up every click: the tap would be switched off.
    AXUIElementSetMessagingTimeout(element, 0.15)
    return element
  }()

  /// Installs or removes the tap to match the setting.
  func update() {
    Self.edge == nil ? removeEventTap() : installEventTap()
  }

  private func installEventTap() {
    if let eventTap, CFMachPortIsValid(eventTap) { return }
    removeEventTap()
    let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: { _, type, event, _ in
          MainActor.assumeIsolated { MinimizeCatcher.shared.handle(type, event) }
        },
        userInfo: nil)
    else {
      // Without Accessibility there is no tap yet; try again once it's granted.
      scheduleRetry()
      return
    }
    self.eventTap = eventTap
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  private func removeEventTap() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    eventTap = nil
    runLoopSource = nil
  }

  private func scheduleRetry() {
    guard !retryScheduled else { return }
    retryScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self else { return }
      self.retryScheduled = false
      if Self.edge != nil { self.installEventTap() }
    }
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .leftMouseDown:
      let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
      guard let edge = Self.edge, event.flags.intersection(modifiers).isEmpty,
        let window = minimizeButtonWindow(at: event.location)
      else { break }
      swallowUp = true
      // Return from the tap first: moving the window asks its app.
      DispatchQueue.main.async { Self.stash(window, to: edge) }
      return nil
    case .leftMouseUp:
      if swallowUp {
        swallowUp = false
        return nil
      }
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private static func stash(_ element: AXUIElement, to edge: StashEdge) {
    guard let window = WindowMover.target(for: element) else { return NSSound.beep() }
    if Stash.shared.contains(window.windowID) {
      Stash.shared.tuckAway(window.windowID)
    } else if !Stash.shared.stash(window, to: edge).ok {
      NSSound.beep()
    }
  }

  /// The window whose minimize button is at `point`, if that's what's there.
  private func minimizeButtonWindow(at point: CGPoint) -> AXUIElement? {
    guard Self.isNearWindowButtons(point) else { return nil }
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit,
      Self.string(hit, kAXSubroleAttribute) == kAXMinimizeButtonSubrole as String
    else { return nil }
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &window) == .success,
      let window, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    return (window as! AXUIElement)
  }

  /// Whether `point` is in the top-left corner of the frontmost ordinary window under it, where macOS puts the
  /// window buttons (lower down in windows with a tall toolbar). Windows above the ordinary ones are passed over:
  /// some apps keep an invisible one over the whole screen that clicks go through.
  private static func isNearWindowButtons(_ point: CGPoint) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    for info in windows where info[kCGWindowLayer as String] as? Int == 0 {
      guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
        .flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.contains(point)
      else { continue }
      return point.x - bounds.minX < 100 && point.y - bounds.minY < 90
    }
    return false
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }
}
