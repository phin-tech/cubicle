import AppKit

/// Swiping left or right with three or four fingers switches workspaces. An event tap catches the trackpad's Dock
/// swipe before the Dock sees it, so macOS doesn't try to slide to a Space that isn't there. It switches once per
/// swipe, as soon as the swipe has a direction. The approach is ISS's swipe override, rewritten for workspaces.
@MainActor
final class SwipeSwitcher {
  static let shared = SwipeSwitcher()
  static let defaultsKey = "swipeWorkspaces"

  static var isEnabledSetting: Bool {
    get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: defaultsKey)
      shared.setEnabled(newValue)
    }
  }

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var wanted = false
  fileprivate var tracking = false
  fileprivate var fired = false

  func setEnabled(_ enabled: Bool) {
    wanted = enabled
    enabled ? start() : stop()
  }

  private func start() {
    guard tap == nil else { return }
    let mask = CGEventMask(1 << Event.gesture) | CGEventMask(1 << Event.dockControl)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: swipeTapCallback, userInfo: nil)
    else {
      // No Accessibility permission yet: try again until it's granted.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, self.wanted else { return }
        self.start()
      }
      return
    }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.tap = tap
    self.source = source
  }

  private func stop() {
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    tap = nil
    source = nil
    tracking = false
    fired = false
  }

  fileprivate func reenable() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
  }

  /// The window server's event types and fields for gestures, as ISS used them.
  fileprivate enum Event {
    static let gesture: Int64 = 29
    static let dockControl: Int64 = 30
    static let dockSwipe: Int64 = 23
    static let horizontal: Int64 = 1
    static let type = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let motion = CGEventField(rawValue: 123)!
    static let progress = CGEventField(rawValue: 124)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
  }

  fileprivate enum Phase: Int64 {
    case began = 1, changed = 2, ended = 4, cancelled = 8
  }

  /// From macOS 27 the Dock needs the real ended event to close its gesture, so it's passed on with its motion zeroed
  /// instead of being swallowed.
  fileprivate static let passesEndedEvent = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

  /// Whether to swallow `event`, switching if it's the moment the swipe got a direction.
  fileprivate func handle(_ event: CGEvent) -> Bool {
    let type = event.getIntegerValueField(Event.type)
    guard type == Event.dockControl || type == Event.gesture else { return false }
    // Real trackpad events come from the kernel (pid 0); anything else was posted by an app.
    guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return false }
    guard type == Event.dockControl else { return tracking }
    guard event.getIntegerValueField(Event.hidType) == Event.dockSwipe,
      event.getIntegerValueField(Event.motion) == Event.horizontal
    else { return false }

    switch Phase(rawValue: event.getIntegerValueField(Event.phase)) {
    case .began:
      tracking = true
      fired = false
      return true
    case .changed:
      guard tracking else { return false }
      fire(event.getDoubleValueField(Event.progress))
      return true
    case .ended:
      guard tracking else { return false }
      fire(event.getDoubleValueField(Event.velocityX))
      tracking = false
      fired = false
      if Self.passesEndedEvent {
        event.setDoubleValueField(Event.progress, value: 0)
        event.setDoubleValueField(Event.velocityX, value: 0)
        event.setDoubleValueField(Event.velocityY, value: 0)
        return false
      }
      return true
    case .cancelled:
      tracking = false
      fired = false
      return true
    case nil:
      return tracking
    }
  }

  private func fire(_ value: Double) {
    guard !fired, value != 0 else { return }
    fired = true
    let direction: SwitchDirection = value > 0 ? .right : .left
    // Outside the tap callback, which the system disables if it takes too long.
    DispatchQueue.main.async {
      if !VirtualWorkspaces.shared.stepUnderCursor(direction) { NSSound.beep() }
    }
  }
}

private func swipeTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  MainActor.assumeIsolated {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      SwipeSwitcher.shared.reenable()
      return Unmanaged.passUnretained(event)
    }
    return SwipeSwitcher.shared.handle(event) ? nil : Unmanaged.passUnretained(event)
  }
}
