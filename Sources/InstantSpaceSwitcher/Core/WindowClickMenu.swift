import AppKit
import ISS

/// ⌃⌥⌘-right-click a window to get a menu of the Spaces on its display; picking one sends the window there.
///
/// Other apps' own context menus can't be extended, so Cubicle catches the click before the app does and shows
/// its own menu. The three modifiers match the default switching shortcuts and keep ordinary right-clicks alone.
@MainActor
final class WindowClickMenu: NSObject {
  static let shared = WindowClickMenu()

  static let defaultsKey = "windowClickMenuEnabled"
  static var isEnabledSetting: Bool {
    get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: defaultsKey)
      shared.setEnabled(newValue)
    }
  }

  private static let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var retryScheduled = false
  private var enabled = false
  /// The click's button-up belongs to the menu too, so the app never sees half a click.
  private var swallowNextMouseUp = false
  private var pending: (window: WindowMover.Target, screenID: UInt32)?

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    enabled ? installEventTap() : removeEventTap()
  }

  private func installEventTap() {
    if let eventTap, CFMachPortIsValid(eventTap) { return }
    removeEventTap()

    let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: { _, type, event, _ in
          // Taps on the main run loop call back on the main thread.
          MainActor.assumeIsolated { WindowClickMenu.shared.handle(type, event) }
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
      if self.enabled { self.installEventTap() }
    }
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .rightMouseDown:
      let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
      guard flags == Self.modifiers else { break }
      swallowNextMouseUp = true
      let point = event.location
      // Return from the tap first: finding the window asks its app, and the menu runs its own loop.
      DispatchQueue.main.async { self.showMenu(at: point) }
      return nil
    case .rightMouseUp where swallowNextMouseUp:
      swallowNextMouseUp = false
      return nil
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private func showMenu(at point: CGPoint) {
    guard let window = WindowMover.window(at: point) else { return }
    guard let (cells, info) = WindowSender.spaces(for: window) else { return NSSound.beep() }

    let menu = NSMenu()
    menu.autoenablesItems = false
    let header = NSMenuItem(title: "Send “\(window.displayName)” to", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    for cell in cells {
      let item = NSMenuItem(title: WindowSender.name(of: cell), action: #selector(pick(_:)), keyEquivalent: "")
      item.target = self
      item.tag = cell.index
      if cell.index < 9 {
        item.keyEquivalent = String(cell.index + 1)
        item.keyEquivalentModifierMask = []
      }
      if cell.index == Int(info.currentIndex) {
        // Where the window already is.
        item.state = .on
        item.isEnabled = false
      }
      menu.addItem(item)
    }

    pending = (window, info.screenID)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    // popUp returns after the choice's action has run.
    pending = nil
  }

  @objc private func pick(_ sender: NSMenuItem) {
    guard let (window, screenID) = pending else { return }
    let index = sender.tag
    // Let the menu finish closing before the move starts grabbing and switching.
    DispatchQueue.main.async {
      WindowSender.sendShowingProgress(window, toIndex: index, screenID: screenID)
    }
  }
}
