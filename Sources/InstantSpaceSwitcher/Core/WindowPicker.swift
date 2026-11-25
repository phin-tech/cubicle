import AppKit
import Carbon

/// Pick windows by clicking them, then name a new workspace for just those windows.
///
/// While picking, Cubicle catches every click (so the clicked app never sees it) and the Return and Escape keys.
/// Clicking a window outlines and numbers it; clicking it again lets it go. Return asks for a name and makes the
/// workspace (`VirtualWorkspaces.newWorkspace`); Escape, a right-click or the shortcut again stops without changes.
@MainActor
final class WindowPicker {
  static let shared = WindowPicker()

  private(set) var isPicking = false
  private var picked: [WindowMover.Target] = []
  private var outlines: [UInt32: NSWindow] = [:]
  private var hover: NSWindow?
  private var hoverID: UInt32?
  private var hint: NSWindow?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var swallowUp = false

  func toggle() {
    isPicking ? stop() : start()
  }

  func start() {
    guard !isPicking else { return }
    guard AXIsProcessTrusted() else {
      NSSound.beep()
      return
    }
    guard installEventTap() else {
      NSSound.beep()
      return
    }
    isPicking = true
    picked = []
    WindowClickMenu.shared.isPaused = true
    showHint()
  }

  func stop() {
    guard isPicking else { return }
    isPicking = false
    removeEventTap()
    WindowClickMenu.shared.isPaused = false
    outlines.values.forEach { $0.orderOut(nil) }
    outlines = [:]
    hover?.orderOut(nil)
    hoverID = nil
    hint?.orderOut(nil)
    picked = []
  }

  // MARK: - Events

