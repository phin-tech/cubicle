import AppKit

/// ⌃⌥⌘-click (or right-click) a window to get a menu of the Spaces on its display; picking one sends the window
/// there. The menu bar's "Move Current Window to Space" uses the same items.
///
/// Other apps' own context menus can't be extended, so Cubicle catches the click before the app does and shows
/// its own menu. The three modifiers match the default switching shortcuts and keep ordinary clicks alone; the
/// catch is that ⌃⌥⌘-drag no longer reaches other apps while this is on.
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
  private var swallowedButtons: Set<CGEventType> = []

  /// What a Space item sends where.
  private final class Choice: NSObject {
    let window: WindowMover.Target
    let index: Int
    let screenID: UInt32
    init(window: WindowMover.Target, index: Int, screenID: UInt32) {
      self.window = window
      self.index = index
      self.screenID = screenID
    }
  }

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    enabled ? installEventTap() : removeEventTap()
  }

  private func installEventTap() {
    if let eventTap, CFMachPortIsValid(eventTap) { return }
    removeEventTap()

    let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
      .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
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
    case .leftMouseDown, .rightMouseDown:
      let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
      guard flags == Self.modifiers else { break }
      swallowedButtons.insert(type == .leftMouseDown ? .leftMouseUp : .rightMouseUp)
      let point = event.location
      // Return from the tap first: finding the window asks its app, and the menu runs its own loop.
      DispatchQueue.main.async { self.showMenu(at: point) }
      return nil
    case .leftMouseUp, .rightMouseUp:
      if swallowedButtons.remove(type) != nil { return nil }
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private func showMenu(at point: CGPoint) {
    guard let window = WindowMover.window(at: point) else { return }
    guard let items = sendItems(for: window) else { return NSSound.beep() }
    let menu = NSMenu()
    menu.autoenablesItems = false
    items.forEach(menu.addItem)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  /// A heading naming the window, then one item per Space on its display (its own Space checked and disabled),
  /// or nil when the Spaces can't be read. Menus holding these need `autoenablesItems = false`.
  func sendItems(for window: WindowMover.Target) -> [NSMenuItem]? {
    guard let spaces = WindowSender.spaces(for: window) else { return nil }
    let header = NSMenuItem(title: "Send “\(window.displayName)” to", action: nil, keyEquivalent: "")
    header.isEnabled = false
    return [header] + SpaceGridWindow.cells(for: spaces).map { cell in
      let item = NSMenuItem(title: WindowSender.name(of: cell), action: #selector(pick(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = Choice(window: window, index: cell.index, screenID: spaces.screenID)
      if cell.index < 9 {
        item.keyEquivalent = String(cell.index + 1)
        item.keyEquivalentModifierMask = []
      }
      if cell.index == spaces.currentIndex {
        // Where the window already is.
        item.state = .on
        item.isEnabled = false
      }
      return item
    }
  }

  @objc private func pick(_ sender: NSMenuItem) {
    guard let choice = sender.representedObject as? Choice else { return }
    // Let the menu finish closing before the move starts grabbing and switching.
    DispatchQueue.main.async {
      WindowSender.sendShowingProgress(choice.window, toIndex: choice.index, screenID: choice.screenID)
    }
  }
}