  private func installEventTap() -> Bool {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved, .keyDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: { _, type, event, _ in
          MainActor.assumeIsolated { WindowPicker.shared.handle(type, event) }
        },
        userInfo: nil)
    else { return false }
    eventTap = tap
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
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

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    guard isPicking else { return Unmanaged.passUnretained(event) }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .leftMouseDown:
      let point = event.location
      swallowUp = true
      // Return from the tap first: finding the window asks its app.
      DispatchQueue.main.async { self.toggleWindow(at: point) }
      return nil
    case .leftMouseUp, .rightMouseUp:
      if swallowUp {
        swallowUp = false
        return nil
      }
    case .rightMouseDown:
      swallowUp = true
      DispatchQueue.main.async { self.stop() }
      return nil
    case .mouseMoved:
      let point = event.location
      DispatchQueue.main.async { self.updateHover(at: point) }
    case .keyDown:
      switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
      case kVK_Escape:
        DispatchQueue.main.async { self.stop() }
        return nil
      case kVK_Return, kVK_ANSI_KeypadEnter:
        DispatchQueue.main.async { self.finish() }
        return nil
      default:
        break
      }
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private func toggleWindow(at point: CGPoint) {
    guard isPicking, let hit = Self.windowUnder(point), let window = Self.target(hit) else { return }
    hover?.orderOut(nil)
    hoverID = nil
    if let position = picked.firstIndex(where: { $0.windowID == window.windowID }) {
      picked.remove(at: position)
      outlines.removeValue(forKey: window.windowID)?.orderOut(nil)
    } else {
      picked.append(window)
      outlines[window.windowID] = Self.outline(window.frame, number: picked.count, picked: true)
    }
    renumber()
    updateHint()
  }

  private func renumber() {
    for (position, window) in picked.enumerated() {
      (outlines[window.windowID]?.contentView as? OutlineView)?.number = position + 1
    }
  }

  /// The top window under the cursor, by the window server's list (cheap enough to run as the mouse moves).
  private func updateHover(at point: CGPoint) {
    guard isPicking else { return }
    let hit = Self.windowUnder(point)
    guard hit?.id != hoverID else { return }
    hoverID = hit?.id
    guard let hit, outlines[hit.id] == nil else {
      hover?.orderOut(nil)
      return
    }
    if hover == nil { hover = Self.outline(hit.frame, number: nil, picked: false) }
    hover?.setFrame(Self.cocoaFrame(hit.frame), display: true)
    hover?.orderFrontRegardless()
  }

  private struct Hit {
    let id: UInt32
    let pid: pid_t
    let frame: CGRect
  }

  /// The window's Accessibility element, found among its app's windows by number.
  private static func target(_ hit: Hit) -> WindowMover.Target? {
    let app = AXUIElementCreateApplication(hit.pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement],
      let window = windows.first(where: { WindowServer.windowID(of: $0) == hit.id })
    else { return nil }
    return WindowMover.target(for: window)
  }

  private static func windowUnder(_ point: CGPoint) -> Hit? {
    guard
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    for entry in list {
      guard (entry[kCGWindowLayer as String] as? Int) == 0,
        let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me,
        let number = entry[kCGWindowNumber as String] as? NSNumber,
        let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
        bounds.contains(point)
      else { continue }
      return Hit(id: number.uint32Value, pid: pid, frame: bounds)
    }
    return nil
  }

  // MARK: - Finishing

  private func finish() {
    guard isPicking else { return }
    guard !picked.isEmpty else {
      NSSound.beep()
      return
    }
    let windows = picked
    removeEventTap()
    hint?.orderOut(nil)
    hover?.orderOut(nil)
    guard let name = Self.askForName(windowCount: windows.count) else {
      stop()
      return
    }
    stop()
    let outcome = VirtualWorkspaces.shared.newWorkspace(with: windows, named: name)
    if !outcome.ok { NSSound.beep() }
    let screenID = WindowSender.spaces(for: windows[0])?.screenID ?? 0
    OSDWindow.shared.show(message: outcome.message, screenID: screenID, force: true, duration: outcome.ok ? 1.2 : 2.5)
  }

  /// Asks what to call the workspace; nil if cancelled. An empty name leaves it numbered.
  private static func askForName(windowCount: Int) -> String? {
    let alert = NSAlert()
    alert.messageText = "Name the New Workspace"
    alert.informativeText = "It will hold the \(windowCount) window\(windowCount == 1 ? "" : "s") you picked."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "Workspace name"
    field.formatter = SpaceNameFormatter()
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }

  // MARK: - Overlays

  private func showHint() {
    if hint == nil {
      let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.level = .statusBar
      panel.ignoresMouseEvents = true
      panel.hasShadow = true
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
      let effect = NSVisualEffectView()
      effect.material = .hudWindow
      effect.state = .active
      effect.wantsLayer = true
      effect.layer?.cornerRadius = 12
      let label = NSTextField(labelWithString: "")
      label.font = .systemFont(ofSize: 14, weight: .medium)
      label.alignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      effect.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
      ])
      panel.contentView = effect
      hint = panel
    }
    updateHint()
  }

  private func updateHint() {
    guard let hint, let label = hint.contentView?.subviews.first as? NSTextField else { return }
    let picks = picked.isEmpty ? "Click windows to put on a new workspace" : "\(picked.count) picked"
    label.stringValue = "\(picks) · Return to name it · Esc to cancel"
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    guard let screen else { return }
    let size = NSSize(width: label.intrinsicContentSize.width + 40, height: 40)
    let visible = screen.visibleFrame
    hint.setFrame(
      NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16, width: size.width, height: size.height),
      display: true)
    hint.orderFrontRegardless()
  }

  private static func outline(_ frame: CGRect, number: Int?, picked: Bool) -> NSWindow {
    let window = NSWindow(contentRect: cocoaFrame(frame), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .floating
    window.ignoresMouseEvents = true
    window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    let view = OutlineView()
    view.picked = picked
    view.number = number
    window.contentView = view
    window.orderFrontRegardless()
    return window
  }

  /// Accessibility's top-left-origin frame in AppKit's bottom-left-origin coordinates.
  private static func cocoaFrame(_ frame: CGRect) -> NSRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
  }
}

/// A coloured border, with the pick's number in a badge for picked windows.
private final class OutlineView: NSView {
  var picked = false { didSet { needsDisplay = true } }
  var number: Int? { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let color = NSColor.controlAccentColor
    color.withAlphaComponent(picked ? 0.18 : 0.08).setFill()
    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
    path.fill()
    color.withAlphaComponent(picked ? 1 : 0.6).setStroke()
    path.lineWidth = picked ? 4 : 2
    path.stroke()

    guard let number else { return }
    let text = NSAttributedString(
      string: "\(number)",
      attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white])
    let diameter: CGFloat = 52
    let badge = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
    color.setFill()
    NSBezierPath(ovalIn: badge).fill()
    let size = text.size()
    text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
  }
}
